package docs

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSingleflightCoalescesAndInvalidationPreventsStaleCache(t *testing.T) {
	requireGo(t)
	realGo, err := exec.LookPath("go")
	must(t, err)
	root := fixture(t, "single")
	target := targetDarwin()

	t.Run("coalesce_concurrent_channels", func(t *testing.T) {
		wrapDir := t.TempDir()
		countFile := filepath.Join(wrapDir, "count.txt")
		startedFile := filepath.Join(wrapDir, "started")
		gateFile := filepath.Join(wrapDir, "gate")
		script := fmt.Sprintf(`#!/bin/sh
args="$*"
if [ "$1" = "list" ]; then
  case "$args" in
    *-deps*)
      echo x >> %q
      touch %q
      i=0
      while [ ! -f %q ] && [ $i -lt 1500 ]; do
        sleep 0.01
        i=$((i+1))
      done
      ;;
  esac
fi
exec %q "$@"
`, countFile, startedFile, gateFile, realGo)
		must(t, os.WriteFile(filepath.Join(wrapDir, "go"), []byte(script), 0o755))
		t.Setenv("PATH", wrapDir+":"+os.Getenv("PATH"))

		svc := NewService()
		opts := Options{Target: target}
		var wg sync.WaitGroup
		var idx *Index
		var pd *PackageDoc
		var sr *SearchResponse

		wg.Add(3)
		go func() { defer wg.Done(); idx = svc.ListPackages("i1", root, opts) }()
		go func() {
			defer wg.Done()
			pd = svc.LoadPackagePage("p1", root, "example.com/single/shapes", opts)
		}()
		go func() { defer wg.Done(); sr = svc.Search("s1", root, opts, "project", "Area", 20) }()

		waitForFile(t, startedFile)
		time.Sleep(80 * time.Millisecond)
		must(t, os.WriteFile(gateFile, []byte("go"), 0o644))
		wg.Wait()

		if idx.Error != "" || pd.Error != "" || sr.Error != "" {
			t.Fatalf("unexpected errors: idx=%q pd=%q sr=%q", idx.Error, pd.Error, sr.Error)
		}
		if idx.Generation == 0 || pd.Generation != idx.Generation || sr.Generation != idx.Generation {
			t.Fatalf("expected shared generation across singleflight channels: idx=%d pd=%d sr=%d", idx.Generation, pd.Generation, sr.Generation)
		}
		data, _ := os.ReadFile(countFile)
		if lines := len(strings.Fields(string(data))); lines != 1 {
			t.Fatalf("expected 1 coalesced go list -deps invocation, got %d", lines)
		}
	})

	t.Run("invalidation_midflight_does_not_cache_stale", func(t *testing.T) {
		wrapDir := t.TempDir()
		countFile := filepath.Join(wrapDir, "count.txt")
		startedFile := filepath.Join(wrapDir, "started")
		gateFile := filepath.Join(wrapDir, "gate")
		script := fmt.Sprintf(`#!/bin/sh
args="$*"
if [ "$1" = "list" ]; then
  case "$args" in
    *-deps*)
      echo x >> %q
      touch %q
      i=0
      while [ ! -f %q ] && [ $i -lt 1500 ]; do
        sleep 0.01
        i=$((i+1))
      done
      ;;
  esac
fi
exec %q "$@"
`, countFile, startedFile, gateFile, realGo)
		must(t, os.WriteFile(filepath.Join(wrapDir, "go"), []byte(script), 0o755))
		t.Setenv("PATH", wrapDir+":"+os.Getenv("PATH"))

		svc := NewService()
		opts := Options{Target: target}
		done := make(chan *Index, 1)
		go func() {
			done <- svc.ListPackages("inv-a", root, opts)
		}()
		waitForFile(t, startedFile)
		svc.Invalidate(root)
		invalGen := svc.CurrentGeneration()
		must(t, os.WriteFile(gateFile, []byte("go"), 0o644))

		res := <-done
		if res.Error != "" || res.Generation <= invalGen {
			t.Fatalf("expected post-invalidation retry generation > %d, got err=%q gen=%d", invalGen, res.Error, res.Generation)
		}
		cached := svc.ListPackages("inv-b", root, opts)
		if cached.Generation != res.Generation {
			t.Fatalf("expected cache hit generation %d, got %d", res.Generation, cached.Generation)
		}
		data, _ := os.ReadFile(countFile)
		if lines := len(strings.Fields(string(data))); lines != 2 {
			t.Fatalf("expected 2 go list invocations (pre-inval discarded + post-inval retry), got %d", lines)
		}
	})

	t.Run("leader_cancel_lets_surviving_waiter_retry", func(t *testing.T) {
		wrapDir := t.TempDir()
		startedFile := filepath.Join(wrapDir, "started")
		gateFile := filepath.Join(wrapDir, "gate")
		script := fmt.Sprintf(`#!/bin/sh
args="$*"
if [ "$1" = "list" ]; then
  case "$args" in
    *-deps*)
      touch %q
      if [ ! -f %q ]; then
        sleep 15
      fi
      ;;
  esac
fi
exec %q "$@"
`, startedFile, gateFile, realGo)
		must(t, os.WriteFile(filepath.Join(wrapDir, "go"), []byte(script), 0o755))
		t.Setenv("PATH", wrapDir+":"+os.Getenv("PATH"))

		svc := NewService()
		opts := Options{Target: target}
		leaderCh := make(chan *Index, 1)
		waiterCh := make(chan *PackageDoc, 1)
		go func() { leaderCh <- svc.ListPackages("leader", root, opts) }()
		waitForFile(t, startedFile)
		go func() { waiterCh <- svc.LoadPackagePage("waiter", root, "example.com/single/shapes", opts) }()
		time.Sleep(60 * time.Millisecond)

		svc.Cancel("leader")
		must(t, os.WriteFile(gateFile, []byte("go"), 0o644))
		leaderRes := <-leaderCh
		if !leaderRes.Cancelled {
			t.Fatalf("expected leader cancelled, got %+v", leaderRes)
		}
		waiterRes := <-waiterCh
		if waiterRes.Error != "" || len(waiterRes.Funcs) == 0 {
			t.Fatalf("expected surviving waiter to retry cleanly, got %+v", waiterRes)
		}
	})
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}
