package usageindex

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"go/types"
	"maps"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	StateBuilding    = "building"
	StateReady       = "ready"
	StateRefreshing  = "refreshing"
	StateUnavailable = "unavailable"
)

const idleRelease = 25 * time.Second

var buildBackoff = []time.Duration{2 * time.Second, 5 * time.Second, 15 * time.Second, 30 * time.Second}

const retryEvery = 60 * time.Second

type Service struct {
	OnInvalidate func(path string)

	log  func(string)
	idle time.Duration
	now  func() time.Time
	wait func(context.Context, time.Duration) bool

	mu         sync.Mutex
	root       string
	enabled    bool
	opts       *Options
	sizes      types.Sizes
	gen        int
	running    bool
	ctx        context.Context
	cancel     context.CancelFunc
	ix         *Index
	state      string
	reason     string
	dirty      map[string]bool
	full       bool
	refreshing map[string]bool
	failed     bool
	timer      *time.Timer
	attempts   int
	retryAt    time.Time

	upd sync.Mutex
}

type Reply struct {
	State  string  `json:"state"`
	Reason string  `json:"reason,omitempty"`
	Counts []Count `json:"counts,omitempty"`
}

type Count struct {
	Line  int   `json:"line"`
	Col   int   `json:"col"`
	Count int   `json:"count"`
	Impls []Loc `json:"impls,omitempty"`
}

func NewService(log func(string)) *Service {
	idle := idleRelease
	if d, err := time.ParseDuration(os.Getenv("GOLENS_USAGE_INDEX_IDLE")); err == nil && d > 0 {
		idle = d
	}
	return &Service{log: log, idle: idle, now: time.Now, wait: waitDelay, enabled: true, state: StateUnavailable, reason: "no workspace is open", dirty: map[string]bool{}}
}

func (s *Service) Open(root string) {
	root = filepath.Clean(root)
	s.mu.Lock()
	if root == s.root {
		s.mu.Unlock()
		return
	}
	prev := s.ix
	reclaim := s.idle >= time.Second
	s.root, s.opts, s.sizes = root, nil, nil
	s.dropLocked()
	s.mu.Unlock()
	reclaimDropped(prev, reclaim)
}

func (s *Service) Close() {
	s.mu.Lock()
	prev := s.ix
	reclaim := s.idle >= time.Second
	s.root, s.opts, s.sizes = "", nil, nil
	s.dropLocked()
	s.mu.Unlock()
	reclaimDropped(prev, reclaim)
}

func (s *Service) Start(root string, opts Options) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if filepath.Clean(root) != s.root || s.root == "" {
		return
	}
	s.opts = &opts
	if s.enabled && s.ix == nil && !s.running {
		s.buildLocked(buildBackoff)
	}
}

func (s *Service) SetEnabled(on bool) {
	s.mu.Lock()
	if on == s.enabled {
		s.mu.Unlock()
		return
	}
	prev := s.ix
	reclaim := s.idle >= time.Second
	s.enabled = on
	s.dropLocked()
	if on && s.opts != nil {
		s.buildLocked(buildBackoff)
	}
	s.mu.Unlock()
	reclaimDropped(prev, reclaim)
}

func reclaimDropped(prev *Index, reclaim bool) {
	if prev != nil && reclaim {
		go func(ix *Index) {
			if ix.releaseTypes() {
				debug.FreeOSMemory()
			}
		}(prev)
	}
}

func (s *Service) MarkDirty(path string) {
	if filepath.Ext(path) != ".go" {
		return
	}
	path = filepath.Clean(path)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.indexedLocked(path) {
		s.dirty[path] = true
	}
}

func (s *Service) Invalidate(path string) {
	if s.OnInvalidate != nil {
		s.OnInvalidate(path)
	}
	switch filepath.Base(path) {
	case "go.mod", "go.work", "go.sum":
	default:
		s.MarkDirty(path)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.indexedLocked(filepath.Clean(path)) || !s.enabled || s.opts == nil {
		return
	}
	if s.ix != nil {
		s.full = true
		return
	}
	s.dropLocked()
	s.buildLocked(buildBackoff)
}

func (s *Service) Query(path string) Reply {
	path = filepath.Clean(path)
	s.upd.Lock()
	defer s.upd.Unlock()
	s.mu.Lock()
	if s.state == StateUnavailable && !s.retryAt.IsZero() && !s.now().Before(s.retryAt) {
		s.buildLocked(nil)
	}
	if s.state != StateReady {
		r := Reply{State: s.state, Reason: s.reason}
		s.mu.Unlock()
		return r
	}
	if !s.underRootLocked(path) {
		s.mu.Unlock()
		return Reply{State: StateUnavailable, Reason: "the file is outside the workspace"}
	}
	ix, ctx, gen := s.ix, s.ctx, s.gen
	if s.refreshing == nil && s.full && !s.failed {
		s.refreshLocked(ix, ctx, gen)
	}
	if s.refreshing != nil {
		return s.refreshingReplyUnlock(ix, path)
	}
	var changed []string
	if !s.failed {
		changed = slices.Collect(maps.Keys(s.dirty))
		clear(s.dirty)
	}
	s.failed = false
	s.mu.Unlock()

	if len(changed) > 0 {
		ok, err := ix.updateInPlace(ctx, changed)
		s.mu.Lock()
		if gen != s.gen {
			r := Reply{State: s.state, Reason: s.reason}
			s.mu.Unlock()
			return r
		}
		if err == nil && !ok {
			for _, p := range changed {
				s.dirty[p] = true
			}
			s.refreshLocked(ix, ctx, gen)
			return s.refreshingReplyUnlock(ix, path)
		}
		if err != nil {
			s.keepDirtyLocked(changed, err)
		}
		s.armIdleLocked(ix)
		s.mu.Unlock()
	}
	return lensReply(StateReady, ix.FileLenses(path))
}

func (s *Service) refreshingReplyUnlock(ix *Index, path string) Reply {
	stale := s.dirty[path] || s.refreshing[path]
	s.mu.Unlock()
	if stale {
		return Reply{State: StateRefreshing}
	}
	return lensReply(StateRefreshing, ix.FileLenses(path))
}

func (s *Service) refreshLocked(ix *Index, ctx context.Context, gen int) {
	changed := slices.Collect(maps.Keys(s.dirty))
	full := s.full
	released := ix.released()
	s.refreshing = maps.Clone(s.dirty)
	clear(s.dirty)
	s.full = false
	if s.timer != nil {
		s.timer.Stop()
	}
	go func() {
		started := time.Now()
		stale, err := ix.reload(ctx)
		s.mu.Lock()
		defer s.mu.Unlock()
		if gen != s.gen {
			return
		}
		s.refreshing = nil
		switch {
		case err != nil:
			s.keepDirtyLocked(changed, err)
			s.full = s.full || full
			s.failed = true
		case released:
			s.log(fmt.Sprintf("usage index rebuilt after its types were released in %d ms", time.Since(started).Milliseconds()))
		default:
			s.log(fmt.Sprintf("usage index rebuilt in the background after a package graph change in %d ms", time.Since(started).Milliseconds()))
		}
		if stale != "" {
			s.log(stale)
		}
		s.armIdleLocked(ix)
	}()
}

func (s *Service) keepDirtyLocked(changed []string, err error) {
	for _, p := range changed {
		s.dirty[p] = true
	}
	s.log("usage index update failed, keeping the last counts: " + err.Error())
}

func lensReply(state string, lenses map[Pos]Lens) Reply {
	r := Reply{State: state, Counts: make([]Count, 0, len(lenses))}
	for pos, l := range lenses {
		r.Counts = append(r.Counts, Count{Line: pos.Line, Col: pos.Col, Count: l.Count, Impls: l.Impls})
	}
	slices.SortFunc(r.Counts, func(a, b Count) int { return cmp.Or(a.Line-b.Line, a.Col-b.Col) })
	return r
}

func (s *Service) dropLocked() {
	s.gen++
	if s.cancel != nil {
		s.cancel()
	}
	s.ctx, s.cancel = nil, nil
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	s.ix, s.running = nil, false
	s.refreshing, s.failed, s.full = nil, false, false
	s.attempts, s.retryAt = 0, time.Time{}
	clear(s.dirty)
	switch {
	case s.root == "":
		s.state, s.reason = StateUnavailable, "no workspace is open"
	case !s.enabled:
		s.state, s.reason = StateUnavailable, "usage counts are turned off"
	default:
		s.state, s.reason = StateBuilding, ""
	}
}

func (s *Service) buildLocked(backoff []time.Duration) {
	ctx, cancel := context.WithCancel(context.Background())
	s.ctx, s.cancel = ctx, cancel
	s.running = true
	s.state, s.reason = StateBuilding, ""
	s.retryAt = time.Time{}
	gen, root, opts, sizes, wait := s.gen, s.root, *s.opts, s.sizes, s.wait
	go func() {
		for {
			started := time.Now()
			ix, stale, err := build(ctx, root, opts, sizes)
			s.mu.Lock()
			if gen != s.gen {
				s.mu.Unlock()
				return
			}
			s.attempts++
			retry := errors.As(err, new(retryableError))
			if err == nil || !retry || len(backoff) == 0 {
				s.finishBuildLocked(root, started, ix, stale, err, retry)
				s.mu.Unlock()
				return
			}
			delay := backoff[0]
			backoff = backoff[1:]
			s.log(fmt.Sprintf("usage index build attempt %d failed for %s, retrying in %v: %v", s.attempts, root, delay, err))
			s.mu.Unlock()
			if !wait(ctx, delay) || ctx.Err() != nil {
				return
			}
		}
	}()
}

func (s *Service) finishBuildLocked(root string, started time.Time, ix *Index, stale string, err error, retry bool) {
	s.running = false
	if err != nil {
		s.state, s.reason = StateUnavailable, err.Error()
		if retry {
			s.retryAt = s.now().Add(retryEvery)
		}
		s.log(fmt.Sprintf("usage index unavailable for %s after attempt %d: %v", root, s.attempts, err))
		return
	}
	s.ix, s.state, s.sizes = ix, StateReady, ix.sizes
	s.armIdleLocked(ix)
	s.log(fmt.Sprintf("usage index ready for %s in %d ms", root, time.Since(started).Milliseconds()))
	if stale != "" {
		s.log(stale)
	}
}

func waitDelay(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func Retryable(err error) error {
	if err == nil {
		return nil
	}
	return retryableError{err}
}

type retryableError struct{ error }

func (e retryableError) Unwrap() error { return e.error }

func (s *Service) armIdleLocked(ix *Index) {
	if s.timer != nil {
		s.timer.Stop()
	}
	reclaim := s.idle >= time.Second
	s.timer = time.AfterFunc(s.idle, func() {
		if ix.releaseTypes() && reclaim {
			debug.FreeOSMemory()
		}
	})
}

func (s *Service) underRootLocked(path string) bool {
	return s.root != "" && strings.HasPrefix(path, s.root+string(filepath.Separator))
}

func (s *Service) indexedLocked(path string) bool {
	if !s.underRootLocked(path) {
		return false
	}
	for _, dir := range strings.Split(filepath.Dir(path[len(s.root)+1:]), string(filepath.Separator)) {
		if dir == "testdata" || dir == "vendor" || strings.HasPrefix(dir, ".") && dir != "." || strings.HasPrefix(dir, "_") {
			return false
		}
	}
	return true
}
