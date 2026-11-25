package database

import "errors"

var pgMapped = map[string]bool{
	"Node Type": true, "Plans": true, "Relation Name": true, "Alias": true, "Plan Rows": true, "Total Cost": true,
	"Actual Rows": true, "Actual Loops": true, "Actual Total Time": true, "Join Type": true,
}

func parsePostgresPlan(raw string) (*Plan, error) {
	var doc []map[string]any
	if err := decodeJSON(raw, &doc); err != nil {
		return nil, err
	}
	if len(doc) == 0 {
		return nil, errors.New("empty plan")
	}
	b := &planBuilder{plan: Plan{Format: "json", Nodes: []PlanNode{}, Raw: raw}}
	top := doc[0]
	b.plan.PlanningMs = numPtr(top["Planning Time"])
	b.plan.ExecutionMs = numPtr(top["Execution Time"])
	root, ok := top["Plan"].(map[string]any)
	if !ok {
		return nil, errors.New("plan has no root node")
	}
	var walk func(node map[string]any, parent *int)
	walk = func(node map[string]any, parent *int) {
		n := PlanNode{Label: scalarText(node["Node Type"]), EstRows: numPtr(node["Plan Rows"]), Cost: numPtr(node["Total Cost"]),
			ActRows: numPtr(node["Actual Rows"]), Loops: numPtr(node["Actual Loops"])}
		if jt, ok := node["Join Type"].(string); ok && jt != "" && jt != "Inner" {
			n.Label += " (" + jt + ")"
		}
		if rel, ok := node["Relation Name"].(string); ok {
			n.Relation = rel
			if alias, ok := node["Alias"].(string); ok && alias != "" && alias != rel {
				n.Relation += " " + alias
			}
		}
		if total := numPtr(node["Actual Total Time"]); total != nil {
			t := *total
			if n.Loops != nil && *n.Loops > 1 {
				t = roundMs(t * *n.Loops)
			}
			n.TimeMs = &t
		}
		n.Detail = detailLines(node, pgMapped)
		id := b.add(parent, n)
		if kids, ok := node["Plans"].([]any); ok {
			for _, k := range kids {
				if m, ok := k.(map[string]any); ok {
					walk(m, &id)
				}
			}
		}
	}
	walk(root, nil)
	b.plan.markMostExpensive()
	return &b.plan, nil
}

func (s *session) explainPostgres(it *runItem, analyze bool) (*Plan, bool, error) {
	prefix := "EXPLAIN (FORMAT JSON) "
	if analyze {
		prefix = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "
	}
	sql := it.prefix(prefix)
	if !analyze {
		rows, err := s.queryLocked(sql, it.bound.args)
		if err != nil {
			return nil, false, err
		}
		p, err := parsePostgresPlan(joinRows(rows))
		return p, false, err
	}
	if s.txLocked() == "failed" {
		return nil, false, errors.New("the open transaction failed; roll it back before analyzing")
	}
	ownTx := s.txLocked() == "idle"
	var err error
	if ownTx {
		_, err = s.execLocked("BEGIN", nil)
	} else {
		_, err = s.execLocked("SAVEPOINT golens_explain", nil)
	}
	if err != nil {
		return nil, false, err
	}
	rows, runErr := s.queryLocked(sql, it.bound.args)
	var undoErr error
	if s.conn != nil {
		if ownTx {
			_, undoErr = s.execLocked("ROLLBACK", nil)
		} else {
			_, undoErr = s.execLocked("ROLLBACK TO SAVEPOINT golens_explain", nil)
			if undoErr == nil {
				_, undoErr = s.execLocked("RELEASE SAVEPOINT golens_explain", nil)
			}
		}
	}
	if runErr != nil {
		return nil, undoErr == nil, runErr
	}
	if undoErr != nil {
		return nil, false, undoErr
	}
	p, err := parsePostgresPlan(joinRows(rows))
	return p, true, err
}
