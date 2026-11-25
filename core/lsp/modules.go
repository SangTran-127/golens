package lsp

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

const (
	maxProjectModules  = 20_000
	moduleListBudget   = 30 * time.Second
	moduleStampRecheck = 2 * time.Second
)

type moduleGraph struct {
	mu      sync.Mutex
	root    string
	stamp   string
	checked time.Time
	mods    []string
	modSet  map[string]struct{}
	loaded  bool
	loading bool
}

type moduleGraphs struct {
	mu     sync.Mutex
	byRoot map[string]*moduleGraph
}

var projectModules moduleGraphs

func (m *moduleGraphs) graph(root string) *moduleGraph {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.byRoot == nil {
		m.byRoot = map[string]*moduleGraph{}
	}
	g := m.byRoot[root]
	if g == nil {
		g = &moduleGraph{}
		m.byRoot[root] = g
	}
	return g
}

func (m *moduleGraphs) refresh(root string) {
	if root == "" {
		return
	}
	m.graph(root).refresh(root)
}

func (m *moduleGraphs) ready(root string) bool {
	return m.graph(root).ready(root)
}

func (m *moduleGraphs) allowFunc(root string) func(string) bool {
	return m.graph(root).allowFunc(root)
}

func (m *moduleGraphs) modules(root string) []string {
	g := m.graph(root)
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.mods...)
}

func (m *moduleGraphs) forget(root string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.byRoot, root)
}

var excludedSubmoduleDirs = map[string]bool{
	"node_modules": true, "vendor": true, "venv": true, "__pycache__": true,
	"testdata": true, "DerivedData": true,
}

func resolveModuleDirs(root string) []string {
	clean := filepath.Clean(root)
	for _, marker := range []string{"go.work", "go.mod"} {
		if _, err := os.Stat(filepath.Join(clean, marker)); err == nil {
			return []string{clean}
		}
	}
	entries, err := os.ReadDir(clean)
	if err != nil {
		return []string{clean}
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".go") {
			return []string{clean}
		}
	}
	var found []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(name, ".") || excludedSubmoduleDirs[name] {
			continue
		}
		sub := filepath.Join(clean, name)
		if _, err := os.Stat(filepath.Join(sub, "go.mod")); err == nil {
			found = append(found, sub)
		}
	}
	if len(found) > 0 {
		return found
	}
	return []string{clean}
}

func workspaceFoldersFor(root string) (string, []map[string]string) {
	dirs := resolveModuleDirs(root)
	folders := make([]map[string]string, 0, len(dirs))
	for _, d := range dirs {
		folders = append(folders, map[string]string{
			"uri":  pathToURI(d),
			"name": filepath.Base(d),
		})
	}
	rootURI := pathToURI(root)
	if len(dirs) == 1 {
		rootURI = pathToURI(dirs[0])
	}
	return rootURI, folders
}

func workspaceFoldersForRoots(primary string, roots []string) (string, []map[string]string) {
	rootURI, folders := workspaceFoldersFor(primary)
	seen := map[string]bool{}
	for _, f := range folders {
		seen[f["uri"]] = true
	}
	for _, r := range roots {
		if filepath.Clean(r) == filepath.Clean(primary) {
			continue
		}
		_, more := workspaceFoldersFor(r)
		for _, f := range more {
			if !seen[f["uri"]] {
				seen[f["uri"]] = true
				folders = append(folders, f)
			}
		}
	}
	return rootURI, folders
}

func moduleStamp(root string) string {
	var b strings.Builder
	for _, dir := range resolveModuleDirs(root) {
		for _, name := range []string{"go.mod", "go.work"} {
			if fi, err := os.Stat(filepath.Join(dir, name)); err == nil {
				b.WriteString(dir)
				b.WriteString(name)
				b.WriteString(fi.ModTime().String())
			}
		}
	}
	return b.String()
}

func moduleListDirs(root string) (hostDir, guestDir string) {
	hostDir = root
	if modDirs := resolveModuleDirs(root); len(modDirs) > 0 {
		hostDir = modDirs[0]
	}
	return hostDir, vmexec.HostToGuestPath(root, hostDir)
}

func listModules(root string) []string {
	targetDir, guestDir := moduleListDirs(root)
	ctx, cancel := context.WithTimeout(context.Background(), moduleListBudget)
	defer cancel()
	cmd := vmexec.CommandContext(ctx, "go", "list", "-m", "-e", "-f", "{{.Path}}", "all")
	cmd.Dir = guestDir
	cmd.Env = vmexec.DefaultVMEnv("arm64", map[string]string{
		"GOPROXY": "off",
		"GOFLAGS": "-mod=readonly",
	})
	out, err := cmd.CombinedOutput()
	if err != nil && bridge.CanFallbackToHost(err) {
		hostCmd := exec.CommandContext(ctx, "go", "list", "-m", "-e", "-f", "{{.Path}}", "all")
		hostCmd.Dir = targetDir
		hostCmd.Env = append(os.Environ(), "GOPROXY=off", "GOFLAGS=-mod=readonly")
		out, _ = hostCmd.CombinedOutput()
	}
	var mods []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() && len(mods) < maxProjectModules {
		if m := strings.TrimSpace(sc.Text()); m != "" {
			mods = append(mods, m)
		}
	}
	return mods
}

func (g *moduleGraph) refresh(root string) {
	if root == "" {
		return
	}
	g.mu.Lock()
	if g.root == root && (g.loading || time.Since(g.checked) < moduleStampRecheck) {
		g.mu.Unlock()
		return
	}
	g.mu.Unlock()
	stamp := moduleStamp(root)
	g.mu.Lock()
	defer g.mu.Unlock()
	g.checked = time.Now()
	if g.root == root && g.stamp == stamp && (g.loaded || g.loading) {
		return
	}
	if g.root != root {
		g.mods, g.modSet, g.loaded = nil, nil, false
	}
	g.root, g.stamp, g.loading = root, stamp, true
	go func() {
		mods := listModules(root)
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.root == root && g.stamp == stamp {
			g.mods, g.modSet, g.loaded = mods, buildModuleSet(mods), true
		}
		if g.root == root {
			g.loading = false
		}
	}()
}

func (g *moduleGraph) ready(root string) bool {
	g.refresh(root)
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.root == root && g.loaded
}

func isStdlibPath(p string) bool {
	first, _, _ := strings.Cut(p, "/")
	return first != "" && !strings.Contains(first, ".")
}

func buildModuleSet(mods []string) map[string]struct{} {
	set := make(map[string]struct{}, len(mods))
	for _, m := range mods {
		set[m] = struct{}{}
	}
	return set
}

func underModuleSet(p string, set map[string]struct{}) bool {
	if len(set) == 0 {
		return false
	}
	if _, ok := set[p]; ok {
		return true
	}
	for i := len(p) - 1; i > 0; i-- {
		if p[i] != '/' {
			continue
		}
		if _, ok := set[p[:i]]; ok {
			return true
		}
	}
	return false
}

func (g *moduleGraph) allowFunc(root string) func(string) bool {
	g.mu.Lock()
	var set map[string]struct{}
	if g.root == root {
		if g.modSet == nil && len(g.mods) > 0 {
			g.modSet = buildModuleSet(g.mods)
		}
		set = g.modSet
	}
	g.mu.Unlock()
	return func(p string) bool {
		return underModuleSet(p, set) || isStdlibPath(p)
	}
}
