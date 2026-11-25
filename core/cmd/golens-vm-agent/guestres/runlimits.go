package guestres

import (
	"fmt"
	"strconv"
)

func RunCgroupLimits(memoryMax uint64, cpuQuotaUS, cpuPeriodUS uint32, swapAccounting bool) map[string]string {
	limits := map[string]string{}
	if memoryMax > 0 {
		limits["memory.max"] = strconv.FormatUint(memoryMax, 10)
		if swapAccounting {
			limits["memory.swap.max"] = "0"
		}
	}
	if cpuQuotaUS > 0 {
		if cpuPeriodUS == 0 {
			cpuPeriodUS = 100000
		}
		limits["cpu.max"] = fmt.Sprintf("%d %d", cpuQuotaUS, cpuPeriodUS)
	}
	return limits
}
