package database

import (
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var mysqlLabels = map[string]string{
	"nested_loop": "Nested Loop", "ordering_operation": "Sort", "grouping_operation": "Group", "duplicates_removal": "Remove Duplicates",
	"union_result": "Union", "windowing": "Window", "materialized_from_subquery": "Materialized Subquery", "attached_subqueries": "Subquery",
	"optimized_away_subqueries": "Optimized Away Subquery", "query_specifications": "Union Part", "filesort": "Sort", "read_sorted_file": "Read Sorted",
	"temporary_table": "Temporary Table", "having_condition": "Having", "block-nl-join": "Block Nested Loop Join", "subqueries": "Subquery",
	"query_block": "Query Block",
}

var mysqlAccess = map[string]string{
	"ALL": "Full Table Scan", "index": "Full Index Scan", "range": "Index Range Scan", "ref": "Index Lookup", "eq_ref": "Unique Index Lookup",
	"const": "Constant Lookup", "system": "System Table", "ref_or_null": "Index Lookup Or Null", "index_merge": "Index Merge",
	"fulltext": "Full-Text Search", "unique_subquery": "Unique Subquery", "index_subquery": "Index Subquery",
}

func humanize(key string) string {
	if l, ok := mysqlLabels[key]; ok {
		return l
	}
	words := strings.FieldsFunc(key, func(r rune) bool { return r == '_' || r == '-' })
	for i, w := range words {
		words[i] = strings.ToUpper(w[:1]) + w[1:]
	}
	return strings.Join(words, " ")
}

func parseMySQLJSONPlan(raw string) (*Plan, error) {
	var doc map[string]any
	if err := decodeJSON(raw, &doc); err != nil {
		return nil, err
	}
	qb, ok := doc["query_block"].(map[string]any)
	if !ok {
		return nil, errors.New("plan has no query block")
	}
	b := &planBuilder{plan: Plan{Format: "json", Nodes: []PlanNode{}, Raw: raw}}
	if qo, ok := doc["query_optimization"].(map[string]any); ok {
		b.plan.PlanningMs = numPtr(qo["r_total_time_ms"])
	}
	b.plan.ExecutionMs = numPtr(qb["r_total_time_ms"])
	b.walkMySQL("query_block", qb, nil)
	b.plan.markMostExpensive()
	return &b.plan, nil
}

func (b *planBuilder) walkMySQL(key string, obj map[string]any, parent *int) {
	n := PlanNode{Label: humanize(key)}
	if key == "table" {
		n.Relation = scalarText(obj["table_name"])
		n.Label = mysqlAccess[scalarText(obj["access_type"])]
		if n.Label == "" {
			n.Label = "Table Access"
		}
		n.EstRows = numPtr(obj["rows_examined_per_scan"])
		if n.EstRows == nil {
			n.EstRows = numPtr(obj["rows"])
		}
		n.ActRows = numPtr(obj["r_rows"])
		n.Loops = numPtr(obj["r_loops"])
		if t := numPtr(obj["r_table_time_ms"]); t != nil {
			total := *t
			if o := numPtr(obj["r_other_time_ms"]); o != nil {
				total += *o
			}
			n.TimeMs = &total
		}
	} else {
		n.TimeMs = numPtr(obj["r_total_time_ms"])
		n.Loops = numPtr(obj["r_loops"])
		if key == "query_block" {
			if id := obj["select_id"]; id != nil {
				n.Label += " " + scalarText(id)
			}
		}
	}
	n.Cost = numPtr(obj["cost"])
	scalars := map[string]any{}
	type child struct {
		key string
		val any
	}
	var kids []child
	for k, v := range obj {
		switch x := v.(type) {
		case map[string]any:
			if k == "cost_info" {
				for ck, cv := range x {
					scalars["cost_info."+ck] = cv
				}
				if c := numPtr(x["prefix_cost"]); c != nil {
					n.Cost = c
				} else if c := numPtr(x["query_cost"]); c != nil {
					n.Cost = c
				} else if c := numPtr(x["sort_cost"]); c != nil {
					n.selfCost = c
				} else if c := numPtr(x["read_cost"]); c != nil && n.Cost == nil {
					n.Cost = c
				}
				continue
			}
			if k == "r_engine_stats" {
				for ck, cv := range x {
					scalars["r_engine_stats."+ck] = cv
				}
				continue
			}
			kids = append(kids, child{k, x})
		case []any:
			objects := false
			for _, e := range x {
				if _, ok := e.(map[string]any); ok {
					objects = true
				}
			}
			if objects {
				kids = append(kids, child{k, x})
			} else {
				scalars[k] = v
			}
		default:
			scalars[k] = v
		}
	}
	skip := map[string]bool{"table_name": key == "table", "r_total_time_ms": true}
	n.Detail = detailLines(scalars, skip)
	id := b.add(parent, n)
	sort.SliceStable(kids, func(i, j int) bool { return kids[i].key < kids[j].key })
	for _, c := range kids {
		switch v := c.val.(type) {
		case map[string]any:
			b.walkMySQL(c.key, v, &id)
		case []any:
			group := b.add(&id, PlanNode{Label: humanize(c.key)})
			target := &group
			for _, e := range v {
				m, ok := e.(map[string]any)
				if !ok {
					continue
				}
				if len(m) == 1 {
					for k, inner := range m {
						if im, ok := inner.(map[string]any); ok {
							b.walkMySQL(k, im, target)
							continue
						}
						b.walkMySQL(c.key, m, target)
					}
					continue
				}
				b.walkMySQL(c.key, m, target)
			}
		}
	}
}

var (
	treeLineRe  = regexp.MustCompile(`^(\s*)-> (.*)$`)
	treeCostRe  = regexp.MustCompile(`\(cost=([\d.e+]+)(?:\.\.([\d.e+]+))? rows=([\d.e+]+)\)`)
	treeActRe   = regexp.MustCompile(`\(actual time=([\d.e+]+)\.\.([\d.e+]+) rows=([\d.e+]+) loops=(\d+)\)`)
	treeNeverRe = regexp.MustCompile(`\(never executed\)`)
	treeOnRe    = regexp.MustCompile(` on ` + "`?" + `([^\s` + "`" + `(]+)`)
)

func parseMySQLTreePlan(raw string) (*Plan, error) {
	b := &planBuilder{plan: Plan{Format: "tree", Nodes: []PlanNode{}, Raw: raw}}
	type frame struct {
		indent int
		id     int
	}
	var stack []frame
	for _, line := range strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n") {
		m := treeLineRe.FindStringSubmatch(line)
		if m == nil {
			if t := strings.TrimSpace(line); t != "" && len(b.plan.Nodes) > 0 {
				last := &b.plan.Nodes[len(b.plan.Nodes)-1]
				last.Detail = strings.TrimSpace(last.Detail + "\n" + t)
			}
			continue
		}
		indent := len(m[1])
		text := m[2]
		n := PlanNode{}
		if c := treeCostRe.FindStringSubmatch(text); c != nil {
			last := c[1]
			if c[2] != "" {
				last = c[2]
			}
			n.Cost = parseF(last)
			n.EstRows = parseF(c[3])
		}
		if a := treeActRe.FindStringSubmatch(text); a != nil {
			n.ActRows = parseF(a[3])
			n.Loops = parseF(a[4])
			if t := parseF(a[2]); t != nil && n.Loops != nil {
				v := roundMs(*t * *n.Loops)
				n.TimeMs = &v
			}
		}
		label := text
		if i := strings.Index(label, "  ("); i >= 0 {
			label = label[:i]
		}
		label = strings.TrimSpace(treeNeverRe.ReplaceAllString(label, ""))
		if i := strings.Index(label, ": "); i >= 0 && !strings.HasPrefix(label, "Sort") {
			n.Detail = strings.TrimSpace(label[i+2:])
			label = label[:i]
		} else if strings.HasPrefix(label, "Sort: ") {
			n.Detail = "Sort key: " + strings.TrimPrefix(label, "Sort: ")
			label = "Sort"
		}
		if o := treeOnRe.FindStringSubmatch(label); o != nil {
			n.Relation = o[1]
		}
		if i := strings.Index(label, ", with "); i >= 0 {
			n.Detail = strings.TrimSpace(strings.TrimSpace(label[i+2:]) + "\n" + n.Detail)
			label = label[:i]
		}
		if treeNeverRe.MatchString(text) {
			n.Detail = strings.TrimSpace(n.Detail + "\nnever executed")
		}
		n.Label = label
		for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
			stack = stack[:len(stack)-1]
		}
		var parent *int
		if len(stack) > 0 {
			p := stack[len(stack)-1].id
			parent = &p
		}
		id := b.add(parent, n)
		stack = append(stack, frame{indent, id})
	}
	if len(b.plan.Nodes) == 0 {
		return nil, errors.New("empty plan")
	}
	b.plan.markMostExpensive()
	return &b.plan, nil
}

func parseF(s string) *float64 {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	return &f
}

func (s *session) explainMySQL(it *runItem, analyze bool) (*Plan, error) {
	conn, _ := s.conn.(*mysqlConn)
	maria := conn != nil && conn.mariaDB()
	prefix := "EXPLAIN FORMAT=JSON "
	switch {
	case analyze && maria:
		prefix = "ANALYZE FORMAT=JSON "
	case analyze:
		prefix = "EXPLAIN ANALYZE "
	}
	rows, err := s.queryLocked(it.prefix(prefix), it.bound.args)
	if err != nil {
		return nil, err
	}
	raw := joinRows(rows)
	if analyze && !maria {
		return parseMySQLTreePlan(raw)
	}
	return parseMySQLJSONPlan(raw)
}
