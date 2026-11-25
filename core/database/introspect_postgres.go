package database

import (
	"context"
	"strings"
)

type pgIntrospector struct{}

func sqlLiteral(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

const unitSep = "\x1f"

func (pgIntrospector) schemas(ctx context.Context, c engineConn) ([]string, string, error) {
	rows, err := queryAll(ctx, c, `SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema' ORDER BY nspname`)
	if err != nil {
		return nil, "", err
	}
	var names []string
	for _, r := range rows {
		names = append(names, r[0])
	}
	return names, c.currentSchema(ctx), nil
}

func (pgIntrospector) schema(ctx context.Context, c engineConn, name string) (*schemaInfo, error) {
	lit := sqlLiteral(name)
	sc := &schemaInfo{Name: name}
	rows, err := queryAll(ctx, c, `SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = `+lit+` AND c.relkind IN ('r','p','v','m','f') ORDER BY c.relname`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		kind := "table"
		if r[1] == "v" || r[1] == "m" {
			kind = "view"
		}
		sc.Tables = append(sc.Tables, &tableInfo{Name: r[0], Kind: kind})
	}
	tables := indexTables(sc)
	rows, err = queryAll(ctx, c, `SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = `+lit+` AND c.relkind IN ('r','p','v','m','f') AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY c.relname, a.attnum`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		if t := tables[r[0]]; t != nil {
			t.Columns = append(t.Columns, columnInfo{Name: r[1], Type: r[2], Nullable: r[3] != "true", Default: r[4]})
		}
	}
	rows, err = queryAll(ctx, c, `SELECT c.relname, con.conname, con.contype,
array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.n ORDER BY k.o), chr(31)),
rn.nspname, rc.relname,
array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.n ORDER BY k.o), chr(31))
FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_class rc ON rc.oid = con.confrelid LEFT JOIN pg_namespace rn ON rn.oid = rc.relnamespace
WHERE n.nspname = `+lit+` AND con.contype IN ('p','f') ORDER BY c.relname, con.conname`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		t := tables[r[0]]
		if t == nil {
			continue
		}
		cols := splitList(r[3])
		if r[2] == "p" {
			t.PrimaryKey = &keyInfo{Name: r[1], Columns: cols}
		} else {
			t.ForeignKeys = append(t.ForeignKeys, foreignKeyInfo{Name: r[1], Columns: cols, RefSchema: r[4], RefTable: r[5], RefColumns: splitList(r[6])})
		}
	}
	rows, err = queryAll(ctx, c, `SELECT t.relname, i.relname, ix.indisunique,
array_to_string(ARRAY(SELECT pg_get_indexdef(ix.indexrelid, k, true) FROM generate_series(1, ix.indnkeyatts) k), chr(31))
FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = `+lit+` ORDER BY t.relname, i.relname`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		if t := tables[r[0]]; t != nil {
			t.Indexes = append(t.Indexes, indexInfo{Name: r[1], Unique: r[2] == "true", Columns: splitList(r[3])})
		}
	}
	rows, err = queryAll(ctx, c, `SELECT DISTINCT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = `+lit+` ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		sc.Routines = append(sc.Routines, r[0])
	}
	return sc, nil
}

func splitList(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, unitSep)
}
