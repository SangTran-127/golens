package database

import (
	"sort"
	"strings"
)

var sqlKeywords = strings.Fields(`SELECT FROM WHERE AND OR NOT IN IS NULL LIKE ILIKE BETWEEN EXISTS JOIN LEFT RIGHT INNER OUTER FULL CROSS
ON USING GROUP BY ORDER HAVING LIMIT OFFSET AS DISTINCT UNION ALL INTERSECT EXCEPT INSERT INTO VALUES UPDATE SET DELETE
RETURNING CREATE TABLE VIEW INDEX DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE CHECK CONSTRAINT
CASE WHEN THEN ELSE END ASC DESC WITH RECURSIVE BEGIN COMMIT ROLLBACK TRUNCATE EXPLAIN ANALYZE TRUE FALSE CAST
WINDOW OVER PARTITION FETCH FIRST NEXT ROWS ONLY ON CONFLICT DO NOTHING`)

var dialectKeywords = map[string][]string{
	EnginePostgres: strings.Fields(`ILIKE SIMILAR LATERAL MATERIALIZED SCHEMA SEQUENCE SHOW VACUUM COPY LISTEN NOTIFY`),
	EngineMySQL:    strings.Fields(`SHOW DESCRIBE USE REPLACE IGNORE DUPLICATE ENGINE AUTO_INCREMENT STRAIGHT_JOIN DATABASE`),
	EngineSQLite:   strings.Fields(`PRAGMA ATTACH DETACH VACUUM GLOB AUTOINCREMENT WITHOUT ROWID STRICT REPLACE`),
}

var commonFunctions = strings.Fields(`count sum avg min max coalesce nullif lower upper length substring trim round abs
cast now concat replace greatest least`)

var dialectFunctions = map[string][]string{
	EnginePostgres: strings.Fields(`array_agg string_agg json_agg jsonb_agg json_build_object jsonb_build_object to_char to_date
to_timestamp date_trunc extract age current_date current_timestamp gen_random_uuid generate_series row_number rank
dense_rank lag lead unnest array_length position split_part regexp_replace format`),
	EngineMySQL: strings.Fields(`group_concat json_object json_array json_extract date_format str_to_date datediff
date_add date_sub curdate curtime ifnull if uuid row_number rank lag lead last_insert_id char_length`),
	EngineSQLite: strings.Fields(`group_concat json_extract json_object json_array strftime date time datetime julianday
ifnull iif instr printf quote random total typeof unixepoch row_number rank lag lead`),
}

var notAlias = map[string]bool{}

func init() {
	for _, w := range strings.Fields(`WHERE JOIN ON LEFT RIGHT INNER OUTER FULL CROSS NATURAL GROUP ORDER HAVING LIMIT OFFSET SET
USING WINDOW UNION EXCEPT INTERSECT VALUES RETURNING FETCH FOR SELECT FROM AND OR AS WITH STRAIGHT_JOIN LATERAL`) {
		notAlias[w] = true
	}
}

type tableRef struct {
	schema, table, alias string
}

var tableClauses = map[string]bool{"FROM": true, "JOIN": true, "UPDATE": true, "INTO": true, "TABLE": true, "STRAIGHT_JOIN": true}

var exprClauses = map[string]bool{
	"SELECT": true, "WHERE": true, "ON": true, "AND": true, "OR": true, "BY": true, "HAVING": true, "SET": true,
	"RETURNING": true, "WHEN": true, "THEN": true, "ELSE": true, "CASE": true, "NOT": true, "DISTINCT": true,
}

func collectRefs(src string, toks []token) []tableRef {
	var refs []tableRef
	inList := false
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		w := ""
		if t.kind == tWord {
			w = strings.ToUpper(t.text(src))
		}
		switch {
		case tableClauses[w]:
			inList = w == "FROM"
			if i+1 < len(toks) && (toks[i+1].kind == tWord || toks[i+1].kind == tQuoted) && !notAlias[strings.ToUpper(toks[i+1].text(src))] {
				ref, next := parseRef(src, toks, i+1)
				refs = append(refs, ref)
				i = next - 1
			}
		case inList && t.kind == tPunct && src[t.start] == ',':
			if i+1 < len(toks) && (toks[i+1].kind == tWord || toks[i+1].kind == tQuoted) {
				ref, next := parseRef(src, toks, i+1)
				refs = append(refs, ref)
				i = next - 1
			}
		case w != "" && notAlias[w] && w != "AS":
			inList = false
		}
	}
	return refs
}

func parseRef(src string, toks []token, i int) (tableRef, int) {
	var parts []string
	for i < len(toks) && (toks[i].kind == tWord || toks[i].kind == tQuoted) {
		parts = append(parts, unquoteIdent(toks[i].text(src)))
		if i+1 < len(toks) && toks[i+1].kind == tPunct && src[toks[i+1].start] == '.' {
			i += 2
			continue
		}
		i++
		break
	}
	ref := tableRef{}
	if len(parts) > 0 {
		ref.table = parts[len(parts)-1]
	}
	if len(parts) > 1 {
		ref.schema = parts[len(parts)-2]
	}
	if i < len(toks) && toks[i].is(src, "AS") {
		i++
	}
	if i < len(toks) && (toks[i].kind == tWord || toks[i].kind == tQuoted) && !notAlias[strings.ToUpper(toks[i].text(src))] {
		ref.alias = unquoteIdent(toks[i].text(src))
		i++
	}
	return ref, i
}

func needsQuote(name, dialect string) bool {
	if name == "" {
		return true
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		lower := c >= 'a' && c <= 'z'
		upper := c >= 'A' && c <= 'Z'
		digit := c >= '0' && c <= '9'
		if !(lower || c == '_' || (digit && i > 0) || (upper && dialect != EnginePostgres)) {
			return true
		}
	}
	return false
}

func quoteIdent(name, dialect string) string {
	if !needsQuote(name, dialect) {
		return name
	}
	if dialect == EngineMySQL {
		return "`" + strings.ReplaceAll(name, "`", "``") + "`"
	}
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

func Complete(req CompleteRequest) CompleteResult {
	dialect := normalizeDialect(req.Dialect)
	text := req.Text
	caret := max(0, min(req.CaretByte, len(text)))
	out := CompleteResult{ReplaceStartByte: caret, Items: []CompletionItem{}}
	if toks := lex(text[:caret], dialect); len(toks) > 0 {
		if k := toks[len(toks)-1].kind; k == tString || k == tComment || k == tQuoted {
			return out
		}
	}
	start := caret
	for start > 0 && isWordChar(text[start-1]) {
		start--
	}
	out.ReplaceStartByte = start
	prefix := strings.ToLower(text[start:caret])
	qualifier := ""
	if start > 0 && text[start-1] == '.' {
		q := start - 1
		for q > 0 && (isWordChar(text[q-1]) || text[q-1] == '"' || text[q-1] == '`') {
			q--
		}
		qualifier = unquoteIdent(text[q : start-1])
	}
	stmts := splitStatements(text, dialect)
	var stmt statement
	for _, s := range stmts {
		if caret >= s.spanStart && caret <= s.spanEnd {
			stmt = s
		}
	}
	refs := collectRefs(text, stmt.toks)
	clause := ""
	for _, t := range stmt.toks {
		if t.end > start {
			break
		}
		if t.kind == tWord {
			w := strings.ToUpper(t.text(text))
			if tableClauses[w] || exprClauses[w] || w == "VALUES" || w == "LIMIT" {
				clause = w
			}
		}
	}
	var snap *snapshot
	name := ""
	if req.DataSourceID != "" {
		if ds := reg.source(req.DataSourceID); ds != nil {
			snap = ds.cachedSnapshot()
			name = ds.definition().Name
		}
	}
	add := func(label, kind, detail, insert string) {
		if prefix != "" && !strings.HasPrefix(strings.ToLower(label), prefix) {
			return
		}
		out.Items = append(out.Items, CompletionItem{Label: label, Kind: kind, Detail: detail, Insert: insert})
	}
	findTable := func(schema, table string) (*tableInfo, string) {
		if snap == nil {
			return nil, ""
		}
		for _, sc := range snap.Schemas {
			if schema != "" && !strings.EqualFold(sc.Name, schema) {
				continue
			}
			if schema == "" && sc.Name != snap.DefaultSchema {
				continue
			}
			for _, t := range sc.Tables {
				if strings.EqualFold(t.Name, table) {
					return t, sc.Name
				}
			}
		}
		return nil, ""
	}
	addColumns := func(t *tableInfo) {
		for _, c := range t.Columns {
			add(c.Name, "column", t.Name+" · "+c.Type, quoteIdent(c.Name, dialect))
		}
	}
	addTables := func(schema string) {
		if snap == nil {
			return
		}
		for _, sc := range snap.Schemas {
			if sc.Name != schema {
				continue
			}
			for _, t := range sc.Tables {
				add(t.Name, t.Kind, sc.Name, quoteIdent(t.Name, dialect))
			}
		}
	}
	if qualifier != "" {
		for _, r := range refs {
			if strings.EqualFold(r.alias, qualifier) || (r.alias == "" && strings.EqualFold(r.table, qualifier)) {
				if t, _ := findTable(r.schema, r.table); t != nil {
					addColumns(t)
				}
			}
		}
		if len(out.Items) == 0 && snap != nil {
			if sc := snap.find(qualifier); sc != nil {
				addTables(sc.Name)
			} else if t, _ := findTable("", qualifier); t != nil {
				addColumns(t)
			}
		}
		if snap == nil && name != "" {
			out.Hint = "Connect to " + name + " to complete table and column names."
		}
		return finish(out)
	}
	keywords := append(append([]string{}, sqlKeywords...), dialectKeywords[dialect]...)
	switch {
	case tableClauses[clause]:
		if snap != nil {
			addTables(snap.DefaultSchema)
			for _, sc := range snap.Schemas {
				add(sc.Name, "schema", "schema", quoteIdent(sc.Name, dialect))
			}
		}
	case exprClauses[clause]:
		seen := map[*tableInfo]bool{}
		for _, r := range refs {
			if t, _ := findTable(r.schema, r.table); t != nil && !seen[t] {
				seen[t] = true
				addColumns(t)
			}
			if r.alias != "" {
				add(r.alias, "alias", r.table, quoteIdent(r.alias, dialect))
			}
		}
		for _, f := range append(append([]string{}, commonFunctions...), dialectFunctions[dialect]...) {
			add(f, "function", "function", f+"(")
		}
	}
	for _, k := range keywords {
		insert := k
		if prefix != "" && strings.ToLower(text[start:caret]) == text[start:caret] {
			insert = strings.ToLower(k)
		}
		add(k, "keyword", "keyword", insert)
	}
	if snap == nil && name != "" && (tableClauses[clause] || exprClauses[clause]) {
		out.Hint = "Connect to " + name + " to complete table and column names."
	}
	return finish(out)
}

var kindRank = map[string]int{"column": 0, "alias": 1, "table": 2, "view": 3, "schema": 4, "function": 5, "keyword": 6}

func finish(out CompleteResult) CompleteResult {
	seen := map[string]bool{}
	items := out.Items[:0]
	for _, it := range out.Items {
		key := it.Kind + "\x00" + it.Label + "\x00" + it.Detail
		if !seen[key] {
			seen[key] = true
			items = append(items, it)
		}
	}
	sort.SliceStable(items, func(i, j int) bool {
		if kindRank[items[i].Kind] != kindRank[items[j].Kind] {
			return kindRank[items[i].Kind] < kindRank[items[j].Kind]
		}
		return false
	})
	if len(items) > 200 {
		items = items[:200]
	}
	out.Items = items
	return out
}
