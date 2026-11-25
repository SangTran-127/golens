package analysis

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestInspectFileConcurrency_AllRules(t *testing.T) {
	src := `package sample

import (
	"context"
	"time"
)

func fetchOrder(ctx context.Context, id string) {
	childCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = childCtx
	_ = cancel

	go func() {
		process(id)
	}()
}

func process(id string) {}
`

	raw, err := InspectFileConcurrency("/tmp/sample.go", src)
	if err != nil {
		t.Fatalf("InspectFileConcurrency returned error: %v", err)
	}

	var report ConcurrencyReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("failed to unmarshal ConcurrencyReport: %v", err)
	}

	if report.FilePath != "/tmp/sample.go" {
		t.Errorf("expected filePath /tmp/sample.go, got %q", report.FilePath)
	}
	if report.GoroutineCount != 1 {
		t.Errorf("expected goroutineCount 1, got %d", report.GoroutineCount)
	}
	if report.ContextCallCount != 2 {
		t.Errorf("expected contextCallCount 2, got %d", report.ContextCallCount)
	}
	if len(report.Findings) != 3 {
		t.Fatalf("expected 3 findings, got %d: %+v", len(report.Findings), report.Findings)
	}

	byKind := make(map[string]ConcurrencyFinding)
	for _, f := range report.Findings {
		byKind[f.Kind] = f
	}

	missingCancel, ok := byKind["missing_cancel_defer"]
	if !ok {
		t.Fatalf("missing 'missing_cancel_defer' finding")
	}
	if !missingCancel.CanAutoFix || missingCancel.Line != 9 || missingCancel.FunctionName != "fetchOrder" {
		t.Errorf("unexpected missing_cancel_defer finding: %+v", missingCancel)
	}

	bgInFunc, ok := byKind["context_background_in_func"]
	if !ok {
		t.Fatalf("missing 'context_background_in_func' finding")
	}
	if !bgInFunc.CanAutoFix || bgInFunc.Line != 9 || bgInFunc.FunctionName != "fetchOrder" {
		t.Errorf("unexpected context_background_in_func finding: %+v", bgInFunc)
	}

	unbounded, ok := byKind["unbounded_goroutine"]
	if !ok {
		t.Fatalf("missing 'unbounded_goroutine' finding")
	}
	if unbounded.Line != 13 || unbounded.FunctionName != "fetchOrder" {
		t.Errorf("unexpected unbounded_goroutine finding: %+v", unbounded)
	}
	if !strings.Contains(unbounded.Summary, "Goroutine launched without an explicit cancellation or WaitGroup lifecycle check in this block") {
		t.Errorf("unexpected unbounded_goroutine summary: %q", unbounded.Summary)
	}
}

func TestInspectFileConcurrency_CleanCode(t *testing.T) {
	src := `package sample

import (
	"context"
	"time"
)

func main() {
	root := context.Background()
	ctx, cancel := context.WithCancel(root)
	defer cancel()

	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}()
}
`

	raw, err := InspectFileConcurrency("main.go", src)
	if err != nil {
		t.Fatalf("InspectFileConcurrency returned error: %v", err)
	}

	var report ConcurrencyReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}

	if report.GoroutineCount != 1 {
		t.Errorf("expected 1 goroutine, got %d", report.GoroutineCount)
	}
	if report.ContextCallCount != 2 {
		t.Errorf("expected 2 context calls, got %d", report.ContextCallCount)
	}
	if len(report.Findings) != 0 {
		t.Errorf("expected 0 findings for clean code, got %+v", report.Findings)
	}
}

func TestApplyConcurrencyQuickFix_MissingCancelDefer(t *testing.T) {
	src := `package sample

import "context"

func run(parent context.Context) {
	ctx, stop := context.WithCancel(parent)
	_ = ctx
}
`
	raw, err := ApplyConcurrencyQuickFix("sample.go", src, 6, "missing_cancel_defer")
	if err != nil {
		t.Fatalf("ApplyConcurrencyQuickFix failed: %v", err)
	}

	var fix ConcurrencyFixResult
	if err := json.Unmarshal([]byte(raw), &fix); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if fix.Error != "" {
		t.Fatalf("unexpected error in fix result: %s", fix.Error)
	}
	if !strings.Contains(fix.UpdatedSource, "\tctx, stop := context.WithCancel(parent)\n\tdefer stop()") {
		t.Errorf("expected defer stop() on next line with matching indent, got:\n%s", fix.UpdatedSource)
	}

	recheckRaw, err := InspectFileConcurrency("sample.go", fix.UpdatedSource)
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	var report ConcurrencyReport
	_ = json.Unmarshal([]byte(recheckRaw), &report)
	if len(report.Findings) != 0 {
		t.Errorf("expected 0 findings after applying missing_cancel_defer fix, got %+v", report.Findings)
	}
}

func TestApplyConcurrencyQuickFix_ContextBackgroundInFuncWithCtxParam(t *testing.T) {
	src := `package sample

import "context"

func queryDB(reqCtx context.Context) {
	runQuery(context.Background())
}

func runQuery(ctx context.Context) {}
`
	raw, err := ApplyConcurrencyQuickFix("sample.go", src, 6, "context_background_in_func")
	if err != nil {
		t.Fatalf("ApplyConcurrencyQuickFix failed: %v", err)
	}

	var fix ConcurrencyFixResult
	if err := json.Unmarshal([]byte(raw), &fix); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if !strings.Contains(fix.UpdatedSource, "runQuery(reqCtx)") {
		t.Errorf("expected context.Background() replaced with reqCtx, got:\n%s", fix.UpdatedSource)
	}
}

func TestApplyConcurrencyQuickFix_ContextBackgroundInFuncWithoutCtxParam(t *testing.T) {
	src := `package sample

import "context"

func queryDB() {
	runQuery(context.Background())
}

func runQuery(ctx context.Context) {}
`
	raw, err := ApplyConcurrencyQuickFix("sample.go", src, 6, "context_background_in_func")
	if err == nil {
		t.Fatalf("expected no automatic fix without a context parameter, got:\n%s", raw)
	}

	var fix ConcurrencyFixResult
	if err := json.Unmarshal([]byte(raw), &fix); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if fix.UpdatedSource != src {
		t.Errorf("expected the source to stay unchanged, got:\n%s", fix.UpdatedSource)
	}
}

func TestApplyConcurrencyQuickFix_SingleLineFuncDoesNotPlaceDeferOutsideFunc(t *testing.T) {
	src := `package main

import "context"

func main() { ctx, cancel := context.WithCancel(context.Background()); _ = ctx; _ = cancel }
`
	rawInspect, err := InspectFileConcurrency("main.go", src)
	if err != nil {
		t.Fatalf("InspectFileConcurrency failed: %v", err)
	}
	var report ConcurrencyReport
	if err := json.Unmarshal([]byte(rawInspect), &report); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if len(report.Findings) != 1 || report.Findings[0].Kind != "missing_cancel_defer" {
		t.Fatalf("expected 1 missing_cancel_defer finding in single-line main, got %+v", report.Findings)
	}

	rawFix, err := ApplyConcurrencyQuickFix("main.go", src, 5, "missing_cancel_defer")
	if err != nil {
		t.Fatalf("ApplyConcurrencyQuickFix failed: %v", err)
	}
	var fix ConcurrencyFixResult
	if err := json.Unmarshal([]byte(rawFix), &fix); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if fix.Error != "" {
		t.Fatalf("unexpected fix error: %s", fix.Error)
	}
	if !strings.Contains(fix.UpdatedSource, "func main() { ctx, cancel := context.WithCancel(context.Background()); defer cancel(); _ = ctx; _ = cancel }") {
		t.Errorf("expected inline defer cancel() inside single-line main, got:\n%s", fix.UpdatedSource)
	}

	recheckRaw, err := InspectFileConcurrency("main.go", fix.UpdatedSource)
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	var recheck ConcurrencyReport
	_ = json.Unmarshal([]byte(recheckRaw), &recheck)
	if len(recheck.Findings) != 0 {
		t.Errorf("expected 0 findings after single-line fix, got %+v", recheck.Findings)
	}
}
