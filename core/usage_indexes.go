package main

import (
	"path/filepath"
	"strings"
	"sync"

	"golens/core/usageindex"
)

type usageIndexes struct {
	OnInvalidate func(path string)

	log      func(string)
	mu       sync.Mutex
	enabled  bool
	byRoot   map[string]*usageindex.Service
	hostOpts *usageindex.Options
}

func newUsageIndexes(log func(string)) *usageIndexes {
	return &usageIndexes{log: log, enabled: true, byRoot: map[string]*usageindex.Service{}}
}

func (u *usageIndexes) Open(root string) {
	root = filepath.Clean(root)
	u.mu.Lock()
	if _, ok := u.byRoot[root]; ok {
		u.mu.Unlock()
		return
	}
	s := usageindex.NewService(u.log)
	if !u.enabled {
		s.SetEnabled(false)
	}
	s.Open(root)
	u.byRoot[root] = s
	opts := u.hostOpts
	u.mu.Unlock()
	if opts != nil {
		s.Start(root, *opts)
	}
}

func (u *usageIndexes) CloseRoot(root string) {
	root = filepath.Clean(root)
	u.mu.Lock()
	s := u.byRoot[root]
	delete(u.byRoot, root)
	u.mu.Unlock()
	if s != nil {
		s.Close()
	}
}

func (u *usageIndexes) Close() {
	u.mu.Lock()
	all := u.byRoot
	u.byRoot = map[string]*usageindex.Service{}
	u.hostOpts = nil
	u.mu.Unlock()
	for _, s := range all {
		s.Close()
	}
}

func (u *usageIndexes) Start(root string, opts usageindex.Options, host bool) {
	u.mu.Lock()
	targets := map[string]*usageindex.Service{}
	if host {
		o := opts
		u.hostOpts = &o
		for r, s := range u.byRoot {
			targets[r] = s
		}
	} else {
		u.hostOpts = nil
		if s := u.byRoot[filepath.Clean(root)]; s != nil {
			targets[filepath.Clean(root)] = s
		}
	}
	u.mu.Unlock()
	for r, s := range targets {
		s.Start(r, opts)
	}
}

func (u *usageIndexes) SetEnabled(on bool) {
	u.mu.Lock()
	u.enabled = on
	all := make([]*usageindex.Service, 0, len(u.byRoot))
	for _, s := range u.byRoot {
		all = append(all, s)
	}
	u.mu.Unlock()
	for _, s := range all {
		s.SetEnabled(on)
	}
}

func (u *usageIndexes) owner(path string) *usageindex.Service {
	path = filepath.Clean(path)
	u.mu.Lock()
	defer u.mu.Unlock()
	best := ""
	for r := range u.byRoot {
		if (path == r || strings.HasPrefix(path, r+"/")) && len(r) > len(best) {
			best = r
		}
	}
	if best == "" {
		return nil
	}
	return u.byRoot[best]
}

func (u *usageIndexes) Query(path string) usageindex.Reply {
	if s := u.owner(path); s != nil {
		return s.Query(path)
	}
	return usageindex.Reply{State: usageindex.StateUnavailable, Reason: "the file is outside the workspace"}
}

func (u *usageIndexes) MarkDirty(path string) {
	if s := u.owner(path); s != nil {
		s.MarkDirty(path)
	}
}

func (u *usageIndexes) Invalidate(path string) {
	if u.OnInvalidate != nil {
		u.OnInvalidate(path)
	}
	if s := u.owner(path); s != nil {
		s.Invalidate(path)
	}
}
