package database

import (
	"database/sql/driver"
	"path/filepath"
	"strings"
	"testing"

	"modernc.org/sqlite"
)

func TestSQLiteSelectOnLockedFileSaysTheFileIsLocked(t *testing.T) {
	e := newEnv(t)
	path := e.sqliteDB("locked.db", `CREATE TABLE items (id INTEGER PRIMARY KEY)`, `INSERT INTO items VALUES (1)`)
	e.configure(sqliteDef("ds1", path))
	holder, err := (&sqlite.Driver{}).Open(filepath.Join(e.root, path))
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	if _, err := holder.(driver.ExecerContext).ExecContext(t0(), "BEGIN EXCLUSIVE", nil); err != nil {
		t.Fatal(err)
	}
	defer holder.(driver.ExecerContext).ExecContext(t0(), "ROLLBACK", nil)
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "reader", Text: "SELECT * FROM items"})
	got := resp.Error
	if got == nil && len(resp.Statements) > 0 {
		got = resp.Statements[0].Error
	}
	if got == nil {
		t.Fatalf("expected the SELECT to fail while another connection holds the file: %+v", resp)
	}
	if got.Kind != "server" || !strings.Contains(got.Message, "Another connection kept this SQLite file locked") {
		t.Fatalf("a busy SQLite file must not read as an unreachable server: %+v", got)
	}
}
