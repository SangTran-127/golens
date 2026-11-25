package guestres

import (
	"reflect"
	"testing"
	"time"
)

func TestMemorySteps(t *testing.T) {
	cases := []struct {
		base, ceiling uint64
		want          []uint64
	}{
		{512 * mib, 512 * mib, []uint64{512 * mib}},
		{512 * mib, 256 * mib, []uint64{512 * mib}},
		{512 * mib, 1024 * mib, []uint64{512 * mib, 1024 * mib}},
		{512 * mib, 2048 * mib, []uint64{512 * mib, 1024 * mib, 2048 * mib}},
		{512 * mib, 3072 * mib, []uint64{512 * mib, 1024 * mib, 2048 * mib, 3072 * mib}},
		{512 * mib, 16384 * mib, []uint64{512 * mib, 1024 * mib, 2048 * mib, 4096 * mib, 8192 * mib, 16384 * mib}},
	}
	for _, c := range cases {
		if got := MemorySteps(c.base, c.ceiling); !reflect.DeepEqual(got, c.want) {
			t.Errorf("MemorySteps(%d, %d) = %v, want %v", c.base>>20, c.ceiling>>20, got, c.want)
		}
	}
}

const (
	stepBase    uint64 = 512 * mib
	stepCeiling uint64 = 2048 * mib
	bootSlack   uint64 = 41 * mib
)

func guestTotal(step uint64) uint64 { return step - bootSlack }

func sampleAt(now time.Time, step, poolUsed, usage uint64) MemorySample {
	total := guestTotal(step)
	return MemorySample{At: now, MemTotal: total, PoolUsed: poolUsed, PoolLimit: ZramPoolFor(total), LSPCurrent: usage}
}

func full(step uint64) uint64 { return ZramPoolFor(guestTotal(step)) * 90 / 100 }

func TestStepControllerNeverGrowsWithoutRoom(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	for i := 0; i < 100; i++ {
		now = now.Add(2 * time.Second)
		if got := c.Target(stepBase, stepBase, stepBase, false, sampleAt(now, stepBase, full(stepBase), 400*mib), now); got != stepBase {
			t.Fatalf("ceiling equal to the base grew to %d MiB", got>>20)
		}
	}
}

func TestStepControllerSmallProjectStaysAtBase(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	for i := 0; i < 600; i++ {
		now = now.Add(2 * time.Second)
		pool := ZramPoolFor(guestTotal(stepBase)) * 30 / 100
		if got := c.Target(stepBase, stepBase, stepCeiling, i%50 > 40, sampleAt(now, stepBase, pool, 180*mib), now); got != stepBase {
			t.Fatalf("a small project grew to %d MiB at sample %d", got>>20, i)
		}
	}
}

func TestStepControllerGrowsOneStepWithCooldown(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := stepBase
	cur = c.Target(cur, stepBase, stepCeiling, false, sampleAt(now, stepBase, full(stepBase), 600*mib), now)
	if cur != 1024*mib {
		t.Fatalf("pressure at the base: target %d MiB, want 1024", cur>>20)
	}
	for _, d := range []time.Duration{2, 10, 28} {
		at := now.Add(d * time.Second)
		if got := c.Target(cur, stepBase, stepCeiling, false, sampleAt(at, 1024*mib, full(1024*mib), 900*mib), at); got != cur {
			t.Fatalf("grew again %v after the last step: %d MiB", d*time.Second, got>>20)
		}
	}
	at := now.Add(31 * time.Second)
	cur = c.Target(cur, stepBase, stepCeiling, false, sampleAt(at, 1024*mib, full(1024*mib), 900*mib), at)
	if cur != stepCeiling {
		t.Fatalf("sustained pressure after the cool-down: %d MiB, want 2048", cur>>20)
	}
	at = at.Add(time.Minute)
	if got := c.Target(cur, stepBase, stepCeiling, false, sampleAt(at, stepCeiling, full(stepCeiling), 1500*mib), at); got != stepCeiling {
		t.Fatalf("grew past the ceiling: %d MiB", got>>20)
	}
}

func TestStepControllerGrowsWhenGoplsIsPinnedAtItsBudgetAndSwapping(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := uint64(1024 * mib)
	high := GuestLSPBudget(guestTotal(cur)).CgroupHigh
	quiet := ZramPoolFor(guestTotal(cur)) * 40 / 100
	s := sampleAt(now, cur, quiet, high)
	s.LSPSwap = high * 30 / 100
	if got := c.Target(cur, stepBase, stepCeiling, false, s, now); got != cur {
		t.Fatalf("gopls at its budget with a little swap grew the guest to %d MiB", got>>20)
	}
	s.LSPCurrent = high * 80 / 100
	s.LSPSwap = high
	if got := c.Target(cur, stepBase, stepCeiling, false, s, now); got != cur {
		t.Fatalf("gopls below its budget grew the guest to %d MiB", got>>20)
	}
	s.LSPCurrent = high
	s.LSPSwap = high * 60 / 100
	if got := c.Target(cur, stepBase, stepCeiling, false, s, now); got != stepCeiling {
		t.Fatalf("gopls pinned at its budget with %d%% of it swapped: %d MiB, want 2048", 60, got>>20)
	}
}

func TestStepControllerIgnoresStaleSamples(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	old := sampleAt(now.Add(-time.Minute), stepBase, full(stepBase), 600*mib)
	if got := c.Target(stepBase, stepBase, stepCeiling, false, old, now); got != stepBase {
		t.Fatalf("a stale sample grew the guest to %d MiB", got>>20)
	}
	if got := c.Target(stepBase, stepBase, stepCeiling, false, MemorySample{}, now); got != stepBase {
		t.Fatalf("no sample grew the guest to %d MiB", got>>20)
	}
}

func TestStepControllerShrinksOnlyAfterSustainedFit(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := c.Target(stepBase, stepBase, stepCeiling, false, sampleAt(now, stepBase, full(stepBase), 600*mib), now)
	if cur != 1024*mib {
		t.Fatalf("setup: %d MiB", cur>>20)
	}
	small := func(at time.Time) MemorySample { return sampleAt(at, 1024*mib, 10*mib, 150*mib) }
	at := now
	for i := 0; i < 80; i++ {
		at = at.Add(2 * time.Second)
		if got := c.Target(cur, stepBase, stepCeiling, false, small(at), at); got != cur {
			t.Fatalf("shrank %v after growing", at.Sub(now))
		}
	}
	at = at.Add(2 * time.Second)
	if got := c.Target(cur, stepBase, stepCeiling, false, sampleAt(at, 1024*mib, 10*mib, 400*mib), at); got != cur {
		t.Fatal("shrank while gopls did not fit the lower step")
	}
	start := at
	for {
		at = at.Add(2 * time.Second)
		got := c.Target(cur, stepBase, stepCeiling, false, small(at), at)
		if got == stepBase {
			break
		}
		if at.Sub(start) > 4*time.Minute {
			t.Fatal("never shrank after the fit held")
		}
	}
	if d := at.Sub(start); d < 3*time.Minute {
		t.Fatalf("shrank %v after the fit began; want at least 3 minutes", d)
	}
}

func TestStepControllerDoesNotShrinkIntoSwap(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := c.Target(stepBase, stepBase, stepCeiling, false, sampleAt(now, stepBase, full(stepBase), 600*mib), now)
	at := now
	for i := 0; i < 300; i++ {
		at = at.Add(2 * time.Second)
		s := sampleAt(at, 1024*mib, 10*mib, 200*mib)
		s.LSPSwap = 150 * mib
		if got := c.Target(cur, stepBase, stepCeiling, false, s, at); got != cur {
			t.Fatalf("shrank while gopls's memory plus swap (350 MiB) exceeds the lower step's budget")
		}
	}
	for i := 0; i < 300; i++ {
		at = at.Add(2 * time.Second)
		s := sampleAt(at, 1024*mib, ZramPoolFor(guestTotal(stepBase))*60/100, 100*mib)
		if got := c.Target(cur, stepBase, stepCeiling, false, s, at); got != cur {
			t.Fatalf("shrank while the swap pool would be over half full at the lower step")
		}
	}
}

func TestStepControllerIdleShrinkAndRestore(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := c.Target(stepBase, stepBase, stepCeiling, false, sampleAt(now, stepBase, full(stepBase), 600*mib), now)
	at := now.Add(31 * time.Second)
	cur = c.Target(cur, stepBase, stepCeiling, false, sampleAt(at, 1024*mib, full(1024*mib), 900*mib), at)
	if cur != stepCeiling {
		t.Fatalf("setup: %d MiB", cur>>20)
	}
	at = at.Add(time.Minute)
	idleSample := func(at time.Time, step uint64) MemorySample { return sampleAt(at, step, 20*mib, 420*mib) }
	if got := c.Target(cur, stepBase, stepCeiling, true, sampleAt(at, stepCeiling, 20*mib, 1200*mib), at); got != cur {
		t.Fatalf("idle shrink while gopls did not fit the lower step even with swap: %d MiB", got>>20)
	}
	at = at.Add(2 * time.Second)
	cur = c.Target(cur, stepBase, stepCeiling, true, idleSample(at, stepCeiling), at)
	if cur != 1024*mib {
		t.Fatalf("idle: %d MiB, want 1024", cur>>20)
	}
	at = at.Add(10 * time.Second)
	if got := c.Target(cur, stepBase, stepCeiling, true, idleSample(at, 1024*mib), at); got != cur {
		t.Fatal("idle shrink stepped twice inside the cool-down")
	}
	at = at.Add(30 * time.Second)
	if got := c.Target(cur, stepBase, stepCeiling, true, idleSample(at, 1024*mib), at); got != cur {
		t.Fatal("idle shrink into a step whose budget plus swap pool cannot hold gopls")
	}
	at = at.Add(5 * time.Second)
	cur = c.Target(cur, stepBase, stepCeiling, false, idleSample(at, 1024*mib), at)
	if cur != stepCeiling {
		t.Fatalf("activity after the idle shrink: %d MiB, want the 2048 MiB step back", cur>>20)
	}
}

func TestStepControllerAdoptsExternalReset(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	cur := c.Target(stepBase, stepBase, stepCeiling, false, sampleAt(now, stepBase, full(stepBase), 600*mib), now)
	if cur != 1024*mib {
		t.Fatalf("setup: %d MiB", cur>>20)
	}
	at := now.Add(5 * time.Second)
	if got := c.Target(stepBase, stepBase, stepCeiling, false, sampleAt(at, stepBase, 0, 50*mib), at); got != stepBase {
		t.Fatalf("after a reboot at the base the controller moved to %d MiB", got>>20)
	}
}

func TestGuestLSPBudgetFollowsTheStep(t *testing.T) {
	small := GuestLSPBudget(471 * mib)
	if small.CgroupHigh != 283*mib || small.CgroupMax != 300*mib {
		t.Fatalf("512 MB guest budget = %d / %d MiB, want 283 / 300", small.CgroupHigh>>20, small.CgroupMax>>20)
	}
	large := GuestLSPBudget(983 * mib)
	if large.CgroupHigh <= small.CgroupHigh*2 || large.GoMemLimit <= small.GoMemLimit*2 {
		t.Fatalf("1 GB guest budget %+v does not scale from %+v", large, small)
	}
}

func TestStepControllerGrowsWhenGoplsStaysAtItsBudget(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	step := uint64(1024 * mib)
	high := GuestLSPBudget(guestTotal(step)).CgroupHigh
	pinned := func(at time.Time) MemorySample {
		s := sampleAt(at, step, 0, high)
		s.LSPSwap = high / 5
		return s
	}
	for d := time.Duration(0); d < 20*time.Second; d += 2 * time.Second {
		at := now.Add(d)
		if got := c.Target(step, stepBase, stepCeiling, false, pinned(at), at); got != step {
			t.Fatalf("grew to %d MiB after gopls sat at its budget for only %v", got>>20, d)
		}
	}
	at := now.Add(20 * time.Second)
	if got := c.Target(step, stepBase, stepCeiling, false, pinned(at), at); got != stepCeiling {
		t.Fatalf("gopls held at its budget for 20 s: target %d MiB, want %d", got>>20, stepCeiling>>20)
	}
	if c.GrowReason == "" {
		t.Fatal("no grow reason recorded")
	}
}

func TestStepControllerPinnedTimerResetsWhenGoplsDropsBelowItsBudget(t *testing.T) {
	c := NewStepController()
	now := time.Unix(1000, 0)
	step := uint64(1024 * mib)
	high := GuestLSPBudget(guestTotal(step)).CgroupHigh
	for i := 0; i < 30; i++ {
		at := now.Add(time.Duration(i*2) * time.Second)
		usage := high
		if i%8 == 7 {
			usage = high * 80 / 100
		}
		if got := c.Target(step, stepBase, stepCeiling, false, sampleAt(at, step, 0, usage), at); got != step {
			t.Fatalf("grew to %d MiB although gopls left its budget every 16 s", got>>20)
		}
	}
}
