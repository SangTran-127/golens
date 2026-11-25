package database

import (
	"context"
	"strconv"
	"strings"
)

const (
	RelatedReferenced  = "referenced"
	RelatedReferencing = "referencing"
)

type RelatedRowsRequest struct {
	ResultID  string `json:"resultId"`
	Row       int64  `json:"row"`
	Column    int    `json:"column"`
	Direction string `json:"direction"`
}

type RelatedTarget struct {
	Schema     string   `json:"schema"`
	Table      string   `json:"table"`
	Where      string   `json:"where"`
	Columns    []string `json:"columns"`
	Constraint string   `json:"constraint"`
}

type RelatedRowsResult struct {
	Targets []RelatedTarget `json:"targets"`
	Error   *Error          `json:"error"`
}

type ReferencingTable struct {
	Schema     string   `json:"schema"`
	Table      string   `json:"table"`
	Columns    []string `json:"columns"`
	Constraint string   `json:"constraint"`
}

func cellLiteral(dialect string, v CellValue) string {
	if v.Encoding == "hex" {
		if dialect == EnginePostgres {
			return `'\x` + v.Text + `'::bytea`
		}
		return "X'" + v.Text + "'"
	}
	switch v.Kind {
	case "int", "float", "decimal":
		if _, err := strconv.ParseFloat(v.Text, 64); err == nil && !strings.ContainsAny(v.Text, "xXnN") {
			return v.Text
		}
	}
	s := strings.ReplaceAll(v.Text, "'", "''")
	if dialect == EngineMySQL {
		s = strings.ReplaceAll(s, `\`, `\\`)
	}
	return "'" + s + "'"
}

func columnIndex(r *result, name string) int {
	b := r.table
	for i, c := range r.columns {
		if c.Name == name && (b == nil || b.tableCol == nil || b.tableCol[i] >= 0) {
			return i
		}
	}
	return -1
}

func refColumns(fk foreignKeyInfo, ref *tableInfo) []string {
	cols := fk.RefColumns
	missing := len(cols) != len(fk.Columns)
	for _, c := range cols {
		if c == "" {
			missing = true
		}
	}
	if missing && ref != nil {
		cols = identityKey(ref)
	}
	if len(cols) != len(fk.Columns) {
		return nil
	}
	return cols
}

func rowWhere(dialect string, r *result, row int64, from, to []string) (string, bool) {
	parts := make([]string, 0, len(from))
	for i, name := range from {
		col := columnIndex(r, name)
		if col < 0 {
			return "", false
		}
		v := r.cell(row, col, 0)
		if v.Error != nil || v.IsNull || v.Truncated {
			return "", false
		}
		parts = append(parts, quoteName(dialect, to[i])+" = "+cellLiteral(dialect, v))
	}
	return strings.Join(parts, " AND "), true
}

func (b *tableBinding) schemaOrDefault() string {
	if b.schema == "" && b.engine == EngineSQLite {
		return "main"
	}
	return b.schema
}

func sameSchema(engine, fkSchema, holder, target string) bool {
	if fkSchema == "" {
		return holder == target || (engine == EngineSQLite && target == "main")
	}
	return fkSchema == target
}

type referencingKey struct {
	schema, table string
	fk            foreignKeyInfo
}

func referencingKeys(ds *dataSource, b *tableBinding) []referencingKey {
	var out []referencingKey
	snap := ds.cachedSnapshot()
	if snap == nil || b == nil || b.info == nil {
		return out
	}
	target := b.schemaOrDefault()
	for _, sc := range snap.Schemas {
		for _, t := range sc.Tables {
			for _, fk := range t.ForeignKeys {
				if fk.RefTable == b.name && sameSchema(b.engine, fk.RefSchema, sc.Name, target) && refColumns(fk, b.info) != nil {
					out = append(out, referencingKey{schema: sc.Name, table: t.Name, fk: fk})
				}
			}
		}
	}
	return out
}

func referencingTables(ds *dataSource, b *tableBinding) []ReferencingTable {
	out := []ReferencingTable{}
	for _, k := range referencingKeys(ds, b) {
		out = append(out, ReferencingTable{Schema: k.schema, Table: k.table, Columns: k.fk.Columns, Constraint: k.fk.Name})
	}
	return out
}

func foreignKeyColumns(r *result, b *tableBinding) []int {
	out := []int{}
	if b == nil || b.info == nil {
		return out
	}
	for i := range r.columns {
		if b.tableCol == nil || b.tableCol[i] < 0 {
			continue
		}
		name := b.info.Columns[b.tableCol[i]].Name
		for _, fk := range b.info.ForeignKeys {
			if containsString(fk.Columns, name) {
				out = append(out, i)
				break
			}
		}
	}
	return out
}

func RelatedRows(req RelatedRowsRequest) RelatedRowsResult {
	out := RelatedRowsResult{Targets: []RelatedTarget{}}
	r := lookupResult(req.ResultID)
	if r == nil {
		out.Error = newError("internal", "That result is no longer available. Open the table again.")
		return out
	}
	r.mu.Lock()
	b := r.table
	r.mu.Unlock()
	if b == nil || b.info == nil {
		out.Error = newError("related", "Related rows are available in a table opened from the schema outline.")
		return out
	}
	ds := r.sess.ds
	dialect := b.engine
	switch req.Direction {
	case RelatedReferenced:
		if req.Column < 0 || req.Column >= len(r.columns) || b.tableCol[req.Column] < 0 {
			out.Error = newError("related", "This column is not part of the table.")
			return out
		}
		name := b.info.Columns[b.tableCol[req.Column]].Name
		for _, fk := range b.info.ForeignKeys {
			if !containsString(fk.Columns, name) {
				continue
			}
			refSchema := fk.RefSchema
			if refSchema == "" {
				refSchema = b.schemaOrDefault()
			}
			_, ref, e := ds.tableInfo(context.Background(), refSchema, fk.RefTable)
			if e != nil {
				out.Error = e
				return out
			}
			cols := refColumns(fk, ref)
			if cols == nil {
				out.Error = newError("related", "GoLens could not tell which columns of “"+fk.RefTable+"” this key points to.")
				return out
			}
			where, ok := rowWhere(dialect, r, req.Row, fk.Columns, cols)
			if !ok {
				out.Error = newError("related", "This row doesn’t reference a row in “"+fk.RefTable+"” because "+strings.Join(fk.Columns, ", ")+" is NULL.")
				return out
			}
			out.Targets = append(out.Targets, RelatedTarget{Schema: refSchema, Table: fk.RefTable, Where: where, Columns: cols, Constraint: fk.Name})
		}
		if len(out.Targets) == 0 {
			out.Error = newError("related", "“"+name+"” is not part of a foreign key.")
		}
	case RelatedReferencing:
		for _, k := range referencingKeys(ds, b) {
			where, ok := rowWhere(dialect, r, req.Row, refColumns(k.fk, b.info), k.fk.Columns)
			if ok {
				out.Targets = append(out.Targets, RelatedTarget{Schema: k.schema, Table: k.table, Where: where, Columns: k.fk.Columns, Constraint: k.fk.Name})
			}
		}
	default:
		out.Error = newError("internal", "GoLens could not read the related rows request.")
	}
	return out
}
