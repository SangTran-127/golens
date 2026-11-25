package database

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func exportDB(e *env) string {
	return e.sqliteDB("export.db",
		`CREATE TABLE things (id INTEGER PRIMARY KEY, "odd ""name""" TEXT, amount NUMERIC, ok BOOLEAN, raw BLOB, doc JSON, note TEXT)`,
		`INSERT INTO things VALUES
 (1, 'comma, "quote"', 10.5, 1, x'00ff', '{"a": [1, 2]}', 'line1
line2'),
 (2, NULL, -3, 0, NULL, NULL, 'tab	here | pipe \ back'),
 (3, 'Tiếng Việt', 1e3, NULL, x'', '"str"', '')`,
	)
}

func exportReq(id, format string) ExportRequest {
	return ExportRequest{ResultID: id, Format: format, Scope: "loaded", Clipboard: true}
}

func TestExportFormats(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", exportDB(e)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM things ORDER BY id"})
	id := resp.Statements[0].ResultID

	res := Export(exportReq(id, "csv"))
	if res.Error != nil || res.RowsWritten != 3 || res.Bytes != int64(len(res.Text)) {
		t.Fatalf("%+v", res)
	}
	records, err := csv.NewReader(strings.NewReader(res.Text)).ReadAll()
	if err != nil || len(records) != 4 || !strings.Contains(res.Text, "\r\n") {
		t.Fatalf("RFC 4180: %v\n%s", err, res.Text)
	}
	if records[0][1] != `odd "name"` || records[1][1] != `comma, "quote"` || records[1][6] != "line1\nline2" || records[1][4] != "0x00ff" || records[2][1] != "" {
		t.Fatalf("%q", records)
	}

	res = Export(exportReq(id, "json"))
	var objs []map[string]any
	if err := json.Unmarshal([]byte(res.Text), &objs); err != nil || len(objs) != 3 {
		t.Fatalf("%v\n%s", err, res.Text)
	}
	if objs[0]["id"] != 1.0 || objs[0]["amount"] != 10.5 || objs[0]["ok"] != true || objs[0]["raw"] != "0x00ff" || objs[1][`odd "name"`] != nil {
		t.Fatalf("%v", objs[0])
	}
	if doc, ok := objs[0]["doc"].(map[string]any); !ok || fmt.Sprint(doc["a"]) != "[1 2]" {
		t.Fatalf("JSON columns embed as JSON: %v", objs[0]["doc"])
	}
	if objs[2]["doc"] != "str" || objs[2]["amount"] != 1000.0 || objs[2]["ok"] != nil {
		t.Fatalf("%v", objs[2])
	}

	res = Export(exportReq(id, "tsv"))
	lines := strings.Split(strings.TrimSuffix(res.Text, "\n"), "\n")
	if len(lines) != 4 || lines[1] != "1\tcomma, \"quote\"\t10.5\ttrue\t0x00ff\t{\"a\":[1,2]}\tline1\\nline2" || !strings.HasSuffix(lines[2], "tab\\there | pipe \\\\ back") {
		t.Fatalf("%q", lines)
	}

	res = Export(exportReq(id, "markdown"))
	wantMD := "| id | odd \"name\" | amount | ok | raw | doc | note |\n" +
		"| ---: | --- | ---: | --- | --- | --- | --- |\n" +
		"| 1 | comma, \"quote\" | 10.5 | true | 0x00ff | {\"a\":[1,2]} | line1<br>line2 |\n" +
		"| 2 | NULL | -3 | false | NULL | NULL | tab\there \\| pipe \\ back |\n" +
		"| 3 | Tiếng Việt | 1000 | NULL | 0x | \"str\" |  |\n"
	if res.Text != wantMD {
		t.Fatalf("got:\n%s\nwant:\n%s", res.Text, wantMD)
	}

	req := exportReq(id, "sql")
	req.Options.TableName = "copy"
	res = Export(req)
	if !strings.HasPrefix(res.Text, `INSERT INTO "copy" ("id", "odd ""name""", "amount", "ok", "raw", "doc", "note") VALUES (1, 'comma, "quote"', 10.5, TRUE, X'00ff', '{"a":[1,2]}', 'line1`) {
		t.Fatalf("%s", res.Text)
	}
	if r := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "w", Text: `CREATE TABLE copy AS SELECT * FROM things WHERE 0`}); r.Statements[0].Error != nil {
		t.Fatal(r.Statements[0].Error)
	}
	run := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "w", Text: res.Text})
	if run.Error != nil || len(run.Statements) != 3 || run.Statements[2].Error != nil {
		t.Fatalf("the SQL export runs back in: %+v %+v", run.Error, run.Statements)
	}
	a := flat(rowsOf(t, e, `SELECT id, "odd ""name""", amount, ok + 0, hex(raw), doc, note FROM things ORDER BY id`))
	b := flat(rowsOf(t, e, `SELECT id, "odd ""name""", amount, ok + 0, hex(raw), doc, note FROM copy ORDER BY id`))
	if a != b {
		t.Fatalf("round trip:\n%s\n%s", a, b)
	}

	for _, d := range []struct{ dialect, want string }{
		{EnginePostgres, `'\x00ff'`},
		{EngineMySQL, "X'00ff'"},
	} {
		if got := sqlLiteralFor(d.dialect, KindBinary, []byte{0, 0xff}); got != d.want {
			t.Errorf("%s binary %s", d.dialect, got)
		}
	}
	if got := sqlLiteralFor(EngineMySQL, KindText, []byte(`it's a \ test`)); got != `'it''s a \\ test'` {
		t.Errorf("MySQL escapes backslashes: %s", got)
	}
	if got := qualifiedFromText(EngineMySQL, "app.order items"); got != "`app`.`order items`" {
		t.Errorf("%s", got)
	}
}

func TestExportScopesAndFile(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 1200)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT id, note FROM orders ORDER BY id", PageSize: 500})
	id := resp.Statements[0].ResultID
	sel := Export(ExportRequest{ResultID: id, Format: "csv", Scope: "selection", Rows: []int64{4, 0, 2}, Clipboard: true, Options: ExportOptions{IncludeHeader: ptr(false), Columns: []int{0}}})
	if sel.Text != "5\r\n1\r\n3\r\n" {
		t.Fatalf("%q", sel.Text)
	}
	SortResultRows(id, []SortKey{{Column: 0, Descending: true}})
	sel = Export(ExportRequest{ResultID: id, Format: "csv", Scope: "selection", Rows: []int64{0}, Clipboard: true, Options: ExportOptions{IncludeHeader: ptr(false), Columns: []int{0}}})
	if sel.Text != "500\r\n" {
		t.Fatalf("selection follows the sorted view: %q", sel.Text)
	}
	loaded := Export(ExportRequest{ResultID: id, Format: "tsv", Scope: "loaded", Clipboard: true})
	if loaded.RowsWritten != 500 || !strings.HasPrefix(loaded.Text, "id\tnote\n500\t") {
		t.Fatalf("%d %q", loaded.RowsWritten, loaded.Text[:20])
	}
	path := filepath.Join(t.TempDir(), "orders.csv")
	all := Export(ExportRequest{ExecID: "exp", ResultID: id, Format: "csv", Scope: "all", Path: path})
	if all.Error != nil || all.RowsWritten != 1200 || !all.CursorClosed {
		t.Fatalf("%+v", all)
	}
	b, _ := os.ReadFile(path)
	if strings.Count(string(b), "\r\n") != 1201 || int64(len(b)) != all.Bytes {
		t.Fatal("file contents")
	}
	if p := mustPage(t, id, 495, 10); p.Flags&PageFlagEnd == 0 || p.Rows != 5 {
		t.Fatal("after exporting the cursor the grid stops asking for more rows")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatalf("temporary files left behind: %v", entries)
	}
	if bad := Export(ExportRequest{ResultID: id, Format: "xml", Scope: "all", Clipboard: true}); bad.Error == nil {
		t.Fatal("unknown format")
	}
	if bad := Export(ExportRequest{ResultID: id, Format: "csv", Scope: "all", Path: "relative.csv"}); bad.Error == nil {
		t.Fatal("relative path")
	}
}

func TestExportClipboardCap(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", e.sqliteDB("big.db", `CREATE TABLE t (v TEXT)`,
		`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1500) INSERT INTO t SELECT printf('%.8000c', 'x') FROM n`)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT v FROM t", PageSize: 2000})
	res := Export(ExportRequest{ResultID: resp.Statements[0].ResultID, Format: "csv", Scope: "loaded", Clipboard: true})
	if res.Error == nil || res.Error.Kind != "tooLarge" || res.Text != "" || !strings.Contains(res.Error.Message, "10 MB") {
		t.Fatalf("%+v", res.Error)
	}
}

func TestExportAllStreamsOneMillionRowsWithFlatMemory(t *testing.T) {
	if testing.Short() {
		t.Skip("streams a million rows")
	}
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 1_000_000)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM orders", PageSize: 500})
	id := resp.Statements[0].ResultID
	runtime.GC()
	var base runtime.MemStats
	runtime.ReadMemStats(&base)
	var peak atomic.Uint64
	stop := make(chan struct{})
	sampled := make(chan struct{})
	go func() {
		defer close(sampled)
		var ms runtime.MemStats
		for {
			select {
			case <-stop:
				return
			case <-time.After(10 * time.Millisecond):
			}
			runtime.ReadMemStats(&ms)
			if ms.HeapInuse > peak.Load() {
				peak.Store(ms.HeapInuse)
			}
		}
	}()
	path := filepath.Join(t.TempDir(), "orders.csv")
	start := time.Now()
	res := Export(ExportRequest{ExecID: "big", ResultID: id, Format: "csv", Scope: "all", Path: path})
	close(stop)
	<-sampled
	if res.Error != nil || res.RowsWritten != 1_000_000 {
		t.Fatalf("%+v", res)
	}
	growth := int64(peak.Load()) - int64(base.HeapInuse)
	t.Logf("exported %d rows (%d bytes) in %v; heap in use grew by at most %.1f MB; spool %d rows",
		res.RowsWritten, res.Bytes, time.Since(start), float64(growth)/(1<<20), lookupResult(id).sp.rowCount())
	if growth > 32<<20 {
		t.Fatalf("heap grew by %d MB while streaming", growth>>20)
	}
	if n := lookupResult(id).sp.rowCount(); n != 500 {
		t.Fatalf("the spool grew to %d rows", n)
	}
	f, _ := os.Open(path)
	defer f.Close()
	lines := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines++
	}
	if lines != 1_000_001 {
		t.Fatalf("%d lines", lines)
	}
}

func TestExportCancelByExecID(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 300_000)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM orders", PageSize: 500})
	id := resp.Statements[0].ResultID
	path := filepath.Join(t.TempDir(), "orders.json")
	done := make(chan ExportResult, 1)
	go func() {
		done <- Export(ExportRequest{ExecID: "exp-cancel", ResultID: id, Format: "json", Scope: "all", Path: path})
	}()
	deadline := time.Now().Add(5 * time.Second)
	for !Cancel("exp-cancel") {
		if time.Now().After(deadline) {
			t.Fatal("export never registered")
		}
		time.Sleep(time.Millisecond)
	}
	res := <-done
	if res.Error == nil || res.Error.Kind != "cancelled" {
		t.Skipf("the export finished before the cancel landed: %+v", res)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a canceled export leaves no file")
	}
	again := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT 1"})
	if again.Error != nil || again.Statements[0].Error != nil {
		t.Fatalf("the console keeps working: %+v", again)
	}
}
