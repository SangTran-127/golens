package kube

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const LogsTopic = "services.kube.logs"

const (
	maxLogLine    = 64 << 10
	maxBatchLines = 2000
	maxBatchBytes = 1 << 20
)

var logsFlushDelay = 100 * time.Millisecond

type LogLine struct {
	Text   string `json:"text"`
	Stderr bool   `json:"stderr"`
	Prefix string `json:"prefix"`
}

type LogsEvent struct {
	Stream  int64     `json:"stream"`
	Lines   []LogLine `json:"lines"`
	Dropped int       `json:"dropped,omitempty"`
	Closed  bool      `json:"closed,omitempty"`
	Reason  string    `json:"reason,omitempty"`
	Error   *Error    `json:"error,omitempty"`
}

type LogsOptions struct {
	Context   string
	Namespace string
	Pod       string
	Container string
	Previous  bool
	Tail      int
}

type logBatcher struct {
	ctx     context.Context
	stream  int64
	mu      sync.Mutex
	lines   []LogLine
	size    int
	dropped int
	timer   *time.Timer
}

func (b *logBatcher) add(text string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, LogLine{Text: text})
	b.size += len(text)
	for len(b.lines) > maxBatchLines || b.size > maxBatchBytes {
		b.size -= len(b.lines[0].Text)
		b.lines = b.lines[1:]
		b.dropped++
	}
	if b.timer == nil {
		b.timer = time.AfterFunc(logsFlushDelay, b.flush)
	}
}

func (b *logBatcher) flush() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	lines, dropped := b.lines, b.dropped
	b.lines, b.size, b.dropped = nil, 0, 0
	if b.ctx.Err() != nil || (len(lines) == 0 && dropped == 0) {
		return
	}
	emitLogs(LogsEvent{Stream: b.stream, Lines: lines, Dropped: dropped})
}

func emitLogs(ev LogsEvent) {
	if ev.Lines == nil {
		ev.Lines = []LogLine{}
	}
	if data, err := json.Marshal(ev); err == nil {
		emitStatus(LogsTopic, string(data))
	}
}

var logStreams struct {
	sync.Mutex
	next int64
	m    map[int64]context.CancelFunc
}

func LogsOpen(o LogsOptions) int64 {
	if o.Pod = strings.TrimSpace(o.Pod); o.Pod == "" {
		return 0
	}
	o.Context, o.Namespace = contextDefaults(o.Context, o.Namespace)
	ctx, cancel := context.WithCancel(context.Background())
	logStreams.Lock()
	if logStreams.m == nil {
		logStreams.m = map[int64]context.CancelFunc{}
	}
	logStreams.next++
	id := logStreams.next
	logStreams.m[id] = cancel
	logStreams.Unlock()
	go func() {
		b := &logBatcher{ctx: ctx, stream: id}
		reason, err := followPodLogs(ctx, o, b.add)
		b.flush()
		logStreams.Lock()
		_, open := logStreams.m[id]
		delete(logStreams.m, id)
		logStreams.Unlock()
		cancel()
		if !open {
			releaseClientsIfIdle()
			return
		}
		ev := LogsEvent{Stream: id, Closed: true, Reason: reason}
		if err != nil {
			ev.Reason, ev.Error = "error", asError(err)
		}
		emitLogs(ev)
		releaseClientsIfIdle()
	}()
	return id
}

func LogsClose(id int64) {
	logStreams.Lock()
	cancel := logStreams.m[id]
	delete(logStreams.m, id)
	logStreams.Unlock()
	if cancel != nil {
		cancel()
	}
}

func releaseClientsIfIdle() {
	watches.Lock()
	idle := watches.set == nil
	watches.Unlock()
	logStreams.Lock()
	idle = idle && len(logStreams.m) == 0
	logStreams.Unlock()
	if idle {
		closeClients()
	}
}

func logsRequest(o LogsOptions, q url.Values) request {
	return request{
		method: http.MethodGet, query: q, verb: "get", resource: "pods/log", namespace: o.Namespace,
		path: "/api/v1/namespaces/" + url.PathEscape(o.Namespace) + "/pods/" + url.PathEscape(o.Pod) + "/log",
	}
}

func followPodLogs(ctx context.Context, o LogsOptions, emit func(string)) (string, error) {
	c, err := clientFor(o.Context)
	if err != nil {
		return "", err
	}
	q := url.Values{"timestamps": {"true"}}
	if o.Container != "" {
		q.Set("container", o.Container)
	}
	if o.Tail >= 0 {
		q.Set("tailLines", strconv.Itoa(o.Tail))
	}
	if o.Previous {
		q.Set("previous", "true")
		_, err := streamPodLogs(ctx, c, logsRequest(o, q), time.Time{}, emit)
		if ctx.Err() != nil {
			return "", nil
		}
		return "ended", err
	}
	q.Set("follow", "true")
	var last time.Time
	for attempt, first := 0, true; ; first = false {
		got, err := streamPodLogs(ctx, c, logsRequest(o, q), last, emit)
		if ctx.Err() != nil {
			return "", nil
		}
		if !got.IsZero() {
			last, attempt = got, 0
		}
		if err != nil {
			e := asError(err)
			switch {
			case e.Kind == KindNotFound:
				return "removed", nil
			case first || !retryable(e) && e.status != http.StatusBadRequest:
				return "", err
			}
		} else if reason := podEnded(ctx, c, o); reason != "" {
			return reason, nil
		}
		q.Del("tailLines")
		if !last.IsZero() {
			q.Set("sinceTime", last.UTC().Format(time.RFC3339))
		}
		delay := reconnectDelays[min(attempt, len(reconnectDelays)-1)]
		attempt++
		select {
		case <-ctx.Done():
			return "", nil
		case <-time.After(delay):
		}
	}
}

func podEnded(ctx context.Context, c *client, o LogsOptions) string {
	var p apiPod
	err := c.getJSON(ctx, request{
		path: "/api/v1/namespaces/" + url.PathEscape(o.Namespace) + "/pods/" + url.PathEscape(o.Pod),
		verb: "get", resource: "pods", namespace: o.Namespace,
	}, &p)
	switch {
	case err != nil:
		if asError(err).Kind == KindNotFound {
			return "removed"
		}
		return ""
	case p.Status.Phase == "Succeeded", p.Status.Phase == "Failed":
		return "ended"
	}
	return ""
}

func streamPodLogs(ctx context.Context, c *client, r request, after time.Time, emit func(string)) (time.Time, error) {
	var last time.Time
	resp, cancel, err := c.stream(ctx, r)
	if err != nil {
		return last, err
	}
	defer cancel()
	defer resp.Body.Close()
	br := bufio.NewReaderSize(resp.Body, 32<<10)
	for {
		line, err := readLine(br)
		if line != "" || err == nil {
			ts, text := splitTimestamp(line)
			if ts.IsZero() || ts.After(after) {
				emit(text)
				if !ts.IsZero() {
					last = ts
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || ctx.Err() != nil {
				return last, nil
			}
			return last, c.bodyError(ctx, err)
		}
	}
}

func readLine(br *bufio.Reader) (string, error) {
	var buf []byte
	over := false
	for {
		chunk, err := br.ReadSlice('\n')
		if room := maxLogLine - len(buf); len(chunk) > room {
			buf = append(buf, chunk[:room]...)
			over = true
		} else {
			buf = append(buf, chunk...)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		text := strings.TrimRight(string(buf), "\r\n")
		if over {
			text += "…"
		}
		return text, err
	}
}

func splitTimestamp(line string) (time.Time, string) {
	head, rest, ok := strings.Cut(line, " ")
	if !ok {
		head, rest = line, ""
	}
	t, err := time.Parse(time.RFC3339Nano, head)
	if err != nil {
		return time.Time{}, line
	}
	return t, rest
}
