package database

import (
	"context"
	"errors"
	"strings"

	"github.com/go-sql-driver/mysql"
)

const (
	ModeAuto   = "auto"
	ModeManual = "manual"
)

type TransactionRequest struct {
	ConsoleID    string `json:"consoleId"`
	DataSourceID string `json:"dataSourceId,omitempty"`
	Action       string `json:"action"`
	Mode         string `json:"mode,omitempty"`
	Isolation    string `json:"isolation,omitempty"`
}

type TransactionResult struct {
	Session         *SessionState `json:"session"`
	IsolationLevels []string      `json:"isolationLevels"`
	Error           *Error        `json:"error"`
}

var isolationLevels = map[string][]string{
	EnginePostgres: {"read committed", "repeatable read", "serializable"},
	EngineMySQL:    {"read uncommitted", "read committed", "repeatable read", "serializable"},
	EngineSQLite:   {"serializable"},
}

func defaultMode(def Definition) string {
	switch def.TxMode {
	case ModeAuto, ModeManual:
		return def.TxMode
	}
	if def.Production {
		return ModeManual
	}
	return ModeAuto
}

func (s *session) txConfig() (string, string) {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	return s.mode, s.isolation
}

func (s *session) setTxConfig(mode, iso string) {
	s.runMu.Lock()
	s.mode, s.isolation = mode, iso
	s.runMu.Unlock()
}

func (s *session) engine() string { return s.ds.definition().Engine }

func (s *session) execLocked(sql string, args []any) (*int64, error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn := s.conn
	s.setRunning(conn, cancel)
	defer s.setRunning(nil, nil)
	cl := classify(sql, lex(sql, s.engine()), s.engine())
	cl.returnsRows = false
	_, affected, err := conn.run(ctx, sql, args, cl)
	if err != nil {
		if conn.broken() {
			conn.close()
			s.conn = nil
			s.state = "failed"
			s.tracked = "idle"
		}
		return nil, err
	}
	s.afterSuccess(runItem{class: cl})
	return affected, nil
}

func beginStatement(engine string) string {
	if engine == EngineMySQL {
		return "START TRANSACTION"
	}
	return "BEGIN"
}

func (s *session) beginIfManualLocked(c classification) error {
	if mode, _ := s.txConfig(); mode != ModeManual || s.conn == nil || s.txLocked() != "idle" || c.kind == "transaction" {
		return nil
	}
	_, err := s.execLocked(beginStatement(s.engine()), nil)
	return err
}

func (s *session) applyIsolationLocked(iso string) error {
	switch s.engine() {
	case EnginePostgres:
		if iso == "" {
			_, err := s.execLocked("SET default_transaction_isolation TO DEFAULT", nil)
			return err
		}
		_, err := s.execLocked("SET default_transaction_isolation TO '"+iso+"'", nil)
		return err
	case EngineMySQL:
		if iso == "" {
			_, err := s.execLocked("SET SESSION transaction_isolation = DEFAULT", nil)
			var me *mysql.MySQLError
			if errors.As(err, &me) && me.Number == 1193 {
				_, err = s.execLocked("SET SESSION tx_isolation = DEFAULT", nil)
			}
			return err
		}
		_, err := s.execLocked("SET SESSION TRANSACTION ISOLATION LEVEL "+strings.ToUpper(iso), nil)
		return err
	}
	return nil
}

func validIsolation(engine, iso string) bool {
	if iso == "" {
		return true
	}
	for _, l := range isolationLevels[engine] {
		if l == iso {
			return true
		}
	}
	return false
}

func Transaction(req TransactionRequest) (out TransactionResult) {
	reg.mu.Lock()
	reg.init()
	s := reg.sessions[req.ConsoleID]
	reg.mu.Unlock()
	if s == nil {
		if ds := reg.source(req.DataSourceID); ds != nil {
			s = reg.sessionFor(req.ConsoleID, ds)
		}
	}
	if s == nil {
		return TransactionResult{IsolationLevels: []string{}, Session: &SessionState{State: "notConnected", Transaction: "idle", Mode: ModeAuto},
			Error: newError("internal", "GoLens does not know this console. Run a statement in it first.")}
	}
	engine := s.engine()
	out = TransactionResult{IsolationLevels: append([]string{}, isolationLevels[engine]...)}
	release := s.acquire("", false)
	defer func() {
		out.Session = s.stateLocked()
		release()
		s.emitStateUnlocked()
	}()
	mode, iso := s.txConfig()
	switch req.Action {
	case "status":
	case "setMode":
		if req.Mode != ModeAuto && req.Mode != ModeManual {
			out.Error = newError("internal", "Choose Auto-Commit or Manual.")
			return out
		}
		if req.Mode == ModeAuto && s.txLocked() != "idle" {
			out.Error = newError("transactionOpen", "Commit or roll back the open transaction before switching to Auto-Commit.")
			return out
		}
		s.setTxConfig(req.Mode, iso)
	case "setIsolation":
		if !validIsolation(engine, req.Isolation) {
			out.Error = newError("unsupported", "This database does not support that isolation level.")
			return out
		}
		if s.txLocked() != "idle" {
			out.Error = newError("transactionOpen", "Commit or roll back the open transaction before changing the isolation level.")
			return out
		}
		if s.conn != nil && req.Isolation != iso {
			if err := s.applyIsolationLocked(req.Isolation); err != nil {
				out.Error = s.ds.classify(err)
				return out
			}
		}
		s.setTxConfig(mode, req.Isolation)
	case "commit", "rollback":
		if s.conn == nil || s.txLocked() == "idle" {
			return out
		}
		sql := "COMMIT"
		if req.Action == "rollback" {
			sql = "ROLLBACK"
		}
		if _, err := s.execLocked(sql, nil); err != nil {
			out.Error = s.ds.classify(err)
		}
		s.tracked = "idle"
	default:
		out.Error = newError("internal", "GoLens does not know that transaction action.")
	}
	return out
}

func (ds *dataSource) classify(err error) *Error {
	ds.mu.Lock()
	secret := ds.secret
	ds.mu.Unlock()
	return classifyError(err, secret)
}

func (s *session) emitStateUnlocked() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.emitState()
}
