package database

import (
	"encoding/hex"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

type CellEdit struct {
	Row    int64  `json:"row"`
	Column int    `json:"column"`
	Value  string `json:"value"`
	IsNull bool   `json:"isNull"`
}

type InsertCell struct {
	Column int    `json:"column"`
	Value  string `json:"value"`
	IsNull bool   `json:"isNull"`
}

type RowInsert struct {
	Cells []InsertCell `json:"cells"`
}

type EditRequest struct {
	ExecID    string         `json:"execId,omitempty"`
	ResultID  string         `json:"resultId"`
	Edits     []CellEdit     `json:"edits"`
	Inserts   []RowInsert    `json:"inserts"`
	Deletes   []int64        `json:"deletes"`
	Confirmed []Confirmation `json:"confirmed,omitempty"`
}

type PlannedStatement struct {
	Kind   string    `json:"kind"`
	Row    *int64    `json:"row,omitempty"`
	Insert *int      `json:"insert,omitempty"`
	SQL    string    `json:"sql"`
	Params []*string `json:"params"`
}

type EditIssue struct {
	Row     *int64 `json:"row,omitempty"`
	Insert  *int   `json:"insert,omitempty"`
	Column  *int   `json:"column,omitempty"`
	Message string `json:"message"`
}

type PlanEditsResult struct {
	Statements []PlannedStatement `json:"statements"`
	Issues     []EditIssue        `json:"issues"`
	Blocked    []Blocked          `json:"blocked"`
	Error      *Error             `json:"error"`
}

type ApplyEditsResult struct {
	Applied         bool          `json:"applied"`
	Committed       bool          `json:"committed"`
	RowsAffected    int64         `json:"rowsAffected"`
	FailedStatement *int          `json:"failedStatement"`
	Blocked         []Blocked     `json:"blocked"`
	Error           *Error        `json:"error"`
	Session         *SessionState `json:"session"`
}

type editPlan struct {
	r       *result
	def     Definition
	stmts   []PlannedStatement
	args    [][]any
	issues  []EditIssue
	blocked []Blocked
}

type sqliteAffinity uint8

const (
	affInteger sqliteAffinity = iota
	affText
	affBlob
	affReal
	affNumeric
)

func affinityOf(decl string) sqliteAffinity {
	d := strings.ToUpper(decl)
	switch {
	case strings.Contains(d, "INT"):
		return affInteger
	case strings.Contains(d, "CHAR"), strings.Contains(d, "CLOB"), strings.Contains(d, "TEXT"):
		return affText
	case d == "" || strings.Contains(d, "BLOB"):
		return affBlob
	case strings.Contains(d, "REAL"), strings.Contains(d, "FLOA"), strings.Contains(d, "DOUB"):
		return affReal
	}
	return affNumeric
}

func parseHexValue(v string) ([]byte, bool) {
	if len(v) < 2 || (v[:2] != "0x" && v[:2] != "0X") {
		return nil, false
	}
	b, err := hex.DecodeString(v[2:])
	return b, err == nil
}

func sqliteArg(col columnInfo, kind uint8, v string) (any, string) {
	decl := strings.ToUpper(col.Type)
	aff := affinityOf(col.Type)
	if strings.Contains(decl, "BOOL") {
		switch strings.ToLower(v) {
		case "true":
			return int64(1), ""
		case "false":
			return int64(0), ""
		}
	}
	switch aff {
	case affInteger:
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n, ""
		}
	case affReal:
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f, ""
		}
	case affNumeric:
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n, ""
		}
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f, ""
		}
	case affBlob:
		if strings.Contains(decl, "BLOB") || kind == KindBinary {
			if b, ok := parseHexValue(v); ok {
				return b, ""
			}
			return nil, "Enter binary values as hexadecimal that starts with 0x."
		}
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && strconv.FormatInt(n, 10) == v {
			return n, ""
		}
	}
	return v, ""
}

func editArg(engine string, col columnInfo, kind uint8, v []byte, fromResult bool) (any, string) {
	binary := kind == KindBinary
	if binary {
		raw := v
		if !fromResult {
			b, ok := parseHexValue(string(v))
			if !ok {
				return nil, "Enter binary values as hexadecimal that starts with 0x."
			}
			raw = b
		}
		if engine == EnginePostgres {
			return `\x` + hex.EncodeToString(raw), ""
		}
		return append([]byte{}, raw...), ""
	}
	switch engine {
	case EngineSQLite:
		return sqliteArg(col, kind, string(v))
	}
	return string(v), ""
}

func displayArg(a any) *string {
	switch v := a.(type) {
	case nil:
		return nil
	case []byte:
		s := "0x" + hex.EncodeToString(v)
		return &s
	case string:
		return &v
	default:
		s := fmt.Sprint(v)
		return &s
	}
}

type sqlBuilder struct {
	engine string
	b      strings.Builder
	args   []any
}

func (sb *sqlBuilder) placeholder(col columnInfo, arg any) {
	sb.args = append(sb.args, arg)
	if sb.engine == EnginePostgres {
		sb.b.WriteString("$" + strconv.Itoa(len(sb.args)) + "::" + col.Type)
		return
	}
	sb.b.WriteByte('?')
}

func (p *editPlan) issue(row *int64, insert, column *int, msg string) {
	p.issues = append(p.issues, EditIssue{Row: row, Insert: insert, Column: column, Message: msg})
}

func planEdits(req EditRequest) (*editPlan, *Error) {
	r := lookupResult(req.ResultID)
	if r == nil {
		return nil, newError("internal", "That result is no longer available. Open the table again.")
	}
	r.mu.Lock()
	b := r.table
	r.mu.Unlock()
	if b == nil {
		return nil, newError("unsupported", "Only tables opened with Open Table can be edited.")
	}
	def := r.sess.ds.definition()
	if !b.editable {
		kind := "unsupported"
		if def.ReadOnly {
			kind = "readOnly"
		}
		return nil, newError(kind, b.reason)
	}
	p := &editPlan{r: r, def: def}
	engine := def.Engine
	table := qualifiedName(engine, b.schema, b.name)
	cols := b.info.Columns
	ncols := len(r.kinds)
	deleted := map[int64]bool{}
	for _, row := range req.Deletes {
		deleted[row] = true
	}
	checkColumn := func(c int, row *int64, insert *int) bool {
		col := c
		if c < 0 || c >= ncols || b.tableCol[c] < 0 {
			p.issue(row, insert, &col, "That column can't be changed.")
			return false
		}
		if reason, ok := b.readOnly[c]; ok {
			p.issue(row, insert, &col, reason)
			return false
		}
		return true
	}
	keyWhere := func(sb *sqlBuilder, row int64) bool {
		rowRef := row
		views, _, _ := r.viewRows(row, 1)
		if len(views) == 0 {
			p.issue(&rowRef, nil, nil, fmt.Sprintf("Row %d is outside the loaded rows.", row+1))
			return false
		}
		refs, err := r.sp.refs(views)
		if err != nil {
			p.issue(&rowRef, nil, nil, "GoLens could not read that row.")
			return false
		}
		sb.b.WriteString(" WHERE ")
		for i, k := range b.keyCols {
			v, null := refs[0].cols[k].cell(refs[0].idx)
			if null {
				p.issue(&rowRef, nil, nil, fmt.Sprintf("Row %d has no value in its key column, so GoLens can't identify it.", row+1))
				return false
			}
			col := cols[b.tableCol[k]]
			arg, problem := editArg(engine, col, r.kinds[k], v, true)
			if problem != "" {
				p.issue(&rowRef, nil, nil, problem)
				return false
			}
			if i > 0 {
				sb.b.WriteString(" AND ")
			}
			sb.b.WriteString(quoteName(engine, col.Name) + " = ")
			sb.placeholder(col, arg)
		}
		return true
	}
	add := func(kind string, row *int64, insert *int, sb *sqlBuilder) {
		params := make([]*string, len(sb.args))
		for i, a := range sb.args {
			params[i] = displayArg(a)
		}
		p.stmts = append(p.stmts, PlannedStatement{Kind: kind, Row: row, Insert: insert, SQL: sb.b.String(), Params: params})
		p.args = append(p.args, sb.args)
	}

	rows := make([]int64, 0, len(deleted))
	for row := range deleted {
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i] < rows[j] })
	for _, row := range rows {
		sb := &sqlBuilder{engine: engine}
		sb.b.WriteString("DELETE FROM " + table)
		if keyWhere(sb, row) {
			add("delete", ptrTo(row), nil, sb)
		}
	}

	byRow := map[int64][]CellEdit{}
	var editRows []int64
	for _, e := range req.Edits {
		if deleted[e.Row] {
			continue
		}
		if _, ok := byRow[e.Row]; !ok {
			editRows = append(editRows, e.Row)
		}
		byRow[e.Row] = append(byRow[e.Row], e)
	}
	sort.Slice(editRows, func(i, j int) bool { return editRows[i] < editRows[j] })
	for _, row := range editRows {
		sb := &sqlBuilder{engine: engine}
		sb.b.WriteString("UPDATE " + table + " SET ")
		ok := true
		seen := map[int]int{}
		var edits []CellEdit
		for _, e := range byRow[row] {
			if i, dup := seen[e.Column]; dup {
				edits[i] = e
				continue
			}
			seen[e.Column] = len(edits)
			edits = append(edits, e)
		}
		for i, e := range edits {
			rowRef := row
			if !checkColumn(e.Column, &rowRef, nil) {
				ok = false
				continue
			}
			col := cols[b.tableCol[e.Column]]
			var arg any
			if !e.IsNull {
				var problem string
				arg, problem = editArg(engine, col, r.kinds[e.Column], []byte(e.Value), false)
				if problem != "" {
					c := e.Column
					p.issue(&rowRef, nil, &c, problem)
					ok = false
					continue
				}
			}
			if i > 0 {
				sb.b.WriteString(", ")
			}
			sb.b.WriteString(quoteName(engine, col.Name) + " = ")
			sb.placeholder(col, arg)
		}
		if ok && keyWhere(sb, row) {
			add("update", ptrTo(row), nil, sb)
		}
	}

	for n, ins := range req.Inserts {
		idx := n
		sb := &sqlBuilder{engine: engine}
		ok := true
		var names []string
		var values []func()
		seen := map[int]bool{}
		for _, c := range ins.Cells {
			if seen[c.Column] {
				continue
			}
			seen[c.Column] = true
			if !checkColumn(c.Column, nil, &idx) {
				ok = false
				continue
			}
			col := cols[b.tableCol[c.Column]]
			var arg any
			if !c.IsNull {
				var problem string
				arg, problem = editArg(engine, col, r.kinds[c.Column], []byte(c.Value), false)
				if problem != "" {
					cc := c.Column
					p.issue(nil, &idx, &cc, problem)
					ok = false
					continue
				}
			}
			names = append(names, quoteName(engine, col.Name))
			values = append(values, func() { sb.placeholder(col, arg) })
		}
		if !ok {
			continue
		}
		sb.b.WriteString("INSERT INTO " + table)
		switch {
		case len(names) > 0:
			sb.b.WriteString(" (" + strings.Join(names, ", ") + ") VALUES (")
			for i, v := range values {
				if i > 0 {
					sb.b.WriteString(", ")
				}
				v()
			}
			sb.b.WriteString(")")
		case engine == EngineMySQL:
			sb.b.WriteString(" () VALUES ()")
		default:
			sb.b.WriteString(" DEFAULT VALUES")
		}
		add("insert", nil, &idx, sb)
	}

	if len(p.stmts) > 0 {
		risks := map[string]bool{}
		for _, st := range p.stmts {
			if risk := primaryRisk(classify(st.SQL, lex(st.SQL, engine), engine), def.Production); risk != "" {
				risks[risk] = true
			}
		}
		hash := p.batchHash()
		for _, risk := range []string{RiskDeleteWithoutWhere, RiskUpdateWithoutWhere, RiskProductionWrite} {
			if risks[risk] {
				p.blocked = append(p.blocked, Blocked{Hash: hash, Risk: risk, Table: b.name, Preview: plural(len(p.stmts), "change", "changes") + " to " + b.name})
			}
		}
	}
	return p, nil
}

func ptrTo[T any](v T) *T { return &v }

func (p *editPlan) batchHash() string {
	var sb strings.Builder
	for _, st := range p.stmts {
		sb.WriteString(st.SQL)
		for _, v := range st.Params {
			if v == nil {
				sb.WriteString("\x00N")
			} else {
				sb.WriteString("\x00V" + *v)
			}
		}
		sb.WriteString("\x1e")
	}
	return statementHash(sb.String())
}

func (p *editPlan) unconfirmed(confirmed []Confirmation) []Blocked {
	ok := map[Confirmation]bool{}
	for _, c := range confirmed {
		ok[c] = true
	}
	out := []Blocked{}
	for _, b := range p.blocked {
		if !ok[Confirmation{Hash: b.Hash, Risk: b.Risk}] {
			out = append(out, b)
		}
	}
	return out
}

func PlanEdits(req EditRequest) PlanEditsResult {
	out := PlanEditsResult{Statements: []PlannedStatement{}, Issues: []EditIssue{}, Blocked: []Blocked{}}
	p, e := planEdits(req)
	if e != nil {
		out.Error = e
		return out
	}
	if p.stmts != nil {
		out.Statements = p.stmts
	}
	if p.issues != nil {
		out.Issues = p.issues
	}
	out.Blocked = p.unconfirmed(nil)
	return out
}

func conflictMessage(st PlannedStatement, affected int64) string {
	switch {
	case st.Insert != nil:
		return fmt.Sprintf("New row %d was not added, so nothing was saved.", *st.Insert+1)
	case affected == 0:
		return fmt.Sprintf("Row %d no longer matches its key in the database (someone may have changed or deleted it), so nothing was saved. Reload the table and make the change again.", *st.Row+1)
	}
	return fmt.Sprintf("The change to row %d would affect %d rows, so nothing was saved.", *st.Row+1, affected)
}

func ApplyEdits(req EditRequest) (out ApplyEditsResult) {
	out = ApplyEditsResult{Blocked: []Blocked{}}
	p, e := planEdits(req)
	if e != nil {
		out.Error = e
		return out
	}
	s := p.r.sess
	if len(p.issues) > 0 {
		out.Error = newError("syntax", p.issues[0].Message)
		out.Session = s.snapshotState()
		return out
	}
	if len(p.stmts) == 0 {
		out.Applied = true
		out.Session = s.snapshotState()
		return out
	}
	if out.Blocked = p.unconfirmed(req.Confirmed); len(out.Blocked) > 0 {
		out.Session = s.snapshotState()
		return out
	}
	release := s.acquire(req.ExecID, true)
	defer release()
	defer func() { out.Session = s.stateLocked() }()
	if e := s.connectLocked(); e != nil {
		out.Error = e
		return out
	}
	switch s.txLocked() {
	case "failed":
		out.Error = newError("transactionOpen", "The open transaction failed. Roll it back before submitting changes.")
		return out
	}
	mode, _ := s.txConfig()
	active := s.txLocked() != "idle"
	ownTx := mode == ModeAuto && !active
	begunHere := false
	if !ownTx && !active {
		if _, err := s.execLocked(beginStatement(p.def.Engine), nil); err != nil {
			out.Error = s.ds.classify(err)
			return out
		}
		begunHere = true
	}
	if ownTx {
		if _, err := s.execLocked(beginStatement(p.def.Engine), nil); err != nil {
			out.Error = s.ds.classify(err)
			return out
		}
	} else if _, err := s.execLocked("SAVEPOINT golens_submit", nil); err != nil {
		out.Error = s.ds.classify(err)
		if begunHere {
			_, _ = s.execLocked("ROLLBACK", nil)
		}
		return out
	}
	undo := func() {
		if s.conn == nil {
			return
		}
		if ownTx {
			_, _ = s.execLocked("ROLLBACK", nil)
			return
		}
		_, _ = s.execLocked("ROLLBACK TO SAVEPOINT golens_submit", nil)
		_, _ = s.execLocked("RELEASE SAVEPOINT golens_submit", nil)
		if begunHere {
			_, _ = s.execLocked("ROLLBACK", nil)
		}
	}
	var history []HistoryEntry
	defer func() { recordHistory(s.ds.id, history...) }()
	var total int64
	for i, st := range p.stmts {
		if s.stopRequested() {
			undo()
			out.FailedStatement = ptrTo(i)
			out.Error = errorFor("cancelled")
			return out
		}
		started := reg.clk.Now()
		affected, err := s.execLocked(st.SQL, p.args[i])
		sr := StatementResult{RowsAffected: affected, DurationMs: ms(reg.clk.Now().Sub(started))}
		if err != nil {
			sr.Error = s.ds.classify(err)
		}
		history = append(history, historyEntry(st.SQL, "edit", sr, nil, started))
		if err != nil {
			out.FailedStatement = ptrTo(i)
			out.Error = sr.Error
			undo()
			out.RowsAffected = 0
			return out
		}
		if affected == nil || *affected != 1 {
			n := int64(0)
			if affected != nil {
				n = *affected
			}
			out.FailedStatement = ptrTo(i)
			out.Error = newError("conflict", conflictMessage(st, n))
			undo()
			return out
		}
		total += *affected
	}
	if ownTx {
		if _, err := s.execLocked("COMMIT", nil); err != nil {
			out.Error = s.ds.classify(err)
			undo()
			return out
		}
		out.Committed = true
	} else if _, err := s.execLocked("RELEASE SAVEPOINT golens_submit", nil); err != nil {
		out.Error = s.ds.classify(err)
		undo()
		return out
	}
	out.Applied = true
	out.RowsAffected = total
	return out
}
