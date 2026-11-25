package docs

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const maxCachedWorkspaces = 4

type cacheKey struct {
	Root   string
	Target Target
}

type cachedWorkspace struct {
	Key        cacheKey
	Stamp      string
	Index      *Index
	Generation int64
	LastUsed   int64
	Exported   []searchEntry
	Unexported []searchEntry
}

type inflightLoad struct {
	done      chan struct{}
	idx       *Index
	entry     *cachedWorkspace
	err       error
	invalSnap int64
}

type Service struct {
	mu          sync.Mutex
	entries     map[cacheKey]*cachedWorkspace
	inflight    map[cacheKey]*inflightLoad
	invalByRoot map[string]int64
	globalInval int64
	invalSeq    int64
	reqs        map[string]context.CancelFunc
	gen         atomic.Int64
	tick        atomic.Int64
}

var DefaultService = NewService()

func NewService() *Service {
	return &Service{
		entries:     map[cacheKey]*cachedWorkspace{},
		inflight:    map[cacheKey]*inflightLoad{},
		invalByRoot: map[string]int64{},
		reqs:        map[string]context.CancelFunc{},
	}
}

func (s *Service) CurrentGeneration() int64 {
	return s.gen.Load()
}

func (s *Service) Invalidate(root string) {
	canon := canonicalRoot(root)
	s.gen.Add(1)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invalSeq++
	if canon == "" {
		clear(s.entries)
		s.globalInval = s.invalSeq
		return
	}
	s.invalByRoot[canon] = s.invalSeq
	for k := range s.entries {
		if k.Root == canon {
			delete(s.entries, k)
		}
	}
}

func (s *Service) rootInvalFloorLocked(canon string) int64 {
	return max(s.globalInval, s.invalByRoot[canon])
}

func (s *Service) Cancel(reqID string) {
	reqID = strings.TrimSpace(reqID)
	if reqID == "" {
		return
	}
	s.mu.Lock()
	cancel := s.reqs[reqID]
	delete(s.reqs, reqID)
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *Service) beginRequest(reqID string, timeout time.Duration) (context.Context, context.CancelFunc) {
	ctx, cancel := withTimeout(context.Background(), timeout)
	if reqID == "" {
		return ctx, cancel
	}
	s.mu.Lock()
	if prev := s.reqs[reqID]; prev != nil {
		prev()
	}
	s.reqs[reqID] = cancel
	s.mu.Unlock()
	return ctx, func() {
		s.mu.Lock()
		delete(s.reqs, reqID)
		s.mu.Unlock()
		cancel()
	}
}

func (s *Service) ListPackages(reqID, root string, opts Options) *Index {
	canon := canonicalRoot(root)
	key := cacheKey{Root: canon, Target: normalizeTargetKey(opts.Target, opts.IncludeStd)}
	ctx, finish := s.beginRequest(reqID, opts.Timeout)
	defer finish()

	idx, _, err := s.getOrLoadIndex(ctx, canon, key, opts)
	if err != nil {
		out := &Index{
			Root:       canon,
			Target:     key.Target,
			Generation: s.gen.Add(1),
			Cancelled:  errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled),
			Error:      err.Error(),
			ErrorKind:  classifyLoadError(err.Error(), 0, 0),
		}
		return out
	}
	cp := *idx
	cp.Root = canon
	return &cp
}

func (s *Service) LoadPackagePage(reqID, root, importPath string, opts Options) *PackageDoc {
	canon := canonicalRoot(root)
	normTarget := normalizeTargetKey(opts.Target, opts.IncludeStd)
	key := cacheKey{Root: canon, Target: normTarget}
	ctx, finish := s.beginRequest(reqID, opts.Timeout)
	defer finish()

	idx, entry, idxErr := s.getOrLoadIndex(ctx, canon, key, opts)
	if idxErr != nil {
		return &PackageDoc{
			Root:       canon,
			Generation: s.gen.Load(),
			ImportPath: importPath,
			Target:     normTarget,
			Cancelled:  errors.Is(idxErr, context.Canceled) || errors.Is(ctx.Err(), context.Canceled),
			Error:      idxErr.Error(),
			ErrorKind:  classifyLoadError(idxErr.Error(), 0, 0),
		}
	}

	var matchedPkg *Package
	for i := range idx.Packages {
		if idx.Packages[i].ImportPath == importPath {
			p := idx.Packages[i]
			matchedPkg = &p
			break
		}
	}
	var matchedMod *Module
	if matchedPkg != nil {
		for i := range idx.Modules {
			if idx.Modules[i].Path == matchedPkg.ModulePath {
				m := idx.Modules[i]
				matchedMod = &m
				break
			}
		}
	}

	if matchedPkg != nil && matchedPkg.Missing {
		modPath, modVer := matchedPkg.MissingModule, matchedPkg.MissingVersion
		if modPath == "" && matchedMod != nil {
			modPath, modVer = matchedMod.Path, matchedMod.Version
		}
		return &PackageDoc{
			Root:              canon,
			Generation:        entry.Generation,
			ImportPath:        matchedPkg.ImportPath,
			Name:              matchedPkg.Name,
			Dir:               matchedPkg.Dir,
			Origin:            matchedPkg.Origin,
			Source:            matchedPkg.Source,
			ModulePath:        matchedPkg.ModulePath,
			Version:           matchedPkg.Version,
			Target:            idx.Target,
			MissingSource:     true,
			MissingModule:     modPath,
			MissingVersion:    modVer,
			Error:             firstNonEmpty(matchedPkg.Error, "Dependency source is not downloaded."),
			ErrorKind:         ErrorKindMissingModule,
			IncludeUnexported: opts.IncludeUnexported,
		}
	}

	if matchedPkg != nil && len(opts.Overlay) == 0 && len(matchedPkg.GoFiles) > 0 {
		if pd, err := BuildPackageDocWithOptions(*matchedPkg, idx.Target, opts); err == nil {
			enrichPageDoc(pd, canon, entry.Generation, matchedMod)
			return pd
		}
	}

	pd, err := LoadPackageDoc(ctx, canon, importPath, opts)
	if pd == nil {
		pd = &PackageDoc{
			Root:       canon,
			Generation: entry.Generation,
			ImportPath: importPath,
			Target:     idx.Target,
			Cancelled:  errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled),
		}
	}
	if err != nil && pd.Error == "" {
		var pkgErr *PackageError
		if errors.As(err, &pkgErr) {
			pd.ErrorKind = pkgErr.Kind
			pd.Error = pkgErr.Message
			pd.MissingModule = pkgErr.Module
			pd.MissingVersion = pkgErr.Version
			pd.MissingSource = pkgErr.Kind == ErrorKindMissingModule
		} else {
			pd.Error = err.Error()
			if pd.ErrorKind == "" {
				pd.ErrorKind = classifyLoadError(pd.Error, 0, 0)
			}
		}
	}
	enrichPageDoc(pd, canon, entry.Generation, matchedMod)
	return pd
}

func enrichPageDoc(pd *PackageDoc, root string, gen int64, mod *Module) {
	pd.Root = root
	pd.Generation = gen
	if mod != nil {
		if pd.ModulePath == "" {
			pd.ModulePath = mod.Path
		}
		if pd.Version == "" {
			pd.Version = mod.Version
		}
		if pd.Source == "" {
			pd.Source = mod.Source
		}
		if mod.Replace != nil {
			pd.ReplacePath = mod.Replace.Path
			pd.ReplaceDir = mod.Replace.Dir
		}
	}
}

func (s *Service) getOrLoadIndex(ctx context.Context, canon string, key cacheKey, opts Options) (*Index, *cachedWorkspace, error) {
	if canon == "" {
		return nil, nil, fmt.Errorf("no workspace path provided")
	}
	for retry := 0; retry < 3; retry++ {
		s.mu.Lock()
		if existing := s.entries[key]; existing != nil {
			if workspaceStamp(canon, existing.Index.GoWork) == existing.Stamp {
				existing.LastUsed = s.tick.Add(1)
				s.mu.Unlock()
				return existing.Index, existing, nil
			}
			delete(s.entries, key)
		}
		if flight := s.inflight[key]; flight != nil {
			s.mu.Unlock()
			select {
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			case <-flight.done:
			}
			s.mu.Lock()
			invalChanged := s.rootInvalFloorLocked(canon) != flight.invalSnap
			s.mu.Unlock()
			if invalChanged {
				continue
			}
			if flight.err != nil {
				if errors.Is(flight.err, context.Canceled) && ctx.Err() == nil {
					continue
				}
				return nil, nil, flight.err
			}
			return flight.idx, flight.entry, nil
		}
		invalSnap := s.rootInvalFloorLocked(canon)
		flight := &inflightLoad{done: make(chan struct{}), invalSnap: invalSnap}
		s.inflight[key] = flight
		s.mu.Unlock()

		optsCopy := opts
		optsCopy.Target = key.Target
		optsCopy.IncludeStd = key.Target.IncludeStd
		idx, err := ListPackages(ctx, canon, optsCopy)
		if err != nil && ctx.Err() != nil {
			err = ctx.Err()
		}

		s.mu.Lock()
		delete(s.inflight, key)
		invalChanged := s.rootInvalFloorLocked(canon) != invalSnap
		if err == nil && !invalChanged {
			gen := s.gen.Add(1)
			idx.Root = canon
			idx.Generation = gen
			entry := &cachedWorkspace{
				Key:        key,
				Stamp:      workspaceStamp(canon, idx.GoWork),
				Index:      idx,
				Generation: gen,
				LastUsed:   s.tick.Add(1),
			}
			s.entries[key] = entry
			s.evictLRULocked()
			flight.idx, flight.entry = idx, entry
		} else if err != nil {
			flight.err = err
		} else {
			flight.err = context.Canceled
		}
		close(flight.done)
		s.mu.Unlock()

		if err == nil && !invalChanged {
			return idx, flight.entry, nil
		}
		if invalChanged && ctx.Err() == nil {
			continue
		}
		if err != nil {
			return nil, nil, err
		}
		return nil, nil, context.Canceled
	}
	return nil, nil, context.Canceled
}

func (s *Service) evictLRULocked() {
	for len(s.entries) > maxCachedWorkspaces {
		var oldestKey cacheKey
		var oldestTick int64
		first := true
		for k, e := range s.entries {
			if first || e.LastUsed < oldestTick {
				oldestKey = k
				oldestTick = e.LastUsed
				first = false
			}
		}
		if first {
			break
		}
		delete(s.entries, oldestKey)
	}
}

func normalizeTargetKey(t Target, includeStd bool) Target {
	return Target{
		GOOS:       strings.TrimSpace(t.GOOS),
		GOARCH:     strings.TrimSpace(t.GOARCH),
		Tags:       strings.TrimSpace(t.Tags),
		IncludeStd: t.IncludeStd || includeStd,
	}
}

func canonicalRoot(root string) string {
	cleaned := filepath.Clean(strings.TrimSpace(root))
	if cleaned == "" || cleaned == "." {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return filepath.Clean(resolved)
	}
	return cleaned
}

func workspaceStamp(root, goWork string) string {
	stamp := ReadSourceStamp(root, []string{"go.mod", "go.sum", "go.work", "go.work.sum"})
	if vDir := detectVendorDir(root, goWork); vDir != "" {
		stamp += ReadSourceStamp(vDir, []string{"modules.txt"})
	}
	return stamp
}
