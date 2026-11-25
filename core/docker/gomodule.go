package docker

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const (
	maxScannedGoFiles = 5000
	maxScannedEntries = 50000
)

type goModule struct {
	root      string
	goVersion string
	toolchain string
	hasGoSum  bool
	requires  bool
	sqlite    bool
}

func findModule(dir string) *goModule {
	for d := dir; d != ""; {
		data, err := os.ReadFile(filepath.Join(d, "go.mod"))
		if err == nil {
			return parseGoMod(d, string(data))
		}
		parent := filepath.Dir(d)
		if parent == d {
			break
		}
		d = parent
	}
	return nil
}

func parseGoMod(root, text string) *goModule {
	m := &goModule{root: root}
	if _, err := os.Stat(filepath.Join(root, "go.sum")); err == nil {
		m.hasGoSum = true
	}
	for _, line := range strings.Split(text, "\n") {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		switch {
		case f[0] == "go" && len(f) > 1:
			m.goVersion = f[1]
		case f[0] == "toolchain" && len(f) > 1 && strings.HasPrefix(f[1], "go"):
			m.toolchain = strings.TrimPrefix(f[1], "go")
		case f[0] == "require":
			m.requires = true
		}
		if strings.Contains(line, "github.com/mattn/go-sqlite3") {
			m.sqlite = true
		}
	}
	return m
}

func (m *goModule) required() (version, directive string) {
	if m.goVersion != "" {
		version, directive = m.goVersion, "go "+m.goVersion
	}
	if m.toolchain != "" && compareVersions(versionParts(m.toolchain), versionParts(version)) > 0 {
		version, directive = m.toolchain, "toolchain go"+m.toolchain
	}
	return version, directive
}

var versionPrefixRe = regexp.MustCompile(`^\d+(?:\.\d+)*`)

func versionParts(v string) []int {
	var parts []int
	for _, p := range strings.Split(versionPrefixRe.FindString(v), ".") {
		if n, err := strconv.Atoi(p); err == nil {
			parts = append(parts, n)
		}
	}
	return parts
}

func compareVersions(a, b []int) int {
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func imageCovers(image, required []int) bool {
	if len(required) > len(image) {
		required = required[:len(image)]
	}
	return compareVersions(image, required) >= 0
}

type goScan struct {
	mains    map[string]bool
	cgoFile  string
	complete bool
}

func scanGoFiles(root string) goScan {
	s := goScan{mains: map[string]bool{}, complete: true}
	fset := token.NewFileSet()
	files, entries := 0, 0
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		entries++
		if entries > maxScannedEntries {
			s.complete = false
			return filepath.SkipAll
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && (name == "vendor" || name == "testdata" || name == "node_modules" || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_")) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") {
			return nil
		}
		files++
		if files > maxScannedGoFiles {
			s.complete = false
			return filepath.SkipAll
		}
		f, _ := parser.ParseFile(fset, p, nil, parser.ImportsOnly)
		if f == nil || f.Name == nil {
			return nil
		}
		if f.Name.Name == "main" {
			rel, _ := filepath.Rel(root, filepath.Dir(p))
			s.mains[filepath.ToSlash(rel)] = true
		}
		if s.cgoFile == "" {
			for _, imp := range f.Imports {
				if imp.Path != nil && imp.Path.Value == `"C"` {
					rel, _ := filepath.Rel(root, p)
					s.cgoFile = filepath.ToSlash(rel)
					break
				}
			}
		}
		return nil
	})
	return s
}
