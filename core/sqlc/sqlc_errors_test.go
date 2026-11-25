package sqlc

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNewSourceMalformedAndNullOverlays(t *testing.T) {
	for _, raw := range []string{"", "{bad json", "null", "[]"} {
		s := newSource(raw)
		if _, err := s.read(filepath.Join(t.TempDir(), "missing.sql")); err == nil {
			t.Fatalf("expected read error for missing file with overlay %q", raw)
		}
	}
}

func TestHeadEdgeCases(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing.go")
	if got := (source{}).head(missing); got != nil {
		t.Fatalf("missing file head = %q, want nil", got)
	}

	empty := filepath.Join(dir, "empty.go")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := (source{}).head(empty); len(got) != 0 {
		t.Fatalf("empty file head = %q, want empty", got)
	}

	short := filepath.Join(dir, "short.go")
	if err := os.WriteFile(short, []byte(generatedMarker+"\npackage db\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	src, ok := generatedSource((source{}).head(short))
	if !ok || src != "" {
		t.Fatalf("generatedSource without source comment = %q, %v; want \"\", true", src, ok)
	}

	longOverlay := generatedMarker + "\n" + strings.Repeat("x", 700)
	s := source{overlays: map[string]string{missing: longOverlay}}
	if got := s.head(missing); len(got) != 512 {
		t.Fatalf("overlay head len = %d, want 512", len(got))
	}
}

func TestWalkSkipsSpecialAndUnreadableDirs(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{".git", "node_modules", "vendor", ".build"} {
		p := filepath.Join(root, dir, "ignored.sql")
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("-- name: Ignored :one\nSELECT 1;\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	kept := filepath.Join(root, "queries", "ok.sql")
	if err := os.MkdirAll(filepath.Dir(kept), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kept, []byte("-- name: Kept :one\nSELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	unreadableDir := filepath.Join(root, "locked")
	if err := os.MkdirAll(unreadableDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(unreadableDir, "secret.sql"), []byte("-- name: Secret :one\nSELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() != 0 {
		if err := os.Chmod(unreadableDir, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(unreadableDir, 0o755) })
	}

	sqlFiles, gens := (source{}).walk(root)
	if len(sqlFiles) != 1 && os.Geteuid() != 0 {
		t.Fatalf("sqlFiles = %v, want only %s", sqlFiles, kept)
	}
	if len(gens) != 0 {
		t.Fatalf("gens = %v, want empty", gens)
	}

	missingSQL, missingGens := (source{}).walk(filepath.Join(root, "nope"))
	if len(missingSQL) != 0 || len(missingGens) != 0 {
		t.Fatalf("missing root walk = %v, %v", missingSQL, missingGens)
	}
}

func TestUTF16ColAndDeclsMalformed(t *testing.T) {
	if got := utf16Col("abc", 99); got != 4 {
		t.Fatalf("utf16Col clamped = %d, want 4", got)
	}
	if got := utf16Col("\U0001F600x", 4); got != 3 {
		t.Fatalf("utf16Col surrogate pair = %d, want 3", got)
	}

	if got := decls([]byte("package db\nfunc ( {\n")); got != nil {
		t.Fatalf("corrupt go syntax should return nil, got %+v", got)
	}

	src := `package db
type Other struct{}
func (q Queries) ValueRecv() {}
func (o *Other) WrongType() {}
func FreeFunc() {}
type Querier struct{}
`
	if got := decls([]byte(src)); len(got) != 0 {
		t.Fatalf("non-Queries / non-interface Querier should yield 0 decls, got %+v", got)
	}

	ifaceSrc := `package db
type Base interface{ Ping() }
type Querier interface {
	Base
	GetUser() error
}
`
	got := decls([]byte(ifaceSrc))
	if len(got) != 1 || got[0].name != "GetUser" || !got[0].iface {
		t.Fatalf("interface decls = %+v", got)
	}
}

func TestQueryForGoErrorAndFallbackBranches(t *testing.T) {
	root := t.TempDir()
	sibling := root + "2"
	if err := os.MkdirAll(sibling, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(sibling) })

	sibGen := filepath.Join(sibling, "a.sql.go")
	if err := os.WriteFile(sibGen, []byte(generatedMarker+"\npackage db\nfunc (q *Queries) GetUser() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := QueryForGo(sibGen, 3, root, ""); got.Name != "" || len(got.Locations) != 0 {
		t.Fatalf("sibling prefix path must be rejected: %+v", got)
	}

	gen := filepath.Join(root, "db", "users.sql.go")
	if err := os.MkdirAll(filepath.Dir(gen), 0o755); err != nil {
		t.Fatal(err)
	}
	genBody := generatedMarker + "\n// source: deleted.sql\npackage db\ntype Queries struct{}\nfunc (q *Queries) FindUser() {}\nfunc (q *Queries) Unmatched() {}\n"
	if err := os.WriteFile(gen, []byte(genBody), 0o644); err != nil {
		t.Fatal(err)
	}
	sqlPath := filepath.Join(root, "sql", "alt.sql")
	if err := os.MkdirAll(filepath.Dir(sqlPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sqlPath, []byte("-- name: FindUser :one\nSELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := QueryForGo(gen, 1, root, ""); got.Name != "" || len(got.Locations) != 0 {
		t.Fatalf("non-decl line should return empty: %+v", got)
	}
	if got := QueryForGo(gen, 6, root, ""); got.Name != "Unmatched" || len(got.Locations) != 0 {
		t.Fatalf("unmatched query = %+v", got)
	}
	got := QueryForGo(gen, 5, root, "")
	if got.Name != "FindUser" || len(got.Locations) != 1 || got.Locations[0].Path != sqlPath {
		t.Fatalf("fallback when source comment mismatches = %+v", got)
	}

	if os.Geteuid() != 0 {
		lockedSQL := filepath.Join(root, "sql", "locked.sql")
		if err := os.WriteFile(lockedSQL, []byte("-- name: FindUser :one\nSELECT 2;\n"), 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(lockedSQL, 0o644) })
		got = QueryForGo(gen, 5, root, "")
		if len(got.Locations) != 1 || got.Locations[0].Path != sqlPath {
			t.Fatalf("unreadable sql should be skipped cleanly: %+v", got)
		}
	}

	corruptGen := filepath.Join(root, "db", "corrupt.sql.go")
	if err := os.WriteFile(corruptGen, []byte(generatedMarker+"\npackage db\nfunc (\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := QueryForGo(corruptGen, 3, root, ""); got.Name != "" || len(got.Locations) != 0 {
		t.Fatalf("corrupt generated Go should return empty: %+v", got)
	}
}

func TestQueriesInFileEmptyMismatchedSourceAndJSON(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "sqlc.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	sqlPath := filepath.Join(root, "queries", "users.sql")
	if err := os.MkdirAll(filepath.Dir(sqlPath), 0o755); err != nil {
		t.Fatal(err)
	}

	res := QueriesInFile(sqlPath, "-- just a comment\nSELECT 1;\n", root, "{bad")
	if res.ConfigDir != root || len(res.Queries) != 0 || len(res.GeneratedFiles) != 0 {
		t.Fatalf("empty queries result = %+v", res)
	}

	otherGen := filepath.Join(root, "db", "orders.sql.go")
	if err := os.MkdirAll(filepath.Dir(otherGen), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(otherGen, []byte(generatedMarker+"\n// source: orders.sql\npackage db\nfunc (q *Queries) GetUser() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	corruptGen := filepath.Join(root, "db", "bad.sql.go")
	if err := os.WriteFile(corruptGen, []byte(generatedMarker+"\npackage db\nfunc (\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	content := "-- name: GetUser :one\nSELECT 1;\n"
	res = QueriesInFile(sqlPath, content, root, "")
	if len(res.Queries) != 1 || res.Queries[0].Go != nil {
		t.Fatalf("mismatched .sql source should not match GetUser: %+v", res)
	}

	rawFile := QueriesInFileJSON(sqlPath, content, root, "")
	var decodedFile FileResult
	if err := json.Unmarshal([]byte(rawFile), &decodedFile); err != nil || decodedFile.ConfigDir != root {
		t.Fatalf("QueriesInFileJSON = %q err=%v", rawFile, err)
	}

	rawGo := QueryForGoJSON(filepath.Join(root, "missing.go"), 1, root, "")
	var decodedGo GoResult
	if err := json.Unmarshal([]byte(rawGo), &decodedGo); err != nil || decodedGo.Locations == nil {
		t.Fatalf("QueryForGoJSON = %q err=%v", rawGo, err)
	}
}

func TestSQLCLineDirectiveAndSymlinkOverlay(t *testing.T) {
	srcWithLineDirective := generatedMarker + "\npackage db\n//line virtual.go:9999\nfunc (q *Queries) GetUser() {}\n"
	ds := decls([]byte(srcWithLineDirective))
	if len(ds) != 1 || ds[0].name != "GetUser" || ds[0].line != 4 {
		t.Fatalf("decls with //line = %+v", ds)
	}

	base := t.TempDir()
	realRoot := filepath.Join(base, "real")
	linkRoot := filepath.Join(base, "link")
	sqlPath := filepath.Join(realRoot, "sql", "queries", "users.sql")
	if err := os.MkdirAll(filepath.Dir(sqlPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sqlPath, []byte("-- name: GetUser :one\nSELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realRoot, linkRoot); err != nil {
		t.Fatal(err)
	}
	unsavedGen := filepath.Join(linkRoot, "db", "users.sql.go")
	overlays, _ := json.Marshal(map[string]string{
		unsavedGen: generatedMarker + "\n// source: users.sql\npackage db\nfunc (q *Queries) GetUser() {}\n",
	})
	got := QueryForGo(unsavedGen, 4, linkRoot, string(overlays))
	if got.Name != "GetUser" || len(got.Locations) != 1 {
		t.Fatalf("QueryForGo unsaved overlay under symlinked root = %+v", got)
	}

	parent := t.TempDir()
	proj := filepath.Join(parent, "proj")
	siblingSub := filepath.Join(parent, "proj2", "sub")
	outside := filepath.Join(parent, "other")
	for _, d := range []string{proj, siblingSub, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(parent, "sqlc.yaml"), []byte("version: \"2\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parent, "proj2", "sqlc.yaml"), []byte("version: \"2\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "sqlc.yaml"), []byte("version: \"2\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if dir := configDir(filepath.Join(siblingSub, "q.sql"), proj); dir != "" {
		t.Fatalf("configDir escaped proj via sibling prefix: %q", dir)
	}
	if dir := configDir(filepath.Join(outside, "q.sql"), proj); dir != "" {
		t.Fatalf("configDir read outside root: %q", dir)
	}
}
