package docker

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const LogsTopic = "services.docker.logs"

const (
	maxLogLine     = 64 << 10
	maxBatchLines  = 2000
	maxBatchBytes  = 1 << 20
	mediaMuxStream = "application/vnd.docker.multiplexed-stream"
	mediaRawStream = "application/vnd.docker.raw-stream"
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
	Error   string    `json:"error,omitempty"`
}

type lineSplitter struct {
	buf    []byte
	over   bool
	stderr bool
	emit   func(string, bool)
}

func (s *lineSplitter) write(p []byte) {
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		chunk := p
		if i >= 0 {
			chunk = p[:i]
		}
		if room := maxLogLine - len(s.buf); len(chunk) > room {
			s.buf = append(s.buf, chunk[:room]...)
			s.over = true
		} else {
			s.buf = append(s.buf, chunk...)
		}
		if i < 0 {
			return
		}
		s.flush()
		p = p[i+1:]
	}
}

func (s *lineSplitter) flush() {
	text := strings.TrimSuffix(string(s.buf), "\r")
	if s.over {
		text += "…"
	}
	s.buf, s.over = s.buf[:0], false
	s.emit(text, s.stderr)
}

func (s *lineSplitter) end() {
	if len(s.buf) > 0 || s.over {
		s.flush()
	}
}

func readLogStream(r io.Reader, mux bool, emit func(text string, stderr bool)) error {
	out := &lineSplitter{emit: emit}
	errOut := &lineSplitter{emit: emit, stderr: true}
	defer out.end()
	defer errOut.end()
	buf := make([]byte, 32<<10)
	if !mux {
		for {
			n, err := r.Read(buf)
			out.write(buf[:n])
			if err != nil {
				return eofIsNil(err)
			}
		}
	}
	var hdr [8]byte
	for {
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return eofIsNil(err)
		}
		s := out
		if hdr[0] == 2 || hdr[0] == 3 {
			s = errOut
		}
		for size := int(binary.BigEndian.Uint32(hdr[4:])); size > 0; {
			n, err := io.ReadFull(r, buf[:min(size, len(buf))])
			s.write(buf[:n])
			if err != nil {
				return eofIsNil(err)
			}
			size -= n
		}
	}
}

func eofIsNil(err error) error {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return nil
	}
	return err
}

func tailParam(tail int) string {
	if tail < 0 {
		return "all"
	}
	return strconv.Itoa(tail)
}

func streamContainerLogs(ctx context.Context, c *Client, id string, q url.Values, tty bool, emit func(string, bool)) error {
	resp, err := c.Do(ctx, http.MethodGet, "/containers/"+id+"/logs", q, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	mux := !tty
	switch resp.Header.Get("Content-Type") {
	case mediaMuxStream:
		mux = true
	case mediaRawStream:
		if compareAPIVersion(c.APIVersion, "1.42") >= 0 {
			mux = false
		}
	}
	if err := readLogStream(resp.Body, mux, emit); err != nil && ctx.Err() == nil {
		return c.wrap(err, time.Time{})
	}
	return nil
}

func sinceParam(startedAt string) string {
	t, err := time.Parse(time.RFC3339Nano, startedAt)
	if err != nil || t.Year() < 2000 {
		return ""
	}
	return fmt.Sprintf("%d.%09d", t.Unix(), t.Nanosecond())
}

func waitSignal(ctx context.Context, sig chan string, timeout time.Duration) (removed, done bool) {
	var after <-chan time.Time
	if timeout > 0 {
		t := time.NewTimer(timeout)
		defer t.Stop()
		after = t.C
	}
	select {
	case <-ctx.Done():
		return false, true
	case s := <-sig:
		return s == signalRemoved, false
	case <-after:
		return false, false
	}
}

func followContainer(ctx context.Context, c *Client, ref string, tail int, prefixed bool, emit func(LogLine)) error {
	in, err := inspectContainer(ctx, c, ref)
	if isNotFound(err) || ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return err
	}
	sig, unsubscribe := subscribeContainer(in.ID)
	defer unsubscribe()
	prefix := ""
	if prefixed {
		if prefix = in.Config.Labels[labelService]; prefix == "" {
			prefix = strings.TrimPrefix(in.Name, "/")
		}
	}
	lineOut := func(text string, stderr bool) { emit(LogLine{Text: text, Stderr: stderr, Prefix: prefix}) }
	q := url.Values{"follow": {"1"}, "stdout": {"1"}, "stderr": {"1"}, "tail": {tailParam(tail)}}
	tty := in.Config.Tty
	for first, attempt := true, 0; ; first = false {
		err := streamContainerLogs(ctx, c, in.ID, q, tty, lineOut)
		if ctx.Err() != nil || isNotFound(err) {
			return nil
		}
		if err != nil && first {
			return err
		}
		if err != nil {
			if removed, done := waitSignal(ctx, sig, reconnectDelays[min(attempt, len(reconnectDelays)-1)]); removed || done {
				return nil
			}
			attempt++
		} else {
			attempt = 0
		}
		for {
			cur, ierr := inspectContainer(ctx, c, in.ID)
			if ctx.Err() != nil || isNotFound(ierr) {
				return nil
			}
			if ierr == nil && cur.State.Running {
				tty = cur.Config.Tty
				q = url.Values{"follow": {"1"}, "stdout": {"1"}, "stderr": {"1"}, "tail": {"0"}}
				if since := sinceParam(cur.State.StartedAt); err == nil && since != "" {
					q.Set("tail", "all")
					q.Set("since", since)
				}
				break
			}
			var wait time.Duration
			if ierr != nil {
				wait = reconnectDelays[min(attempt, len(reconnectDelays)-1)]
				attempt++
			}
			if removed, done := waitSignal(ctx, sig, wait); removed || done {
				return nil
			}
		}
	}
}

func followLogs(ctx context.Context, ids []string, tail int, prefixed bool, emit func(LogLine)) (removed bool, err error) {
	connectCtx, cancel := context.WithTimeout(ctx, engineTimeout(snapshotTimeout))
	c, err := engineClient(connectCtx)
	cancel()
	if err != nil {
		return false, err
	}
	errs := make([]error, len(ids))
	var wg sync.WaitGroup
	for i, id := range ids {
		wg.Go(func() { errs[i] = followContainer(ctx, c, id, tail, prefixed, emit) })
	}
	wg.Wait()
	if ctx.Err() != nil {
		return false, nil
	}
	for _, e := range errs {
		if e != nil {
			forgetClient(e)
			return false, e
		}
	}
	return true, nil
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

func (b *logBatcher) add(l LogLine) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, l)
	b.size += len(l.Text)
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

func LogsOpen(ids []string, tail int) int64 {
	seen := map[string]bool{}
	clean := []string{}
	for _, id := range ids {
		if id = strings.TrimSpace(id); id != "" && !seen[id] {
			seen[id] = true
			clean = append(clean, id)
		}
	}
	if len(clean) == 0 {
		return 0
	}
	ctx, cancel := withGeneration(context.Background())
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
		removed, err := followLogs(ctx, clean, tail, len(clean) > 1, b.add)
		b.flush()
		logStreams.Lock()
		_, open := logStreams.m[id]
		delete(logStreams.m, id)
		logStreams.Unlock()
		cancel()
		if !open {
			return
		}
		ev := LogsEvent{Stream: id, Closed: true}
		switch {
		case err != nil:
			ev.Reason, ev.Error = "error", plainError(err)
		case removed:
			ev.Reason = "removed"
		}
		emitLogs(ev)
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

func openLogStreams() int {
	logStreams.Lock()
	defer logStreams.Unlock()
	return len(logStreams.m)
}

func FollowComposeLogs(parent context.Context, composePath string, tail int, emit func(LogLine)) error {
	ctx, stop := withGeneration(parent)
	defer stop()
	err := followComposeLogs(ctx, composePath, tail, emit)
	if parent.Err() == nil && ctx.Err() != nil {
		return fmt.Errorf("GoLens switched to the Docker context “%s”, so these logs stopped; run Compose Logs again to follow it.", CurrentContext())
	}
	return err
}

func followComposeLogs(ctx context.Context, composePath string, tail int, emit func(LogLine)) error {
	connectCtx, cancel := context.WithTimeout(ctx, engineTimeout(snapshotTimeout))
	defer cancel()
	c, err := engineClient(connectCtx)
	if err != nil {
		return err
	}
	list, err := listContainers(connectCtx, c, nil)
	if err != nil {
		forgetClient(err)
		return err
	}
	want, dir := filepath.Clean(composePath), filepath.Dir(filepath.Clean(composePath))
	var ids []string
	for _, a := range list {
		files := splitConfigFiles(a.Labels[labelConfigFiles])
		match := a.Labels[labelProject] != "" && filepath.Clean(a.Labels[labelWorkingDir]) == dir && len(files) == 0
		for _, f := range files {
			match = match || filepath.Clean(f) == want
		}
		if match {
			ids = append(ids, a.ID)
		}
	}
	if len(ids) == 0 {
		return fmt.Errorf("No containers of the Compose project in %s exist yet; run Compose Up first.", filepath.Base(dir))
	}
	_, err = followLogs(ctx, ids, tail, true, emit)
	return err
}
