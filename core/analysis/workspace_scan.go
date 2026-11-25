package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
)

const (
	workspaceScanMaxFiles     = 250
	workspaceScanMaxFileBytes = 1 << 20
)

var workspaceScanSkipDirs = map[string]bool{
	".git":         true,
	"vendor":       true,
	".build":       true,
	"node_modules": true,
	"build":        true,
	".golens":        true,
	"testdata":     true,
	"third_party":  true,
}

type goSourceTarget struct {
	path    string
	content []byte
	loaded  bool
}

type parsedGoSource struct {
	path    string
	content []byte
	fset    *token.FileSet
	file    *ast.File
}

func loadedGoSourceTarget(path string, content []byte) goSourceTarget {
	return goSourceTarget{path: path, content: content, loaded: true}
}

func collectWorkspaceGoTargets(absWorkspace, absActiveFile, activeContent string, includeTests bool) []goSourceTarget {
	var targets []goSourceTarget
	cleanActive := ""
	if absActiveFile != "" {
		cleanActive = filepath.Clean(absActiveFile)
	}
	isCandidate := func(name string) bool {
		if !strings.HasSuffix(name, ".go") || strings.HasPrefix(name, ".") {
			return false
		}
		return includeTests || !strings.HasSuffix(name, "_test.go")
	}

	seenActive := false
	_ = filepath.WalkDir(absWorkspace, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if d.IsDir() {
			if path != absWorkspace {
				name := d.Name()
				if workspaceScanSkipDirs[name] || strings.HasPrefix(name, ".") {
					return filepath.SkipDir
				}
			}
			return nil
		}
		if len(targets) >= workspaceScanMaxFiles {
			return filepath.SkipAll
		}
		if !isCandidate(d.Name()) {
			return nil
		}
		if info, statErr := d.Info(); statErr == nil && info.Size() > workspaceScanMaxFileBytes {
			return nil
		}
		cleanPath := filepath.Clean(path)
		if cleanActive != "" && cleanPath == cleanActive && activeContent != "" {
			seenActive = true
			targets = append(targets, loadedGoSourceTarget(cleanPath, []byte(activeContent)))
			return nil
		}
		targets = append(targets, goSourceTarget{path: cleanPath})
		return nil
	})

	activeIsGo := strings.HasSuffix(cleanActive, ".go") && (includeTests || !strings.HasSuffix(cleanActive, "_test.go"))
	if !seenActive && cleanActive != "" && activeContent != "" && activeIsGo {
		if strings.HasPrefix(cleanActive, filepath.Clean(absWorkspace)) {
			targets = append(targets, loadedGoSourceTarget(cleanActive, []byte(activeContent)))
		}
	}

	sortGoSourceTargets(targets)
	return targets
}

func sortGoSourceTargets(targets []goSourceTarget) {
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].path < targets[j].path
	})
}

func analyseGoSourceTargets[T any](targets []goSourceTarget, mode parser.Mode, analyse func(src parsedGoSource) T) ([]T, error) {
	type outcome struct {
		value    T
		parsed   bool
		parseErr error
	}
	outcomes := make([]outcome, len(targets))

	process := func(i int) {
		t := targets[i]
		content := t.content
		if !t.loaded {
			data, err := os.ReadFile(t.path)
			if err != nil {
				return
			}
			content = data
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, t.path, content, mode)
		if file == nil {
			outcomes[i].parseErr = err
			return
		}
		outcomes[i].value = analyse(parsedGoSource{path: t.path, content: content, fset: fset, file: file})
		outcomes[i].parsed = true
	}

	runIndexedParallel(len(targets), process)

	results := make([]T, 0, len(targets))
	var firstParseErr error
	for _, o := range outcomes {
		if o.parsed {
			results = append(results, o.value)
			continue
		}
		if o.parseErr != nil && firstParseErr == nil {
			firstParseErr = o.parseErr
		}
	}
	return results, firstParseErr
}

func flattenGoSourceResults[T any](perFile [][]T) []T {
	total := 0
	for _, items := range perFile {
		total += len(items)
	}
	if total == 0 {
		return nil
	}
	out := make([]T, 0, total)
	for _, items := range perFile {
		out = append(out, items...)
	}
	return out
}

func runIndexedParallel(n int, fn func(i int)) {
	workers := runtime.GOMAXPROCS(0)
	if workers > n {
		workers = n
	}
	if workers <= 1 {
		for i := 0; i < n; i++ {
			fn(i)
		}
		return
	}
	jobs := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				fn(i)
			}
		}()
	}
	for i := 0; i < n; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
}
