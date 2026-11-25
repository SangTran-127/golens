package kube

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"sync"
	"time"

	"golens/core/bridge"
)

const BatchTopic = "services.kube.batch"

const MaxRows = 500

const (
	StateLive         = "live"
	StateRelisting    = "relisting"
	StateReconnecting = "reconnecting"
	StateError        = "error"
)

var (
	coalesceDelay    = 100 * time.Millisecond
	idleReleaseDelay = 500 * time.Millisecond
	reconnectDelays  = []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second}
	emitStatus       = func(topic, payload string) { bridge.Status(topic, payload) }
	errGone          = errors.New("watch expired")
)

type Batch struct {
	Seq       int64             `json:"seq"`
	Watch     int64             `json:"watch"`
	Context   string            `json:"context"`
	Namespace string            `json:"namespace"`
	Kind      string            `json:"kind"`
	State     string            `json:"state"`
	Reset     bool              `json:"reset"`
	Upserts   []json.RawMessage `json:"upserts"`
	Removals  []string          `json:"removals"`
	Total     int               `json:"total"`
	Truncated bool              `json:"truncated"`
	Error     *Error            `json:"error,omitempty"`
}

type kindSpec struct {
	name     string
	group    string
	resource string
	decode   func(json.RawMessage) (apiMeta, any, error)
}

func (k kindSpec) path(namespace string) string {
	prefix := "/api/v1"
	if k.group != "" {
		prefix = "/apis/" + k.group
	}
	return prefix + "/namespaces/" + url.PathEscape(namespace) + "/" + k.resource
}

func decodeAs[T any](conv func(*T) any, meta func(*T) apiMeta) func(json.RawMessage) (apiMeta, any, error) {
	return func(raw json.RawMessage) (apiMeta, any, error) {
		var v T
		if err := json.Unmarshal(raw, &v); err != nil {
			return apiMeta{}, nil, err
		}
		return meta(&v), conv(&v), nil
	}
}

var kindSpecs = map[string]kindSpec{
	"pods": {name: "pods", resource: "pods", decode: decodeAs(
		func(p *apiPod) any { return podFromAPI(p) }, func(p *apiPod) apiMeta { return p.Metadata })},
	"deployments": {name: "deployments", group: "apps/v1", resource: "deployments", decode: decodeAs(
		func(d *apiDeployment) any { return deploymentFromAPI(d) }, func(d *apiDeployment) apiMeta { return d.Metadata })},
	"services": {name: "services", resource: "services", decode: decodeAs(
		func(s *apiService) any { return serviceFromAPI(s) }, func(s *apiService) apiMeta { return s.Metadata })},
}

func normalizeKind(k string) string {
	switch k {
	case "pod", "pods":
		return "pods"
	case "deployment", "deployments":
		return "deployments"
	case "service", "services":
		return "services"
	}
	return ""
}

type watchSet struct {
	id        int64
	context   string
	namespace string
	emitMu    sync.Mutex
	seq       int64
	kinds     map[string]*kindWatch
}

type kindWatch struct {
	set    *watchSet
	spec   kindSpec
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}

	mu        sync.Mutex
	store     map[string]json.RawMessage
	dirty     map[string]bool
	shown     map[string]bool
	reset     bool
	lastTotal int
	timer     *time.Timer
}

var watches struct {
	sync.Mutex
	set  *watchSet
	next int64
}

func contextDefaults(contextName, namespace string) (string, string) {
	cfg, ok, err := loadConfig()
	if err != nil || !ok {
		if namespace == "" {
			namespace = "default"
		}
		return contextName, namespace
	}
	if contextName == "" {
		contextName = cfg.CurrentContext
	}
	if namespace == "" {
		namespace = namespaceOf(cfg.Contexts[contextName])
	}
	return contextName, namespace
}

func WatchStart(contextName, namespace string, kinds []string) int64 {
	contextName, namespace = contextDefaults(contextName, namespace)
	want := map[string]bool{}
	for _, k := range kinds {
		if k = normalizeKind(k); k != "" {
			want[k] = true
		}
	}
	watches.Lock()
	defer watches.Unlock()
	s := watches.set
	if s != nil && (s.context != contextName || s.namespace != namespace) {
		s.stop()
		s = nil
	}
	if s == nil {
		watches.next++
		s = &watchSet{id: watches.next, context: contextName, namespace: namespace, kinds: map[string]*kindWatch{}}
		watches.set = s
	}
	for name, k := range s.kinds {
		if !want[name] {
			k.stop()
			delete(s.kinds, name)
		}
	}
	for name := range want {
		if k := s.kinds[name]; k != nil && !k.finished() {
			continue
		}
		s.kinds[name] = s.startKind(kindSpecs[name])
	}
	return s.id
}

func WatchStop(id int64) {
	watches.Lock()
	s := watches.set
	if s == nil || s.id != id {
		watches.Unlock()
		return
	}
	watches.set = nil
	s.stop()
	watches.Unlock()
	releaseClientsIfIdle()
	time.AfterFunc(idleReleaseDelay, releaseClientsIfIdle)
}

func (s *watchSet) stop() {
	for _, k := range s.kinds {
		k.cancel()
	}
	for _, k := range s.kinds {
		k.stop()
	}
}

func (s *watchSet) startKind(spec kindSpec) *kindWatch {
	ctx, cancel := context.WithCancel(context.Background())
	k := &kindWatch{set: s, spec: spec, ctx: ctx, cancel: cancel, done: make(chan struct{}),
		store: map[string]json.RawMessage{}, dirty: map[string]bool{}, shown: map[string]bool{}}
	go k.run()
	return k
}

func (s *watchSet) emit(ctx context.Context, b Batch) {
	s.emitMu.Lock()
	defer s.emitMu.Unlock()
	if ctx.Err() != nil {
		return
	}
	s.seq++
	b.Seq, b.Watch, b.Context, b.Namespace = s.seq, s.id, s.context, s.namespace
	if b.Upserts == nil {
		b.Upserts = []json.RawMessage{}
	}
	if b.Removals == nil {
		b.Removals = []string{}
	}
	if data, err := json.Marshal(b); err == nil {
		emitStatus(BatchTopic, string(data))
	}
}

func (k *kindWatch) finished() bool {
	select {
	case <-k.done:
		return true
	default:
		return false
	}
}

func (k *kindWatch) stop() {
	k.cancel()
	k.mu.Lock()
	if k.timer != nil {
		k.timer.Stop()
		k.timer = nil
	}
	k.mu.Unlock()
	select {
	case <-k.done:
	case <-time.After(time.Second):
	}
}

func retryable(e *Error) bool {
	return e.Kind == KindUnreachable || e.Kind == KindOther
}

func (k *kindWatch) run() {
	defer close(k.done)
	attempt, rv, relist := 0, "", true
	for {
		started := time.Now()
		progressed := false
		c, err := clientFor(k.set.context)
		if err == nil && relist {
			if rv, err = k.list(c); err == nil {
				relist, attempt = false, 0
			}
		}
		if err == nil {
			rv, progressed, err = k.watch(c, rv)
			if progressed {
				attempt = 0
			}
		}
		if k.ctx.Err() != nil {
			return
		}
		if errors.Is(err, errGone) {
			k.emitState(StateRelisting, nil)
			relist = true
			continue
		}
		if err == nil {
			if progressed || time.Since(started) > time.Second {
				continue
			}
		} else {
			ke := asError(err)
			if !retryable(ke) {
				k.emitState(StateError, ke)
				return
			}
			k.emitState(StateReconnecting, ke)
		}
		delay := reconnectDelays[min(attempt, len(reconnectDelays)-1)]
		attempt++
		select {
		case <-k.ctx.Done():
			return
		case <-time.After(delay):
		}
	}
}

func (k *kindWatch) request(verb string, q url.Values) request {
	return request{method: http.MethodGet, path: k.spec.path(k.set.namespace), query: q, verb: verb, resource: k.spec.resource, namespace: k.set.namespace}
}

func (k *kindWatch) list(c *client) (string, error) {
	store := map[string]json.RawMessage{}
	q := url.Values{"limit": {strconv.Itoa(MaxRows)}}
	rv := ""
	for {
		var page struct {
			Metadata apiListMeta       `json:"metadata"`
			Items    []json.RawMessage `json:"items"`
		}
		if err := c.getJSON(k.ctx, k.request("list", q), &page); err != nil {
			return "", err
		}
		for _, raw := range page.Items {
			meta, row, err := k.spec.decode(raw)
			if err != nil || meta.Name == "" {
				continue
			}
			if data, err := json.Marshal(row); err == nil {
				store[meta.Name] = data
			}
		}
		rv = page.Metadata.ResourceVersion
		if page.Metadata.Continue == "" {
			break
		}
		q.Set("continue", page.Metadata.Continue)
	}
	k.mu.Lock()
	k.store, k.dirty, k.reset = store, map[string]bool{}, true
	if k.timer != nil {
		k.timer.Stop()
		k.timer = nil
	}
	k.mu.Unlock()
	k.flush()
	return rv, nil
}

type watchEvent struct {
	Type   string          `json:"type"`
	Object json.RawMessage `json:"object"`
}

func (k *kindWatch) watch(c *client, rv string) (string, bool, error) {
	q := url.Values{
		"watch": {"1"}, "resourceVersion": {rv}, "allowWatchBookmarks": {"true"},
		"timeoutSeconds": {strconv.Itoa(300 + rand.IntN(300))},
	}
	resp, cancel, err := c.stream(k.ctx, k.request("watch", q))
	if err != nil {
		var ke *Error
		if errors.As(err, &ke) && ke.status == http.StatusGone {
			return rv, false, errGone
		}
		return rv, false, err
	}
	defer cancel()
	defer resp.Body.Close()
	dec := json.NewDecoder(resp.Body)
	progressed := false
	for {
		var ev watchEvent
		if err := dec.Decode(&ev); err != nil {
			if k.ctx.Err() != nil || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return rv, progressed, nil
			}
			return rv, progressed, c.bodyError(k.ctx, err)
		}
		progressed = true
		switch ev.Type {
		case "BOOKMARK":
			var obj struct {
				Metadata apiMeta `json:"metadata"`
			}
			if json.Unmarshal(ev.Object, &obj) == nil && obj.Metadata.ResourceVersion != "" {
				rv = obj.Metadata.ResourceVersion
			}
		case "ERROR":
			var st apiStatus
			_ = json.Unmarshal(ev.Object, &st)
			if st.Code == http.StatusGone {
				return rv, progressed, errGone
			}
			msg := sentence(st.Message)
			if msg == "" {
				msg = "The cluster ended the watch with an error."
			}
			return rv, progressed, &Error{Kind: KindOther, status: st.Code, Message: msg}
		case "ADDED", "MODIFIED", "DELETED":
			meta, row, err := k.spec.decode(ev.Object)
			if err != nil || meta.Name == "" {
				continue
			}
			if meta.ResourceVersion != "" {
				rv = meta.ResourceVersion
			}
			k.apply(ev.Type == "DELETED", meta.Name, row)
		}
	}
}

func (k *kindWatch) apply(deleted bool, name string, row any) {
	var data []byte
	if !deleted {
		var err error
		if data, err = json.Marshal(row); err != nil {
			return
		}
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if deleted {
		delete(k.store, name)
	} else {
		k.store[name] = data
	}
	k.dirty[name] = true
	if k.timer == nil {
		k.timer = time.AfterFunc(coalesceDelay, k.flush)
	}
}

func (k *kindWatch) flush() {
	k.mu.Lock()
	k.timer = nil
	names := make([]string, 0, len(k.store))
	for n := range k.store {
		names = append(names, n)
	}
	sort.Strings(names)
	limit := min(len(names), MaxRows)
	shown := make(map[string]bool, limit)
	b := Batch{Kind: k.spec.name, State: StateLive, Reset: k.reset, Total: len(names), Truncated: len(names) > limit}
	for _, n := range names[:limit] {
		shown[n] = true
		if k.reset || k.dirty[n] || !k.shown[n] {
			b.Upserts = append(b.Upserts, k.store[n])
		}
	}
	if !k.reset {
		for n := range k.shown {
			if !shown[n] {
				b.Removals = append(b.Removals, n)
			}
		}
		sort.Strings(b.Removals)
	}
	changed := k.reset || len(b.Upserts) > 0 || len(b.Removals) > 0 || len(names) != k.lastTotal
	k.shown, k.dirty, k.reset, k.lastTotal = shown, map[string]bool{}, false, len(names)
	k.mu.Unlock()
	if changed {
		k.set.emit(k.ctx, b)
	}
}

func (k *kindWatch) emitState(state string, err *Error) {
	k.mu.Lock()
	total := k.lastTotal
	k.mu.Unlock()
	k.set.emit(k.ctx, Batch{Kind: k.spec.name, State: state, Total: total, Truncated: total > MaxRows, Error: err})
}
