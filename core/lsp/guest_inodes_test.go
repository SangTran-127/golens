package lsp

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeGuestProc struct {
	t      *testing.T
	inodes string
	drop   string
	lines  chan string
	cancel context.CancelFunc
	done   chan error
}

func startFakeGuest(t *testing.T, headroom int, initial string) *fakeGuestProc {
	t.Helper()
	dir := t.TempDir()
	g := &fakeGuestProc{t: t, inodes: filepath.Join(dir, "inode-nr"), drop: filepath.Join(dir, "drop_caches"), lines: make(chan string, 64), done: make(chan error, 1)}
	g.set(initial)
	if err := os.WriteFile(g.drop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	g.cancel = cancel
	cmd := exec.CommandContext(ctx, "sh", "-c", guestInodeReclaimScript(headroom, "0.05", g.inodes, g.drop))
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		s := bufio.NewScanner(out)
		for s.Scan() {
			g.lines <- s.Text()
		}
		g.done <- cmd.Wait()
	}()
	t.Cleanup(func() { cancel(); <-g.done })
	return g
}

func (g *fakeGuestProc) set(nr string) {
	if err := os.WriteFile(g.inodes+".tmp", []byte(nr+"\t0\n"), 0o644); err != nil {
		g.t.Fatal(err)
	}
	if err := os.Rename(g.inodes+".tmp", g.inodes); err != nil {
		g.t.Fatal(err)
	}
}

func (g *fakeGuestProc) expect(want string) {
	g.t.Helper()
	select {
	case got := <-g.lines:
		if got != want {
			g.t.Fatalf("got %q, want %q", got, want)
		}
	case <-time.After(3 * time.Second):
		g.t.Fatalf("no %q within 3s", want)
	}
}

func (g *fakeGuestProc) expectQuiet(d time.Duration) {
	g.t.Helper()
	select {
	case got := <-g.lines:
		g.t.Fatalf("unexpected %q", got)
	case <-time.After(d):
	}
}

func TestGuestInodeReclaimDropsOnlyAboveTheFloorPlusHeadroom(t *testing.T) {
	g := startFakeGuest(t, 100, "50")
	g.expectQuiet(300 * time.Millisecond)
	g.set("101")
	g.expect("drop 101 101")
	if b, _ := os.ReadFile(g.drop); strings.TrimSpace(string(b)) != "2" {
		t.Fatalf("drop_caches got %q, want 2", b)
	}
	g.set("150")
	g.expectQuiet(300 * time.Millisecond)
	g.set("202")
	g.expect("drop 202 202")
}

func TestGuestInodeReclaimBacksOffWhenTheBaselineStaysHigh(t *testing.T) {
	g := startFakeGuest(t, 100, "5000")
	g.expect("drop 5000 5000")
	g.expectQuiet(500 * time.Millisecond)
	g.set("5099")
	g.expectQuiet(300 * time.Millisecond)
	g.set("5101")
	g.expect("drop 5101 5101")
}

func TestGuestInodeReclaimReportsWhenDropCachesIsUnavailable(t *testing.T) {
	dir := t.TempDir()
	inodes := filepath.Join(dir, "inode-nr")
	if err := os.WriteFile(inodes, []byte("1\t0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("sh", "-c", guestInodeReclaimScript(100, "0.05", inodes, filepath.Join(dir, "missing", "drop_caches"))).Output()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != guestReclaimUnsupported {
		t.Fatalf("exit = %v, want %d", err, guestReclaimUnsupported)
	}
	if !strings.Contains(string(out), "cannot read") {
		t.Fatalf("output %q must explain why", out)
	}
}

func TestReclaimLogSummarisesDropsAtMostOncePerMinute(t *testing.T) {
	var got []string
	clock := time.Unix(0, 0)
	l := &reclaimLog{report: func(s string) { got = append(got, s) }, now: func() time.Time { return clock }}
	_, _ = l.Write([]byte("drop 9000 800\ndrop 9100"))
	clock = clock.Add(10 * time.Second)
	_, _ = l.Write([]byte(" 700\n"))
	clock = clock.Add(time.Minute)
	_, _ = l.Write([]byte("drop 9300 600\ncannot read x\n"))
	want := []string{
		"guest inode reclaim: 1 drops in 0s, last 9000 -> 800 inodes",
		"guest inode reclaim: 2 drops in 1m0s, last 9300 -> 600 inodes",
		"guest inode reclaim: cannot read x",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestSuperviseGuestInodeReclaimRetriesWhileRemoteAndStopsWhenUnsupported(t *testing.T) {
	var mu sync.Mutex
	var reports []string
	report := func(s string) { mu.Lock(); reports = append(reports, s); mu.Unlock() }
	runs := 0
	run := func() error {
		runs++
		if runs < 3 {
			return errors.New("connection lost")
		}
		return errGuestReclaimUnsupported
	}
	superviseGuestInodeReclaim(func() bool { return true }, run, report, time.Millisecond)
	if runs != 3 {
		t.Fatalf("runs = %d, want 3", runs)
	}
	if len(reports) != 2 || !strings.Contains(reports[0], "connection lost") || !strings.Contains(reports[1], "cannot drop caches") {
		t.Fatalf("each distinct failure must be reported once: %q", reports)
	}

	runs = 0
	superviseGuestInodeReclaim(func() bool { return false }, func() error { runs++; return errors.New("vm stopped") }, func(string) {}, time.Millisecond)
	if runs != 1 {
		t.Fatalf("must stop retrying once gopls no longer runs in the VM: runs = %d", runs)
	}
}
