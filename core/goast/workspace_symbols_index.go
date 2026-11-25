package goast

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const (
	workspaceSymbolMaxFiles    = 400
	workspaceSymbolMaxFileSize = 1 << 20
	workspaceSymbolMaxRoots    = 8
)

var workspaceSymbolRefreshInterval = 2 * time.Second

type cachedWorkspaceSymbolFile struct {
	modTimeNano int64
	size        int64
	relSlash    string
	symbols     []WorkspaceSymbolItem
}

type workspaceSymbolIndex struct {
	root         string
	resolvedRoot string
	mu           sync.Mutex
	files        map[string]cachedWorkspaceSymbolFile
	order        []string
	symbols      []WorkspaceSymbolItem
	refreshed    time.Time
	lastUsed     time.Time
	built        bool

	dirtyMu sync.Mutex
	dirty   map[string]struct{}
}

var (
	workspaceSymbolIndexesMu sync.Mutex
	workspaceSymbolIndexes   = map[string]*workspaceSymbolIndex{}
)

func workspaceSymbolIndexFor(root string) *workspaceSymbolIndex {
	workspaceSymbolIndexesMu.Lock()
	defer workspaceSymbolIndexesMu.Unlock()
	now := time.Now()
	if idx, ok := workspaceSymbolIndexes[root]; ok {
		idx.lastUsed = now
		return idx
	}
	if len(workspaceSymbolIndexes) >= workspaceSymbolMaxRoots {
		var oldestKey string
		var oldest time.Time
		for k, v := range workspaceSymbolIndexes {
			if oldestKey == "" || v.lastUsed.Before(oldest) {
				oldestKey, oldest = k, v.lastUsed
			}
		}
		delete(workspaceSymbolIndexes, oldestKey)
	}
	idx := &workspaceSymbolIndex{root: root, resolvedRoot: resolveWorkspaceSymbolPath(root), files: map[string]cachedWorkspaceSymbolFile{}, lastUsed: now}
	workspaceSymbolIndexes[root] = idx
	return idx
}

func resolveWorkspaceSymbolPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	dir, base := filepath.Split(path)
	if resolvedDir, err := filepath.EvalSymlinks(dir); err == nil {
		return filepath.Join(resolvedDir, base)
	}
	return path
}

func InvalidateWorkspaceSymbolFile(path string) {
	path = strings.TrimSpace(path)
	if path == "" || !strings.HasSuffix(path, ".go") {
		return
	}
	clean := filepath.Clean(path)
	if abs, err := filepath.Abs(clean); err == nil {
		clean = abs
	}
	candidates := []string{clean}
	if resolved := resolveWorkspaceSymbolPath(clean); resolved != clean {
		candidates = append(candidates, resolved)
	}

	workspaceSymbolIndexesMu.Lock()
	indexes := make([]*workspaceSymbolIndex, 0, len(workspaceSymbolIndexes))
	for _, idx := range workspaceSymbolIndexes {
		indexes = append(indexes, idx)
	}
	workspaceSymbolIndexesMu.Unlock()

	for _, idx := range indexes {
		if key, ok := idx.keyFor(candidates); ok {
			idx.markDirty(key)
		}
	}
}

func (idx *workspaceSymbolIndex) keyFor(candidates []string) (string, bool) {
	for _, root := range []string{idx.root, idx.resolvedRoot} {
		for _, c := range candidates {
			rel, err := filepath.Rel(root, c)
			if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				continue
			}
			return filepath.Join(idx.root, rel), true
		}
	}
	return "", false
}

func (idx *workspaceSymbolIndex) markDirty(file string) {
	idx.dirtyMu.Lock()
	if idx.dirty == nil {
		idx.dirty = map[string]struct{}{}
	}
	idx.dirty[file] = struct{}{}
	idx.dirtyMu.Unlock()
}

func (idx *workspaceSymbolIndex) takeDirty() map[string]struct{} {
	idx.dirtyMu.Lock()
	defer idx.dirtyMu.Unlock()
	d := idx.dirty
	idx.dirty = nil
	return d
}

func (idx *workspaceSymbolIndex) snapshot() []WorkspaceSymbolItem {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	dirty := idx.takeDirty()
	if idx.built && time.Since(idx.refreshed) < workspaceSymbolRefreshInterval {
		if len(dirty) > 0 {
			idx.applyDirtyLocked(dirty)
		}
		return idx.symbols
	}
	idx.refreshLocked(dirty)
	return idx.symbols
}

func (idx *workspaceSymbolIndex) applyDirtyLocked(dirty map[string]struct{}) {
	removed := map[string]bool{}
	var added []string
	for file := range dirty {
		rel, err := filepath.Rel(idx.root, file)
		if err != nil {
			continue
		}
		_, known := idx.files[file]
		info, statErr := os.Stat(file)
		if statErr != nil || !info.Mode().IsRegular() || info.Size() > workspaceSymbolMaxFileSize || workspaceSymbolPathSkipped(rel) {
			if known {
				delete(idx.files, file)
				removed[file] = true
			}
			continue
		}
		if !known && len(idx.files) >= workspaceSymbolMaxFiles {
			continue
		}
		relSlash := filepath.ToSlash(rel)
		idx.files[file] = cachedWorkspaceSymbolFile{
			modTimeNano: info.ModTime().UnixNano(),
			size:        info.Size(),
			relSlash:    relSlash,
			symbols:     parseWorkspaceSymbolFile(file, relSlash),
		}
		if !known {
			added = append(added, file)
		}
	}
	if len(removed) > 0 {
		kept := idx.order[:0]
		for _, f := range idx.order {
			if !removed[f] {
				kept = append(kept, f)
			}
		}
		idx.order = kept
	}
	idx.order = append(idx.order, added...)
	total := 0
	for _, f := range idx.order {
		total += len(idx.files[f].symbols)
	}
	symbols := make([]WorkspaceSymbolItem, 0, total)
	for _, f := range idx.order {
		symbols = append(symbols, idx.files[f].symbols...)
	}
	idx.symbols = symbols
}

func workspaceSymbolPathSkipped(rel string) bool {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for _, dir := range parts[:len(parts)-1] {
		if shouldSkipWorkspaceSymbolDir(dir) {
			return true
		}
	}
	return false
}

type workspaceSymbolFileEntry struct {
	cleanFile string
	relSlash  string
	modNano   int64
	size      int64
	hasStat   bool
	symbols   []WorkspaceSymbolItem
}

func (idx *workspaceSymbolIndex) refreshLocked(dirty map[string]struct{}) {
	entries := idx.collectFiles()

	var pending []int
	for i := range entries {
		e := &entries[i]
		_, isDirty := dirty[e.cleanFile]
		if !e.hasStat || isDirty {
			pending = append(pending, i)
			continue
		}
		if c, ok := idx.files[e.cleanFile]; ok && c.modTimeNano == e.modNano && c.size == e.size && c.relSlash == e.relSlash {
			e.symbols = c.symbols
			continue
		}
		pending = append(pending, i)
	}

	parseWorkspaceSymbolFiles(entries, pending)

	files := make(map[string]cachedWorkspaceSymbolFile, len(entries))
	order := make([]string, 0, len(entries))
	total := 0
	for i := range entries {
		e := &entries[i]
		total += len(e.symbols)
		c := cachedWorkspaceSymbolFile{modTimeNano: -1, size: -1, relSlash: e.relSlash, symbols: e.symbols}
		if e.hasStat {
			c.modTimeNano, c.size = e.modNano, e.size
		}
		order = append(order, e.cleanFile)
		files[e.cleanFile] = c
	}
	symbols := make([]WorkspaceSymbolItem, 0, total)
	for i := range entries {
		symbols = append(symbols, entries[i].symbols...)
	}

	idx.files = files
	idx.order = order
	idx.symbols = symbols
	idx.refreshed = time.Now()
	idx.built = true
}

func (idx *workspaceSymbolIndex) collectFiles() []workspaceSymbolFileEntry {
	cleanRoot := idx.root
	var entries []workspaceSymbolFileEntry
	_ = filepath.WalkDir(cleanRoot, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if d.IsDir() {
			if path != cleanRoot && shouldSkipWorkspaceSymbolDir(d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".go") {
			return nil
		}
		info, statErr := d.Info()
		if statErr == nil && info.Size() > workspaceSymbolMaxFileSize {
			return nil
		}
		if len(entries) >= workspaceSymbolMaxFiles {
			return filepath.SkipAll
		}

		cleanFile := filepath.Clean(path)
		if absFile, err := filepath.Abs(cleanFile); err == nil {
			cleanFile = absFile
		}
		relPath, err := filepath.Rel(cleanRoot, cleanFile)
		if err != nil {
			relPath = d.Name()
		}
		e := workspaceSymbolFileEntry{cleanFile: cleanFile, relSlash: filepath.ToSlash(relPath)}
		if statErr == nil && info != nil {
			e.hasStat = true
			e.modNano = info.ModTime().UnixNano()
			e.size = info.Size()
		}
		entries = append(entries, e)
		return nil
	})
	return entries
}

func parseWorkspaceSymbolFiles(entries []workspaceSymbolFileEntry, pending []int) {
	if len(pending) == 0 {
		return
	}
	workers := runtime.GOMAXPROCS(0)
	if workers > 8 {
		workers = 8
	}
	if workers > len(pending) {
		workers = len(pending)
	}
	jobs := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				e := &entries[i]
				e.symbols = parseWorkspaceSymbolFile(e.cleanFile, e.relSlash)
			}
		}()
	}
	for _, i := range pending {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
}

func parseWorkspaceSymbolFile(cleanFile, relSlash string) []WorkspaceSymbolItem {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, cleanFile, nil, parser.SkipObjectResolution)
	if err != nil || f == nil {
		return []WorkspaceSymbolItem{}
	}
	pkgName := ""
	if f.Name != nil {
		pkgName = f.Name.Name
	}
	syms := extractFileWorkspaceSymbols(fset, f, pkgName, cleanFile, relSlash)
	if syms == nil {
		return []WorkspaceSymbolItem{}
	}
	return syms
}
