package goast

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"
)

func TestTopWorkspaceSymbolsMatchesFullSort(t *testing.T) {
	var symbols []WorkspaceSymbolItem
	for i := 0; i < 300; i++ {
		symbols = append(symbols, WorkspaceSymbolItem{
			Name:    fmt.Sprintf("Item%03d", (i*37)%300),
			RelPath: fmt.Sprintf("p%d/f.go", i%7),
			Line:    i,
			Package: "pkg",
		})
	}
	for _, q := range []string{"", "Item", "item01", "I1", "zzz"} {
		var full []WorkspaceSymbolItem
		for _, s := range symbols {
			score := scoreWorkspaceSymbol(s, q)
			if q != "" && score <= 0 {
				continue
			}
			s.Score = score
			full = append(full, s)
		}
		sort.Slice(full, func(i, j int) bool {
			a, b := full[i], full[j]
			if a.Score != b.Score {
				return a.Score > b.Score
			}
			if a.Name != b.Name {
				return a.Name < b.Name
			}
			if a.RelPath != b.RelPath {
				return a.RelPath < b.RelPath
			}
			return a.Line < b.Line
		})
		for _, limit := range []int{1, 10, 1000} {
			got := topWorkspaceSymbols(symbols, q, limit)
			want := full
			if len(want) > limit {
				want = want[:limit]
			}
			if len(got) != len(want) {
				t.Fatalf("q=%q limit=%d: got %d items, want %d", q, limit, len(got), len(want))
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("q=%q limit=%d idx=%d: got %+v want %+v", q, limit, i, got[i], want[i])
				}
			}
		}
	}
}

func TestWorkspaceSymbolIndexPicksUpChangesAfterRefreshInterval(t *testing.T) {
	prev := workspaceSymbolRefreshInterval
	workspaceSymbolRefreshInterval = 0
	defer func() { workspaceSymbolRefreshInterval = prev }()

	root := t.TempDir()
	file := filepath.Join(root, "a.go")
	if err := os.WriteFile(file, []byte("package a\n\nfunc Alpha() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := SearchWorkspaceSymbols(root, "Alpha", 10); len(got) != 1 {
		t.Fatalf("expected Alpha, got %+v", got)
	}
	if err := os.WriteFile(file, []byte("package a\n\nfunc Bravo() {}\n\nfunc Charlie() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Minute)
	if err := os.Chtimes(file, future, future); err != nil {
		t.Fatal(err)
	}
	if got := SearchWorkspaceSymbols(root, "Alpha", 10); len(got) != 0 {
		t.Fatalf("expected Alpha gone, got %+v", got)
	}
	if got := SearchWorkspaceSymbols(root, "Bravo", 10); len(got) != 1 {
		t.Fatalf("expected Bravo, got %+v", got)
	}
}

func TestWorkspaceSymbolIndexThrottlesRescan(t *testing.T) {
	prev := workspaceSymbolRefreshInterval
	workspaceSymbolRefreshInterval = time.Hour
	defer func() { workspaceSymbolRefreshInterval = prev }()

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.go"), []byte("package a\n\nfunc Alpha() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := SearchWorkspaceSymbols(root, "Alpha", 10); len(got) != 1 {
		t.Fatalf("expected Alpha, got %+v", got)
	}
	if err := os.WriteFile(filepath.Join(root, "b.go"), []byte("package a\n\nfunc Delta() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := SearchWorkspaceSymbols(root, "Delta", 10); len(got) != 0 {
		t.Fatalf("expected cached index within refresh interval, got %+v", got)
	}
}

func withLongWorkspaceSymbolRefresh(t *testing.T) {
	prev := workspaceSymbolRefreshInterval
	workspaceSymbolRefreshInterval = time.Hour
	t.Cleanup(func() { workspaceSymbolRefreshInterval = prev })
}

func writeGoFile(t *testing.T, path, src string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceSymbolInvalidationShowsSavedSymbolImmediately(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	file := filepath.Join(root, "a.go")
	writeGoFile(t, file, "package a\n\nfunc Alpha() {}\n")
	if got := SearchWorkspaceSymbols(root, "Alpha", 10); len(got) != 1 {
		t.Fatalf("expected Alpha, got %+v", got)
	}

	writeGoFile(t, file, "package a\n\nfunc Alpha() {}\n\nfunc Echo() {}\n")
	InvalidateWorkspaceSymbolFile(file)
	if got := SearchWorkspaceSymbols(root, "Echo", 10); len(got) != 1 || got[0].RelPath != "a.go" {
		t.Fatalf("expected Echo right after save, got %+v", got)
	}

	added := filepath.Join(root, "pkg", "b.go")
	writeGoFile(t, added, "package pkg\n\ntype Foxtrot struct{}\n")
	InvalidateWorkspaceSymbolFile(added)
	if got := SearchWorkspaceSymbols(root, "Foxtrot", 10); len(got) != 1 || got[0].RelPath != "pkg/b.go" {
		t.Fatalf("expected Foxtrot from new file, got %+v", got)
	}
	if got := SearchWorkspaceSymbols(root, "Alpha", 10); len(got) != 1 {
		t.Fatalf("expected Alpha kept, got %+v", got)
	}
}

func TestWorkspaceSymbolInvalidationRemovesDeletedFile(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	file := filepath.Join(root, "gone.go")
	writeGoFile(t, file, "package a\n\nfunc Golf() {}\n")
	writeGoFile(t, filepath.Join(root, "keep.go"), "package a\n\nfunc Hotel() {}\n")
	if got := SearchWorkspaceSymbols(root, "Golf", 10); len(got) != 1 {
		t.Fatalf("expected Golf, got %+v", got)
	}

	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	InvalidateWorkspaceSymbolFile(file)
	if got := SearchWorkspaceSymbols(root, "Golf", 10); len(got) != 0 {
		t.Fatalf("expected Golf removed, got %+v", got)
	}
	if got := SearchWorkspaceSymbols(root, "Hotel", 10); len(got) != 1 {
		t.Fatalf("expected Hotel kept, got %+v", got)
	}
}

func TestWorkspaceSymbolInvalidationMatchesResolvedPath(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "a.go")
	writeGoFile(t, file, "package a\n\nfunc India() {}\n")
	if got := SearchWorkspaceSymbols(root, "India", 10); len(got) != 1 {
		t.Fatalf("expected India, got %+v", got)
	}
	writeGoFile(t, file, "package a\n\nfunc Juliet() {}\n")
	InvalidateWorkspaceSymbolFile(filepath.Join(resolvedRoot, "a.go"))
	if got := SearchWorkspaceSymbols(root, "Juliet", 10); len(got) != 1 || got[0].File != file {
		t.Fatalf("expected Juliet keyed under the workspace path, got %+v", got)
	}
}

func TestWorkspaceSymbolInvalidationOutsideRootsIsNoOp(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	writeGoFile(t, filepath.Join(root, "a.go"), "package a\n\nfunc Kilo() {}\n")
	before := SearchWorkspaceSymbols(root, "", 100)

	outside := filepath.Join(t.TempDir(), "x.go")
	writeGoFile(t, outside, "package x\n\nfunc Lima() {}\n")
	InvalidateWorkspaceSymbolFile(outside)
	InvalidateWorkspaceSymbolFile(root)
	InvalidateWorkspaceSymbolFile("")

	idx := workspaceSymbolIndexFor(root)
	idx.dirtyMu.Lock()
	pending := len(idx.dirty)
	idx.dirtyMu.Unlock()
	if pending != 0 {
		t.Fatalf("expected no dirty files, got %d", pending)
	}
	after := SearchWorkspaceSymbols(root, "", 100)
	if len(after) != len(before) || len(SearchWorkspaceSymbols(root, "Lima", 10)) != 0 {
		t.Fatalf("index changed after outside invalidation: before %+v after %+v", before, after)
	}
}

func TestWorkspaceSymbolInvalidationSkipsIgnoredDirs(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	writeGoFile(t, filepath.Join(root, "a.go"), "package a\n\nfunc Mike() {}\n")
	SearchWorkspaceSymbols(root, "Mike", 10)
	vendored := filepath.Join(root, "vendor", "v.go")
	writeGoFile(t, vendored, "package v\n\nfunc November() {}\n")
	InvalidateWorkspaceSymbolFile(vendored)
	if got := SearchWorkspaceSymbols(root, "November", 10); len(got) != 0 {
		t.Fatalf("expected vendor file ignored, got %+v", got)
	}
}

func TestWorkspaceSymbolInvalidationConcurrentWithQueries(t *testing.T) {
	withLongWorkspaceSymbolRefresh(t)
	root := t.TempDir()
	file := filepath.Join(root, "a.go")
	writeGoFile(t, file, "package a\n\nfunc Oscar() {}\n")
	SearchWorkspaceSymbols(root, "Oscar", 10)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 200; i++ {
			InvalidateWorkspaceSymbolFile(file)
		}
	}()
	for i := 0; i < 200; i++ {
		if got := SearchWorkspaceSymbols(root, "Oscar", 10); len(got) != 1 {
			t.Fatalf("expected Oscar, got %+v", got)
		}
	}
	<-done
}
