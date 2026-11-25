package docker

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

type svcContainer struct {
	ID        string
	Name      string
	Image     string
	ImageID   string
	State     string
	Status    string
	Labels    map[string]string
	Ports     []map[string]any
	Mounts    []map[string]any
	Env       []string
	Tty       bool
	StartedAt string
	Logs      []fakeLogLine
	Networks  map[string]string
	stopped   chan struct{}
}

type svcEngine struct {
	*fakeEngine
	t          *testing.T
	mu         sync.Mutex
	containers []*svcContainer
	images     []map[string]any
	volumes    []map[string]any
	actions    []string
	logQueries []string
	events     chan map[string]any
	drop       chan struct{}
	eventConns int
	filters    []string
	actionWait time.Duration
}

func newSvcEngine(t *testing.T) *svcEngine {
	t.Helper()
	s := &svcEngine{t: t, events: make(chan map[string]any, 64), drop: make(chan struct{})}
	s.fakeEngine = newFakeEngine(t, nil)
	v := "/v" + s.APIVersionPinned()
	s.Handle("GET "+v+"/containers/json", s.list)
	s.Handle("GET "+v+"/containers/{id}/json", s.inspect)
	s.Handle("GET "+v+"/containers/{id}/logs", s.logs)
	s.Handle("POST "+v+"/containers/{id}/{action}", s.action)
	s.Handle("DELETE "+v+"/containers/{id}", s.removeContainer)
	s.Handle("GET "+v+"/images/json", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		writeJSON(w, s.images)
	})
	s.Handle("GET "+v+"/images/{name...}", s.inspectImage)
	s.Handle("DELETE "+v+"/images/{name...}", s.removeImage)
	s.Handle("GET "+v+"/volumes", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		writeJSON(w, map[string]any{"Volumes": s.volumes, "Warnings": nil})
	})
	s.Handle("DELETE "+v+"/volumes/{name}", s.removeVolume)
	s.Handle("GET "+v+"/events", s.eventStream)
	t.Setenv("DOCKER_HOST", "unix://"+s.Socket)
	resetServicesState(t)
	return s
}

func resetServicesState(t *testing.T) {
	clientCache.Lock()
	clientCache.c = nil
	clientCache.Unlock()
	t.Cleanup(func() {
		watchState.Lock()
		w := watchState.w
		watchState.Unlock()
		if w != nil {
			WatchStop(w.id)
		}
		logStreams.Lock()
		ids := []int64{}
		for id := range logStreams.m {
			ids = append(ids, id)
		}
		logStreams.Unlock()
		for _, id := range ids {
			LogsClose(id)
		}
		statsStreams.Lock()
		ids = ids[:0]
		for id := range statsStreams.m {
			ids = append(ids, id)
		}
		statsStreams.Unlock()
		for _, id := range ids {
			StatsStop(id)
		}
		chosenContext.Lock()
		chosenContext.name = ""
		chosenContext.Unlock()
		clientCache.Lock()
		clientCache.c = nil
		clientCache.Unlock()
	})
}

func (s *svcEngine) add(c *svcContainer) *svcContainer {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.State == "" {
		c.State = "running"
	}
	if c.Status == "" {
		c.Status = "Up 2 minutes"
	}
	if c.StartedAt == "" {
		c.StartedAt = "2026-11-15T16:00:00.123456789Z"
	}
	c.stopped = make(chan struct{})
	if c.State != "running" {
		close(c.stopped)
	}
	s.containers = append(s.containers, c)
	return c
}

func (s *svcEngine) find(ref string) *svcContainer {
	for _, c := range s.containers {
		if c.ID == ref || c.Name == ref || (len(ref) >= 4 && strings.HasPrefix(c.ID, ref)) {
			return c
		}
	}
	return nil
}

func (s *svcEngine) setState(id, state, status string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.find(id)
	if c.State == "running" && state != "running" {
		close(c.stopped)
	}
	if c.State != "running" && state == "running" {
		c.stopped = make(chan struct{})
		c.StartedAt = "2026-11-15T16:05:00.5Z"
	}
	c.State, c.Status = state, status
}

func (s *svcEngine) remove(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, c := range s.containers {
		if c.ID == id {
			if c.State == "running" {
				close(c.stopped)
			}
			s.containers = append(s.containers[:i], s.containers[i+1:]...)
			return
		}
	}
}

func (s *svcEngine) summary(c *svcContainer) map[string]any {
	ports := c.Ports
	if ports == nil {
		ports = []map[string]any{}
	}
	mounts := c.Mounts
	if mounts == nil {
		mounts = []map[string]any{}
	}
	networks := map[string]any{}
	for name, id := range c.Networks {
		networks[name] = map[string]any{"NetworkID": id}
	}
	return map[string]any{
		"Id": c.ID, "Names": []string{"/" + c.Name}, "Image": c.Image, "ImageID": c.ImageID,
		"Command": "/app/server", "Created": 1763222400, "State": c.State, "Status": c.Status,
		"Ports": ports, "Labels": c.Labels, "Mounts": mounts, "NetworkSettings": map[string]any{"Networks": networks},
	}
}

func (s *svcEngine) list(w http.ResponseWriter, r *http.Request) {
	var f map[string][]string
	_ = json.Unmarshal([]byte(r.URL.Query().Get("filters")), &f)
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []map[string]any{}
	for _, c := range s.containers {
		if ids := f["id"]; len(ids) > 0 {
			match := false
			for _, id := range ids {
				match = match || strings.HasPrefix(c.ID, id)
			}
			if !match {
				continue
			}
		}
		out = append(out, s.summary(c))
	}
	writeJSON(w, out)
}

func notFound(w http.ResponseWriter, what string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	json.NewEncoder(w).Encode(map[string]string{"message": "No such " + what})
}

func (s *svcEngine) inspect(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.find(r.PathValue("id"))
	if c == nil {
		notFound(w, "container: "+r.PathValue("id"))
		return
	}
	ports := map[string]any{}
	for _, p := range c.Ports {
		key := strings.Join([]string{jsonNumber(p["PrivatePort"]), p["Type"].(string)}, "/")
		if pub, ok := p["PublicPort"]; ok {
			ports[key] = append(asList(ports[key]), map[string]any{"HostIp": p["IP"], "HostPort": jsonNumber(pub)})
		} else if _, ok := ports[key]; !ok {
			ports[key] = nil
		}
	}
	writeJSON(w, map[string]any{
		"Id": c.ID, "Created": "2026-11-15T15:59:58.5Z", "Path": "/app/server", "Args": []string{"--addr", ":8080"},
		"Name": "/" + c.Name, "Image": c.ImageID,
		"State": map[string]any{"Status": c.State, "Running": c.State == "running", "ExitCode": 0,
			"StartedAt": c.StartedAt, "FinishedAt": "0001-01-01T00:00:00Z", "Health": map[string]any{"Status": "healthy"}},
		"HostConfig": map[string]any{"RestartPolicy": map[string]any{"Name": "on-failure", "MaximumRetryCount": 3}},
		"Mounts":     []map[string]any{{"Type": "volume", "Name": "pgdata", "Source": "/var/lib/docker/volumes/pgdata/_data", "Destination": "/data", "Mode": "z", "RW": true}},
		"Config":     map[string]any{"Image": c.Image, "Env": c.Env, "Labels": c.Labels, "Tty": c.Tty, "WorkingDir": "/app"},
		"NetworkSettings": map[string]any{"Ports": ports, "Networks": map[string]any{
			"velo_default": map[string]any{"IPAddress": "172.18.0.2", "Gateway": "172.18.0.1", "MacAddress": "02:42:ac:12:00:02", "Aliases": []string{"api"}},
		}},
	})
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func jsonNumber(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func (s *svcEngine) action(w http.ResponseWriter, r *http.Request) {
	id, action := r.PathValue("id"), r.PathValue("action")
	s.mu.Lock()
	s.actions = append(s.actions, action+" "+id+" "+r.URL.RawQuery)
	wait := s.actionWait
	c := s.find(id)
	s.mu.Unlock()
	if wait > 0 {
		select {
		case <-time.After(wait):
		case <-r.Context().Done():
			return
		}
	}
	if c == nil {
		notFound(w, "container: "+id)
		return
	}
	switch action {
	case "start":
		if c.State == "running" {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		s.setState(c.ID, "running", "Up Less than a second")
	case "stop":
		s.setState(c.ID, "exited", "Exited (0) Less than a second ago")
	case "restart":
		s.setState(c.ID, "running", "Up Less than a second")
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *svcEngine) removeContainer(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.actions = append(s.actions, "delete "+r.PathValue("id")+" "+r.URL.RawQuery)
	c := s.find(r.PathValue("id"))
	s.mu.Unlock()
	if c == nil {
		notFound(w, "container")
		return
	}
	if c.State == "running" {
		w.WriteHeader(http.StatusConflict)
		writeJSON(w, map[string]string{"message": "cannot remove container: container is running"})
		return
	}
	s.remove(c.ID)
	w.WriteHeader(http.StatusNoContent)
}

func (s *svcEngine) findImage(name string) map[string]any {
	for _, img := range s.images {
		if img["Id"] == name {
			return img
		}
		for _, tag := range img["RepoTags"].([]string) {
			if tag == name {
				return img
			}
		}
	}
	return nil
}

func (s *svcEngine) inspectImage(w http.ResponseWriter, r *http.Request) {
	name, ok := strings.CutSuffix(r.PathValue("name"), "/json")
	s.mu.Lock()
	defer s.mu.Unlock()
	img := s.findImage(name)
	if !ok || img == nil {
		notFound(w, "image: "+name)
		return
	}
	writeJSON(w, img)
}

func (s *svcEngine) removeImage(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	s.mu.Lock()
	defer s.mu.Unlock()
	s.actions = append(s.actions, "rmi "+name+" "+r.URL.RawQuery)
	img := s.findImage(name)
	if img == nil {
		notFound(w, "image: "+name)
		return
	}
	tags := img["RepoTags"].([]string)
	kept := []string{}
	for _, tag := range tags {
		if tag != name {
			kept = append(kept, tag)
		}
	}
	if len(kept) > 0 && img["Id"] != name {
		img["RepoTags"] = kept
	} else {
		for i, other := range s.images {
			if other["Id"] == img["Id"] {
				s.images = append(s.images[:i], s.images[i+1:]...)
				break
			}
		}
	}
	writeJSON(w, []map[string]string{{"Untagged": name}})
}

func (s *svcEngine) removeVolume(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	s.mu.Lock()
	defer s.mu.Unlock()
	s.actions = append(s.actions, "rmv "+name+" "+r.URL.RawQuery)
	for i, v := range s.volumes {
		if v["Name"] == name {
			s.volumes = append(s.volumes[:i], s.volumes[i+1:]...)
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}
	notFound(w, "volume: "+name)
}

func (s *svcEngine) logs(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.logQueries = append(s.logQueries, r.PathValue("id")+" "+r.URL.RawQuery)
	c := s.find(r.PathValue("id"))
	var lines []fakeLogLine
	var stopped chan struct{}
	tty := false
	if c != nil {
		lines, stopped, tty = append([]fakeLogLine(nil), c.Logs...), c.stopped, c.Tty
	}
	s.mu.Unlock()
	if c == nil {
		notFound(w, "container: "+r.PathValue("id"))
		return
	}
	if tty {
		w.Header().Set("Content-Type", mediaRawStream)
	} else {
		w.Header().Set("Content-Type", mediaMuxStream)
	}
	w.WriteHeader(http.StatusOK)
	for _, l := range lines {
		if tty {
			w.Write([]byte(l.Text + "\r\n"))
		} else {
			w.Write(muxFrame(l.Stderr, l.Text+"\n"))
		}
	}
	w.(http.Flusher).Flush()
	if r.URL.Query().Get("follow") != "1" {
		return
	}
	select {
	case <-r.Context().Done():
	case <-stopped:
	}
}

func (s *svcEngine) appendLog(id string, l fakeLogLine) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.find(id)
	c.Logs = append(c.Logs, l)
}

func (s *svcEngine) eventStream(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.eventConns++
	s.filters = append(s.filters, r.URL.Query().Get("filters"))
	drop := s.drop
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.(http.Flusher).Flush()
	enc := json.NewEncoder(w)
	for {
		select {
		case <-r.Context().Done():
			return
		case <-drop:
			return
		case ev := <-s.events:
			enc.Encode(ev)
			w.(http.Flusher).Flush()
		}
	}
}

func (s *svcEngine) dropEvents() {
	s.mu.Lock()
	defer s.mu.Unlock()
	close(s.drop)
	s.drop = make(chan struct{})
}

func (s *svcEngine) snapshot() (actions, logQueries, filters []string, conns int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.actions...), append([]string(nil), s.logQueries...), append([]string(nil), s.filters...), s.eventConns
}

func containerEvent(id, action string) map[string]any {
	return map[string]any{"Type": "container", "Action": action, "Actor": map[string]any{"ID": id, "Attributes": map[string]string{}},
		"scope": "local", "time": 1763222700, "timeNano": int64(1763222700000000000)}
}

type statusRecorder struct {
	mu     sync.Mutex
	events map[string][]string
	signal chan struct{}
}

func recordStatus(t *testing.T) *statusRecorder {
	rec := &statusRecorder{events: map[string][]string{}, signal: make(chan struct{}, 1)}
	old := emitStatus
	emitStatus = func(topic, payload string) {
		rec.mu.Lock()
		rec.events[topic] = append(rec.events[topic], payload)
		rec.mu.Unlock()
		select {
		case rec.signal <- struct{}{}:
		default:
		}
	}
	t.Cleanup(func() { emitStatus = old })
	return rec
}

func (rec *statusRecorder) count(topic string) int {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	return len(rec.events[topic])
}

func (rec *statusRecorder) waitFor(t *testing.T, topic string, n int) []string {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		rec.mu.Lock()
		got := append([]string(nil), rec.events[topic]...)
		rec.mu.Unlock()
		if len(got) >= n {
			return got
		}
		select {
		case <-rec.signal:
		case <-time.After(20 * time.Millisecond):
		case <-deadline:
			t.Fatalf("waited for %d %s events, got %d: %v", n, topic, len(got), got)
		}
	}
}

func (rec *statusRecorder) batches(t *testing.T, n int) []Batch {
	t.Helper()
	var out []Batch
	for _, p := range rec.waitFor(t, BatchTopic, n) {
		var b Batch
		if err := json.Unmarshal([]byte(p), &b); err != nil {
			t.Fatal(err)
		}
		out = append(out, b)
	}
	return out
}

func (rec *statusRecorder) logEvents(t *testing.T, n int) []LogsEvent {
	t.Helper()
	var out []LogsEvent
	for _, p := range rec.waitFor(t, LogsTopic, n) {
		var ev LogsEvent
		if err := json.Unmarshal([]byte(p), &ev); err != nil {
			t.Fatal(err)
		}
		out = append(out, ev)
	}
	return out
}

func allLogLines(events []LogsEvent) []LogLine {
	var out []LogLine
	for _, ev := range events {
		out = append(out, ev.Lines...)
	}
	return out
}

func lineTexts(lines []LogLine) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		text := l.Text
		if l.Prefix != "" {
			text = l.Prefix + " | " + text
		}
		if l.Stderr {
			text = "!" + text
		}
		out = append(out, text)
	}
	sort.Strings(out)
	return out
}

func composeLabels(project, service, dir string) map[string]string {
	return map[string]string{
		labelProject: project, labelService: service, labelWorkingDir: dir,
		labelConfigFiles: dir + "/compose.yaml",
	}
}
