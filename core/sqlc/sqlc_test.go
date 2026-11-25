package sqlc

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, engine string) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("testdata", engine))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func lineOf(t *testing.T, path, needle string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for i, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, needle) {
			return i + 1
		}
	}
	t.Fatalf("%q not in %s", needle, path)
	return 0
}

func TestQueryForGo(t *testing.T) {
	root := fixture(t, "postgresql")
	users := filepath.Join(root, "sql/queries/users.sql")
	cases := []struct {
		file, decl, name string
		line             int
	}{
		{"db/users.sql.go", "func (q *Queries) GetUser(", "GetUser", 1},
		{"db/users.sql.go", "func (q *Queries) DeleteUser(", "DeleteUser", 8},
		{"db/querier.go", "\tGetUser(ctx", "GetUser", 1},
		{"db/batch.go", "func (q *Queries) RenameUsers(", "RenameUsers", 11},
		{"db/copyfrom.go", "func (q *Queries) CopyUsers(", "CopyUsers", 14},
	}
	for _, c := range cases {
		gen := filepath.Join(root, c.file)
		got := QueryForGo(gen, lineOf(t, gen, c.decl), root, "")
		want := Location{Path: users, Line: c.line, Col: 10}
		if got.Name != c.name || len(got.Locations) != 1 || got.Locations[0] != want {
			t.Errorf("%s %s: got %+v, want %s at %+v", c.file, c.decl, got, c.name, want)
		}
	}
}

func TestQueryForGoIgnoresNonQueries(t *testing.T) {
	root := fixture(t, "postgresql")
	cases := map[string]string{
		"db/db.go":     "func (q *Queries) WithTx(",
		"db/models.go": "type User struct",
	}
	for file, decl := range cases {
		gen := filepath.Join(root, file)
		if got := QueryForGo(gen, lineOf(t, gen, decl), root, ""); len(got.Locations) != 0 {
			t.Errorf("%s: expected no locations, got %+v", decl, got)
		}
	}
	self, _ := filepath.Abs("sqlc.go")
	if got := QueryForGo(self, 1, root, ""); got.Name != "" || len(got.Locations) != 0 {
		t.Errorf("non-sqlc file: got %+v", got)
	}
}

func TestQueriesInFileAllEngines(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql", "sqlite"} {
		root := fixture(t, engine)
		sqlPath := filepath.Join(root, "sql/queries/users.sql")
		text, _ := os.ReadFile(sqlPath)
		res := QueriesInFile(sqlPath, string(text), root, "")
		if res.ConfigDir != root {
			t.Errorf("%s: configDir %q", engine, res.ConfigDir)
		}
		if len(res.Queries) < 3 {
			t.Fatalf("%s: queries %+v", engine, res.Queries)
		}
		for _, q := range res.Queries {
			if q.Go == nil {
				t.Errorf("%s: %s has no Go method", engine, q.Name)
				continue
			}
			gotLine := lineOf(t, q.Go.Path, "func (q *Queries) "+q.Name+"(")
			if q.Go.Line != gotLine || q.Go.Col != 19 {
				t.Errorf("%s: %s -> %+v, want line %d col 19", engine, q.Name, q.Go, gotLine)
			}
		}
		if q := res.Queries[0]; q.Name != "GetUser" || q.Cmd != ":one" || q.Line != 1 || q.NameCol != 10 || q.EndLine != 4 {
			t.Errorf("%s: first query %+v", engine, q)
		}
		for _, g := range res.GeneratedFiles {
			if filepath.Dir(g) != filepath.Join(root, "db") {
				t.Errorf("%s: generated file outside out dir: %s", engine, g)
			}
		}
		if len(res.GeneratedFiles) < 4 {
			t.Errorf("%s: generatedFiles %v", engine, res.GeneratedFiles)
		}
	}
}

func TestQueriesInFileOverlayAndMissing(t *testing.T) {
	root := fixture(t, "postgresql")
	sqlPath := filepath.Join(root, "sql/queries/users.sql")
	text := "\n\n-- name: GetUser :one\nSELECT 1;\n\n/* name: NotYetGenerated :many */\nSELECT 2;\n"
	res := QueriesInFile(sqlPath, text, root, "")
	if len(res.Queries) != 2 || res.Queries[0].Line != 3 || res.Queries[0].Go == nil {
		t.Fatalf("unsaved text not used: %+v", res.Queries)
	}
	if res.Queries[1].Name != "NotYetGenerated" || res.Queries[1].Go != nil {
		t.Errorf("missing method should be null: %+v", res.Queries[1])
	}

	gen := filepath.Join(root, "db/users.sql.go")
	overlay, _ := json.Marshal(map[string]string{sqlPath: "-- moved down\n\n-- name: GetUser :one\nSELECT 1;\n"})
	got := QueryForGo(gen, lineOf(t, gen, "func (q *Queries) GetUser("), root, string(overlay))
	if len(got.Locations) != 1 || got.Locations[0].Line != 3 {
		t.Errorf("overlay ignored: %+v", got)
	}
}

func TestDuplicateNamesPreferNearestPackage(t *testing.T) {
	root, _ := filepath.Abs("testdata")
	for _, engine := range []string{"postgresql", "mysql", "sqlite"} {
		gen := filepath.Join(root, engine, "db/users.sql.go")
		got := QueryForGo(gen, lineOf(t, gen, "func (q *Queries) GetUser("), root, "")
		if len(got.Locations) != 1 || got.Locations[0].Path != filepath.Join(root, engine, "sql/queries/users.sql") {
			t.Errorf("%s Go->SQL: %+v", engine, got.Locations)
		}
		sqlPath := filepath.Join(root, engine, "sql/queries/users.sql")
		text, _ := os.ReadFile(sqlPath)
		for _, q := range QueriesInFile(sqlPath, string(text), root, "").Queries {
			if q.Go == nil || filepath.Dir(q.Go.Path) != filepath.Join(root, engine, "db") {
				t.Errorf("%s SQL->Go %s: %+v", engine, q.Name, q.Go)
			}
		}
	}
	tie := nearest("/w/a/x.go", []Location{{Path: "/w/b/q.sql"}, {Path: "/w/c/q.sql"}})
	if len(tie) != 2 {
		t.Errorf("equal distance must keep both for the picker, got %+v", tie)
	}
}

func TestConfigDirFromNestedFolder(t *testing.T) {
	root := fixture(t, "sqlite")
	if got := configDir(filepath.Join(root, "sql/queries/users.sql"), filepath.Dir(root)); got != root {
		t.Errorf("configDir = %q", got)
	}
	if got := configDir(filepath.Join(root, "sql/queries/users.sql"), filepath.Join(root, "sql")); got != "" {
		t.Errorf("configDir must stop at root, got %q", got)
	}
}

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	b, err := os.ReadFile(from)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(to, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func twoServices(t *testing.T) string {
	t.Helper()
	src := fixture(t, "sqlite")
	root := t.TempDir()
	gens, _ := filepath.Glob(filepath.Join(src, "db", "*.go"))
	for _, svc := range []string{"a", "b"} {
		copyFile(t, filepath.Join(src, "sql/queries/users.sql"), filepath.Join(root, "sql", svc, "users.sql"))
		for _, g := range gens {
			copyFile(t, g, filepath.Join(root, "gen", svc, filepath.Base(g)))
		}
	}
	return root
}

func TestSiblingServicesMatchByFolderName(t *testing.T) {
	root := twoServices(t)
	real := root
	for _, svc := range []string{"a", "b"} {
		sqlPath := filepath.Join(root, "sql", svc, "users.sql")
		text, _ := os.ReadFile(sqlPath)
		for _, q := range QueriesInFile(sqlPath, string(text), root, "").Queries {
			if q.Go == nil || filepath.Dir(q.Go.Path) != filepath.Join(real, "gen", svc) {
				t.Errorf("sql/%s %s -> %+v", svc, q.Name, q.Go)
			}
		}
		gen := filepath.Join(root, "gen", svc, "users.sql.go")
		got := QueryForGo(gen, lineOf(t, gen, "func (q *Queries) GetUser("), root, "")
		if len(got.Locations) != 1 || got.Locations[0].Path != filepath.Join(real, "sql", svc, "users.sql") {
			t.Errorf("gen/%s Go->SQL: %+v", svc, got.Locations)
		}
	}
}

func TestQueryForGoIgnoresGeneratedCodeOutsideWorkspace(t *testing.T) {
	gen := filepath.Join(fixture(t, "postgresql"), "db/users.sql.go")
	got := QueryForGo(gen, lineOf(t, gen, "func (q *Queries) GetUser("), fixture(t, "mysql"), "")
	if len(got.Locations) != 0 {
		t.Errorf("a dependency's generated method must not match workspace queries: %+v", got.Locations)
	}
}

func TestSymlinkedRootKeepsCallerSpelling(t *testing.T) {
	root := twoServices(t)
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(root, link); err != nil {
		t.Skip(err)
	}
	real, _ := filepath.EvalSymlinks(root)
	sqlPath := filepath.Join(link, "sql", "a", "users.sql")
	overlay, _ := json.Marshal(map[string]string{sqlPath: "\n\n-- name: GetUser :one\nSELECT 1;\n"})
	gen := filepath.Join(real, "gen", "a", "users.sql.go")
	got := QueryForGo(gen, lineOf(t, gen, "func (q *Queries) GetUser("), link, string(overlay))
	if len(got.Locations) != 1 || got.Locations[0].Path != sqlPath || got.Locations[0].Line != 3 {
		t.Errorf("generated file reached through the real path must still resolve, in the root's spelling: %+v", got.Locations)
	}
	text, _ := os.ReadFile(sqlPath)
	q := QueriesInFile(sqlPath, string(text), link, "").Queries[0]
	if q.Go == nil || q.Go.Path != filepath.Join(link, "gen", "a", "users.sql.go") {
		t.Errorf("SQL->Go must report paths under the root as given: %+v", q.Go)
	}
}
