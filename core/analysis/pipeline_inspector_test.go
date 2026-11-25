package analysis

import (
	"strings"
	"testing"
)

func TestInspectPipelineSafetyDetectsAllCategories(t *testing.T) {
	src := `package sample

import "context"

func runPipeline(ctx context.Context, out chan<- int) {
	jobs := make(chan int, 2)
	jobs <- 1
	for i := 0; i < 2; i++ {
		go func() {
			close(out)
		}()
	}
	out <- 42
	for v := range jobs {
		_ = v
	}
}
`
	report, err := InspectPipelineSafety(src, "pipeline.go")
	if err != nil {
		t.Fatalf("InspectPipelineSafety failed: %v", err)
	}
	if report.TotalCount < 3 {
		t.Fatalf("expected at least 3 pipeline issues, got %d", report.TotalCount)
	}

	cats := map[string]bool{}
	for _, issue := range report.Issues {
		cats[issue.Category] = true
	}
	for _, want := range []string{
		"close-channel-from-receiver-or-multiple-workers",
		"pipeline-send-without-context-select",
		"range-over-unclosed-channel",
	} {
		if !cats[want] {
			t.Fatalf("missing category %q in %+v", want, report.Issues)
		}
	}
}

func TestApplyPipelineSafetyFixesRewritesAllCategories(t *testing.T) {
	src := `package sample

import "context"

func runPipeline(ctx context.Context, out chan<- int) {
	jobs := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func() {
			close(out)
		}()
	}
	out <- 42
	for v := range jobs {
		_ = v
	}
}
`
	res, err := ApplyPipelineSafetyFixes(src, "pipeline.go", nil)
	if err != nil {
		t.Fatalf("ApplyPipelineSafetyFixes failed: %v", err)
	}
	if res.AppliedCount < 3 {
		t.Fatalf("expected at least 3 applied fixes, got %d", res.AppliedCount)
	}
	if !strings.Contains(res.ModifiedSource, "case <-ctx.Done():") {
		t.Fatalf("expected select with ctx.Done(), got:\n%s", res.ModifiedSource)
	}
	if !strings.Contains(res.ModifiedSource, "close(jobs)") {
		t.Fatalf("expected close(jobs) before range loop, got:\n%s", res.ModifiedSource)
	}
}
