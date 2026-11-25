package docker

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
)

const BatchTopic = "services.docker.batch"

var (
	coalesceDelay   = 100 * time.Millisecond
	reconnectDelays = []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second}
	emitStatus      = func(topic, payload string) { bridge.Status(topic, payload) }
)

type Batch struct {
	Seq         int64       `json:"seq"`
	Reset       bool        `json:"reset"`
	Upserts     []Container `json:"upserts"`
	Removals    []string    `json:"removals"`
	Invalidated []string    `json:"invalidated"`
	Engine      EngineState `json:"engine"`
}

var containerActions = map[string]bool{
	"create": true, "start": true, "restart": true, "stop": true, "die": true, "pause": true,
	"unpause": true, "rename": true, "update": true, "destroy": true, "health_status": true, "oom": true,
}

var imageActions = map[string]bool{"pull": true, "tag": true, "untag": true, "delete": true, "import": true, "load": true}

var volumeActions = map[string]bool{"create": true, "destroy": true}

type apiEvent struct {
	Type   string `json:"Type"`
	Action string `json:"Action"`
	Actor  struct {
		ID string `json:"ID"`
	} `json:"Actor"`
	TimeNano int64 `json:"timeNano"`
}

type watcher struct {
	id      int64
	cancel  context.CancelFunc
	ctx     context.Context
	done    chan struct{}
	widen   chan struct{}
	mu      sync.Mutex
	kinds   map[string]bool
	dirty   map[string]bool
	removed map[string]bool
	invalid map[string]bool
	timer   *time.Timer
	client  *Client
	emitMu  sync.Mutex
	seq     int64
}

var watchState struct {
	sync.Mutex
	w      *watcher
	nextID int64
}

func watchKinds(kinds []string) map[string]bool {
	out := map[string]bool{"container": true}
	for _, k := range kinds {
		switch k = normalizeKind(k); k {
		case "image", "volume":
			out[k] = true
		}
	}
	return out
}

func WatchStart(kinds []string) int64 {
	want := watchKinds(kinds)
	watchState.Lock()
	defer watchState.Unlock()
	if w := watchState.w; w != nil {
		w.mu.Lock()
		widened := false
		for k := range want {
			if !w.kinds[k] {
				w.kinds[k] = true
				widened = true
			}
		}
		w.mu.Unlock()
		if widened {
			select {
			case w.widen <- struct{}{}:
			default:
			}
		}
		return w.id
	}
	watchState.nextID++
	ctx, cancel := context.WithCancel(context.Background())
	w := &watcher{
		id: watchState.nextID, ctx: ctx, cancel: cancel, done: make(chan struct{}), widen: make(chan struct{}, 1),
		kinds: want, dirty: map[string]bool{}, removed: map[string]bool{}, invalid: map[string]bool{},
	}
	watchState.w = w
	go w.run()
	return w.id
}

func WatchStop(id int64) {
	watchState.Lock()
	w := watchState.w
	if w == nil || w.id != id {
		watchState.Unlock()
		return
	}
	watchState.w = nil
	watchState.Unlock()
	w.cancel()
	w.mu.Lock()
	if w.timer != nil {
		w.timer.Stop()
		w.timer = nil
	}
	w.mu.Unlock()
	select {
	case <-w.done:
	case <-time.After(time.Second):
	}
	sharedTransport.CloseIdleConnections()
}

func (w *watcher) run() {
	defer close(w.done)
	attempt := 0
	for {
		connected, err := w.stream()
		if w.ctx.Err() != nil {
			return
		}
		if errors.Is(err, errWidened) {
			attempt = 0
			continue
		}
		if connected {
			attempt = 0
		}
		forgetClient(err)
		st := engineStateFor(nil, err)
		st.State = "reconnecting"
		w.emit(Batch{Upserts: []Container{}, Removals: []string{}, Invalidated: []string{}, Engine: st})
		delay := reconnectDelays[min(attempt, len(reconnectDelays)-1)]
		attempt++
		select {
		case <-w.ctx.Done():
			return
		case <-time.After(delay):
		case <-w.widen:
		}
	}
}

var errWidened = errors.New("watch kinds widened")

func (w *watcher) filters() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	types := []string{}
	actions := map[string]bool{}
	add := func(m map[string]bool) {
		for a := range m {
			actions[a] = true
		}
	}
	for k := range w.kinds {
		types = append(types, k)
		switch k {
		case "container":
			add(containerActions)
		case "image":
			add(imageActions)
		case "volume":
			add(volumeActions)
		}
	}
	events := make([]string, 0, len(actions))
	for a := range actions {
		events = append(events, a)
	}
	sort.Strings(types)
	sort.Strings(events)
	return filtersParam(map[string][]string{"type": types, "event": events})
}

func (w *watcher) stream() (bool, error) {
	connectCtx, cancelConnect := context.WithTimeout(w.ctx, engineTimeout(snapshotTimeout))
	c, err := engineClient(connectCtx)
	cancelConnect()
	if err != nil {
		return false, err
	}
	w.mu.Lock()
	w.client = c
	w.mu.Unlock()
	ctx, cancel := context.WithCancel(w.ctx)
	defer cancel()
	widened := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
		case <-w.widen:
			close(widened)
			cancel()
		}
	}()
	resp, err := c.Do(ctx, http.MethodGet, "/events", url.Values{"filters": {w.filters()}}, nil)
	if err != nil {
		return false, w.streamErr(widened, err)
	}
	defer resp.Body.Close()
	if err := w.resnapshot(c); err != nil {
		return true, w.streamErr(widened, err)
	}
	dec := json.NewDecoder(resp.Body)
	for {
		var ev apiEvent
		if err := dec.Decode(&ev); err != nil {
			return true, w.streamErr(widened, c.wrap(err, time.Time{}))
		}
		w.handle(ev)
	}
}

func (w *watcher) streamErr(widened chan struct{}, err error) error {
	select {
	case <-widened:
		return errWidened
	default:
	}
	return err
}

func (w *watcher) resnapshot(c *Client) error {
	ctx, cancel := context.WithTimeout(w.ctx, timeoutFor(c.Endpoint, snapshotTimeout*2))
	defer cancel()
	list, err := listContainers(ctx, c, nil)
	if err != nil {
		return err
	}
	b := Batch{Reset: true, Upserts: make([]Container, 0, len(list)), Removals: []string{}, Invalidated: []string{}, Engine: engineStateFor(c, nil)}
	for _, a := range list {
		b.Upserts = append(b.Upserts, containerFromAPI(a))
	}
	sortContainers(b.Upserts)
	w.mu.Lock()
	for k := range w.kinds {
		if k != "container" {
			b.Invalidated = append(b.Invalidated, k+"s")
		}
	}
	w.dirty, w.removed, w.invalid = map[string]bool{}, map[string]bool{}, map[string]bool{}
	w.mu.Unlock()
	sort.Strings(b.Invalidated)
	w.emit(b)
	return nil
}

func (w *watcher) handle(ev apiEvent) {
	action, _, _ := strings.Cut(ev.Action, ":")
	action = strings.TrimSpace(action)
	id := ev.Actor.ID
	w.mu.Lock()
	defer w.mu.Unlock()
	switch ev.Type {
	case "container":
		if !containerActions[action] || id == "" {
			return
		}
		switch action {
		case "destroy":
			delete(w.dirty, id)
			w.removed[id] = true
			publishContainerSignal(id, signalRemoved)
		case "start", "restart", "unpause":
			w.dirty[id] = true
			publishContainerSignal(id, signalStarted)
		default:
			w.dirty[id] = true
		}
		if action == "create" || action == "destroy" {
			for _, k := range []string{"image", "volume"} {
				if w.kinds[k] {
					w.invalid[k+"s"] = true
				}
			}
		}
	case "image":
		if imageActions[action] && w.kinds["image"] {
			w.invalid["images"] = true
		}
	case "volume":
		if volumeActions[action] && w.kinds["volume"] {
			w.invalid["volumes"] = true
		}
	default:
		return
	}
	if w.timer == nil && (len(w.dirty) > 0 || len(w.removed) > 0 || len(w.invalid) > 0) {
		w.timer = time.AfterFunc(coalesceDelay, w.flush)
	}
}

func (w *watcher) flush() {
	w.mu.Lock()
	w.timer = nil
	dirty, removed, invalid, c := w.dirty, w.removed, w.invalid, w.client
	w.dirty, w.removed, w.invalid = map[string]bool{}, map[string]bool{}, map[string]bool{}
	w.mu.Unlock()
	if w.ctx.Err() != nil || len(dirty)+len(removed)+len(invalid) == 0 {
		return
	}
	b := Batch{Upserts: []Container{}, Removals: []string{}, Invalidated: []string{}}
	ids := make([]string, 0, len(dirty))
	for id := range dirty {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var err error
	if len(ids) > 0 && c != nil {
		ctx, cancel := context.WithTimeout(w.ctx, timeoutFor(c.Endpoint, snapshotTimeout))
		defer cancel()
		var list []apiContainer
		if list, err = listContainers(ctx, c, ids); err == nil {
			found := map[string]bool{}
			for _, a := range list {
				found[a.ID] = true
				b.Upserts = append(b.Upserts, containerFromAPI(a))
			}
			for _, id := range ids {
				if !found[id] {
					removed[id] = true
				}
			}
			sortContainers(b.Upserts)
		} else if w.ctx.Err() != nil {
			return
		}
	}
	for id := range removed {
		b.Removals = append(b.Removals, id)
	}
	sort.Strings(b.Removals)
	for k := range invalid {
		b.Invalidated = append(b.Invalidated, k)
	}
	sort.Strings(b.Invalidated)
	b.Engine = engineStateFor(c, err)
	if err != nil {
		b.Engine.State = "reconnecting"
	}
	w.emit(b)
}

func (w *watcher) emit(b Batch) {
	w.emitMu.Lock()
	defer w.emitMu.Unlock()
	if w.ctx.Err() != nil {
		return
	}
	w.seq++
	b.Seq = w.seq
	if data, err := json.Marshal(b); err == nil {
		emitStatus(BatchTopic, string(data))
	}
}

const (
	signalStarted = "started"
	signalRemoved = "removed"
)

var containerSignals struct {
	sync.Mutex
	subs map[string]map[chan string]bool
}

func subscribeContainer(id string) (chan string, func()) {
	ch := make(chan string, 1)
	containerSignals.Lock()
	if containerSignals.subs == nil {
		containerSignals.subs = map[string]map[chan string]bool{}
	}
	if containerSignals.subs[id] == nil {
		containerSignals.subs[id] = map[chan string]bool{}
	}
	containerSignals.subs[id][ch] = true
	containerSignals.Unlock()
	return ch, func() {
		containerSignals.Lock()
		delete(containerSignals.subs[id], ch)
		if len(containerSignals.subs[id]) == 0 {
			delete(containerSignals.subs, id)
		}
		containerSignals.Unlock()
	}
}

func publishContainerSignal(id, signal string) {
	containerSignals.Lock()
	defer containerSignals.Unlock()
	for ch := range containerSignals.subs[id] {
		select {
		case ch <- signal:
		default:
			select {
			case <-ch:
			default:
			}
			ch <- signal
		}
	}
}
