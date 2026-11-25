package usageindex

import (
	"context"
	"errors"
	"fmt"
	"go/types"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func writeFiles(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, src := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func mustUpdate(t *testing.T, ix *Index, dir string, rels ...string) {
	t.Helper()
	paths := make([]string, len(rels))
	for i, rel := range rels {
		paths[i] = filepath.Join(dir, rel)
	}
	if err := ix.Update(context.Background(), paths); err != nil {
		t.Fatalf("Update(%v): %v", rels, err)
	}
}

// allLenses returns FileLenses of every file the index knows.
func allLenses(ix *Index) map[string]map[Pos]Lens {
	out := map[string]map[Pos]Lens{}
	for name := range ix.files {
		out[name] = ix.FileLenses(name)
	}
	return out
}

// diffFromFresh lists every file whose lenses, counts and implementation
// results, differ between ix and fresh, including files only one of them
// knows.
func diffFromFresh(ix, fresh *Index) []string {
	got, want := allLenses(ix), allLenses(fresh)
	names := map[string]bool{}
	for n := range got {
		names[n] = true
	}
	for n := range want {
		names[n] = true
	}
	var diffs []string
	for n := range names {
		if !reflect.DeepEqual(got[n], want[n]) {
			diffs = append(diffs, fmt.Sprintf("%s: updated %v, fresh %v", n, got[n], want[n]))
		}
	}
	sort.Strings(diffs)
	return diffs
}

// expectMatchesFreshBuild fails unless every file's lenses equal those of a
// fresh Build of dir.
func expectMatchesFreshBuild(t *testing.T, ix *Index, dir string, opts Options) {
	t.Helper()
	fresh, err := Build(context.Background(), dir, opts)
	if err != nil {
		t.Fatalf("fresh Build: %v", err)
	}
	if diffs := diffFromFresh(ix, fresh); len(diffs) > 0 {
		t.Fatalf("updated index differs from a fresh build:\n%s", strings.Join(diffs, "\n"))
	}
}

func TestUpdateAddsAndRemovesCall(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": "package a\n\nfunc F() int { return 1 }\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() }\n",
	})
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 1})

	writeFiles(t, dir, map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.F() }\n"})
	mustUpdate(t, ix, dir, "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 2})
	expectMatchesFreshBuild(t, ix, dir, Options{})

	writeFiles(t, dir, map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nvar _ = a.F\n\nfunc B() int { return 0 }\n"})
	mustUpdate(t, ix, dir, "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 1})
	expectMatchesFreshBuild(t, ix, dir, Options{})
}

func TestUpdateMethodMakesTypeImplementWorkspaceInterface(t *testing.T) {
	files := map[string]string{
		"c/c.go": `package c

type Namer interface {
	Name() string
	Kind() int
}

func Call(n Namer) string { _ = n.Kind(); return n.Name() }
`,
		"d/d.go": `package d

type T struct{}

func (T) Name() string { return "t" }
`,
	}
	dir, ix := buildModule(t, files)
	expectCounts(t, ix, dir, "d/d.go", map[string]int{"T": 1, "Name": 0})

	writeFiles(t, dir, map[string]string{"d/d.go": files["d/d.go"] + "\nfunc (T) Kind() int { return 0 }\n"})
	mustUpdate(t, ix, dir, "d/d.go")
	expectCounts(t, ix, dir, "d/d.go", map[string]int{"T": 2, "Name": 1, "Kind": 1})
	expectCounts(t, ix, dir, "c/c.go", map[string]int{"Namer": 1, "Call": 0})
	expectMatchesFreshBuild(t, ix, dir, Options{})
}

func TestUpdateHubPackageReChecksImporters(t *testing.T) {
	hub := `package h

import "example.com/m/base"

type H struct{ base.Base }

func Hub() {}
`
	dir, ix := buildModule(t, map[string]string{
		"base/base.go": "package base\n\ntype Base struct{}\n\nfunc (Base) M() {}\n",
		"h/h.go":       hub,
		"a/a.go":       "package a\n\nimport \"example.com/m/h\"\n\nfunc A(x h.H) { x.M(); h.Hub() }\n",
		"a/a_test.go": `package a

import (
	"testing"

	"example.com/m/h"
)

func TestA(t *testing.T) { A(h.H{}); h.H{}.M() }
`,
		"b/b.go": "package b\n\nimport \"example.com/m/h\"\n\nfunc B(x h.H) { x.M() }\n",
		"c/c.go": "package c\n\nimport (\n\t\"example.com/m/b\"\n\t\"example.com/m/h\"\n)\n\nfunc C() { b.B(h.H{}) }\n",
	})
	expectCounts(t, ix, dir, "base/base.go", map[string]int{"Base": 2, "M": 3})
	expectCounts(t, ix, dir, "h/h.go", map[string]int{"H": 5, "Hub": 1})

	l := ix.l
	writeFiles(t, dir, map[string]string{"h/h.go": hub + "\nfunc (H) M() {}\n"})
	mustUpdate(t, ix, dir, "h/h.go")
	if ix.l != l {
		t.Fatal("a body edit rebuilt the index")
	}
	expectCounts(t, ix, dir, "base/base.go", map[string]int{"Base": 2, "M": 0})
	expectCounts(t, ix, dir, "h/h.go", map[string]int{"H": 6, "Hub": 1, "M": 3})
	expectMatchesFreshBuild(t, ix, dir, Options{})
}

func TestUpdateKeepsLastGoodCountsThroughErrors(t *testing.T) {
	a := "package a\n\nfunc F() int { return 1 }\n\nfunc G() int { return F() }\n"
	b := "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.G() }\n"
	dir, ix := buildModule(t, map[string]string{"a/a.go": a, "b/b.go": b})
	wantA := map[string]int{"F": 2, "G": 1}
	wantB := map[string]int{"B": 0}
	expectCounts(t, ix, dir, "a/a.go", wantA)

	writeFiles(t, dir, map[string]string{"b/b.go": b + "\nfunc Broken( {\n"})
	mustUpdate(t, ix, dir, "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", wantA)
	if got := ix.FileLenses(filepath.Join(dir, "b/b.go")); len(got) != 1 {
		t.Fatalf("b/b.go counts after syntax error = %v, want the last good counts", got)
	}

	writeFiles(t, dir, map[string]string{"a/a.go": strings.Replace(a, "return 1", `return "x"`, 1)})
	mustUpdate(t, ix, dir, "a/a.go")
	expectCounts(t, ix, dir, "a/a.go", wantA)

	writeFiles(t, dir, map[string]string{
		"a/a.go": a + "\nfunc H() int { return F() }\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.H() + a.H() }\n",
	})
	mustUpdate(t, ix, dir, "a/a.go", "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 3, "G": 0, "H": 2})
	expectCounts(t, ix, dir, "b/b.go", wantB)
	expectMatchesFreshBuild(t, ix, dir, Options{})
}

func TestBrokenTestVariantKeepsPackageCounts(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"p/p.go":      "package p\n\nfunc F() int { return 1 }\n\nfunc G() int { return F() }\n",
		"p/p_test.go": "package p\n\nfunc TestBroken() int { return \"x\" + F() }\n",
	})
	expectCounts(t, ix, dir, "p/p.go", map[string]int{"F": 2, "G": 0})
	if got := countsByName(t, ix, dir, "p/p_test.go"); got != nil {
		t.Errorf("p/p_test.go counts = %v, want none", got)
	}
}

// testOverlay returns Options whose overlay serves the sources given to the
// returned function; an empty source drops the file from the overlay.
func testOverlay() (Options, func(path, src string)) {
	var mu sync.Mutex
	overlay := map[string]string{}
	opts := Options{Overlay: func(path string) ([]byte, bool) {
		mu.Lock()
		defer mu.Unlock()
		src, ok := overlay[path]
		return []byte(src), ok
	}}
	return opts, func(path, src string) {
		mu.Lock()
		defer mu.Unlock()
		if src == "" {
			delete(overlay, path)
		} else {
			overlay[path] = src
		}
	}
}

func TestUpdateOverlayWinsOverDisk(t *testing.T) {
	opts, setOverlay := testOverlay()
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": "module example.com/m\n\ngo 1.26\n",
		"a/a.go": "package a\n\nfunc F() int { return 1 }\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() }\n",
	})
	bPath := filepath.Join(dir, "b/b.go")
	setOverlay(bPath, "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.F() }\n")
	ix, err := Build(context.Background(), dir, opts)
	if err != nil {
		t.Fatal(err)
	}
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 2})

	setOverlay(bPath, "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.F() + a.F() }\n")
	mustUpdate(t, ix, dir, "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 3})
	expectMatchesFreshBuild(t, ix, dir, opts)

	setOverlay(bPath, "")
	mustUpdate(t, ix, dir, "b/b.go")
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 1})
	expectMatchesFreshBuild(t, ix, dir, opts)
}

func TestUpdateStructuralChangesRebuild(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": "package a\n\nfunc F() int { return 1 }\n",
		"b/b.go": "package b\n\nfunc B() int { return 2 }\n",
		"c/c.go": "package c\n\nimport \"example.com/m/a\"\n\nfunc C() int { return a.F() }\n",
	})
	steps := []struct {
		name    string
		write   map[string]string
		del     string
		rel     string
		rebuild bool
		want    map[string]int
	}{
		{name: "new file", write: map[string]string{"a/new.go": "package a\n\nfunc N() int { return F() }\n"}, rel: "a/new.go", rebuild: true, want: map[string]int{"F": 2}},
		{name: "deleted file", del: "a/new.go", rel: "a/new.go", rebuild: true, want: map[string]int{"F": 1}},
		{name: "added import", write: map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() }\n"}, rel: "b/b.go", rebuild: true, want: map[string]int{"F": 2}},
		{name: "removed import", write: map[string]string{"c/c.go": "package c\n\nfunc C() int { return 0 }\n"}, rel: "c/c.go", want: map[string]int{"F": 1}},
		{name: "re-added import", write: map[string]string{"c/c.go": "package c\n\nimport \"example.com/m/a\"\n\nfunc C() int { return a.F() }\n"}, rel: "c/c.go", rebuild: true, want: map[string]int{"F": 2}},
		{name: "package clause", write: map[string]string{"b/b.go": "package bb\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() }\n"}, rel: "b/b.go", rebuild: true, want: map[string]int{"F": 2}},
		{name: "build constraint", write: map[string]string{"c/c.go": "//go:build ignore\n\npackage c\n\nimport \"example.com/m/a\"\n\nfunc C() int { return a.F() }\n"}, rel: "c/c.go", rebuild: true, want: map[string]int{"F": 1}},
	}
	for _, s := range steps {
		writeFiles(t, dir, s.write)
		if s.del != "" {
			if err := os.Remove(filepath.Join(dir, s.del)); err != nil {
				t.Fatal(err)
			}
		}
		l := ix.l
		mustUpdate(t, ix, dir, s.rel)
		if rebuilt := ix.l != l; rebuilt != s.rebuild {
			t.Fatalf("%s: rebuilt = %t, want %t", s.name, rebuilt, s.rebuild)
		}
		if got := countsByName(t, ix, dir, "a/a.go"); !reflect.DeepEqual(got, s.want) {
			t.Fatalf("%s: a/a.go counts = %v, want %v", s.name, got, s.want)
		}
		expectMatchesFreshBuild(t, ix, dir, Options{})
	}
}

// TestRebuildAfterReleaseMatchesUpdates edits a module through the overlay,
// applying each edit to one index with Update alone and to another by
// releasing its types and rebuilding it, and checks after each edit that both
// have the same lenses. A variant with errors keeps its last good data in
// both; one that never type-checked has none in either.
func TestRebuildAfterReleaseMatchesUpdates(t *testing.T) {
	a := `package a

type Closer interface{ Close() error }

type T struct{}

func (T) Close() error { return nil }

func F() int { return 1 }

func G(c Closer) int { _ = c.Close(); return F() }
`
	b := `package b

import "example.com/m/a"

type R struct{}

func (R) Close() error { return nil }

func useR(x interface{ Close() error }) error { return x.Close() }

func B() int { _ = useR(R{}); return a.F() + a.G(a.T{}) }
`
	c := "package c\n\nimport \"example.com/m/b\"\n\nfunc C() int { return b.B() + \"x\" }\n"
	e := `package e

type W struct{}

func (W) Close() int { return 0 }

func useW(x interface{ Close() int }) int { return x.Close() }

func E() { useW(W{}) }
`
	files := map[string]string{
		"a/a.go":      a,
		"a/a_test.go": "package a\n\nimport \"testing\"\n\nfunc TestF(t *testing.T) { F(); _ = T{}.Close() }\n",
		"b/b.go":      b,
		"c/c.go":      c,
		"e/e.go":      e,
	}
	dir := t.TempDir()
	files["go.mod"] = "module example.com/m\n\ngo 1.26\n"
	writeFiles(t, dir, files)
	opts, setOverlay := testOverlay()
	ctx := context.Background()
	upd, err := Build(ctx, dir, opts)
	if err != nil {
		t.Fatal(err)
	}
	rb, err := Build(ctx, dir, opts)
	if err != nil {
		t.Fatal(err)
	}
	path := func(rel string) string { return filepath.Join(dir, rel) }
	if upd.FileLenses(path("c/c.go")) != nil {
		t.Fatal("c/c.go has lenses before it ever type-checked")
	}
	expectCounts(t, upd, dir, "b/b.go", map[string]int{"R": 2, "Close": 2, "useR": 1, "B": 1})

	steps := []struct {
		name    string
		rel     string
		src     string
		release bool
		fresh   bool
	}{
		{name: "type error in a", rel: "a/a.go", src: a + "\nfunc Bad() int { return \"x\" }\n", release: true},
		{name: "syntax error in b", rel: "b/b.go", src: b + "\nfunc Broken( {\n", release: true},
		{name: "edit in e while a and b are broken", rel: "e/e.go", src: e + "\nfunc E2() { E() }\n", release: true},
		{name: "fix a", rel: "a/a.go", src: a, release: true},
		{name: "fix b in place after a rebuild", rel: "b/b.go", src: b, fresh: true},
		{name: "fix c", rel: "c/c.go", src: strings.Replace(c, ` + "x"`, "", 1), release: true, fresh: true},
	}
	for _, s := range steps {
		setOverlay(path(s.rel), s.src)
		mustUpdate(t, upd, dir, s.rel)
		if s.release {
			rb.ReleaseTypes()
		}
		mustUpdate(t, rb, dir, s.rel)
		if diffs := diffFromFresh(rb, upd); len(diffs) > 0 {
			t.Fatalf("%s: rebuilt index differs from the updated one:\n%s", s.name, strings.Join(diffs, "\n"))
		}
		for _, rel := range []string{"a/a.go", "b/b.go", "e/e.go"} {
			if rb.FileLenses(path(rel)) == nil {
				t.Fatalf("%s: %s lost its lenses", s.name, rel)
			}
		}
		if got := rb.FileLenses(path("c/c.go")) != nil; got != (s.rel == "c/c.go") {
			t.Fatalf("%s: c/c.go has lenses = %t", s.name, got)
		}
		expectCounts(t, rb, dir, "b/b.go", map[string]int{"R": 2, "Close": 2, "useR": 1, "B": 1})
		if got := countsByName(t, rb, dir, "e/e.go"); got["Close"] != 1 {
			t.Fatalf("%s: e/e.go counts = %v, want Close 1", s.name, got)
		}
		if s.fresh {
			expectMatchesFreshBuild(t, rb, dir, opts)
		}
	}
}

func TestReleaseTypesThenUpdate(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": "package a\n\nfunc F() int { return 1 }\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() }\n",
	})
	ix.ReleaseTypes()
	if ix.l != nil {
		t.Fatal("types still retained after ReleaseTypes")
	}
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 1})

	writeFiles(t, dir, map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc B() int { return a.F() + a.F() }\n"})
	mustUpdate(t, ix, dir, "b/b.go")
	if ix.l == nil {
		t.Fatal("Update after ReleaseTypes did not rebuild")
	}
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 2})
	expectMatchesFreshBuild(t, ix, dir, Options{})
}

// cancelAfter reports context.Canceled from Err once it has been asked n
// times, so an update is cancelled at a chosen package boundary.
type cancelAfter struct {
	context.Context
	n atomic.Int32
}

func (c *cancelAfter) Err() error {
	if c.n.Add(-1) < 0 {
		return context.Canceled
	}
	return nil
}

func TestCancelledUpdateLeavesCountsUnchanged(t *testing.T) {
	hub := "package h\n\ntype H struct{}\n\nfunc (H) M() {}\n\nfunc Hub() {}\n"
	files := map[string]string{"h/h.go": hub}
	for _, p := range []string{"a", "b", "c", "d"} {
		files[p+"/"+p+".go"] = fmt.Sprintf("package %s\n\nimport \"example.com/m/h\"\n\nfunc %s() { h.Hub(); h.H{}.M() }\n", p, strings.ToUpper(p))
	}
	dir, ix := buildModule(t, files)
	before := allLenses(ix)
	writeFiles(t, dir, map[string]string{"h/h.go": hub + "\nfunc Extra() { Hub() }\n"})
	path := filepath.Join(dir, "h/h.go")

	cancelled := 0
	for n := int32(0); ; n++ {
		ctx := &cancelAfter{Context: context.Background()}
		ctx.n.Store(n)
		err := ix.Update(ctx, []string{path})
		if err == nil {
			break
		}
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Update cancelled after %d checks: %v", n, err)
		}
		cancelled++
		if got := allLenses(ix); !reflect.DeepEqual(got, before) {
			t.Fatalf("counts changed by an Update cancelled after %d checks", n)
		}
	}
	if cancelled < 5 {
		t.Fatalf("only %d cancellation points exercised, want one per re-checked package", cancelled)
	}
	expectMatchesFreshBuild(t, ix, dir, Options{})

	ix.ReleaseTypes()
	writeFiles(t, dir, map[string]string{"h/h.go": hub})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	snapshot := allLenses(ix)
	if err := ix.Update(ctx, []string{path}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled rebuild error = %v, want context.Canceled", err)
	}
	if got := allLenses(ix); !reflect.DeepEqual(got, snapshot) {
		t.Fatal("counts changed by a cancelled rebuild")
	}
}

func TestFileLensesDuringUpdate(t *testing.T) {
	calls := func(n int) string {
		return "package b\n\nimport \"example.com/m/a\"\n\nfunc B() {\n" + strings.Repeat("\ta.F()\n\ta.G()\n", n) + "}\n"
	}
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": "package a\n\nfunc F() {}\n\nfunc G() {}\n",
		"b/b.go": calls(1),
	})
	aPath := filepath.Join(dir, "a/a.go")
	fPos := Pos{Line: 3, Col: 6}
	gPos := Pos{Line: 5, Col: 6}

	stop := make(chan struct{})
	var reads atomic.Int64
	var bad atomic.Value
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				c := ix.FileLenses(aPath)
				if c == nil || c[fPos].Count != c[gPos].Count {
					bad.Store(fmt.Sprint(c))
				}
				reads.Add(1)
			}
		}()
	}
	for i := 2; i <= 21; i++ {
		writeFiles(t, dir, map[string]string{"b/b.go": calls(i)})
		if i == 10 {
			ix.ReleaseTypes()
		}
		mustUpdate(t, ix, dir, "b/b.go")
	}
	close(stop)
	wg.Wait()
	if v := bad.Load(); v != nil {
		t.Fatalf("FileLenses observed a half-applied update: %v", v)
	}
	if reads.Load() == 0 {
		t.Fatal("no concurrent reads ran")
	}
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"F": 21, "G": 21})
}

func TestBuildTakesGOARCHFromGoEnv(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{"go.mod": "module example.com/m\n\ngo 1.26\n", "m.go": "package m\n"})
	withArch := func(arch string) Options {
		return Options{RunGo: func(ctx context.Context, dir string, args ...string) ([]byte, error) {
			if len(args) > 0 && args[0] == "env" {
				return []byte(arch + "\n"), nil
			}
			return runGo(ctx, dir, args...)
		}}
	}
	ix, err := Build(context.Background(), dir, withArch("386"))
	if err != nil {
		t.Fatal(err)
	}
	if want := types.SizesFor("gc", "386"); ix.l.sizes != want {
		t.Fatalf("sizes = %v, want those of 386", ix.l.sizes)
	}
	if _, err := Build(context.Background(), dir, withArch("nonsense")); err == nil || !strings.Contains(err.Error(), "GOARCH") {
		t.Fatalf("Build with an unknown GOARCH: err = %v", err)
	}
}
