package guestres

import "encoding/binary"

type ZramSwap struct {
	DiskSize uint64
	MemLimit uint64
}

func ZramSwapFor(memTotal uint64) ZramSwap {
	if memTotal == 0 {
		memTotal = fallbackMemTotal
	}
	return ZramSwap{
		DiskSize: alignDown(memTotal),
		MemLimit: alignDown(memTotal / 4),
	}
}

func (b LSPBudget) WithSwapPool(memTotal, pool uint64) LSPBudget {
	if pool == 0 || pool >= memTotal {
		return b
	}
	rest := memTotal - pool
	b.CgroupHigh = min(b.CgroupHigh, alignDown(rest*80/100))
	b.CgroupMax = min(b.CgroupMax, alignDown(rest*85/100))
	return b
}

func SwapHeader(pageSize int, deviceBytes uint64) []byte {
	if pageSize < 4096 || deviceBytes < 2*uint64(pageSize) {
		return nil
	}
	h := make([]byte, pageSize)
	binary.LittleEndian.PutUint32(h[1024:], 1)
	binary.LittleEndian.PutUint32(h[1028:], uint32(deviceBytes/uint64(pageSize)-1))
	copy(h[pageSize-10:], "SWAPSPACE2")
	return h
}
