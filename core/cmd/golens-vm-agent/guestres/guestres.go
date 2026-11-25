package guestres

import (
	"bufio"
	"bytes"
	"strconv"
	"strings"
)

const (
	mib = 1024 * 1024

	fallbackMemTotal = 2048 * mib
	minGoplsLimit    = 128 * mib
)

type LSPBudget struct {
	GoMemLimit uint64
	CgroupHigh uint64
	CgroupMax  uint64
}

func ParseMemTotal(meminfo []byte) uint64 {
	sc := bufio.NewScanner(bytes.NewReader(meminfo))
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(strings.TrimPrefix(line, "MemTotal:"))
		if len(fields) == 0 {
			return 0
		}
		kb, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return 0
		}
		return kb * 1024
	}
	return 0
}

func LSPBudgetFor(memTotal uint64) LSPBudget {
	if memTotal == 0 {
		memTotal = fallbackMemTotal
	}
	limit := alignDown(memTotal * 60 / 100)
	if limit < minGoplsLimit {
		limit = minGoplsLimit
	}
	return LSPBudget{
		GoMemLimit: limit,
		CgroupHigh: alignDown(memTotal * 70 / 100),
		CgroupMax:  alignDown(memTotal * 85 / 100),
	}
}

func GoMemLimitEnv(bytes uint64) string {
	return "GOMEMLIMIT=" + strconv.FormatUint(bytes/mib, 10) + "MiB"
}

const BalloonPageSize = 4096

func ParseBalloonPages(vmstat []byte) uint64 {
	sc := bufio.NewScanner(bytes.NewReader(vmstat))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 || fields[0] != "nr_balloon_pages" {
			continue
		}
		n, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return 0
		}
		return n
	}
	return 0
}

func UsableMemory(memTotal, balloonPages uint64) uint64 {
	inflated := balloonPages * BalloonPageSize
	if memTotal == 0 || inflated >= memTotal {
		return memTotal
	}
	return memTotal - inflated
}

func ParseUsableMemory(meminfoAndVmstat []byte) uint64 {
	return UsableMemory(ParseMemTotal(meminfoAndVmstat), ParseBalloonPages(meminfoAndVmstat))
}

func UsableAtStep(memTotal, balloonPages, step, ceiling uint64) uint64 {
	usable := UsableMemory(memTotal, balloonPages)
	if step == 0 || ceiling <= step || memTotal <= ceiling-step {
		return usable
	}
	return min(usable, memTotal-(ceiling-step))
}

const (
	memTotalMoveBytes = 4 * mib
	lspMaxHeadroom    = 32 * mib
)

func MemTotalMoved(applied, now uint64) bool {
	if applied > now {
		return applied-now >= memTotalMoveBytes
	}
	return now-applied >= memTotalMoveBytes
}

func LSPMaxFor(budgetMax, current uint64) uint64 {
	if current < budgetMax {
		return budgetMax
	}
	return alignDown(current + lspMaxHeadroom + mib - 1)
}

func alignDown(v uint64) uint64 {
	return v / mib * mib
}
