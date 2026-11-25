package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type PackageDependencyReport struct {
	ModulePath          string        `json:"modulePath"`
	PackageCount        int           `json:"packageCount"`
	StdlibImportCount   int           `json:"stdlibImportCount"`
	ExternalImportCount int           `json:"externalImportCount"`
	Cycles              []ImportCycle `json:"cycles"`
	Packages            []PackageNode `json:"packages"`
}

type ImportCycle struct {
	ID    string               `json:"id"`
	Chain []string             `json:"chain"`
	Edges []ImportEdgeLocation `json:"edges"`
}

type ImportEdgeLocation struct {
	FromPkg  string `json:"fromPkg"`
	ToPkg    string `json:"toPkg"`
	FilePath string `json:"filePath"`
	Line     int    `json:"line"`
}

type PackageNode struct {
	ImportPath  string              `json:"importPath"`
	PackageName string              `json:"packageName"`
	RelativeDir string              `json:"relativeDir"`
	GoFiles     []string            `json:"goFiles"`
	FanIn       int                 `json:"fanIn"`
	FanOut      int                 `json:"fanOut"`
	Imports     []PackageImportEdge `json:"imports"`
	ImportedBy  []string            `json:"importedBy"`
}

type PackageImportEdge struct {
	TargetPath string `json:"targetPath"`
	Category   string `json:"category"`
	FilePath   string `json:"filePath"`
	Line       int    `json:"line"`
}

func InspectPackageDependencies(workspaceDir string) (string, error) {
	report := PackageDependencyReport{
		Cycles:   []ImportCycle{},
		Packages: []PackageNode{},
	}

	workspaceDir = strings.TrimSpace(workspaceDir)
	if workspaceDir == "" {
		out, err := json.Marshal(report)
		return string(out), err
	}

	absRoot, err := filepath.Abs(workspaceDir)
	if err != nil {
		absRoot = workspaceDir
	}
	info, err := os.Stat(absRoot)
	if err != nil || !info.IsDir() {
		out, mErr := json.Marshal(report)
		return string(out), mErr
	}

	modulePath := readGoModModulePath(filepath.Join(absRoot, "go.mod"))
	report.ModulePath = modulePath

	dirFiles := make(map[string][]string)
	dirTestFiles := make(map[string][]string)

	skipDirs := map[string]bool{
		".git":         true,
		"vendor":       true,
		"node_modules": true,
		".build":       true,
		"build":        true,
		".golens":        true,
		"testdata":     true,
		"third_party":  true,
	}

	filesVisited := 0
	_ = filepath.WalkDir(absRoot, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if d.IsDir() {
			if path != absRoot {
				name := d.Name()
				if skipDirs[name] || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") {
					return filepath.SkipDir
				}
			}
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasPrefix(name, ".") {
			return nil
		}
		if info, statErr := d.Info(); statErr == nil && info.Size() > (1<<20) {
			return nil
		}
		filesVisited++
		if filesVisited > 300 {
			return filepath.SkipAll
		}
		dir := filepath.Dir(path)
		if strings.HasSuffix(name, "_test.go") {
			dirTestFiles[dir] = append(dirTestFiles[dir], path)
		} else {
			dirFiles[dir] = append(dirFiles[dir], path)
		}
		return nil
	})

	for dir, tFiles := range dirTestFiles {
		if len(dirFiles[dir]) == 0 && len(tFiles) > 0 {
			dirFiles[dir] = tFiles
		}
	}

	var sortedDirs []string
	for dir := range dirFiles {
		sortedDirs = append(sortedDirs, dir)
	}
	sort.Strings(sortedDirs)

	pkgByImportPath := make(map[string]*PackageNode)
	var orderedImportPaths []string
	stdlibSet := make(map[string]bool)
	externalSet := make(map[string]bool)

	fset := token.NewFileSet()

	for _, dir := range sortedDirs {
		files := dirFiles[dir]
		sort.Strings(files)

		relDir, relErr := filepath.Rel(absRoot, dir)
		if relErr != nil || relDir == "" {
			relDir = "."
		}
		relDir = filepath.ToSlash(relDir)

		importPath := relDir
		if modulePath != "" {
			if relDir == "." {
				importPath = modulePath
			} else {
				importPath = modulePath + "/" + relDir
			}
		}

		var goFileNames []string
		var pkgName string
		seenImports := make(map[string]bool)
		var imports []PackageImportEdge

		for _, filePath := range files {
			goFileNames = append(goFileNames, filepath.Base(filePath))
			src, readErr := os.ReadFile(filePath)
			if readErr != nil {
				continue
			}
			astFile, _ := parser.ParseFile(fset, filePath, src, parser.ImportsOnly)
			if astFile == nil {
				continue
			}
			if pkgName == "" && astFile.Name != nil && astFile.Name.Name != "" {
				pkgName = astFile.Name.Name
			}
			for _, imp := range astFile.Imports {
				if imp == nil || imp.Path == nil {
					continue
				}
				targetPath := strings.Trim(imp.Path.Value, "\"`")
				if targetPath == "" {
					continue
				}
				category := classifyImportPath(targetPath, modulePath)
				switch category {
				case "stdlib":
					stdlibSet[targetPath] = true
				case "external":
					externalSet[targetPath] = true
				}
				if seenImports[targetPath] {
					continue
				}
				seenImports[targetPath] = true
				line := 1
				if pos := fset.Position(imp.Pos()); pos.Line > 0 {
					line = pos.Line
				}
				imports = append(imports, PackageImportEdge{
					TargetPath: targetPath,
					Category:   category,
					FilePath:   filePath,
					Line:       line,
				})
			}
		}

		if pkgName == "" {
			if relDir == "." {
				pkgName = filepath.Base(absRoot)
			} else {
				pkgName = filepath.Base(dir)
			}
		}
		if imports == nil {
			imports = []PackageImportEdge{}
		}
		if goFileNames == nil {
			goFileNames = []string{}
		}

		node := &PackageNode{
			ImportPath:  importPath,
			PackageName: pkgName,
			RelativeDir: relDir,
			GoFiles:     goFileNames,
			FanOut:      len(imports),
			Imports:     imports,
			ImportedBy:  []string{},
		}
		pkgByImportPath[importPath] = node
		orderedImportPaths = append(orderedImportPaths, importPath)
	}

	sort.Strings(orderedImportPaths)

	importedBySets := make(map[string]map[string]bool)
	for _, fromPath := range orderedImportPaths {
		node := pkgByImportPath[fromPath]
		for i := range node.Imports {
			target := node.Imports[i].TargetPath
			if _, exists := pkgByImportPath[target]; exists && node.Imports[i].Category != "internal" {
				node.Imports[i].Category = "internal"
				delete(stdlibSet, target)
				delete(externalSet, target)
			}
			if node.Imports[i].Category == "internal" && target != fromPath {
				if importedBySets[target] == nil {
					importedBySets[target] = make(map[string]bool)
				}
				importedBySets[target][fromPath] = true
			}
		}
	}

	for _, importPath := range orderedImportPaths {
		node := pkgByImportPath[importPath]
		if callers := importedBySets[importPath]; len(callers) > 0 {
			for caller := range callers {
				node.ImportedBy = append(node.ImportedBy, caller)
			}
			sort.Strings(node.ImportedBy)
		}
		node.FanIn = len(node.ImportedBy)
	}

	report.PackageCount = len(orderedImportPaths)
	report.StdlibImportCount = len(stdlibSet)
	report.ExternalImportCount = len(externalSet)
	report.Cycles = detectInternalImportCycles(orderedImportPaths, pkgByImportPath)

	for _, importPath := range orderedImportPaths {
		report.Packages = append(report.Packages, *pkgByImportPath[importPath])
	}

	out, err := json.Marshal(report)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func readGoModModulePath(goModPath string) string {
	f, err := os.Open(goModPath)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if idx := strings.Index(line, "//"); idx >= 0 {
			line = strings.TrimSpace(line[:idx])
		}
		if strings.HasPrefix(line, "module ") {
			rest := strings.TrimSpace(strings.TrimPrefix(line, "module "))
			rest = strings.Trim(rest, "\"`")
			fields := strings.Fields(rest)
			if len(fields) > 0 {
				return fields[0]
			}
		}
	}
	return ""
}

func classifyImportPath(targetPath string, modulePath string) string {
	if modulePath != "" && (targetPath == modulePath || strings.HasPrefix(targetPath, modulePath+"/")) {
		return "internal"
	}
	firstSegment := targetPath
	if slashIdx := strings.IndexByte(targetPath, '/'); slashIdx >= 0 {
		firstSegment = targetPath[:slashIdx]
	}
	if strings.Contains(firstSegment, ".") {
		return "external"
	}
	return "stdlib"
}

const (
	maxImportCycleLength   = 16
	maxReportedImportCycle = 500
	maxImportCycleSearch   = 200000
)

func detectInternalImportCycles(orderedImportPaths []string, pkgByImportPath map[string]*PackageNode) []ImportCycle {
	cycles := make([]ImportCycle, 0)
	seenCycleKey := make(map[string]bool)

	edgeLookup := make(map[string]map[string]PackageImportEdge)
	adj := make(map[string][]string)

	for _, fromPath := range orderedImportPaths {
		node := pkgByImportPath[fromPath]
		if node == nil {
			continue
		}
		edgeLookup[fromPath] = make(map[string]PackageImportEdge)
		for _, imp := range node.Imports {
			if imp.Category != "internal" || imp.TargetPath == fromPath {
				continue
			}
			if _, dup := edgeLookup[fromPath][imp.TargetPath]; !dup {
				adj[fromPath] = append(adj[fromPath], imp.TargetPath)
			}
			edgeLookup[fromPath][imp.TargetPath] = imp
		}
		sort.Strings(adj[fromPath])
	}

	component := stronglyConnectedComponents(orderedImportPaths, adj)
	componentSize := make(map[int]int)
	for _, id := range component {
		componentSize[id]++
	}

	budget := maxImportCycleSearch
	visited := make(map[string]bool)
	for _, startNode := range orderedImportPaths {
		startComponent, ok := component[startNode]
		if !ok || componentSize[startComponent] < 2 {
			continue
		}
		var dfs func(curr string, path []string)
		dfs = func(curr string, path []string) {
			visited[curr] = true
			defer func() { visited[curr] = false }()

			for _, next := range adj[curr] {
				if budget <= 0 || len(cycles) >= maxReportedImportCycle {
					return
				}
				budget--
				if next < startNode {
					continue
				}
				if nextComponent, ok := component[next]; !ok || nextComponent != startComponent {
					continue
				}
				if next == startNode {
					chain := make([]string, len(path)+1)
					copy(chain, path)
					chain[len(path)] = startNode
					key := strings.Join(chain, "->")
					if !seenCycleKey[key] {
						seenCycleKey[key] = true
						edges := make([]ImportEdgeLocation, 0, len(chain)-1)
						for i := 0; i < len(chain)-1; i++ {
							u := chain[i]
							v := chain[i+1]
							impEdge := edgeLookup[u][v]
							edges = append(edges, ImportEdgeLocation{
								FromPkg:  u,
								ToPkg:    v,
								FilePath: impEdge.FilePath,
								Line:     impEdge.Line,
							})
						}
						cycles = append(cycles, ImportCycle{
							ID:    fmt.Sprintf("cycle-%d", len(cycles)+1),
							Chain: chain,
							Edges: edges,
						})
					}
					continue
				}
				if !visited[next] && len(path) < maxImportCycleLength {
					dfs(next, append(path, next))
				}
			}
		}
		dfs(startNode, []string{startNode})
	}

	return cycles
}

func stronglyConnectedComponents(nodes []string, adj map[string][]string) map[string]int {
	index := make(map[string]int, len(nodes))
	lowLink := make(map[string]int, len(nodes))
	onStack := make(map[string]bool, len(nodes))
	component := make(map[string]int, len(nodes))
	stack := make([]string, 0, len(nodes))
	nextIndex := 0
	nextComponent := 0

	type frame struct {
		node string
		edge int
	}

	for _, root := range nodes {
		if _, seen := index[root]; seen {
			continue
		}
		index[root] = nextIndex
		lowLink[root] = nextIndex
		nextIndex++
		stack = append(stack, root)
		onStack[root] = true
		work := []frame{{node: root}}

		for len(work) > 0 {
			top := &work[len(work)-1]
			if top.edge < len(adj[top.node]) {
				next := adj[top.node][top.edge]
				top.edge++
				if _, seen := index[next]; !seen {
					index[next] = nextIndex
					lowLink[next] = nextIndex
					nextIndex++
					stack = append(stack, next)
					onStack[next] = true
					work = append(work, frame{node: next})
				} else if onStack[next] && index[next] < lowLink[top.node] {
					lowLink[top.node] = index[next]
				}
				continue
			}

			node := top.node
			work = work[:len(work)-1]
			if len(work) > 0 {
				parent := work[len(work)-1].node
				if lowLink[node] < lowLink[parent] {
					lowLink[parent] = lowLink[node]
				}
			}
			if lowLink[node] != index[node] {
				continue
			}
			for {
				member := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				onStack[member] = false
				component[member] = nextComponent
				if member == node {
					break
				}
			}
			nextComponent++
		}
	}
	return component
}
