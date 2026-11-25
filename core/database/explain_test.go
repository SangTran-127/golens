package database

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func f2(v *float64) string {
	if v == nil {
		return "-"
	}
	return fmt.Sprintf("%g", *v)
}

func outline(p *Plan) string {
	var b strings.Builder
	depth := map[int]int{}
	for _, n := range p.Nodes {
		d := 0
		if n.Parent != nil {
			d = depth[*n.Parent] + 1
		}
		depth[n.ID] = d
		mark := ""
		if p.MostExpensive != nil && *p.MostExpensive == n.ID {
			mark = " *"
		}
		fmt.Fprintf(&b, "%s%s [%s] est=%s act=%s loops=%s cost=%s ms=%s%s\n", strings.Repeat("  ", d), n.Label, n.Relation,
			f2(n.EstRows), f2(n.ActRows), f2(n.Loops), f2(n.Cost), f2(n.TimeMs), mark)
	}
	return b.String()
}

func recorded(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "explain", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestExplainParsersOnRecordedPlans(t *testing.T) {
	cases := []struct {
		file   string
		parse  func(string) (*Plan, error)
		want   string
		detail string
	}{
		{"postgres-plan.json", parsePostgresPlan, `Sort [] est=4 act=- loops=- cost=2.2 ms=-
  Hash Join [] est=4 act=- loops=- cost=2.15 ms=-
    Seq Scan [golens_ex_users u] est=4 act=- loops=- cost=1.06 ms=- *
    Hash [] est=3 act=- loops=- cost=1.03 ms=-
      Seq Scan [golens_ex_teams t] est=3 act=- loops=- cost=1.03 ms=-
`, "Hash Cond: (u.team_id = t.id)"},
		{"postgres-analyze.json", parsePostgresPlan, "", "Shared Hit Blocks"},
		{"mysql-plan.json", parseMySQLJSONPlan, `Query Block 1 [] est=- act=- loops=- cost=6.3 ms=-
  Sort [] est=- act=- loops=- cost=6.85 ms=- *
    Nested Loop [] est=- act=- loops=- cost=- ms=-
      Full Table Scan [t] est=3 act=- loops=- cost=0.55 ms=-
      Index Lookup [u] est=1 act=- loops=- cost=2.3 ms=-
`, "using_filesort: true"},
		{"mysql-analyze.txt", parseMySQLTreePlan, `Sort [] est=- act=4 loops=1 cost=- ms=0.149
  Stream results [] est=5 act=4 loops=1 cost=2.42 ms=0.117
    Nested loop inner join [] est=5 act=4 loops=1 cost=2.42 ms=0.113
      Table scan on t [t] est=3 act=3 loops=1 cost=0.55 ms=0.0502
      Index lookup on u using golens_ex_users_team (team_id=t.id) [u] est=1.67 act=1.33 loops=3 cost=0.461 ms=0.0594 *
`, "Sort key: u.`name`"},
		{"mariadb-plan.json", parseMySQLJSONPlan, "", "attached_condition"},
		{"mariadb-analyze.json", parseMySQLJSONPlan, "", "r_buffer_size: 382KiB"},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			p, err := c.parse(recorded(t, c.file))
			if err != nil {
				t.Fatal(err)
			}
			got := outline(p)
			if c.want != "" && got != c.want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, c.want)
			}
			if len(p.Nodes) < 3 || p.MostExpensive == nil || p.Raw == "" {
				t.Fatalf("%s\n%+v", got, p)
			}
			found := false
			for _, n := range p.Nodes {
				if strings.Contains(n.Detail, c.detail) {
					found = true
				}
			}
			if !found {
				t.Fatalf("unmapped fields stay as detail text; %q missing:\n%s", c.detail, got)
			}
			t.Logf("\n%s", got)
		})
	}
	pg, _ := parsePostgresPlan(recorded(t, "postgres-analyze.json"))
	if pg.PlanningMs == nil || pg.ExecutionMs == nil || pg.Nodes[0].ActRows == nil || pg.Nodes[0].TimeMs == nil {
		t.Fatalf("%+v", pg)
	}
	maria, _ := parseMySQLJSONPlan(recorded(t, "mariadb-analyze.json"))
	acted := false
	for _, n := range maria.Nodes {
		if n.Relation == "u" && n.ActRows != nil && n.TimeMs != nil {
			acted = true
		}
	}
	if !acted || maria.ExecutionMs == nil {
		t.Fatalf("MariaDB ANALYZE keeps actual rows and time:\n%s", outline(maria))
	}
	future := `[{"Plan": {"Node Type": "Quantum Scan", "Total Cost": 1, "Plan Rows": 2, "Brand New Field": {"x": [1, 2]}}}]`
	fp, err := parsePostgresPlan(future)
	if err != nil || fp.Nodes[0].Detail != `Brand New Field: {"x":[1,2]}` {
		t.Fatalf("%+v %v", fp, err)
	}
}

func TestExplainSQLite(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 200)))
	req := ExplainRequest{ExecuteRequest: ExecuteRequest{ExecID: "x1", ConsoleID: "c1", DataSourceID: "ds1", Mode: "caret",
		Text: "SELECT 1;\nSELECT o.id, c.name FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.customer_id = :c;"}}
	req.CaretByte = 12
	res := Explain(req)
	if res.Error == nil || res.Error.Kind != "needsParameters" {
		t.Fatalf("%+v", res.Error)
	}
	req.Parameters = []ParamValue{{Name: ":c", Value: "1"}}
	res = Explain(req)
	if res.Error != nil || res.Plan == nil || res.Plan.Format != "queryPlan" || len(res.Plan.Nodes) < 2 || res.RolledBack || res.Analyzed {
		t.Fatalf("%+v %+v", res, res.Error)
	}
	relations := map[string]bool{}
	for _, n := range res.Plan.Nodes {
		relations[n.Relation] = true
	}
	if !relations["o"] && !relations["orders"] {
		t.Fatalf("%s", outline(res.Plan))
	}
	req.Analyze = true
	res = Explain(req)
	if res.Error != nil || !res.Analyzed || res.Plan.ActualRows == nil || *res.Plan.ActualRows != 100 || res.Plan.ExecutionMs == nil {
		t.Fatalf("%+v %+v", res.Plan, res.Error)
	}
	del := ExplainRequest{ExecuteRequest: ExecuteRequest{ConsoleID: "c1", DataSourceID: "ds1", Mode: "caret", Text: "DELETE FROM orders"}, Analyze: true}
	res = Explain(del)
	if res.Error == nil || res.Error.Kind != "unsupported" || !strings.Contains(res.Error.Message, "SQLite") {
		t.Fatalf("%+v", res.Error)
	}
	del.Analyze = false
	if res = Explain(del); res.Error != nil || res.Plan == nil {
		t.Fatalf("Explain Plan of a write only plans it: %+v", res.Error)
	}
	if got := flat(rowsOf(t, e, "SELECT count(*) FROM orders")); got != "200\n" {
		t.Fatalf("explain changed data: %q", got)
	}
	bad := Explain(ExplainRequest{ExecuteRequest: ExecuteRequest{ConsoleID: "c1", DataSourceID: "ds1", Text: "SELECT nope FROM orders"}})
	if bad.Error == nil || bad.Error.Position == nil {
		t.Fatalf("%+v", bad.Error)
	}
}
