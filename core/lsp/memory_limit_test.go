package lsp

import (
	"errors"
	"testing"

	"golens/core/cmd/golens-vm-agent/guestres"
)

func TestGoplsMemoryLimitAddsTheBallastToTheGuestBudget(t *testing.T) {
	meminfo := []byte("MemTotal:         483328 kB\nMemFree:          100000 kB\n")
	budget := guestres.LSPBudgetFor(483328 * 1024).GoMemLimit
	got := goplsMemoryLimitForGuest(meminfo)
	if want := int64(budget) + goplsBallastBytes; got != want {
		t.Fatalf("memoryLimit = %d, want %d", got, want)
	}
	if got>>20 < 350 || got>>20 > 400 {
		t.Fatalf("memoryLimit for a 512 MB guest = %d MiB, want about 375", got>>20)
	}
}

func TestGoplsMemoryLimitFollowsTheBalloonNotTheBootSize(t *testing.T) {
	both := []byte("MemTotal:        2024116 kB\nMemFree:          33756 kB\nnr_free_pages 8000\nnr_balloon_pages 393216\n")
	usable := uint64(2024116*1024 - 393216*4096)
	if got, want := goplsMemoryLimitForGuest(both), int64(guestres.LSPBudgetFor(usable).GoMemLimit)+goplsBallastBytes; got != want {
		t.Fatalf("memoryLimit with a 2 GB guest ballooned to 512 MB = %d MiB, want %d", got>>20, want>>20)
	}
}

func TestGoplsMemoryLimitIsUnsetWhenMeminfoIsUnreadable(t *testing.T) {
	if got := goplsMemoryLimitForGuest([]byte("garbage")); got != 0 {
		t.Fatalf("memoryLimit = %d, want 0", got)
	}
}

func TestRemoteSettingsCarryTheProbedMemoryLimitOnlyForTheVM(t *testing.T) {
	old := remoteGoplsMemoryLimit.Load()
	t.Cleanup(func() { remoteGoplsMemoryLimit.Store(old) })

	remoteGoplsMemoryLimit.Store(0)
	if _, ok := goplsSettingsFor(true)["memoryLimit"]; ok {
		t.Fatal("memoryLimit sent before the guest was probed")
	}

	remoteGoplsMemoryLimit.Store(400 << 20)
	if got := goplsSettingsFor(true)["memoryLimit"]; got != int64(400<<20) {
		t.Fatalf("remote memoryLimit = %v, want %d", got, int64(400<<20))
	}
	if _, ok := goplsSettingsFor(false)["memoryLimit"]; ok {
		t.Fatal("memoryLimit sent to host gopls")
	}
}

func stubGuestMeminfo(t *testing.T, read func() ([]byte, error)) {
	oldRead, oldDelay, oldLimit := readGuestMeminfo, meminfoRetryDelay, remoteGoplsMemoryLimit.Load()
	t.Cleanup(func() {
		readGuestMeminfo, meminfoRetryDelay = oldRead, oldDelay
		remoteGoplsMemoryLimit.Store(oldLimit)
	})
	readGuestMeminfo, meminfoRetryDelay = read, 0
}

func TestGoplsMemoryLimitProbeRetriesAFailedGuestRead(t *testing.T) {
	meminfo := []byte("MemTotal:         482760 kB\n")
	calls := 0
	stubGuestMeminfo(t, func() ([]byte, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("exit status 1")
		}
		return meminfo, nil
	})
	remoteGoplsMemoryLimit.Store(0)
	probeGuestGoplsMemoryLimit()
	if calls != 2 {
		t.Fatalf("guest meminfo read %d times, want 2", calls)
	}
	if got, want := remoteGoplsMemoryLimit.Load(), goplsMemoryLimitForGuest(meminfo); got != want {
		t.Fatalf("memoryLimit after a retried read = %d, want %d", got, want)
	}
}

func TestGoplsMemoryLimitProbeUsesTheCurrentStepBeforeTheBalloonInflates(t *testing.T) {
	meminfo := []byte("MemTotal:        2023424 kB\n")
	SetGuestMemoryStep(512<<20, 2048<<20)
	t.Cleanup(func() { SetGuestMemoryStep(0, 0) })
	stubGuestMeminfo(t, func() ([]byte, error) { return meminfo, nil })
	probeGuestGoplsMemoryLimit()
	want := goplsMemoryLimitForTotal(2023424<<10 - 1536<<20)
	if got := remoteGoplsMemoryLimit.Load(); got != want {
		t.Fatalf("memoryLimit at the 512 MiB step of a 2 GiB guest = %d MiB, want %d MiB", got>>20, want>>20)
	}
	if full := goplsMemoryLimitForTotal(2023424 << 10); want >= full {
		t.Fatalf("step-sized memoryLimit %d MiB is not below the full-guest %d MiB", want>>20, full>>20)
	}
}

func TestGoplsMemoryLimitProbeGivesUpAfterThreeFailedReads(t *testing.T) {
	calls := 0
	stubGuestMeminfo(t, func() ([]byte, error) {
		calls++
		return nil, errors.New("exit status 1")
	})
	remoteGoplsMemoryLimit.Store(400 << 20)
	probeGuestGoplsMemoryLimit()
	if calls != 3 {
		t.Fatalf("guest meminfo read %d times, want 3", calls)
	}
	if got := remoteGoplsMemoryLimit.Load(); got != 0 {
		t.Fatalf("memoryLimit after three failed reads = %d, want 0", got)
	}
}
