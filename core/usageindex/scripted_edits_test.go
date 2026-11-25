package usageindex

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

type editTarget struct {
	pkg   string
	files []string
	funcs []string
	types []string
}

type editSample struct {
	took     time.Duration
	pkg      string
	kind     string
	affected int
}

// TestScriptedEditsMatchFreshBuild copies a real workspace, applies a script
// of edits over many packages with an Update after each, and checks at
// checkpoints that every file's lenses, counts and implementation results,
// equal a fresh Build. At each checkpoint it also checks that releasing the
// types and rebuilding gives the lenses of the updated index, on the clean
// tree and with a type error and a syntax error injected in two packages.
// It logs update and query latency and the heap held with and without
// retained types.
func TestScriptedEditsMatchFreshBuild(t *testing.T) {
	src := os.Getenv("USAGEINDEX_EDIT_WS")
	if src == "" {
		t.Skip("set USAGEINDEX_EDIT_WS to a workspace directory")
	}
	src, err := filepath.Abs(src)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	copyTree(t, src, dir)
	ctx := context.Background()

	start := time.Now()
	ix, err := Build(ctx, dir, Options{})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	t.Logf("initial build %v, HeapAlloc after GC %.1f MB", time.Since(start).Round(time.Millisecond), heapMB())

	targets := editTargets(t, ix)
	if len(targets) < 10 {
		t.Fatalf("only %d editable packages", len(targets))
	}
	rng := rand.New(rand.NewPCG(1, 2))
	rng.Shuffle(len(targets), func(i, j int) { targets[i], targets[j] = targets[j], targets[i] })

	const steps = 220
	const checkpoints = 10
	orig := map[string][]byte{}
	cur := map[string][]byte{}
	var samples []editSample
	var log []string
	read := func(path string) []byte {
		if b, ok := cur[path]; ok {
			return b
		}
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		orig[path] = b
		cur[path] = b
		return b
	}
	apply := func(tg editTarget, path, kind string, content []byte) {
		if err := os.WriteFile(path, content, 0o644); err != nil {
			t.Fatal(err)
		}
		cur[path] = content
		affected := affectedVariants(ix, path)
		t0 := time.Now()
		if err := ix.Update(ctx, []string{path}); err != nil {
			t.Fatalf("Update after %s on %s: %v", kind, path, err)
		}
		samples = append(samples, editSample{took: time.Since(t0), pkg: tg.pkg, kind: kind, affected: affected})
		log = append(log, fmt.Sprintf("%s %s", kind, strings.TrimPrefix(path, dir+"/")))
	}
	compare := func(label string) {
		fresh, err := Build(ctx, dir, Options{})
		if err != nil {
			t.Fatalf("%s: fresh Build: %v", label, err)
		}
		if diffs := diffFromFresh(ix, fresh); len(diffs) > 0 {
			t.Fatalf("%s: %d files differ from a fresh build:\n%s\nedits so far:\n%s",
				label, len(diffs), strings.Join(diffs, "\n"), strings.Join(log, "\n"))
		}
		t.Logf("%s after %d updates: all %d files equal a fresh build", label, len(samples), len(fresh.files))
	}
	// rebuildMatches gives a copy of ix's state the rebuild that follows
	// ReleaseTypes and checks that it has the lenses of ix, kept by Update.
	rebuildMatches := func(label string, broken ...string) {
		t0 := time.Now()
		rb := &Index{dir: ix.dir, opts: ix.opts, sizes: ix.sizes, state: ix.state}
		if _, err := rb.reload(ctx); err != nil {
			t.Fatalf("%s: rebuild: %v", label, err)
		}
		if diffs := diffFromFresh(rb, ix); len(diffs) > 0 {
			t.Fatalf("%s: %d files differ between the rebuilt and the updated index:\n%s\nedits so far:\n%s",
				label, len(diffs), strings.Join(diffs, "\n"), strings.Join(log, "\n"))
		}
		for _, p := range broken {
			if rb.FileLenses(p) == nil {
				t.Fatalf("%s: the rebuild dropped the last good lenses of %s", label, p)
			}
		}
		t.Logf("%s: rebuild after release equals the updated index (%v)", label, time.Since(t0).Round(time.Millisecond))
	}
	checkpoint := func(n int) {
		label := fmt.Sprintf("checkpoint %d", n)
		compare(label)
		rebuildMatches(label + ", clean tree")
		var broken []string
		for j, inject := range []string{"\nfunc zzTypeError() int { return \"x\" }\n", "\nfunc zzBroken( {\n"} {
			p := targets[(2*n+j)%len(targets)].files[0]
			broken = append(broken, p)
			if err := os.WriteFile(p, append(slices.Clone(read(p)), inject...), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := ix.Update(ctx, []string{p}); err != nil {
				t.Fatalf("%s: Update after injecting an error in %s: %v", label, p, err)
			}
		}
		rebuildMatches(label+", type and syntax errors in "+strings.TrimPrefix(broken[0], dir+"/")+" and "+strings.TrimPrefix(broken[1], dir+"/"), broken...)
		for _, p := range broken {
			if err := os.WriteFile(p, cur[p], 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if err := ix.Update(ctx, broken); err != nil {
			t.Fatalf("%s: Update after removing the injected errors: %v", label, err)
		}
	}

	for i := range steps {
		tg := targets[i%len(targets)]
		path := tg.files[rng.IntN(len(tg.files))]
		body := read(path)
		kind := []string{"call", "call", "method", "method", "syntax", "revert"}[i%6]
		if kind == "call" && len(tg.funcs) == 0 {
			kind = "method"
		}
		if kind == "method" && len(tg.types) == 0 {
			kind = "call"
		}
		if kind == "revert" {
			edited := slices.Sorted(func(yield func(string) bool) {
				for p := range orig {
					if !slices.Equal(orig[p], cur[p]) && !yield(p) {
						return
					}
				}
			})
			if len(edited) == 0 {
				kind = "call"
			} else {
				p := edited[rng.IntN(len(edited))]
				apply(targetOf(targets, p, tg), p, "revert", orig[p])
			}
		}
		switch kind {
		case "call":
			fn := tg.funcs[rng.IntN(len(tg.funcs))]
			apply(tg, path, "call", fmt.Appendf(slices.Clone(body), "\nfunc zzEditCall%d() { %s() }\n", i, fn))
		case "method":
			typ := tg.types[rng.IntN(len(tg.types))]
			apply(tg, path, "method", fmt.Appendf(slices.Clone(body), "\nfunc (*%s) ZzEditMethod%d() {}\n", typ, i))
		case "syntax":
			apply(tg, path, "syntax-error", append(slices.Clone(body), "\nfunc zzBroken( {\n"...))
			apply(tg, path, "syntax-fix", body)
		}
		if (i+1)%(steps/checkpoints) == 0 && i+1 < steps {
			checkpoint((i + 1) / (steps / checkpoints))
		}
	}
	compare("final")
	if len(samples) < 200 {
		t.Fatalf("only %d updates ran, want at least 200", len(samples))
	}

	logLatency(t, samples)

	var queries []time.Duration
	var decls, impls int
	for name := range ix.files {
		t0 := time.Now()
		lenses := ix.FileLenses(name)
		queries = append(queries, time.Since(t0))
		for _, l := range lenses {
			decls++
			impls += len(l.Impls)
		}
	}
	slices.Sort(queries)
	t.Logf("FileLenses over %d files (%d declarations, %d implementation locations): median %v, p95 %v, max %v",
		len(queries), decls, impls, queries[len(queries)/2].Round(10*time.Microsecond),
		queries[len(queries)*95/100].Round(10*time.Microsecond), queries[len(queries)-1].Round(10*time.Microsecond))

	retained := heapMB()
	ix.ReleaseTypes()
	t.Logf("HeapAlloc after GC: %.1f MB with types retained, %.1f MB after ReleaseTypes", retained, heapMB())
	runtime.KeepAlive(ix)
}

func heapMB() float64 {
	var ms runtime.MemStats
	runtime.GC()
	runtime.GC()
	runtime.ReadMemStats(&ms)
	return float64(ms.HeapAlloc) / (1 << 20)
}

func logLatency(t *testing.T, samples []editSample) {
	t.Helper()
	sorted := slices.Clone(samples)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].took < sorted[j].took })
	q := func(s []editSample, f float64) time.Duration {
		if len(s) == 0 {
			return 0
		}
		return s[min(len(s)-1, int(f*float64(len(s))))].took.Round(100 * time.Microsecond)
	}
	slow := sorted[len(sorted)-1]
	t.Logf("updates %d: median %v, p95 %v, max %v", len(sorted), q(sorted, 0.5), q(sorted, 0.95), slow.took.Round(100*time.Microsecond))
	t.Logf("slowest update: %v, %s in %s, %d variants re-checked", slow.took.Round(100*time.Microsecond), slow.kind, slow.pkg, slow.affected)
	var few, many []editSample
	for _, s := range sorted {
		if s.affected <= 5 {
			few = append(few, s)
		} else {
			many = append(many, s)
		}
	}
	pkgs := map[string]bool{}
	for _, s := range few {
		pkgs[s.pkg] = true
	}
	t.Logf("edits re-checking at most 5 variants: %d in %d packages, median %v, p95 %v", len(few), len(pkgs), q(few, 0.5), q(few, 0.95))
	t.Logf("edits re-checking more than 5 variants: %d, median %v, p95 %v", len(many), q(many, 0.5), q(many, 0.95))
}

// affectedVariants counts the package variants an Update of path re-checks.
func affectedVariants(ix *Index, path string) int {
	seen := map[int]bool{}
	queue := slices.Clone(ix.files[path].pkgs)
	for len(queue) > 0 {
		p := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		if !seen[p] {
			seen[p] = true
			queue = append(queue, ix.pkgs[p].importedBy...)
		}
	}
	return len(seen)
}

func targetOf(targets []editTarget, path string, fallback editTarget) editTarget {
	for _, tg := range targets {
		if slices.Contains(tg.files, path) {
			return tg
		}
	}
	return fallback
}

// editTargets lists, for every cleanly type-checked plain workspace package,
// its non-test files, its top-level functions callable without arguments and
// its non-generic struct types.
func editTargets(t *testing.T, ix *Index) []editTarget {
	t.Helper()
	var out []editTarget
	for i, pe := range ix.pkgs {
		if pe.itv || pe.broken || strings.Contains(pe.id, " [") {
			continue
		}
		tg := editTarget{pkg: pe.path}
		for _, fe := range pe.files {
			if fe.owner != i || strings.HasSuffix(fe.name, "_test.go") {
				continue
			}
			f, err := parser.ParseFile(token.NewFileSet(), fe.name, nil, parser.SkipObjectResolution)
			if err != nil {
				t.Fatal(err)
			}
			tg.files = append(tg.files, fe.name)
			for _, d := range f.Decls {
				switch d := d.(type) {
				case *ast.FuncDecl:
					if d.Recv == nil && d.Type.TypeParams == nil && d.Type.Params.NumFields() == 0 && d.Name.Name != "init" {
						tg.funcs = append(tg.funcs, d.Name.Name)
					}
				case *ast.GenDecl:
					for _, s := range d.Specs {
						if ts, ok := s.(*ast.TypeSpec); ok && ts.TypeParams == nil && !ts.Assign.IsValid() {
							if _, ok := ts.Type.(*ast.StructType); ok {
								tg.types = append(tg.types, ts.Name.Name)
							}
						}
					}
				}
			}
		}
		if len(tg.files) > 0 && len(tg.funcs)+len(tg.types) > 0 {
			out = append(out, tg)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].pkg < out[j].pkg })
	return out
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir() && d.Name() == ".git":
			return filepath.SkipDir
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case !d.Type().IsRegular():
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		t.Fatalf("copy %s: %v", src, err)
	}
}
