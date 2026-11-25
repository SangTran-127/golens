package guestres

import "testing"

func TestParseMemTotal(t *testing.T) {
	meminfo := []byte("MemTotal:        2014580 kB\nMemFree:         1500000 kB\nMemAvailable:    1800000 kB\n")
	if got, want := ParseMemTotal(meminfo), uint64(2014580*1024); got != want {
		t.Fatalf("ParseMemTotal = %d, want %d", got, want)
	}
	if got := ParseMemTotal([]byte("MemFree: 10 kB\n")); got != 0 {
		t.Fatalf("missing MemTotal should yield 0, got %d", got)
	}
	if got := ParseMemTotal([]byte("MemTotal: abc kB\n")); got != 0 {
		t.Fatalf("malformed MemTotal should yield 0, got %d", got)
	}
}

func TestLSPBudgetScalesWithGuestMemory(t *testing.T) {
	b := LSPBudgetFor(2048 * mib)
	if b.GoMemLimit != 1228*mib {
		t.Fatalf("GoMemLimit = %d MiB, want 1228 MiB", b.GoMemLimit/mib)
	}
	if !(b.GoMemLimit < b.CgroupHigh && b.CgroupHigh < b.CgroupMax && b.CgroupMax < 2048*mib) {
		t.Fatalf("budget must be ordered below guest memory: %+v", b)
	}
	if b.GoMemLimit%mib != 0 || b.CgroupHigh%mib != 0 || b.CgroupMax%mib != 0 {
		t.Fatalf("budget must be MiB aligned: %+v", b)
	}
}

func TestLSPBudgetHandlesSmallAndUnknownMemory(t *testing.T) {
	small := LSPBudgetFor(160 * mib)
	if small.GoMemLimit != minGoplsLimit {
		t.Fatalf("small guest GoMemLimit = %d, want floor %d", small.GoMemLimit, minGoplsLimit)
	}
	unknown := LSPBudgetFor(0)
	if unknown != LSPBudgetFor(fallbackMemTotal) {
		t.Fatalf("unknown memory should use fallback budget")
	}
}

func TestGoMemLimitEnv(t *testing.T) {
	if got := GoMemLimitEnv(1228 * mib); got != "GOMEMLIMIT=1228MiB" {
		t.Fatalf("GoMemLimitEnv = %q", got)
	}
}

func TestUsableMemorySubtractsTheInflatedBalloon(t *testing.T) {
	both := []byte("MemTotal:        2024116 kB\nMemFree:  33756 kB\nnr_free_pages 8000\nnr_balloon_pages 393216\nballoon_inflate 393216\n")
	if got, want := ParseUsableMemory(both), uint64(2024116*1024-393216*4096); got != want {
		t.Fatalf("usable memory with a 1.5 GiB balloon = %d, want %d", got, want)
	}
	if got := ParseUsableMemory([]byte("MemTotal: 482304 kB\n")); got != 482304*1024 {
		t.Fatalf("no balloon line: %d", got)
	}
	if got := UsableMemory(100*mib, 1<<30); got != 100*mib {
		t.Fatalf("a balloon larger than MemTotal: %d", got)
	}
	if got := ParseBalloonPages([]byte("nr_balloon_pages x\n")); got != 0 {
		t.Fatalf("malformed balloon line: %d", got)
	}
}

func TestUsableAtStepCountsTheBalloonBeforeItInflates(t *testing.T) {
	const memTotal = 1976 * mib
	if got, want := UsableAtStep(memTotal, 0, 512*mib, 2048*mib), uint64(440*mib); got != want {
		t.Fatalf("usable at the 512 MiB step before the balloon inflates = %d MiB, want %d MiB", got>>20, want>>20)
	}
	inflated := uint64(1536*mib) / 4096
	if got, want := UsableAtStep(memTotal, inflated, 512*mib, 2048*mib), uint64(440*mib); got != want {
		t.Fatalf("usable at the 512 MiB step after the balloon inflates = %d MiB, want %d MiB", got>>20, want>>20)
	}
	if got, want := UsableAtStep(memTotal, inflated, 1024*mib, 2048*mib), uint64(440*mib); got != want {
		t.Fatalf("usable while the balloon still holds the smaller step = %d MiB, want %d MiB", got>>20, want>>20)
	}
	for _, c := range []struct{ step, ceiling uint64 }{{0, 2048 * mib}, {2048 * mib, 2048 * mib}, {512 * mib, 0}} {
		if got, want := UsableAtStep(memTotal, 0, c.step, c.ceiling), uint64(memTotal); got != want {
			t.Fatalf("usable with step %d MiB and ceiling %d MiB = %d MiB, want the measured %d MiB", c.step>>20, c.ceiling>>20, got>>20, want>>20)
		}
	}
}

func TestMemTotalMoved(t *testing.T) {
	if !MemTotalMoved(0, 471*mib) {
		t.Error("the first reading was not applied")
	}
	if MemTotalMoved(471*mib, 473*mib) || MemTotalMoved(473*mib, 471*mib) {
		t.Error("a 2 MiB wobble resized the guest budget")
	}
	if !MemTotalMoved(1983*mib, 471*mib) || !MemTotalMoved(471*mib, 983*mib) {
		t.Error("a balloon step did not resize the guest budget")
	}
}

func TestLSPMaxForNeverCutsBelowCurrentUsage(t *testing.T) {
	if got := LSPMaxFor(300*mib, 250*mib); got != 300*mib {
		t.Errorf("usage under the budget: max %d MiB, want 300", got>>20)
	}
	usage := uint64(600*mib + 12345)
	got := LSPMaxFor(300*mib, usage)
	if got < usage+31*mib || got%mib != 0 {
		t.Errorf("usage over a shrunken budget: max %d bytes, want at least usage plus headroom, MiB aligned", got)
	}
}
