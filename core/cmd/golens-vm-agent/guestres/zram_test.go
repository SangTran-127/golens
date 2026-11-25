package guestres

import (
	"encoding/binary"
	"testing"
)

func TestZramSwapForA512MBGuest(t *testing.T) {
	z := ZramSwapFor(482760 * 1024)
	if z.DiskSize>>20 != 471 {
		t.Errorf("disk size = %d MiB, want 471", z.DiskSize>>20)
	}
	if z.MemLimit>>20 != 117 {
		t.Errorf("compressed pool limit = %d MiB, want 117", z.MemLimit>>20)
	}
	if z.DiskSize%mib != 0 || z.MemLimit%mib != 0 {
		t.Errorf("sizes not MiB aligned: %+v", z)
	}
}

func TestZramSwapForUnknownMemoryUsesTheFallback(t *testing.T) {
	if got, want := ZramSwapFor(0), ZramSwapFor(fallbackMemTotal); got != want {
		t.Errorf("ZramSwapFor(0) = %+v, want %+v", got, want)
	}
}

func TestLSPBudgetLeavesRoomForTheSwapPool(t *testing.T) {
	memTotal := uint64(482760 * 1024)
	pool := ZramSwapFor(memTotal).MemLimit
	b := LSPBudgetFor(memTotal).WithSwapPool(memTotal, pool)
	if b.CgroupMax+pool > memTotal*90/100 {
		t.Errorf("memory.max %d MiB plus the %d MiB pool exceeds 90%% of the guest", b.CgroupMax>>20, pool>>20)
	}
	if b.CgroupHigh >= b.CgroupMax {
		t.Errorf("memory.high %d MiB is not below memory.max %d MiB", b.CgroupHigh>>20, b.CgroupMax>>20)
	}
	if b.CgroupHigh>>20 != 283 || b.CgroupMax>>20 != 301 {
		t.Errorf("512 MB guest budget = high %d MiB, max %d MiB, want 283 and 301", b.CgroupHigh>>20, b.CgroupMax>>20)
	}
	if b.GoMemLimit != LSPBudgetFor(memTotal).GoMemLimit {
		t.Error("the swap pool changed GOMEMLIMIT")
	}
	if got := LSPBudgetFor(memTotal).WithSwapPool(memTotal, 0); got != LSPBudgetFor(memTotal) {
		t.Errorf("no pool changed the budget: %+v", got)
	}
}

func TestSwapHeaderMatchesMkswapVersion1(t *testing.T) {
	h := SwapHeader(4096, 512<<20)
	if len(h) != 4096 {
		t.Fatalf("header is %d bytes, want one page", len(h))
	}
	if string(h[4096-10:]) != "SWAPSPACE2" {
		t.Errorf("signature = %q", h[4096-10:])
	}
	if v := binary.LittleEndian.Uint32(h[1024:]); v != 1 {
		t.Errorf("version = %d, want 1", v)
	}
	if last := binary.LittleEndian.Uint32(h[1028:]); last != 512<<20/4096-1 {
		t.Errorf("last page = %d, want %d", last, 512<<20/4096-1)
	}
	if bad := binary.LittleEndian.Uint32(h[1032:]); bad != 0 {
		t.Errorf("bad pages = %d, want 0", bad)
	}
}

func TestSwapHeaderRejectsATinyDevice(t *testing.T) {
	if SwapHeader(4096, 4096) != nil || SwapHeader(512, 1<<20) != nil {
		t.Error("header built for an unusable device")
	}
}
