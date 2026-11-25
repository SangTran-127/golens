package goast

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func siteSQL(sites []SQLSite) []string {
	out := make([]string, 0, len(sites))
	for _, s := range sites {
		out = append(out, strings.TrimSpace(s.SQL))
	}
	return out
}

func requireSites(t *testing.T, sites []SQLSite, want map[string]string) {
	t.Helper()
	got := map[string]string{}
	for _, s := range sites {
		got[strings.TrimSpace(s.SQL)] = s.API
	}
	if len(got) != len(want) {
		t.Fatalf("got %d sites %v, want %d %v", len(got), siteSQL(sites), len(want), want)
	}
	for sql, api := range want {
		if got[sql] != api {
			t.Errorf("site %q: api %q, want %q (all: %v)", sql, got[sql], api, got)
		}
	}
}

func TestSQLSitesDatabaseSQL(t *testing.T) {
	src := "package store\n\nimport (\n\t\"context\"\n\t\"database/sql\"\n)\n\n" +
		"type Store struct{ db *sql.DB }\n\n" +
		"type Embedded struct{ *sql.DB }\n\n" +
		"func (s *Store) Run(ctx context.Context, tx *sql.Tx, c *sql.Conn, e Embedded) {\n" +
		"\ts.db.Query(\"SELECT 1\")\n" +
		"\ts.db.QueryRowContext(ctx, `SELECT name FROM users WHERE id = $1`, 1)\n" +
		"\ttx.Exec(\"UPDATE users SET name = $1 \" +\n\t\t\"WHERE id = $2\", \"a\", 1)\n" +
		"\ttx.PrepareContext(ctx, \"SELECT 2\")\n" +
		"\tc.ExecContext(ctx, \"DELETE FROM sessions\")\n" +
		"\te.Query(\"SELECT 3\")\n" +
		"\tdb, _ := sql.Open(\"pgx\", \"\")\n" +
		"\tdb.Exec(\"SELECT 4\")\n" +
		"}\n"
	sites := ScanSQLSites("/nowhere/store.go", src, "")
	requireSites(t, sites, map[string]string{
		"SELECT 1":                                 SQLAPIDatabaseSQL,
		"SELECT name FROM users WHERE id = $1":     SQLAPIDatabaseSQL,
		"UPDATE users SET name = $1 WHERE id = $2": SQLAPIDatabaseSQL,
		"SELECT 2":             SQLAPIDatabaseSQL,
		"DELETE FROM sessions": SQLAPIDatabaseSQL,
		"SELECT 3":             SQLAPIDatabaseSQL,
		"SELECT 4":             SQLAPIDatabaseSQL,
	})
	for _, s := range sites {
		if !strings.HasPrefix(s.SQL, "UPDATE") {
			continue
		}
		if len(s.Parts) != 2 {
			t.Fatalf("concatenation parts = %d, want 2", len(s.Parts))
		}
		if got := src[s.Parts[0].StartByte:s.Parts[0].EndByte]; got != "UPDATE users SET name = $1 " {
			t.Fatalf("first part %q", got)
		}
		if got := src[s.StartByte:s.EndByte]; !strings.HasPrefix(got, "\"UPDATE") || !strings.HasSuffix(got, "$2\"") {
			t.Fatalf("site range %q", got)
		}
		if s.Line != 15 {
			t.Fatalf("line = %d, want 15", s.Line)
		}
	}
}

func TestSQLSitesPgx(t *testing.T) {
	src := `package store

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func run(ctx context.Context, conn *pgx.Conn, pool *pgxpool.Pool) error {
	conn.QueryRow(ctx, "SELECT id FROM users WHERE email = $1", "a")
	pool.Exec(ctx, "UPDATE users SET seen = now()")
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	tx.Query(ctx, "SELECT * FROM orders")
	b := &pgx.Batch{}
	b.Queue("INSERT INTO audit(msg) VALUES ($1)", "x")
	c, _ := pool.Acquire(ctx)
	c.Query(ctx, "SELECT 5")
	return nil
}
`
	sites := ScanSQLSites("/nowhere/pg.go", src, "")
	requireSites(t, sites, map[string]string{
		"SELECT id FROM users WHERE email = $1": SQLAPIPgx,
		"UPDATE users SET seen = now()":         SQLAPIPgx,
		"SELECT * FROM orders":                  SQLAPIPgx,
		"INSERT INTO audit(msg) VALUES ($1)":    SQLAPIPgx,
		"SELECT 5":                              SQLAPIPgx,
	})
	for _, s := range sites {
		if s.DialectHint != "postgres" {
			t.Fatalf("pgx site %q dialect %q", s.SQL, s.DialectHint)
		}
	}
}

func TestSQLSitesSqlx(t *testing.T) {
	src := `package store

import (
	"context"

	"github.com/jmoiron/sqlx"
)

type User struct{}

func run(ctx context.Context, db *sqlx.DB) {
	var u User
	var us []User
	db.Get(&u, "SELECT * FROM users WHERE id = ?", 1)
	db.Select(&us, "SELECT * FROM users")
	db.NamedExec("INSERT INTO users (name) VALUES (:name)", u)
	db.NamedQuery("SELECT * FROM users WHERE name = :name", u)
	db.Queryx("SELECT 6")
	db.QueryRowx("SELECT 7")
	db.SelectContext(ctx, &us, "SELECT 8")
	db.Exec("SELECT 9")
	tx := db.MustBegin()
	tx.NamedExec("DELETE FROM users WHERE id = :id", u)
	sqlx.Get(db, &u, "SELECT 10")
}
`
	sites := ScanSQLSites("/nowhere/x.go", src, "")
	requireSites(t, sites, map[string]string{
		"SELECT * FROM users WHERE id = ?":        SQLAPISqlx,
		"SELECT * FROM users":                     SQLAPISqlx,
		"INSERT INTO users (name) VALUES (:name)": SQLAPISqlx,
		"SELECT * FROM users WHERE name = :name":  SQLAPISqlx,
		"SELECT 6":                                SQLAPISqlx,
		"SELECT 7":                                SQLAPISqlx,
		"SELECT 8":                                SQLAPISqlx,
		"SELECT 9":                                SQLAPIDatabaseSQL,
		"DELETE FROM users WHERE id = :id":        SQLAPISqlx,
		"SELECT 10":                               SQLAPISqlx,
	})
}

func TestSQLSitesLanguageMarker(t *testing.T) {
	src := "package store\n\n" +
		"// language=SQL\n" +
		"const listUsers = `SELECT id, name FROM users`\n\n" +
		"var other = \"SELECT not marked\"\n\n" +
		"func q() string {\n" +
		"\t/* language=PostgreSQL */ return \"SELECT now()\"\n" +
		"}\n\n" +
		"// language=MySQL\n\n" +
		"var tooFar = \"SELECT far\"\n\n" +
		"// language=JSON\n" +
		"var notSQL = `{}`\n"
	sites := ScanSQLSites("/nowhere/m.go", src, "")
	requireSites(t, sites, map[string]string{
		"SELECT id, name FROM users": SQLAPIMarker,
		"SELECT now()":               SQLAPIMarker,
	})
	for _, s := range sites {
		if s.SQL == "SELECT now()" && s.DialectHint != "postgres" {
			t.Fatalf("PostgreSQL marker dialect = %q", s.DialectHint)
		}
	}
}

func TestSQLSitesMarkerOverridesDialect(t *testing.T) {
	src := `package store

import "database/sql"

func run(db *sql.DB) {
	db.Exec(
		// language=MySQL
		"UPDATE t SET a = ?", 1)
}
`
	sites := ScanSQLSites("/nowhere/d.go", src, "")
	if len(sites) != 1 || sites[0].API != SQLAPIDatabaseSQL || sites[0].DialectHint != "mysql" {
		t.Fatalf("sites = %+v", sites)
	}
}

func TestSQLSitesSqlcInterface(t *testing.T) {
	src := `package db

import (
	"context"
	"database/sql"
)

type DBTX interface {
	ExecContext(context.Context, string, ...interface{}) (sql.Result, error)
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

type Queries struct{ db DBTX }

func (q *Queries) Count(ctx context.Context) {
	q.db.QueryRowContext(ctx, "SELECT count(*) FROM authors")
}
`
	requireSites(t, ScanSQLSites("/nowhere/q.go", src, ""), map[string]string{
		"SELECT count(*) FROM authors": SQLAPIDatabaseSQL,
	})
}

func TestSQLSitesNegatives(t *testing.T) {
	src := `package store

import (
	"database/sql"
	"fmt"
	"strings"
)

type Index struct{}

func (Index) Query(q string) []string { return nil }
func (Index) Exec(q string) error     { return nil }

type Builder struct{}

func (*Builder) Select(cols ...string) *Builder { return nil }

func run(db *sql.DB, idx Index, b *Builder, table string, q string) {
	idx.Query("SELECT looks like sql")
	idx.Exec("DELETE everything")
	b.Select("id", "name")
	db.Query(q)
	db.Query(fmt.Sprintf("SELECT * FROM %s", table))
	db.Query("SELECT * FROM " + table)
	db.Exec(strings.TrimSpace("SELECT 1"))
	var r strings.Reader
	_ = r
}
`
	if sites := ScanSQLSites("/nowhere/n.go", src, ""); len(sites) != 0 {
		t.Fatalf("expected no sites, got %v", siteSQL(sites))
	}
}

func TestSQLSitesUnrelatedFileWithoutSQLImport(t *testing.T) {
	src := `package search

import "example.com/es"

func run(c *es.Client) {
	c.Query("SELECT nothing")
}
`
	if sites := ScanSQLSites("/nowhere/s.go", src, ""); len(sites) != 0 {
		t.Fatalf("expected no sites, got %v", siteSQL(sites))
	}
}

func TestSQLSitesUnknownReceiverInSQLFile(t *testing.T) {
	src := `package handlers

import (
	"database/sql"

	"example.com/app/internal/app"
)

var _ *sql.DB

func run(a *app.App) {
	a.DB.Query("SELECT 11")
}
`
	requireSites(t, ScanSQLSites("/nowhere/h.go", src, ""), map[string]string{"SELECT 11": SQLAPIDatabaseSQL})
}

func TestSQLSitesSiblingFieldTypes(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "store.go"), []byte("package store\n\nimport \"database/sql\"\n\ntype Store struct{ db *sql.DB }\n\nfunc (s *Store) helper() { s.db.Ping() }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "users.go")
	src := "package store\n\nfunc (s *Store) Users() {\n\ts.db.Query(`SELECT * FROM users`)\n}\n"
	requireSites(t, ScanSQLSites(path, src, dir), map[string]string{"SELECT * FROM users": SQLAPIDatabaseSQL})
	if sites := ScanSQLSites(path, src, ""); len(sites) != 0 {
		t.Fatalf("without a root the sibling is not read, got %v", siteSQL(sites))
	}
}

func TestSQLSitesPrefilterSkipsPlainFiles(t *testing.T) {
	if sites := ScanSQLSites("/nowhere/p.go", "package p\n\nfunc f() string { return \"SELECT 1\" }\n", ""); len(sites) != 0 {
		t.Fatalf("got %v", siteSQL(sites))
	}
}

func BenchmarkScanSQLSites(b *testing.B) {
	var sb strings.Builder
	sb.WriteString("package store\n\nimport (\n\t\"context\"\n\t\"database/sql\"\n)\n\ntype Store struct{ db *sql.DB }\n\n")
	for i := 0; i < 200; i++ {
		sb.WriteString("func (s *Store) Q")
		sb.WriteString(strings.Repeat("x", i%7+1))
		sb.WriteString(strconv.Itoa(i))
		sb.WriteString("(ctx context.Context) {\n\ts.db.QueryContext(ctx, `SELECT id, name FROM users WHERE id = $1`, 1)\n}\n\n")
	}
	src := sb.String()
	loadStubs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(ScanSQLSites("/nowhere/b.go", src, "")) != 200 {
			b.Fatal("missing sites")
		}
	}
}
