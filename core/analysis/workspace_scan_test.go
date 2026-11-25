package analysis

import (
	"fmt"
	"go/parser"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeScanFile(t *testing.T, root, rel, body string) string {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCollectWorkspaceGoTargets_FiltersAndOrders(t *testing.T) {
	root := t.TempDir()
	writeScanFile(t, root, "b/b.go", "package b\n")
	writeScanFile(t, root, "a/a.go", "package a\n")
	writeScanFile(t, root, "a/a_test.go", "package a\n")
	writeScanFile(t, root, "vendor/v/v.go", "package v\n")
	writeScanFile(t, root, ".hidden/h.go", "package h\n")
	writeScanFile(t, root, "a/.dot.go", "package a\n")
	writeScanFile(t, root, "a/notes.txt", "x")
	writeScanFile(t, root, "big/big.go", "package big\n"+strings.Repeat("// pad\n", (workspaceScanMaxFileBytes/7)+10))
	active := writeScanFile(t, root, "c/c.go", "package c\n")

	names := func(targets []goSourceTarget) []string {
		out := make([]string, 0, len(targets))
		for _, tg := range targets {
			rel, _ := filepath.Rel(root, tg.path)
			out = append(out, filepath.ToSlash(rel))
		}
		return out
	}

	got := collectWorkspaceGoTargets(root, active, "package c\n\nvar X = 1\n", false)
	if want := []string{"a/a.go", "b/b.go", "c/c.go"}; !reflect.DeepEqual(names(got), want) {
		t.Fatalf("got %v want %v", names(got), want)
	}
	for _, tg := range got {
		if strings.HasSuffix(tg.path, "c.go") && (!tg.loaded || !strings.Contains(string(tg.content), "var X")) {
			t.Fatalf("active file should use editor content, got %+v", tg)
		}
		if !strings.HasSuffix(tg.path, "c.go") && tg.loaded {
			t.Fatalf("workspace files should be read lazily: %s", tg.path)
		}
	}

	withTests := collectWorkspaceGoTargets(root, "", "", true)
	if want := []string{"a/a.go", "a/a_test.go", "b/b.go", "c/c.go"}; !reflect.DeepEqual(names(withTests), want) {
		t.Fatalf("got %v want %v", names(withTests), want)
	}

	unsaved := filepath.Join(root, "d/new.go")
	withUnsaved := collectWorkspaceGoTargets(root, unsaved, "package d\n", false)
	if want := []string{"a/a.go", "b/b.go", "c/c.go", "d/new.go"}; !reflect.DeepEqual(names(withUnsaved), want) {
		t.Fatalf("got %v want %v", names(withUnsaved), want)
	}
}

func TestCollectWorkspaceGoTargets_CapsFileCount(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < workspaceScanMaxFiles+20; i++ {
		writeScanFile(t, root, fmt.Sprintf("p/f%04d.go", i), "package p\n")
	}
	if got := len(collectWorkspaceGoTargets(root, "", "", false)); got != workspaceScanMaxFiles {
		t.Fatalf("expected %d targets, got %d", workspaceScanMaxFiles, got)
	}
}

func TestAnalyseGoSourceTargets_PreservesOrderAndSkipsUnreadable(t *testing.T) {
	root := t.TempDir()
	var targets []goSourceTarget
	for i := 0; i < 64; i++ {
		body := fmt.Sprintf("package p\n\nfunc F%d() {}\n", i)
		if i == 10 || i == 20 {
			body = "not a go file\n"
		}
		path := writeScanFile(t, root, fmt.Sprintf("f%02d.go", i), body)
		targets = append(targets, goSourceTarget{path: path})
	}
	targets = append(targets, goSourceTarget{path: filepath.Join(root, "missing.go")})

	names, err := analyseGoSourceTargets(targets, parser.SkipObjectResolution, func(src parsedGoSource) string {
		return filepath.Base(src.path)
	})
	if err != nil {
		t.Fatalf("unexpected parse error: %v", err)
	}
	var want []string
	for i := 0; i < 64; i++ {
		want = append(want, fmt.Sprintf("f%02d.go", i))
	}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("results out of order:\n got %v\nwant %v", names, want)
	}
}
