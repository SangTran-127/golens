//go:build dbengines

package database

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func isMariaDB(t *testing.T) bool {
	return strings.Contains(t.Name(), "/mariadb")
}

func editTableDDL(engine string) []string {
	if engine == EnginePostgres {
		return []string{
			`DROP TABLE IF EXISTS "golens ""edit"" t"`,
			`CREATE TABLE "golens ""edit"" t" (id bigint PRIMARY KEY, "e-mail" varchar(100), born date, amount numeric(10,2), flag boolean, data bytea, at timestamptz)`,
			`INSERT INTO "golens ""edit"" t" VALUES (1, 'ada@example.com', '1815-12-10', 10.50, true, '\x00ff', '2026-11-16 09:00:00+07'),
 (2, 'grace@example.com', '1906-12-09', 2.25, false, NULL, NULL), (3, 'linus@example.com', NULL, NULL, NULL, NULL, NULL)`,
		}
	}
	return []string{
		"DROP TABLE IF EXISTS `golens \"edit\" t`",
		"CREATE TABLE `golens \"edit\" t` (id bigint PRIMARY KEY, `e-mail` varchar(100), born date, amount decimal(10,2), flag boolean, data varbinary(16), at datetime)",
		"INSERT INTO `golens \"edit\" t` VALUES (1, 'ada@example.com', '1815-12-10', 10.50, true, x'00ff', '2026-11-16 09:00:00'), " +
			"(2, 'grace@example.com', '1906-12-09', 2.25, false, NULL, NULL), (3, 'linus@example.com', NULL, NULL, NULL, NULL, NULL)",
	}
}

func engineRows(t *testing.T, e *env, def Definition, sql string) string {
	t.Helper()
	resp := run(t, e, def, "check", sql)
	p := mustPage(t, resp.Statements[len(resp.Statements)-1].ResultID, 0, 1000)
	var b strings.Builder
	for r := 0; r < p.Rows; r++ {
		for c := range p.Columns {
			if c > 0 {
				b.WriteByte('|')
			}
			if p.Columns[c].Nulls[r] {
				b.WriteString("NULL")
			} else {
				b.WriteString(p.Columns[c].Values[r])
			}
		}
		b.WriteByte('\n')
	}
	return b.String()
}

func TestEngineEditsAppliedAndRolledBack(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		for _, s := range editTableDDL(engine) {
			run(t, e, def, "setup", s)
		}
		Introspect(IntrospectRequest{DataSourceID: def.ID, Refresh: true})
		schema := def.DefaultSchema
		open := OpenTable(OpenTableRequest{ExecID: "open", ConsoleID: "table", DataSourceID: def.ID, Schema: schema, Table: `golens "edit" t`, OrderBy: "id", PageSize: 500})
		if open.Error != nil || !open.Editable || strings.Join(open.KeyColumns, ",") != "id" {
			t.Fatalf("%+v %+v", open.Error, open)
		}
		id := open.Statements[0].ResultID
		req := EditRequest{ExecID: "submit", ResultID: id,
			Edits: []CellEdit{
				{Row: 0, Column: 1, Value: "'; DROP TABLE t; --"},
				{Row: 0, Column: 3, Value: "11.75"},
				{Row: 1, Column: 2, Value: "1906-12-10"},
				{Row: 1, Column: 4, Value: "true"},
				{Row: 1, Column: 5, Value: "0xcafe"},
			},
			Inserts: []RowInsert{{Cells: []InsertCell{{Column: 0, Value: "4"}, {Column: 1, Value: "ken@example.com"}, {Column: 3, Value: "1"}}}},
			Deletes: []int64{2},
		}
		if engine == EngineMySQL {
			req.Edits[3].Value = "1"
		}
		res := ApplyEdits(req)
		if res.Error != nil || !res.Applied || !res.Committed || res.RowsAffected != 4 {
			t.Fatalf("%+v %+v", res, res.Error)
		}
		q := map[string]string{
			EnginePostgres: `SELECT id, "e-mail", born, amount, flag, encode(data, 'hex') FROM "golens ""edit"" t" ORDER BY id`,
			EngineMySQL:    "SELECT id, `e-mail`, born, amount, flag, hex(data) FROM `golens \"edit\" t` ORDER BY id",
		}[engine]
		got := strings.ToLower(engineRows(t, e, def, q))
		want := map[string]string{
			EnginePostgres: "1|'; drop table t; --|1815-12-10|11.75|true|00ff\n2|grace@example.com|1906-12-10|2.25|true|cafe\n4|ken@example.com|null|1.00|null|null\n",
			EngineMySQL:    "1|'; drop table t; --|1815-12-10|11.75|1|00ff\n2|grace@example.com|1906-12-10|2.25|1|cafe\n4|ken@example.com|null|1.00|null|null\n",
		}[engine]
		if got != want {
			t.Fatalf("after submit:\n%s\nwant\n%s", got, want)
		}

		open = OpenTable(OpenTableRequest{ConsoleID: "table", DataSourceID: def.ID, Schema: schema, Table: `golens "edit" t`, OrderBy: "id", PageSize: 500})
		id = open.Statements[0].ResultID
		run(t, e, def, "other", map[string]string{
			EnginePostgres: `DELETE FROM "golens ""edit"" t" WHERE id = 4`,
			EngineMySQL:    "DELETE FROM `golens \"edit\" t` WHERE id = 4",
		}[engine])
		res = ApplyEdits(EditRequest{ResultID: id, Edits: []CellEdit{{Row: 0, Column: 1, Value: "changed"}, {Row: 2, Column: 1, Value: "gone"}}})
		if res.Applied || res.Error == nil || res.Error.Kind != "conflict" || res.Session.Transaction != "idle" {
			t.Fatalf("%+v %+v", res, res.Error)
		}
		if got := engineRows(t, e, def, strings.Replace(q, "ORDER BY id", "WHERE id = 1", 1)); !strings.Contains(got, "DROP TABLE") {
			t.Fatalf("the first update must roll back: %s", got)
		}
		run(t, e, def, "setup", editTableDDL(engine)[0])
	})
}

func TestEngineManualModeAcrossStatements(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		run(t, e, def, "setup", "DROP TABLE IF EXISTS golens_tx")
		run(t, e, def, "setup", "CREATE TABLE golens_tx (id int PRIMARY KEY)")
		if r := Transaction(TransactionRequest{ConsoleID: "c1", DataSourceID: def.ID, Action: "setIsolation", Isolation: "repeatable read"}); r.Error != nil {
			t.Fatalf("%+v", r.Error)
		}
		if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeManual}); r.Error != nil || r.Session.Mode != ModeManual {
			t.Fatalf("%+v", r)
		}
		resp := run(t, e, def, "c1", "INSERT INTO golens_tx VALUES (1)")
		if resp.Session.Transaction != "active" || resp.Session.Isolation != "repeatable read" {
			t.Fatalf("%+v", resp.Session)
		}
		iso := map[string]string{EnginePostgres: "SHOW transaction_isolation", EngineMySQL: "SELECT @@transaction_isolation"}[engine]
		if v := strings.ToLower(engineRows(t, e, def, iso)); !strings.Contains(v, "repeatable") {
			t.Logf("the check console runs at the server default: %q", v)
		}
		got := run(t, e, def, "c1", iso+"; INSERT INTO golens_tx VALUES (2)")
		if got.Session.Transaction != "active" {
			t.Fatalf("%+v", got.Session)
		}
		if v := strings.ToLower(mustPage(t, got.Statements[0].ResultID, 0, 1).Columns[0].Values[0]); !strings.Contains(v, "repeatable") {
			t.Fatalf("isolation %q", v)
		}
		if n := engineRows(t, e, def, "SELECT count(*) FROM golens_tx"); n != "0\n" {
			t.Fatalf("another console must not see uncommitted rows: %q", n)
		}
		if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "rollback"}); r.Error != nil || r.Session.Transaction != "idle" {
			t.Fatalf("%+v", r)
		}
		run(t, e, def, "c1", "INSERT INTO golens_tx VALUES (3)")
		if n := engineRows(t, e, def, "SELECT count(*) FROM golens_tx"); n != "0\n" {
			t.Fatalf("manual mode never commits implicitly: %q", n)
		}
		if r := Transaction(TransactionRequest{ConsoleID: "c1", Action: "commit"}); r.Error != nil {
			t.Fatalf("%+v", r)
		}
		if n := engineRows(t, e, def, "SELECT id FROM golens_tx"); n != "3\n" {
			t.Fatalf("%q", n)
		}
		Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeAuto})
		run(t, e, def, "setup", "DROP TABLE golens_tx")
	})
}

func TestEngineExplain(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		run(t, e, def, "setup", "DROP TABLE IF EXISTS golens_ex")
		run(t, e, def, "setup", "CREATE TABLE golens_ex (id int PRIMARY KEY, n int)")
		run(t, e, def, "setup", "INSERT INTO golens_ex VALUES (1, 10), (2, 20), (3, 30)")
		sel := ExplainRequest{ExecuteRequest: ExecuteRequest{ExecID: "ex", ConsoleID: "c1", DataSourceID: def.ID, Mode: "caret",
			Text: "SELECT a.n, b.n FROM golens_ex a JOIN golens_ex b ON b.id = a.id WHERE a.n > :min"}, Analyze: false}
		sel.Parameters = []ParamValue{{Name: ":min", Value: "5"}}
		res := Explain(sel)
		if res.Error != nil || res.Plan == nil || len(res.Plan.Nodes) < 2 || res.Plan.MostExpensive == nil {
			t.Fatalf("%+v %+v", res.Error, res.Plan)
		}
		sel.Analyze = true
		res = Explain(sel)
		if res.Error != nil || !res.Analyzed || res.Plan == nil {
			t.Fatalf("%+v", res.Error)
		}
		acted := false
		for _, n := range res.Plan.Nodes {
			if n.ActRows != nil {
				acted = true
			}
		}
		if !acted {
			t.Fatalf("analyze reports actual rows: %s", outline(res.Plan))
		}
		t.Logf("\n%s", outline(res.Plan))
		del := ExplainRequest{ExecuteRequest: ExecuteRequest{ExecID: "ex2", ConsoleID: "c1", DataSourceID: def.ID, Mode: "caret", Text: "DELETE FROM golens_ex"}, Analyze: true}
		res = Explain(del)
		if engine == EnginePostgres {
			if res.Error != nil || !res.RolledBack || res.Session.Transaction != "idle" {
				t.Fatalf("%+v %+v", res, res.Error)
			}
			Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeManual})
			run(t, e, def, "c1", "INSERT INTO golens_ex VALUES (4, 40)")
			res = Explain(del)
			if res.Error != nil || !res.RolledBack || res.Session.Transaction != "active" {
				t.Fatalf("inside an open transaction the analyze rolls back to a savepoint: %+v %+v", res, res.Error)
			}
			Transaction(TransactionRequest{ConsoleID: "c1", Action: "rollback"})
			Transaction(TransactionRequest{ConsoleID: "c1", Action: "setMode", Mode: ModeAuto})
		} else if res.Error == nil || res.Error.Kind != "unsupported" {
			t.Fatalf("%+v", res.Error)
		}
		if n := engineRows(t, e, def, "SELECT count(*) FROM golens_ex"); n != "3\n" {
			t.Fatalf("EXPLAIN ANALYZE DELETE must leave the table unchanged: %q", n)
		}
		run(t, e, def, "setup", "DROP TABLE golens_ex")
	})
}

func TestEngineParametersAndExport(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		run(t, e, def, "setup", "DROP TABLE IF EXISTS golens_p")
		run(t, e, def, "setup", "CREATE TABLE golens_p (id int PRIMARY KEY, name varchar(60))")
		evil := "'; DROP TABLE golens_p; --"
		resp := e.exec(ExecuteRequest{DataSourceID: def.ID, ConsoleID: "c1", Text: "INSERT INTO golens_p VALUES (:id, :name)",
			Parameters: []ParamValue{{Name: ":id", Value: "1"}, {Name: ":name", Value: evil}}})
		if resp.Error != nil || resp.Statements[0].Error != nil {
			t.Fatalf("%+v %+v", resp.Error, resp.Statements)
		}
		if got := engineRows(t, e, def, "SELECT name FROM golens_p"); got != evil+"\n" {
			t.Fatalf("%q", got)
		}
		series := map[string]string{
			EnginePostgres: "SELECT g, 'row ' || g FROM generate_series(1, 100000) g",
			EngineMySQL:    "WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 100000) SELECT g, CONCAT('row ', g) FROM s",
		}[engine]
		if engine == EngineMySQL {
			if isMariaDB(t) {
				run(t, e, def, "c2", "SET SESSION max_recursive_iterations = 1000000")
			} else {
				run(t, e, def, "c2", "SET SESSION cte_max_recursion_depth = 1000000")
			}
		}
		resp = run(t, e, def, "c2", series)
		path := filepath.Join(t.TempDir(), "rows.csv")
		res := Export(ExportRequest{ExecID: "exp", ResultID: resp.Statements[0].ResultID, Format: "csv", Scope: "all", Path: path})
		if res.Error != nil || res.RowsWritten != 100000 || !res.CursorClosed {
			t.Fatalf("%+v", res)
		}
		f, _ := os.Open(path)
		lines := 0
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			lines++
		}
		f.Close()
		if lines != 100001 {
			t.Fatalf("%d lines", lines)
		}
		run(t, e, def, "c2", "SELECT 1")
		count := CountRows(CountRowsRequest{DataSourceID: def.ID, Schema: def.DefaultSchema, Table: "golens_p", Where: "id = 1"})
		if count.Error != nil || *count.Count != 1 {
			t.Fatalf("%+v", count)
		}
		run(t, e, def, "setup", "DROP TABLE golens_p")
	})
}
