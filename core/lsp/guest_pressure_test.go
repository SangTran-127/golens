package lsp

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/cmd/golens-vm-agent/guestres"
)

type syncBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func TestPressureTrackerHysteresis(t *testing.T) {
	var states []bool
	var reports []string
	p := &pressureTracker{set: func(on bool) { states = append(states, on) }, report: func(s string) { reports = append(reports, s) }}
	limit := int64(100 << 20)
	feed := func(used int64) {
		_, _ = p.Write([]byte("zram " + strconv.FormatInt(used, 10) + " " + strconv.FormatInt(limit, 10) + "\n"))
	}
	feed(50 << 20)
	feed(84 << 20)
	if len(states) != 0 {
		t.Fatalf("paused below the threshold: %v", states)
	}
	feed(86 << 20)
	feed(90 << 20)
	feed(75 << 20)
	if len(states) != 1 || !states[0] {
		t.Fatalf("states %v", states)
	}
	feed(69 << 20)
	feed(60 << 20)
	if len(states) != 2 || states[1] {
		t.Fatalf("states %v", states)
	}
	if len(reports) != 2 || !strings.Contains(reports[0], "pausing") || !strings.Contains(reports[1], "resuming") {
		t.Fatalf("reports %v", reports)
	}
}

func TestPressureTrackerIgnoresUnlimitedPoolAndSplitLines(t *testing.T) {
	var states []bool
	p := &pressureTracker{set: func(on bool) { states = append(states, on) }, report: func(string) {}}
	_, _ = p.Write([]byte("zram 900 0\nzram 95"))
	_, _ = p.Write([]byte(" 100\n"))
	if len(states) != 1 || !states[0] {
		t.Fatalf("states %v", states)
	}
}

func TestGuestPressureScriptReportsPool(t *testing.T) {
	dir := t.TempDir()
	stat := filepath.Join(dir, "mm_stat")
	meminfo := filepath.Join(dir, "meminfo")
	vmstat := filepath.Join(dir, "vmstat")
	cg := filepath.Join(dir, "lsp")
	if err := os.WriteFile(stat, []byte("300 120 115 122 130 45 20 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(meminfo, []byte("MemFree:  1000 kB\nMemTotal:        482304 kB\nMemAvailable: 90000 kB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(vmstat, []byte("nr_free_pages 8000\nnr_balloon_pages 393216\nballoon_inflate 393216\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func() string {
		cmd := exec.Command("sh", "-c", guestPressureScript(stat, meminfo, vmstat, cg, "0.05"))
		out := &syncBuffer{}
		cmd.Stdout = out
		cmd.Stderr = out
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(200 * time.Millisecond)
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return out.String()
	}
	if got := run(); !strings.HasPrefix(got, "zram 115 122 482304 393216 0 0\n") {
		t.Fatalf("without the gopls cgroup: output %q", got)
	}
	if err := os.MkdirAll(cg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cg, "memory.current"), []byte("296747008\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cg, "memory.swap.current"), []byte("104857600\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := run(); !strings.HasPrefix(got, "zram 115 122 482304 393216 296747008 104857600\n") {
		t.Fatalf("with the gopls cgroup: output %q", got)
	}
	missing := exec.Command("sh", "-c", guestPressureScript(filepath.Join(dir, "absent"), meminfo, vmstat, cg, "1"))
	err := missing.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != guestReclaimUnsupported {
		t.Fatalf("missing pool: %v", err)
	}
}

func TestPressureTrackerRecordsGuestMemorySamples(t *testing.T) {
	var samples []guestres.MemorySample
	var states []bool
	p := &pressureTracker{
		set:    func(on bool) { states = append(states, on) },
		report: func(string) {},
		sample: func(s guestres.MemorySample) { samples = append(samples, s) },
	}
	_, _ = p.Write([]byte("zram 110000000 122000000 2024116 393216 296747008 104857600\nzram 5 0 1000 0 1 2\nzram 1 2 0 0 0 0\nzram 1 2 x 0 0 0\nzram 10 100\n"))
	if len(samples) != 2 {
		t.Fatalf("samples %+v", samples)
	}
	s := samples[0]
	if s.MemTotal != 2024116<<10-393216*4096 || s.PoolUsed != 110000000 || s.PoolLimit != 122000000 || s.LSPCurrent != 296747008 || s.LSPSwap != 104857600 || s.At.IsZero() {
		t.Fatalf("sample %+v", s)
	}
	if samples[1].PoolLimit != 0 || samples[1].MemTotal != 1000<<10 {
		t.Fatalf("sample with no pool limit %+v", samples[1])
	}
	if len(states) != 2 || !states[0] || states[1] {
		t.Fatalf("pressure states %v", states)
	}
}

func TestGoplsAppliesMemoryLimitLive(t *testing.T) {
	info := func(v string) json.RawMessage {
		inner, _ := json.Marshal(map[string]any{"GoVersion": "go1.27.1", "Path": "golang.org/x/tools/gopls", "Version": v})
		b, _ := json.Marshal(map[string]any{"capabilities": map[string]any{}, "serverInfo": map[string]any{"name": "gopls", "version": string(inner)}})
		return b
	}
	for v, want := range map[string]bool{
		"v0.24.0-golens.2":  true,
		"v0.25.1-golens.10": true,
		"v0.24.0-golens":    false,
		"v0.24.0-golens.1":  false,
		"v0.24.0":           false,
		"(devel)":           false,
	} {
		if got := goplsAppliesMemoryLimitLive(info(v)); got != want {
			t.Errorf("%s: live memoryLimit %v, want %v", v, got, want)
		}
	}
	if !goplsAppliesMemoryLimitLive(json.RawMessage(`{"serverInfo":{"version":"v0.24.0-golens.2"}}`)) {
		t.Error("a plain version string was not recognised")
	}
	if goplsAppliesMemoryLimitLive(json.RawMessage(`{}`)) {
		t.Error("a server without serverInfo was treated as live")
	}
}

func TestMemoryLimitMoved(t *testing.T) {
	if !memoryLimitMoved(0, 300<<20) {
		t.Error("an unset limit was not replaced")
	}
	if memoryLimitMoved(377<<20, 380<<20) {
		t.Error("a 3 MiB wobble resent the gopls settings")
	}
	if !memoryLimitMoved(377<<20, 685<<20) || !memoryLimitMoved(685<<20, 377<<20) {
		t.Error("a guest step did not move the gopls memory limit")
	}
}

func TestPressureClearsWhenWatchStops(t *testing.T) {
	guestMemoryPressure.Store(true)
	guestPressureWatch.running = true
	superviseGuestPressure(func() bool { return false }, func() error { return errors.New("boom") }, func(string) {}, time.Millisecond)
	if GuestMemoryPressure() || guestPressureWatch.running {
		t.Fatal("pressure or running flag left set after the watch stopped")
	}
}
