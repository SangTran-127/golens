package database

import (
	"context"
	"strconv"
	"strings"
)

const reasonNoKey = "This table has no primary key, so GoLens can't identify which rows to change."

type OpenTableRequest struct {
	ExecID        string         `json:"execId"`
	ConsoleID     string         `json:"consoleId"`
	DataSourceID  string         `json:"dataSourceId"`
	WorkspaceRoot string         `json:"workspaceRoot,omitempty"`
	Schema        string         `json:"schema"`
	Table         string         `json:"table"`
	Where         string         `json:"where"`
	OrderBy       string         `json:"orderBy"`
	PageSize      int            `json:"pageSize"`
	Confirmed     []Confirmation `json:"confirmed,omitempty"`
}

type ReadOnlyColumn struct {
	Column int    `json:"column"`
	Reason string `json:"reason"`
}

type OpenTableResponse struct {
	ExecuteResponse
	SQL               string             `json:"sql"`
	Editable          bool               `json:"editable"`
	KeyColumns        []string           `json:"keyColumns"`
	Reason            string             `json:"reason"`
	ReadOnlyColumns   []ReadOnlyColumn   `json:"readOnlyColumns"`
	ForeignKeyColumns []int              `json:"foreignKeyColumns"`
	ReferencingTables []ReferencingTable `json:"referencingTables"`
}

type CountRowsRequest struct {
	ExecID       string `json:"execId"`
	DataSourceID string `json:"dataSourceId"`
	Schema       string `json:"schema"`
	Table        string `json:"table"`
	Where        string `json:"where"`
}

type CountRowsResult struct {
	Count *int64 `json:"count"`
	Error *Error `json:"error"`
}

type tableBinding struct {
	engine   string
	schema   string
	name     string
	info     *tableInfo
	tableCol []int
	keyCols  []int
	editable bool
	reason   string
	readOnly map[int]string
}

func quoteName(dialect, name string) string {
	if normalizeDialect(dialect) == EngineMySQL {
		return "`" + strings.ReplaceAll(name, "`", "``") + "`"
	}
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

func qualifiedName(dialect, schema, table string) string {
	if schema == "" {
		return quoteName(dialect, table)
	}
	return quoteName(dialect, schema) + "." + quoteName(dialect, table)
}

func fragmentError(what string) *Error {
	return newError("syntax", "The "+what+" must be a single expression, without a semicolon or an unclosed quote, comment or parenthesis.")
}

func checkFragment(dialect, fragment, what string) *Error {
	depth := 0
	for _, t := range lex(fragment, dialect) {
		switch {
		case t.kind == tSemicolon:
			return fragmentError(what)
		case punctIs(fragment, t, '('):
			depth++
		case punctIs(fragment, t, ')'):
			depth--
			if depth < 0 {
				return fragmentError(what)
			}
		}
	}
	if depth != 0 {
		return fragmentError(what)
	}
	return nil
}

func tokenStartsAt(toks []token, off int) bool {
	for _, t := range toks {
		if t.start == off {
			return true
		}
		if t.start > off {
			return false
		}
	}
	return off == 0
}

func composeSelect(dialect, head, where, orderBy string) (string, *Error) {
	var b strings.Builder
	b.WriteString(head)
	var boundaries []int
	if w := strings.TrimSpace(where); w != "" {
		if e := checkFragment(dialect, w, "filter"); e != nil {
			return "", e
		}
		b.WriteString("\nWHERE ")
		b.WriteString(w)
		boundaries = append(boundaries, b.Len())
	}
	if o := strings.TrimSpace(orderBy); o != "" {
		if e := checkFragment(dialect, o, "sort order"); e != nil {
			return "", e
		}
		b.WriteString("\nORDER BY ")
		b.WriteString(o)
		boundaries = append(boundaries, b.Len())
	}
	sql := b.String()
	toks := lex(sql+"\n", dialect)
	for _, off := range boundaries {
		if !tokenStartsAt(toks, off) {
			return "", fragmentError("filter or sort order")
		}
	}
	stmts := splitStatements(sql, dialect)
	if len(stmts) != 1 {
		return "", fragmentError("filter or sort order")
	}
	if c := classify(sql, stmts[0].toks, dialect); c.kind != "select" || c.writes {
		return "", fragmentError("filter or sort order")
	}
	return sql, nil
}

func (ds *dataSource) tableInfo(ctx context.Context, schema, table string) (string, *tableInfo, *Error) {
	snap := ds.cachedSnapshot()
	if snap == nil {
		var e *Error
		if snap, e = ds.refreshSnapshot(ctx, schema); e != nil {
			return "", nil, e
		}
	}
	if schema == "" {
		schema = snap.DefaultSchema
	}
	sc := snap.find(schema)
	if sc == nil || sc.IntrospectedAt == "" {
		var e *Error
		if snap, e = ds.refreshSnapshot(ctx, schema); e != nil {
			return schema, nil, e
		}
		sc = snap.find(schema)
	}
	if sc == nil {
		return schema, nil, nil
	}
	if t := findTableInfo(sc, table); t != nil {
		return schema, t, nil
	}
	snap, e := ds.refreshSnapshot(ctx, schema)
	if e != nil {
		return schema, nil, e
	}
	if sc = snap.find(schema); sc != nil {
		return schema, findTableInfo(sc, table), nil
	}
	return schema, nil, nil
}

func findTableInfo(sc *schemaInfo, table string) *tableInfo {
	for _, t := range sc.Tables {
		if t.Name == table {
			return t
		}
	}
	return nil
}

func identityKey(t *tableInfo) []string {
	if t.PrimaryKey != nil && len(t.PrimaryKey.Columns) > 0 {
		return t.PrimaryKey.Columns
	}
	cols := map[string]columnInfo{}
	for _, c := range t.Columns {
		cols[c.Name] = c
	}
	for _, ix := range t.Indexes {
		if !ix.Unique || len(ix.Columns) == 0 {
			continue
		}
		ok := true
		for _, name := range ix.Columns {
			c, found := cols[name]
			if !found || c.Nullable {
				ok = false
				break
			}
		}
		if ok {
			return ix.Columns
		}
	}
	return nil
}

func unsupportedColumn(engine string, c columnInfo) string {
	if engine != EngineMySQL {
		return ""
	}
	t := strings.ToLower(c.Type)
	for _, p := range []string{"geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "bit"} {
		if t == p || strings.HasPrefix(t, p+"(") {
			return "GoLens can't edit " + c.Type + " values yet."
		}
	}
	return ""
}

func bindTable(def Definition, schema string, t *tableInfo, cols []Column) *tableBinding {
	b := &tableBinding{engine: def.Engine, schema: schema, info: t, readOnly: map[int]string{}}
	if t != nil {
		b.name = t.Name
	}
	switch {
	case t == nil:
		b.reason = "GoLens could not find this table in the schema. Refresh the schema and open the table again."
		return b
	case t.Kind == "view":
		b.reason = "This is a view, so GoLens can't change its rows."
		return b
	case def.ReadOnly:
		b.reason = def.Name + " is read-only. Turn off Read-only in Edit Data Source to edit rows."
	}
	byName := map[string]int{}
	for i, c := range t.Columns {
		byName[c.Name] = i
	}
	b.tableCol = make([]int, len(cols))
	for i, c := range cols {
		ti, ok := byName[c.Name]
		if !ok {
			b.tableCol[i] = -1
			b.readOnly[i] = "This column is not part of the table."
			continue
		}
		b.tableCol[i] = ti
		if r := unsupportedColumn(def.Engine, t.Columns[ti]); r != "" {
			b.readOnly[i] = r
		}
	}
	key := identityKey(t)
	if len(key) == 0 {
		if b.reason == "" {
			b.reason = reasonNoKey
		}
		return b
	}
	for _, k := range key {
		found := -1
		for i, c := range cols {
			if c.Name == k && b.tableCol[i] >= 0 {
				found = i
				break
			}
		}
		if found < 0 {
			b.keyCols = nil
			if b.reason == "" {
				b.reason = reasonNoKey
			}
			return b
		}
		b.keyCols = append(b.keyCols, found)
	}
	b.editable = b.reason == ""
	return b
}

func (b *tableBinding) keyNames() []string {
	out := []string{}
	if b == nil || b.info == nil {
		return out
	}
	for _, k := range b.keyCols {
		out = append(out, b.info.Columns[b.tableCol[k]].Name)
	}
	return out
}

func OpenTable(req OpenTableRequest) OpenTableResponse {
	out := OpenTableResponse{ExecuteResponse: ExecuteResponse{ExecID: req.ExecID, Blocked: []Blocked{}, Statements: []StatementResult{}},
		KeyColumns: []string{}, ReadOnlyColumns: []ReadOnlyColumn{}, ForeignKeyColumns: []int{}, ReferencingTables: []ReferencingTable{}}
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		out.Session = &SessionState{State: "notConnected", Transaction: "idle", Mode: ModeAuto}
		out.Error = newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")
		return out
	}
	def := ds.definition()
	schema, info, e := ds.tableInfo(context.Background(), req.Schema, req.Table)
	if e != nil {
		out.Session = reg.sessionFor(req.ConsoleID, ds).snapshotState()
		out.Error = e
		return out
	}
	if def.Engine == EngineSQLite && schema == "" {
		schema = "main"
	}
	sql, e := composeSelect(def.Engine, "SELECT * FROM "+qualifiedName(def.Engine, schema, req.Table), req.Where, req.OrderBy)
	if e != nil {
		out.Session = reg.sessionFor(req.ConsoleID, ds).snapshotState()
		out.Error = e
		return out
	}
	out.SQL = sql
	out.ExecuteResponse = Execute(ExecuteRequest{ExecID: req.ExecID, ConsoleID: req.ConsoleID, DataSourceID: req.DataSourceID,
		WorkspaceRoot: req.WorkspaceRoot, Text: sql, Mode: "all", PageSize: req.PageSize, Confirmed: req.Confirmed, Source: "table"})
	if len(out.Statements) != 1 || out.Statements[0].ResultID == "" {
		return out
	}
	r := lookupResult(out.Statements[0].ResultID)
	if r == nil {
		return out
	}
	b := bindTable(def, schema, info, r.columns)
	if b.name == "" {
		b.name = req.Table
	}
	r.mu.Lock()
	r.table = b
	r.mu.Unlock()
	out.Editable = b.editable
	out.Reason = b.reason
	out.KeyColumns = b.keyNames()
	out.ForeignKeyColumns = foreignKeyColumns(r, b)
	out.ReferencingTables = referencingTables(ds, b)
	for i := range r.columns {
		if reason, ok := b.readOnly[i]; ok {
			out.ReadOnlyColumns = append(out.ReadOnlyColumns, ReadOnlyColumn{Column: i, Reason: reason})
		}
	}
	return out
}

func (r *registry) addOp(id string, cancel func()) func() {
	if id == "" {
		return func() {}
	}
	r.mu.Lock()
	r.init()
	r.ops[id] = cancel
	r.mu.Unlock()
	return func() {
		r.mu.Lock()
		delete(r.ops, id)
		r.mu.Unlock()
	}
}

func CountRows(req CountRowsRequest) CountRowsResult {
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		return CountRowsResult{Error: newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")}
	}
	def := ds.definition()
	schema := req.Schema
	if schema == "" && def.Engine == EngineSQLite {
		schema = "main"
	}
	sql, e := composeSelect(def.Engine, "SELECT count(*) FROM "+qualifiedName(def.Engine, schema, req.Table), req.Where, "")
	if e != nil {
		return CountRowsResult{Error: e}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var value string
	e = ds.withMeta(ctx, func(c engineConn) error {
		done := reg.addOp(req.ExecID, func() { c.interrupt(ds, cancel) })
		defer done()
		var err error
		value, err = queryValue(ctx, c, sql)
		return err
	})
	if e != nil {
		return CountRowsResult{Error: e}
	}
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return CountRowsResult{Error: newError("internal", "GoLens could not read the row count.")}
	}
	return CountRowsResult{Count: &n}
}
