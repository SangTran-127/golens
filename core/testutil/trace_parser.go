package testutil

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"golang.org/x/exp/trace"
)

const (
	MaxTraceFileSize  = 16 * 1024 * 1024
	MaxGoroutineLanes = 200
	MaxCausationLinks = 1000
	MaxSpansPerLane   = 2000
)

type TraceSpan struct {
	State      string `json:"state"`
	StartNs    int64  `json:"startNs"`
	EndNs      int64  `json:"endNs"`
	DurationNs int64  `json:"durationNs"`
	Reason     string `json:"reason,omitempty"`
	File       string `json:"file,omitempty"`
	Line       int    `json:"line,omitempty"`
	Function   string `json:"function,omitempty"`
}

type GoroutineTimelineLane struct {
	GoroutineID   uint64      `json:"goroutineId"`
	Name          string      `json:"name"`
	Spans         []TraceSpan `json:"spans"`
	TotalActiveNs int64       `json:"totalActiveNs"`
	TotalWaitNs   int64       `json:"totalWaitNs"`
	EventCount    int         `json:"eventCount"`
}

type CausationLink struct {
	FromGoroutine uint64 `json:"fromG"`
	ToGoroutine   uint64 `json:"toG"`
	TimestampNs   int64  `json:"timestampNs"`
	Reason        string `json:"reason,omitempty"`
	File          string `json:"file,omitempty"`
	Line          int    `json:"line,omitempty"`
	Function      string `json:"function,omitempty"`
}

type TraceResult struct {
	StartNs         int64                   `json:"startNs"`
	EndNs           int64                   `json:"endNs"`
	TotalDurationNs int64                   `json:"totalDurationNs"`
	TotalGoroutines int                     `json:"totalGoroutines"`
	Lanes           []GoroutineTimelineLane `json:"lanes"`
	CausationLinks  []CausationLink         `json:"causationLinks"`
	GCPeriods       []TraceSpan             `json:"gcPeriods,omitempty"`
	Truncated       bool                    `json:"truncated"`
}

type gState struct {
	id            uint64
	name          string
	curState      string
	curStartNs    int64
	curReason     string
	curFile       string
	curLine       int
	curFunc       string
	totalActiveNs int64
	totalWaitNs   int64
	eventCount    int
	spans         []TraceSpan
}

func (g *gState) transitionTo(newState string, ts int64, reason, file string, line int, fn string) {
	if g.curState != "" && ts > g.curStartNs {
		dur := ts - g.curStartNs
		switch g.curState {
		case "running":
			g.totalActiveNs += dur
		case "waiting":
			g.totalWaitNs += dur
		}

		n := len(g.spans)
		if n > 0 && g.spans[n-1].State == g.curState && g.spans[n-1].Reason == g.curReason {
			g.spans[n-1].EndNs = ts
			g.spans[n-1].DurationNs = ts - g.spans[n-1].StartNs
		} else if n < MaxSpansPerLane {
			g.spans = append(g.spans, TraceSpan{
				State:      g.curState,
				StartNs:    g.curStartNs,
				EndNs:      ts,
				DurationNs: dur,
				Reason:     g.curReason,
				File:       g.curFile,
				Line:       g.curLine,
				Function:   g.curFunc,
			})
		}
	}

	g.curState = newState
	g.curStartNs = ts
	g.curReason = reason
	if file != "" {
		g.curFile = file
		g.curLine = line
		g.curFunc = fn
	}
	g.eventCount++
}

func (g *gState) closeAt(ts int64) {
	if g.curState != "" && ts > g.curStartNs {
		dur := ts - g.curStartNs
		switch g.curState {
		case "running":
			g.totalActiveNs += dur
		case "waiting":
			g.totalWaitNs += dur
		}
		n := len(g.spans)
		if n > 0 && g.spans[n-1].State == g.curState && g.spans[n-1].Reason == g.curReason {
			g.spans[n-1].EndNs = ts
			g.spans[n-1].DurationNs = ts - g.spans[n-1].StartNs
		} else if n < MaxSpansPerLane {
			g.spans = append(g.spans, TraceSpan{
				State:      g.curState,
				StartNs:    g.curStartNs,
				EndNs:      ts,
				DurationNs: dur,
				Reason:     g.curReason,
				File:       g.curFile,
				Line:       g.curLine,
				Function:   g.curFunc,
			})
		}
		g.curState = ""
	}
}

func extractUserFrame(ev trace.Event) (file string, line int, fn string) {
	for fr := range ev.Stack().Frames() {
		if !strings.Contains(fr.File, "src/runtime/") && !strings.Contains(fr.File, "runtime/") {
			return fr.File, int(fr.Line), fr.Func
		}
		if file == "" {
			file = fr.File
			line = int(fr.Line)
			fn = fr.Func
		}
	}
	return file, line, fn
}

func shortFuncName(fn string) string {
	if idx := strings.LastIndex(fn, "/"); idx >= 0 {
		fn = fn[idx+1:]
	}
	return fn
}

func ParseGoTraceFile(tracePath string) (*TraceResult, error) {
	f, err := os.Open(tracePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if fi.Size() == 0 {
		return nil, errors.New("trace file is empty")
	}
	if fi.Size() > MaxTraceFileSize {
		return nil, fmt.Errorf("trace file size (%d bytes) exceeds 16MB limit", fi.Size())
	}

	limitedReader := io.LimitReader(f, MaxTraceFileSize+1)
	r, err := trace.NewReader(limitedReader)
	if err != nil {
		return nil, fmt.Errorf("failed to parse trace header: %w", err)
	}

	var (
		firstTs  int64 = -1
		lastTs   int64 = 0
		gMap           = make(map[uint64]*gState)
		links          = make([]CausationLink, 0, 128)
		gcRanges       = make([]TraceSpan, 0, 32)
		activeGC *TraceSpan
	)

	for {
		ev, err := r.ReadEvent()
		if err == io.EOF {
			break
		}
		if err != nil {
			if len(gMap) > 0 {
				break
			}
			return nil, fmt.Errorf("trace read error: %w", err)
		}

		ts := int64(ev.Time())
		if firstTs == -1 && ts > 0 {
			firstTs = ts
		}
		if ts > lastTs {
			lastTs = ts
		}

		switch ev.Kind() {
		case trace.EventStateTransition:
			st := ev.StateTransition()
			if st.Resource.Kind == trace.ResourceGoroutine {
				goid := uint64(st.Resource.Goroutine())
				g, exists := gMap[goid]
				if !exists {
					g = &gState{
						id:         goid,
						name:       fmt.Sprintf("G%d", goid),
						curStartNs: ts,
					}
					gMap[goid] = g
				}

				from, to := st.Goroutine()
				file, line, fn := extractUserFrame(ev)
				if fn != "" && (g.name == "" || strings.HasPrefix(g.name, "G")) {
					g.name = fmt.Sprintf("G%d (%s)", goid, shortFuncName(fn))
				}

				var targetState string
				switch to {
				case trace.GoRunning:
					targetState = "running"
				case trace.GoRunnable:
					targetState = "runnable"
				case trace.GoWaiting:
					targetState = "waiting"
				case trace.GoSyscall:
					targetState = "syscall"
				case trace.GoNotExist:
					targetState = ""
				default:
					targetState = ""
				}

				if from == trace.GoWaiting && to == trace.GoRunnable {
					fromG := uint64(ev.Goroutine())
					if fromG != 0 && fromG != goid && len(links) < MaxCausationLinks {
						links = append(links, CausationLink{
							FromGoroutine: fromG,
							ToGoroutine:   goid,
							TimestampNs:   ts,
							Reason:        st.Reason,
							File:          file,
							Line:          line,
							Function:      fn,
						})
					}
				}

				g.transitionTo(targetState, ts, st.Reason, file, line, fn)
			}

		case trace.EventRangeBegin, trace.EventRangeActive:
			rng := ev.Range()
			if strings.HasPrefix(rng.Name, "stop-the-world") || strings.HasPrefix(rng.Name, "GC") {
				activeGC = &TraceSpan{
					State:   "gc",
					StartNs: ts,
					Reason:  rng.Name,
				}
			}

		case trace.EventRangeEnd:
			rng := ev.Range()
			if activeGC != nil && (strings.HasPrefix(rng.Name, "stop-the-world") || strings.HasPrefix(rng.Name, "GC")) {
				activeGC.EndNs = ts
				activeGC.DurationNs = ts - activeGC.StartNs
				gcRanges = append(gcRanges, *activeGC)
				activeGC = nil
			}
		}
	}

	for _, g := range gMap {
		g.closeAt(lastTs)
	}

	allLanes := make([]*gState, 0, len(gMap))
	for _, g := range gMap {
		allLanes = append(allLanes, g)
	}

	sort.Slice(allLanes, func(i, j int) bool {
		if allLanes[i].totalActiveNs != allLanes[j].totalActiveNs {
			return allLanes[i].totalActiveNs > allLanes[j].totalActiveNs
		}
		if allLanes[i].eventCount != allLanes[j].eventCount {
			return allLanes[i].eventCount > allLanes[j].eventCount
		}
		return allLanes[i].id < allLanes[j].id
	})

	totalGoroutines := len(allLanes)
	truncated := false
	if len(allLanes) > MaxGoroutineLanes {
		allLanes = allLanes[:MaxGoroutineLanes]
		truncated = true
	}

	topIDs := make(map[uint64]bool, len(allLanes))
	resultLanes := make([]GoroutineTimelineLane, len(allLanes))
	for i, g := range allLanes {
		topIDs[g.id] = true
		resultLanes[i] = GoroutineTimelineLane{
			GoroutineID:   g.id,
			Name:          g.name,
			Spans:         g.spans,
			TotalActiveNs: g.totalActiveNs,
			TotalWaitNs:   g.totalWaitNs,
			EventCount:    g.eventCount,
		}
	}

	filteredLinks := make([]CausationLink, 0, len(links))
	for _, link := range links {
		if topIDs[link.ToGoroutine] {
			filteredLinks = append(filteredLinks, link)
		}
	}

	if firstTs == -1 {
		firstTs = 0
	}

	return &TraceResult{
		StartNs:         firstTs,
		EndNs:           lastTs,
		TotalDurationNs: lastTs - firstTs,
		TotalGoroutines: totalGoroutines,
		Lanes:           resultLanes,
		CausationLinks:  filteredLinks,
		GCPeriods:       gcRanges,
		Truncated:       truncated,
	}, nil
}
