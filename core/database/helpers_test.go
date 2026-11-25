package database

import (
	"database/sql/driver"
	"encoding/json"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"

	"modernc.org/sqlite"
)

type fakeTimer struct {
	at      time.Time
	f       func()
	stopped bool
}

func (t *fakeTimer) Stop() bool {
	was := !t.stopped
	t.stopped = true
	return was
}

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeTimer
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) AfterFunc(d time.Duration, f func()) stopper {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := &fakeTimer{at: c.now.Add(d), f: f}
	c.timers = append(c.timers, t)
	return t
}

func (c *fakeClock) active() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, t := range c.timers {
		if !t.stopped {
			n++
		}
	}
	return n
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	var due []*fakeTimer
	for _, t := range c.timers {
		if !t.stopped && !t.at.After(c.now) {
			t.stopped = true
			due = append(due, t)
		}
	}
	c.mu.Unlock()
	sort.Slice(due, func(i, j int) bool { return due[i].at.Before(due[j].at) })
	for _, t := range due {
		t.f()
	}
}

type eventLog struct {
	mu     sync.Mutex
	events []Event
}

func (l *eventLog) all() []Event {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]Event(nil), l.events...)
}

type env struct {
	t     testing.TB
	clock *fakeClock
	root  string
	log   *eventLog
}

func newEnv(t testing.TB) *env {
	t.Helper()
	e := &env{t: t, clock: &fakeClock{now: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}, root: t.TempDir(), log: &eventLog{}}
	prevReg, prevEmit, prevLimit, prevRoot, prevCache := reg, emitStatus, spoolState.limit, spoolState.root, schemaCacheRoot
	reg = &registry{clk: e.clock}
	spoolState.root = filepath.Join(t.TempDir(), "spool")
	schemaCacheRoot = filepath.Join(t.TempDir(), "schema")
	prevHistory := historyState.root
	SetHistoryDirectory(filepath.Join(t.TempDir(), "history"))
	emitStatus = func(topic, payload string) {
		var ev Event
		if json.Unmarshal([]byte(payload), &ev) == nil {
			e.log.mu.Lock()
			e.log.events = append(e.log.events, ev)
			e.log.mu.Unlock()
		}
	}
	t.Cleanup(func() {
		reg.mu.Lock()
		roots := map[string]bool{}
		for _, ds := range reg.sources {
			roots[ds.root] = true
		}
		reg.mu.Unlock()
		for r := range roots {
			ShutdownWorkspace(r)
		}
		reg, emitStatus, spoolState.limit, spoolState.root, schemaCacheRoot = prevReg, prevEmit, prevLimit, prevRoot, prevCache
		SetHistoryDirectory(prevHistory)
	})
	return e
}

func (e *env) sqliteDB(name string, stmts ...string) string {
	e.t.Helper()
	path := filepath.Join(e.root, name)
	dc, err := (&sqlite.Driver{}).Open(path)
	if err != nil {
		e.t.Fatal(err)
	}
	defer dc.Close()
	for _, s := range stmts {
		if _, err := dc.(driver.ExecerContext).ExecContext(t0(), s, nil); err != nil {
			e.t.Fatalf("%s: %v", s, err)
		}
	}
	return name
}

func (e *env) configure(defs ...Definition) {
	e.t.Helper()
	b, _ := json.Marshal(DataSourcesFile{Version: 1, DataSources: defs})
	if res := Configure(e.root, string(b)); len(res.Issues) > 0 {
		e.t.Fatalf("issues: %+v", res.Issues)
	}
}

func sqliteDef(id, path string) Definition {
	return Definition{ID: id, Name: "fixture", Engine: EngineSQLite, Password: "none", SQLitePath: path}
}

func (e *env) exec(req ExecuteRequest) ExecuteResponse {
	e.t.Helper()
	if req.ExecID == "" {
		req.ExecID = "exec-" + time.Now().Format("150405.000000000")
	}
	if req.ConsoleID == "" {
		req.ConsoleID = "console-1"
	}
	if req.Mode == "" {
		req.Mode = "all"
	}
	req.WorkspaceRoot = e.root
	return Execute(req)
}

func mustPage(t testing.TB, id string, first int64, n int) *DecodedPage {
	t.Helper()
	b, ok := FetchPage(id, first, n)
	if !ok {
		t.Fatalf("unknown result %s", id)
	}
	p, err := DecodePage(b)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func (l *eventLog) has(event, execID string) bool {
	for _, ev := range l.all() {
		if ev.Event == event && ev.ExecID == execID {
			return true
		}
	}
	return false
}
