package database

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

type ExplainRequest struct {
	ExecuteRequest
	Analyze bool `json:"analyze"`
}

type PlanNode struct {
	ID       int      `json:"id"`
	Parent   *int     `json:"parent"`
	Label    string   `json:"label"`
	Relation string   `json:"relation"`
	EstRows  *float64 `json:"estRows"`
	ActRows  *float64 `json:"actRows"`
	Loops    *float64 `json:"loops"`
	Cost     *float64 `json:"cost"`
	TimeMs   *float64 `json:"timeMs"`
	Detail   string   `json:"detail"`
	selfCost *float64
}

func roundMs(v float64) float64 { return math.Round(v*10000) / 10000 }

type Plan struct {
	Format        string     `json:"format"`
	Nodes         []PlanNode `json:"nodes"`
	MostExpensive *int       `json:"mostExpensive"`
	PlanningMs    *float64   `json:"planningMs"`
	ExecutionMs   *float64   `json:"executionMs"`
	ActualRows    *int64     `json:"actualRows"`
	Raw           string     `json:"raw"`
}

type ExplainResult struct {
	Plan       *Plan         `json:"plan"`
	Analyzed   bool          `json:"analyzed"`
	RolledBack bool          `json:"rolledBack"`
	Blocked    []Blocked     `json:"blocked"`
	Session    *SessionState `json:"session"`
	Error      *Error        `json:"error"`
}

type planBuilder struct {
	plan Plan
}

func (b *planBuilder) add(parent *int, n PlanNode) int {
	n.ID = len(b.plan.Nodes)
	n.Parent = parent
	b.plan.Nodes = append(b.plan.Nodes, n)
	return n.ID
}

func fptr(v float64) *float64 { return &v }

func detailLines(fields map[string]any, skip map[string]bool) string {
	keys := make([]string, 0, len(fields))
	for k := range fields {
		if !skip[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var lines []string
	for _, k := range keys {
		lines = append(lines, k+": "+scalarText(fields[k]))
	}
	return strings.Join(lines, "\n")
}

func scalarText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case json.Number:
		return x.String()
	case bool:
		if x {
			return "true"
		}
		return "false"
	case nil:
		return "null"
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = scalarText(e)
		}
		return strings.Join(parts, ", ")
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func numberOf(v any) (float64, bool) {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case string:
		var f float64
		_, err := fmt.Sscan(x, &f)
		return f, err == nil
	case float64:
		return x, true
	}
	return 0, false
}

func numPtr(v any) *float64 {
	if f, ok := numberOf(v); ok {
		return &f
	}
	return nil
}

func decodeJSON(raw string, v any) error {
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	return dec.Decode(v)
}

func (p *Plan) markMostExpensive() {
	if len(p.Nodes) == 0 {
		return
	}
	children := map[int][]int{}
	for _, n := range p.Nodes {
		if n.Parent != nil {
			children[*n.Parent] = append(children[*n.Parent], n.ID)
		}
	}
	useTime := false
	for _, n := range p.Nodes {
		if n.TimeMs != nil {
			useTime = true
		}
	}
	metric := func(n PlanNode) *float64 {
		if useTime {
			return n.TimeMs
		}
		return n.Cost
	}
	var below func(id int) float64
	below = func(id int) float64 {
		sum := 0.0
		for _, c := range children[id] {
			if cm := metric(p.Nodes[c]); cm != nil {
				sum += *cm
			} else {
				sum += below(c)
			}
		}
		return sum
	}
	for i, n := range p.Nodes {
		if n.selfCost != nil {
			v := *n.selfCost + below(n.ID)
			p.Nodes[i].Cost = &v
		}
	}
	best, bestSelf := -1, -1.0
	for _, n := range p.Nodes {
		m := metric(n)
		if m == nil {
			continue
		}
		self := *m - below(n.ID)
		if self > bestSelf {
			best, bestSelf = n.ID, self
		}
	}
	if best >= 0 {
		p.MostExpensive = &best
	}
}

func Explain(req ExplainRequest) (out ExplainResult) {
	out = ExplainResult{Blocked: []Blocked{}}
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		out.Session = &SessionState{State: "notConnected", Transaction: "idle", Mode: ModeAuto}
		out.Error = newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")
		return out
	}
	def := ds.definition()
	if req.Mode == "all" {
		req.Mode = "caret"
	}
	items := selectItems(req.ExecuteRequest, def.Engine)
	s := reg.sessionFor(req.ConsoleID, ds)
	if len(items) == 0 {
		out.Session = s.snapshotState()
		out.Error = newError("syntax", "There is no SQL statement to explain here.")
		return out
	}
	it := items[0]
	it.bound = bindParams(it.text, def.Engine, req.Parameters)
	if len(it.bound.missing) > 0 {
		out.Session = s.snapshotState()
		out.Error = missingParamsError(it.bound.missing)
		return out
	}
	if it.class.kind == "explain" {
		out.Session = s.snapshotState()
		out.Error = newError("unsupported", "This statement is already an EXPLAIN. Run it with Run Statement instead.")
		return out
	}
	if req.Analyze && it.class.writes {
		switch {
		case def.Engine == EngineMySQL:
			out.Session = s.snapshotState()
			out.Error = newError("unsupported", "MySQL can analyze only SELECT statements, so GoLens did not run this "+strings.ToUpper(it.class.kind)+". Use Explain Plan to see its estimated plan.")
			return out
		case def.Engine == EngineSQLite:
			out.Session = s.snapshotState()
			out.Error = newError("unsupported", "SQLite can't measure a statement that changes data, so GoLens did not run it. Use Explain Plan to see its plan.")
			return out
		case def.ReadOnly:
			out.Session = s.snapshotState()
			out.Error = newError("readOnly", def.Name+" is read-only, so GoLens did not analyze this statement. Turn off Read-only in Edit Data Source to allow it.")
			return out
		case def.Production:
			h := statementHash(it.text)
			confirmed := false
			for _, c := range req.Confirmed {
				if c.Hash == h && c.Risk == RiskProductionWrite {
					confirmed = true
				}
			}
			if !confirmed {
				out.Blocked = append(out.Blocked, Blocked{Index: it.index, Hash: h, Risk: RiskProductionWrite, Table: it.class.table, Line: it.line, Preview: preview(it.text)})
				out.Session = s.snapshotState()
				return out
			}
		}
	}
	release := s.acquire(req.ExecID, true)
	defer release()
	defer func() { out.Session = s.stateLocked() }()
	if e := s.connectLocked(); e != nil {
		out.Error = e
		return out
	}
	var plan *Plan
	var err error
	switch def.Engine {
	case EnginePostgres:
		plan, out.RolledBack, err = s.explainPostgres(&it, req.Analyze)
	case EngineMySQL:
		plan, err = s.explainMySQL(&it, req.Analyze)
	default:
		plan, err = s.explainSQLite(&it, req.Analyze)
	}
	if err != nil {
		out.Error = s.statementError(err, it, req.ExecuteRequest)
		return out
	}
	out.Plan = plan
	out.Analyzed = req.Analyze
	return out
}

func (s *session) queryLocked(sql string, args []any) ([][]string, error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.setRunning(s.conn, cancel)
	defer s.setRunning(nil, nil)
	return queryArgs(ctx, s.conn, sql, args)
}

func joinRows(rows [][]string) string {
	var b bytes.Buffer
	for i, r := range rows {
		if i > 0 {
			b.WriteByte('\n')
		}
		if len(r) > 0 {
			b.WriteString(r[0])
		}
	}
	return b.String()
}

func (it *runItem) prefix(p string) string {
	sql := it.text
	if it.bound.sql != "" {
		sql = it.bound.sql
	}
	edits := []rewriteEdit{{origStart: 0, origEnd: 0, newStart: 0, newEnd: len(p)}}
	for _, e := range it.bound.offsets.edits {
		e.newStart += len(p)
		e.newEnd += len(p)
		edits = append(edits, e)
	}
	it.bound.sql = p + sql
	it.bound.offsets.edits = edits
	return it.bound.sql
}

func elapsedMs(start time.Time) *float64 {
	v := ms(time.Since(start))
	return &v
}
