package lsp

import (
	"strings"
	"sync"
	"time"
)

const initialLoadTitle = "Setting up workspace"

type readinessTimeouts struct {
	firstProgress time.Duration
	initialLoad   time.Duration
}

func readinessTimeoutsFor(remote bool) readinessTimeouts {
	if remote {
		return readinessTimeouts{firstProgress: 30 * time.Second, initialLoad: 5 * time.Minute}
	}
	return readinessTimeouts{firstProgress: 10 * time.Second, initialLoad: 3 * time.Minute}
}

type readiness struct {
	mu        sync.Mutex
	report    func(state, detail string)
	timeouts  readinessTimeouts
	afterFunc func(time.Duration, func()) *time.Timer

	active      map[string]string
	initial     map[string]bool
	expected    int
	endedLoads  int
	sawLoad     bool
	loaded      bool
	initialized bool
	closed      bool
	lastState   string
	timer       *time.Timer
}

func newReadiness(remote bool, report func(state, detail string)) *readiness {
	return &readiness{
		report:    report,
		timeouts:  readinessTimeoutsFor(remote),
		afterFunc: time.AfterFunc,
		active:    map[string]string{},
		initial:   map[string]bool{},
		expected:  1,
	}
}

func isInitialLoadTitle(title string) bool {
	return title == initialLoadTitle || strings.Contains(strings.ToLower(title), "loading packages")
}

func (r *readiness) progress(token, kind, title string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	switch kind {
	case "begin":
		r.active[token] = title
		if !r.loaded && isInitialLoadTitle(title) {
			r.initial[token] = true
			if !r.sawLoad {
				r.sawLoad = true
				r.armLocked(r.timeouts.initialLoad, r.loadTimedOut)
			}
		}
		r.emitLocked("indexing", title)
	case "end":
		delete(r.active, token)
		if r.initial[token] {
			delete(r.initial, token)
			r.endedLoads++
			if r.initialized && r.endedLoads >= r.expected {
				r.markLoadedLocked()
			}
		}
		r.settleLocked()
	}
}

func (r *readiness) initializedSent(folders int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.initialized = true
	r.expected = max(1, folders)
	if r.endedLoads >= r.expected {
		r.markLoadedLocked()
	}
	if !r.loaded {
		if !r.sawLoad {
			r.armLocked(r.timeouts.firstProgress, r.firstProgressTimedOut)
		}
		if len(r.active) == 0 {
			r.emitLocked("indexing", initialLoadTitle)
		}
	}
	r.settleLocked()
}

func (r *readiness) firstProgressTimedOut() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.sawLoad || r.loaded {
		return
	}
	r.markLoadedLocked()
	r.settleLocked()
}

func (r *readiness) loadTimedOut() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.loaded {
		return
	}
	for token := range r.initial {
		delete(r.active, token)
	}
	clear(r.initial)
	r.markLoadedLocked()
	r.settleLocked()
}

func (r *readiness) markLoadedLocked() {
	r.loaded = true
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
}

func (r *readiness) settleLocked() {
	if !r.initialized || !r.loaded {
		return
	}
	if len(r.active) == 0 {
		r.emitLocked("ready", "")
		return
	}
	for _, title := range r.active {
		r.emitLocked("indexing", title)
		return
	}
}

func (r *readiness) armLocked(d time.Duration, fn func()) {
	if r.timer != nil {
		r.timer.Stop()
	}
	r.timer = r.afterFunc(d, fn)
}

func (r *readiness) emitLocked(state, detail string) {
	key := state + "\x00" + detail
	if key == r.lastState {
		return
	}
	r.lastState = key
	r.report(state, detail)
}

func (r *readiness) isReady() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.initialized && r.loaded && len(r.active) == 0
}

func (r *readiness) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	if r.timer != nil {
		r.timer.Stop()
		r.timer = nil
	}
}
