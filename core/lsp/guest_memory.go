package lsp

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/cmd/golens-vm-agent/guestres"
)

const (
	memoryLimitMoveBytes   = 16 << 20
	liveMemoryLimitMinimum = 2
)

var guestMemory struct {
	mu      sync.Mutex
	sample  guestres.MemorySample
	ctl     *guestres.StepController
	step    uint64
	ceiling uint64
}

func SetGuestMemoryStep(step, ceiling uint64) {
	guestMemory.mu.Lock()
	guestMemory.step, guestMemory.ceiling = step, ceiling
	guestMemory.mu.Unlock()
}

func currentGuestStep() (step, ceiling uint64) {
	guestMemory.mu.Lock()
	defer guestMemory.mu.Unlock()
	return guestMemory.step, guestMemory.ceiling
}

func parseGuestMemorySample(f []string, used, limit int64) (guestres.MemorySample, bool) {
	var v [4]uint64
	for i := range v {
		n, err := strconv.ParseUint(f[i], 10, 64)
		if err != nil {
			return guestres.MemorySample{}, false
		}
		v[i] = n
	}
	if v[0] == 0 {
		return guestres.MemorySample{}, false
	}
	return guestres.MemorySample{
		At:         time.Now(),
		MemTotal:   guestres.UsableMemory(v[0]<<10, v[1]),
		PoolUsed:   uint64(used),
		PoolLimit:  uint64(limit),
		LSPCurrent: v[2],
		LSPSwap:    v[3],
	}, true
}

func recordGuestMemory(s guestres.MemorySample) {
	guestMemory.mu.Lock()
	guestMemory.sample = s
	guestMemory.mu.Unlock()
	followGuestGoplsMemoryLimit(s.MemTotal)
}

func GuestMemoryStepTarget(current, base, ceiling uint64, idle bool) uint64 {
	guestMemory.mu.Lock()
	if guestMemory.ctl == nil {
		guestMemory.ctl = guestres.NewStepController()
	}
	s := guestMemory.sample
	ctl := guestMemory.ctl
	ctl.GrowReason = ""
	target := ctl.Target(current, base, ceiling, idle, s, time.Now())
	grew := ctl.GrowReason
	guestMemory.mu.Unlock()
	if target != current {
		var reason string
		switch {
		case target > current && grew != "":
			reason = grew
		case target > current:
			reason = "activity resumed"
		case idle:
			reason = "app inactive"
		default:
			reason = "gopls fits the smaller step"
		}
		bridge.Debug(fmt.Sprintf("guest memory step %d -> %d MiB (%s; gopls %d MiB with %d MiB swapped, pool %d of %d MiB)",
			current>>20, target>>20, reason, s.LSPCurrent>>20, s.LSPSwap>>20, s.PoolUsed>>20, s.PoolLimit>>20))
	}
	return target
}

func followGuestGoplsMemoryLimit(memTotal uint64) {
	limit := goplsMemoryLimitForTotal(memTotal)
	old := remoteGoplsMemoryLimit.Load()
	if limit <= 0 || !memoryLimitMoved(old, limit) {
		return
	}
	remoteGoplsMemoryLimit.Store(limit)
	srv := current()
	if srv == nil || !srv.isRemote {
		return
	}
	if !srv.liveMemoryLimit {
		bridge.Debug(fmt.Sprintf("gopls memoryLimit %d MiB for a %d MiB guest takes effect when gopls restarts; this gopls build cannot change it live", limit>>20, memTotal>>20))
		return
	}
	bridge.Debug(fmt.Sprintf("gopls memoryLimit %d MiB for a %d MiB guest", limit>>20, memTotal>>20))
	notifySettingsChanged()
}

func memoryLimitMoved(old, limit int64) bool {
	d := old - limit
	if d < 0 {
		d = -d
	}
	return old <= 0 || d >= memoryLimitMoveBytes
}

func goplsAppliesMemoryLimitLive(initResult json.RawMessage) bool {
	var r struct {
		ServerInfo struct {
			Version string `json:"version"`
		} `json:"serverInfo"`
	}
	if json.Unmarshal(initResult, &r) != nil {
		return false
	}
	v := r.ServerInfo.Version
	var info struct{ Version string }
	if json.Unmarshal([]byte(v), &info) == nil && info.Version != "" {
		v = info.Version
	}
	const marker = "-golens."
	i := strings.LastIndex(v, marker)
	if i < 0 {
		return false
	}
	n, err := strconv.Atoi(v[i+len(marker):])
	return err == nil && n >= liveMemoryLimitMinimum
}
