package database

import (
	"context"
	"fmt"
	"strings"
)

type sqliteIntrospector struct{}

func sqliteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

func (sqliteIntrospector) schemas(ctx context.Context, c engineConn) ([]string, string, error) {
	rows, err := queryAll(ctx, c, `SELECT name FROM pragma_database_list WHERE name <> 'temp' ORDER BY seq`)
	if err != nil {
		return nil, "", err
	}
	var names []string
	for _, r := range rows {
		names = append(names, r[0])
	}
	return names, "main", nil
}

func (sqliteIntrospector) schema(ctx context.Context, c engineConn, name string) (*schemaInfo, error) {
	master := sqliteIdent(name) + ".sqlite_schema"
	lit := sqlLiteral(name)
	user := `m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\'`
	sc := &schemaInfo{Name: name}
	rows, err := queryAll(ctx, c, `SELECT m.name, m.type FROM `+master+` m WHERE `+user+` ORDER BY m.name`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		sc.Tables = append(sc.Tables, &tableInfo{Name: r[0], Kind: r[1]})
	}
	tables := indexTables(sc)
	rows, err = queryAll(ctx, c, `SELECT m.name, p.name, p.type, p."notnull", p.dflt_value, p.pk FROM `+master+` m
JOIN pragma_table_info(m.name, `+lit+`) p WHERE `+user+` ORDER BY m.name, p.cid`)
	if err != nil {
		return nil, err
	}
	pk := map[string][][2]string{}
	for _, r := range rows {
		t := tables[r[0]]
		if t == nil {
			continue
		}
		t.Columns = append(t.Columns, columnInfo{Name: r[1], Type: strings.ToLower(r[2]), Nullable: r[3] == "0", Default: r[4]})
		if r[5] != "0" && r[5] != "" {
			pk[r[0]] = append(pk[r[0]], [2]string{r[5], r[1]})
		}
	}
	for name, cols := range pk {
		key := &keyInfo{Name: "pk_" + name}
		for i := 1; i <= len(cols); i++ {
			for _, c := range cols {
				if c[0] == fmt.Sprint(i) {
					key.Columns = append(key.Columns, c[1])
				}
			}
		}
		tables[name].PrimaryKey = key
	}
	rows, err = queryAll(ctx, c, `SELECT m.name, p.id, p."table", p."from", p."to" FROM `+master+` m
JOIN pragma_foreign_key_list(m.name, `+lit+`) p WHERE m.type = 'table' ORDER BY m.name, p.id, p.seq`)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		t := tables[r[0]]
		if t == nil {
			continue
		}
		fkName := "fk_" + r[0] + "_" + r[1]
		n := len(t.ForeignKeys)
		if n == 0 || t.ForeignKeys[n-1].Name != fkName {
			t.ForeignKeys = append(t.ForeignKeys, foreignKeyInfo{Name: fkName, RefTable: r[2]})
			n++
		}
		fk := &t.ForeignKeys[n-1]
		fk.Columns = append(fk.Columns, r[3])
		fk.RefColumns = append(fk.RefColumns, r[4])
	}
	rows, err = queryAll(ctx, c, `SELECT m.name, il.name, il."unique", ii.name FROM `+master+` m
JOIN pragma_index_list(m.name, `+lit+`) il JOIN pragma_index_info(il.name, `+lit+`) ii
WHERE m.type = 'table' ORDER BY m.name, il.name, ii.seqno`)
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
			t.Indexes = append(t.Indexes, indexInfo{Name: r[1], Unique: r[2] == "1"})
			n++
		}
		t.Indexes[n-1].Columns = append(t.Indexes[n-1].Columns, r[3])
	}
	return sc, nil
}
