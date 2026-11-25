package lsp

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func drainWire(w *wire) []map[string]any {
	var out []map[string]any
	for {
		select {
		case m, ok := <-w.msgs:
			if !ok {
				return out
			}
			out = append(out, m)
		default:
			return out
		}
	}
}

func waitWireCount(t *testing.T, w *wire, n int) []map[string]any {
	t.Helper()
	out := make([]map[string]any, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, w.next())
	}
	return out
}

func msgURI(m map[string]any) string {
	params, _ := m["params"].(map[string]any)
	td, _ := params["textDocument"].(map[string]any)
	u, _ := td["uri"].(string)
	return u
}

func sentPaths() []string {
	docs.mu.Lock()
	defer docs.mu.Unlock()
	var out []string
	for p, d := range docs.docs {
		if d.sent {
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}

func TestMRUEvictionKeepsBuffersReadable(t *testing.T) {
	freshStore(t)
	docs.maxOpen = 20
	s, w := fakeServer(t, 2)
	docs.attach(s)

	var allPaths []string
	for i := 1; i <= 30; i++ {
		p := fmt.Sprintf("/w/file_%02d.go", i)
		allPaths = append(allPaths, p)
		body := fmt.Sprintf("package w\nconst V%02d = %d\n", i, i)
		OpenDocument(p, []byte(body))
		if i <= 20 {
			m := w.next()
			if m["method"] != "textDocument/didOpen" || msgURI(m) != pathToURI(p) {
				t.Fatalf("open %d: got %v", i, m)
			}
		} else {
			m1 := w.next()
			m2 := w.next()
			if m1["method"] != "textDocument/didOpen" || msgURI(m1) != pathToURI(p) {
				t.Fatalf("open %d first msg: got %v", i, m1)
			}
			wantClosed := fmt.Sprintf("/w/file_%02d.go", i-20)
			if m2["method"] != "textDocument/didClose" || msgURI(m2) != pathToURI(wantClosed) {
				t.Fatalf("open %d expected didClose for %s, got %v", i, wantClosed, m2)
			}
		}
	}
	w.none()

	gotSent := sentPaths()
	if len(gotSent) != 20 {
		t.Fatalf("expected 20 sent documents, got %d (%v)", len(gotSent), gotSent)
	}
	for i := 1; i <= 10; i++ {
		evicted := fmt.Sprintf("/w/file_%02d.go", i)
		if slices.Contains(gotSent, evicted) {
			t.Fatalf("expected %s to be evicted from gopls", evicted)
		}
	}
	for i := 11; i <= 30; i++ {
		kept := fmt.Sprintf("/w/file_%02d.go", i)
		if !slices.Contains(gotSent, kept) {
			t.Fatalf("expected %s to stay open in gopls", kept)
		}
	}

	for i, p := range allPaths {
		want := fmt.Sprintf("package w\nconst V%02d = %d\n", i+1, i+1)
		got, ok := OpenDocumentContent(p)
		if !ok || string(got) != want {
			t.Fatalf("OpenDocumentContent(%s) = (%q, %v), want (%q, true)", p, got, ok, want)
		}
	}
}

func TestMRUNeverEvictsDirtyOrVisibleUntilSaved(t *testing.T) {
	freshStore(t)
	docs.maxOpen = 4
	s, w := fakeServer(t, 2)
	docs.attach(s)

	SetVisibleDocuments([]string{"/w/vis1.go", "/w/vis2.go"})
	OpenDocument("/w/vis1.go", []byte("package w\n"))
	w.next()
	OpenDocument("/w/vis2.go", []byte("package w\n"))
	w.next()

	OpenDocument("/w/dirty1.go", []byte("package w\n"))
	w.next()
	if st := ChangeDocument("/w/dirty1.go", 10, 10, []byte("// edit\n"), 10); st != ChangeApplied {
		t.Fatalf("ChangeDocument status %v", st)
	}
	w.next()
	s.c.openGate()

	OpenDocument("/w/dirty2.go", []byte("package w\n"))
	w.next()
	if st := ReplaceDocument("/w/dirty2.go", []byte("package w\n// replaced\n")); st != ChangeApplied {
		t.Fatalf("ReplaceDocument status %v", st)
	}
	w.next()
	s.c.openGate()

	OpenDocument("/w/dirty3.go", []byte("package w\n"))
	w.next()
	if st := ReplaceDocument("/w/dirty3.go", []byte("package w\n// replaced 3\n")); st != ChangeApplied {
		t.Fatalf("ReplaceDocument status %v", st)
	}
	w.next()
	s.c.openGate()
	w.none()

	if n := len(sentPaths()); n != 5 {
		t.Fatalf("expected all 5 dirty/visible docs to remain open above cap=4, got %d (%v)", n, sentPaths())
	}

	MarkDocumentSaved("/w/dirty1.go")
	m := w.next()
	if m["method"] != "textDocument/didClose" || msgURI(m) != pathToURI("/w/dirty1.go") {
		t.Fatalf("expected didClose for newly saved /w/dirty1.go to return to cap=4, got %v", m)
	}
	w.none()
	if n := len(sentPaths()); n != 4 {
		t.Fatalf("expected 4 sent docs after MarkDocumentSaved, got %d (%v)", n, sentPaths())
	}

	tmpDir := t.TempDir()
	diskDoc := filepath.Join(tmpDir, "saved_via_sync.go")
	diskBody := []byte("package w\n// synced\n")
	if err := os.WriteFile(diskDoc, diskBody, 0644); err != nil {
		t.Fatal(err)
	}
	OpenDocument(diskDoc, []byte("package w\n"))
	// Opening diskDoc when all 4 others are dirty/visible keeps all 5 open because open keeps the newly opened doc.
	w.next()
	if st := ReplaceDocument(diskDoc, diskBody); st != ChangeApplied {
		t.Fatalf("ReplaceDocument diskDoc: %v", st)
	}
	s.c.flushChanges()
	w.next()
	if n := len(sentPaths()); n != 5 {
		t.Fatalf("expected 5 sent docs with diskDoc dirty, got %d", n)
	}
	SyncSavedIfClean(diskDoc)
	m = w.next()
	if m["method"] != "textDocument/didClose" || msgURI(m) != pathToURI(diskDoc) {
		t.Fatalf("expected SyncSavedIfClean to evict %s back to cap=4, got %v", diskDoc, m)
	}
}

func TestMRURehydratesOnSnapshotVisibleAndSwiftMessage(t *testing.T) {
	freshStore(t)
	docs.maxOpen = 3
	s, w := fakeServer(t, 2)
	docs.attach(s)

	for i := 1; i <= 5; i++ {
		p := fmt.Sprintf("/w/f%d.go", i)
		OpenDocument(p, []byte(fmt.Sprintf("package w\n// f%d\n", i)))
	}
	// Drain initial 5 didOpens + 2 didCloses (f1, f2 evicted; f3, f4, f5 sent).
	waitWireCount(t, w, 7)
	w.none()

	if slices.Contains(sentPaths(), "/w/f1.go") || slices.Contains(sentPaths(), "/w/f2.go") {
		t.Fatalf("expected f1 and f2 evicted, got %v", sentPaths())
	}

	// 1. snapshot on evicted f1 re-opens f1 and evicts LRU f3.
	snap, ok := docs.snapshot("/w/f1.go", 0)
	if !ok || snap.uri != pathToURI("/w/f1.go") {
		t.Fatalf("snapshot on evicted f1 failed: ok=%v snap=%+v", ok, snap)
	}
	mOpen := w.next()
	mClose := w.next()
	if mOpen["method"] != "textDocument/didOpen" || msgURI(mOpen) != pathToURI("/w/f1.go") {
		t.Fatalf("expected didOpen for f1, got %v", mOpen)
	}
	if mClose["method"] != "textDocument/didClose" || msgURI(mClose) != pathToURI("/w/f3.go") {
		t.Fatalf("expected didClose for f3, got %v", mClose)
	}
	w.none()

	// 2. SetVisibleDocuments on evicted f2 re-opens f2 and evicts LRU f4.
	SetVisibleDocuments([]string{"/w/f2.go"})
	mOpen = w.next()
	mClose = w.next()
	if mOpen["method"] != "textDocument/didOpen" || msgURI(mOpen) != pathToURI("/w/f2.go") {
		t.Fatalf("expected didOpen for visible f2, got %v", mOpen)
	}
	if mClose["method"] != "textDocument/didClose" || msgURI(mClose) != pathToURI("/w/f4.go") {
		t.Fatalf("expected didClose for f4, got %v", mClose)
	}
	w.none()

	// 3. SendSwiftMessage(textDocument/hover) on evicted f3 re-opens f3 before forwarding hover, evicting f5.
	hoverMsg := fmt.Sprintf(`{"jsonrpc":"2.0","id":4294967300,"method":"textDocument/hover","params":{"textDocument":{"uri":%q},"position":{"line":0,"character":0}}}`, pathToURI("/w/f3.go"))
	if !SendSwiftMessage([]byte(hoverMsg)) {
		t.Fatal("SendSwiftMessage returned false")
	}
	mOpen = w.next()
	mClose = w.next()
	mHover := w.next()
	if mOpen["method"] != "textDocument/didOpen" || msgURI(mOpen) != pathToURI("/w/f3.go") {
		t.Fatalf("expected didOpen for f3 before hover, got %v", mOpen)
	}
	if mClose["method"] != "textDocument/didClose" || msgURI(mClose) != pathToURI("/w/f5.go") {
		t.Fatalf("expected didClose for f5, got %v", mClose)
	}
	if mHover["method"] != "textDocument/hover" {
		t.Fatalf("expected textDocument/hover after rehydration, got %v", mHover)
	}
	_ = drainWire(w)
}

func TestAttachAfterRestartReplaysUpToCapPrioritizingVisibleDirtyAndMRU(t *testing.T) {
	freshStore(t)
	t.Setenv("GOLENS_MAX_GOPLS_OPEN_DOCS", "4")

	for i := 1; i <= 8; i++ {
		p := fmt.Sprintf("/w/r%d.go", i)
		OpenDocument(p, []byte(fmt.Sprintf("package w\n// r%d\n", i)))
	}
	// Make r1 visible and r2 dirty; MRU clean docs are r8, r7, r6, ...
	SetVisibleDocuments([]string{"/w/r1.go"})
	r2Init := "package w\n// r2\n"
	if st := ChangeDocument("/w/r2.go", len(r2Init), len(r2Init), []byte("// dirty\n"), len(r2Init)); st != ChangeApplied {
		t.Fatalf("ChangeDocument r2: %v", st)
	}

	s, w := fakeServer(t, 2)
	docs.attach(s)

	msgs := waitWireCount(t, w, 4)
	w.none()

	var opened []string
	for _, m := range msgs {
		if m["method"] != "textDocument/didOpen" {
			t.Fatalf("expected didOpen during attach, got %v", m)
		}
		opened = append(opened, uriToPath(msgURI(m)))
	}
	slices.Sort(opened)
	want := []string{"/w/r1.go", "/w/r2.go", "/w/r7.go", "/w/r8.go"}
	if !slices.Equal(opened, want) {
		t.Fatalf("attach opened %v, want %v", opened, want)
	}
	if !slices.Equal(sentPaths(), want) {
		t.Fatalf("sentPaths = %v, want %v", sentPaths(), want)
	}
	// Evicted older clean docs remain in docStore for overlay reads.
	for i := 3; i <= 6; i++ {
		p := fmt.Sprintf("/w/r%d.go", i)
		if _, ok := OpenDocumentContent(p); !ok {
			t.Fatalf("expected %s to remain in docStore after attach", p)
		}
	}
}
