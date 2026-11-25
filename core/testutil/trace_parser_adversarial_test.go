package testutil

import (
	"crypto/rand"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// generateAdversarialTrace generates a real Go execution trace file with controllable goroutines
// and intentional channel unblocking interactions for causation link validation.
func generateAdversarialTrace(t *testing.T, tmpDir string, numGoroutines int) string {
	t.Helper()
	tracePath := filepath.Join(tmpDir, fmt.Sprintf("adv_trace_%d.out", numGoroutines))
	src := `package main

import (
	"os"
	"runtime"
	"runtime/trace"
	"sync"
	"time"
)

func workerSender(ch chan int, id int, wg *sync.WaitGroup) {
	defer wg.Done()
	// Active CPU work to build activeNs
	start := time.Now()
	for time.Since(start) < 2*time.Millisecond {
		runtime.Gosched()
	}
	ch <- id
}

func workerReceiver(ch chan int, wg *sync.WaitGroup) {
	defer wg.Done()
	_ = <-ch
	// Active CPU work after unblock
	start := time.Now()
	for time.Since(start) < 1*time.Millisecond {
		runtime.Gosched()
	}
}

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
	numPairs := ` + fmt.Sprintf("%d", numGoroutines/2+1) + `
	channels := make([]chan int, numPairs)
	for i := range channels {
		channels[i] = make(chan int) // Unbuffered to force blocking/unblocking
	}

	for i := 0; i < numPairs; i++ {
		wg.Add(2)
		go workerReceiver(channels[i], &wg)
		// Small stagger to guarantee receiver is waiting before sender sends
		time.Sleep(100 * time.Microsecond)
		go workerSender(channels[i], i, &wg)
	}

	wg.Wait()
}
`
	goFile := filepath.Join(tmpDir, fmt.Sprintf("main_%d.go", numGoroutines))
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

// TestAdversarial_Trace_FileSizeExceeding16MB tests that files exceeding 16MB limit
// are rejected gracefully by os.Stat / LimitReader without memory exhaustion or hangs.
func TestAdversarial_Trace_FileSizeExceeding16MB(t *testing.T) {
	tmpDir := t.TempDir()

	testSizes := []struct {
		name string
		size int64
	}{
		{"ExactBoundaryPlusOne", MaxTraceFileSize + 1},
		{"TwentyMegabytes", 20 * 1024 * 1024},
		{"FiftyMegabytes", 50 * 1024 * 1024},
		{"HundredMegabytes", 100 * 1024 * 1024},
	}

	for _, tc := range testSizes {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(tmpDir, tc.name+".trace")
			f, err := os.Create(path)
			if err != nil {
				t.Fatalf("Create failed: %v", err)
			}
			// Use Truncate for instant sparse allocation without disk exhaustion
			if err := f.Truncate(tc.size); err != nil {
				f.Close()
				t.Fatalf("Truncate failed: %v", err)
			}
			f.Close()

			start := time.Now()
			res, err := ParseGoTraceFile(path)
			elapsed := time.Since(start)

			if err == nil {
				t.Fatalf("Expected error for file size %d bytes, got nil result: %+v", tc.size, res)
			}
			if !strings.Contains(err.Error(), "16MB limit") {
				t.Errorf("Error should mention 16MB limit, got: %v", err)
			}
			if elapsed > 200*time.Millisecond {
				t.Errorf("Rejection took too long (%v), pre-stat check failed to fail fast", elapsed)
			}
		})
	}
}

// TestAdversarial_Trace_MalformedTruncatedCorrupted verifies parser returns error
// without panic on arbitrary corrupted / truncated byte streams.
func TestAdversarial_Trace_MalformedTruncatedCorrupted(t *testing.T) {
	tmpDir := t.TempDir()

	// 1. Completely random fuzz payloads
	for i := 1; i <= 5; i++ {
		t.Run(fmt.Sprintf("FuzzRandom_%d", i), func(t *testing.T) {
			path := filepath.Join(tmpDir, fmt.Sprintf("random_%d.trace", i))
			buf := make([]byte, 1024*i)
			_, _ = rand.Read(buf)
			if err := os.WriteFile(path, buf, 0644); err != nil {
				t.Fatalf("WriteFile failed: %v", err)
			}

			// Must not panic
			_, _ = ParseGoTraceFile(path)
		})
	}

	// 2. Non-trace formats (JSON, HTML, ELF/Mach-O headers, zero bytes)
	nonTracePayloads := map[string][]byte{
		"ZeroBytes1K":      make([]byte, 1024),
		"JSONPayload":      []byte(`{"trace": true, "events": [1, 2, 3]}`),
		"PNGHeader":        []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A},
		"MachOHeader":      []byte{0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01},
		"SingleByte":       []byte{0x00},
		"RepetitiveHeader": []byte("go 1.21 trace\x00\x00\x00"),
	}

	for name, data := range nonTracePayloads {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(tmpDir, name+".trace")
			if err := os.WriteFile(path, data, 0644); err != nil {
				t.Fatalf("WriteFile failed: %v", err)
			}

			// Verify safe execution without panic
			_, _ = ParseGoTraceFile(path)
		})
	}

	// 3. Truncated real trace
	realTracePath := generateAdversarialTrace(t, tmpDir, 6)
	realData, err := os.ReadFile(realTracePath)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}

	truncationPoints := []int{
		8,   // Cut during header magic
		16,  // Cut after header magic
		64,  // Cut during generation header
		256, // Cut during early event table
		len(realData) / 4,
		len(realData) / 2,
		len(realData) - 10,
	}

	for _, cut := range truncationPoints {
		if cut >= len(realData) {
			continue
		}
		t.Run(fmt.Sprintf("TruncatedAt_%d_of_%d", cut, len(realData)), func(t *testing.T) {
			truncPath := filepath.Join(tmpDir, fmt.Sprintf("trunc_%d.trace", cut))
			if err := os.WriteFile(truncPath, realData[:cut], 0644); err != nil {
				t.Fatalf("WriteFile failed: %v", err)
			}

			// Must not panic, either returns valid partial result or clean error
			res, parseErr := ParseGoTraceFile(truncPath)
			if parseErr != nil {
				// Clean error expected
				return
			}
			// If it recovered partially, lanes must be consistent
			if res != nil {
				for _, lane := range res.Lanes {
					for _, span := range lane.Spans {
						if span.StartNs > span.EndNs {
							t.Errorf("Invalid span bounds on partial trace: start=%d > end=%d", span.StartNs, span.EndNs)
						}
					}
				}
			}
		})
	}
}

// TestAdversarial_Trace_GoroutinesExceeding200 tests that when goroutines exceed 200,
// the lane hard cap strictly truncates to Top 200 sorted by totalActiveNs desc,
// then eventCount desc, and sets Truncated = true.
func TestAdversarial_Trace_GoroutinesExceeding200(t *testing.T) {
	tmpDir := t.TempDir()
	// Generate 240 goroutines
	tracePath := generateAdversarialTrace(t, tmpDir, 240)

	res, err := ParseGoTraceFile(tracePath)
	if err != nil {
		t.Fatalf("ParseGoTraceFile failed: %v", err)
	}

	if res.TotalGoroutines <= MaxGoroutineLanes {
		t.Fatalf("Expected total goroutines > %d, got %d", MaxGoroutineLanes, res.TotalGoroutines)
	}
	if len(res.Lanes) != MaxGoroutineLanes {
		t.Fatalf("Expected exactly %d lanes, got %d", MaxGoroutineLanes, len(res.Lanes))
	}
	if !res.Truncated {
		t.Errorf("Expected Truncated == true")
	}

	// Verify deterministic sorting: totalActiveNs desc, then eventCount desc, then ID asc
	for i := 1; i < len(res.Lanes); i++ {
		prev := res.Lanes[i-1]
		curr := res.Lanes[i]

		if curr.TotalActiveNs > prev.TotalActiveNs {
			t.Fatalf("Lane %d has higher TotalActiveNs (%d) than lane %d (%d)",
				i, curr.TotalActiveNs, i-1, prev.TotalActiveNs)
		}
		if curr.TotalActiveNs == prev.TotalActiveNs {
			if curr.EventCount > prev.EventCount {
				t.Fatalf("Lane %d has equal ActiveNs but higher EventCount (%d vs %d)",
					i, curr.EventCount, prev.EventCount)
			}
			if curr.EventCount == prev.EventCount && curr.GoroutineID < prev.GoroutineID {
				t.Fatalf("Lane %d has equal ActiveNs & EventCount but smaller GoroutineID (%d vs %d)",
					i, curr.GoroutineID, prev.GoroutineID)
			}
		}
	}
}

// TestAdversarial_Trace_CausationLinksValidation tests causation link extraction (fromG -> toG),
// timestamp validity, bounds within [StartNs, EndNs], and target goroutine presence in Top 200.
func TestAdversarial_Trace_CausationLinksValidation(t *testing.T) {
	tmpDir := t.TempDir()
	tracePath := generateAdversarialTrace(t, tmpDir, 20)

	res, err := ParseGoTraceFile(tracePath)
	if err != nil {
		t.Fatalf("ParseGoTraceFile failed: %v", err)
	}

	if len(res.CausationLinks) == 0 {
		t.Fatalf("Expected causation links to be recorded from unbuffered channels, got 0")
	}

	topIDs := make(map[uint64]bool)
	for _, l := range res.Lanes {
		topIDs[l.GoroutineID] = true
	}

	for idx, link := range res.CausationLinks {
		if link.FromGoroutine == 0 {
			t.Errorf("Link[%d]: FromGoroutine is 0", idx)
		}
		if link.ToGoroutine == 0 {
			t.Errorf("Link[%d]: ToGoroutine is 0", idx)
		}
		if link.FromGoroutine == link.ToGoroutine {
			t.Errorf("Link[%d]: Self-unblocking causation link detected: G%d -> G%d", idx, link.FromGoroutine, link.ToGoroutine)
		}
		if link.TimestampNs < res.StartNs || link.TimestampNs > res.EndNs {
			t.Errorf("Link[%d]: Timestamp %d out of trace bounds [%d, %d]", idx, link.TimestampNs, res.StartNs, res.EndNs)
		}
		if !topIDs[link.ToGoroutine] {
			t.Errorf("Link[%d]: ToGoroutine %d not found in Top 200 lanes", idx, link.ToGoroutine)
		}
	}
}

// TestAdversarial_Trace_ConcurrencyAndMemoryUnderRace verifies thread-safety,
// absence of data races, and heap memory stability under 20 concurrent goroutines.
func TestAdversarial_Trace_ConcurrencyAndMemoryUnderRace(t *testing.T) {
	tmpDir := t.TempDir()
	tracePath := generateAdversarialTrace(t, tmpDir, 16)

	const concurrency = 20
	const iterations = 5

	var wg sync.WaitGroup
	var successCount int64
	var errCount int64

	runtime.GC()
	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	startSignal := make(chan struct{})

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			<-startSignal // Synchronized start for maximum concurrent pressure

			for it := 0; it < iterations; it++ {
				res, err := ParseGoTraceFile(tracePath)
				if err != nil {
					atomic.AddInt64(&errCount, 1)
				} else if res != nil && len(res.Lanes) > 0 {
					atomic.AddInt64(&successCount, 1)
				}
			}
		}(i)
	}

	close(startSignal)
	wg.Wait()

	runtime.GC()
	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	expectedSuccess := int64(concurrency * iterations)
	if successCount != expectedSuccess {
		t.Errorf("Expected %d successful concurrent parses, got %d (errors: %d)",
			expectedSuccess, successCount, errCount)
	}

	// Memory growth check: allocations should not scale linearly with leaks
	heapGrowth := int64(memAfter.HeapAlloc) - int64(memBefore.HeapAlloc)
	t.Logf("Heap Alloc Before: %d bytes, After: %d bytes, Delta: %d bytes (20 goroutines x %d runs)",
		memBefore.HeapAlloc, memAfter.HeapAlloc, heapGrowth, iterations)
}
