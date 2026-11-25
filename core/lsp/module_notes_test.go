package lsp

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const notesGoMod = `module example.com/app

go 1.22

require github.com/old/lib v1.0.0 // indirect

require (
	github.com/fine/lib v1.2.0
	github.com/bad/lib v0.3.1
)
`

const notesStream = `{"Path":"example.com/app","Main":true}
{"Path":"github.com/old/lib","Version":"v1.0.0","Deprecated":"use github.com/new/lib"}
{"Path":"github.com/fine/lib","Version":"v1.2.0","Update":{"Version":"v1.3.0"}}
{"Path":"github.com/bad/lib","Version":"v0.3.1","Retracted":["data race in Close"]}
{"Path":"golang.org/x/text","Version":"v0.3.0","Deprecated":"not required directly"}
`

func TestParseModuleNotesMapsRequireLines(t *testing.T) {
	notes := parseModuleNotes([]byte(notesStream), []byte(notesGoMod))
	if len(notes) != 2 {
		t.Fatalf("notes %+v", notes)
	}
	if notes[0].Path != "github.com/old/lib" || notes[0].Line != 5 || notes[0].Deprecated == "" {
		t.Fatalf("deprecated note %+v", notes[0])
	}
	if notes[1].Path != "github.com/bad/lib" || notes[1].Line != 9 || len(notes[1].Retracted) != 1 {
		t.Fatalf("retracted note %+v", notes[1])
	}
}

func TestModuleNotesCachesAndDegradesOffline(t *testing.T) {
	dir := t.TempDir()
	gomod := filepath.Join(dir, "go.mod")
	_ = os.WriteFile(gomod, []byte(notesGoMod), 0o644)
	calls := 0
	old := runGoListUpdates
	t.Cleanup(func() { runGoListUpdates = old })
	runGoListUpdates = func(string) ([]byte, error) {
		calls++
		return []byte(notesStream), nil
	}
	first := ModuleNotes(gomod)
	if ModuleNotes(gomod) != first || calls != 1 {
		t.Fatalf("not cached: calls=%d", calls)
	}
	if !strings.Contains(first, "data race in Close") {
		t.Fatalf("payload %s", first)
	}
	other := filepath.Join(t.TempDir(), "go.mod")
	_ = os.WriteFile(other, []byte(notesGoMod), 0o644)
	oldTTL := moduleNotesErrorTTL
	moduleNotesErrorTTL = 0
	t.Cleanup(func() { moduleNotesErrorTTL = oldTTL })
	runGoListUpdates = func(string) ([]byte, error) { return nil, errors.New("dial tcp: no route to host") }
	if got := ModuleNotes(other); !strings.Contains(got, `"error":"dial tcp`) || !strings.Contains(got, `"notes":[]`) {
		t.Fatalf("offline payload %s", got)
	}
	runGoListUpdates = func(string) ([]byte, error) {
		return []byte(`{"Path":"example.com/x","Version":"v1.0.0","Error":{"Err":"dial tcp 127.0.0.1:9: connect: connection refused"}}`), nil
	}
	if got := ModuleNotes(other); !strings.Contains(got, `"error":"dial tcp 127.0.0.1:9`) {
		t.Fatalf("module error payload %s", got)
	}
	runGoListUpdates = func(string) ([]byte, error) { return []byte(notesStream), errors.New("dial tcp: connection refused") }
	if got := ModuleNotes(other); !strings.Contains(got, `"error":"dial tcp`) || !strings.Contains(got, "data race in Close") {
		t.Fatalf("partial offline payload %s", got)
	}
	if got := ModuleNotes(filepath.Join(dir, "missing", "go.mod")); !strings.Contains(got, "not found") {
		t.Fatalf("missing payload %s", got)
	}
}

func TestModuleNotesCachesErrorsBrieflyAndCoalescesCalls(t *testing.T) {
	gomod := filepath.Join(t.TempDir(), "go.mod")
	_ = os.WriteFile(gomod, []byte(notesGoMod), 0o644)
	var calls atomic.Int32
	release := make(chan struct{})
	old := runGoListUpdates
	t.Cleanup(func() { runGoListUpdates = old })
	runGoListUpdates = func(string) ([]byte, error) {
		calls.Add(1)
		<-release
		return nil, errors.New("dial tcp: no route to host")
	}
	var wg sync.WaitGroup
	results := make([]string, 6)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = ModuleNotes(gomod)
		}(i)
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if n := calls.Load(); n != 1 {
		t.Fatalf("overlapping calls spawned %d listings", n)
	}
	for _, r := range results {
		if !strings.Contains(r, `"error":"dial tcp`) {
			t.Fatalf("payload %s", r)
		}
	}
	if got := ModuleNotes(gomod); !strings.Contains(got, `"error":"dial tcp`) || calls.Load() != 1 {
		t.Fatalf("error result not cached: calls=%d", calls.Load())
	}
	oldTTL := moduleNotesErrorTTL
	moduleNotesErrorTTL = time.Nanosecond
	t.Cleanup(func() { moduleNotesErrorTTL = oldTTL })
	moduleNotesCache.Lock()
	e := moduleNotesCache.entries[gomod]
	e.expires = time.Now().Add(-time.Second)
	moduleNotesCache.entries[gomod] = e
	moduleNotesCache.Unlock()
	ModuleNotes(gomod)
	if n := calls.Load(); n != 2 {
		t.Fatalf("expired error result was not retried: calls=%d", n)
	}
}
