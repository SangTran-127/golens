package testutil

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func generateTestTrace(t *testing.T, tmpDir string, numGoroutines int) string {
	t.Helper()
	tracePath := filepath.Join(tmpDir, "trace.out")
	src := `package main

import (
	"os"
	"runtime/trace"
	"sync"
	"time"
)

func main() {
	f, err := os.Create("` + tracePath + `")
	if err != nil {
		panic(err)
	}
	defer f.Close()

	if err := trace.Start(f); err != nil {
		panic(err)
	}
	defer trace.Stop()

	var wg sync.WaitGroup
	ch := make(chan int, 1)

	for i := 0; i < ` + fmt.Sprintf("%d", numGoroutines) + `; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			if id%2 == 0 {
				time.Sleep(2 * time.Millisecond)
				select {
				case ch <- id:
				default:
				}
			} else {
				select {
				case <-ch:
				case <-time.After(5 * time.Millisecond):
				}
			}
		}(i)
	}
	wg.Wait()
}
`
	goFile := filepath.Join(tmpDir, "main.go")
	if err := os.WriteFile(goFile, []byte(src), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	cmd := exec.Command("go", "run", goFile)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go run failed: %v, out: %s", err, string(out))
	}
	return tracePath
}

func TestParseGoTraceFile_Basic(t *testing.T) {
	tmpDir := t.TempDir()
	tracePath := generateTestTrace(t, tmpDir, 10)

	res, err := ParseGoTraceFile(tracePath)
	if err != nil {
		t.Fatalf("ParseGoTraceFile failed: %v", err)
	}

	if res.TotalDurationNs <= 0 {
		t.Errorf("expected TotalDurationNs > 0, got %d", res.TotalDurationNs)
	}
	if len(res.Lanes) == 0 {
		t.Errorf("expected at least 1 lane, got 0")
	}
	if res.TotalGoroutines < 10 {
		t.Errorf("expected >= 10 goroutines, got %d", res.TotalGoroutines)
	}

	foundRunning := false
	foundWaiting := false
	for _, lane := range res.Lanes {
		for _, span := range lane.Spans {
			if span.State == "running" {
				foundRunning = true
			}
			if span.State == "waiting" {
				foundWaiting = true
			}
			if span.StartNs > span.EndNs {
				t.Errorf("span start > end: %d > %d", span.StartNs, span.EndNs)
			}
		}
	}
	if !foundRunning {
		t.Errorf("expected to find at least one 'running' span")
	}
	if !foundWaiting {
		t.Errorf("expected to find at least one 'waiting' span")
	}
}

func TestParseGoTraceFile_CausationLinks(t *testing.T) {
	tmpDir := t.TempDir()
	tracePath := generateTestTrace(t, tmpDir, 6)

	res, err := ParseGoTraceFile(tracePath)
	if err != nil {
		t.Fatalf("ParseGoTraceFile failed: %v", err)
	}

	if len(res.CausationLinks) == 0 {
		t.Logf("Notice: no causation links captured for small trace (may occur if channel buffers don't block)")
	} else {
		for _, link := range res.CausationLinks {
			if link.FromGoroutine == 0 || link.ToGoroutine == 0 {
				t.Errorf("invalid causation link endpoints: from=%d, to=%d", link.FromGoroutine, link.ToGoroutine)
			}
			if link.TimestampNs < res.StartNs || link.TimestampNs > res.EndNs {
				t.Errorf("causation link timestamp out of bounds: %d (range [%d, %d])", link.TimestampNs, res.StartNs, res.EndNs)
			}
		}
	}
}

func TestParseGoTraceFile_InvalidBytes(t *testing.T) {
	tmpDir := t.TempDir()
	badFile := filepath.Join(tmpDir, "corrupted.trace")
	if err := os.WriteFile(badFile, []byte("NOT_A_TRACE_FILE_RANDOM_GARBAGE"), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	res, err := ParseGoTraceFile(badFile)
	if err == nil {
		t.Errorf("expected error on invalid trace bytes, got nil result: %+v", res)
	}
}

func TestParseGoTraceFile_EmptyFile(t *testing.T) {
	tmpDir := t.TempDir()
	emptyFile := filepath.Join(tmpDir, "empty.trace")
	if err := os.WriteFile(emptyFile, []byte{}, 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	_, err := ParseGoTraceFile(emptyFile)
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Errorf("expected empty file error, got: %v", err)
	}
}

func TestParseGoTraceFile_Exceeds16MB(t *testing.T) {
	tmpDir := t.TempDir()
	hugeFile := filepath.Join(tmpDir, "huge.trace")
	f, err := os.Create(hugeFile)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	defer f.Close()

	if err := f.Truncate(MaxTraceFileSize + 1024); err != nil {
		t.Fatalf("Truncate failed: %v", err)
	}

	_, err = ParseGoTraceFile(hugeFile)
	if err == nil || !strings.Contains(err.Error(), "16MB") {
		t.Errorf("expected 16MB limit error, got: %v", err)
	}
}

func TestParseGoTraceFile_Top200Cap(t *testing.T) {
	tmpDir := t.TempDir()
	tracePath := generateTestTrace(t, tmpDir, 250)

	res, err := ParseGoTraceFile(tracePath)
	if err != nil {
		t.Fatalf("ParseGoTraceFile failed: %v", err)
	}

	if res.TotalGoroutines < 250 {
		t.Errorf("expected >= 250 total goroutines, got %d", res.TotalGoroutines)
	}
	if len(res.Lanes) != MaxGoroutineLanes {
		t.Errorf("expected exactly %d lanes, got %d", MaxGoroutineLanes, len(res.Lanes))
	}
	if !res.Truncated {
		t.Errorf("expected Truncated == true for 250 goroutines")
	}

	// Verify lanes are sorted descending by TotalActiveNs
	for i := 1; i < len(res.Lanes); i++ {
		if res.Lanes[i].TotalActiveNs > res.Lanes[i-1].TotalActiveNs {
			t.Errorf("lanes not sorted descending: lane[%d]=%d > lane[%d]=%d",
				i, res.Lanes[i].TotalActiveNs, i-1, res.Lanes[i-1].TotalActiveNs)
		}
	}
}
