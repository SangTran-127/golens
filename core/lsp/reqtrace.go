package lsp

import (
	"encoding/json"
	"strconv"
	"sync"
	"time"

	"golens/core/bridge"
)

type tracedRequest struct {
	method string
	start  time.Time
}

type requestTracer struct {
	mu       sync.Mutex
	inFlight map[int64]tracedRequest
	change   map[string]time.Time
}

var reqTrace = &requestTracer{inFlight: map[int64]tracedRequest{}, change: map[string]time.Time{}}

func (t *requestTracer) begin(id int64, method string) {
	if !traceLSP {
		return
	}
	t.mu.Lock()
	t.inFlight[id] = tracedRequest{method, time.Now()}
	n := len(t.inFlight)
	t.mu.Unlock()
	bridge.Debug("[lspreq] send " + method + " id=" + strconv.FormatInt(id, 10) + " inflight=" + strconv.Itoa(n))
}

func (t *requestTracer) beginSwift(msg []byte) {
	if !traceLSP {
		return
	}
	var head struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if json.Unmarshal(msg, &head) != nil || head.Method == "" {
		return
	}
	if id, ok := parseID(head.ID); ok {
		t.begin(id, head.Method)
	}
}

func (t *requestTracer) end(id int64, outcome string, bytes int) {
	if !traceLSP {
		return
	}
	t.mu.Lock()
	r, ok := t.inFlight[id]
	delete(t.inFlight, id)
	n := len(t.inFlight)
	t.mu.Unlock()
	if !ok {
		return
	}
	ms := float64(time.Since(r.start).Microseconds()) / 1000
	bridge.Debug("[lspreq] done " + r.method + " id=" + strconv.FormatInt(id, 10) + " ms=" + strconv.FormatFloat(ms, 'f', 1, 64) +
		" outcome=" + outcome + " bytes=" + strconv.Itoa(bytes) + " inflight=" + strconv.Itoa(n))
}

func (t *requestTracer) response(id int64, env *envelope, bytes int) {
	if !traceLSP {
		return
	}
	outcome := "ok"
	if env.Error != nil {
		switch env.Error.Code {
		case requestCancelled:
			outcome = "cancelled"
		case contentModified:
			outcome = "modified"
		default:
			outcome = "error"
		}
	}
	t.end(id, outcome, bytes)
}

func (t *requestTracer) changeSent(uri string, version int32, changes int) {
	if !traceLSP {
		return
	}
	t.mu.Lock()
	t.change[uri] = time.Now()
	t.mu.Unlock()
	bridge.Debug("[lspreq] didChange v=" + strconv.Itoa(int(version)) + " changes=" + strconv.Itoa(changes))
}

func (t *requestTracer) diagnostics(uri string, version *int32, count int) {
	if !traceLSP {
		return
	}
	t.mu.Lock()
	sent, ok := t.change[uri]
	t.mu.Unlock()
	since := "-"
	if ok {
		since = strconv.FormatFloat(float64(time.Since(sent).Microseconds())/1000, 'f', 1, 64)
	}
	v := "-"
	if version != nil {
		v = strconv.Itoa(int(*version))
	}
	bridge.Debug("[lspreq] diagnostics " + uriToPath(uri) + " v=" + v + " n=" + strconv.Itoa(count) + " sinceChange=" + since)
}
