package database

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func editDB(e *env) string {
	return e.sqliteDB("edit.db",
		`CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, "e-mail" TEXT, score REAL, active BOOLEAN, avatar BLOB)`,
		`INSERT INTO people VALUES (1, 'Ada', 'ada@example.com', 9.5, 1, x'00ff'), (2, 'Grace', NULL, 7, 0, NULL), (3, 'Linus', 'l@example.com', 3.25, 1, NULL)`,
		`CREATE TABLE logs (msg TEXT)`,
		`INSERT INTO logs VALUES ('a'), ('b')`,
		`CREATE TABLE tags (name TEXT NOT NULL UNIQUE, n INTEGER)`,
		`INSERT INTO tags VALUES ('go', 1)`,
		`CREATE TABLE loose (code TEXT UNIQUE, n INTEGER)`,
		`CREATE VIEW people_view AS SELECT id, name FROM people`,
	)
}

func openTable(t *testing.T, table, where, order string) OpenTableResponse {
	t.Helper()
	resp := OpenTable(OpenTableRequest{ExecID: "open-" + table, ConsoleID: "table-" + table, DataSourceID: "ds1", Table: table, Where: where, OrderBy: order, PageSize: 500})
	if resp.Error != nil {
		t.Fatalf("open %s: %+v", table, resp.Error)
	}
	if len(resp.Statements) != 1 || resp.Statements[0].Error != nil {
		t.Fatalf("open %s: %+v", table, resp.Statements)
	}
	return resp
}

func rowsOf(t *testing.T, e *env, sql string) [][]*string {
	t.Helper()
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "check", Text: sql})
	if resp.Error != nil || resp.Statements[0].Error != nil {
		t.Fatalf("%s: %+v %+v", sql, resp.Error, resp.Statements)
	}
	p := mustPage(t, resp.Statements[0].ResultID, 0, 1000)
	out := make([][]*string, p.Rows)
	for r := range out {
		for c := range p.Columns {
			if p.Columns[c].Nulls[r] {
				out[r] = append(out[r], nil)
			} else {
				out[r] = append(out[r], s(p.Columns[c].Values[r]))
			}
		}
	}
	return out
}

func flat(rows [][]*string) string {
	var b strings.Builder
	for _, r := range rows {
		for i, v := range r {
			if i > 0 {
				b.WriteByte('|')
			}
			if v == nil {
				b.WriteString("NULL")
			} else {
				b.WriteString(*v)
			}
		}
		b.WriteByte('\n')
	}
	return b.String()
}

func TestOpenTableFilterSortAndEditability(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 50)))
	resp := openTable(t, "orders", "customer_id = 1 AND note IS NOT NULL", "id DESC")
	if !resp.Editable || strings.Join(resp.KeyColumns, ",") != "id" || resp.Reason != "" {
		t.Fatalf("%+v", resp)
	}
	if resp.SQL != "SELECT * FROM \"main\".\"orders\"\nWHERE customer_id = 1 AND note IS NOT NULL\nORDER BY id DESC" {
		t.Fatalf("sql %q", resp.SQL)
	}
	p := mustPage(t, resp.Statements[0].ResultID, 0, 3)
	if p.Columns[0].Values[0] != "50" || p.Columns[0].Values[1] != "48" || p.Columns[0].Values[2] != "46" {
		t.Fatalf("server sort/filter: %v", p.Columns[0].Values)
	}
	count := CountRows(CountRowsRequest{DataSourceID: "ds1", Table: "orders", Where: "customer_id = 1"})
	if count.Error != nil || count.Count == nil || *count.Count != 25 {
		t.Fatalf("%+v", count)
	}
	h := History(HistoryRequest{DataSourceID: "ds1"})
	if len(h.Entries) == 0 || h.Entries[0].Source != "table" || !strings.Contains(h.Entries[0].Text, "ORDER BY id DESC") {
		t.Fatalf("history %+v", h.Entries)
	}
}

func TestOpenTableEditabilityReasons(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	cases := map[string]struct {
		editable bool
		key      string
		reason   string
	}{
		"people":      {true, "id", ""},
		"tags":        {true, "name", ""},
		"logs":        {false, "", reasonNoKey},
		"loose":       {false, "", reasonNoKey},
		"people_view": {false, "", "This is a view, so GoLens can't change its rows."},
	}
	for table, want := range cases {
		resp := openTable(t, table, "", "")
		if resp.Editable != want.editable || strings.Join(resp.KeyColumns, ",") != want.key || resp.Reason != want.reason {
			t.Errorf("%s: editable=%v key=%v reason=%q", table, resp.Editable, resp.KeyColumns, resp.Reason)
		}
	}
	if reasonNoKey != "This table has no primary key, so GoLens can't identify which rows to change." {
		t.Fatal("the no-key reason must match the product copy")
	}
	logs := openTable(t, "logs", "", "")
	plan := PlanEdits(EditRequest{ResultID: logs.Statements[0].ResultID, Edits: []CellEdit{{Row: 0, Column: 0, Value: "x"}}})
	if plan.Error == nil || plan.Error.Message != reasonNoKey || len(plan.Statements) != 0 {
		t.Fatalf("%+v", plan)
	}
	ro := sqliteDef("ds1", "edit.db")
	ro.ReadOnly = true
	e.configure(ro)
	resp := openTable(t, "people", "", "")
	if resp.Editable || !strings.Contains(resp.Reason, "read-only") {
		t.Fatalf("%+v", resp)
	}
}

func TestOpenTableRejectsInjectedFragments(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	for _, bad := range []struct{ where, order string }{
		{"1=1; DROP TABLE people", ""},
		{"name = 'x", ""},
		{"1=1 /*", ""},
		{"(1=1", ""},
		{"1=1)", ""},
		{"", "id; DELETE FROM people"},
		{"", "id) UNION SELECT 1 --"},
	} {
		resp := OpenTable(OpenTableRequest{ConsoleID: "t", DataSourceID: "ds1", Table: "people", Where: bad.where, OrderBy: bad.order})
		if resp.Error == nil || resp.Error.Kind != "syntax" || len(resp.Statements) != 0 {
			t.Errorf("%q %q: %+v", bad.where, bad.order, resp.Error)
		}
	}
	resp := OpenTable(OpenTableRequest{ConsoleID: "t", DataSourceID: "ds1", Table: "people", Where: "name <> ';' -- comment", OrderBy: "id"})
	if resp.Error != nil || resp.Statements[0].Error != nil || resp.Statements[0].RowsFetched != 3 {
		t.Fatalf("a semicolon in a string and a trailing comment are fine: %+v %+v", resp.Error, resp.Statements)
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM people")); got != "3\n" {
		t.Fatal(got)
	}
}

func TestApplyEditsSQLiteRoundTrip(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	resp := openTable(t, "people", "", "id")
	id := resp.Statements[0].ResultID
	req := EditRequest{ExecID: "submit", ResultID: id,
		Edits: []CellEdit{
			{Row: 0, Column: 1, Value: "Ada Lovelace"},
			{Row: 0, Column: 2, IsNull: true},
			{Row: 1, Column: 3, Value: "8.75"},
			{Row: 1, Column: 4, Value: "true"},
			{Row: 1, Column: 5, Value: "0xcafe"},
		},
		Inserts: []RowInsert{{Cells: []InsertCell{{Column: 0, Value: "10"}, {Column: 1, Value: "Ken"}, {Column: 3, Value: "1e2"}}}},
		Deletes: []int64{2},
	}
	plan := PlanEdits(req)
	if plan.Error != nil || len(plan.Issues) != 0 || len(plan.Statements) != 4 || len(plan.Blocked) != 0 {
		t.Fatalf("%+v", plan)
	}
	want := []string{
		`DELETE FROM "main"."people" WHERE "id" = ?`,
		`UPDATE "main"."people" SET "name" = ?, "e-mail" = ? WHERE "id" = ?`,
		`UPDATE "main"."people" SET "score" = ?, "active" = ?, "avatar" = ? WHERE "id" = ?`,
		`INSERT INTO "main"."people" ("id", "name", "score") VALUES (?, ?, ?)`,
	}
	for i, st := range plan.Statements {
		if st.SQL != want[i] {
			t.Errorf("statement %d:\n got %s\nwant %s", i, st.SQL, want[i])
		}
	}
	if p := plan.Statements[1].Params; *p[0] != "Ada Lovelace" || p[1] != nil || *p[2] != "1" {
		t.Fatalf("params %v", p)
	}
	if p := plan.Statements[2].Params; *p[0] != "8.75" || *p[1] != "1" || *p[2] != "0xcafe" {
		t.Fatalf("params %v", p)
	}
	res := ApplyEdits(req)
	if res.Error != nil || !res.Applied || !res.Committed || res.RowsAffected != 4 || res.Session.Transaction != "idle" {
		t.Fatalf("%+v %+v", res, res.Error)
	}
	got := flat(rowsOf(t, e, `SELECT id, name, "e-mail", score, active, hex(avatar), typeof(score) FROM people ORDER BY id`))
	wantRows := "1|Ada Lovelace|NULL|9.5|true|00FF|real\n2|Grace|NULL|8.75|true|CAFE|real\n10|Ken|NULL|100|NULL||real\n"
	if got != wantRows {
		t.Fatalf("after submit:\n%s\nwant\n%s", got, wantRows)
	}
	b, err := os.ReadFile(filepath.Join(historyState.root, "ds1.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "Ada Lovelace") || strings.Contains(string(b), "cafe") || !strings.Contains(string(b), `"source":"edit"`) {
		t.Fatalf("history must not hold edit-grid values:\n%s", b)
	}
	if fi, _ := os.Stat(filepath.Join(historyState.root, "ds1.jsonl")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("history mode %v", fi.Mode().Perm())
	}
}

func TestApplyEditsRollsBackWhenARowChanged(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	resp := openTable(t, "people", "", "id")
	id := resp.Statements[0].ResultID
	rowsOf(t, e, "DELETE FROM people WHERE id = 3 RETURNING id")
	res := ApplyEdits(EditRequest{ResultID: id, Edits: []CellEdit{{Row: 0, Column: 1, Value: "Changed"}, {Row: 2, Column: 1, Value: "Gone"}}})
	if res.Applied || res.Error == nil || res.Error.Kind != "conflict" || res.FailedStatement == nil || *res.FailedStatement != 1 {
		t.Fatalf("%+v %+v", res, res.Error)
	}
	if !strings.Contains(res.Error.Message, "Row 3 no longer matches") || res.Session.Transaction != "idle" {
		t.Fatalf("%+v", res.Error)
	}
	if got := flat(rowsOf(t, e, "SELECT name FROM people ORDER BY id")); got != "Ada\nGrace\n" {
		t.Fatalf("the first update must roll back too: %q", got)
	}
}

func TestPlanEditsIssues(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	resp := openTable(t, "people", "", "id")
	plan := PlanEdits(EditRequest{ResultID: resp.Statements[0].ResultID,
		Edits: []CellEdit{{Row: 0, Column: 5, Value: "not hex"}, {Row: 99, Column: 1, Value: "x"}, {Row: 1, Column: 42, Value: "x"}}})
	if plan.Error != nil || len(plan.Issues) != 3 || len(plan.Statements) != 0 {
		t.Fatalf("%+v", plan)
	}
	res := ApplyEdits(EditRequest{ResultID: resp.Statements[0].ResultID, Edits: []CellEdit{{Row: 0, Column: 5, Value: "nope"}}})
	if res.Applied || res.Error == nil {
		t.Fatalf("%+v", res)
	}
	prod := sqliteDef("ds1", "edit.db")
	prod.Production = true
	prod.TxMode = ModeAuto
	e.configure(prod)
	resp = openTable(t, "people", "", "id")
	req := EditRequest{ResultID: resp.Statements[0].ResultID, Edits: []CellEdit{{Row: 0, Column: 1, Value: "Prod"}}}
	plan = PlanEdits(req)
	if len(plan.Blocked) != 1 || plan.Blocked[0].Risk != RiskProductionWrite {
		t.Fatalf("production asks again: %+v", plan.Blocked)
	}
	res = ApplyEdits(req)
	if res.Applied || len(res.Blocked) != 1 {
		t.Fatalf("%+v", res)
	}
	req.Confirmed = []Confirmation{{Hash: res.Blocked[0].Hash, Risk: res.Blocked[0].Risk}}
	other := req
	other.Edits = []CellEdit{{Row: 0, Column: 1, Value: "Different"}}
	other.Confirmed = req.Confirmed
	if r := ApplyEdits(other); r.Applied || len(r.Blocked) != 1 {
		t.Fatal("a confirmation covers exactly the confirmed changes")
	}
	if r := ApplyEdits(req); !r.Applied || r.Error != nil {
		t.Fatalf("%+v %+v", r, r.Error)
	}
}

func TestManualTransactionNeverCommitsImplicitly(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", editDB(e)))
	st := Transaction(TransactionRequest{ConsoleID: "c1", DataSourceID: "ds1", Action: "status"})
	if st.Error != nil || st.Session.Mode != ModeAuto || strings.Join(st.IsolationLevels, ",") != "serializable" {
		t.Fatalf("%+v", st)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeManual}); r.Error != nil || r.Session.Mode != ModeManual {
		t.Fatalf("%+v", r)
	}
	run := func(text string) ExecuteResponse {
		resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c1", Text: text})
		if resp.Error != nil || resp.Statements[len(resp.Statements)-1].Error != nil {
			t.Fatalf("%s: %+v %+v", text, resp.Error, resp.Statements)
		}
		return resp
	}
	resp := run("INSERT INTO logs VALUES ('manual')")
	if resp.Session.Transaction != "active" {
		t.Fatalf("a statement in manual mode opens a transaction: %+v", resp.Session)
	}
	resp = run("INSERT INTO logs VALUES ('second'); SELECT count(*) FROM logs")
	if resp.Session.Transaction != "active" {
		t.Fatalf("%+v", resp.Session)
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM logs")); got != "2\n" {
		t.Fatalf("another console must not see uncommitted rows: %q", got)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeAuto}); r.Error == nil || r.Error.Kind != "transactionOpen" {
		t.Fatalf("%+v", r)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setIsolation", Isolation: "serializable"}); r.Error == nil || r.Error.Kind != "transactionOpen" {
		t.Fatalf("%+v", r)
	}
	if r := CloseConsole("c1", false); r.OK || !r.HadOpenTransaction {
		t.Fatalf("%+v", r)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "rollback"}); r.Error != nil || r.Session.Transaction != "idle" {
		t.Fatalf("%+v", r)
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM logs")); got != "2\n" {
		t.Fatalf("roll back restores: %q", got)
	}
	run("INSERT INTO logs VALUES ('kept')")
	tableResp := openTable(t, "people", "", "id")
	_ = tableResp
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "commit"}); r.Error != nil || r.Session.Transaction != "idle" || r.Session.Mode != ModeManual {
		t.Fatalf("%+v", r)
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM logs")); got != "3\n" {
		t.Fatalf("commit keeps: %q", got)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setIsolation", Isolation: "read committed"}); r.Error == nil || r.Error.Kind != "unsupported" {
		t.Fatalf("%+v", r)
	}
	if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeAuto}); r.Error != nil || r.Session.Mode != ModeAuto {
		t.Fatalf("%+v", r)
	}
	if resp := run("INSERT INTO logs VALUES ('auto')"); resp.Session.Transaction != "idle" {
		t.Fatalf("%+v", resp.Session)
	}
}

func TestManualModeEditsStayInTheTransaction(t *testing.T) {
	e := newEnv(t)
	def := sqliteDef("ds1", editDB(e))
	def.Production = true
	e.configure(def)
	resp := openTable(t, "people", "", "id")
	if resp.Session.Mode != ModeManual {
		t.Fatalf("production defaults to manual: %+v", resp.Session)
	}
	req := EditRequest{ResultID: resp.Statements[0].ResultID, Edits: []CellEdit{{Row: 0, Column: 1, Value: "Pending"}}}
	first := ApplyEdits(req)
	req.Confirmed = []Confirmation{{Hash: first.Blocked[0].Hash, Risk: first.Blocked[0].Risk}}
	res := ApplyEdits(req)
	if !res.Applied || res.Committed || res.Session.Transaction != "active" {
		t.Fatalf("%+v %+v", res, res.Error)
	}
	if got := flat(rowsOf(t, e, "SELECT name FROM people WHERE id = 1")); got != "Ada\n" {
		t.Fatalf("not committed yet: %q", got)
	}
	Transaction(TransactionRequest{ConsoleID: "table-people", Action: "rollback"})
	if got := flat(rowsOf(t, e, "SELECT name FROM people WHERE id = 1")); got != "Ada\n" {
		t.Fatalf("%q", got)
	}
}
