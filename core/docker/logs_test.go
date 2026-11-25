package docker

import (
	"bytes"
	"context"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type emitted struct {
	text   string
	stderr bool
}

func collect(t *testing.T, data []byte, mux bool) []emitted {
	t.Helper()
	var out []emitted
	err := readLogStream(bytes.NewReader(data), mux, func(text string, stderr bool) { out = append(out, emitted{text, stderr}) })
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestReadLogStreamDemultiplexes(t *testing.T) {
	var data []byte
	for _, f := range []struct {
		stream byte
		text   string
	}{{1, "hel"}, {1, "lo\nwor"}, {2, "oops\r\n"}, {1, "ld\n"}, {3, "daemon error\n"}, {1, "no newline"}} {
		frame := muxFrame(f.stream == 2, f.text)
		frame[0] = f.stream
		data = append(data, frame...)
	}
	got := collect(t, data, true)
	want := []emitted{{"hello", false}, {"oops", true}, {"world", false}, {"daemon error", true}, {"no newline", false}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
}

func TestReadLogStreamRawForTTY(t *testing.T) {
	got := collect(t, []byte("a\r\nb\n\nc"), false)
	if want := []emitted{{"a", false}, {"b", false}, {"", false}, {"c", false}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
}

func TestLogLinesAreCappedAt64KB(t *testing.T) {
	long := strings.Repeat("x", maxLogLine+5000)
	for _, mux := range []bool{true, false} {
		data := []byte(long + "\nnext\n")
		if mux {
			data = append(muxFrame(false, long[:40000]), muxFrame(false, long[40000:]+"\nnext\n")...)
		}
		got := collect(t, data, mux)
		if len(got) != 2 || got[0].text != strings.Repeat("x", maxLogLine)+"…" || got[1].text != "next" {
			t.Fatalf("mux=%v: %d lines, first %d bytes", mux, len(got), len(got[0].text))
		}
	}
}

func TestLogsOpenFollowsOneContainerUntilClosed(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	api, _, _, _ := seedProject(s, "/w")
	if LogsOpen(nil, 500) != 0 || LogsOpen([]string{" "}, 500) != 0 {
		t.Fatal("no ids must return 0")
	}
	id := LogsOpen([]string{api.ID}, 500)
	lines := allLogLines(rec.logEvents(t, 1))
	if want := []LogLine{{Text: "listening on :8080"}, {Text: "warning: debug mode", Stderr: true}}; !reflect.DeepEqual(lines, want) {
		t.Fatalf("lines = %+v", lines)
	}
	_, queries, _, _ := s.snapshot()
	if want := api.ID + " follow=1&stderr=1&stdout=1&tail=500"; len(queries) != 1 || queries[0] != want {
		t.Fatalf("queries = %q", queries)
	}
	LogsClose(id)
	waitUntil(t, "stream to close", func() bool { return openLogStreams() == 0 })
	s.setState(api.ID, "exited", "Exited (0)")
	time.Sleep(200 * time.Millisecond)
	if n := rec.count(LogsTopic); n != 1 {
		t.Fatalf("events after close: %d", n)
	}
}

func TestLogsMergeWithPrefixesAndCloseWhenRemoved(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	api, redis, _, _ := seedProject(s, "/w")
	id := LogsOpen([]string{api.ID, redis.ID, api.ID}, 100)
	waitUntil(t, "merged lines", func() bool { return rec.count(LogsTopic) > 0 && len(lineTexts(allLogLines(rec.logEvents(t, 1)))) == 3 })
	got := lineTexts(allLogLines(rec.logEvents(t, 1)))
	if want := []string{"!api | warning: debug mode", "api | listening on :8080", "redis | Ready to accept connections"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("merged = %q", got)
	}
	s.remove(api.ID)
	s.remove(redis.ID)
	publishContainerSignal(redis.ID, signalRemoved)
	events := rec.logEvents(t, 2)
	last := events[len(events)-1]
	if last.Stream != id || !last.Closed || last.Reason != "removed" || len(last.Lines) != 0 {
		t.Fatalf("closing event = %+v", last)
	}
	waitUntil(t, "stream table cleanup", func() bool { return openLogStreams() == 0 })
}

func TestLogsOfTTYContainerAreRaw(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	_, _, _, plain := seedProject(s, "/w")
	LogsOpen([]string{plain.Name}, 10)
	if lines := allLogLines(rec.logEvents(t, 1)); !reflect.DeepEqual(lines, []LogLine{{Text: "tty line"}}) {
		t.Fatalf("tty lines = %+v", lines)
	}
}

func TestLogsResumeAfterRestartSinceStart(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	_, redis, _, _ := seedProject(s, "/w")
	LogsOpen([]string{redis.ID}, 500)
	rec.logEvents(t, 1)
	s.setState(redis.ID, "running", "Up 1 second")
	s.appendLog(redis.ID, fakeLogLine{Text: "restarted"})
	publishContainerSignal(redis.ID, signalStarted)
	waitUntil(t, "restart line", func() bool {
		for _, l := range allLogLines(rec.logEvents(t, 1)) {
			if l.Text == "restarted" {
				return true
			}
		}
		return false
	})
	start, _ := time.Parse(time.RFC3339Nano, "2026-11-15T16:05:00.5Z")
	_, queries, _, _ := s.snapshot()
	want := fmt.Sprintf("%s follow=1&since=%d.500000000&stderr=1&stdout=1&tail=all", redis.ID, start.Unix())
	if len(queries) != 2 || queries[1] != want {
		t.Fatalf("queries = %q, want second %q", queries, want)
	}
}

func TestLogsReportEngineDown(t *testing.T) {
	rec := recordStatus(t)
	t.Setenv("DOCKER_HOST", "unix://"+filepath.Join(shortTempDir(t), "missing.sock"))
	resetServicesState(t)
	id := LogsOpen([]string{"api"}, 500)
	ev := rec.logEvents(t, 1)[0]
	if ev.Stream != id || !ev.Closed || ev.Reason != "error" || !strings.HasPrefix(ev.Error, "Docker Engine isn’t running at ") {
		t.Fatalf("event = %+v", ev)
	}
}

func TestLogsOfUnknownContainerCloseAsRemoved(t *testing.T) {
	rec := recordStatus(t)
	newSvcEngine(t)
	LogsOpen([]string{"gone"}, 500)
	if ev := rec.logEvents(t, 1)[0]; !ev.Closed || ev.Reason != "removed" {
		t.Fatalf("event = %+v", ev)
	}
}

func TestLogBatcherKeepsNewestWithinCaps(t *testing.T) {
	rec := recordStatus(t)
	b := &logBatcher{ctx: context.Background(), stream: 7}
	for i := range maxBatchLines + 500 {
		b.add(LogLine{Text: fmt.Sprint(i)})
	}
	b.flush()
	ev := rec.logEvents(t, 1)[0]
	if len(ev.Lines) != maxBatchLines || ev.Dropped != 500 || ev.Lines[0].Text != "500" {
		t.Fatalf("lines %d dropped %d first %q", len(ev.Lines), ev.Dropped, ev.Lines[0].Text)
	}
	big := strings.Repeat("y", 300<<10)
	for range 5 {
		b.add(LogLine{Text: big})
	}
	b.flush()
	if ev := rec.logEvents(t, 2)[1]; len(ev.Lines) != 3 || ev.Dropped != 2 {
		t.Fatalf("byte cap: lines %d dropped %d", len(ev.Lines), ev.Dropped)
	}
	ctx, cancel := context.WithCancel(context.Background())
	closed := &logBatcher{ctx: ctx, stream: 8}
	closed.add(LogLine{Text: "late"})
	cancel()
	closed.flush()
	if rec.count(LogsTopic) != 2 {
		t.Fatal("a closed stream must not emit")
	}
}

func TestFollowComposeLogs(t *testing.T) {
	s := newSvcEngine(t)
	ws := "/Users/me/src/velo"
	seedProject(s, ws)
	ctx, cancel := context.WithCancel(context.Background())
	var mu sync.Mutex
	var lines []LogLine
	done := make(chan error, 1)
	go func() {
		done <- FollowComposeLogs(ctx, ws+"/compose.yaml", 200, func(l LogLine) {
			mu.Lock()
			lines = append(lines, l)
			mu.Unlock()
		})
	}()
	waitUntil(t, "compose lines", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(lines) == 3
	})
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	got := lineTexts(lines)
	mu.Unlock()
	if want := []string{"!api | warning: debug mode", "api | listening on :8080", "redis | Ready to accept connections"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("compose = %q", got)
	}
	err := FollowComposeLogs(context.Background(), "/Users/me/src/other/compose.yaml", 200, func(LogLine) {})
	if err == nil || err.Error() != "No containers of the Compose project in other exist yet; run Compose Up first." {
		t.Fatalf("no containers = %v", err)
	}
}
