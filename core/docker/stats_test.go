package docker

import (
	"encoding/json"
	"math"
	"net/http"
	"sync"
	"testing"
	"time"
)

func statsJSON(t *testing.T, raw string) apiStats {
	t.Helper()
	var s apiStats
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestStatsMathCgroupV2(t *testing.T) {
	s := statsJSON(t, `{"cpu_stats":{"cpu_usage":{"total_usage":400000000},"system_cpu_usage":20000000000,"online_cpus":4},
	"precpu_stats":{"cpu_usage":{"total_usage":200000000},"system_cpu_usage":10000000000,"online_cpus":4},
	"memory_stats":{"usage":104857600,"limit":8221675520,"stats":{"inactive_file":31457280,"anon":73400320,"file":31457280}}}`)
	cpu, mem, limit := statsSample(s, nil)
	if math.Abs(cpu-8) > 1e-9 || mem != 73400320 || limit != 8221675520 {
		t.Fatalf("v2 sample = %v %d %d", cpu, mem, limit)
	}
}

func TestStatsMathCgroupV1(t *testing.T) {
	s := statsJSON(t, `{"cpu_stats":{"cpu_usage":{"total_usage":3000000000,"percpu_usage":[1500000000,1500000000]},"system_cpu_usage":50000000000},
	"precpu_stats":{"cpu_usage":{"total_usage":2000000000},"system_cpu_usage":40000000000},
	"memory_stats":{"usage":104857600,"limit":2147483648,"stats":{"total_inactive_file":10485760,"cache":41943040}}}`)
	cpu, mem, limit := statsSample(s, nil)
	if math.Abs(cpu-20) > 1e-9 || mem != 94371840 || limit != 2147483648 {
		t.Fatalf("v1 sample = %v %d %d", cpu, mem, limit)
	}
	s = statsJSON(t, `{"memory_stats":{"usage":104857600,"stats":{"cache":41943040}}}`)
	if _, mem, _ := statsSample(s, nil); mem != 62914560 {
		t.Fatalf("v1 sample with cache only = %d", mem)
	}
	s = statsJSON(t, `{"memory_stats":{"usage":1000,"stats":{"inactive_file":5000}}}`)
	if _, mem, _ := statsSample(s, nil); mem != 1000 {
		t.Fatalf("cache above usage = %d", mem)
	}
}

func TestStatsFirstSampleWithoutPreviousCPU(t *testing.T) {
	first := statsJSON(t, `{"cpu_stats":{"cpu_usage":{"total_usage":900000000000},"system_cpu_usage":800000000000000,"online_cpus":8},
	"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":0}}`)
	if cpu, _, _ := statsSample(first, nil); cpu != 0 {
		t.Fatalf("first sample cpu = %v", cpu)
	}
	prev := first.CPUStats
	next := statsJSON(t, `{"cpu_stats":{"cpu_usage":{"total_usage":900100000000},"system_cpu_usage":800010000000000,"online_cpus":8},
	"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":0}}`)
	if cpu, _, _ := statsSample(next, &prev); math.Abs(cpu-8) > 1e-9 {
		t.Fatalf("second sample against our own previous = %v", cpu)
	}
}

type statsRecord struct {
	at time.Time
	ev StatsEvent
}

func recordStats(t *testing.T) func() []statsRecord {
	var mu sync.Mutex
	var out []statsRecord
	old := emitStatus
	emitStatus = func(topic, payload string) {
		if topic != StatsTopic {
			return
		}
		var ev StatsEvent
		if err := json.Unmarshal([]byte(payload), &ev); err != nil {
			t.Error(err)
		}
		mu.Lock()
		out = append(out, statsRecord{at: time.Now(), ev: ev})
		mu.Unlock()
	}
	t.Cleanup(func() { emitStatus = old })
	return func() []statsRecord {
		mu.Lock()
		defer mu.Unlock()
		return append([]statsRecord(nil), out...)
	}
}

func waitStats(t *testing.T, get func() []statsRecord, done func([]statsRecord) bool) []statsRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := get(); done(got) {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	got := get()
	t.Fatalf("stats events never finished: %+v", got)
	return got
}

func statsEngine(t *testing.T, samples int, every time.Duration) (*fakeEngine, chan struct{}) {
	f := newFakeEngine(t, nil)
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	resetServicesState(t)
	ended := make(chan struct{}, 4)
	f.Handle("GET /v1.47/containers/{id}/stats", func(w http.ResponseWriter, r *http.Request) {
		defer func() { ended <- struct{}{} }()
		if r.PathValue("id") != "web" || r.URL.Query().Get("stream") != "1" {
			notFound(w, "container: "+r.PathValue("id"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		total, system := uint64(0), uint64(0)
		for i := 1; samples < 0 || i <= samples; i++ {
			pre := map[string]any{"cpu_usage": map[string]any{"total_usage": total}, "system_cpu_usage": system, "online_cpus": 2}
			total += 10000000
			system += 1000000000
			enc.Encode(map[string]any{
				"cpu_stats":    map[string]any{"cpu_usage": map[string]any{"total_usage": total}, "system_cpu_usage": system, "online_cpus": 2},
				"precpu_stats": pre,
				"memory_stats": map[string]any{"usage": 1000 * i, "limit": 8000, "stats": map[string]any{"inactive_file": 100}},
			})
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(every):
			}
		}
	})
	return f, ended
}

func TestStatsStreamThrottlesAndCloses(t *testing.T) {
	old := statsInterval
	statsInterval = 150 * time.Millisecond
	t.Cleanup(func() { statsInterval = old })
	get := recordStats(t)
	statsEngine(t, 12, 25*time.Millisecond)
	stream := StatsStart("web")
	if stream == 0 || StatsStart("  ") != 0 {
		t.Fatal("stream ids")
	}
	got := waitStats(t, get, func(r []statsRecord) bool { return len(r) > 0 && r[len(r)-1].ev.Closed })
	samples := got[:len(got)-1]
	if len(samples) < 2 || len(samples) > 4 {
		t.Fatalf("12 samples over 300 ms at one per 150 ms gave %d events: %+v", len(samples), got)
	}
	for i := 1; i < len(samples); i++ {
		if gap := samples[i].at.Sub(samples[i-1].at); gap < statsInterval-10*time.Millisecond {
			t.Fatalf("events %d and %d only %v apart", i-1, i, gap)
		}
	}
	for _, r := range samples {
		if r.ev.Stream != stream || r.ev.ID != "web" || r.ev.MemoryLimitBytes != 8000 || r.ev.Closed {
			t.Fatalf("sample = %+v", r.ev)
		}
	}
	if samples[0].ev.MemoryBytes != 900 || samples[len(samples)-1].ev.MemoryBytes != 11900 {
		t.Fatalf("first sample and the latest one should be sent: %+v", samples)
	}
	if math.Abs(samples[len(samples)-1].ev.CPUPercent-2) > 1e-9 {
		t.Fatalf("cpu = %v", samples[len(samples)-1].ev.CPUPercent)
	}
	if last := got[len(got)-1].ev; last.Stream != stream || last.ID != "web" || last.Error != "" {
		t.Fatalf("closed event = %+v", last)
	}
	if openStatsStreams() != 0 {
		t.Fatal("stream still registered")
	}
}

func TestStatsStopEndsTheRequestWithoutEvents(t *testing.T) {
	get := recordStats(t)
	_, ended := statsEngine(t, -1, 20*time.Millisecond)
	stream := StatsStart("web")
	waitStats(t, get, func(r []statsRecord) bool { return len(r) > 0 })
	StatsStop(stream)
	select {
	case <-ended:
	case <-time.After(time.Second):
		t.Fatal("the engine request stayed open after Stop")
	}
	n := len(get())
	time.Sleep(100 * time.Millisecond)
	if after := get(); len(after) != n || after[len(after)-1].ev.Closed {
		t.Fatalf("events after Stop: %+v", after[n-1:])
	}
}

func TestStatsMissingContainerClosesWithError(t *testing.T) {
	get := recordStats(t)
	statsEngine(t, 1, time.Millisecond)
	stream := StatsStart("gone")
	got := waitStats(t, get, func(r []statsRecord) bool { return len(r) > 0 && r[len(r)-1].ev.Closed })
	if len(got) != 1 || got[0].ev.Stream != stream || got[0].ev.Error != "No such container: gone." {
		t.Fatalf("events = %+v", got)
	}
}
