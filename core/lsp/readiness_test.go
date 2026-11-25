package lsp

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeTimers struct {
	mu      sync.Mutex
	pending []*fakeTimer
}

type fakeTimer struct {
	d       time.Duration
	fn      func()
	stopped bool
}

func (f *fakeTimers) afterFunc(d time.Duration, fn func()) *time.Timer {
	f.mu.Lock()
	f.pending = append(f.pending, &fakeTimer{d: d, fn: fn})
	f.mu.Unlock()
	return time.NewTimer(time.Hour)
}

func (f *fakeTimers) fire(d time.Duration) bool {
	f.mu.Lock()
	var hit *fakeTimer
	for _, t := range f.pending {
		if t.d == d && !t.stopped {
			hit = t
			t.stopped = true
			break
		}
	}
	f.mu.Unlock()
	if hit == nil {
		return false
	}
	hit.fn()
	return true
}

type stateLog struct {
	mu     sync.Mutex
	states []string
}

func (l *stateLog) report(state, detail string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if detail != "" {
		state += ":" + detail
	}
	l.states = append(l.states, state)
}

func (l *stateLog) get() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.Clone(l.states)
}

func newTestReadiness(remote bool) (*readiness, *stateLog, *fakeTimers) {
	log := &stateLog{}
	timers := &fakeTimers{}
	r := newReadiness(remote, log.report)
	r.afterFunc = timers.afterFunc
	return r, log, timers
}

func TestReadyWaitsForInitialWorkspaceLoad(t *testing.T) {
	r, log, _ := newTestReadiness(true)
	r.initializedSent(1)
	if got := log.get(); !slices.Equal(got, []string{"indexing:Setting up workspace"}) {
		t.Fatalf("after initialized: %v", got)
	}
	r.progress("1", "begin", "Setting up workspace")
	r.progress("2", "begin", "Running go generate")
	r.progress("2", "end", "")
	if r.isReady() {
		t.Fatal("ready before the initial load ended")
	}
	r.progress("1", "end", "")
	got := log.get()
	if got[len(got)-1] != "ready" || !r.isReady() {
		t.Fatalf("not ready after initial load ended: %v", got)
	}
	if slices.Contains(got[:len(got)-1], "ready") {
		t.Fatalf("ready reported early: %v", got)
	}
}

func TestReadyHandlesProgressBeforeInitializedReturns(t *testing.T) {
	r, log, _ := newTestReadiness(false)
	r.progress("1", "begin", "Setting up workspace")
	r.progress("1", "end", "")
	if slices.Contains(log.get(), "ready") {
		t.Fatalf("ready before initialized was sent: %v", log.get())
	}
	r.initializedSent(1)
	if got := log.get(); got[len(got)-1] != "ready" {
		t.Fatalf("load already finished, want ready: %v", got)
	}
}

func TestReadyWaitsForEveryWorkspaceFolder(t *testing.T) {
	r, log, _ := newTestReadiness(true)
	r.initializedSent(2)
	r.progress("a", "begin", "Setting up workspace")
	r.progress("a", "end", "")
	if r.isReady() || slices.Contains(log.get(), "ready") {
		t.Fatalf("ready after one of two folders: %v", log.get())
	}
	r.progress("b", "begin", "Setting up workspace")
	r.progress("b", "end", "")
	if !r.isReady() {
		t.Fatalf("not ready after both folders: %v", log.get())
	}
}

func TestReadyFallsBackWhenGoplsSendsNoProgress(t *testing.T) {
	r, log, timers := newTestReadiness(true)
	r.initializedSent(1)
	if r.isReady() {
		t.Fatal("ready immediately")
	}
	if !timers.fire(readinessTimeoutsFor(true).firstProgress) {
		t.Fatal("no first-progress timer armed")
	}
	if got := log.get(); got[len(got)-1] != "ready" {
		t.Fatalf("fallback did not report ready: %v", got)
	}
}

func TestReadyFallsBackWhenInitialLoadNeverEnds(t *testing.T) {
	r, log, timers := newTestReadiness(false)
	r.initializedSent(1)
	r.progress("1", "begin", "Setting up workspace")
	timers.fire(readinessTimeoutsFor(false).firstProgress)
	if r.isReady() || slices.Contains(log.get(), "ready") {
		t.Fatalf("first-progress fallback overrode a running load: %v", log.get())
	}
	if !timers.fire(readinessTimeoutsFor(false).initialLoad) {
		t.Fatal("no initial-load cap armed")
	}
	if got := log.get(); got[len(got)-1] != "ready" {
		t.Fatalf("cap did not report ready: %v", got)
	}
	r.progress("2", "begin", "Running vulncheck")
	r.progress("2", "end", "")
	got := log.get()
	if got[len(got)-2] != "indexing:Running vulncheck" || got[len(got)-1] != "ready" {
		t.Fatalf("later progress not tracked: %v", got)
	}
}

func TestReadinessSilentAfterClose(t *testing.T) {
	r, log, timers := newTestReadiness(true)
	r.initializedSent(1)
	r.close()
	n := len(log.get())
	timers.fire(readinessTimeoutsFor(true).firstProgress)
	r.progress("1", "begin", "Setting up workspace")
	r.progress("1", "end", "")
	if len(log.get()) != n {
		t.Fatalf("closed readiness kept reporting: %v", log.get())
	}
}

type scriptedProbe struct {
	mu      sync.Mutex
	results map[string][]guestProbeResult
	calls   []string
}

func (p *scriptedProbe) probe(_ context.Context, dir string) guestProbeResult {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls = append(p.calls, dir)
	seq := p.results[dir]
	if len(seq) == 0 {
		return guestDirMissing
	}
	r := seq[0]
	if len(seq) > 1 {
		p.results[dir] = seq[1:]
	}
	return r
}

func fakeWaiter(p *scriptedProbe, budget time.Duration) (shareWaiter, *[]time.Duration) {
	now := time.Unix(0, 0)
	var slept []time.Duration
	return shareWaiter{
		probe:  p.probe,
		sleep:  func(_ context.Context, d time.Duration) bool { slept = append(slept, d); now = now.Add(d); return true },
		now:    func() time.Time { return now },
		budget: budget,
	}, &slept
}

func TestShareWaitRetriesUntilFolderAppears(t *testing.T) {
	p := &scriptedProbe{results: map[string][]guestProbeResult{
		"/workspaces/app-1": {guestDirMissing, guestDirMissing, guestDirMissing, guestDirVisible},
	}}
	w, slept := fakeWaiter(p, 15*time.Second)
	slug, err := w.wait(context.Background(), []string{"app-1"})
	if err != nil || slug != "app-1" {
		t.Fatalf("wait = %q, %v", slug, err)
	}
	if !slices.Equal(*slept, []time.Duration{100 * time.Millisecond, 200 * time.Millisecond, 400 * time.Millisecond}) {
		t.Fatalf("backoff = %v", *slept)
	}
}

func TestShareWaitPicksTheVisibleSlugSpelling(t *testing.T) {
	p := &scriptedProbe{results: map[string][]guestProbeResult{
		"/workspaces/nfd-1": {guestDirMissing},
		"/workspaces/raw-2": {guestDirVisible},
	}}
	w, _ := fakeWaiter(p, time.Second)
	slug, err := w.wait(context.Background(), []string{"nfd-1", "raw-2"})
	if err != nil || slug != "raw-2" {
		t.Fatalf("wait = %q, %v", slug, err)
	}
}

func TestShareWaitGivesUpWithClearError(t *testing.T) {
	p := &scriptedProbe{results: map[string][]guestProbeResult{}}
	w, slept := fakeWaiter(p, 15*time.Second)
	_, err := w.wait(context.Background(), []string{"gone-1"})
	if !errors.Is(err, errWorkspaceNotVisible) {
		t.Fatalf("err = %v", err)
	}
	var total time.Duration
	for _, d := range *slept {
		total += d
		if d > shareRetryMax {
			t.Fatalf("sleep %v above cap", d)
		}
	}
	if total != 15*time.Second {
		t.Fatalf("waited %v, want the whole 15s budget", total)
	}
	if !strings.Contains(err.Error(), "not visible inside the Linux VM") {
		t.Fatalf("error not plain language: %v", err)
	}
}

func TestShareWaitDoesNotBlockWhenProbeUnavailable(t *testing.T) {
	p := &scriptedProbe{results: map[string][]guestProbeResult{
		"/workspaces/a-1": {guestProbeUnavailable},
		"/workspaces/a-2": {guestProbeUnavailable},
	}}
	w, slept := fakeWaiter(p, 15*time.Second)
	slug, err := w.wait(context.Background(), []string{"a-1", "a-2"})
	if err != nil || slug != "a-1" || len(*slept) != 0 {
		t.Fatalf("wait = %q, %v after %v", slug, err, *slept)
	}
}

func TestShareWaitStopsOnCancel(t *testing.T) {
	p := &scriptedProbe{results: map[string][]guestProbeResult{}}
	w, _ := fakeWaiter(p, 15*time.Second)
	w.sleep = func(context.Context, time.Duration) bool { return false }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := w.wait(ctx, []string{"x"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
}
