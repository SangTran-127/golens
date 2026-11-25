package database

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
)

var sqliteRelationRe = regexp.MustCompile(`^(?:SCAN|SEARCH)(?: TABLE)? ("[^"]+"|\S+)`)

func parseSQLitePlan(rows [][]string) (*Plan, error) {
	if len(rows) == 0 {
		return nil, errors.New("empty plan")
	}
	b := &planBuilder{plan: Plan{Format: "queryPlan", Nodes: []PlanNode{}}}
	ids := map[string]int{}
	var raw []string
	for _, r := range rows {
		if len(r) < 4 {
			continue
		}
		raw = append(raw, r[0]+"|"+r[1]+"|"+r[3])
		n := PlanNode{Label: r[3]}
		if m := sqliteRelationRe.FindStringSubmatch(r[3]); m != nil {
			n.Relation = unquoteIdent(m[1])
		}
		var parent *int
		if p, ok := ids[r[1]]; ok {
			parent = &p
		}
		ids[r[0]] = b.add(parent, n)
	}
	b.plan.Raw = strings.Join(raw, "\n")
	return &b.plan, nil
}

func (s *session) explainSQLite(it *runItem, analyze bool) (*Plan, error) {
	sql := it.text
	if it.bound.sql != "" {
		sql = it.bound.sql
	}
	args := it.bound.args
	plain := *it
	rows, err := s.queryLocked(it.prefix("EXPLAIN QUERY PLAN "), args)
	if err != nil {
		return nil, err
	}
	p, err := parseSQLitePlan(rows)
	if err != nil || !analyze {
		return p, err
	}
	*it = plain
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.setRunning(s.conn, cancel)
	defer s.setRunning(nil, nil)
	start := time.Now()
	cur, _, err := s.conn.run(ctx, sql, args, classification{kind: "select", returnsRows: true})
	if err != nil {
		return nil, err
	}
	var n int64
	if cur != nil {
		for {
			ch := newChunk(len(cur.columns()))
			more := true
			for !ch.full() && more {
				if more, err = cur.next(ch); err != nil {
					_ = cur.close(true)
					return nil, err
				}
			}
			n += int64(ch.rows)
			if !more {
				break
			}
		}
		_ = cur.close(false)
	}
	p.ExecutionMs = elapsedMs(start)
	p.ActualRows = &n
	return p, nil
}
