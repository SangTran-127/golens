package database

import (
	"fmt"
	"strings"
	"testing"
)

func syntheticTable(t *testing.T, e *env, def Definition, schema string, info *tableInfo, kinds []uint8, rows [][]*string) string {
	t.Helper()
	e.configure(def)
	ds := reg.source(def.ID)
	s := reg.sessionFor("synthetic", ds)
	cols := make([]Column, len(info.Columns))
	for i, c := range info.Columns {
		cols[i] = Column{Name: c.Name, DBType: c.Type, Kind: KindName(kinds[i])}
	}
	r := &result{id: newResultID(), sess: s, sp: newSpool("synthetic", len(cols)), columns: cols, kinds: kinds, complete: true}
	ch := newChunk(len(cols))
	for _, row := range rows {
		for c, v := range row {
			if v == nil {
				ch.setNull(c)
			} else {
				ch.setValue(c, append(ch.cols[c].data, *v...))
			}
		}
		ch.endRow()
	}
	r.sp.commit(ch)
	r.table = bindTable(def, schema, info, cols)
	reg.mu.Lock()
	reg.results[r.id] = r
	reg.mu.Unlock()
	return r.id
}

func oddTable() *tableInfo {
	return &tableInfo{Name: `odd "name"`, Kind: "table", Columns: []columnInfo{
		{Name: "id", Type: "bigint"},
		{Name: "e-mail", Type: "character varying(120)", Nullable: true},
		{Name: "weird`col", Type: "timestamp with time zone", Nullable: true},
		{Name: "data", Type: "bytea", Nullable: true},
		{Name: "tags", Type: "text[]", Nullable: true},
	}, PrimaryKey: &keyInfo{Name: "pk", Columns: []string{"id"}}}
}

func renderPlan(plan PlanEditsResult) string {
	var b strings.Builder
	for _, st := range plan.Statements {
		b.WriteString(st.SQL)
		b.WriteString(" --")
		for _, p := range st.Params {
			if p == nil {
				b.WriteString(" NULL")
			} else {
				fmt.Fprintf(&b, " %q", *p)
			}
		}
		b.WriteByte('\n')
	}
	for _, is := range plan.Issues {
		b.WriteString("issue: " + is.Message + "\n")
	}
	return b.String()
}

func TestDMLGoldenPerDialect(t *testing.T) {
	kinds := []uint8{KindInt, KindText, KindDateTime, KindBinary, KindText}
	rows := [][]*string{
		{s("1"), s("a@example.com"), s("2026-11-15T10:00:00+07:00"), s("\x00\xff"), s("{a,b}")},
		{s("2"), nil, nil, nil, nil},
	}
	req := func(id string) EditRequest {
		return EditRequest{ResultID: id,
			Edits: []CellEdit{
				{Row: 0, Column: 1, Value: "'; DROP TABLE t; --"},
				{Row: 0, Column: 2, IsNull: true},
				{Row: 0, Column: 3, Value: "0xBEEF"},
				{Row: 0, Column: 4, Value: "{x,\"y z\"}"},
			},
			Inserts: []RowInsert{{Cells: []InsertCell{{Column: 0, Value: "3"}, {Column: 1, IsNull: true}}}, {}},
			Deletes: []int64{1},
		}
	}
	golden := map[string]string{
		EnginePostgres: `DELETE FROM "app"."odd ""name""" WHERE "id" = $1::bigint -- "2"
UPDATE "app"."odd ""name""" SET "e-mail" = $1::character varying(120), "weird` + "`" + `col" = $2::timestamp with time zone, "data" = $3::bytea, "tags" = $4::text[] WHERE "id" = $5::bigint -- "'; DROP TABLE t; --" NULL "\\xbeef" "{x,\"y z\"}" "1"
INSERT INTO "app"."odd ""name""" ("id", "e-mail") VALUES ($1::bigint, $2::character varying(120)) -- "3" NULL
INSERT INTO "app"."odd ""name""" DEFAULT VALUES --
`,
		EngineMySQL: "DELETE FROM `app`.`odd \"name\"` WHERE `id` = ? -- \"2\"\n" +
			"UPDATE `app`.`odd \"name\"` SET `e-mail` = ?, `weird``col` = ?, `data` = ?, `tags` = ? WHERE `id` = ? -- \"'; DROP TABLE t; --\" NULL \"0xbeef\" \"{x,\\\"y z\\\"}\" \"1\"\n" +
			"INSERT INTO `app`.`odd \"name\"` (`id`, `e-mail`) VALUES (?, ?) -- \"3\" NULL\n" +
			"INSERT INTO `app`.`odd \"name\"` () VALUES () --\n",
	}
	for engine, want := range golden {
		t.Run(engine, func(t *testing.T) {
			e := newEnv(t)
			def := Definition{ID: "ds-" + engine, Name: "golden", Engine: engine, Host: "localhost", Port: 5432, User: "u", Password: "none"}
			id := syntheticTable(t, e, def, "app", oddTable(), kinds, rows)
			plan := PlanEdits(req(id))
			if plan.Error != nil {
				t.Fatal(plan.Error)
			}
			if got := renderPlan(plan); got != want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestDMLKeysAlwaysInWhere(t *testing.T) {
	info := &tableInfo{Name: "pairs", Kind: "table", Columns: []columnInfo{
		{Name: "tenant", Type: "text"}, {Name: "n", Type: "integer"}, {Name: "v", Type: "text", Nullable: true},
	}, Indexes: []indexInfo{{Name: "u", Unique: true, Columns: []string{"tenant", "n"}}}}
	e := newEnv(t)
	def := Definition{ID: "pg", Name: "pg", Engine: EnginePostgres, Host: "h", Port: 1, User: "u", Password: "none"}
	id := syntheticTable(t, e, def, "public", info, []uint8{KindText, KindInt, KindText}, [][]*string{{s("acme"), s("7"), s("x")}})
	plan := PlanEdits(EditRequest{ResultID: id, Edits: []CellEdit{{Row: 0, Column: 1, Value: "8"}}, Deletes: nil})
	want := `UPDATE "public"."pairs" SET "n" = $1::integer WHERE "tenant" = $2::text AND "n" = $3::integer -- "8" "acme" "7"` + "\n"
	if got := renderPlan(plan); got != want {
		t.Fatalf("got %s", got)
	}
	for _, st := range plan.Statements {
		c := classify(st.SQL, lex(st.SQL, EnginePostgres), EnginePostgres)
		if len(c.risks) != 0 {
			t.Fatalf("generated SQL must never be a risky statement: %v", c.risks)
		}
	}
}

func TestSQLiteAffinityConversion(t *testing.T) {
	cases := []struct {
		decl, in string
		want     any
	}{
		{"INTEGER", "42", int64(42)},
		{"INTEGER", "4.5", "4.5"},
		{"BIGINT", "-7", int64(-7)},
		{"REAL", "1e3", 1000.0},
		{"DOUBLE PRECISION", "x", "x"},
		{"NUMERIC", "10", int64(10)},
		{"DECIMAL(10,2)", "10.25", 10.25},
		{"BOOLEAN", "true", int64(1)},
		{"BOOLEAN", "false", int64(0)},
		{"TEXT", "007", "007"},
		{"VARCHAR(20)", "12", "12"},
		{"", "12", int64(12)},
		{"", "abc", "abc"},
		{"DATETIME", "2026-11-15 10:00:00", "2026-11-15 10:00:00"},
	}
	for _, c := range cases {
		got, problem := editArg(EngineSQLite, columnInfo{Type: c.decl}, sqliteKind(c.decl), []byte(c.in), false)
		if problem != "" || fmt.Sprintf("%T %v", got, got) != fmt.Sprintf("%T %v", c.want, c.want) {
			t.Errorf("%s %q: got %T %v (%s)", c.decl, c.in, got, got, problem)
		}
	}
	got, _ := editArg(EngineSQLite, columnInfo{Type: "BLOB"}, KindBinary, []byte("0x00ff"), false)
	if b, ok := got.([]byte); !ok || len(b) != 2 || b[1] != 0xff {
		t.Fatalf("%v", got)
	}
	if _, problem := editArg(EngineSQLite, columnInfo{Type: "BLOB"}, KindBinary, []byte("zz"), false); problem == "" {
		t.Fatal("binary needs hex")
	}
	if got, _ := editArg(EngineMySQL, columnInfo{Type: "int(11)"}, KindInt, []byte("5"), false); got != "5" {
		t.Fatal("MySQL binds strings")
	}
}
