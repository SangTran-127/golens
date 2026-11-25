package database

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func paramNames(r ParametersResult) string {
	var parts []string
	for _, p := range r.Parameters {
		var pos []string
		for _, b := range p.Positions {
			pos = append(pos, fmt.Sprintf("%d-%d", b.StartByte, b.EndByte))
		}
		part := p.Name + "@" + strings.Join(pos, ",")
		if p.TypeHint != "" {
			part += ":" + p.TypeHint
		}
		if p.Nullable {
			part += "?"
		}
		parts = append(parts, part)
	}
	return strings.Join(parts, " ")
}

func TestParameterDetection(t *testing.T) {
	cases := []struct {
		dialect, text, want string
	}{
		{EnginePostgres, "SELECT $1::int, $2, $1 FROM t", "$1@7-9,20-22:int $2@16-18"},
		{EnginePostgres, "SELECT * FROM t WHERE a = :a AND b = @b AND c ? 'k' AND d::text = ':x' -- :y\n/* :z */", ":a@26-28 @b@37-39"},
		{EnginePostgres, "SELECT arr[1:n], arr[lo:hi] FROM t WHERE x = :x", ":x@45-47"},
		{EnginePostgres, "SELECT CAST(:when AS timestamp with time zone)", ":when@12-17:timestamp with time zone"},
		{EnginePostgres, "SELECT * FROM t WHERE id = sqlc.arg(user_id)::bigint AND n = sqlc.narg('n')", "@user_id@27-44:bigint @n@61-75?"},
		{EnginePostgres, "SELECT $tag$ :not $1 $tag$, E'\\' :no'", ""},
		{EngineMySQL, "SELECT * FROM t WHERE a = ? AND b = ? AND c = :c AND @v = 1 AND d = '?'", "?1@26-27 ?2@36-37 :c@46-48"},
		{EngineMySQL, "SELECT sqlc.arg(name), `?`", "@name@7-21"},
		{EngineSQLite, "SELECT ?, ?2, :a, @b, $c, [x:y] FROM t", "?1@7-8 ?2@10-12 :a@14-16 @b@18-20 $c@22-24"},
		{EnginePostgres, "PREPARE p AS SELECT $1", ""},
		{EnginePostgres, "CREATE FUNCTION f(int) RETURNS int BEGIN ATOMIC SELECT $1; END", ""},
	}
	for _, c := range cases {
		if got := paramNames(Parameters(c.text, c.dialect, 0, 0)); got != c.want {
			t.Errorf("%s %q:\n got %s\nwant %s", c.dialect, c.text, got, c.want)
		}
	}
	text := "SELECT :a;\nSELECT :b;\n"
	if got := paramNames(Parameters(text, EnginePostgres, 11, 21)); got != ":b@18-20" {
		t.Fatalf("range: %s", got)
	}
}

func TestBindParamsRewritesOnlyRealParameters(t *testing.T) {
	text := "SELECT ':x', $2, :name, :name -- :c\n/* :d */ FROM t WHERE y = $1"
	b := bindParams(text, EnginePostgres, []ParamValue{{Name: "$1", Value: "one"}, {Name: "$2", Value: "two"}, {Name: ":name", IsNull: true}})
	if b.sql != "SELECT ':x', $1, $2, $2 -- :c\n/* :d */ FROM t WHERE y = $3" || len(b.missing) != 0 {
		t.Fatalf("%q %v", b.sql, b.missing)
	}
	if fmt.Sprint(b.args) != "[two <nil> one]" {
		t.Fatalf("%v", b.args)
	}
	if got := b.offsets.original(strings.Index(b.sql, "FROM")); got != strings.Index(text, "FROM") {
		t.Fatalf("offset map %d", got)
	}
	m := bindParams("SELECT ?, :a, ?, :a", EngineMySQL, []ParamValue{{Name: "?1", Value: "1"}, {Name: ":a", Value: "A"}, {Name: "?2", Value: "2"}})
	if m.sql != "SELECT ?, ?, ?, ?" || fmt.Sprint(m.args) != "[1 A 2 A]" {
		t.Fatalf("%q %v", m.sql, m.args)
	}
	miss := bindParams("SELECT :a, :b", EngineSQLite, []ParamValue{{Name: ":a", Value: "1"}})
	if strings.Join(miss.missing, ",") != ":b" {
		t.Fatal(miss.missing)
	}
}

func TestParametersAreBoundNeverSpliced(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", e.sqliteDB("p.db", `CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)`, `INSERT INTO t VALUES (1, 'a')`)))
	evil := "'; DROP TABLE t; --"
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "INSERT INTO t (name) VALUES (:name)", Parameters: []ParamValue{{Name: ":name", Value: evil}}})
	if resp.Error != nil || resp.Statements[0].Error != nil || *resp.Statements[0].RowsAffected != 1 {
		t.Fatalf("%+v %+v", resp.Error, resp.Statements)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT id, name FROM t WHERE name = ? OR id = ?", Parameters: []ParamValue{{Name: "?1", Value: evil}, {Name: "?2", Value: "99"}}})
	if resp.Error != nil || resp.Statements[0].Error != nil || resp.Statements[0].RowsFetched != 1 {
		t.Fatalf("%+v %+v", resp.Error, resp.Statements)
	}
	p := mustPage(t, resp.Statements[0].ResultID, 0, 10)
	if p.Columns[1].Values[0] != evil {
		t.Fatalf("%q", p.Columns[1].Values[0])
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM t")); got != "2\n" {
		t.Fatalf("table must survive: %q", got)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM t WHERE id = :id AND name = :name"})
	if resp.Error == nil || resp.Error.Kind != "needsParameters" || !strings.Contains(resp.Error.Message, ":id and :name") || len(resp.Statements) != 0 {
		t.Fatalf("%+v", resp.Error)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM t LIMIT ?", Parameters: []ParamValue{{Name: "?1", Value: "1"}}})
	if resp.Error != nil || resp.Statements[0].Error != nil || resp.Statements[0].RowsFetched != 1 {
		t.Fatalf("an integer parameter binds as an integer: %+v", resp.Statements)
	}
	resp = e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM t WHERE name = :secret", Parameters: []ParamValue{{Name: ":secret", Value: "hunter2", Secret: true}}})
	if resp.Statements[0].Error != nil {
		t.Fatal(resp.Statements[0].Error)
	}
	h := History(HistoryRequest{DataSourceID: "ds1", Query: "secret"})
	if len(h.Entries) != 1 || len(h.Entries[0].Parameters) != 1 || !h.Entries[0].Parameters[0].Secret || h.Entries[0].Parameters[0].Value != "" {
		t.Fatalf("%+v", h.Entries)
	}
	b, _ := os.ReadFile(filepath.Join(historyState.root, "ds1.jsonl"))
	if strings.Contains(string(b), "hunter2") {
		t.Fatal("a secret parameter value reached the history file")
	}
}

func FuzzParams(f *testing.F) {
	for _, s := range []string{
		"SELECT :a, $1, ?, @b FROM t WHERE x = ':no' -- :c",
		"SELECT sqlc.arg(id)::int, sqlc.narg('n')",
		"SELECT $$ :x $$, arr[a:b], x::text",
		"/* :a */ SELECT ?3, $name",
		"SELECT ':' || :a || '\\'' || :b",
	} {
		f.Add(s, uint8(0))
		f.Add(s, uint8(1))
		f.Add(s, uint8(2))
	}
	f.Fuzz(func(t *testing.T, text string, d uint8) {
		dialect := []string{EnginePostgres, EngineMySQL, EngineSQLite}[d%3]
		uses := findParams(text, dialect)
		var values []ParamValue
		for _, u := range uses {
			if u.start < 0 || u.end > len(text) || u.start >= u.end {
				t.Fatalf("bad range %+v", u)
			}
			values = append(values, ParamValue{Name: u.name, Value: "v"})
		}
		b := bindParams(text, dialect, values)
		if len(b.missing) != 0 {
			t.Fatalf("missing %v", b.missing)
		}
		if len(uses) == 0 {
			if b.sql != text && b.sql != "" {
				t.Fatal("text changed without parameters")
			}
			return
		}
		var orig, rewritten strings.Builder
		prev := 0
		for _, u := range uses {
			orig.WriteString(text[prev:u.start])
			prev = u.end
		}
		orig.WriteString(text[prev:])
		prev = 0
		for _, ed := range b.offsets.edits {
			rewritten.WriteString(b.sql[prev:ed.newStart])
			placeholder := b.sql[ed.newStart:ed.newEnd]
			if placeholder != "?" && !strings.HasPrefix(placeholder, "$") {
				t.Fatalf("placeholder %q", placeholder)
			}
			prev = ed.newEnd
		}
		rewritten.WriteString(b.sql[prev:])
		if orig.String() != rewritten.String() {
			t.Fatalf("text outside parameters changed:\n%q\n%q", orig.String(), rewritten.String())
		}
		if dialect != EnginePostgres && len(b.args) != len(uses) {
			t.Fatalf("args %d uses %d", len(b.args), len(uses))
		}
	})
}

func TestHistoryCapCompactionAndSearch(t *testing.T) {
	newEnv(t)
	root := t.TempDir()
	SetHistoryDirectory(filepath.Join(root, "QueryHistory"))
	at := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	for i := 0; i < 1300; i++ {
		n := int64(i)
		recordHistory("ds/1", historyEntry(fmt.Sprintf("SELECT %d", i), "console", StatementResult{RowsAffected: &n, DurationMs: 1}, nil, at))
	}
	path := filepath.Join(root, "QueryHistory", "ds_1.jsonl")
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
	if di, _ := os.Stat(filepath.Dir(path)); di.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v", di.Mode().Perm())
	}
	lines := 0
	f, _ := os.Open(path)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines++
	}
	f.Close()
	if lines > historyCap+historySlack {
		t.Fatalf("file holds %d lines", lines)
	}
	all := History(HistoryRequest{DataSourceID: "ds/1", Limit: 5000})
	if len(all.Entries) != historyCap || all.Entries[0].Text != "SELECT 1299" || all.Entries[historyCap-1].Text != "SELECT 300" {
		t.Fatalf("%d entries, first %q last %q", len(all.Entries), all.Entries[0].Text, all.Entries[len(all.Entries)-1].Text)
	}
	found := History(HistoryRequest{DataSourceID: "ds/1", Query: "select 129", Limit: 50})
	if len(found.Entries) != 10 {
		t.Fatalf("search found %d", len(found.Entries))
	}
	gone := found.Entries[0].ID
	after := History(HistoryRequest{DataSourceID: "ds/1", Delete: gone, Query: "SELECT 1299"})
	if len(after.Entries) != 0 {
		t.Fatalf("%+v", after.Entries)
	}
	SetHistoryDirectory(filepath.Join(root, "QueryHistory"))
	if again := History(HistoryRequest{DataSourceID: "ds/1", Limit: 5000}); len(again.Entries) != historyCap {
		t.Fatalf("history survives a relaunch: %d", len(again.Entries))
	}
	recordHistory("ds/1", historyEntry("SELECT 'new'", "console", StatementResult{Error: errorFor("syntax")}, nil, at))
	latest := History(HistoryRequest{DataSourceID: "ds/1", Limit: 1})
	if latest.Entries[0].Error == "" || latest.Entries[0].RowCount != nil {
		t.Fatalf("%+v", latest.Entries[0])
	}
	if c := History(HistoryRequest{DataSourceID: "ds/1", Clear: true}); c.Error != nil {
		t.Fatal(c.Error)
	}
	if left := History(HistoryRequest{DataSourceID: "ds/1"}); len(left.Entries) != 0 {
		t.Fatal("clear")
	}
}

func TestHistoryDefaultRootFollowsTheBundle(t *testing.T) {
	root := defaultHistoryRoot()
	if !strings.HasSuffix(root, filepath.Join("Library", "Application Support", "GoLens", "QueryHistory")) {
		t.Fatalf("outside an app bundle the folder is GoLens: %s", root)
	}
	m := bundleIDPattern.FindSubmatch([]byte("<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>dev.golens.smoke.db</string>"))
	if m == nil || string(m[1]) != "dev.golens.smoke.db" {
		t.Fatal("bundle identifier")
	}
}

func TestErrorPositionsSQLiteAndMySQL(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", e.sqliteDB("x.db", "CREATE TABLE t (a int)")))
	text := "SELECT 1;\nSELECT a\nFROMM t"
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: text, Mode: "caret", CaretByte: 12})
	pos := resp.Statements[0].Error.Position
	if pos == nil || pos.Line != 3 || pos.Col != 7 {
		t.Fatalf("%+v %+v", resp.Statements[0].Error, pos)
	}
	stmt := "SELECT *\nFROM t\nWHER x = 1"
	off, ok := enginePosition(&Error{Detail: "You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'x = 1' at line 3"}, stmt)
	if !ok || stmt[off:] != "x = 1" {
		t.Fatalf("%d %v", off, ok)
	}
}
