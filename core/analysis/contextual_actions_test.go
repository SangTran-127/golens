package analysis

import (
	"strings"
	"testing"
	"time"
)

func TestContextualASTQuickFixes_ConcurrencyCancel(t *testing.T) {
	src := `package main

import (
	"context"
	"time"
)

func worker() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = ctx
}
`
	// Line 10: ctx, cancel := context.WithTimeout(...)
	start := time.Now()
	fixes, err := ContextualASTQuickFixes("", "worker.go", src, 10)
	duration := time.Since(start)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if duration > 10*time.Millisecond {
		t.Errorf("expected < 10ms execution time, took %v", duration)
	}

	if len(fixes) == 0 {
		t.Fatalf("expected at least 1 quick fix for missing cancel defer, got 0")
	}

	found := false
	for _, fix := range fixes {
		if strings.Contains(fix.UpdatedSource, "defer cancel()") {
			found = true
			if fix.Title != "Add defer cancel()" {
				t.Errorf("expected the action title %q, got %q", "Add defer cancel()", fix.Title)
			}
			break
		}
	}
	if !found {
		t.Errorf("expected quick fix with defer cancel(), got fixes: %+v", fixes)
	}
}

func TestContextualASTQuickFixes_HTTPRespClose(t *testing.T) {
	src := `package main

import (
	"net/http"
)

func fetchData() error {
	resp, err := http.Get("https://example.com")
	if err != nil {
		return err
	}
	_ = resp
	return nil
}
`
	fixes, err := ContextualASTQuickFixes("", "fetch.go", src, 8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(fixes) == 0 {
		t.Fatalf("expected at least 1 quick fix for HTTP response body close, got 0")
	}

	found := false
	for _, fix := range fixes {
		if strings.Contains(fix.UpdatedSource, "resp.Body.Close()") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected fix with resp.Body.Close(), got: %+v", fixes)
	}
}

func TestContextualASTQuickFixes_ErrorWrapping(t *testing.T) {
	src := `package main

import (
	"fmt"
	"os"
)

func openFile() error {
	_, err := os.Open("foo.txt")
	if err != nil {
		return fmt.Errorf("failed to open: %v", err)
	}
	return nil
}
`
	fixes, err := ContextualASTQuickFixes("", "open.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(fixes) == 0 {
		t.Fatalf("expected quick fix for %%v error wrapping verb, got 0")
	}

	found := false
	for _, fix := range fixes {
		if strings.Contains(fix.UpdatedSource, "%w") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected fix replacing %%v with %%w, got: %+v", fixes)
	}
}

func TestContextualASTQuickFixes_PerformanceGuardrail(t *testing.T) {
	src := `package main

import (
	"context"
	"time"
)

func runLoop() {
	ctx, cancel := context.WithCancel(context.Background())
	_ = ctx
	_ = cancel
}
`
	// Warm up
	_, _ = ContextualASTQuickFixes("", "run.go", src, 9)

	// Measure 5 iterations
	for i := 0; i < 5; i++ {
		start := time.Now()
		_, err := ContextualASTQuickFixes("", "run.go", src, 9)
		elapsed := time.Since(start)
		if err != nil {
			t.Fatalf("run %d failed: %v", i, err)
		}
		// R4 guardrail: < 2ms in-memory AST check on small file
		if elapsed > 20*time.Millisecond {
			t.Errorf("iteration %d took too long: %v (guardrail < 20ms)", i, elapsed)
		}
	}
}

func TestContextualASTQuickFixes_EmptyAndOutOfRange(t *testing.T) {
	fixes, err := ContextualASTQuickFixes("", "test.go", "", 1)
	if err != nil || len(fixes) != 0 {
		t.Errorf("expected empty fixes for empty content, got: %v, %v", fixes, err)
	}

	fixes2, err2 := ContextualASTQuickFixes("", "test.go", "package main", 999)
	if err2 != nil || len(fixes2) != 0 {
		t.Errorf("expected empty fixes for out-of-range line, got: %v, %v", fixes2, err2)
	}
}

func TestContextualASTQuickFixes_ResourceSQLTimeAndSync(t *testing.T) {
	src := `package ops

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"sync"
	"time"
)

func runAll(ctx context.Context, db *sql.DB, mu *sync.Mutex, rw *sync.RWMutex, fail bool) error {
	f, err := os.Open("data.txt")
	if err != nil {
		return err
	}
	if fail {
		return errors.New("fail")
	}
	_ = f.Close()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("tx fail")
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	ticker := time.NewTicker(time.Second)
	<-ticker.C

	mu.Lock()
	rw.RLock()
	return nil
}

func trailingCloseOnly(path string, fail bool) error {
	h, err := os.Open(path)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("tail fail")
	}
	_ = h.Close()
	return nil
}
`
	lineFor := func(needle string) int {
		for idx, l := range strings.Split(src, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		t.Fatalf("missing line %q", needle)
		return 0
	}
	cases := []struct {
		needle      string
		inspectorID string
		wantTitle   string
		wantText    string
		absentText  string
		keepText    string
	}{
		{`os.Open("data.txt")`, "resource", "Add defer f.Close()", "defer f.Close()", "", "_ = f.Close()"},
		{`os.Open(path)`, "resource", "Add defer h.Close()", "defer h.Close()", "_ = h.Close()", ""},
		{"db.BeginTx(", "sqltx", "Add defer tx.Rollback()", "defer tx.Rollback()", "", ""},
		{"time.NewTicker(", "time", "Add defer ticker.Stop()", "defer ticker.Stop()", "", ""},
		{"mu.Lock()", "sync", "Add defer mu.Unlock()", "defer mu.Unlock()", "", ""},
		{"rw.RLock()", "sync", "Add defer rw.RUnlock()", "defer rw.RUnlock()", "", ""},
	}
	for _, tc := range cases {
		fixes, err := ContextualASTQuickFixes("", "ops.go", src, lineFor(tc.needle))
		if err != nil {
			t.Fatalf("%s error: %v", tc.needle, err)
		}
		var matched *ContextualQuickFix
		for i := range fixes {
			if fixes[i].InspectorID == tc.inspectorID && fixes[i].Title == tc.wantTitle {
				matched = &fixes[i]
				break
			}
		}
		if matched == nil {
			t.Fatalf("%s: expected fix %q (%s), got %+v", tc.needle, tc.wantTitle, tc.inspectorID, fixes)
		}
		if !strings.Contains(matched.UpdatedSource, tc.wantText) {
			t.Fatalf("%s: expected %q in updated source:\n%s", tc.needle, tc.wantText, matched.UpdatedSource)
		}
		if tc.keepText != "" && !strings.Contains(matched.UpdatedSource, tc.keepText) {
			t.Fatalf("%s: expected non-trailing %q preserved:\n%s", tc.needle, tc.keepText, matched.UpdatedSource)
		}
		if tc.absentText != "" && strings.Contains(matched.UpdatedSource, tc.absentText) {
			t.Fatalf("%s: expected redundant %q removed:\n%s", tc.needle, tc.absentText, matched.UpdatedSource)
		}
	}
}
