package lsp

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"io/fs"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type recallSite struct {
	start, end int
	kind       string
	importSpec [2]int
}

type recallResult struct {
	root, file, kind, ident, snippet string
	raw, golens                        int
}

type recallSample struct {
	Root    string           `json:"root"`
	File    string           `json:"file"`
	Kind    string           `json:"kind"`
	Ident   string           `json:"ident"`
	Snippet string           `json:"snippet"`
	Query   string           `json:"query"`
	Items   []completionItem `json:"items"`
}

type recallCorpus struct {
	Seed    int64               `json:"seed"`
	Modules map[string][]string `json:"modules"`
	Samples []recallSample      `json:"samples"`
}

func allowModules(mods []string) func(string) bool {
	g := moduleGraph{root: "r", mods: mods, loaded: true}
	return g.allowFunc("r")
}

func evaluateSample(smp recallSample, allowed func(string) bool) (res recallResult, forbidden, duplicates int) {
	idx := make([]int, len(smp.Items))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool { return smp.Items[idx[a]].SortText < smp.Items[idx[b]].SortText })
	rawLabels := make([]string, len(idx))
	for i, j := range idx {
		rawLabels[i] = smp.Items[j].Label
	}
	ranked := rankItemsFor(smp.Items, smp.Query, allowed)
	ranked = ranked[:min(len(ranked), maxCompletionRows)]
	golensLabels := make([]string, len(ranked))
	seen := map[string]bool{}
	for i, r := range ranked {
		row := makeRow(&smp.Items[r.index], r)
		golensLabels[i] = row.Label
		key := row.Label + "\x00" + row.Kind + "\x00" + row.Package
		if seen[key] {
			duplicates++
		}
		seen[key] = true
		if imp := smp.Items[r.index].unimportedPath(); imp != "" && !allowed(imp) {
			forbidden++
		}
	}
	kind := smp.Kind
	if kind == "selector" {
		kind = itemKindName(smp.Items, smp.Ident)
	}
	return recallResult{root: smp.Root, file: smp.File, kind: kind, ident: smp.Ident, snippet: smp.Snippet,
		raw: rankOf(rawLabels, smp.Ident), golens: rankOf(golensLabels, smp.Ident)}, forbidden, duplicates
}

const recallMissing = maxCompletionRows

var recallKeywords = map[token.Token]bool{
	token.RETURN: true, token.FOR: true, token.IF: true, token.DEFER: true, token.GO: true,
	token.SWITCH: true, token.SELECT: true, token.BREAK: true, token.CONTINUE: true,
	token.RANGE: true, token.VAR: true, token.CONST: true, token.FUNC: true, token.TYPE: true,
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

func recallRoots() []string {
	if v := os.Getenv("GOLENS_RECALL_ROOTS"); v != "" {
		return strings.Split(v, ":")
	}
	return nil
}

func goFiles(root string, limit int) []string {
	var files []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || len(files) >= limit {
			return filepath.SkipDir
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && (strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") || name == "vendor" || name == "testdata" || name == "node_modules") {
				return filepath.SkipDir
			}
			if sub := filepath.Join(p, "go.mod"); p != root {
				if _, err := os.Stat(sub); err == nil {
					return filepath.SkipDir
				}
			}
			return nil
		}
		if strings.HasSuffix(name, ".go") {
			if fi, err := d.Info(); err == nil && fi.Size() < 256<<10 {
				files = append(files, p)
			}
		}
		return nil
	})
	return files
}

func recallSites(src []byte) []recallSite {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "x.go", src, parser.SkipObjectResolution)
	if err != nil {
		return nil
	}
	off := func(p token.Pos) int { return fset.Position(p).Offset }
	imports := map[string][2]int{}
	grouped := map[string]bool{}
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.IMPORT {
			continue
		}
		for _, spec := range gd.Specs {
			is := spec.(*ast.ImportSpec)
			path, _ := strconv.Unquote(is.Path.Value)
			name := path[strings.LastIndex(path, "/")+1:]
			if is.Name != nil {
				name = is.Name.Name
			}
			imports[name] = [2]int{off(is.Pos()), off(is.End())}
			grouped[name] = gd.Lparen.IsValid() && len(gd.Specs) > 1 && is.Name == nil && !strings.Contains(path, ".")
		}
	}
	var sites []recallSite
	add := func(id *ast.Ident, kind string) {
		if id == nil || len(id.Name) < 2 || id.Name == "_" {
			return
		}
		sites = append(sites, recallSite{start: off(id.Pos()), end: off(id.End()), kind: kind})
	}
	for _, decl := range f.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if !ok || fd.Body == nil {
			continue
		}
		locals := map[string]bool{}
		for _, list := range []*ast.FieldList{fd.Recv, fd.Type.Params, fd.Type.Results} {
			if list == nil {
				continue
			}
			for _, fl := range list.List {
				for _, n := range fl.Names {
					locals[n.Name] = true
				}
			}
		}
		defining := map[*ast.Ident]bool{}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.AssignStmt:
				if n.Tok == token.DEFINE {
					for _, l := range n.Lhs {
						if id, ok := l.(*ast.Ident); ok {
							defining[id] = true
							locals[id.Name] = true
						}
					}
				}
			case *ast.ValueSpec:
				for _, id := range n.Names {
					defining[id] = true
					locals[id.Name] = true
				}
			case *ast.RangeStmt:
				for _, e := range []ast.Expr{n.Key, n.Value} {
					if id, ok := e.(*ast.Ident); ok && n.Tok == token.DEFINE {
						defining[id] = true
						locals[id.Name] = true
					}
				}
			case *ast.LabeledStmt:
				defining[n.Label] = true
			case *ast.BranchStmt:
				if n.Label != nil {
					defining[n.Label] = true
				}
			case *ast.FuncLit:
				for _, fl := range n.Type.Params.List {
					for _, id := range fl.Names {
						defining[id] = true
						locals[id.Name] = true
					}
				}
			case *ast.TypeSpec:
				defining[n.Name] = true
			case *ast.Field:
				for _, id := range n.Names {
					defining[id] = true
				}
			}
			return true
		})
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.SelectorExpr:
				if x, ok := n.X.(*ast.Ident); ok {
					if spec, imported := imports[x.Name]; imported && !locals[x.Name] {
						add(n.Sel, "package member")
						if grouped[x.Name] {
							before := len(sites)
							add(x, "unimported")
							if len(sites) > before {
								sites[len(sites)-1].importSpec = spec
							}
						} else {
							add(x, "package")
						}
						return false
					}
				}
				add(n.Sel, "selector")
				return true
			case *ast.KeyValueExpr:
				if id, ok := n.Key.(*ast.Ident); ok {
					add(id, "literal key")
					defining[id] = true
				}
			case *ast.Ident:
				if defining[n] {
					return true
				}
				if locals[n.Name] {
					add(n, "local")
				} else {
					add(n, "identifier")
				}
			}
			return true
		})
	}
	seenSel := map[int]bool{}
	out := sites[:0]
	for _, s := range sites {
		if seenSel[s.start] {
			continue
		}
		seenSel[s.start] = true
		out = append(out, s)
	}
	sites = out
	var sc scanner.Scanner
	file := token.NewFileSet().AddFile("x.go", -1, len(src))
	sc.Init(file, src, nil, 0)
	for {
		pos, tok, lit := sc.Scan()
		if tok == token.EOF {
			break
		}
		if recallKeywords[tok] {
			o := file.Offset(pos)
			if o > 0 && (src[o-1] == '\t' || src[o-1] == ' ') {
				sites = append(sites, recallSite{start: o, end: o + len(lit), kind: "keyword"})
			}
		}
	}
	return sites
}

func lineSnippet(src []byte, caret int) string {
	s := strings.LastIndexByte(string(src[:caret]), '\n') + 1
	e := strings.IndexByte(string(src[caret:]), '\n')
	if e < 0 {
		e = len(src) - caret
	}
	return strings.TrimSpace(string(src[s:caret]) + "‸" + string(src[caret:caret+e]))
}

func rankOf(labels []string, ident string) int {
	for i, l := range labels {
		if strings.TrimSpace(l) == ident {
			return i
		}
	}
	return recallMissing
}

type recallMetrics struct {
	n                  int
	r1, r3, r5, rr     float64
	vr1, vr3, vr5, vrr float64
}

func (m *recallMetrics) add(raw, golens int) {
	m.n++
	acc := func(rank int, r1, r3, r5, rr *float64) {
		if rank < 1 {
			*r1++
		}
		if rank < 3 {
			*r3++
		}
		if rank < 5 {
			*r5++
		}
		if rank < recallMissing {
			*rr += 1 / float64(rank+1)
		}
	}
	acc(raw, &m.r1, &m.r3, &m.r5, &m.rr)
	acc(golens, &m.vr1, &m.vr3, &m.vr5, &m.vrr)
}

func (m *recallMetrics) row(name string) string {
	n := float64(max(m.n, 1))
	return fmt.Sprintf("%-15s %5d | gopls R@1 %.3f R@3 %.3f R@5 %.3f MRR %.3f | golens R@1 %.3f R@3 %.3f R@5 %.3f MRR %.3f",
		name, m.n, m.r1/n, m.r3/n, m.r5/n, m.rr/n, m.vr1/n, m.vr3/n, m.vr5/n, m.vrr/n)
}

func itemKindName(items []completionItem, ident string) string {
	for _, it := range items {
		if strings.TrimSpace(it.Label) == ident {
			switch it.Kind {
			case 2:
				return "method"
			case 5, 10:
				return "field"
			}
		}
	}
	return "selector"
}

func TestCompletionRecall(t *testing.T) {
	setupPATH()
	if _, err := exec.LookPath("gopls"); err != nil {
		t.Skip("gopls not installed")
	}
	roots := recallRoots()
	if len(roots) == 0 {
		t.Skip("no sample corpora on this machine")
	}
	total := envInt("GOLENS_RECALL_N", 200)
	seed := int64(envInt("GOLENS_RECALL_SEED", 1))
	rng := rand.New(rand.NewSource(seed))
	freshStore(t)
	t.Cleanup(Shutdown)

	quota := map[string]int{}
	std := ""
	for _, r := range roots {
		if strings.HasSuffix(r, "/go/src") {
			std = r
		}
	}
	others := len(roots)
	if std != "" {
		quota[std] = total / 2
		others--
	}
	for _, r := range roots {
		if r != std && others > 0 {
			quota[r] = (total - quota[std]) / others
		}
	}

	started := time.Now()
	corpus := recallCorpus{Seed: seed, Modules: map[string][]string{}}
	if replay := os.Getenv("GOLENS_RECALL_REPLAY"); replay != "" {
		data, err := os.ReadFile(replay)
		if err != nil || json.Unmarshal(data, &corpus) != nil {
			t.Fatalf("cannot replay %s: %v", replay, err)
		}
		roots = nil
	}
	for _, root := range roots {
		files := goFiles(root, 20000)
		if len(files) == 0 || quota[root] == 0 {
			continue
		}
		CloseWorkspace()
		OpenWorkspace(root)
		waitFor(t, "gopls for "+root, 60*time.Second, func() bool { srv := current(); return srv != nil && srv.root == root })
		waitFor(t, "module graph for "+root, 60*time.Second, func() bool { return projectModules.ready(root) })
		corpus.Modules[filepath.Base(root)] = projectModules.modules(root)
		warm := false
		for got, tries := 0, 0; got < quota[root] && tries < quota[root]*10; tries++ {
			path := files[rng.Intn(len(files))]
			src, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			sites := recallSites(src)
			if len(sites) == 0 {
				continue
			}
			site := sites[rng.Intn(len(sites))]
			ident := string(src[site.start:site.end])
			runes := []rune(ident)
			if len(runes) < 2 {
				continue
			}
			k := len(string(runes[:1+rng.Intn(min(3, len(runes)-1))]))
			overlay := append(append([]byte(nil), src[:site.start+k]...), src[site.end:]...)
			if site.importSpec[1] > 0 {
				for i := site.importSpec[0]; i < site.importSpec[1]; i++ {
					overlay[i] = ' '
				}
			}
			caret := site.start + k
			OpenDocument(path, overlay)
			var start completionStart
			budget := 5 * time.Second
			if !warm {
				budget = 90 * time.Second
			}
			deadline := time.Now().Add(budget)
			for time.Now().Before(deadline) {
				_ = json.Unmarshal([]byte(StartCompletion(path, caret, 1, "")), &start)
				if start.OK {
					break
				}
				time.Sleep(200 * time.Millisecond)
			}
			if !start.OK {
				CloseDocument(path)
				continue
			}
			warm = true
			completions.mu.Lock()
			s := completions.session
			completions.mu.Unlock()
			rel, _ := filepath.Rel(root, path)
			corpus.Samples = append(corpus.Samples, recallSample{Root: filepath.Base(root), File: rel, Kind: site.kind, Ident: ident,
				Snippet: lineSnippet(overlay, caret), Query: s.query, Items: s.items})
			CloseDocument(path)
			got++
		}
	}
	if save := os.Getenv("GOLENS_RECALL_SAVE"); save != "" {
		if data, err := json.Marshal(corpus); err == nil {
			_ = os.WriteFile(save, data, 0o644)
		}
	}
	var results []recallResult
	forbidden, duplicates := 0, 0
	missKind, shown := os.Getenv("GOLENS_RECALL_MISSES"), 0
	for _, smp := range corpus.Samples {
		r, f, d := evaluateSample(smp, allowModules(corpus.Modules[smp.Root]))
		if missKind != "" && r.kind == missKind && r.golens > 0 && shown < 25 {
			shown++
			var top []string
			for _, ri := range rankItemsFor(smp.Items, smp.Query, nil)[:min(5, len(smp.Items))] {
				top = append(top, smp.Items[ri.index].Label)
			}
			t.Logf("miss %q (golens #%d, gopls #%d): %s -> %v", r.ident, r.golens+1, r.raw+1, r.snippet, top)
		}
		results = append(results, r)
		forbidden += f
		duplicates += d
		if f > 0 {
			t.Logf("forbidden unimported suggestion in %s/%s", smp.Root, smp.File)
		}
	}
	if len(results) == 0 {
		t.Skip("no samples collected")
	}

	var all recallMetrics
	byKind := map[string]*recallMetrics{}
	for _, r := range results {
		all.add(r.raw, r.golens)
		if byKind[r.kind] == nil {
			byKind[r.kind] = &recallMetrics{}
		}
		byKind[r.kind].add(r.raw, r.golens)
	}
	var b strings.Builder
	_, _ = fmt.Fprintf(&b, "masked-identifier recall: %d samples, seed %d, %v\n", len(results), corpus.Seed, time.Since(started).Round(time.Second))
	b.WriteString(all.row("all") + "\n")
	kinds := make([]string, 0, len(byKind))
	for k := range byKind {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	for _, k := range kinds {
		b.WriteString(byKind[k].row(k) + "\n")
	}
	sort.SliceStable(results, func(i, j int) bool { return results[i].golens-results[i].raw > results[j].golens-results[j].raw })
	b.WriteString("worst GoLens-vs-gopls regressions:\n")
	for _, r := range results[:min(20, len(results))] {
		if r.golens <= r.raw {
			break
		}
		_, _ = fmt.Fprintf(&b, "  %s/%s [%s] %q gopls #%d golens #%d: %s\n", r.root, r.file, r.kind, r.ident, r.raw+1, r.golens+1, r.snippet)
	}
	t.Log(b.String())
	if out := os.Getenv("GOLENS_RECALL_OUT"); out != "" {
		_ = os.WriteFile(out, []byte(b.String()), 0o644)
	}
	if forbidden > 0 || duplicates > 0 {
		t.Errorf("%d forbidden unimported suggestions, %d duplicate rows", forbidden, duplicates)
	}
	n := float64(all.n)
	for _, m := range []struct {
		name      string
		raw, golens float64
	}{{"R@1", all.r1, all.vr1}, {"R@3", all.r3, all.vr3}, {"R@5", all.r5, all.vr5}, {"MRR", all.rr, all.vrr}} {
		if m.golens < m.raw {
			t.Errorf("GoLens %s %.3f is below raw gopls %.3f", m.name, m.golens/n, m.raw/n)
		}
	}
}
