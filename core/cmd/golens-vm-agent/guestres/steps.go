package guestres

import "time"

const BaseGuestMemory uint64 = 512 * mib

type MemorySample struct {
	At         time.Time
	MemTotal   uint64
	PoolUsed   uint64
	PoolLimit  uint64
	LSPCurrent uint64
	LSPSwap    uint64
}

type StepPolicy struct {
	GrowPoolPercent   uint64
	GrowAtHighPercent uint64
	GrowSwapPercent   uint64
	GrowCooldown      time.Duration
	GrowPinnedAfter   time.Duration
	ShrinkFitPercent  uint64
	ShrinkPoolPercent uint64
	ShrinkAfter       time.Duration
	IdleShrinkAfter   time.Duration
	SampleMaxAge      time.Duration
}

var DefaultStepPolicy = StepPolicy{
	GrowPoolPercent:   85,
	GrowAtHighPercent: 95,
	GrowSwapPercent:   50,
	GrowCooldown:      30 * time.Second,
	GrowPinnedAfter:   20 * time.Second,
	ShrinkFitPercent:  75,
	ShrinkPoolPercent: 50,
	ShrinkAfter:       3 * time.Minute,
	IdleShrinkAfter:   30 * time.Second,
	SampleMaxAge:      10 * time.Second,
}

func MemorySteps(base, ceiling uint64) []uint64 {
	if base == 0 || ceiling <= base {
		return []uint64{max(base, ceiling)}
	}
	steps := []uint64{base}
	for s := base * 2; s < ceiling; s *= 2 {
		steps = append(steps, s)
	}
	return append(steps, ceiling)
}

func ZramPoolFor(memTotal uint64) uint64 {
	return ZramSwapFor(memTotal).MemLimit
}

func GuestLSPBudget(memTotal uint64) LSPBudget {
	return LSPBudgetFor(memTotal).WithSwapPool(memTotal, ZramPoolFor(memTotal))
}

type StepController struct {
	Policy      StepPolicy
	current     uint64
	changedAt   time.Time
	grewAt      time.Time
	fitSince    time.Time
	pinnedSince time.Time
	beforeIdle  uint64
	GrowReason  string
}

func NewStepController() *StepController {
	return &StepController{Policy: DefaultStepPolicy}
}

func (c *StepController) Target(current, base, ceiling uint64, idle bool, s MemorySample, now time.Time) uint64 {
	steps := MemorySteps(base, ceiling)
	if len(steps) == 1 {
		c.adopt(steps[0], now)
		return steps[0]
	}
	if current != c.current {
		c.adopt(current, now)
	}
	idx := stepIndex(steps, current)
	if !idle && c.beforeIdle > 0 {
		restore := min(c.beforeIdle, ceiling)
		c.beforeIdle = 0
		if restore > current {
			return c.move(restore, now)
		}
	}
	if s.MemTotal == 0 || now.Sub(s.At) > c.Policy.SampleMaxAge || now.Before(s.At) {
		c.fitSince = time.Time{}
		c.pinnedSince = time.Time{}
		return current
	}
	if c.Policy.GoplsPinned(s) {
		if c.pinnedSince.IsZero() {
			c.pinnedSince = now
		}
	} else {
		c.pinnedSince = time.Time{}
	}
	if reason := c.growReason(s, now); idx < len(steps)-1 && reason != "" &&
		(c.grewAt.IsZero() || now.Sub(c.grewAt) >= c.Policy.GrowCooldown) {
		c.grewAt = now
		c.GrowReason = reason
		return c.move(steps[idx+1], now)
	}
	if idx == 0 || current < steps[idx] {
		c.fitSince = time.Time{}
		return current
	}
	lower := steps[idx-1]
	fits, fitsIdle := c.fitsLower(s, current-lower)
	if fits {
		if c.fitSince.IsZero() {
			c.fitSince = now
		}
	} else {
		c.fitSince = time.Time{}
	}
	switch {
	case fits && now.Sub(c.fitSince) >= c.Policy.ShrinkAfter && now.Sub(c.changedAt) >= c.Policy.ShrinkAfter:
		return c.move(lower, now)
	case idle && fitsIdle && now.Sub(c.changedAt) >= c.Policy.IdleShrinkAfter:
		if c.beforeIdle == 0 {
			c.beforeIdle = current
		}
		return c.move(lower, now)
	}
	return current
}

func (p StepPolicy) PoolFull(s MemorySample) bool {
	return s.PoolLimit > 0 && s.PoolUsed*100 >= s.PoolLimit*p.GrowPoolPercent
}

func (p StepPolicy) GoplsPinned(s MemorySample) bool {
	high := GuestLSPBudget(s.MemTotal).CgroupHigh
	return high > 0 && s.LSPCurrent*100 >= high*p.GrowAtHighPercent
}

func (p StepPolicy) GoplsStarved(s MemorySample) bool {
	high := GuestLSPBudget(s.MemTotal).CgroupHigh
	return p.GoplsPinned(s) && s.LSPSwap*100 >= high*p.GrowSwapPercent
}

func (c *StepController) growReason(s MemorySample, now time.Time) string {
	switch {
	case c.Policy.PoolFull(s):
		return "swap pool nearly full"
	case c.Policy.GoplsStarved(s):
		return "gopls is at its memory budget and swapping"
	case !c.pinnedSince.IsZero() && now.Sub(c.pinnedSince) >= c.Policy.GrowPinnedAfter:
		return "gopls has been held at its memory budget"
	}
	return ""
}

func (p StepPolicy) UnderPressure(s MemorySample) bool {
	return p.PoolFull(s) || p.GoplsStarved(s)
}

func (c *StepController) fitsLower(s MemorySample, drop uint64) (fits, fitsIdle bool) {
	if s.MemTotal <= drop {
		return false, false
	}
	memTotal := s.MemTotal - drop
	budget := GuestLSPBudget(memTotal)
	pool := ZramPoolFor(memTotal)
	usage := s.LSPCurrent + s.LSPSwap
	poolFits := s.PoolUsed*100 <= pool*c.Policy.ShrinkPoolPercent
	fits = poolFits && usage*100 <= budget.CgroupHigh*c.Policy.ShrinkFitPercent
	fitsIdle = poolFits && usage <= budget.CgroupHigh+pool
	return fits, fitsIdle
}

func (c *StepController) adopt(current uint64, now time.Time) {
	if c.current == current {
		return
	}
	c.current = current
	c.changedAt = now
	c.fitSince = time.Time{}
	c.pinnedSince = time.Time{}
	c.beforeIdle = 0
}

func (c *StepController) move(target uint64, now time.Time) uint64 {
	c.current = target
	c.changedAt = now
	c.fitSince = time.Time{}
	c.pinnedSince = time.Time{}
	return target
}

func stepIndex(steps []uint64, current uint64) int {
	idx := 0
	for i, s := range steps {
		if s <= current {
			idx = i
		}
	}
	return idx
}
