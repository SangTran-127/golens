package database

import (
	"context"
	"strings"
)

type mysqlIntrospector struct{}

func mysqlLiteral(s string) string {
	return "'" + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), "'", "''") + "'"
}

func (mysqlIntrospector) schemas(ctx context.Context, c engineConn) ([]string, string, error) {
	rows, err := queryAll(ctx, c, `SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') ORDER BY SCHEMA_NAME`)
	if err != nil {
		return nil, "", err
	}
	var names []string
	for _, r := range rows {
		names = append(names, r[0])
	}
	return names, c.currentSchema(ctx), nil
}

func (mysqlIntrospector) schema(ctx context.Context, c engineConn, name string) (*schemaInfo, error) {
	lit := mysqlLiteral(name)
	sc := &schemaInfo{Name: name}
	rows, err := queryAll(ctx, c, `SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = `+lit+` ORDER BY TABLE_NAME`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		kind := "table"
		if strings.Contains(r[1], "VIEW") {
			kind = "view"
		}
		sc.Tables = append(sc.Tables, &tableInfo{Name: r[0], Kind: kind})
	}
	tables := indexTables(sc)
	rows, err = queryAll(ctx, c, `SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = `+lit+` ORDER BY TABLE_NAME, ORDINAL_POSITION`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		if t := tables[r[0]]; t != nil {
			t.Columns = append(t.Columns, columnInfo{Name: r[1], Type: r[2], Nullable: r[3] == "YES", Default: r[4]})
		}
	}
	rows, err = queryAll(ctx, c, `SELECT TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = `+lit+` ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		t := tables[r[0]]
		if t == nil {
			continue
		}
		switch {
		case r[1] == "PRIMARY":
			if t.PrimaryKey == nil {
				t.PrimaryKey = &keyInfo{Name: "PRIMARY"}
			}
			t.PrimaryKey.Columns = append(t.PrimaryKey.Columns, r[2])
		case r[4] != "":
			n := len(t.ForeignKeys)
			if n == 0 || t.ForeignKeys[n-1].Name != r[1] {
				t.ForeignKeys = append(t.ForeignKeys, foreignKeyInfo{Name: r[1], RefSchema: r[3], RefTable: r[4]})
				n++
			}
			fk := &t.ForeignKeys[n-1]
			fk.Columns = append(fk.Columns, r[2])
			fk.RefColumns = append(fk.RefColumns, r[5])
		}
	}
	rows, err = queryAll(ctx, c, `SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = `+lit+` ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		t := tables[r[0]]
		if t == nil {
			continue
		}
		n := len(t.Indexes)
		if n == 0 || t.Indexes[n-1].Name != r[1] {
			t.Indexes = append(t.Indexes, indexInfo{Name: r[1], Unique: r[2] == "0"})
			n++
		}
		t.Indexes[n-1].Columns = append(t.Indexes[n-1].Columns, r[3])
	}
	rows, err = queryAll(ctx, c, `SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = `+lit+` ORDER BY ROUTINE_NAME`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		sc.Routines = append(sc.Routines, r[0])
	}
	return sc, nil
}
