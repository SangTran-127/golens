package database

import (
	"strings"
	"testing"
)

func relatedDB(e *env) string {
	return e.sqliteDB("related.db",
		`CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)`,
		`CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), note TEXT)`,
		`CREATE TABLE refunds (id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders, reason TEXT)`,
		`CREATE TABLE regions (code TEXT, country TEXT, label TEXT, PRIMARY KEY (code, country))`,
		`CREATE TABLE stores (id INTEGER PRIMARY KEY, region TEXT, country TEXT, FOREIGN KEY (region, country) REFERENCES regions(code, country))`,
		`INSERT INTO customers VALUES (1, 'Ada'), (2, 'O''Brien')`,
		`INSERT INTO orders VALUES (10, 1, 'first'), (11, 2, 'second'), (12, NULL, 'walk-in')`,
		`INSERT INTO refunds VALUES (100, 10, 'damaged'), (101, 10, 'late')`,
		`INSERT INTO regions VALUES ('w', 'us', 'West')`,
		`INSERT INTO stores VALUES (5, 'w', 'us')`,
	)
}

func columnOf(t *testing.T, resp OpenTableResponse, name string) int {
	t.Helper()
	for i, c := range resp.Statements[0].Columns {
		if c.Name == name {
			return i
		}
	}
	t.Fatalf("no column %s", name)
	return -1
}

func TestRelatedRowsBothDirections(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", relatedDB(e)))
	orders := openTable(t, "orders", "", "id")
	if len(orders.ForeignKeyColumns) != 1 || orders.ForeignKeyColumns[0] != columnOf(t, orders, "customer_id") {
		t.Fatalf("foreign key columns = %v", orders.ForeignKeyColumns)
	}
	if len(orders.ReferencingTables) != 1 || orders.ReferencingTables[0].Table != "refunds" || orders.ReferencingTables[0].Columns[0] != "order_id" {
		t.Fatalf("referencing tables = %+v", orders.ReferencingTables)
	}
	rid := orders.Statements[0].ResultID
	res := RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 0, Column: columnOf(t, orders, "customer_id"), Direction: RelatedReferenced})
	if res.Error != nil || len(res.Targets) != 1 {
		t.Fatalf("referenced = %+v", res)
	}
	tg := res.Targets[0]
	if tg.Table != "customers" || tg.Schema != "main" || tg.Where != `"id" = 1` {
		t.Fatalf("target = %+v", tg)
	}
	customers := openTable(t, tg.Table, tg.Where, "")
	if rows := flat(rowsOf(t, e, customers.SQL)); rows != "1|Ada\n" {
		t.Fatalf("referenced row = %q", rows)
	}

	res = RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 2, Column: columnOf(t, orders, "customer_id"), Direction: RelatedReferenced})
	if res.Error == nil || !strings.Contains(res.Error.Message, "NULL") {
		t.Fatalf("a NULL key has no referenced row: %+v", res)
	}
	res = RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 0, Column: columnOf(t, orders, "note"), Direction: RelatedReferenced})
	if res.Error == nil {
		t.Fatal("a column outside a foreign key has no referenced row")
	}

	res = RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 0, Direction: RelatedReferencing})
	if res.Error != nil || len(res.Targets) != 1 || res.Targets[0].Table != "refunds" || res.Targets[0].Where != `"order_id" = 10` {
		t.Fatalf("referencing = %+v", res)
	}
	refunds := openTable(t, "refunds", res.Targets[0].Where, "id")
	if rows := flat(rowsOf(t, e, refunds.SQL)); rows != "100|10|damaged\n101|10|late\n" {
		t.Fatalf("referencing rows = %q", rows)
	}
}

func TestRelatedRowsQuotesTextAndCompositeKeys(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", relatedDB(e)))
	stores := openTable(t, "stores", "", "")
	res := RelatedRows(RelatedRowsRequest{ResultID: stores.Statements[0].ResultID, Row: 0, Column: columnOf(t, stores, "country"), Direction: RelatedReferenced})
	if res.Error != nil || len(res.Targets) != 1 || res.Targets[0].Where != `"code" = 'w' AND "country" = 'us'` {
		t.Fatalf("composite = %+v", res)
	}
	regions := openTable(t, "regions", "", "")
	res = RelatedRows(RelatedRowsRequest{ResultID: regions.Statements[0].ResultID, Row: 0, Direction: RelatedReferencing})
	if res.Error != nil || len(res.Targets) != 1 || res.Targets[0].Where != `"region" = 'w' AND "country" = 'us'` {
		t.Fatalf("composite referencing = %+v", res)
	}
	customers := openTable(t, "customers", "", "id")
	res = RelatedRows(RelatedRowsRequest{ResultID: customers.Statements[0].ResultID, Row: 1, Direction: RelatedReferencing})
	if res.Error != nil || len(res.Targets) != 1 || res.Targets[0].Where != `"customer_id" = 2` {
		t.Fatalf("referencing customers = %+v", res)
	}
	if got := cellLiteral(EngineMySQL, CellValue{Kind: "text", Text: `O'Brien\`}); got != `'O''Brien\\'` {
		t.Fatalf("mysql literal = %s", got)
	}
	if got := cellLiteral(EnginePostgres, CellValue{Kind: "binary", Encoding: "hex", Text: "00ff"}); got != `'\x00ff'::bytea` {
		t.Fatalf("bytea literal = %s", got)
	}
	if got := cellLiteral(EngineSQLite, CellValue{Kind: "float", Text: "NaN"}); got != "'NaN'" {
		t.Fatalf("NaN literal = %s", got)
	}
}

func TestOpenTableSeesATableCreatedAfterTheSchemaWasRead(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", relatedDB(e)))
	openTable(t, "customers", "", "")
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "ddl", Text: "CREATE TABLE notes (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id))"})
	if resp.Error != nil || resp.Statements[0].Error != nil {
		t.Fatalf("create: %+v %+v", resp.Error, resp.Statements)
	}
	notes := openTable(t, "notes", "", "")
	if !notes.Editable || len(notes.ForeignKeyColumns) != 1 {
		t.Fatalf("a new table is read from the schema again: %+v", notes)
	}
}

func TestRelatedRowsNeedATable(t *testing.T) {
	e := newEnv(t)
	e.configure(sqliteDef("ds1", relatedDB(e)))
	resp := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c", Text: "SELECT * FROM orders"})
	res := RelatedRows(RelatedRowsRequest{ResultID: resp.Statements[0].ResultID, Row: 0, Column: 1, Direction: RelatedReferenced})
	if res.Error == nil || res.Error.Kind != "related" {
		t.Fatalf("a console result has no table binding: %+v", res)
	}
	if res = RelatedRows(RelatedRowsRequest{ResultID: "r-missing"}); res.Error == nil {
		t.Fatal("an unknown result is an error")
	}
}
