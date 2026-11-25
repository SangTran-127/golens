package database

import (
	"strings"
	"testing"
)

func TestApplyEditsSQLiteWhileAnotherConsoleReads(t *testing.T) {
	e := newEnv(t)
	path := e.sqliteDB("busy.db",
		`CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL)`,
		`INSERT INTO customers VALUES (1, 'Ada'), (2, 'Grace'), (3, 'Linus')`,
		`CREATE TABLE orders (id INTEGER PRIMARY KEY, customer INTEGER REFERENCES customers(id))`,
		`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000) INSERT INTO orders SELECT i, 1 FROM n`,
	)
	e.configure(sqliteDef("ds1", path))
	partial := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "reader", Text: "SELECT * FROM orders", PageSize: 500})
	if partial.Error != nil || partial.Statements[0].Error != nil || partial.Statements[0].Complete {
		t.Fatalf("expected a partial result: %+v %+v", partial.Error, partial.Statements)
	}
	resp := openTable(t, "customers", "", "id")
	res := ApplyEdits(EditRequest{ExecID: "submit", ResultID: resp.Statements[0].ResultID,
		Edits:   []CellEdit{{Row: 0, Column: 1, Value: "Ada Lovelace"}},
		Deletes: []int64{2},
	})
	if res.Applied || res.Error == nil {
		t.Fatalf("expected the submit to fail while the file is locked: %+v", res)
	}
	if res.Error.Kind != "server" || !strings.Contains(res.Error.Message, "Another connection kept this SQLite file locked") {
		t.Fatalf("the error must say the file is in use: %+v", res.Error)
	}
	if res.Session.Transaction != "idle" {
		t.Fatalf("a failed submit must not leave a transaction open: %+v", res.Session)
	}
	if got := flat(rowsOf(t, e, "SELECT name FROM customers ORDER BY id")); got != "Ada\nGrace\nLinus\n" {
		t.Fatalf("nothing may be saved: %q", got)
	}
}
