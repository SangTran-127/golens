package database

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestReleaseMemoryRunsAgainForACloseDuringARelease(t *testing.T) {
	for releaseRequests.Load() != 0 {
		time.Sleep(5 * time.Millisecond)
	}
	started := make(chan struct{})
	unblock := make(chan struct{})
	var calls atomic.Int32
	orig := swapFreeOSMemory(func() {
		if calls.Add(1) == 1 {
			close(started)
			<-unblock
		}
	})
	defer func() {
		for releaseRequests.Load() != 0 {
			time.Sleep(5 * time.Millisecond)
		}
		swapFreeOSMemory(orig)
	}()
	releaseMemory()
	<-started
	releaseMemory()
	close(unblock)
	deadline := time.Now().Add(2 * time.Second)
	for releaseRequests.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("freeOSMemory ran %d times, want 2", got)
	}
	if releaseRequests.Load() != 0 {
		t.Fatal("release requests were not drained")
	}
}
