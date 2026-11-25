package docker

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

func fastReconnect(t *testing.T) {
	old := reconnectDelays
	reconnectDelays = []time.Duration{50 * time.Millisecond}
	t.Cleanup(func() { reconnectDelays = old })
}

func currentWatch() *watcher {
	watchState.Lock()
	defer watchState.Unlock()
	return watchState.w
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNothingConnectsBeforeAWatchOrCall(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	time.Sleep(150 * time.Millisecond)
	if reqs := s.Requests(); len(reqs) != 0 {
		t.Fatalf("requests before any call: %v", reqs)
	}
}

func TestWatchResnapshotsThenCoalesces(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	api, redis, _, _ := seedProject(s, "/w")
	id := WatchStart([]string{"containers"})
	first := rec.batches(t, 1)[0]
	if !first.Reset || first.Seq != 1 || len(first.Upserts) != 4 || first.Engine.State != "running" || len(first.Invalidated) != 0 {
		t.Fatalf("first batch = %+v", first)
	}
	_, _, filters, _ := s.snapshot()
	var f map[string][]string
	if err := json.Unmarshal([]byte(filters[0]), &f); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f["type"], []string{"container"}) || len(f["event"]) == 0 {
		t.Fatalf("filters = %v", f)
	}
	for _, e := range f["event"] {
		if e == "exec_start" || e == "exec_create" || e == "attach" {
			t.Fatalf("noisy event %s in filter", e)
		}
	}

	sig, unsubscribe := subscribeContainer(redis.ID)
	defer unsubscribe()
	s.setState(api.ID, "exited", "Exited (0) 1 second ago")
	s.setState(redis.ID, "running", "Up 1 second")
	for _, ev := range []map[string]any{
		containerEvent(api.ID, "kill"), containerEvent(api.ID, "die"), containerEvent(api.ID, "stop"),
		containerEvent(redis.ID, "start"), containerEvent(redis.ID, "exec_start: sh -c true"),
		containerEvent(redis.ID, "health_status: healthy"),
	} {
		s.events <- ev
	}
	select {
	case got := <-sig:
		if got != signalStarted {
			t.Fatalf("signal = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("a start event must wake log streams of that container")
	}
	second := rec.batches(t, 2)[1]
	if second.Reset || second.Seq != 2 || len(second.Upserts) != 2 || len(second.Removals) != 0 {
		t.Fatalf("coalesced batch = %+v", second)
	}
	if second.Upserts[0].State != "exited" || second.Upserts[1].State != "running" {
		t.Fatalf("upserts = %+v", second.Upserts)
	}
	time.Sleep(250 * time.Millisecond)
	if n := rec.count(BatchTopic); n != 2 {
		t.Fatalf("events within 100 ms must make one batch, got %d batches", n)
	}

	s.remove(redis.ID)
	s.events <- containerEvent(redis.ID, "destroy")
	third := rec.batches(t, 3)[2]
	if third.Seq != 3 || len(third.Upserts) != 0 || !reflect.DeepEqual(third.Removals, []string{redis.ID}) {
		t.Fatalf("removal batch = %+v", third)
	}
	if WatchStart(nil) != id {
		t.Fatal("a second start must return the same watch")
	}
}

func TestWatchWidensKindsAndInvalidates(t *testing.T) {
	rec := recordStatus(t)
	s := newSvcEngine(t)
	seedProject(s, "/w")
	id := WatchStart([]string{"containers"})
	rec.batches(t, 1)
	if got := WatchStart([]string{"images", "volumes"}); got != id {
		t.Fatalf("widen returned %d, want %d", got, id)
	}
	reset := rec.batches(t, 2)[1]
	if !reset.Reset || !reflect.DeepEqual(reset.Invalidated, []string{"images", "volumes"}) {
		t.Fatalf("widened reset = %+v", reset)
	}
	_, _, filters, conns := s.snapshot()
	var f map[string][]string
	json.Unmarshal([]byte(filters[len(filters)-1]), &f)
	if conns != 2 || !reflect.DeepEqual(f["type"], []string{"container", "image", "volume"}) {
		t.Fatalf("conns = %d, filters = %v", conns, f)
	}
	s.events <- map[string]any{"Type": "image", "Action": "pull", "Actor": map[string]any{"ID": "redis:7"}}
	b := rec.batches(t, 3)[2]
	if !reflect.DeepEqual(b.Invalidated, []string{"images"}) || len(b.Upserts) != 0 {
		t.Fatalf("image batch = %+v", b)
	}
	s.events <- map[string]any{"Type": "volume", "Action": "mount", "Actor": map[string]any{"ID": "redisdata"}}
	s.events <- map[string]any{"Type": "volume", "Action": "destroy", "Actor": map[string]any{"ID": "orphan"}}
	b = rec.batches(t, 4)[3]
	if !reflect.DeepEqual(b.Invalidated, []string{"volumes"}) {
		t.Fatalf("volume batch = %+v", b)
	}
	if WatchStart([]string{"images"}) != id {
		t.Fatal("same kinds must not restart the watch")
	}
	time.Sleep(150 * time.Millisecond)
	if _, _, _, conns := s.snapshot(); conns != 2 {
		t.Fatalf("no reconnect expected, conns = %d", conns)
	}
}

func TestWatchReconnectsAndResnapshots(t *testing.T) {
	fastReconnect(t)
	rec := recordStatus(t)
	s := newSvcEngine(t)
	seedProject(s, "/w")
	WatchStart([]string{"container"})
	rec.batches(t, 1)
	s.remove(hexID("c3"))
	s.dropEvents()
	got := rec.batches(t, 3)
	if got[1].Engine.State != "reconnecting" || got[1].Engine.Error == "" || len(got[1].Upserts) != 0 {
		t.Fatalf("drop batch = %+v", got[1])
	}
	if !got[2].Reset || got[2].Engine.State != "running" || len(got[2].Upserts) != 3 {
		t.Fatalf("resnapshot = %+v", got[2])
	}
	for i := range got {
		if got[i].Seq != int64(i+1) {
			t.Fatalf("seq = %d at %d", got[i].Seq, i)
		}
	}
}

func TestWatchStopEndsConnectionsAndRetries(t *testing.T) {
	fastReconnect(t)
	rec := recordStatus(t)
	s := newSvcEngine(t)
	seedProject(s, "/w")
	id := WatchStart([]string{"container"})
	rec.batches(t, 1)
	WatchStop(id + 1)
	if currentWatch() == nil {
		t.Fatal("a stale id must not stop the watch")
	}
	WatchStop(id)
	before := len(s.Requests())
	s.events <- containerEvent(hexID("a1"), "die")
	time.Sleep(300 * time.Millisecond)
	if after := len(s.Requests()); after != before {
		t.Fatalf("requests after stop: %v", s.Requests()[before:])
	}
	if n := rec.count(BatchTopic); n != 1 {
		t.Fatalf("batches after stop: %d", n)
	}
	if currentWatch() != nil {
		t.Fatal("watch still registered")
	}
}

func TestWatchRetriesOnlyWhileOpen(t *testing.T) {
	fastReconnect(t)
	rec := recordStatus(t)
	s := newSvcEngine(t)
	seedProject(s, "/w")
	s.srv.Close()
	id := WatchStart([]string{"container"})
	got := rec.batches(t, 2)
	if got[0].Engine.State != "reconnecting" || got[0].Engine.Reason != ReasonDown {
		t.Fatalf("engine down batch = %+v", got[0])
	}
	WatchStop(id)
	n := rec.count(BatchTopic)
	time.Sleep(200 * time.Millisecond)
	if rec.count(BatchTopic) != n {
		t.Fatal("watch kept retrying after stop")
	}
}
