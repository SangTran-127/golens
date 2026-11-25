package runner

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
)

type streamEvent struct {
	ID    int64           `json:"id"`
	Key   string          `json:"key"`
	State string          `json:"state"`
	Error string          `json:"error"`
	Lines []runOutputLine `json:"lines"`
}

type runEventLog struct {
	mu     sync.Mutex
	events []streamEvent
}

func captureRunEvents(t *testing.T) *runEventLog {
	t.Helper()
	log := &runEventLog{}
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic != "runEvent" {
			return
		}
		var ev streamEvent
		if json.Unmarshal([]byte(payload), &ev) == nil {
			log.mu.Lock()
			log.events = append(log.events, ev)
			log.mu.Unlock()
		}
	}))
	return log
}

func (l *runEventLog) waitState(t *testing.T, id int64, states ...string) streamEvent {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		l.mu.Lock()
		for _, ev := range l.events {
			for _, s := range states {
				if ev.ID == id && ev.State == s {
					l.mu.Unlock()
					return ev
				}
			}
		}
		l.mu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("run %d never reached %v", id, states)
	return streamEvent{}
}

func (l *runEventLog) lines(id int64) []runOutputLine {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []runOutputLine
	for _, ev := range l.events {
		if ev.ID == id {
			out = append(out, ev.Lines...)
		}
	}
	return out
}

func TestStreamSessionEmitsRunEvents(t *testing.T) {
	log := captureRunEvents(t)
	outR, outW := io.Pipe()
	errR, errW := io.Pipe()
	var exited string
	exitDone := make(chan struct{})
	id := StartStream("stream:test", "Compose Logs", "/tmp", outR, StreamOptions{Stderr: errR, OnExit: func(state string) {
		exited = state
		close(exitDone)
	}})
	if id == 0 {
		t.Fatal("no run id")
	}
	if ev := log.waitState(t, id, "started"); ev.Key != "stream:test" {
		t.Fatalf("started = %+v", ev)
	}
	fmt.Fprintln(outW, "api | listening")
	fmt.Fprintln(errW, "api | warning")
	errW.Close()
	outW.Close()
	log.waitState(t, id, "exited")
	<-exitDone
	if exited != "exited" {
		t.Fatalf("OnExit state = %q", exited)
	}
	got := log.lines(id)
	if len(got) != 2 {
		t.Fatalf("lines = %+v", got)
	}
	for _, l := range got {
		if (l.Text == "api | warning") != l.Stderr {
			t.Fatalf("stderr flag wrong on %+v", l)
		}
	}
	if lookupProgram(id) != nil {
		t.Fatal("finished stream still registered")
	}
}

func TestStreamSessionStopClosesReader(t *testing.T) {
	log := captureRunEvents(t)
	r, w := io.Pipe()
	stopped := make(chan struct{})
	id := StartStream("stream:stop", "Logs", "", r, StreamOptions{OnStop: func() { close(stopped) }})
	log.waitState(t, id, "started")
	StopProgramRun(id)
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("OnStop not called")
	}
	log.waitState(t, id, "stopped")
	if _, err := w.Write([]byte("late\n")); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("writer should see the closed reader, got %v", err)
	}
}

func TestStreamSessionReadErrorFails(t *testing.T) {
	log := captureRunEvents(t)
	r, w := io.Pipe()
	id := StartStream("stream:fail", "Logs", "", r, StreamOptions{})
	w.CloseWithError(errors.New("Docker Engine isn’t running at /var/run/docker.sock."))
	ev := log.waitState(t, id, "failed")
	if ev.Error != "Docker Engine isn’t running at /var/run/docker.sock." {
		t.Fatalf("failed = %+v", ev)
	}
	if lines := log.lines(id); len(lines) != 1 || !lines[0].Stderr || !strings.Contains(lines[0].Text, "isn’t running") {
		t.Fatalf("error line = %+v", lines)
	}
}

func TestStreamSessionSameKeyReplaces(t *testing.T) {
	log := captureRunEvents(t)
	r1, _ := io.Pipe()
	first := StartStream("stream:same", "Logs", "", r1, StreamOptions{})
	r2, w2 := io.Pipe()
	second := StartStream("stream:same", "Logs", "", r2, StreamOptions{})
	log.waitState(t, first, "stopped")
	if lookupProgram(second) == nil {
		t.Fatal("replacement not registered")
	}
	w2.Close()
	log.waitState(t, second, "exited")
}
