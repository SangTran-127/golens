package fsutil

import (
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const maxKnownWorkspaceRoots = 8

type knownRoot struct {
	path  string
	alias string
	seq   uint64
}

var (
	workspaceRootsMu sync.Mutex
	workspaceRoots   = map[string]knownRoot{}
	workspaceRootSeq uint64
)

func RegisterWorkspaceRoot(root string) {
	if root == "" {
		return
	}
	clean := filepath.Clean(root)
	if clean == "/" {
		return
	}
	workspaceRootsMu.Lock()
	entry, known := workspaceRoots[clean]
	workspaceRootsMu.Unlock()

	if !known {
		entry = knownRoot{path: clean}
		if resolved, err := filepath.EvalSymlinks(clean); err == nil && resolved != clean {
			entry.alias = resolved
		}
	}

	workspaceRootsMu.Lock()
	defer workspaceRootsMu.Unlock()
	workspaceRootSeq++
	entry.seq = workspaceRootSeq
	workspaceRoots[clean] = entry
	for len(workspaceRoots) > maxKnownWorkspaceRoots {
		oldest := ""
		var oldestSeq uint64
		for key, e := range workspaceRoots {
			if oldest == "" || e.seq < oldestSeq {
				oldest, oldestSeq = key, e.seq
			}
		}
		delete(workspaceRoots, oldest)
	}
}

func ForgetWorkspaceRoots() {
	workspaceRootsMu.Lock()
	defer workspaceRootsMu.Unlock()
	workspaceRoots = map[string]knownRoot{}
}

func knownWorkspaceRoots() []string {
	workspaceRootsMu.Lock()
	entries := make([]knownRoot, 0, len(workspaceRoots))
	for _, entry := range workspaceRoots {
		entries = append(entries, entry)
	}
	workspaceRootsMu.Unlock()
	sort.Slice(entries, func(i, j int) bool { return entries[i].seq > entries[j].seq })
	roots := make([]string, 0, len(entries)*2)
	for _, entry := range entries {
		roots = append(roots, entry.path)
		if entry.alias != "" {
			roots = append(roots, entry.alias)
		}
	}
	return roots
}

func pathWithin(root, path string) bool {
	return path == root || strings.HasPrefix(path, root+"/")
}

func latestKnownRootContaining(path string) string {
	for _, root := range knownWorkspaceRoots() {
		if pathWithin(root, path) {
			return root
		}
	}
	return ""
}

func ResolveGitMount(root, dir string) (string, bool) {
	if dir == "" {
		dir = root
	}
	if dir == "" {
		return "", true
	}
	cleanDir := filepath.Clean(dir)
	if root != "" && filepath.Clean(root) != cleanDir {
		cleanRoot := filepath.Clean(root)
		if pathWithin(cleanRoot, cleanDir) {
			return cleanRoot, true
		}
		if resolved, err := filepath.EvalSymlinks(cleanRoot); err == nil && resolved != cleanRoot && pathWithin(resolved, cleanDir) {
			return resolved, true
		}
		if known := latestKnownRootContaining(cleanDir); known != "" {
			return known, true
		}
		return "", false
	}
	if known := latestKnownRootContaining(cleanDir); known != "" {
		return known, true
	}
	return cleanDir, true
}
