package movedecl

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/goast"
)

func writeModule(t *testing.T, files map[string]string) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	files["go.mod"] = "module example.com/app\n\ngo 1.22\n"
	for name, content := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func offsetOf(t *testing.T, dir, file, needle string) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, file))
	if err != nil {
		t.Fatal(err)
	}
	i := strings.Index(string(data), needle)
	if i < 0 {
		t.Fatalf("%q not found in %s", needle, file)
	}
	return i
}

func wireOffset(src string, pos goast.LSPWirePos) int {
	line, col := 0, 0
	for i, r := range src {
		if line == pos.Line && col == pos.Character {
			return i
		}
		if r == '\n' {
			line++
			col = 0
		} else if r >= 0x10000 {
			col += 2
		} else {
			col++
		}
	}
	return len(src)
}

func applyResponse(t *testing.T, resp goast.GenerateCodeResponse) {
	t.Helper()
	for path, edits := range resp.EditsByPath {
		data, _ := os.ReadFile(path)
		src := string(data)
		if len(edits) == 1 && edits[0].NewText == src {
			continue
		}
		for i := len(edits) - 1; i >= 0; i-- {
			start, end := wireOffset(src, edits[i].Range.Start), wireOffset(src, edits[i].Range.End)
			src = src[:start] + edits[i].NewText + src[end:]
		}
		if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func mustVet(t *testing.T, dir string) {
	t.Helper()
	cmd := exec.Command("go", "vet", "./...")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("project does not compile after the move: %v\n%s", err, out)
	}
}

func read(t *testing.T, dir, file string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, file))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestMoveFunctionToExistingPackage(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"util/util.go":      "package util\n\nimport \"strings\"\n\n// Shout returns s in capitals.\nfunc Shout(s string) string {\n\treturn strings.ToUpper(s) + Suffix\n}\n\nconst Suffix = \"!\"\n\nfunc Local() string { return Shout(\"x\") }\n",
		"text/text.go":      "package text\n\nfunc Trim(s string) string { return s }\n",
		"cmd/main.go":       "package main\n\nimport (\n\t\"fmt\"\n\n\t\"example.com/app/util\"\n)\n\nfunc main() { fmt.Println(util.Shout(\"a\")) }\n",
		"other/other.go":    "package other\n\nimport u \"example.com/app/util\"\n\nfunc Loud() string { return u.Shout(\"b\") + u.Suffix }\n",
		"util/util_test.go": "package util\n\nimport \"testing\"\n\nfunc TestShout(t *testing.T) {\n\tif Shout(\"a\") == \"\" {\n\t\tt.Fatal()\n\t}\n}\n",
	})
	resp := Move(context.Background(), Request{
		Path: filepath.Join(dir, "util/util.go"), Offset: offsetOf(t, dir, "util/util.go", "func Shout"),
		Dest: filepath.Join(dir, "text/text.go"), WorkspaceDir: dir,
	})
	if resp.Error == "" {
		t.Fatalf("expected the move to be refused: util still uses Shout and Shout uses util.Suffix")
	}
	if !strings.Contains(resp.Error, "import it back") {
		t.Fatalf("unexpected reason: %s", resp.Error)
	}
}

func TestMoveFunctionRewritesEveryReference(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"util/util.go":      "package util\n\nimport \"strings\"\n\n// Shout returns s in capitals.\nfunc Shout(s string) string {\n\treturn strings.ToUpper(s)\n}\n\nfunc Local() string { return Shout(\"x\") }\n",
		"text/text.go":      "package text\n\nfunc Trim(s string) string { return s }\n",
		"cmd/main.go":       "package main\n\nimport (\n\t\"fmt\"\n\n\t\"example.com/app/util\"\n)\n\nfunc main() { fmt.Println(util.Shout(\"a\")) }\n",
		"other/other.go":    "package other\n\nimport u \"example.com/app/util\"\n\nfunc Loud() string { return u.Shout(\"b\") + u.Local() }\n",
		"util/util_test.go": "package util\n\nimport \"testing\"\n\nfunc TestShout(t *testing.T) {\n\tif Shout(\"a\") == \"\" {\n\t\tt.Fatal()\n\t}\n}\n",
		"util/x_test.go":    "package util_test\n\nimport (\n\t\"testing\"\n\n\t\"example.com/app/util\"\n)\n\nfunc TestX(t *testing.T) { _ = util.Shout(\"a\") }\n",
	})
	resp := Move(context.Background(), Request{
		Path: filepath.Join(dir, "util/util.go"), Offset: offsetOf(t, dir, "util/util.go", "func Shout"),
		Dest: filepath.Join(dir, "text/text.go"), WorkspaceDir: dir,
	})
	if resp.Error != "" {
		t.Fatal(resp.Error)
	}
	applyResponse(t, resp)
	mustVet(t, dir)
	if got := read(t, dir, "util/util.go"); strings.Contains(got, "func Shout") || strings.Contains(got, "\"strings\"") || !strings.Contains(got, "text.Shout(\"x\")") {
		t.Errorf("source file not updated:\n%s", got)
	}
	if got := read(t, dir, "text/text.go"); !strings.Contains(got, "// Shout returns s in capitals.\nfunc Shout") || !strings.Contains(got, "\"strings\"") {
		t.Errorf("destination file not updated:\n%s", got)
	}
	if got := read(t, dir, "cmd/main.go"); !strings.Contains(got, "text.Shout(\"a\")") || strings.Contains(got, "app/util\"") {
		t.Errorf("cmd/main.go not updated:\n%s", got)
	}
	if got := read(t, dir, "other/other.go"); !strings.Contains(got, "text.Shout(\"b\") + u.Local()") || !strings.Contains(got, "u \"example.com/app/util\"") {
		t.Errorf("other/other.go not updated:\n%s", got)
	}
	if got := read(t, dir, "util/x_test.go"); !strings.Contains(got, "text.Shout(\"a\")") {
		t.Errorf("util/x_test.go not updated:\n%s", got)
	}
}

func TestMoveTypeWithMethodsToNewPackage(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"store/store.go":   "package store\n\nimport \"sync\"\n\n// Cache holds values.\ntype Cache struct {\n\tmu    sync.Mutex\n\tItems map[string]string\n}\n\nfunc New() *Cache { return &Cache{Items: map[string]string{}} }\n",
		"store/methods.go": "package store\n\nfunc (c *Cache) Get(k string) string {\n\tc.mu.Lock()\n\tdefer c.mu.Unlock()\n\treturn c.Items[k]\n}\n\nfunc Helper() int { return 1 }\n",
		"cmd/main.go":      "package main\n\nimport \"example.com/app/store\"\n\nfunc main() {\n\tvar c *store.Cache = store.New()\n\t_ = c.Get(\"k\")\n}\n",
	})
	dest := filepath.Join(dir, "internal/cache/cache.go")
	resp := Move(context.Background(), Request{
		Path: filepath.Join(dir, "store/store.go"), Offset: offsetOf(t, dir, "store/store.go", "type Cache"),
		Dest: dest, WorkspaceDir: dir,
	})
	if resp.Error != "" {
		t.Fatal(resp.Error)
	}
	applyResponse(t, resp)
	mustVet(t, dir)
	got := read(t, dir, "internal/cache/cache.go")
	if !strings.HasPrefix(got, "package cache\n") || !strings.Contains(got, "type Cache struct") || !strings.Contains(got, "func (c *Cache) Get") || !strings.Contains(got, "\"sync\"") {
		t.Errorf("new package file:\n%s", got)
	}
	if got := read(t, dir, "store/store.go"); !strings.Contains(got, "func New() *cache.Cache { return &cache.Cache{") || strings.Contains(got, "\"sync\"") {
		t.Errorf("store/store.go:\n%s", got)
	}
	if got := read(t, dir, "store/methods.go"); strings.Contains(got, "Get") || !strings.Contains(got, "func Helper") {
		t.Errorf("store/methods.go:\n%s", got)
	}
	if got := read(t, dir, "cmd/main.go"); !strings.Contains(got, "var c *cache.Cache = store.New()") {
		t.Errorf("cmd/main.go:\n%s", got)
	}
}

func TestMoveIntoPackageThatAlreadyUsesIt(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"util/util.go": "package util\n\nfunc Double(n int) int { return n * 2 }\n\nfunc Other() int { return 1 }\n",
		"calc/calc.go": "package calc\n\nimport \"example.com/app/util\"\n\nfunc Quad(n int) int { return util.Double(util.Double(n)) }\n",
	})
	resp := Move(context.Background(), Request{
		Path: filepath.Join(dir, "util/util.go"), Offset: offsetOf(t, dir, "util/util.go", "func Double"),
		Dest: filepath.Join(dir, "calc/calc.go"), WorkspaceDir: dir,
	})
	if resp.Error != "" {
		t.Fatal(resp.Error)
	}
	applyResponse(t, resp)
	mustVet(t, dir)
	if got := read(t, dir, "calc/calc.go"); !strings.Contains(got, "return Double(Double(n))") || strings.Contains(got, "app/util") || !strings.Contains(got, "func Double(n int) int") {
		t.Errorf("calc/calc.go:\n%s", got)
	}
}

func TestMoveRefusals(t *testing.T) {
	dir := writeModule(t, map[string]string{
		"util/util.go": "package util\n\nfunc helper() int { return 1 }\n\nfunc Use() int { return helper() }\n\nfunc Needs() int { return secret }\n\nvar secret = 2\n\nconst (\n\tA = iota\n\tB\n)\n\ntype T struct{}\n\nfunc (T) M() {}\n",
		"text/text.go": "package text\n\nfunc Use() int { return 0 }\n",
	})
	cases := []struct{ needle, want string }{
		{"func helper", "not exported"},
		{"func Needs", "not exported"},
		{"func Use", "already declares Use"},
		{"B\n", "group"},
		{"func (T) M", "methods move with it"},
	}
	for _, c := range cases {
		resp := Move(context.Background(), Request{
			Path: filepath.Join(dir, "util/util.go"), Offset: offsetOf(t, dir, "util/util.go", c.needle),
			Dest: filepath.Join(dir, "text/text.go"), WorkspaceDir: dir,
		})
		if !strings.Contains(resp.Error, c.want) {
			t.Errorf("%q: got %q, want a reason containing %q", c.needle, resp.Error, c.want)
		}
		if len(resp.EditsByPath) != 0 {
			t.Errorf("%q: a refused move returned edits", c.needle)
		}
	}
}
