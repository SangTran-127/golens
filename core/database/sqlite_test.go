package database

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func t0() context.Context { return context.Background() }

const ordersSchema = `CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL)`

func ordersDB(e *env, rows int) string {
	stmts := []string{
		ordersSchema,
		`CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), amount NUMERIC, note TEXT, paid BOOLEAN, payload BLOB, created_at DATETIME)`,
		`CREATE INDEX orders_customer ON orders(customer_id)`,
		`INSERT INTO customers (id, name) VALUES (1, 'Ada'), (2, 'Grace')`,
		fmt.Sprintf(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < %d)
INSERT INTO orders SELECT x, 1 + x %% 2, x * 1.5, CASE WHEN x %% 7 = 0 THEN NULL ELSE 'note ' || x END, x %% 2, x'00ff', '2026-11-15 10:00:00' FROM n`, rows),
	}
	return e.sqliteDB("app.db", stmts...)
}

func TestNothingRunsUntilUsed(t *testing.T) {
	e := newEnv(t)
	before := runtime.NumGoroutine()
	e.configure(sqliteDef("ds1", ordersDB(e, 10)))
	st := GetStats()
	if st.Sessions != 0 || st.Pools != 0 || st.OpenResults != 0 || st.SpoolMemBytes != 0 {
		t.Fatalf("stats after configure: %+v", st)
	}
	if e.clock.active() != 0 {
		t.Fatal("configure armed a timer")
	}
	if got := runtime.NumGoroutine(); got > before {
		t.Fatalf("goroutines grew from %d to %d", before, got)
	}
	_ = Statements("SELECT 1; DELETE FROM t", "sqlite")
	_ = Complete(CompleteRequest{DataSourceID: "ds1", Dialect: "sqlite", Text: "SELECT ", CaretByte: 7})
	if st := GetStats(); st.Sessions != 0 || st.Pools != 0 {
		t.Fatalf("pure calls connected: %+v", st)
	}
}

func TestSQLiteExecuteFetchSortCell(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 1200)))
	text := "SELECT 1;\nSELECT id, note, amount, paid, payload, created_at FROM orders ORDER BY id;\n"
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: text, Mode: "caret", CaretByte: 15, PageSize: 500})
	if resp.Error != nil || len(resp.Statements) != 1 {
		t.Fatalf("%+v", resp)
	}
	sr := resp.Statements[0]
	if sr.Error != nil || sr.RowsFetched != 500 || sr.Complete || sr.Truncated || sr.ResultID == "" || sr.Line != 2 {
		t.Fatalf("statement: %+v %+v", sr, sr.Error)
	}
	if sr.Columns[0].Kind != "int" || sr.Columns[1].Kind != "text" || sr.Columns[3].Kind != "bool" || sr.Columns[4].Kind != "binary" || sr.Columns[5].Kind != "datetime" {
		t.Fatalf("columns: %+v", sr.Columns)
	}
	if resp.Session.State != "connected" || resp.Session.Transaction != "idle" {
		t.Fatalf("session: %+v", resp.Session)
	}
	p := mustPage(t, sr.ResultID, 0, 500)
	if p.Rows != 500 || p.Flags&PageFlagEnd != 0 || p.Columns[0].Values[0] != "1" || p.Columns[1].Values[0] != "note 1" {
		t.Fatalf("first page: rows=%d flags=%d first=%q", p.Rows, p.Flags, p.Columns[0].Values[0])
	}
	if !p.Columns[1].Nulls[6] || p.Columns[3].Values[0] != "true" || p.Columns[4].Values[0] != "0x00ff" || p.Columns[5].Values[0] != "2026-11-15T10:00:00Z" {
		t.Fatalf("formatting: null=%v paid=%q blob=%q at=%q", p.Columns[1].Nulls[6], p.Columns[3].Values[0], p.Columns[4].Values[0], p.Columns[5].Values[0])
	}
	p = mustPage(t, sr.ResultID, 500, 500)
	if p.Rows != 500 || p.FirstRow != 500 || p.Columns[0].Values[0] != "501" {
		t.Fatalf("second page from cursor: %d %q", p.Rows, p.Columns[0].Values[0])
	}
	fa := FetchAll(sr.ResultID)
	if fa.Error != nil || fa.RowsFetched != 1200 || !fa.Complete {
		t.Fatalf("fetch all: %+v", fa)
	}
	p = mustPage(t, sr.ResultID, 1100, 500)
	if p.Rows != 100 || p.Flags&PageFlagEnd == 0 {
		t.Fatalf("last page: %d flags %d", p.Rows, p.Flags)
	}
	so := SortResultRows(sr.ResultID, []SortKey{{Column: 2, Descending: true}})
	if so.Error != nil || so.SortedRows != 1200 || !so.Complete || so.Version != 1 {
		t.Fatalf("sort: %+v", so)
	}
	p = mustPage(t, sr.ResultID, 0, 3)
	if p.Flags&PageFlagSorted == 0 || p.Version != 1 || p.Columns[0].Values[0] != "1200" || p.Columns[0].Values[1] != "1199" {
		t.Fatalf("sorted page: %v %d", p.Columns[0].Values, p.Flags)
	}
	cv := Cell(sr.ResultID, 0, 1, 4)
	if cv.IsNull || cv.Text != "note" || !cv.Truncated || cv.ByteCount != 9 || cv.Encoding != "utf8" {
		t.Fatalf("cell: %+v", cv)
	}
	cv = Cell(sr.ResultID, 0, 4, 100)
	if cv.Encoding != "hex" || cv.Text != "00ff" || cv.Kind != "binary" {
		t.Fatalf("binary cell: %+v", cv)
	}
	if so := SortResultRows(sr.ResultID, nil); so.Version != 2 {
		t.Fatalf("unsort: %+v", so)
	}
	CloseResult(sr.ResultID)
	if _, ok := FetchPage(sr.ResultID, 0, 1); ok {
		t.Fatal("closed result still served")
	}
	if st := GetStats(); st.OpenResults != 0 || st.SpoolMemBytes != 0 {
		t.Fatalf("after close: %+v", st)
	}
	var started, finished int
	for _, ev := range e.log.all() {
		switch ev.Event {
		case "statementStarted":
			started++
		case "statementFinished":
			finished++
		}
	}
	if started != 1 || finished != 1 {
		t.Fatalf("events started=%d finished=%d", started, finished)
	}
}

func TestSortTextNullsAndUnparsableNumbers(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", e.sqliteDB("sort.db",
		`CREATE TABLE t (id INTEGER, name TEXT, score NUMERIC)`,
		`INSERT INTO t VALUES (1, 'pear', 10), (2, NULL, 'n/a'), (3, 'apple', 2), (4, 'pear', NULL), (5, 'apple', 'abc'), (6, 'fig', 2.5)`)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT id, name, score FROM t"})
	id := resp.Statements[0].ResultID
	ids := func(keys ...SortKey) string {
		if so := SortResultRows(id, keys); so.Error != nil || so.SortedRows != 6 {
			t.Fatalf("sort: %+v", so)
		}
		return strings.Join(mustPage(t, id, 0, 6).Columns[0].Values, ",")
	}
	if got := ids(SortKey{Column: 1}); got != "3,5,6,1,4,2" {
		t.Fatalf("name ascending: %s", got)
	}
	if got := ids(SortKey{Column: 1, Descending: true}, SortKey{Column: 0, Descending: true}); got != "2,4,1,6,5,3" {
		t.Fatalf("name descending, id descending: %s", got)
	}
	if got := ids(SortKey{Column: 2}); got != "3,6,1,5,2,4" {
		t.Fatalf("score ascending: %s", got)
	}
	CloseResult(id)
}

func TestSQLiteRunAllTruncatesEarlierResults(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 700)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM orders; UPDATE orders SET note = 'x' WHERE id = 1; SELECT id FROM orders", PageSize: 500})
	if len(resp.Statements) != 3 {
		t.Fatalf("%+v", resp)
	}
	a, b, c := resp.Statements[0], resp.Statements[1], resp.Statements[2]
	if !a.Truncated || a.Complete || a.RowsFetched != 500 {
		t.Fatalf("first: %+v", a)
	}
	if b.RowsAffected == nil || *b.RowsAffected != 1 || b.ResultID != "" {
		t.Fatalf("update: %+v", b)
	}
	if c.Truncated || c.Complete {
		t.Fatalf("last: %+v", c)
	}
	if p := mustPage(t, a.ResultID, 500, 100); p.Rows != 0 || p.Flags&PageFlagEnd == 0 {
		t.Fatalf("truncated result read more rows: %d", p.Rows)
	}
	if p := mustPage(t, c.ResultID, 500, 500); p.Rows != 200 {
		t.Fatalf("last result: %d", p.Rows)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT nope FROM orders; SELECT 1"})
	if len(resp.Statements) != 1 || resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "syntax" {
		t.Fatalf("error stops the run: %+v", resp.Statements)
	}
	if resp.Statements[0].Error.Position == nil || resp.Statements[0].Error.Position.Line != 1 {
		t.Fatalf("position: %+v", resp.Statements[0].Error)
	}
}

func countOrders(t *testing.T, e *env) string {
	t.Helper()
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "counter", Text: "SELECT count(*) FROM orders"})
	if resp.Error != nil || resp.Statements[0].Error != nil {
		t.Fatalf("%+v", resp)
	}
	return mustPage(t, resp.Statements[0].ResultID, 0, 1).Columns[0].Values[0]
}

func TestBlockedStatementsNeedConfirmation(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 20)))
	text := "DELETE FROM orders"
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: text})
	if len(resp.Blocked) != 1 || len(resp.Statements) != 0 || resp.Error != nil {
		t.Fatalf("%+v", resp)
	}
	b := resp.Blocked[0]
	if b.Risk != RiskDeleteWithoutWhere || b.Table != "orders" || b.Hash != statementHash(text) || b.Line != 1 || b.Preview != "DELETE FROM orders" {
		t.Fatalf("blocked: %+v", b)
	}
	if got := countOrders(t, e); got != "20" {
		t.Fatalf("blocked statement ran: %s rows left", got)
	}
	edited := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "DELETE FROM orders ", Confirmed: []Confirmation{{Hash: b.Hash, Risk: b.Risk}}})
	if len(edited.Blocked) != 0 {
		t.Fatalf("whitespace-only edit should keep the hash: %+v", edited.Blocked)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "UPDATE orders SET note = 'y'"})
	if len(resp.Blocked) != 1 || resp.Blocked[0].Risk != RiskUpdateWithoutWhere {
		t.Fatalf("update: %+v", resp)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "UPDATE orders SET note = 'yy'", Confirmed: []Confirmation{{Hash: resp.Blocked[0].Hash, Risk: RiskUpdateWithoutWhere}}})
	if len(resp.Blocked) != 1 {
		t.Fatal("an edited statement must ask again")
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "DROP TABLE customers"})
	if len(resp.Blocked) != 1 || resp.Blocked[0].Risk != RiskDropTable {
		t.Fatalf("drop: %+v", resp)
	}
	prod := sqliteDef("ds1", "app.db")
	prod.Production = true
	e.configure(prod)
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "INSERT INTO customers VALUES (3, 'Linus')"})
	if len(resp.Blocked) != 1 || resp.Blocked[0].Risk != RiskProductionWrite {
		t.Fatalf("production write: %+v", resp)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "INSERT INTO customers VALUES (3, 'Linus')", Confirmed: []Confirmation{{Hash: resp.Blocked[0].Hash, Risk: RiskProductionWrite}}})
	if len(resp.Blocked) != 0 || resp.Statements[0].Error != nil || *resp.Statements[0].RowsAffected != 1 {
		t.Fatalf("confirmed production write: %+v", resp)
	}
	if resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 1"}); len(resp.Blocked) != 0 {
		t.Fatal("reads on production are not blocked")
	}
}

func TestReadOnlyRefusedByClassifierAndEngine(t *testing.T) {
	e := newEnv(t)
	def := sqliteDef("ds1", ordersDB(e, 5))
	def.ReadOnly = true
	e.configure(def)
	for _, text := range []string{
		"INSERT INTO customers VALUES (9, 'x')",
		"UPDATE customers SET name = 'x' WHERE id = 1",
		"DELETE FROM customers WHERE id = 1",
		"CREATE TABLE t (id int)",
		"WITH d AS (DELETE FROM customers WHERE id = 1 RETURNING *) SELECT * FROM d",
		"PRAGMA query_only = 0",
	} {
		resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 1;\n" + text})
		if resp.Error == nil || resp.Error.Kind != "readOnly" || len(resp.Statements) != 0 || resp.Error.Position.Line != 2 {
			t.Fatalf("%s: %+v", text, resp)
		}
		if !strings.Contains(resp.Error.Message, "fixture is read-only") {
			t.Fatalf("message: %s", resp.Error.Message)
		}
	}
	if resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT name FROM customers"}); resp.Error != nil || resp.Statements[0].Error != nil {
		t.Fatalf("read on read-only: %+v", resp)
	}
	ds := reg.source("ds1")
	s := reg.sessionFor("console-1", ds)
	req := ExecuteRequest{ExecID: "bypass", ConsoleID: "console-1", DataSourceID: "ds1", Text: "INSERT INTO customers VALUES (9, 'x'); DELETE FROM customers", Mode: "all"}
	items := selectItems(req, EngineSQLite)
	for i := range items {
		items[i].class.writes = false
		items[i].class.risks = nil
		items[i].class.returnsRows = false
	}
	resp := s.execute(req, items)
	if len(resp.Statements) != 1 || resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "readOnly" {
		t.Fatalf("engine-level read-only: %+v", resp.Statements)
	}
	if got := countCustomers(t, e); got != "2" {
		t.Fatalf("engine let a write through: %s", got)
	}
}

func countCustomers(t *testing.T, e *env) string {
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "counter", Text: "SELECT count(*) FROM customers"})
	return mustPage(t, resp.Statements[0].ResultID, 0, 1).Columns[0].Values[0]
}

func TestSQLiteCancelRunningStatementAndFetchAll(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 5)))
	done := make(chan ExecuteResponse, 1)
	go func() {
		done <- e.exec(ExecuteRequest{ExecID: "long", DataSourceID: "ds1",
			Text: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"})
	}()
	deadline := time.Now().Add(2 * time.Second)
	for !Cancel("long") {
		if time.Now().After(deadline) {
			t.Fatal("statement never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	start := time.Now()
	select {
	case resp := <-done:
		if time.Since(start) > time.Second {
			t.Fatalf("cancel took %v", time.Since(start))
		}
		if resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "cancelled" || resp.Statements[0].Error.Message != "The statement was canceled." {
			t.Fatalf("%+v", resp.Statements[0].Error)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancel did not stop the statement")
	}
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x, 'row ' || x FROM c"})
	id := resp.Statements[0].ResultID
	if id == "" || resp.Statements[0].Complete {
		t.Fatalf("%+v", resp.Statements[0])
	}
	fa := make(chan FetchAllResult, 1)
	go func() { fa <- FetchAll(id) }()
	time.Sleep(150 * time.Millisecond)
	if !Cancel(id) {
		t.Fatal("fetch all was not running")
	}
	select {
	case r := <-fa:
		if r.Complete || r.Error == nil || r.Error.Kind != "cancelled" || r.RowsFetched <= 500 {
			t.Fatalf("%+v", r)
		}
	case <-time.After(time.Second):
		t.Fatal("cancel did not stop fetch all")
	}
	if resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 42"}); resp.Statements[0].Error != nil {
		t.Fatalf("session unusable after cancel: %+v", resp.Statements[0].Error)
	}
}

func TestSpoolSpillsAndCleansUp(t *testing.T) {
	e := newEnv(t)
	spoolState.limit = 256 << 10
	e.configure(sqliteDef("ds1", ordersDB(e, 20000)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT id, note, created_at FROM orders ORDER BY id"})
	id := resp.Statements[0].ResultID
	fa := FetchAll(id)
	if !fa.Complete || fa.RowsFetched != 20000 || fa.SpoolDiskBytes == 0 {
		t.Fatalf("%+v", fa)
	}
	st := GetStats()
	if st.SpoolMemBytes > spoolState.limit || st.SpoolDiskBytes == 0 {
		t.Fatalf("stats: %+v", st)
	}
	for _, first := range []int64{0, 7000, 19990} {
		p := mustPage(t, id, first, 10)
		if p.Columns[0].Values[0] != fmt.Sprint(first+1) {
			t.Fatalf("page at %d starts with %q", first, p.Columns[0].Values[0])
		}
	}
	if so := SortResultRows(id, []SortKey{{Column: 0, Descending: true}}); so.SortedRows != 20000 {
		t.Fatalf("%+v", so)
	}
	if p := mustPage(t, id, 0, 1); p.Columns[0].Values[0] != "20000" {
		t.Fatalf("sorted spill: %q", p.Columns[0].Values[0])
	}
	dir := filepath.Join(spoolState.root, fmt.Sprint(os.Getpid()))
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Fatalf("spill files: %d", len(entries))
	}
	CloseResult(id)
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("spill file left after close: %d", len(entries))
	}
	if st := GetStats(); st.SpoolDiskBytes != 0 || st.SpoolMemBytes != 0 {
		t.Fatalf("after close: %+v", st)
	}
}

func TestStaleSpoolFoldersRemovedAtFirstConfigure(t *testing.T) {
	e := newEnv(t)
	stale := filepath.Join(spoolState.root, "999999")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	e.configure(sqliteDef("ds1", ordersDB(e, 1)))
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale spool folder survived")
	}
}

func TestSecretsNeverLeak(t *testing.T) {
	e := newEnv(t)
	const secret = "hunter2-very-secret"
	pg := Definition{ID: "pg", Name: "local", Engine: EnginePostgres, Host: "127.0.0.1", Port: 1, Database: "app", User: "app", Password: "keychain", SSL: SSL{Mode: "disable"}}
	e.configure(pg)
	resp := e.exec(ExecuteRequest{DataSourceID: "pg", Text: "SELECT 1"})
	if resp.Error == nil || resp.Error.Kind != "needsSecret" || !strings.Contains(resp.Error.Message, "local") {
		t.Fatalf("%+v", resp.Error)
	}
	SetSecret("pg", secret)
	resp = e.exec(ExecuteRequest{DataSourceID: "pg", Text: "SELECT 1"})
	if resp.Error == nil || resp.Error.Kind != "connect" || !strings.Contains(resp.Error.Message, "127.0.0.1:1") {
		t.Fatalf("%+v", resp.Error)
	}
	tc := TestConnection(TestConnectionRequest{Definition: pg, Secret: secret})
	for _, v := range []any{resp, GetStats(), tc, Introspect(IntrospectRequest{DataSourceID: "pg"}), e.log.all()} {
		b, _ := json.Marshal(v)
		if strings.Contains(string(b), secret) {
			t.Fatalf("secret leaked: %s", b)
		}
	}
	e2 := classifyError(fmt.Errorf("auth failed for password %s", secret), secret)
	if strings.Contains(e2.Detail, secret) || strings.Contains(e2.Message, secret) {
		t.Fatal("redaction failed")
	}
}

func TestMissingSQLiteFile(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", "data/missing.db"))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 1"})
	if resp.Error == nil || resp.Error.Kind != "connect" || !strings.Contains(resp.Error.Message, "data/missing.db does not exist") {
		t.Fatalf("%+v", resp.Error)
	}
	tc := TestConnection(TestConnectionRequest{Definition: sqliteDef("x", "data/missing.db"), WorkspaceRoot: e.root})
	if tc.OK || tc.Error.Kind != "connect" {
		t.Fatalf("%+v", tc)
	}
	def := sqliteDef("ds1", "data/new.db")
	def.SQLiteCreate = true
	if err := os.MkdirAll(filepath.Join(e.root, "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	e.configure(def)
	if resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "CREATE TABLE t (id int)"}); resp.Error != nil || resp.Statements[0].Error != nil {
		t.Fatalf("%+v", resp)
	}
	tc = TestConnection(TestConnectionRequest{Definition: def, WorkspaceRoot: e.root})
	if !tc.OK || !strings.HasPrefix(tc.ServerVersion, "SQLite 3.") {
		t.Fatalf("%+v", tc)
	}
}

func TestIdleCloseWithFakeClock(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 5)))
	if resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 1"}); resp.Error != nil {
		t.Fatal(resp.Error)
	}
	if st := GetStats(); st.Sessions != 1 {
		t.Fatalf("%+v", st)
	}
	e.clock.Advance(14 * time.Minute)
	if st := GetStats(); st.Sessions != 1 {
		t.Fatal("closed too early")
	}
	e.clock.Advance(time.Minute)
	if st := GetStats(); st.Sessions != 0 {
		t.Fatalf("idle console not closed: %+v", st)
	}
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "BEGIN; INSERT INTO customers VALUES (5, 'x')"})
	if resp.Session.Transaction != "active" {
		t.Fatalf("%+v", resp.Session)
	}
	e.clock.Advance(16 * time.Minute)
	if st := GetStats(); st.Sessions != 1 {
		t.Fatal("console with an open transaction was closed")
	}
	warned := false
	for _, ev := range e.log.all() {
		if ev.Event == "sessionState" && ev.TransactionOpenMinutes >= 15 {
			warned = true
		}
	}
	if !warned {
		t.Fatal("no open-transaction event")
	}
	if r := CloseConsole("console-1", false); r.OK || !r.HadOpenTransaction {
		t.Fatalf("%+v", r)
	}
	if r := CloseConsole("console-1", true); !r.OK || !r.HadOpenTransaction {
		t.Fatalf("%+v", r)
	}
	if got := countCustomers(t, e); got != "2" {
		t.Fatalf("closing rolled nothing back: %s", got)
	}
	if res := Introspect(IntrospectRequest{DataSourceID: "ds1"}); res.Error != nil {
		t.Fatal(res.Error)
	}
	if st := GetStats(); st.Pools != 1 {
		t.Fatalf("%+v", st)
	}
	e.clock.Advance(2 * time.Minute)
	if st := GetStats(); st.Pools != 0 {
		t.Fatalf("idle metadata pool not closed: %+v", st)
	}
	d := Disconnect("ds1")
	if !d.OK {
		t.Fatalf("%+v", d)
	}
	if st := GetStats(); st.Sessions != 0 {
		t.Fatalf("%+v", st)
	}
}

func TestIntrospectionAndSchemaCache(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 3)))
	res := Introspect(IntrospectRequest{DataSourceID: "ds1"})
	if res.Error != nil || res.DefaultSchema != "main" || len(res.Schemas) != 1 || res.Schemas[0].Tables != 2 || res.Schemas[0].IntrospectedAt == "" {
		t.Fatalf("%+v", res)
	}
	nodes := SchemaChildren(SchemaChildrenRequest{DataSourceID: "ds1", Path: []string{"main"}}).Nodes
	if len(nodes) != 2 || nodes[0].Name != "customers" || nodes[1].Detail != "7 columns" {
		t.Fatalf("%+v", nodes)
	}
	nodes = SchemaChildren(SchemaChildrenRequest{DataSourceID: "ds1", Path: []string{"main", "orders"}}).Nodes
	kinds := map[string]int{}
	for _, n := range nodes {
		kinds[n.Kind]++
	}
	if kinds["column"] != 7 || kinds["primaryKey"] != 1 || kinds["foreignKey"] != 1 || kinds["index"] != 1 {
		t.Fatalf("%+v", nodes)
	}
	for _, n := range nodes {
		if n.Kind == "foreignKey" && n.Detail != "customer_id → customers(id)" {
			t.Fatalf("fk detail %q", n.Detail)
		}
	}
	e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "CREATE TABLE invoices (id INTEGER PRIMARY KEY)"})
	if res := Introspect(IntrospectRequest{DataSourceID: "ds1"}); res.Schemas[0].Tables != 3 {
		t.Fatalf("DDL did not refresh the snapshot: %+v", res)
	}
	Disconnect("ds1")
	ds := reg.source("ds1")
	ds.mu.Lock()
	ds.snap = nil
	ds.mu.Unlock()
	res = Introspect(IntrospectRequest{DataSourceID: "ds1"})
	if res.Schemas[0].Tables != 3 || GetStats().Pools != 0 {
		t.Fatalf("warm load should come from the disk cache without connecting: %+v %+v", res, GetStats())
	}
	c := Complete(CompleteRequest{DataSourceID: "ds1", Dialect: "sqlite", Text: "SELECT o. FROM orders o", CaretByte: 9})
	found := false
	for _, it := range c.Items {
		if it.Label == "customer_id" && it.Kind == "column" {
			found = true
		}
	}
	if !found {
		t.Fatalf("%+v", c.Items)
	}
}

func TestStatementsAndCaretSelection(t *testing.T) {
	text := "SELECT 1;\nSELECT 2;\nSELECT 3;"
	items := selectItems(ExecuteRequest{Text: text, Mode: "selection", Selection: ByteRange{StartByte: 10, EndByte: len(text)}}, "sqlite")
	if len(items) != 2 || items[0].text != "SELECT 2" || items[0].start != 10 || items[0].line != 2 {
		t.Fatalf("%+v", items)
	}
	items = selectItems(ExecuteRequest{Text: text, Mode: "caret", CaretByte: 21}, "sqlite")
	if len(items) != 1 || items[0].text != "SELECT 3" {
		t.Fatalf("%+v", items)
	}
}
