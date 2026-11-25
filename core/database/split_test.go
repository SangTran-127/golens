package database

import (
	"reflect"
	"strings"
	"testing"
)

func texts(src, dialect string) []string {
	var out []string
	for _, s := range splitStatements(src, dialect) {
		out = append(out, s.text(src))
	}
	return out
}

func TestSplitStatements(t *testing.T) {
	cases := []struct {
		name, dialect, src string
		want               []string
	}{
		{"simple", "postgres", "SELECT 1; SELECT 2;", []string{"SELECT 1", "SELECT 2"}},
		{"no trailing semicolon", "postgres", "SELECT 1;\nSELECT 2\n", []string{"SELECT 1", "SELECT 2"}},
		{"semicolon in string", "postgres", "SELECT 'a;b'; SELECT 'it''s;'", []string{"SELECT 'a;b'", "SELECT 'it''s;'"}},
		{"semicolon in comments", "postgres", "SELECT 1 -- x;y\n; /* a; /* nested; */ b; */ SELECT 2", []string{"SELECT 1", "SELECT 2"}},
		{"leading comment dropped", "postgres", "-- name: GetUser :one\nSELECT * FROM users;", []string{"SELECT * FROM users"}},
		{"comment only tail", "postgres", "SELECT 1;\n-- trailing\n", []string{"SELECT 1"}},
		{"dollar quotes", "postgres", "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT f();",
			[]string{"CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql", "SELECT f()"}},
		{"tagged dollar quotes", "postgres", "SELECT $fn$ a; $$ b $fn$; SELECT $1;", []string{"SELECT $fn$ a; $$ b $fn$", "SELECT $1"}},
		{"escape string", "postgres", `SELECT E'a\';b'; SELECT 2`, []string{`SELECT E'a\';b'`, "SELECT 2"}},
		{"quoted identifier", "postgres", `SELECT "a;b" FROM t; SELECT 2`, []string{`SELECT "a;b" FROM t`, "SELECT 2"}},
		{"begin atomic", "postgres", "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT CASE WHEN true THEN 2 END; END; SELECT 3;",
			[]string{"CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT CASE WHEN true THEN 2 END; END", "SELECT 3"}},
		{"plain begin is a statement", "postgres", "BEGIN; UPDATE t SET a = 1 WHERE id = 2; COMMIT;", []string{"BEGIN", "UPDATE t SET a = 1 WHERE id = 2", "COMMIT"}},
		{"mysql backslash string", "mysql", `SELECT 'a\';b'; SELECT 2`, []string{`SELECT 'a\';b'`, "SELECT 2"}},
		{"mysql hash comment", "mysql", "SELECT 1 # c;d\n; SELECT 2", []string{"SELECT 1", "SELECT 2"}},
		{"mysql backticks", "mysql", "SELECT `a;b` FROM t; SELECT 2", []string{"SELECT `a;b` FROM t", "SELECT 2"}},
		{"mysql delimiter", "mysql", "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nCALL p();",
			[]string{"CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()"}},
		{"mysql procedure without delimiter", "mysql", "CREATE PROCEDURE p() BEGIN IF 1 THEN SELECT 1; END IF; WHILE 0 DO SELECT 2; END WHILE; END; SELECT 3;",
			[]string{"CREATE PROCEDURE p() BEGIN IF 1 THEN SELECT 1; END IF; WHILE 0 DO SELECT 2; END WHILE; END", "SELECT 3"}},
		{"sqlite trigger", "sqlite", "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE u SET n = CASE WHEN n IS NULL THEN 1 ELSE n + 1 END; DELETE FROM v WHERE id = 1; END; SELECT 1;",
			[]string{"CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE u SET n = CASE WHEN n IS NULL THEN 1 ELSE n + 1 END; DELETE FROM v WHERE id = 1; END", "SELECT 1"}},
		{"sqlite brackets", "sqlite", "SELECT [a;b] FROM t; SELECT 2", []string{"SELECT [a;b] FROM t", "SELECT 2"}},
		{"sqlite begin transaction", "sqlite", "BEGIN; INSERT INTO t VALUES (1); END;", []string{"BEGIN", "INSERT INTO t VALUES (1)", "END"}},
		{"unterminated string", "postgres", "SELECT 'abc; SELECT 2", []string{"SELECT 'abc; SELECT 2"}},
		{"empty", "postgres", " ;; \n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := texts(c.src, c.dialect)
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got %q\nwant %q", got, c.want)
			}
		})
	}
}

func TestStatementLinesAndCaret(t *testing.T) {
	src := "SELECT 1;\n\n  SELECT 2;  \n-- note\nSELECT 3"
	st := splitStatements(src, "postgres")
	if len(st) != 3 || st[0].line != 1 || st[1].line != 3 || st[2].line != 5 {
		t.Fatalf("lines: %+v", st)
	}
	cases := map[int]int{0: 0, 5: 0, 9: 0, 10: 1, 13: 1, 22: 1, 24: 1, 26: 2, len(src): 2}
	for caret, want := range cases {
		if got := statementAtCaret(st, src, caret); got != want {
			t.Errorf("caret %d: got %d want %d", caret, got, want)
		}
	}
}

func classOf(src, dialect string) classification {
	st := splitStatements(src, dialect)
	return classify(src, st[0].toks, dialect)
}

func TestClassify(t *testing.T) {
	cases := []struct {
		src, dialect, kind string
		writes             bool
		risks              []string
		table              string
	}{
		{"SELECT * FROM t", "postgres", "select", false, nil, ""},
		{"(SELECT 1) UNION (SELECT 2)", "postgres", "select", false, nil, ""},
		{"select * into backup from t", "postgres", "select", true, nil, ""},
		{"DELETE FROM orders", "postgres", "delete", true, []string{RiskDeleteWithoutWhere}, "orders"},
		{"DELETE FROM public.orders WHERE id = 1", "postgres", "delete", true, nil, "public.orders"},
		{"DELETE FROM t WHERE id IN (SELECT id FROM u WHERE x)", "postgres", "delete", true, nil, "t"},
		{"UPDATE t SET a = (SELECT b FROM u WHERE u.id = 1)", "postgres", "update", true, []string{RiskUpdateWithoutWhere}, "t"},
		{"update \"Order\" set a = 1 where id = 2", "postgres", "update", true, nil, "Order"},
		{"UPDATE LOW_PRIORITY `t` SET a = 1", "mysql", "update", true, []string{RiskUpdateWithoutWhere}, "t"},
		{"DELETE FROM t LIMIT 10", "mysql", "delete", true, []string{RiskDeleteWithoutWhere}, "t"},
		{"TRUNCATE TABLE logs", "postgres", "ddl", true, []string{RiskTruncate}, "logs"},
		{"DROP TABLE IF EXISTS a.b", "postgres", "ddl", true, []string{RiskDropTable}, "a.b"},
		{"drop schema s cascade", "postgres", "ddl", true, []string{RiskDropSchema}, "s"},
		{"DROP DATABASE app", "mysql", "ddl", true, []string{RiskDropDatabase}, "app"},
		{"DROP INDEX i", "postgres", "ddl", true, nil, ""},
		{"CREATE TABLE t (id int)", "sqlite", "ddl", true, nil, ""},
		{"WITH x AS (SELECT 1) SELECT * FROM x", "postgres", "select", false, nil, ""},
		{"WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", "postgres", "select", true, nil, ""},
		{"WITH x AS (SELECT id FROM t FOR UPDATE) SELECT * FROM x", "postgres", "select", false, nil, ""},
		{"WITH x AS (SELECT 1) DELETE FROM t", "postgres", "delete", true, []string{RiskDeleteWithoutWhere}, "t"},
		{"EXPLAIN SELECT 1", "postgres", "explain", false, nil, ""},
		{"EXPLAIN DELETE FROM t", "postgres", "explain", false, nil, ""},
		{"EXPLAIN ANALYZE DELETE FROM t", "postgres", "explain", true, []string{RiskDeleteWithoutWhere}, "t"},
		{"EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1 WHERE id = 1", "postgres", "explain", true, nil, "t"},
		{"INSERT INTO t VALUES (1)", "postgres", "insert", true, nil, ""},
		{"BEGIN", "postgres", "transaction", false, nil, ""},
		{"BEGIN READ WRITE", "postgres", "transaction", true, nil, ""},
		{"START TRANSACTION READ WRITE", "mysql", "transaction", true, nil, ""},
		{"SET search_path = app", "postgres", "session", false, nil, ""},
		{"SET default_transaction_read_only = off", "postgres", "session", true, nil, ""},
		{"SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "postgres", "session", true, nil, ""},
		{"SET SESSION TRANSACTION READ WRITE", "mysql", "session", true, nil, ""},
		{"SET @@transaction_read_only = 0", "mysql", "session", true, nil, ""},
		{"PRAGMA table_info(t)", "sqlite", "session", false, nil, ""},
		{"PRAGMA query_only = 0", "sqlite", "session", true, nil, ""},
		{"PRAGMA query_only(0)", "sqlite", "session", true, nil, ""},
		{"PRAGMA user_version", "sqlite", "session", false, nil, ""},
		{"VACUUM", "sqlite", "other", true, nil, ""},
		{"CALL p()", "mysql", "other", true, nil, ""},
		{"SHOW TABLES", "mysql", "other", false, nil, ""},
	}
	for _, c := range cases {
		got := classOf(c.src, c.dialect)
		if got.kind != c.kind || got.writes != c.writes || !reflect.DeepEqual(got.risks, c.risks) || got.table != c.table {
			t.Errorf("%s: got kind=%s writes=%v risks=%v table=%q", c.src, got.kind, got.writes, got.risks, got.table)
		}
	}
}

func TestStatementsExport(t *testing.T) {
	src := "SELECT * FROM users;\nDELETE FROM orders;\nDROP TABLE x;"
	got := Statements(src, "postgres")
	if len(got) != 3 || got[1].Risks[0] != RiskDeleteWithoutWhere || got[2].Risks[0] != RiskDropTable || got[0].Writes || got[1].Line != 2 {
		t.Fatalf("%+v", got)
	}
	if src[got[1].StartByte:got[1].EndByte] != "DELETE FROM orders" {
		t.Fatalf("range %q", src[got[1].StartByte:got[1].EndByte])
	}
}

func FuzzSplit(f *testing.F) {
	for _, s := range []string{"SELECT 1; SELECT 'a;b';", "CREATE TRIGGER t BEGIN SELECT 1; END;", "DELIMITER //\nSELECT 1//", "$$a;$$;", "/* /* */ */;", "E'\\'';"} {
		f.Add(s, uint8(0))
		f.Add(s, uint8(1))
		f.Add(s, uint8(2))
	}
	f.Fuzz(func(t *testing.T, src string, d uint8) {
		dialect := []string{"postgres", "mysql", "sqlite"}[d%3]
		toks := lex(src, dialect)
		pos := 0
		for _, tk := range toks {
			if tk.start != pos || tk.end <= tk.start {
				t.Fatalf("token gap at %d: %+v", pos, tk)
			}
			pos = tk.end
		}
		if pos != len(src) {
			t.Fatalf("lexer stopped at %d of %d", pos, len(src))
		}
		prev := 0
		for _, st := range splitStatements(src, dialect) {
			if st.start < prev || st.end < st.start || st.end > len(src) || st.spanEnd < st.end {
				t.Fatalf("bad span %+v", st)
			}
			if strings.TrimSpace(st.text(src)) == "" {
				t.Fatalf("empty statement")
			}
			prev = st.end
			_ = classify(src, st.toks, dialect)
		}
		_ = Statements(src, dialect)
	})
}
