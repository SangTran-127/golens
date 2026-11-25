package database

import (
	"context"
	"encoding/json"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
)

const (
	metaPoolSize    = 2
	metaIdleTimeout = 2 * time.Minute
	consoleIdle     = 15 * time.Minute
)

type stopper interface{ Stop() bool }

type clock interface {
	Now() time.Time
	AfterFunc(d time.Duration, f func()) stopper
}

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

func (realClock) AfterFunc(d time.Duration, f func()) stopper { return time.AfterFunc(d, f) }

var emitStatus = func(topic, payload string) { bridge.Status(topic, payload) }

func emit(ev Event) {
	b, err := json.Marshal(ev)
	if err == nil {
		emitStatus("database", string(b))
	}
}

type metaPool struct {
	sem   chan struct{}
	idle  []engineConn
	open  int
	timer stopper
}

type dataSource struct {
	id        string
	def       Definition
	root      string
	mu        sync.Mutex
	secret    string
	hasSecret bool
	pool      metaPool
	snap      *snapshot
	snapStale bool
	introMu   sync.Mutex
	removed   bool
}

type registry struct {
	mu       sync.Mutex
	sources  map[string]*dataSource
	sessions map[string]*session
	results  map[string]*result
	execs    map[string]*session
	ops      map[string]func()
	clk      clock
	cleaned  bool
}

var reg = &registry{clk: realClock{}}

func (r *registry) init() {
	if r.sources == nil {
		r.sources = map[string]*dataSource{}
		r.sessions = map[string]*session{}
		r.results = map[string]*result{}
		r.execs = map[string]*session{}
		r.ops = map[string]func(){}
	}
}

func (r *registry) source(id string) *dataSource {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	return r.sources[id]
}

func (ds *dataSource) definition() Definition {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	return ds.def
}

func needsSecret(def Definition) bool {
	return def.Engine != EngineSQLite && (def.Password == "keychain" || def.Password == "ask")
}

func (ds *dataSource) dialOptions(meta bool) (dialOptions, *Error) {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	if needsSecret(ds.def) && !ds.hasSecret {
		return dialOptions{}, &Error{Kind: "needsSecret", Message: fmt.Sprintf("Enter the password for %s to connect.", ds.def.Name)}
	}
	return dialOptions{def: ds.def, root: ds.root, secret: ds.secret, meta: meta}, nil
}

func (ds *dataSource) connectError(err error) *Error {
	ds.mu.Lock()
	def, secret := ds.def, ds.secret
	ds.mu.Unlock()
	if mf, ok := err.(*missingFileError); ok {
		return sqliteMissingFileError(mf)
	}
	if se, ok := err.(*sshError); ok {
		return &Error{Kind: "connect", Message: se.message}
	}
	e := classifyConnectError(err, &def, secret)
	if e.Kind == "auth" {
		e.Message = fmt.Sprintf("The server did not accept the user name or password for %s. Check them in Edit Data Source.", def.Name)
		ds.mu.Lock()
		ds.secret, ds.hasSecret = "", false
		ds.mu.Unlock()
	}
	return e
}

func (ds *dataSource) acquireMeta(ctx context.Context) (engineConn, *Error) {
	opts, e := ds.dialOptions(true)
	if e != nil {
		return nil, e
	}
	ds.mu.Lock()
	if ds.pool.sem == nil {
		ds.pool.sem = make(chan struct{}, metaPoolSize)
	}
	sem := ds.pool.sem
	ds.mu.Unlock()
	select {
	case sem <- struct{}{}:
	case <-ctx.Done():
		return nil, classifyError(ctx.Err(), "")
	}
	ds.mu.Lock()
	if ds.pool.timer != nil {
		ds.pool.timer.Stop()
		ds.pool.timer = nil
	}
	for len(ds.pool.idle) > 0 {
		c := ds.pool.idle[len(ds.pool.idle)-1]
		ds.pool.idle = ds.pool.idle[:len(ds.pool.idle)-1]
		if !c.broken() {
			ds.mu.Unlock()
			return c, nil
		}
		ds.pool.open--
		c.close()
	}
	ds.pool.open++
	ds.mu.Unlock()
	c, err := dial(ctx, opts)
	if err != nil {
		ds.mu.Lock()
		ds.pool.open--
		ds.mu.Unlock()
		<-sem
		return nil, ds.connectError(err)
	}
	return c, nil
}

func (ds *dataSource) releaseMeta(c engineConn) {
	ds.mu.Lock()
	if c.broken() || ds.removed {
		ds.pool.open--
		c.close()
	} else {
		ds.pool.idle = append(ds.pool.idle, c)
	}
	if ds.pool.timer != nil {
		ds.pool.timer.Stop()
		ds.pool.timer = nil
	}
	if len(ds.pool.idle) > 0 {
		ds.pool.timer = reg.clk.AfterFunc(metaIdleTimeout, ds.closeIdleMeta)
	}
	sem := ds.pool.sem
	ds.mu.Unlock()
	<-sem
}

func (ds *dataSource) closeIdleMeta() {
	ds.mu.Lock()
	idle := ds.pool.idle
	ds.pool.idle = nil
	ds.pool.open -= len(idle)
	if ds.pool.timer != nil {
		ds.pool.timer.Stop()
		ds.pool.timer = nil
	}
	ds.mu.Unlock()
	for _, c := range idle {
		c.close()
	}
}

func (ds *dataSource) withMeta(ctx context.Context, fn func(engineConn) error) *Error {
	c, e := ds.acquireMeta(ctx)
	if e != nil {
		return e
	}
	err := fn(c)
	ds.releaseMeta(c)
	if err != nil {
		ds.mu.Lock()
		secret := ds.secret
		ds.mu.Unlock()
		return classifyError(err, secret)
	}
	return nil
}

func (ds *dataSource) killQuery(ctx context.Context, id string) error {
	if e := ds.withMeta(ctx, func(c engineConn) error {
		_, _, err := c.run(ctx, "KILL QUERY "+id, nil, classification{kind: "other"})
		return err
	}); e != nil {
		return fmt.Errorf("%s", e.Message)
	}
	return nil
}

func (ds *dataSource) markStale() {
	ds.mu.Lock()
	ds.snapStale = true
	ds.mu.Unlock()
}

func validate(defs []Definition) []Issue {
	issues := []Issue{}
	seen := map[string]bool{}
	add := func(id, field, msg string) { issues = append(issues, Issue{ID: id, Field: field, Message: msg}) }
	for _, d := range defs {
		if d.ID == "" {
			add("", "id", "A data source has no identifier. Remove it and add it again.")
			continue
		}
		if seen[d.ID] {
			add(d.ID, "id", "Two data sources share the same identifier. Duplicate one of them again.")
		}
		seen[d.ID] = true
		if strings.TrimSpace(d.Name) == "" {
			add(d.ID, "name", "Enter a name for the data source.")
		}
		switch d.Engine {
		case EnginePostgres, EngineMySQL:
			if strings.TrimSpace(d.Host) == "" {
				add(d.ID, "host", "Enter the host name of the database server.")
			}
			if d.Port <= 0 || d.Port > 65535 {
				add(d.ID, "port", "Enter a port between 1 and 65535.")
			}
			if strings.TrimSpace(d.User) == "" {
				add(d.ID, "user", "Enter the user name for the database server.")
			}
			switch d.Password {
			case "keychain", "ask", "none":
			default:
				add(d.ID, "password", "Choose how GoLens gets the password.")
			}
			switch d.SSL.Mode {
			case "", "disable", "prefer", "require", "verify-ca", "verify-full":
			default:
				add(d.ID, "ssl.mode", "Choose an SSL mode.")
			}
			if (d.SSL.Cert == "") != (d.SSL.Key == "") {
				add(d.ID, "ssl.key", "Choose both the client certificate and its key, or neither.")
			}
		case EngineSQLite:
			if strings.TrimSpace(d.SQLitePath) == "" {
				add(d.ID, "sqlitePath", "Choose the SQLite database file.")
			}
		default:
			add(d.ID, "engine", "Choose PostgreSQL, MySQL or SQLite.")
		}
		validateSSH(d, add)
	}
	return issues
}

func Configure(root, dataSourcesJSON string) ConfigureResult {
	var file DataSourcesFile
	if err := json.Unmarshal([]byte(dataSourcesJSON), &file); err != nil {
		return ConfigureResult{Issues: []Issue{{Field: "file", Message: "GoLens could not read the data source definitions."}}}
	}
	issues := validate(file.DataSources)
	reg.mu.Lock()
	reg.init()
	first := !reg.cleaned
	reg.cleaned = true
	keep := map[string]bool{}
	var closeSources []*dataSource
	var reconnect []*dataSource
	for _, d := range file.DataSources {
		if d.ID == "" {
			continue
		}
		keep[d.ID] = true
		if ds, ok := reg.sources[d.ID]; ok {
			ds.mu.Lock()
			changed := ds.def != d || ds.root != root
			identity := connectionIdentity(ds.def, ds.root) != connectionIdentity(d, root)
			ds.def, ds.root = d, root
			if identity {
				ds.snap = nil
			}
			ds.mu.Unlock()
			if changed {
				reconnect = append(reconnect, ds)
			}
			continue
		}
		reg.sources[d.ID] = &dataSource{id: d.ID, def: d, root: root}
	}
	for id, ds := range reg.sources {
		if ds.root == root && !keep[id] {
			closeSources = append(closeSources, ds)
			delete(reg.sources, id)
		}
	}
	reg.mu.Unlock()
	if first {
		cleanStaleSpools()
	}
	for _, ds := range reconnect {
		ds.disconnect(false)
	}
	for _, ds := range closeSources {
		ds.mu.Lock()
		ds.removed = true
		ds.mu.Unlock()
		ds.disconnect(true)
	}
	return ConfigureResult{Issues: issues}
}

func (ds *dataSource) sessions() []*session {
	reg.mu.Lock()
	defer reg.mu.Unlock()
	var out []*session
	for _, s := range reg.sessions {
		if s.ds == ds {
			out = append(out, s)
		}
	}
	return out
}

func (ds *dataSource) disconnect(dropSecret bool) bool {
	hadTx := false
	for _, s := range ds.sessions() {
		if s.closeConn(true) {
			hadTx = true
		}
	}
	ds.closeIdleMeta()
	tunnels.stopDataSource(ds.id)
	ds.mu.Lock()
	if dropSecret {
		ds.secret, ds.hasSecret = "", false
		ds.snap = nil
	}
	ds.mu.Unlock()
	return hadTx
}

func SetSecret(id, secret string) OKResult {
	ds := reg.source(id)
	if ds == nil {
		return OKResult{OK: false}
	}
	ds.mu.Lock()
	ds.secret, ds.hasSecret = secret, true
	ds.mu.Unlock()
	return OKResult{OK: true}
}

func Disconnect(id string) DisconnectResult {
	ds := reg.source(id)
	if ds == nil {
		return DisconnectResult{OK: true}
	}
	return DisconnectResult{OK: true, HadOpenTransaction: ds.disconnect(true)}
}

func CloseConsole(id string, force bool) DisconnectResult {
	reg.mu.Lock()
	reg.init()
	s := reg.sessions[id]
	reg.mu.Unlock()
	if s == nil {
		return DisconnectResult{OK: true}
	}
	if !force && s.transactionOpen() {
		return DisconnectResult{OK: false, HadOpenTransaction: true}
	}
	wasConnected := s.connected()
	hadTx := s.closeConn(true)
	var results []*result
	removed := false
	reg.mu.Lock()
	if reg.sessions[id] == s {
		delete(reg.sessions, id)
		removed = true
	}
	for _, r := range reg.results {
		if r.sess == s {
			results = append(results, r)
		}
	}
	reg.mu.Unlock()
	for _, r := range results {
		CloseResult(r.id)
	}
	closedCount := len(results)
	s = nil
	results = nil
	if closedCount == 0 && (wasConnected || removed) {
		releaseMemory()
	}
	return DisconnectResult{OK: true, HadOpenTransaction: hadTx}
}

func ShutdownWorkspace(root string) {
	reg.mu.Lock()
	reg.init()
	var sources []*dataSource
	for id, ds := range reg.sources {
		if ds.root == root {
			sources = append(sources, ds)
			delete(reg.sources, id)
		}
	}
	var results []*result
	for _, r := range reg.results {
		for _, ds := range sources {
			if r.sess.ds == ds {
				results = append(results, r)
			}
		}
	}
	reg.mu.Unlock()
	for _, ds := range sources {
		ds.mu.Lock()
		ds.removed = true
		ds.mu.Unlock()
		ds.disconnect(true)
		reg.mu.Lock()
		for id, s := range reg.sessions {
			if s.ds == ds {
				delete(reg.sessions, id)
			}
		}
		reg.mu.Unlock()
	}
	for _, r := range results {
		CloseResult(r.id)
	}
}

func GetStats() Stats {
	reg.mu.Lock()
	reg.init()
	st := Stats{OpenResults: len(reg.results)}
	sessions := make([]*session, 0, len(reg.sessions))
	for _, s := range reg.sessions {
		sessions = append(sessions, s)
	}
	sources := make([]*dataSource, 0, len(reg.sources))
	for _, ds := range reg.sources {
		sources = append(sources, ds)
	}
	reg.mu.Unlock()
	for _, s := range sessions {
		if s.connected() {
			st.Sessions++
		}
	}
	for _, ds := range sources {
		ds.mu.Lock()
		if ds.pool.open > 0 {
			st.Pools++
		}
		ds.mu.Unlock()
	}
	st.SpoolMemBytes, st.SpoolDiskBytes = spoolTotals()
	st.Tunnels = tunnels.info()
	st.Goroutines = runtime.NumGoroutine()
	return st
}

func connectionIdentity(d Definition, root string) string {
	if d.Engine == EngineSQLite {
		return d.Engine + "|" + resolvePath(root, d.SQLitePath)
	}
	return strings.Join([]string{d.Engine, d.Host, fmt.Sprint(d.Port), d.Database, d.User}, "|")
}
