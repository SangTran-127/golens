//go:build dbengines

package database

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func engineDef(t *testing.T, engine string) (Definition, string) {
	t.Helper()
	envName := map[string]string{EnginePostgres: "GOLENS_TEST_PG_DSN", EngineMySQL: "GOLENS_TEST_MYSQL_DSN"}[engine]
	id := engine + "-test"
	if strings.HasSuffix(t.Name(), "/mariadb") || strings.Contains(t.Name(), "/mariadb/") {
		envName, id = "GOLENS_TEST_MARIADB_DSN", "mariadb-test"
	}
	raw := os.Getenv(envName)
	if raw == "" {
		t.Skipf("%s is not set; start the engines with scripts/db/engines.sh up or run make test-db (needs Docker)", envName)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("%s: %v", envName, err)
	}
	port, _ := strconv.Atoi(u.Port())
	secret, _ := u.User.Password()
	return Definition{
		ID: id, Name: id, Engine: engine, Host: u.Hostname(), Port: port,
		Database: strings.TrimPrefix(u.Path, "/"), User: u.User.Username(), Password: "keychain",
		SSL: SSL{Mode: "disable"}, DefaultSchema: map[string]string{EnginePostgres: "public", EngineMySQL: strings.TrimPrefix(u.Path, "/")}[engine],
	}, secret
}

func engineEnv(t *testing.T, engine string, mutate func(*Definition)) (*env, Definition) {
	def, secret := engineDef(t, engine)
	if mutate != nil {
		mutate(&def)
	}
	e := newEnv(t)
	e.configure(def)
	SetSecret(def.ID, secret)
	return e, def
}

func forEachEngine(t *testing.T, fn func(t *testing.T, engine string)) {
	for _, target := range []string{EnginePostgres, EngineMySQL, "mariadb"} {
		engine := normalizeDialect(target)
		t.Run(target, func(t *testing.T) { fn(t, engine) })
	}
}

func run(t *testing.T, e *env, def Definition, console, text string) ExecuteResponse {
	t.Helper()
	resp := e.exec(ExecuteRequest{DataSourceID: def.ID, ConsoleID: console, Text: text, PageSize: 500})
	if len(resp.Blocked) > 0 {
		var confirmed []Confirmation
		for _, b := range resp.Blocked {
			confirmed = append(confirmed, Confirmation{Hash: b.Hash, Risk: b.Risk})
		}
		resp = e.exec(ExecuteRequest{DataSourceID: def.ID, ConsoleID: console, Text: text, PageSize: 500, Confirmed: confirmed})
	}
	if resp.Error != nil {
		t.Fatalf("%s: %+v", text, resp.Error)
	}
	for _, s := range resp.Statements {
		if s.Error != nil {
			t.Fatalf("%s: %+v", text, s.Error)
		}
	}
	return resp
}

func TestEngineExecuteAndFetch(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		resp := run(t, e, def, "c1", "SELECT 1 AS a, 'x' AS b; SELECT NULL AS n, 2.50 AS d")
		if len(resp.Statements) != 2 || !resp.Statements[0].Complete || resp.Statements[1].Columns[1].Kind != "decimal" {
			t.Fatalf("%+v", resp.Statements)
		}
		p := mustPage(t, resp.Statements[1].ResultID, 0, 10)
		if !p.Columns[0].Nulls[0] || p.Columns[1].Values[0] != "2.50" {
			t.Fatalf("%+v", p.Columns)
		}
		series := map[string]string{
			EnginePostgres: "SELECT g, 'row ' || g, now() FROM generate_series(1, 100000) g",
			EngineMySQL:    "WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 100000) SELECT g, CONCAT('row ', g), NOW() FROM s",
		}[engine]
		if engine == EngineMySQL && isMariaDB(t) {
			run(t, e, def, "c1", "SET SESSION max_recursive_iterations = 1000000")
		} else if engine == EngineMySQL {
			run(t, e, def, "c1", "SET SESSION cte_max_recursion_depth = 1000000")
		}
		resp = run(t, e, def, "c1", series)
		id := resp.Statements[0].ResultID
		if fa := FetchAll(id); !fa.Complete || fa.RowsFetched != 100000 {
			t.Fatalf("%+v", fa)
		}
		if p := mustPage(t, id, 99990, 50); p.Rows != 10 || p.Columns[0].Values[9] != "100000" {
			t.Fatalf("last page %d", p.Rows)
		}
	})
}

func TestEngineCancelWithinOneSecond(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		sleep := map[string]string{EnginePostgres: "SELECT pg_sleep(30)", EngineMySQL: "SELECT SLEEP(30)"}[engine]
		done := make(chan ExecuteResponse, 1)
		go func() {
			done <- e.exec(ExecuteRequest{ExecID: "sleep", DataSourceID: def.ID, ConsoleID: "c1", Text: sleep})
		}()
		deadline := time.Now().Add(5 * time.Second)
		for !e.log.has("statementStarted", "sleep") {
			if time.Now().After(deadline) {
				t.Fatal("statement never started")
			}
			time.Sleep(5 * time.Millisecond)
		}
		if !Cancel("sleep") {
			t.Fatal("cancel found no running statement")
		}
		start := time.Now()
		select {
		case resp := <-done:
			if d := time.Since(start); d > time.Second {
				t.Fatalf("cancel took %v", d)
			}
			if resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "cancelled" {
				t.Fatalf("%+v", resp.Statements[0])
			}
		case <-time.After(5 * time.Second):
			t.Fatal("cancel did not stop the statement")
		}
		run(t, e, def, "c1", "SELECT 1")
		if engine == EngineMySQL {
			done := make(chan ExecuteResponse, 1)
			go func() {
				done <- e.exec(ExecuteRequest{ExecID: "bench", DataSourceID: def.ID, ConsoleID: "c1", Text: "SELECT BENCHMARK(10000000000, MD5('x'))"})
			}()
			for !Cancel("bench") {
				time.Sleep(20 * time.Millisecond)
			}
			resp := <-done
			if resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "cancelled" {
				t.Fatalf("%+v", resp.Statements[0])
			}
			run(t, e, def, "c1", "SELECT 1")
		}
	})
}

func TestEngineAbandonedCursorIsCheap(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		big := map[string]string{
			EnginePostgres: "SELECT g FROM generate_series(1, 20000000) g",
			EngineMySQL:    "SELECT 1 AS n FROM information_schema.COLUMNS a, information_schema.COLUMNS b, information_schema.COLUMNS c",
		}[engine]
		run(t, e, def, "c1", big)
		start := time.Now()
		run(t, e, def, "c1", "SELECT 2")
		if d := time.Since(start); d > 2*time.Second {
			t.Fatalf("closing a half-read result took %v", d)
		}
	})
}

func TestEngineReadOnlySession(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		run(t, e, def, "w", "DROP TABLE IF EXISTS golens_ro")
		run(t, e, def, "w", "CREATE TABLE golens_ro (id int)")
		ro := def
		ro.ReadOnly = true
		e.configure(ro)
		resp := e.exec(ExecuteRequest{DataSourceID: ro.ID, ConsoleID: "r", Text: "INSERT INTO golens_ro VALUES (1)"})
		if resp.Error == nil || resp.Error.Kind != "readOnly" {
			t.Fatalf("classifier: %+v", resp)
		}
		ds := reg.source(ro.ID)
		s := reg.sessionFor("r", ds)
		req := ExecuteRequest{ExecID: "bypass", ConsoleID: "r", DataSourceID: ro.ID, Text: "INSERT INTO golens_ro VALUES (1)", Mode: "all"}
		items := selectItems(req, engine)
		items[0].class.writes = false
		resp = s.execute(req, items)
		if len(resp.Statements) != 1 || resp.Statements[0].Error == nil || resp.Statements[0].Error.Kind != "readOnly" {
			t.Fatalf("engine: %+v", resp.Statements)
		}
		e.configure(def)
		run(t, e, def, "w", "DROP TABLE golens_ro")
	})
}

func TestEngineTransactionState(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		if resp := run(t, e, def, "c1", "BEGIN"); resp.Session.Transaction != "active" {
			t.Fatalf("%+v", resp.Session)
		}
		if r := CloseConsole("c1", false); r.OK || !r.HadOpenTransaction {
			t.Fatalf("%+v", r)
		}
		if resp := run(t, e, def, "c1", "ROLLBACK"); resp.Session.Transaction != "idle" {
			t.Fatalf("%+v", resp.Session)
		}
		if engine == EnginePostgres {
			resp := e.exec(ExecuteRequest{DataSourceID: def.ID, ConsoleID: "c1", Text: "BEGIN; SELECT 1/0"})
			if resp.Session.Transaction != "failed" {
				t.Fatalf("%+v", resp.Session)
			}
			run(t, e, def, "c1", "ROLLBACK")
		}
	})
}

func TestEngineSSLRequire(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		def, secret := engineDef(t, engine)
		def.SSL.Mode = "require"
		res := TestConnection(TestConnectionRequest{Definition: def, Secret: secret})
		if !res.OK {
			t.Fatalf("%+v", res.Error)
		}
		def.SSL.Mode = "verify-full"
		res = TestConnection(TestConnectionRequest{Definition: def, Secret: secret})
		if res.OK || res.Error.Kind != "tls" {
			t.Fatalf("self-signed certificate should fail verify-full: %+v", res)
		}
		def.SSL.Mode = "disable"
		res = TestConnection(TestConnectionRequest{Definition: def, Secret: secret + "-wrong"})
		if res.OK || res.Error.Kind != "auth" || strings.Contains(fmt.Sprint(res.Error), secret) {
			t.Fatalf("%+v", res.Error)
		}
	})
}

func TestIntrospectLargeSchema(t *testing.T) {
	forEachEngine(t, func(t *testing.T, engine string) {
		e, def := engineEnv(t, engine, nil)
		var b strings.Builder
		switch engine {
		case EnginePostgres:
			b.WriteString("DROP SCHEMA IF EXISTS golens_big CASCADE; CREATE SCHEMA golens_big;\n")
			b.WriteString("DO $$ BEGIN FOR i IN 1..1000 LOOP EXECUTE format('CREATE TABLE golens_big.t%s (id bigint PRIMARY KEY, name text NOT NULL, ref bigint, created_at timestamptz DEFAULT now())', i); END LOOP; END $$;")
			run(t, e, def, "c1", b.String())
		case EngineMySQL:
			run(t, e, def, "c1", "DROP DATABASE IF EXISTS golens_big")
			run(t, e, def, "c1", "CREATE DATABASE golens_big")
			for i := 1; i <= 1000; i++ {
				fmt.Fprintf(&b, "CREATE TABLE golens_big.t%d (id bigint PRIMARY KEY, name varchar(50) NOT NULL, ref bigint, created_at datetime DEFAULT CURRENT_TIMESTAMP);\n", i)
			}
			run(t, e, def, "c1", b.String())
		}
		start := time.Now()
		res := SchemaChildren(SchemaChildrenRequest{DataSourceID: def.ID, Path: []string{"golens_big"}})
		cold := time.Since(start)
		if res.Error != nil || len(res.Nodes) != 1000 {
			t.Fatalf("%d nodes, %+v", len(res.Nodes), res.Error)
		}
		t.Logf("cold introspection of 1,000 tables: %v", cold)
		if cold > 2*time.Second {
			t.Fatalf("cold introspection took %v", cold)
		}
		cols := SchemaChildren(SchemaChildrenRequest{DataSourceID: def.ID, Path: []string{"golens_big", "t1"}})
		if len(cols.Nodes) < 5 {
			t.Fatalf("%+v", cols.Nodes)
		}
		ds := reg.source(def.ID)
		ds.mu.Lock()
		ds.snap = nil
		ds.mu.Unlock()
		start = time.Now()
		Introspect(IntrospectRequest{DataSourceID: def.ID})
		t.Logf("warm load from the disk cache: %v", time.Since(start))
		if time.Since(start) > 50*time.Millisecond {
			t.Fatalf("warm load took %v", time.Since(start))
		}
		run(t, e, def, "c1", map[string]string{EnginePostgres: "DROP SCHEMA golens_big CASCADE", EngineMySQL: "DROP DATABASE golens_big"}[engine])
	})
}
