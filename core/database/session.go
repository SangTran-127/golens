package database

import (
	"context"
	"errors"
	"math"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

type runningOp struct {
	conn   engineConn
	cancel context.CancelFunc
}

type session struct {
	id        string
	ds        *dataSource
	mu        sync.Mutex
	conn      engineConn
	state     string
	tracked   string
	schema    string
	open      *result
	timer     stopper
	txSince   time.Time
	runMu     sync.Mutex
	running   *runningOp
	cancelled bool
	mode      string
	isolation string
}

type runItem struct {
	index      int
	text       string
	start, end int
	line       int
	class      classification
	toks       []token
	src        string
	bound      boundSQL
}

func (r *registry) sessionFor(consoleID string, ds *dataSource) *session {
	r.mu.Lock()
	r.init()
	s := r.sessions[consoleID]
	if s != nil && s.ds == ds {
		r.mu.Unlock()
		return s
	}
	old := s
	s = &session{id: consoleID, ds: ds, state: "notConnected", tracked: "idle", mode: defaultMode(ds.definition())}
	r.sessions[consoleID] = s
	r.mu.Unlock()
	if old != nil {
		old.closeConn(true)
	}
	return s
}

func (s *session) setRunning(c engineConn, cancel context.CancelFunc) {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	if cancel == nil {
		s.running = nil
		return
	}
	s.running = &runningOp{conn: c, cancel: cancel}
	if s.cancelled {
		c.interrupt(s.ds, cancel)
	}
}

func (s *session) interrupt() bool {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	s.cancelled = true
	if s.running == nil {
		return false
	}
	s.running.conn.interrupt(s.ds, s.running.cancel)
	return true
}

func (s *session) stopRequested() bool {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	return s.cancelled
}

func (s *session) connected() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.conn != nil
}

func (s *session) txLocked() string {
	if s.conn == nil {
		return "idle"
	}
	return s.conn.txStatus(s.tracked)
}

func isMySQL(c engineConn) bool {
	_, ok := c.(*mysqlConn)
	return ok
}

func (s *session) transactionOpen() bool {
	if !s.mu.TryLock() {
		return true
	}
	defer s.mu.Unlock()
	return s.txLocked() != "idle"
}

func (s *session) stateLocked() *SessionState {
	mode, iso := s.txConfig()
	return &SessionState{State: s.state, Transaction: s.txLocked(), Schema: s.schema, Mode: mode, Isolation: iso}
}

func (s *session) emitState() {
	emit(Event{Event: "sessionState", ConsoleID: s.id, DataSource: s.ds.id, Session: s.stateLocked()})
}

func (s *session) closeConn(interrupt bool) bool {
	if interrupt {
		s.interrupt()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	hadTx := s.txLocked() != "idle"
	s.abandonOpenLocked(true)
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.conn != nil {
		s.conn.close()
		s.conn = nil
		s.state = "notConnected"
		s.tracked = "idle"
		s.emitState()
	}
	return hadTx
}

func (s *session) touchLocked() {
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = reg.clk.AfterFunc(consoleIdle, s.idleFired)
}

func (s *session) idleFired() {
	if !s.mu.TryLock() {
		return
	}
	defer s.mu.Unlock()
	s.timer = nil
	if s.conn == nil {
		return
	}
	if s.open != nil {
		s.touchLocked()
		return
	}
	if s.txLocked() != "idle" {
		minutes := int(reg.clk.Now().Sub(s.txSince) / time.Minute)
		emit(Event{Event: "sessionState", ConsoleID: s.id, DataSource: s.ds.id, Session: s.stateLocked(), TransactionOpenMinutes: max(minutes, int(consoleIdle/time.Minute))})
		s.touchLocked()
		return
	}
	s.conn.close()
	s.conn = nil
	s.state = "notConnected"
	s.tracked = "idle"
	s.emitState()
}

func (s *session) connectLocked() *Error {
	if s.conn != nil && !s.conn.broken() {
		return nil
	}
	if s.conn != nil {
		s.conn.close()
		s.conn = nil
	}
	opts, e := s.ds.dialOptions(false)
	if e != nil {
		return e
	}
	s.state = "connecting"
	s.emitState()
	c, err := dial(context.Background(), opts)
	if err != nil {
		s.state = "failed"
		s.emitState()
		return s.ds.connectError(err)
	}
	s.conn = c
	s.state = "connected"
	s.tracked = "idle"
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	s.schema = c.currentSchema(ctx)
	cancel()
	if _, iso := s.txConfig(); iso != "" {
		if err := s.applyIsolationLocked(iso); err != nil {
			s.conn.close()
			s.conn = nil
			s.state = "failed"
			s.emitState()
			return s.ds.connectError(err)
		}
	}
	s.emitState()
	return nil
}

func (s *session) abandonOpenLocked(truncate bool) {
	r := s.open
	if r == nil {
		return
	}
	s.open = nil
	r.mu.Lock()
	cur, cancel := r.cur, r.cancel
	r.cur, r.cancel = nil, nil
	if !r.complete && truncate {
		r.truncated = true
	}
	r.firstPage = nil
	r.mu.Unlock()
	if cur != nil {
		s.stopCursor(cur, cancel)
	}
}

func (s *session) stopCursor(cur cursor, cancel context.CancelFunc) {
	switch c := s.conn.(type) {
	case *pgConn:
		if c.txStatus("") == "idle" {
			cancel()
		}
	case *mysqlConn:
		ctx, done := context.WithTimeout(context.Background(), 3*time.Second)
		if s.ds.killQuery(ctx, c.id) != nil {
			cancel()
		}
		done()
	}
	_ = cur.close(true)
	cancel()
}

func ms(d time.Duration) float64 {
	return math.Round(float64(d.Microseconds())/10) / 100
}

func selectItems(req ExecuteRequest, dialect string) []runItem {
	text := req.Text
	base := 0
	if req.Mode == "selection" {
		a, b := req.Selection.StartByte, req.Selection.EndByte
		a = max(0, min(a, len(text)))
		b = max(a, min(b, len(text)))
		base = a
		text = text[a:b]
	}
	stmts := splitStatements(text, dialect)
	if len(stmts) == 0 {
		return nil
	}
	if req.Mode == "caret" || req.Mode == "" {
		i := statementAtCaret(stmts, text, max(0, min(req.CaretByte, len(text))))
		stmts = stmts[i : i+1]
	}
	var items []runItem
	for i, st := range stmts {
		items = append(items, runItem{
			index: i, text: st.text(text), start: base + st.start, end: base + st.end,
			line: lineAt(req.Text, base+st.start), class: classify(text, st.toks, dialect), toks: st.toks, src: text,
		})
	}
	return items
}

func primaryRisk(c classification, production bool) string {
	order := []string{RiskDropDatabase, RiskDropSchema, RiskDropTable, RiskTruncate, RiskDeleteWithoutWhere, RiskUpdateWithoutWhere}
	for _, o := range order {
		for _, r := range c.risks {
			if r == o {
				return r
			}
		}
	}
	if production && c.writes {
		return RiskProductionWrite
	}
	return ""
}

func Execute(req ExecuteRequest) ExecuteResponse {
	resp := ExecuteResponse{ExecID: req.ExecID, Blocked: []Blocked{}, Statements: []StatementResult{}}
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		resp.Session = &SessionState{State: "notConnected", Transaction: "idle"}
		resp.Error = newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")
		return resp
	}
	def := ds.definition()
	items := selectItems(req, def.Engine)
	s := reg.sessionFor(req.ConsoleID, ds)
	if len(items) == 0 {
		resp.Session = s.snapshotState()
		resp.Error = newError("syntax", "There is no SQL statement to run here.")
		return resp
	}
	if def.ReadOnly {
		for _, it := range items {
			if it.class.writes {
				resp.Session = s.snapshotState()
				resp.Error = newError("readOnly", def.Name+" is read-only, so GoLens did not run this statement. Turn off Read-only in Edit Data Source to allow writes.")
				resp.Error.Position = positionIn(req.Text, it.start)
				return resp
			}
		}
	}
	var missing []string
	seen := map[string]bool{}
	for i := range items {
		items[i].bound = bindParams(items[i].text, def.Engine, req.Parameters)
		for _, m := range items[i].bound.missing {
			if !seen[m] {
				seen[m] = true
				missing = append(missing, m)
			}
		}
	}
	if len(missing) > 0 {
		resp.Session = s.snapshotState()
		resp.Error = missingParamsError(missing)
		return resp
	}
	confirmed := map[Confirmation]bool{}
	for _, c := range req.Confirmed {
		confirmed[c] = true
	}
	for _, it := range items {
		risk := primaryRisk(it.class, def.Production)
		if risk == "" {
			continue
		}
		h := statementHash(it.text)
		if confirmed[Confirmation{Hash: h, Risk: risk}] {
			continue
		}
		resp.Blocked = append(resp.Blocked, Blocked{Index: it.index, Hash: h, Risk: risk, Table: it.class.table, Line: it.line, Preview: preview(it.text)})
	}
	if len(resp.Blocked) > 0 {
		resp.Session = s.snapshotState()
		return resp
	}
	return s.execute(req, items)
}

func (s *session) snapshotState() *SessionState {
	if !s.mu.TryLock() {
		mode, iso := s.txConfig()
		return &SessionState{State: "connected", Transaction: "idle", Mode: mode, Isolation: iso}
	}
	defer s.mu.Unlock()
	return s.stateLocked()
}

func (s *session) acquire(execID string, interrupt bool) func() {
	s.runMu.Lock()
	s.cancelled = false
	s.runMu.Unlock()
	if execID != "" {
		reg.mu.Lock()
		reg.init()
		reg.execs[execID] = s
		reg.mu.Unlock()
	}
	if interrupt {
		s.interruptFetch()
	}
	s.mu.Lock()
	s.abandonOpenLocked(true)
	return func() {
		if s.conn != nil {
			s.touchLocked()
		}
		s.mu.Unlock()
		if execID != "" {
			reg.mu.Lock()
			delete(reg.execs, execID)
			reg.mu.Unlock()
		}
	}
}

func (s *session) execute(req ExecuteRequest, items []runItem) ExecuteResponse {
	resp := ExecuteResponse{ExecID: req.ExecID, Blocked: []Blocked{}, Statements: []StatementResult{}}
	release := s.acquire(req.ExecID, true)
	defer release()
	if e := s.connectLocked(); e != nil {
		resp.Error = e
		resp.Session = s.stateLocked()
		return resp
	}
	pageSize := req.PageSize
	if pageSize <= 0 {
		pageSize = 500
	}
	source := req.Source
	if source == "" {
		source = "console"
	}
	var history []HistoryEntry
	defer func() { recordHistory(s.ds.id, history...) }()
	for i, it := range items {
		if s.stopRequested() {
			break
		}
		started := StatementResult{Index: it.index, Line: it.line, StartByte: it.start, EndByte: it.end, Kind: it.class.kind, Columns: []Column{}, Notices: []string{}}
		emit(Event{Event: "statementStarted", ExecID: req.ExecID, ConsoleID: s.id, DataSource: s.ds.id, Statement: &started})
		var sr StatementResult
		if err := s.beginIfManualLocked(it.class); err != nil {
			sr = started
			sr.Error = s.statementError(err, it, req)
		} else {
			sr = s.runOne(req, it, i == len(items)-1, pageSize, started)
		}
		resp.Statements = append(resp.Statements, sr)
		history = append(history, historyEntry(it.text, source, sr, usedParams(it.bound, req.Parameters), reg.clk.Now()))
		emit(Event{Event: "statementFinished", ExecID: req.ExecID, ConsoleID: s.id, DataSource: s.ds.id, Statement: &sr})
		if sr.Error != nil || s.conn == nil {
			break
		}
	}
	if len(resp.Statements) == 0 && s.stopRequested() {
		resp.Error = errorFor("cancelled")
	}
	resp.Session = s.stateLocked()
	return resp
}

func (s *session) interruptFetch() {
	s.runMu.Lock()
	op := s.running
	s.runMu.Unlock()
	if op != nil {
		op.conn.interrupt(s.ds, op.cancel)
	}
}

func (s *session) statementError(err error, it runItem, req ExecuteRequest) *Error {
	s.ds.mu.Lock()
	secret := s.ds.secret
	s.ds.mu.Unlock()
	e := classifyError(err, secret)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Position > 0 {
		sent := it.text
		if it.bound.sql != "" {
			sent = it.bound.sql
		}
		off := it.bound.offsets.original(runeOffset(sent, int(pgErr.Position)-1))
		e.Position = positionIn(req.Text, it.start+min(off, len(it.text)))
	}
	if e.Position == nil {
		if off, ok := enginePosition(e, it.text); ok {
			e.Position = positionIn(req.Text, it.start+off)
		}
	}
	if e.Position == nil {
		e.Position = positionIn(req.Text, it.start)
	}
	if e.Kind == "connectionLost" || (s.conn != nil && s.conn.broken()) {
		if s.conn != nil {
			s.conn.close()
		}
		s.conn = nil
		s.state = "failed"
		s.tracked = "idle"
		e.Kind = "connectionLost"
		e.Message = defaultMessages["connectionLost"]
	}
	return e
}

func runeOffset(s string, runes int) int {
	off := 0
	for i := 0; i < runes && off < len(s); i++ {
		_, n := utf8.DecodeRuneInString(s[off:])
		off += n
	}
	return off
}

func (s *session) afterSuccess(it runItem) {
	c := it.class
	wasIdle := s.tracked == "idle"
	switch {
	case c.tx == txBegin:
		s.tracked = "active"
	case c.tx == txEnd:
		s.tracked = "idle"
	case c.ddl && isMySQL(s.conn):
		s.tracked = "idle"
	}
	if s.conn != nil && s.conn.txStatus(s.tracked) != "idle" && (wasIdle || s.txSince.IsZero()) {
		s.txSince = reg.clk.Now()
	}
	if s.conn != nil && s.conn.txStatus(s.tracked) == "idle" {
		s.txSince = time.Time{}
	}
	if c.ddl {
		s.ds.markStale()
	}
	if c.session && s.conn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if v := s.conn.currentSchema(ctx); v != "" {
			s.schema = v
		}
		cancel()
	}
}

func (s *session) runOne(req ExecuteRequest, it runItem, last bool, pageSize int, sr StatementResult) StatementResult {
	ctx, cancel := context.WithCancel(context.Background())
	conn := s.conn
	s.setRunning(conn, cancel)
	defer s.setRunning(nil, nil)
	start := time.Now()
	sqlText := it.text
	if it.bound.sql != "" {
		sqlText = it.bound.sql
	}
	cur, affected, err := conn.run(ctx, sqlText, it.bound.args, it.class)
	if err == nil && cur == nil {
		cancel()
		sr.RowsAffected = affected
		sr.Complete = true
		sr.DurationMs = ms(time.Since(start))
		sr.FirstRowMs = sr.DurationMs
		sr.Notices = append(sr.Notices, conn.takeNotices()...)
		s.afterSuccess(it)
		return sr
	}
	if err != nil {
		cancel()
		sr.DurationMs = ms(time.Since(start))
		sr.Notices = append(sr.Notices, conn.takeNotices()...)
		sr.Error = s.statementError(err, it, req)
		return sr
	}
	r := newResult(s, cur, pageSize)
	r.cancel = cancel
	eof, firstRow, err := r.fill(int64(pageSize), start, nil)
	sr.DurationMs = ms(time.Since(start))
	sr.FirstRowMs = ms(firstRow)
	sr.Notices = append(sr.Notices, conn.takeNotices()...)
	if err != nil {
		r.cur = nil
		_ = cur.close(true)
		cancel()
		r.sp.close()
		sr.Error = s.statementError(err, it, req)
		return sr
	}
	if s.stopRequested() {
		r.cur = nil
		if eof {
			_ = cur.close(false)
			cancel()
		} else {
			s.stopCursor(cur, cancel)
		}
		r.sp.close()
		sr.Error = &Error{Kind: "cancelled", Message: defaultMessages["cancelled"]}
		return sr
	}
	r.kinds = cur.kinds()
	sr.Columns = cur.columns()
	r.columns = sr.Columns
	switch {
	case eof:
		r.complete = true
		r.cur = nil
		r.cancel = nil
		_ = cur.close(false)
		cancel()
	case !last:
		r.truncated = true
		r.cur = nil
		r.cancel = nil
		s.stopCursor(cur, cancel)
	default:
		s.open = r
	}
	encStart := time.Now()
	r.firstPage = r.encode(0, pageSize)
	sr.PageEncodedMs = ms(time.Since(encStart))
	sr.ResultID = r.id
	sr.RowsFetched = r.sp.rowCount()
	sr.Complete = r.complete
	sr.Truncated = r.truncated
	reg.mu.Lock()
	reg.results[r.id] = r
	reg.mu.Unlock()
	if s.conn != nil {
		s.afterSuccess(it)
	}
	return sr
}

func Cancel(id string) bool {
	reg.mu.Lock()
	reg.init()
	s := reg.execs[id]
	r := reg.results[id]
	op := reg.ops[id]
	reg.mu.Unlock()
	if op != nil {
		op()
		return true
	}
	if s != nil {
		s.interrupt()
		return true
	}
	if r != nil {
		r.mu.Lock()
		fetching := r.fetching
		r.mu.Unlock()
		if fetching {
			return r.sess.interrupt()
		}
	}
	return false
}

func TestConnection(req TestConnectionRequest) TestConnectionResult {
	ds := &dataSource{id: req.Definition.ID, def: req.Definition, root: req.WorkspaceRoot, secret: req.Secret, hasSecret: true}
	if issues := validate([]Definition{req.Definition}); len(issues) > 0 {
		return TestConnectionResult{Error: &Error{Kind: "connect", Message: issues[0].Message}}
	}
	start := time.Now()
	c, err := dial(context.Background(), dialOptions{def: req.Definition, root: req.WorkspaceRoot, secret: req.Secret})
	if err != nil {
		e := ds.connectError(err)
		if e.Kind == "auth" {
			e.Message = "The server did not accept the user name or password. Check them and test again."
		}
		return TestConnectionResult{Error: e}
	}
	defer c.close()
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	v, err := c.serverVersion(ctx)
	if err != nil {
		return TestConnectionResult{Error: classifyError(err, req.Secret)}
	}
	return TestConnectionResult{OK: true, ServerVersion: strings.TrimSpace(v), LatencyMs: time.Since(start).Milliseconds()}
}
