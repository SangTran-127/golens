package docker

import (
	"os"
	"path/filepath"
	"sync"
	"time"
)

const contextFactsTTL = 10 * time.Second

type ignoreFile struct {
	name    string
	path    string
	content string
}

type contextFacts struct {
	mod      *goModule
	scan     *goScan
	ignores  []ignoreFile
	modPath  string
	modTime  time.Time
	loadedAt time.Time
}

var (
	factsMu    sync.Mutex
	factsCache = map[string]*contextFacts{}
	factsNow   = time.Now
	factsLoads int
)

func goModTime(path string) time.Time {
	if st, err := os.Stat(path); err == nil {
		return st.ModTime()
	}
	return time.Time{}
}

func loadContextFacts(ctxDir, base string) *contextFacts {
	key := ctxDir + "\x00" + base
	now := factsNow()
	factsMu.Lock()
	defer factsMu.Unlock()
	if f := factsCache[key]; f != nil && now.Sub(f.loadedAt) < contextFactsTTL && (f.modPath == "" || goModTime(f.modPath).Equal(f.modTime)) {
		return f
	}
	for k, f := range factsCache {
		if now.Sub(f.loadedAt) >= contextFactsTTL {
			delete(factsCache, k)
		}
	}
	factsLoads++
	f := &contextFacts{loadedAt: now, mod: findModule(ctxDir)}
	if f.mod != nil {
		f.modPath = filepath.Join(f.mod.root, "go.mod")
		f.modTime = goModTime(f.modPath)
		s := scanGoFiles(f.mod.root)
		f.scan = &s
	}
	for _, name := range []string{base + ".dockerignore", ".dockerignore"} {
		p := filepath.Join(ctxDir, name)
		if data, err := os.ReadFile(p); err == nil {
			f.ignores = append(f.ignores, ignoreFile{name: name, path: p, content: string(data)})
		}
	}
	factsCache[key] = f
	return f
}
