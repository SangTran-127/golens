package guestres

import (
	"errors"
	"strings"
	"testing"
)

func TestParseMemoryEventsAndOOMDetection(t *testing.T) {
	raw := []byte("low 0\nhigh 2\nmax 5\noom 1\noom_kill 1\noom_group_kill 0\n")
	ev := ParseMemoryEvents(raw)
	if !ev.OOMKilled() {
		t.Fatal("expected OOMKilled() == true")
	}
	if ev.High != 2 || ev.Max != 5 || ev.OOM != 1 || ev.OOMKill != 1 {
		t.Fatalf("unexpected parsed events: %+v", ev)
	}
	sum := ev.Summary()
	for _, want := range []string{"oom_kill=1", "oom=1", "max=5", "high=2"} {
		if !strings.Contains(sum, want) {
			t.Fatalf("Summary() = %q, missing %q", sum, want)
		}
	}
}

func TestFormatDiagnosticsNeverSilentOnZeroStderr(t *testing.T) {
	cgDiag := FormatCgroupSetupDiagnostic("go", errors.New("memory.max=1024: invalid argument"))
	if !strings.Contains(cgDiag, "failed to prepare cgroup") || !strings.Contains(cgDiag, "memory.max=1024") || !strings.HasSuffix(cgDiag, "\n") {
		t.Fatalf("unexpected cgroup setup diagnostic: %q", cgDiag)
	}

	pipeDiag := FormatPipeDiagnostic("go", "stderr", errors.New("too many open files"))
	if !strings.Contains(pipeDiag, "stderr pipe") || !strings.Contains(pipeDiag, "too many open files") {
		t.Fatalf("unexpected pipe diagnostic: %q", pipeDiag)
	}

	evFork := ParseMemoryEvents([]byte("max 3\noom 1\noom_kill 0\n"))
	startDiag := FormatStartDiagnostic("nonexistent-bin", errors.New("executable file not found"), evFork, 64<<20)
	if !strings.Contains(startDiag, "nonexistent-bin") || !strings.Contains(startDiag, "executable file not found") || !strings.Contains(startDiag, "memory.max=67108864") {
		t.Fatalf("unexpected start diagnostic: %q", startDiag)
	}

	evOOM := ParseMemoryEvents([]byte("max 9\noom 2\noom_kill 1\n"))
	oomDiag := FormatWaitDiagnostic("go", errors.New("signal: killed"), 0, evOOM, 128<<20)
	if !strings.Contains(oomDiag, "OOM killer") || !strings.Contains(oomDiag, "oom_kill=1") || !strings.Contains(oomDiag, "signal: killed") {
		t.Fatalf("unexpected OOM wait diagnostic: %q", oomDiag)
	}

	exitDiag := FormatWaitDiagnostic("go", errors.New("exit status 1"), 0, MemoryEvents{}, 0)
	if !strings.Contains(exitDiag, "exited without stderr: exit status 1") {
		t.Fatalf("unexpected silent exit diagnostic: %q", exitDiag)
	}

	// Non-empty child stderr must not be overwritten or duplicated.
	if got := FormatWaitDiagnostic("go", errors.New("exit status 1"), 42, evOOM, 128<<20); got != "" {
		t.Fatalf("expected empty diagnostic when child already wrote stderr, got %q", got)
	}
	if got := FormatWaitDiagnostic("go", nil, 0, MemoryEvents{}, 0); got != "" {
		t.Fatalf("expected empty diagnostic on clean exit 0, got %q", got)
	}
}
