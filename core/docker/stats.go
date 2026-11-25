package docker

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const StatsTopic = "services.docker.stats"

var statsInterval = time.Second

type StatsEvent struct {
	Stream           int64   `json:"stream"`
	ID               string  `json:"id"`
	CPUPercent       float64 `json:"cpuPercent"`
	MemoryBytes      int64   `json:"memoryBytes"`
	MemoryLimitBytes int64   `json:"memoryLimitBytes"`
	Closed           bool    `json:"closed"`
	Error            string  `json:"error,omitempty"`
}

type apiCPUStats struct {
	CPUUsage struct {
		TotalUsage  uint64   `json:"total_usage"`
		PercpuUsage []uint64 `json:"percpu_usage"`
	} `json:"cpu_usage"`
	SystemUsage uint64 `json:"system_cpu_usage"`
	OnlineCPUs  uint32 `json:"online_cpus"`
}

type apiStats struct {
	CPUStats    apiCPUStats `json:"cpu_stats"`
	PreCPUStats apiCPUStats `json:"precpu_stats"`
	MemoryStats struct {
		Usage uint64            `json:"usage"`
		Limit uint64            `json:"limit"`
		Stats map[string]uint64 `json:"stats"`
	} `json:"memory_stats"`
}

func cpuPercent(cur, prev apiCPUStats) float64 {
	if cur.CPUUsage.TotalUsage < prev.CPUUsage.TotalUsage || cur.SystemUsage <= prev.SystemUsage {
		return 0
	}
	cpuDelta := float64(cur.CPUUsage.TotalUsage - prev.CPUUsage.TotalUsage)
	systemDelta := float64(cur.SystemUsage - prev.SystemUsage)
	online := float64(cur.OnlineCPUs)
	if online == 0 {
		online = float64(len(cur.CPUUsage.PercpuUsage))
	}
	return cpuDelta / systemDelta * online * 100
}

func memoryUsage(s apiStats) int64 {
	usage := s.MemoryStats.Usage
	for _, key := range []string{"total_inactive_file", "inactive_file", "cache"} {
		if v, ok := s.MemoryStats.Stats[key]; ok {
			if v < usage {
				return int64(usage - v)
			}
			return int64(usage)
		}
	}
	return int64(usage)
}

func statsSample(s apiStats, prev *apiCPUStats) (cpu float64, mem, limit int64) {
	pre := s.PreCPUStats
	if pre.SystemUsage == 0 {
		if prev == nil {
			pre = s.CPUStats
		} else {
			pre = *prev
		}
	}
	return cpuPercent(s.CPUStats, pre), memoryUsage(s), int64(s.MemoryStats.Limit)
}

var statsStreams struct {
	sync.Mutex
	next int64
	m    map[int64]context.CancelFunc
}

func emitStats(ev StatsEvent) {
	if data, err := json.Marshal(ev); err == nil {
		emitStatus(StatsTopic, string(data))
	}
}

func StatsStart(id string) int64 {
	id = strings.TrimSpace(id)
	if id == "" {
		return 0
	}
	ctx, cancel := withGeneration(context.Background())
	statsStreams.Lock()
	if statsStreams.m == nil {
		statsStreams.m = map[int64]context.CancelFunc{}
	}
	statsStreams.next++
	stream := statsStreams.next
	statsStreams.m[stream] = cancel
	statsStreams.Unlock()
	go func() {
		err := followStats(ctx, id, func(ev StatsEvent) {
			ev.Stream, ev.ID = stream, id
			statsStreams.Lock()
			_, open := statsStreams.m[stream]
			statsStreams.Unlock()
			if open && ctx.Err() == nil {
				emitStats(ev)
			}
		})
		statsStreams.Lock()
		_, open := statsStreams.m[stream]
		delete(statsStreams.m, stream)
		statsStreams.Unlock()
		cancel()
		if !open {
			return
		}
		ev := StatsEvent{Stream: stream, ID: id, Closed: true}
		if err != nil {
			ev.Error = plainError(err)
		}
		emitStats(ev)
	}()
	return stream
}

func StatsStop(stream int64) {
	statsStreams.Lock()
	cancel := statsStreams.m[stream]
	delete(statsStreams.m, stream)
	statsStreams.Unlock()
	if cancel != nil {
		cancel()
	}
}

func openStatsStreams() int {
	statsStreams.Lock()
	defer statsStreams.Unlock()
	return len(statsStreams.m)
}

func followStats(ctx context.Context, id string, emit func(StatsEvent)) error {
	connectCtx, cancel := context.WithTimeout(ctx, engineTimeout(snapshotTimeout))
	c, err := engineClient(connectCtx)
	cancel()
	if err != nil {
		return err
	}
	resp, err := c.Do(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/stats", url.Values{"stream": {"1"}}, nil)
	if err != nil {
		if ctx.Err() != nil {
			return nil
		}
		forgetClient(err)
		return err
	}
	defer resp.Body.Close()
	latest := make(chan StatsEvent, 1)
	readErr := make(chan error, 1)
	go func() {
		dec := json.NewDecoder(resp.Body)
		var prev *apiCPUStats
		for {
			var s apiStats
			if err := dec.Decode(&s); err != nil {
				readErr <- eofIsNil(err)
				return
			}
			cpu, mem, limit := statsSample(s, prev)
			cur := s.CPUStats
			prev = &cur
			ev := StatsEvent{CPUPercent: cpu, MemoryBytes: mem, MemoryLimitBytes: limit}
			select {
			case latest <- ev:
			default:
				select {
				case <-latest:
				default:
				}
				latest <- ev
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case ev := <-latest:
			emit(ev)
			t := time.NewTimer(statsInterval)
			select {
			case <-ctx.Done():
				t.Stop()
				return nil
			case <-t.C:
			}
		case err := <-readErr:
			select {
			case ev := <-latest:
				emit(ev)
			default:
			}
			if ctx.Err() != nil {
				return nil
			}
			if err != nil {
				return c.wrap(err, time.Time{})
			}
			return nil
		}
	}
}
