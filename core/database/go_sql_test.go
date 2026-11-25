package database

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSiteParamsPerAPI(t *testing.T) {
	cases := []struct {
		sql, hint string
		want      []string
	}{
		{"SELECT * FROM users WHERE id = $1 AND org = $2", "postgres", []string{"$1", "$2"}},
		{"SELECT * FROM users WHERE id = $1", "", []string{"$1"}},
		{"SELECT * FROM users WHERE id = ? AND name = ?", "", []string{"?1", "?2"}},
		{"SELECT * FROM users WHERE id = ?", "mysql", []string{"?1"}},
		{"INSERT INTO users (name) VALUES (:name)", "", []string{":name"}},
		{"SELECT * FROM users WHERE name = :name AND created::date = now()::date", "postgres", []string{":name"}},
		{"SELECT 1", "", []string{}},
	}
	for _, c := range cases {
		if got := SiteParams(c.sql, c.hint); !reflect.DeepEqual(got, c.want) {
			t.Errorf("SiteParams(%q, %q) = %v, want %v", c.sql, c.hint, got, c.want)
		}
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSqlcQueryBindsMacros(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "sqlc.yaml"), "version: \"2\"\nsql:\n  - engine: \"postgresql\"\n    schema: \"schema.sql\"\n    queries: \"queries\"\n")
	path := filepath.Join(dir, "queries", "users.sql")
	content := "-- name: GetUser :one\nSELECT * FROM users\nWHERE id = sqlc.arg(id) AND org = @org AND deleted = sqlc.narg('deleted');\n\n-- name: ListByIDs :many\nSELECT * FROM users WHERE id = ANY($1::int[]);\n"
	writeFile(t, path, content)
	res := SqlcQuery(path, content, 1)
	if res.Error != nil || res.Name != "GetUser" || res.Engine != EnginePostgres || res.ConfigDir != dir {
		t.Fatalf("result = %+v", res)
	}
	var names []string
	for _, p := range res.Parameters {
		names = append(names, p.Name)
	}
	if !reflect.DeepEqual(names, []string{"@id", "@org", "@deleted"}) {
		t.Fatalf("parameters = %v", names)
	}
	if !res.Parameters[2].Nullable {
		t.Fatal("sqlc.narg is nullable")
	}
	if content[res.StartByte:res.EndByte] != res.SQL {
		t.Fatal("the byte range does not match the query text")
	}
	b := bindParams(content[res.StartByte:res.EndByte], EnginePostgres, []ParamValue{{Name: "@id", Value: "1"}, {Name: "@org", Value: "2"}, {Name: "@deleted", IsNull: true}})
	if len(b.missing) != 0 || b.sql != "SELECT * FROM users\nWHERE id = $1 AND org = $2 AND deleted = $3;" || len(b.args) != 3 {
		t.Fatalf("bound = %q missing %v args %v", b.sql, b.missing, b.args)
	}
	if res = SqlcQuery(path, content, 6); res.Name != "ListByIDs" || len(res.Parameters) != 1 || res.Parameters[0].Name != "$1" {
		t.Fatalf("second query = %+v", res)
	}
	if res = SqlcQuery(path, "SELECT 1;\n", 1); res.Error == nil {
		t.Fatal("a line without a sqlc query is an error")
	}
}

func TestSqlcQueryEngineFromMatchingBlock(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "sqlc.yaml"), "version: \"2\"\nsql:\n  - engine: \"postgresql\"\n    queries: \"pg/queries.sql\"\n  - engine: mysql\n    queries:\n      - \"my/a.sql\"\n      - my/b\n")
	content := "-- name: Pick :many\nSELECT * FROM t WHERE id IN (sqlc.slice(ids)) AND a = sqlc.arg(a);\n"
	res := SqlcQuery(filepath.Join(dir, "my", "b", "q.sql"), content, 1)
	if res.Engine != EngineMySQL {
		t.Fatalf("engine = %q", res.Engine)
	}
	if len(res.Parameters) != 2 || res.Parameters[0].Name != "@ids" || res.Parameters[1].Name != "@a" {
		t.Fatalf("parameters = %+v", res.Parameters)
	}
	if res = SqlcQuery(filepath.Join(dir, "pg", "queries.sql"), content, 1); res.Engine != EnginePostgres {
		t.Fatalf("engine = %q", res.Engine)
	}
	if res = SqlcQuery(filepath.Join(dir, "other.sql"), content, 1); res.Engine != "" {
		t.Fatalf("two engines and no matching block must leave the engine open, got %q", res.Engine)
	}
}

func TestSqlcQueryEngineFromJSONConfig(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "sqlc.json"), `{"version":"2","sql":[{"engine":"sqlite","queries":["q"]}]}`)
	if res := SqlcQuery(filepath.Join(dir, "q", "a.sql"), "-- name: A :exec\nDELETE FROM t WHERE id = ?;\n", 1); res.Engine != EngineSQLite || len(res.Parameters) != 1 {
		t.Fatalf("result = %+v", res)
	}
}
