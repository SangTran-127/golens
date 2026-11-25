package docs

import (
	"context"
	"errors"
	"go/ast"
	"go/build/constraint"
	"go/token"
	"sort"
	"strings"
	"sync"
)

const (
	maxSearchWorkers = 4
	maxSearchResults = 200
)

type SearchResult struct {
	ImportPath  string `json:"importPath"`
	PackageName string `json:"packageName,omitempty"`
	Symbol      string `json:"symbol,omitempty"`
	Kind        string `json:"kind"`
	Signature   string `json:"signature,omitempty"`
	ModulePath  string `json:"modulePath,omitempty"`
	Version     string `json:"version,omitempty"`
	Origin      string `json:"origin"`
	Source      string `json:"source"`
	Excluded    bool   `json:"excluded,omitempty"`
	Build       string `json:"build,omitempty"`
	Missing     bool   `json:"missing,omitempty"`
}

type SearchResponse struct {
	Root       string         `json:"root"`
	Target     Target         `json:"target"`
	Generation int64          `json:"generation"`
	Query      string         `json:"query"`
	Results    []SearchResult `json:"results"`
	Error      string         `json:"error,omitempty"`
	Cancelled  bool           `json:"cancelled,omitempty"`
}

type searchEntry struct {
	Result    SearchResult
	LowerPkg  string
	LowerPath string
	LowerSym  string
	LowerLeaf string
	LowerFull string
}

func (s *Service) Search(reqID, root string, opts Options, scope, query string, limit int) *SearchResponse {
	canon := canonicalRoot(root)
	normTarget := normalizeTargetKey(opts.Target, opts.IncludeStd)
	key := cacheKey{Root: canon, Target: normTarget}
	ctx, finish := s.beginRequest(reqID, opts.Timeout)
	defer finish()

	resp := &SearchResponse{
		Root:    canon,
		Target:  normTarget,
		Query:   query,
		Results: []SearchResult{},
	}
	idx, entry, err := s.getOrLoadIndex(ctx, canon, key, opts)
	if err != nil {
		resp.Generation = s.gen.Load()
		resp.Cancelled = errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled)
		resp.Error = err.Error()
		return resp
	}
	resp.Target = idx.Target
	resp.Generation = entry.Generation

	entries := s.cachedSearchEntries(ctx, entry, idx, opts)
	if ctx.Err() != nil {
		resp.Cancelled = true
		resp.Error = ctx.Err().Error()
		return resp
	}
	resp.Results = filterAndRankSearch(entries, scope, query, limit)
	return resp
}

func (s *Service) cachedSearchEntries(ctx context.Context, entry *cachedWorkspace, idx *Index, opts Options) []searchEntry {
	s.mu.Lock()
	var cached []searchEntry
	if opts.IncludeUnexported {
		cached = entry.Unexported
	} else {
		cached = entry.Exported
	}
	s.mu.Unlock()
	if cached != nil {
		return cached
	}
	built := buildSearchIndex(ctx, idx, opts)
	if ctx.Err() != nil {
		return nil
	}
	s.mu.Lock()
	if opts.IncludeUnexported {
		if entry.Unexported == nil {
			entry.Unexported = built
		}
		cached = entry.Unexported
	} else {
		if entry.Exported == nil {
			entry.Exported = built
		}
		cached = entry.Exported
	}
	s.mu.Unlock()
	return cached
}

func buildSearchIndex(ctx context.Context, idx *Index, opts Options) []searchEntry {
	if len(idx.Packages) == 0 {
		return nil
	}
	workers := min(maxSearchWorkers, len(idx.Packages))
	jobs := make(chan Package, len(idx.Packages))
	for _, p := range idx.Packages {
		jobs <- p
	}
	close(jobs)

	var mu sync.Mutex
	var out []searchEntry
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var local []searchEntry
			for p := range jobs {
				if ctx.Err() != nil {
					return
				}
				local = append(local, packageSearchEntries(p, idx.Target, opts)...)
			}
			mu.Lock()
			out = append(out, local...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	return out
}

func packageSearchEntries(p Package, target Target, opts Options) []searchEntry {
	var out []searchEntry
	out = append(out, makeSearchEntry(SearchResult{
		ImportPath:  p.ImportPath,
		PackageName: p.Name,
		Kind:        "package",
		ModulePath:  p.ModulePath,
		Version:     p.Version,
		Origin:      p.Origin,
		Source:      p.Source,
		Missing:     p.Missing,
	}))
	if p.Missing || len(p.GoFiles) == 0 || p.Dir == "" {
		return out
	}
	pkgOpts := Options{
		Target:            target,
		IncludeUnexported: opts.IncludeUnexported,
	}
	pd, err := BuildPackageDocWithOptions(p, target, pkgOpts)
	if pd == nil {
		return out
	}
	addSym := func(sym Symbol, displayName string) {
		out = append(out, makeSearchEntry(SearchResult{
			ImportPath:  p.ImportPath,
			PackageName: pd.Name,
			Symbol:      displayName,
			Kind:        sym.Kind,
			Signature:   firstLine(sym.Signature),
			ModulePath:  p.ModulePath,
			Version:     p.Version,
			Origin:      p.Origin,
			Source:      p.Source,
		}))
	}
	if err == nil {
		for _, c := range pd.Consts {
			addSym(c, c.Name)
		}
		for _, v := range pd.Vars {
			addSym(v, v.Name)
		}
		for _, f := range pd.Funcs {
			addSym(f, f.Name)
		}
		for _, t := range pd.Types {
			addSym(t, t.Name)
			for _, f := range t.Funcs {
				addSym(f, f.Name)
			}
			for _, m := range t.Methods {
				addSym(m, t.Name+"."+m.Name)
			}
		}
	}
	for _, ex := range pd.Excluded {
		if ex.Reason != "build-constraint" {
			continue
		}
		out = append(out, makeSearchEntry(SearchResult{
			ImportPath:  p.ImportPath,
			PackageName: pd.Name,
			Symbol:      ex.Name,
			Kind:        ex.Kind,
			ModulePath:  p.ModulePath,
			Version:     p.Version,
			Origin:      p.Origin,
			Source:      p.Source,
			Excluded:    true,
			Build:       ex.Build,
		}))
	}
	return out
}

func makeSearchEntry(r SearchResult) searchEntry {
	lowerPkg := strings.ToLower(r.PackageName)
	lowerPath := strings.ToLower(r.ImportPath)
	lowerSym := strings.ToLower(r.Symbol)
	leaf := lowerSym
	if _, after, ok := strings.Cut(lowerSym, "."); ok {
		leaf = after
	}
	full := lowerPath
	if lowerSym != "" {
		full = lowerPath + "." + lowerSym
	}
	return searchEntry{
		Result:    r,
		LowerPkg:  lowerPkg,
		LowerPath: lowerPath,
		LowerSym:  lowerSym,
		LowerLeaf: leaf,
		LowerFull: full,
	}
}

func filterAndRankSearch(entries []searchEntry, scope, query string, limit int) []SearchResult {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" {
		return []SearchResult{}
	}
	if limit <= 0 || limit > maxSearchResults {
		limit = maxSearchResults
	}
	normScope := strings.ToLower(strings.TrimSpace(scope))
	type scored struct {
		rank int
		res  SearchResult
	}
	var hits []scored
	for _, e := range entries {
		if !matchesScope(e.Result.Origin, normScope) {
			continue
		}
		rank := scoreSearchEntry(e, q)
		if rank < 0 {
			continue
		}
		hits = append(hits, scored{rank: rank, res: e.Result})
	}
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].rank != hits[j].rank {
			return hits[i].rank < hits[j].rank
		}
		if hits[i].res.Excluded != hits[j].res.Excluded {
			return !hits[i].res.Excluded
		}
		if hits[i].res.Missing != hits[j].res.Missing {
			return !hits[i].res.Missing
		}
		oi, oj := originRank(hits[i].res.Origin), originRank(hits[j].res.Origin)
		if oi != oj {
			return oi < oj
		}
		if hits[i].res.Symbol != hits[j].res.Symbol {
			return hits[i].res.Symbol < hits[j].res.Symbol
		}
		return hits[i].res.ImportPath < hits[j].res.ImportPath
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	out := make([]SearchResult, len(hits))
	for i, h := range hits {
		out[i] = h.res
	}
	return out
}

func matchesScope(origin, scope string) bool {
	switch scope {
	case "", "all":
		return true
	case "project":
		return origin == OriginProject
	case "dependencies", "dependency":
		return origin == OriginDependency
	case "stdlib", "std":
		return origin == OriginStdlib
	default:
		return true
	}
}

func scoreSearchEntry(e searchEntry, q string) int {
	if e.Result.Kind == "package" {
		switch {
		case e.LowerPath == q:
			return 0
		case e.LowerPkg == q:
			return 1
		case strings.HasPrefix(e.LowerPkg, q) || strings.HasPrefix(e.LowerPath, q):
			return 2
		case strings.Contains(e.LowerPath, q) || strings.Contains(e.LowerPkg, q):
			return 3
		default:
			return -1
		}
	}
	pkgDotSym := e.LowerPkg + "." + e.LowerSym
	pathDotSym := e.LowerPath + "." + e.LowerSym
	pathHashSym := e.LowerPath + "#" + e.LowerSym
	hasDotSym := strings.Contains(e.LowerSym, ".")
	switch {
	case pkgDotSym == q || pathDotSym == q || pathHashSym == q || (hasDotSym && e.LowerSym == q):
		return 0
	case e.LowerSym == q || e.LowerLeaf == q:
		return 1
	case strings.HasPrefix(e.LowerSym, q) || strings.HasPrefix(e.LowerLeaf, q) ||
		strings.HasPrefix(pkgDotSym, q) || strings.HasPrefix(e.LowerPath, q):
		return 2
	case strings.Contains(pkgDotSym, q) || strings.Contains(e.LowerFull, q):
		return 3
	default:
		return -1
	}
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	return line
}

type declName struct {
	name, kind string
	pos        token.Pos
}

func declNames(decl ast.Decl) []declName {
	switch d := decl.(type) {
	case *ast.FuncDecl:
		if d.Recv != nil && len(d.Recv.List) > 0 {
			return []declName{{recvName(d.Recv.List[0].Type) + "." + d.Name.Name, "method", d.Pos()}}
		}
		return []declName{{d.Name.Name, "func", d.Pos()}}
	case *ast.GenDecl:
		var out []declName
		for _, spec := range d.Specs {
			switch s := spec.(type) {
			case *ast.TypeSpec:
				out = append(out, declName{s.Name.Name, "type", s.Pos()})
			case *ast.ValueSpec:
				for _, n := range s.Names {
					out = append(out, declName{n.Name, d.Tok.String(), n.Pos()})
				}
			}
		}
		return out
	}
	return nil
}

func recvName(e ast.Expr) string {
	switch t := e.(type) {
	case *ast.StarExpr:
		return recvName(t.X)
	case *ast.IndexExpr:
		return recvName(t.X)
	case *ast.IndexListExpr:
		return recvName(t.X)
	case *ast.Ident:
		return t.Name
	}
	return ""
}

func isTestFunc(name string) bool {
	for _, p := range []string{"Test", "Benchmark", "Fuzz", "Example"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

func allExported(s string) bool {
	for _, part := range strings.Split(s, ".") {
		if part == "" || !token.IsExported(part) {
			return false
		}
	}
	return true
}

func buildExpr(f *ast.File) string {
	for _, cg := range f.Comments {
		if cg.Pos() >= f.Package {
			break
		}
		for _, c := range cg.List {
			if constraint.IsGoBuild(c.Text) {
				if expr, err := constraint.Parse(c.Text); err == nil {
					return expr.String()
				}
			}
		}
	}
	return ""
}

func filenameConstraint(name string) string {
	base := strings.TrimSuffix(strings.TrimSuffix(name, ".go"), "_test")
	parts := strings.Split(base, "_")
	if len(parts) < 2 {
		return ""
	}
	if len(parts) >= 3 {
		return parts[len(parts)-2] + " && " + parts[len(parts)-1]
	}
	return parts[len(parts)-1]
}
