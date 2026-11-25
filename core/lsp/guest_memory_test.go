package lsp

import (
	"testing"
	"time"

	"golens/core/cmd/golens-vm-agent/guestres"
)

func resetGuestMemory(t *testing.T) {
	t.Helper()
	guestMemory.mu.Lock()
	guestMemory.sample = guestres.MemorySample{}
	guestMemory.ctl = nil
	guestMemory.mu.Unlock()
	old := remoteGoplsMemoryLimit.Load()
	t.Cleanup(func() {
		guestMemory.mu.Lock()
		guestMemory.sample = guestres.MemorySample{}
		guestMemory.ctl = nil
		guestMemory.mu.Unlock()
		remoteGoplsMemoryLimit.Store(old)
	})
}

func TestGuestMemoryStepTargetGrowsOnFullPoolAndHoldsWithoutSamples(t *testing.T) {
	resetGuestMemory(t)
	const mib = 1 << 20
	base, ceiling := uint64(512*mib), uint64(2048*mib)
	if got := GuestMemoryStepTarget(base, base, ceiling, false); got != base {
		t.Fatalf("no guest sample yet: %d MiB", got>>20)
	}
	recordGuestMemory(guestres.MemorySample{At: time.Now(), MemTotal: 430 * mib, PoolUsed: 100 * mib, PoolLimit: 107 * mib, LSPCurrent: 280 * mib, LSPSwap: 300 * mib})
	if got := GuestMemoryStepTarget(base, base, ceiling, false); got != 1024*mib {
		t.Fatalf("full swap pool at the base: %d MiB, want 1024", got>>20)
	}
	if got := GuestMemoryStepTarget(base, base, base, false); got != base {
		t.Fatalf("a 512 MB ceiling grew to %d MiB", got>>20)
	}
}

func TestGuestMemorySampleMovesTheGoplsMemoryLimit(t *testing.T) {
	resetGuestMemory(t)
	const mib = 1 << 20
	remoteGoplsMemoryLimit.Store(goplsMemoryLimitForTotal(471 * mib))
	small := remoteGoplsMemoryLimit.Load()
	recordGuestMemory(guestres.MemorySample{At: time.Now(), MemTotal: 473 * mib})
	if got := remoteGoplsMemoryLimit.Load(); got != small {
		t.Fatalf("a 2 MiB MemTotal wobble moved memoryLimit from %d to %d MiB", small>>20, got>>20)
	}
	recordGuestMemory(guestres.MemorySample{At: time.Now(), MemTotal: 983 * mib})
	large := remoteGoplsMemoryLimit.Load()
	if want := goplsMemoryLimitForTotal(983 * mib); large != want || large <= small {
		t.Fatalf("1 GB step: memoryLimit %d MiB, want %d (512 MB step %d)", large>>20, want>>20, small>>20)
	}
	recordGuestMemory(guestres.MemorySample{At: time.Now(), MemTotal: 471 * mib})
	if got := remoteGoplsMemoryLimit.Load(); got != small {
		t.Fatalf("back at the base: memoryLimit %d MiB, want %d", got>>20, small>>20)
	}
}
