package usageindex

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const serviceModule = "module example.com/m\n\ngo 1.26\n"

func newTestService(t *testing.T) *Service {
	t.Helper()
	s := NewService(func(string) {})
	t.Cleanup(s.Close)
	return s
}

func waitState(t *testing.T, s *Service, path, want string) Reply {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		r := s.Query(path)
		if r.State == want {
			return r
		}
		if time.Now().After(deadline) {
			t.Fatalf("state = %s (%s), want %s", r.State, r.Reason, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func countAt(r Reply, line int) (int, bool) {
	for _, c := range r.Counts {
		if c.Line == line {
			return c.Count, true
		}
	}
	return 0, false
}

func TestServiceLifecycle(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F() }\n",
	})
	aPath, bPath := filepath.Join(dir, "a/a.go"), filepath.Join(dir, "b/b.go")
	var lists atomic.Int32
	opts := Options{RunGo: func(ctx context.Context, d string, args ...string) ([]byte, error) {
		if args[0] == "list" {
			lists.Add(1)
		}
		return runGo(ctx, d, args...)
	}}
	s := newTestService(t)
	if r := s.Query(aPath); r.State != StateUnavailable {
		t.Fatalf("before Open: state = %s, want unavailable", r.State)
	}
	s.Open(dir)
	if r := s.Query(aPath); r.State != StateBuilding {
		t.Fatalf("after Open, before Start: state = %s, want building", r.State)
	}
	s.Start(dir, opts)
	r := waitState(t, s, aPath, StateReady)
	if n, ok := countAt(r, 3); !ok || n != 1 {
		t.Fatalf("F count = %d, %v; want 1 (%+v)", n, ok, r)
	}

	writeFiles(t, dir, map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F(); a.F() }\n"})
	s.MarkDirty(bPath)
	if n, _ := countAt(s.Query(aPath), 3); n != 2 {
		t.Fatalf("after editing b.go: F count = %d, want 2", n)
	}

	s.Start(dir, opts)
	if n := lists.Load(); n != 1 {
		t.Fatalf("a second Start for a ready index ran go list again: %d runs", n)
	}
	s.Invalidate(filepath.Join(dir, "go.mod"))
	waitState(t, s, aPath, StateReady)
	if n := lists.Load(); n != 2 {
		t.Fatalf("go.mod change: go list runs = %d, want 2", n)
	}
	if r := s.Query(filepath.Join(t.TempDir(), "x.go")); r.State != StateUnavailable {
		t.Fatalf("file outside the workspace: state = %s, want unavailable", r.State)
	}

	s.Close()
	if r := s.Query(aPath); r.State != StateUnavailable {
		t.Fatalf("after Close: state = %s, want unavailable", r.State)
	}
}

func TestServiceOverlayFromBuffers(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n\nfunc G() {}\n",
	})
	aPath := filepath.Join(dir, "a/a.go")
	var mu sync.Mutex
	buffers := map[string][]byte{}
	s := newTestService(t)
	s.Open(dir)
	s.Start(dir, Options{Overlay: func(p string) ([]byte, bool) {
		mu.Lock()
		defer mu.Unlock()
		b, ok := buffers[p]
		return b, ok
	}})
	waitState(t, s, aPath, StateReady)

	mu.Lock()
	buffers[aPath] = []byte("package a\n\nfunc F() {}\n\nfunc G() { F(); F(); F() }\n")
	mu.Unlock()
	s.MarkDirty(aPath)
	if n, _ := countAt(s.Query(aPath), 3); n != 3 {
		t.Fatalf("unsaved buffer: F count = %d, want 3", n)
	}
}

func TestServiceCloseCancelsBuild(t *testing.T) {
	dir := t.TempDir()
	started := make(chan struct{})
	stopped := make(chan error, 1)
	s := newTestService(t)
	s.Open(dir)
	s.Start(dir, Options{RunGo: func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		close(started)
		<-ctx.Done()
		stopped <- ctx.Err()
		return nil, ctx.Err()
	}})
	<-started
	s.Close()
	select {
	case err := <-stopped:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("build context error = %v, want canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not cancel the build")
	}
	if r := s.Query(filepath.Join(dir, "a.go")); r.State != StateUnavailable {
		t.Fatalf("after Close: state = %s, want unavailable", r.State)
	}
}

func TestServiceDisabled(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{"go.mod": serviceModule, "m.go": "package m\n\nfunc F() {}\n"})
	path := filepath.Join(dir, "m.go")
	s := newTestService(t)
	s.SetEnabled(false)
	s.Open(dir)
	s.Start(dir, Options{})
	if r := s.Query(path); r.State != StateUnavailable {
		t.Fatalf("disabled: state = %s, want unavailable", r.State)
	}
	s.SetEnabled(true)
	waitState(t, s, path, StateReady)
	s.SetEnabled(false)
	s.mu.Lock()
	kept := s.ix != nil
	s.mu.Unlock()
	if r := s.Query(path); r.State != StateUnavailable || kept {
		t.Fatalf("turned off: state = %s, index kept = %v", r.State, kept)
	}
}

func TestServiceSkipsIgnoredPaths(t *testing.T) {
	root := filepath.Join(t.TempDir(), "ws")
	s := newTestService(t)
	s.Open(root)
	for _, rel := range []string{"testdata/x.go", "a/testdata/x.go", "vendor/v/x.go", ".git/x.go", "a/.hidden/x.go", "_tools/x.go", "a/x.txt"} {
		s.MarkDirty(filepath.Join(root, rel))
	}
	s.MarkDirty(filepath.Join(filepath.Dir(root), "other/x.go"))
	s.MarkDirty(root + "x/y.go")
	if len(s.dirty) != 0 {
		t.Fatalf("ignored paths marked dirty: %v", s.dirty)
	}
	for _, rel := range []string{"x.go", "a/b/x.go", "a/data/x_test.go"} {
		s.MarkDirty(filepath.Join(root, rel))
	}
	if len(s.dirty) != 3 {
		t.Fatalf("dirty = %v, want the three workspace files", s.dirty)
	}
}

func waitReleased(t *testing.T, s *Service) *Index {
	t.Helper()
	s.mu.Lock()
	ix := s.ix
	s.mu.Unlock()
	deadline := time.Now().Add(5 * time.Second)
	for !ix.released() {
		if time.Now().After(deadline) {
			t.Fatal("types were not released after the idle period")
		}
		time.Sleep(5 * time.Millisecond)
	}
	return ix
}

func TestServiceReleasesTypesWhenIdle(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"m.go":   "package m\n\nfunc F() {}\n\nfunc G() { F() }\n",
		"n/n.go": "package n\n\nfunc H() {}\n\nfunc I() { H() }\n",
	})
	path, other := filepath.Join(dir, "m.go"), filepath.Join(dir, "n/n.go")
	s := newTestService(t)
	s.idle = 30 * time.Millisecond
	s.Open(dir)
	s.Start(dir, Options{})
	waitState(t, s, path, StateReady)
	ix := waitReleased(t, s)
	if n, ok := countAt(s.Query(path), 3); !ok || n != 1 {
		t.Fatalf("after release: F count = %d, %v; want 1", n, ok)
	}

	s.mu.Lock()
	s.idle = time.Hour
	s.mu.Unlock()
	writeFiles(t, dir, map[string]string{"m.go": "package m\n\nfunc F() {}\n\nfunc G() { F(); F() }\n"})
	s.MarkDirty(path)
	if r := s.Query(path); r.State != StateRefreshing || r.Counts != nil {
		t.Fatalf("first query after release = %+v, want refreshing without the edited file's stale counts", r)
	}
	if r := s.Query(other); r.State != StateRefreshing {
		t.Fatalf("query of an unedited file during the rebuild: state = %s, want refreshing", r.State)
	} else if n, ok := countAt(r, 3); !ok || n != 1 {
		t.Fatalf("unedited file during the rebuild: H count = %d, %v; want the last count 1", n, ok)
	}
	r := waitState(t, s, path, StateReady)
	if n, _ := countAt(r, 3); n != 2 {
		t.Fatalf("after the background rebuild: F count = %d, want 2", n)
	}
	if ix.released() {
		t.Fatal("the background rebuild did not retain the types")
	}
}

func TestServiceRetriesFailedRebuildAndReadsGOARCHOnce(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\ntype Namer interface{ Name() string }\n\nfunc F() {}\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F() }\n",
	})
	aPath, bPath := filepath.Join(dir, "a/a.go"), filepath.Join(dir, "b/b.go")
	var envRuns atomic.Int32
	var failList atomic.Bool
	opts := Options{RunGo: func(ctx context.Context, d string, args ...string) ([]byte, error) {
		switch {
		case args[0] == "env":
			envRuns.Add(1)
		case args[0] == "list" && failList.Load():
			return nil, errors.New("exit status 1")
		}
		return runGo(ctx, d, args...)
	}}
	s := newTestService(t)
	s.idle = 30 * time.Millisecond
	s.Open(dir)
	s.Start(dir, opts)
	waitState(t, s, aPath, StateReady)
	waitReleased(t, s)
	s.mu.Lock()
	s.idle = time.Hour
	s.mu.Unlock()

	writeFiles(t, dir, map[string]string{"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\ntype T struct{}\n\nfunc (T) Name() string { return \"\" }\n\nfunc G() { a.F(); a.F() }\n"})
	s.MarkDirty(bPath)
	failList.Store(true)
	if r := s.Query(aPath); r.State != StateRefreshing {
		t.Fatalf("query after release: state = %s, want refreshing", r.State)
	}
	r := waitState(t, s, aPath, StateReady)
	if n, _ := countAt(r, 5); n != 1 {
		t.Fatalf("after the failed rebuild: F count = %d, want the last count 1", n)
	}
	if len(r.Counts) == 0 || r.Counts[0].Impls != nil {
		t.Fatalf("after the failed rebuild: Namer lens = %+v, want the last result, no implementations", r.Counts)
	}

	failList.Store(false)
	if r := s.Query(aPath); r.State != StateRefreshing {
		t.Fatalf("query after the failure: state = %s, want a retry in the background", r.State)
	}
	r = waitState(t, s, aPath, StateReady)
	if n, _ := countAt(r, 5); n != 2 {
		t.Fatalf("after the retry: F count = %d, want 2", n)
	}
	if got := r.Counts[0].Impls; len(got) != 1 || got[0].File != bPath || got[0].Line != 5 {
		t.Fatalf("after the retry: Namer implementations = %+v, want b.T", got)
	}
	s.mu.Lock()
	ix := s.ix
	s.mu.Unlock()
	fresh, err := Build(context.Background(), dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if diffs := diffFromFresh(ix, fresh); len(diffs) > 0 {
		t.Fatalf("after the retry the index differs from a fresh build:\n%s", strings.Join(diffs, "\n"))
	}

	s.Invalidate(filepath.Join(dir, "go.mod"))
	waitState(t, s, aPath, StateReady)
	if n := envRuns.Load(); n != 1 {
		t.Fatalf("go env ran %d times for one open workspace, want 1", n)
	}
}

// queryWithin fails unless Query answers within d, so that a query blocked on
// a rebuild fails the test instead of hanging it.
func queryWithin(t *testing.T, s *Service, path string, d time.Duration) Reply {
	t.Helper()
	done := make(chan Reply, 1)
	go func() { done <- s.Query(path) }()
	select {
	case r := <-done:
		return r
	case <-time.After(d):
		t.Fatalf("Query(%s) did not answer within %v", path, d)
		return Reply{}
	}
}

func TestServiceRebuildsStructuralChangesInBackground(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F() }\n",
	})
	aPath, cPath := filepath.Join(dir, "a/a.go"), filepath.Join(dir, "b/c.go")
	var gated atomic.Bool
	var lists atomic.Int32
	proceed := make(chan struct{})
	opts := Options{RunGo: func(ctx context.Context, d string, args ...string) ([]byte, error) {
		if args[0] == "list" {
			lists.Add(1)
			if gated.Load() {
				select {
				case <-proceed:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
		}
		return runGo(ctx, d, args...)
	}}
	allowList := func() {
		t.Helper()
		select {
		case proceed <- struct{}{}:
		case <-time.After(10 * time.Second):
			t.Fatal("no background go list started")
		}
	}
	s := newTestService(t)
	s.Open(dir)
	s.Start(dir, opts)
	waitState(t, s, aPath, StateReady)
	s.mu.Lock()
	ix := s.ix
	s.mu.Unlock()
	if ix.released() {
		t.Fatal("types released before the structural change")
	}

	gated.Store(true)
	writeFiles(t, dir, map[string]string{"b/c.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc H() { a.F() }\n"})
	s.MarkDirty(cPath)
	r := queryWithin(t, s, aPath, 5*time.Second)
	if r.State != StateRefreshing {
		t.Fatalf("query after a new file: state = %s, want refreshing", r.State)
	}
	if n, ok := countAt(r, 3); !ok || n != 1 {
		t.Fatalf("during the rebuild: F count = %d, %v; want the last count 1", n, ok)
	}
	if r := queryWithin(t, s, cPath, 5*time.Second); r.State != StateRefreshing || r.Counts != nil {
		t.Fatalf("new file during the rebuild = %+v, want refreshing without counts", r)
	}
	allowList()
	r = waitState(t, s, aPath, StateReady)
	if n, _ := countAt(r, 3); n != 2 {
		t.Fatalf("after the background rebuild: F count = %d, want 2", n)
	}
	if ix.released() {
		t.Fatal("the background rebuild did not retain the types")
	}
	fresh, err := Build(context.Background(), dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if diffs := diffFromFresh(ix, fresh); len(diffs) > 0 {
		t.Fatalf("after the background rebuild the index differs from a fresh build:\n%s", strings.Join(diffs, "\n"))
	}

	before := lists.Load()
	s.Invalidate(filepath.Join(dir, "go.mod"))
	r = queryWithin(t, s, aPath, 5*time.Second)
	if n, ok := countAt(r, 3); r.State != StateRefreshing || !ok || n != 2 {
		t.Fatalf("query after a go.mod change = %+v, want refreshing with the last count 2", r)
	}
	allowList()
	waitState(t, s, aPath, StateReady)
	if n := lists.Load() - before; n != 1 {
		t.Fatalf("go.mod change: go list runs = %d, want 1", n)
	}
}

func TestGoCommandErrorIncludesStderr(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{"go.mod": "module example.com/m\n\ngo 1.26\n\nrequire (\n", "m.go": "package m\n"})
	_, err := Build(context.Background(), dir, Options{})
	if err == nil || !strings.Contains(err.Error(), "go list: exit status 1: go: errors parsing go.mod") {
		t.Fatalf("Build error = %v, want the go list failure with its stderr", err)
	}
	exit := errors.New("exit status 1")
	long := CommandError(exit, []byte("  "+strings.Repeat("x", 5000)+"\n"))
	if !errors.Is(long, exit) || len(long.Error()) > len(exit.Error())+2+maxStderr+3 || !strings.HasSuffix(long.Error(), "x...") {
		t.Fatalf("long stderr: %d bytes, %q...", len(long.Error()), long.Error()[:40])
	}
	if got := CommandError(exit, []byte(" \n")).Error(); got != "exit status 1 (nothing on stderr)" {
		t.Fatalf("empty stderr: %q", got)
	}
}

func TestServiceConcurrentQueriesRunOneUpdate(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{"go.mod": serviceModule, "m.go": "package m\n\nfunc F() {}\n"})
	path := filepath.Join(dir, "m.go")
	var reads atomic.Int32
	counting := atomic.Bool{}
	s := newTestService(t)
	s.Open(dir)
	s.Start(dir, Options{Overlay: func(p string) ([]byte, bool) {
		if p == path && counting.Load() {
			reads.Add(1)
		}
		return nil, false
	}})
	waitState(t, s, path, StateReady)
	counting.Store(true)
	s.MarkDirty(path)
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if r := s.Query(path); r.State != StateReady {
				t.Errorf("state = %s, want ready", r.State)
			}
		})
	}
	wg.Wait()
	if n := reads.Load(); n != 1 {
		t.Fatalf("the dirty file was read %d times by 8 concurrent queries, want 1 update", n)
	}
}

func TestBuildRefusesTooLargeWorkspace(t *testing.T) {
	dir := t.TempDir()
	var list strings.Builder
	for i := range maxWorkspaceVariants + 1 {
		fmt.Fprintf(&list, `{"ImportPath":"example.com/m/p%d","Name":"p%d","Dir":%q,"GoFiles":["p.go"],"Module":{"Main":true}}`+"\n", i, i, filepath.Join(dir, fmt.Sprint(i)))
	}
	var overlayReads, lists atomic.Int32
	opts := Options{
		RunGo: func(_ context.Context, _ string, args ...string) ([]byte, error) {
			if args[0] == "env" {
				return []byte("arm64\n"), nil
			}
			lists.Add(1)
			return []byte(list.String()), nil
		},
		Overlay: func(string) ([]byte, bool) {
			overlayReads.Add(1)
			return nil, false
		},
	}
	if _, err := Build(context.Background(), dir, opts); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("Build error = %v, want ErrTooLarge", err)
	}
	if n := overlayReads.Load(); n != 0 {
		t.Fatalf("a too-large workspace read %d files", n)
	}
	lists.Store(0)
	s, delays, _, _, advance, _ := backoffService(t)
	s.Open(dir)
	s.Start(dir, opts)
	path := filepath.Join(dir, "0", "p.go")
	if r := waitState(t, s, path, StateUnavailable); !strings.Contains(r.Reason, "workspace too large") {
		t.Fatalf("reason = %q, want workspace too large", r.Reason)
	}
	advance(2 * retryEvery)
	if r := s.Query(path); r.State != StateUnavailable || lists.Load() != 1 || len(delays) != 0 {
		t.Fatalf("too-large workspace later: state = %s, go list runs = %d, backoffs = %d; want unavailable without retries", r.State, lists.Load(), len(delays))
	}
}

func TestServiceLogsVariantsWithoutFreshData(t *testing.T) {
	dir := t.TempDir()
	b := "package b\n\nfunc B() int { return 1 }\n"
	c := "package c\n\nfunc C() int { return 2 }\n"
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n",
		"b/b.go": strings.Replace(b, "1", `"x"`, 1),
		"c/c.go": c + "\nfunc Broken( {\n",
	})
	aPath, bPath, cPath := filepath.Join(dir, "a/a.go"), filepath.Join(dir, "b/b.go"), filepath.Join(dir, "c/c.go")
	var mu sync.Mutex
	var logs []string
	since := func(n int) []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(logs[n:])
	}
	s := NewService(func(msg string) {
		mu.Lock()
		defer mu.Unlock()
		logs = append(logs, msg)
	})
	t.Cleanup(s.Close)
	s.idle = 30 * time.Millisecond
	s.Open(dir)
	s.Start(dir, Options{})
	waitState(t, s, aPath, StateReady)
	got := since(0)
	if len(got) != 2 || !strings.HasPrefix(got[0], "usage index ready for ") ||
		!strings.HasPrefix(got[1], "usage index has no fresh data for 2 package variants: example.com/m/b: "+bPath+":3:23: cannot use \"x\"") ||
		!strings.Contains(got[1], "; example.com/m/c: "+cPath+":5:14: expected ')'") {
		t.Fatalf("build logs = %q, want ready then the two broken variants with their first errors", got)
	}

	rebuild := func(rel, src string) []string {
		t.Helper()
		n := len(since(0))
		waitReleased(t, s)
		writeFiles(t, dir, map[string]string{rel: src})
		s.MarkDirty(filepath.Join(dir, rel))
		if r := s.Query(aPath); r.State != StateRefreshing {
			t.Fatalf("query after release: state = %s, want refreshing", r.State)
		}
		waitState(t, s, aPath, StateReady)
		return since(n)
	}
	got = rebuild("b/b.go", b)
	if len(got) != 2 || !strings.HasPrefix(got[0], "usage index rebuilt after its types were released") ||
		!strings.HasPrefix(got[1], "usage index has no fresh data for 1 package variant: example.com/m/c: "+cPath+":5:14: expected ')'") {
		t.Fatalf("rebuild logs = %q, want rebuilt then the one broken variant", got)
	}
	got = rebuild("c/c.go", c)
	if len(got) != 1 || !strings.HasPrefix(got[0], "usage index rebuilt after its types were released") {
		t.Fatalf("clean rebuild logs = %q, want only the rebuilt line", got)
	}
}

func TestStaleReportCapsVariantsAndErrors(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{"go.mod": serviceModule}
	long := strings.Repeat("y", 1000)
	for i := range 12 {
		files[fmt.Sprintf("p%02d/p.go", i)] = fmt.Sprintf("package p%02d\n\nfunc F() int { return %s }\n", i, long)
	}
	writeFiles(t, dir, files)
	_, report, err := build(context.Background(), dir, Options{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	head, list, _ := strings.Cut(report, ": ")
	parts := strings.Split(list, "; ")
	if head != "usage index has no fresh data for 12 package variants" || len(parts) != 11 || parts[10] != "and 2 more" {
		t.Fatalf("report = %.300q..., want 10 variants and 2 more", report)
	}
	for i, p := range parts[:10] {
		id := fmt.Sprintf("example.com/m/p%02d", i)
		msg, ok := strings.CutPrefix(p, id+": ")
		if !ok || !strings.Contains(msg, "undefined: yyy") || len(msg) > maxStderr+3 || !strings.HasSuffix(msg, "...") {
			t.Fatalf("variant %d: %d bytes, %.120q", i, len(msg), p)
		}
	}
	if _, report, err := build(context.Background(), dir, Options{Overlay: func(p string) ([]byte, bool) {
		return []byte("package " + filepath.Base(filepath.Dir(p)) + "\n"), true
	}}, nil); err != nil || report != "" {
		t.Fatalf("clean build report = %q, %v; want none", report, err)
	}

	mixed := t.TempDir()
	writeFiles(t, mixed, map[string]string{"go.mod": serviceModule, "d/d.go": "package d\n", "d/e.go": "package e\n"})
	_, report, err = build(context.Background(), mixed, Options{}, nil)
	if err != nil || !strings.HasPrefix(report, "usage index has no fresh data for 1 package variant: example.com/m/d: go list: found packages d (d.go) and e (e.go)") {
		t.Fatalf("go list error report = %q, %v", report, err)
	}
}

// backoffService returns a service whose backoff waits hand each delay to the
// test on delays and wait for a release, and whose clock the test advances.
func backoffService(t *testing.T) (s *Service, delays chan time.Duration, release chan struct{}, canceled chan struct{}, advance func(time.Duration), logs func() []string) {
	t.Helper()
	var mu sync.Mutex
	var lines []string
	s = NewService(func(msg string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, msg)
	})
	t.Cleanup(s.Close)
	delays, release, canceled = make(chan time.Duration, 8), make(chan struct{}), make(chan struct{}, 8)
	s.wait = func(ctx context.Context, d time.Duration) bool {
		delays <- d
		select {
		case <-release:
			return true
		case <-ctx.Done():
			canceled <- struct{}{}
			return false
		}
	}
	base := time.Now()
	var offset atomic.Int64
	s.now = func() time.Time { return base.Add(time.Duration(offset.Load())) }
	advance = func(d time.Duration) { offset.Add(int64(d)) }
	logs = func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(lines)
	}
	return
}

func nextDelay(t *testing.T, delays chan time.Duration, want time.Duration) {
	t.Helper()
	select {
	case d := <-delays:
		if d != want {
			t.Fatalf("backoff delay = %v, want %v", d, want)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("no retry was scheduled, want one after %v", want)
	}
}

var errExit = Retryable(CommandError(errors.New("exit status 1"), nil))

func TestServiceRetriesFailedFirstBuild(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F(); a.F() }\n",
	})
	aPath := filepath.Join(dir, "a/a.go")
	var envRuns, listRuns atomic.Int32
	opts := Options{RunGo: func(ctx context.Context, d string, args ...string) ([]byte, error) {
		switch {
		case args[0] == "env" && envRuns.Add(1) == 1:
			return nil, errExit
		case args[0] == "list" && listRuns.Add(1) == 1:
			return nil, errExit
		}
		return runGo(ctx, d, args...)
	}}
	s, delays, release, _, _, logs := backoffService(t)
	s.Open(dir)
	s.Start(dir, opts)
	for _, d := range buildBackoff[:2] {
		nextDelay(t, delays, d)
		if r := s.Query(aPath); r.State != StateBuilding {
			t.Fatalf("waiting %v to retry: state = %s (%s), want building", d, r.State, r.Reason)
		}
		release <- struct{}{}
	}
	r := waitState(t, s, aPath, StateReady)
	if n, ok := countAt(r, 3); !ok || n != 2 {
		t.Fatalf("after the retries: F count = %d, %v; want 2", n, ok)
	}
	got := logs()
	if len(got) != 3 ||
		!strings.HasPrefix(got[0], "usage index build attempt 1 failed for "+dir+", retrying in 2s: usageindex: go env: exit status 1 (nothing on stderr)") ||
		!strings.HasPrefix(got[1], "usage index build attempt 2 failed for "+dir+", retrying in 5s: usageindex: go list: exit status 1 (nothing on stderr)") ||
		!strings.HasPrefix(got[2], "usage index ready for "+dir) {
		t.Fatalf("logs = %q, want two failed attempts then ready", got)
	}
}

func TestServiceRetriesAfterBackoffAtMostEveryMinute(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "m.go")
	var runs atomic.Int32
	opts := Options{RunGo: func(context.Context, string, ...string) ([]byte, error) {
		runs.Add(1)
		return nil, errExit
	}}
	s, delays, release, _, advance, logs := backoffService(t)
	s.Open(dir)
	s.Start(dir, opts)
	for _, d := range buildBackoff {
		nextDelay(t, delays, d)
		if r := s.Query(path); r.State != StateBuilding {
			t.Fatalf("waiting %v to retry: state = %s (%s), want building", d, r.State, r.Reason)
		}
		release <- struct{}{}
	}
	r := waitState(t, s, path, StateUnavailable)
	if !strings.Contains(r.Reason, "go env: exit status 1") {
		t.Fatalf("reason = %q, want the go env failure", r.Reason)
	}
	attempts := len(buildBackoff) + 1
	if n := runs.Load(); int(n) != attempts {
		t.Fatalf("go ran %d times, want %d attempts", n, attempts)
	}
	if got := logs(); len(got) != attempts || !strings.HasPrefix(got[attempts-1], fmt.Sprintf("usage index unavailable for %s after attempt %d: ", dir, attempts)) {
		t.Fatalf("logs = %q, want one line per attempt ending unavailable", got)
	}

	advance(retryEvery - time.Second)
	if r := s.Query(path); r.State != StateUnavailable || runs.Load() != int32(attempts) {
		t.Fatalf("query before a minute passed: state = %s, go runs = %d; want unavailable and no retry", r.State, runs.Load())
	}
	advance(time.Second)
	if r := s.Query(path); r.State != StateBuilding {
		t.Fatalf("query after a minute: state = %s, want building", r.State)
	}
	waitState(t, s, path, StateUnavailable)
	if n := runs.Load(); int(n) != attempts+1 {
		t.Fatalf("a query after a minute ran go %d more times, want 1", int(n)-attempts)
	}
	if r := s.Query(path); r.State != StateUnavailable || runs.Load() != int32(attempts+1) {
		t.Fatalf("query right after the failed retry: state = %s, go runs = %d; want no retry", r.State, runs.Load())
	}
	if len(delays) != 0 {
		t.Fatal("the retry after a minute scheduled a backoff")
	}
	if got := logs(); !strings.HasPrefix(got[len(got)-1], fmt.Sprintf("usage index unavailable for %s after attempt %d: ", dir, attempts+1)) {
		t.Fatalf("last log = %q, want attempt %d unavailable", got[len(got)-1], attempts+1)
	}
}

func TestServiceCancelsPendingRetry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if waitDelay(ctx, time.Hour) || !waitDelay(context.Background(), 0) {
		t.Fatal("waitDelay does not stop when its context is done")
	}
	for name, stop := range map[string]func(*Service, string){
		"close":   func(s *Service, _ string) { s.Close() },
		"switch":  func(s *Service, dir string) { s.Open(filepath.Join(dir, "other")) },
		"disable": func(s *Service, _ string) { s.SetEnabled(false) },
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			var runs atomic.Int32
			s, delays, _, canceled, _, _ := backoffService(t)
			s.Open(dir)
			s.Start(dir, Options{RunGo: func(context.Context, string, ...string) ([]byte, error) {
				runs.Add(1)
				return nil, errExit
			}})
			nextDelay(t, delays, buildBackoff[0])
			stop(s, dir)
			select {
			case <-canceled:
			case <-time.After(10 * time.Second):
				t.Fatal("the pending retry was not canceled")
			}
			if n := runs.Load(); n != 1 {
				t.Fatalf("go ran %d times, want only the first attempt", n)
			}
		})
	}
}

func TestReleaseTypesReturnsTrueOnlyWhenRetained(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{
		"go.mod": serviceModule,
		"a/a.go": "package a\n\nfunc F() {}\n",
		"b/b.go": "package b\n\nimport \"example.com/m/a\"\n\nfunc G() { a.F() }\n",
	})
	aPath := filepath.Join(dir, "a/a.go")
	ix, err := Build(context.Background(), dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !ix.releaseTypes() {
		t.Fatal("first releaseTypes = false, want true")
	}
	if ix.releaseTypes() {
		t.Fatal("second releaseTypes = true, want false")
	}
	if err := ix.Update(context.Background(), []string{aPath}); err != nil {
		t.Fatal(err)
	}
	if !ix.releaseTypes() {
		t.Fatal("releaseTypes after Update rebuild = false, want true")
	}
	if ix.releaseTypes() {
		t.Fatal("repeat releaseTypes after rebuild = true, want false")
	}

	s := newTestService(t)
	s.idle = 25 * time.Millisecond
	s.Open(dir)
	s.Start(dir, Options{})
	waitState(t, s, aPath, StateReady)
	started := time.Now()
	ix = waitReleased(t, s)
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("millisecond idle release took %v, want fast completion without FreeOSMemory overhead", elapsed)
	}
	if ix.releaseTypes() {
		t.Fatal("idle-released index still returned true from releaseTypes")
	}
}
