package sqlc

import "testing"

func TestQueryAt(t *testing.T) {
	content := "-- name: GetUser :one\nSELECT id, name FROM users\nWHERE id = sqlc.arg(id);\n\n-- name: ListUsers :many\nSELECT * FROM users;\n\n\n"
	q, ok := QueryAt(content, 1)
	if !ok || q.Name != "GetUser" || q.Cmd != ":one" || q.SQL != "SELECT id, name FROM users\nWHERE id = sqlc.arg(id);" {
		t.Fatalf("first query = %+v", q)
	}
	if content[q.StartByte:q.EndByte] != q.SQL {
		t.Fatalf("byte range does not match the text: %q", content[q.StartByte:q.EndByte])
	}
	q, ok = QueryAt(content, 5)
	if !ok || q.Name != "ListUsers" || q.SQL != "SELECT * FROM users;" || q.Line != 5 {
		t.Fatalf("second query = %+v", q)
	}
	if q, ok = QueryAt(content, 3); !ok || q.Name != "GetUser" {
		t.Fatalf("a body line belongs to its query, got %+v", q)
	}
	if _, ok = QueryAt("SELECT 1;\n", 1); ok {
		t.Fatal("a file without name comments has no query")
	}
	if q, ok = QueryAt("-- name: Empty :exec\n", 1); !ok || q.SQL != "" {
		t.Fatalf("an empty query = %+v", q)
	}
}
