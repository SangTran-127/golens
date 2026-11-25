package database

import (
	"fmt"
	"sort"
	"testing"
	"time"
)

func fixtureSnapshot(tables, columns int) *snapshot {
	sc := &schemaInfo{Name: "public", IntrospectedAt: "2026-11-15T10:00:00Z"}
	sc.Tables = append(sc.Tables,
		&tableInfo{Name: "orders", Kind: "table", Columns: []columnInfo{{Name: "id", Type: "int8"}, {Name: "customer_id", Type: "int8"}, {Name: "currency", Type: "text"}, {Name: "total", Type: "numeric"}}},
		&tableInfo{Name: "customers", Kind: "table", Columns: []columnInfo{{Name: "id", Type: "int8"}, {Name: "email", Type: "text"}, {Name: "Display Name", Type: "text"}}},
		&tableInfo{Name: "active_customers", Kind: "view", Columns: []columnInfo{{Name: "id", Type: "int8"}}},
	)
	for i := 0; i < tables; i++ {
		t := &tableInfo{Name: fmt.Sprintf("table_%04d", i), Kind: "table"}
		for c := 0; c < columns; c++ {
			t.Columns = append(t.Columns, columnInfo{Name: fmt.Sprintf("col_%02d", c), Type: "text"})
		}
		sc.Tables = append(sc.Tables, t)
	}
	return &snapshot{Version: 1, DefaultSchema: "public", Schemas: []*schemaInfo{sc, {Name: "audit"}}}
}

func withSnapshot(t testing.TB, snap *snapshot) {
	e := &registry{clk: realClock{}}
	e.init()
	e.sources["pg"] = &dataSource{id: "pg", def: Definition{ID: "pg", Name: "local", Engine: EnginePostgres}, snap: snap}
	prev := reg
	reg = e
	t.Cleanup(func() { reg = prev })
}

func labels(items []CompletionItem, kind string) []string {
	var out []string
	for _, it := range items {
		if kind == "" || it.Kind == kind {
			out = append(out, it.Label)
		}
	}
	sort.Strings(out)
	return out
}

func TestCompleteColumnsThroughAlias(t *testing.T) {
	withSnapshot(t, fixtureSnapshot(0, 0))
	text := "SELECT o.cu FROM orders o"
	res := Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: text, CaretByte: 11})
	if res.ReplaceStartByte != 9 || fmt.Sprint(labels(res.Items, "")) != "[currency customer_id]" {
		t.Fatalf("%+v", res)
	}
	if res.Items[0].Detail != "orders · "+map[string]string{"currency": "text", "customer_id": "int8"}[res.Items[0].Label] {
		t.Fatalf("detail %q", res.Items[0].Detail)
	}
	text = "SELECT c. FROM orders o JOIN customers AS c ON c.id = o.customer_id"
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: text, CaretByte: 9})
	if fmt.Sprint(labels(res.Items, "column")) != "[Display Name email id]" {
		t.Fatalf("%+v", res.Items)
	}
	for _, it := range res.Items {
		if it.Label == "Display Name" && it.Insert != `"Display Name"` {
			t.Fatalf("quoting: %q", it.Insert)
		}
	}
}

func TestCompleteClauses(t *testing.T) {
	withSnapshot(t, fixtureSnapshot(0, 0))
	res := Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM cu", CaretByte: 16})
	if fmt.Sprint(labels(res.Items, "table")) != "[customers]" {
		t.Fatalf("%+v", res.Items)
	}
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM a", CaretByte: 15})
	if fmt.Sprint(labels(res.Items, "view")) != "[active_customers]" || fmt.Sprint(labels(res.Items, "schema")) != "[audit]" {
		t.Fatalf("%+v", res.Items)
	}
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM orders WHERE cu", CaretByte: 29})
	if fmt.Sprint(labels(res.Items, "column")) != "[currency customer_id]" || res.Items[0].Kind != "column" {
		t.Fatalf("%+v", res.Items)
	}
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "sel", CaretByte: 3})
	if len(res.Items) != 1 || res.Items[0].Insert != "select" {
		t.Fatalf("keyword case: %+v", res.Items)
	}
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT 'cu", CaretByte: 10})
	if len(res.Items) != 0 {
		t.Fatal("completion inside a string")
	}
	res = Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT 1; SELECT * FROM orders o WHERE o.", CaretByte: 41})
	if len(labels(res.Items, "column")) != 4 {
		t.Fatalf("second statement: %+v", res.Items)
	}
}

func TestCompleteWithoutSnapshotGivesHint(t *testing.T) {
	withSnapshot(t, nil)
	schemaCacheRoot = t.TempDir()
	t.Cleanup(func() { schemaCacheRoot = "" })
	res := Complete(CompleteRequest{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM ", CaretByte: 14})
	if res.Hint != "Connect to local to complete table and column names." || len(labels(res.Items, "table")) != 0 {
		t.Fatalf("%+v", res)
	}
}

func BenchmarkComplete(b *testing.B) {
	withSnapshot(b, fixtureSnapshot(2000, 20))
	reqs := []CompleteRequest{
		{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM table_1", CaretByte: 21},
		{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT t. FROM table_0042 t JOIN orders o ON o.id = t.col_01", CaretByte: 9},
		{DataSourceID: "pg", Dialect: "postgres", Text: "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id WHERE ", CaretByte: 70},
	}
	durations := make([]time.Duration, 0, b.N)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		start := time.Now()
		Complete(reqs[i%len(reqs)])
		durations = append(durations, time.Since(start))
	}
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	b.ReportMetric(float64(durations[len(durations)*95/100].Microseconds())/1000, "p95-ms")
}
