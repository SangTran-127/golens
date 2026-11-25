package guestres

import (
	"maps"
	"testing"
)

func TestRunCgroupLimitsTurnSwapOffWithAMemoryLimit(t *testing.T) {
	cases := []struct {
		mem           uint64
		quota, period uint32
		swap          bool
		want          map[string]string
	}{
		{128 << 20, 0, 0, true, map[string]string{"memory.max": "134217728", "memory.swap.max": "0"}},
		{128 << 20, 0, 0, false, map[string]string{"memory.max": "134217728"}},
		{0, 50000, 0, true, map[string]string{"cpu.max": "50000 100000"}},
		{256 << 20, 25000, 50000, true, map[string]string{"memory.max": "268435456", "memory.swap.max": "0", "cpu.max": "25000 50000"}},
		{0, 0, 0, true, map[string]string{}},
	}
	for _, c := range cases {
		if got := RunCgroupLimits(c.mem, c.quota, c.period, c.swap); !maps.Equal(got, c.want) {
			t.Fatalf("RunCgroupLimits(%d, %d, %d, %v) = %v, want %v", c.mem, c.quota, c.period, c.swap, got, c.want)
		}
	}
}
