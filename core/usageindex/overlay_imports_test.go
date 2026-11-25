package usageindex

import (
	"context"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"
)

type memOverlay struct {
	mu    sync.RWMutex
	files map[string][]byte
}

func newMemOverlay() *memOverlay {
	return &memOverlay{files: make(map[string][]byte)}
}

func (m *memOverlay) set(path, content string) {
	m.mu.Lock()
	m.files[filepath.Clean(path)] = []byte(content)
	m.mu.Unlock()
}

func (m *memOverlay) get(path string) ([]byte, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	b, ok := m.files[filepath.Clean(path)]
	if !ok {
		return nil, false
	}
	return append([]byte(nil), b...), true
}

func (m *memOverlay) paths() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return slices.Collect(maps.Keys(m.files))
}

func TestOverlayUnsavedCrossPackageImportUpdatesIndexAndService(t *testing.T) {
	dir := t.TempDir()
	diskPkgA := "package pkga\n\nfunc Run() int {\n\treturn 0\n}\n"
	diskPkgB := "package pkgb\n\nfunc Helper() int {\n\treturn 42\n}\n"
	writeFiles(t, dir, map[string]string{
		"go.mod":    serviceModule,
		"pkga/a.go": diskPkgA,
		"pkgb/b.go": diskPkgB,
	})
	aPath := filepath.Join(dir, "pkga/a.go")
	bPath := filepath.Join(dir, "pkgb/b.go")

	ov := newMemOverlay()
	opts := Options{
		Overlay:      ov.get,
		OverlayFiles: ov.paths,
	}

	ctx := context.Background()
	ix, err := Build(ctx, dir, opts)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got := ix.FileLenses(bPath)[Pos{Line: 3, Col: 6}].Count; got != 0 {
		t.Fatalf("initial Helper count = %d, want 0", got)
	}

	unsavedPkgA := "package pkga\n\nimport \"example.com/m/pkgb\"\n\nfunc Run() int {\n\treturn pkgb.Helper() + pkgb.Helper()\n}\n"
	ov.set(aPath, unsavedPkgA)

	if err := ix.Update(ctx, []string{aPath}); err != nil {
		t.Fatalf("Index.Update with unsaved cross-package import: %v", err)
	}
	if got := ix.FileLenses(bPath)[Pos{Line: 3, Col: 6}].Count; got != 2 {
		t.Fatalf("after unsaved cross-package import, Helper count = %d, want 2 (lenses=%+v)", got, ix.FileLenses(bPath))
	}

	// Verify the file on disk was never modified.
	onDisk, err := os.ReadFile(aPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(onDisk) != diskPkgA {
		t.Fatalf("disk file was unexpectedly modified: %q", onDisk)
	}

	// Verify Service rebuild flow (Open -> Start -> MarkDirty -> Query until refreshed) with DefaultOverlayFiles.
	ov2 := newMemOverlay()
	prevDefault := DefaultOverlayFiles
	DefaultOverlayFiles = ov2.paths
	t.Cleanup(func() { DefaultOverlayFiles = prevDefault })

	svc := newTestService(t)
	svc.Open(dir)
	svc.Start(dir, Options{Overlay: ov2.get})
	r := waitState(t, svc, bPath, StateReady)
	if n, ok := countAt(r, 3); !ok || n != 0 {
		t.Fatalf("Service initial Helper count = (%d, %v), want (0, true)", n, ok)
	}

	// Edit a.go in overlay to import pkgb and add a brand-new unsaved file c.go in pkga calling Helper too.
	cPath := filepath.Join(dir, "pkga/c.go")
	ov2.set(aPath, "package pkga\n\nimport \"example.com/m/pkgb\"\n\nfunc Run() int {\n\treturn pkgb.Helper()\n}\n")
	ov2.set(cPath, "package pkga\n\nimport \"example.com/m/pkgb\"\n\nfunc Extra() int {\n\treturn pkgb.Helper()\n}\n")
	svc.MarkDirty(aPath)
	svc.MarkDirty(cPath)

	deadline := time.Now().Add(20 * time.Second)
	for {
		r = svc.Query(bPath)
		if r.State == StateReady {
			if n, ok := countAt(r, 3); ok && n == 2 {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("Service did not converge to Helper count=2; last reply=%+v", r)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
