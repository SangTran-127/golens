package database

import (
	"fmt"
	"testing"
)

const benchRows = 200000

func benchResult(b *testing.B, memLimit int64) *env {
	e := newEnv(b)
	if memLimit > 0 {
		spoolState.limit = memLimit
	}
	e.configure(sqliteDef("ds1", e.sqliteDB("bench.db",
		`CREATE TABLE t (a INTEGER, b TEXT, c REAL, d INTEGER, e TEXT, f NUMERIC, g TEXT, h INTEGER, i TEXT, j REAL)`,
		fmt.Sprintf(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < %d)
INSERT INTO t SELECT x, 'name ' || x, x * 0.25, x %% 100, 'some longer text value ' || x, x * 1.01, NULL, x * 7, 'status', x / 3.0 FROM n`, benchRows))))
	return e
}

func runFetchAll(b *testing.B, e *env) string {
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", Text: "SELECT * FROM t"})
	if resp.Error != nil || resp.Statements[0].Error != nil {
		b.Fatalf("%+v", resp)
	}
	id := resp.Statements[0].ResultID
	if fa := FetchAll(id); !fa.Complete || fa.RowsFetched != benchRows {
		b.Fatalf("%+v", fa)
	}
	return id
}

func BenchmarkFetchAllSQLite(b *testing.B) {
	e := benchResult(b, 0)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		CloseResult(runFetchAll(b, e))
	}
	b.ReportMetric(float64(benchRows*b.N)/b.Elapsed().Seconds(), "rows/s")
}

func benchPages(b *testing.B, memLimit int64) {
	e := benchResult(b, memLimit)
	id := runFetchAll(b, e)
	if memLimit > 0 && GetStats().SpoolDiskBytes == 0 {
		b.Fatal("nothing spilled")
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		first := int64((i * 7919 * 500) % (benchRows - 500))
		if page, ok := FetchPage(id, first, 500); !ok || len(page) == 0 {
			b.Fatal("no page")
		}
	}
}

func BenchmarkFetchPageMemory(b *testing.B) { benchPages(b, 0) }

func BenchmarkFetchPageSpill(b *testing.B) { benchPages(b, 1<<20) }
