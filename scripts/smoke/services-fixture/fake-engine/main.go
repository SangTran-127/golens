package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type container struct {
	ID, Name, Image, ImageID, Command, State string
	ExitCode                                 int
	Created                                  int64
	Labels                                   map[string]string
	Env                                      []string
	PublicPort, PrivatePort                  int
	Volume                                   string
	Lines                                    []string
	StartedAt, FinishedAt                    time.Time
}

type engine struct {
	mu         sync.Mutex
	containers []*container
	images     []map[string]any
	volumes    []map[string]any
	subs       map[chan map[string]any]bool
	requests   *os.File
	noteMu     sync.Mutex
}

func id(seed string) string { return strings.Repeat(seed, 64)[:64] }

func newEngine(project string) *engine {
	compose := filepath.Join(project, "compose.yaml")
	labels := func(proj, service, dir, files string) map[string]string {
		return map[string]string{
			"com.docker.compose.project": proj, "com.docker.compose.service": service,
			"com.docker.compose.project.working_dir": dir, "com.docker.compose.project.config_files": files,
		}
	}
	now := time.Now()
	e := &engine{subs: map[chan map[string]any]bool{}}
	e.containers = []*container{
		{ID: id("a1"), Name: "svcdemo-api-1", Image: "svcdemo-api", ImageID: "sha256:" + id("e1"), Command: "/app/server --addr :8080", State: "running",
			Created: now.Add(-10 * time.Minute).Unix(), Labels: labels("svcdemo", "api", project, compose),
			Env: []string{"DATABASE_URL=postgres://app:s3cret@db/app", "PORT=8080"}, PublicPort: 8080, PrivatePort: 8080,
			Lines: []string{"svcdemo api starting", "listening on :8080"}, StartedAt: now.Add(-9 * time.Minute)},
		{ID: id("b2"), Name: "svcdemo-redis-1", Image: "redis:7", ImageID: "sha256:" + id("e2"), Command: "docker-entrypoint.sh redis-server", State: "exited", ExitCode: 1,
			Created: now.Add(-10 * time.Minute).Unix(), Labels: labels("svcdemo", "redis", project, compose), Env: []string{"REDIS_ARGS=--save 60 1"},
			Volume: "redisdata", Lines: []string{"Ready to accept connections", "fatal: out of memory"}, StartedAt: now.Add(-9 * time.Minute), FinishedAt: now.Add(-2 * time.Minute)},
		{ID: id("c3"), Name: "other-web-1", Image: "nginx:1.27", ImageID: "sha256:" + id("e3"), Command: "nginx -g 'daemon off;'", State: "running",
			Created: now.Add(-2 * time.Hour).Unix(), Labels: labels("other", "web", "/Users/me/src/other", "/Users/me/src/other/compose.yaml"),
			PublicPort: 8081, PrivatePort: 80, Lines: []string{"nginx ready"}, StartedAt: now.Add(-2 * time.Hour)},
		{ID: id("c4"), Name: "other-worker-1", Image: "nginx:1.27", ImageID: "sha256:" + id("e3"), Command: "worker", State: "exited",
			Created: now.Add(-2 * time.Hour).Unix(), Labels: labels("other", "worker", "/Users/me/src/other", "/Users/me/src/other/compose.yaml"),
			Lines: []string{"worker done"}, FinishedAt: now.Add(-time.Hour)},
		{ID: id("d4"), Name: "scratch", Image: "alpine", ImageID: "sha256:" + id("e4"), Command: "sh", State: "running",
			Created: now.Add(-6 * time.Hour).Unix(), Labels: map[string]string{}, Lines: []string{"/ #"}, StartedAt: now.Add(-6 * time.Hour)},
	}
	e.images = []map[string]any{
		{"Id": "sha256:" + id("e1"), "RepoTags": []string{"svcdemo-api:latest"}, "Size": 182000000, "Created": now.Add(-time.Hour).Unix()},
		{"Id": "sha256:" + id("e2"), "RepoTags": []string{"redis:7"}, "Size": 117000000, "Created": now.Add(-48 * time.Hour).Unix()},
		{"Id": "sha256:" + id("e3"), "RepoTags": []string{"nginx:1.27"}, "Size": 192000000, "Created": now.Add(-72 * time.Hour).Unix()},
		{"Id": "sha256:" + id("e4"), "RepoTags": []string{"alpine:latest"}, "Size": 8800000, "Created": now.Add(-96 * time.Hour).Unix()},
		{"Id": "sha256:" + id("e9"), "RepoTags": []string{"<none>:<none>"}, "Size": 5000000, "Created": now.Add(-200 * time.Hour).Unix()},
	}
	e.volumes = []map[string]any{
		{"Name": "redisdata", "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/redisdata/_data", "CreatedAt": now.Add(-time.Hour).Format(time.RFC3339), "Labels": map[string]string{"com.docker.compose.project": "svcdemo"}},
		{"Name": "orphan", "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/orphan/_data", "CreatedAt": now.Add(-50 * time.Hour).Format(time.RFC3339), "Labels": map[string]string{}},
	}
	return e
}

func status(c *container) string {
	if c.State == "running" {
		return "Up " + humanize(time.Since(c.StartedAt))
	}
	return fmt.Sprintf("Exited (%d) %s ago", c.ExitCode, humanize(time.Since(c.FinishedAt)))
}

func humanize(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "Less than a second"
	case d < time.Hour:
		return fmt.Sprintf("%d minutes", int(d.Minutes()))
	default:
		return fmt.Sprintf("%d hours", int(d.Hours()))
	}
}

func (e *engine) find(ref string) *container {
	for _, c := range e.containers {
		if c.ID == ref || c.Name == ref || strings.HasPrefix(c.ID, ref) {
			return c
		}
	}
	return nil
}

func (e *engine) summary(c *container) map[string]any {
	ports := []map[string]any{}
	if c.PrivatePort > 0 {
		p := map[string]any{"PrivatePort": c.PrivatePort, "Type": "tcp"}
		if c.PublicPort > 0 && c.State == "running" {
			p["PublicPort"], p["IP"] = c.PublicPort, "0.0.0.0"
		}
		ports = append(ports, p)
	}
	mounts := []map[string]any{}
	if c.Volume != "" {
		mounts = append(mounts, map[string]any{"Type": "volume", "Name": c.Volume})
	}
	return map[string]any{"Id": c.ID, "Names": []string{"/" + c.Name}, "Image": c.Image, "ImageID": c.ImageID, "Command": c.Command,
		"Created": c.Created, "State": c.State, "Status": status(c), "Ports": ports, "Labels": c.Labels, "Mounts": mounts}
}

func (e *engine) inspect(c *container) map[string]any {
	ports := map[string]any{}
	if c.PrivatePort > 0 {
		var bind any
		if c.PublicPort > 0 && c.State == "running" {
			bind = []map[string]string{{"HostIp": "0.0.0.0", "HostPort": fmt.Sprint(c.PublicPort)}}
		}
		ports[fmt.Sprintf("%d/tcp", c.PrivatePort)] = bind
	}
	mounts := []map[string]any{}
	if c.Volume != "" {
		mounts = append(mounts, map[string]any{"Type": "volume", "Name": c.Volume, "Source": "/var/lib/docker/volumes/" + c.Volume + "/_data", "Destination": "/data", "Mode": "z", "RW": true})
	}
	finished := "0001-01-01T00:00:00Z"
	if !c.FinishedAt.IsZero() {
		finished = c.FinishedAt.UTC().Format(time.RFC3339Nano)
	}
	return map[string]any{
		"Id": c.ID, "Name": "/" + c.Name, "Image": c.ImageID, "Created": time.Unix(c.Created, 0).UTC().Format(time.RFC3339Nano),
		"Path": strings.Fields(c.Command)[0], "Args": strings.Fields(c.Command)[1:],
		"State": map[string]any{"Status": c.State, "Running": c.State == "running", "ExitCode": c.ExitCode,
			"StartedAt": c.StartedAt.UTC().Format(time.RFC3339Nano), "FinishedAt": finished},
		"HostConfig": map[string]any{"RestartPolicy": map[string]any{"Name": "unless-stopped"}},
		"Mounts":     mounts,
		"Config":     map[string]any{"Image": c.Image, "Env": c.Env, "Labels": c.Labels, "Tty": false, "WorkingDir": "/app"},
		"NetworkSettings": map[string]any{"Ports": ports, "Networks": map[string]any{
			"svcdemo_default": map[string]any{"IPAddress": "172.18.0.2", "Gateway": "172.18.0.1", "MacAddress": "02:42:ac:12:00:02", "Aliases": []string{c.Name}}}},
	}
}

func (e *engine) publish(kind, action, actor string) {
	ev := map[string]any{"Type": kind, "Action": action, "Actor": map[string]any{"ID": actor}, "timeNano": time.Now().UnixNano()}
	for ch := range e.subs {
		select {
		case ch <- ev:
		default:
		}
	}
}

func (e *engine) note(line string) {
	if e.requests == nil {
		return
	}
	e.noteMu.Lock()
	defer e.noteMu.Unlock()
	fmt.Fprintf(e.requests, "%d %s\n", time.Now().UnixMilli(), line)
}

func (e *engine) stopExternally(name string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if c := e.find(name); c != nil && c.State == "running" {
		c.State, c.ExitCode, c.FinishedAt = "exited", 0, time.Now()
		e.note("EXTERNAL stop " + name)
		e.publish("container", "die", c.ID)
		e.publish("container", "stop", c.ID)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func frame(stderr bool, text string) []byte {
	hdr := make([]byte, 8)
	hdr[0] = 1
	if stderr {
		hdr[0] = 2
	}
	binary.BigEndian.PutUint32(hdr[4:], uint32(len(text)))
	return append(hdr, text...)
}

func (e *engine) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /_ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("API-Version", "1.47")
		w.Write([]byte("OK"))
	})
	mux.HandleFunc("GET /{ver}/version", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"Version": "27.3.1", "ApiVersion": "1.47", "MinAPIVersion": "1.24", "Os": "linux", "Arch": "arm64"})
	})
	mux.HandleFunc("GET /{ver}/containers/json", func(w http.ResponseWriter, r *http.Request) {
		var filters map[string][]string
		json.Unmarshal([]byte(r.URL.Query().Get("filters")), &filters)
		e.mu.Lock()
		defer e.mu.Unlock()
		out := []map[string]any{}
		for _, c := range e.containers {
			if ids := filters["id"]; len(ids) > 0 {
				match := false
				for _, want := range ids {
					match = match || strings.HasPrefix(c.ID, want)
				}
				if !match {
					continue
				}
			}
			out = append(out, e.summary(c))
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /{ver}/containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		c := e.find(r.PathValue("id"))
		if c == nil {
			writeJSON(w, 404, map[string]string{"message": "No such container: " + r.PathValue("id")})
			return
		}
		writeJSON(w, 200, e.inspect(c))
	})
	mux.HandleFunc("POST /{ver}/containers/{id}/{action}", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		c := e.find(r.PathValue("id"))
		if c == nil {
			writeJSON(w, 404, map[string]string{"message": "No such container"})
			return
		}
		switch r.PathValue("action") {
		case "start", "restart":
			c.State, c.ExitCode, c.StartedAt = "running", 0, time.Now()
			c.Lines = append(c.Lines, c.Name+" started")
			e.publish("container", "start", c.ID)
		case "stop":
			c.State, c.ExitCode, c.FinishedAt = "exited", 0, time.Now()
			e.publish("container", "die", c.ID)
			e.publish("container", "stop", c.ID)
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("DELETE /{ver}/containers/{id}", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		c := e.find(r.PathValue("id"))
		if c == nil {
			writeJSON(w, 404, map[string]string{"message": "No such container"})
			return
		}
		if c.State == "running" {
			writeJSON(w, 409, map[string]string{"message": "cannot remove container: container is running"})
			return
		}
		for i, x := range e.containers {
			if x == c {
				e.containers = append(e.containers[:i], e.containers[i+1:]...)
				break
			}
		}
		e.publish("container", "destroy", c.ID)
		w.WriteHeader(204)
	})
	mux.HandleFunc("GET /{ver}/containers/{id}/logs", func(w http.ResponseWriter, r *http.Request) {
		defer e.note("END GET " + r.URL.Path)
		e.mu.Lock()
		c := e.find(r.PathValue("id"))
		var lines []string
		if c != nil {
			lines = append(lines, c.Lines...)
		}
		e.mu.Unlock()
		if c == nil {
			writeJSON(w, 404, map[string]string{"message": "No such container"})
			return
		}
		w.Header().Set("Content-Type", "application/vnd.docker.multiplexed-stream")
		w.WriteHeader(200)
		for _, l := range lines {
			w.Write(frame(strings.HasPrefix(l, "fatal"), l+"\n"))
		}
		w.(http.Flusher).Flush()
		if r.URL.Query().Get("follow") != "1" {
			return
		}
		tick := time.NewTicker(2 * time.Second)
		defer tick.Stop()
		n := 0
		for {
			select {
			case <-r.Context().Done():
				return
			case <-tick.C:
				e.mu.Lock()
				running := c.State == "running"
				e.mu.Unlock()
				if !running {
					return
				}
				if c.PublicPort > 0 {
					n++
					w.Write(frame(false, fmt.Sprintf("GET /health 200 %dms request=%d\n", 1+n%5, n)))
					w.(http.Flusher).Flush()
				}
			}
		}
	})
	mux.HandleFunc("GET /{ver}/events", func(w http.ResponseWriter, r *http.Request) {
		defer e.note("END GET " + r.URL.Path)
		ch := make(chan map[string]any, 32)
		e.mu.Lock()
		e.subs[ch] = true
		e.mu.Unlock()
		defer func() {
			e.mu.Lock()
			delete(e.subs, ch)
			e.mu.Unlock()
		}()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		enc := json.NewEncoder(w)
		for {
			select {
			case <-r.Context().Done():
				return
			case ev := <-ch:
				enc.Encode(ev)
				w.(http.Flusher).Flush()
			}
		}
	})
	mux.HandleFunc("GET /{ver}/images/json", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		writeJSON(w, 200, e.images)
	})
	mux.HandleFunc("GET /{ver}/images/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		for _, img := range e.images {
			if img["Id"] == r.PathValue("id") || strings.HasPrefix(img["Id"].(string), "sha256:"+r.PathValue("id")) {
				writeJSON(w, 200, map[string]any{"Id": img["Id"], "RepoTags": img["RepoTags"]})
				return
			}
		}
		writeJSON(w, 404, map[string]string{"message": "No such image"})
	})
	mux.HandleFunc("DELETE /{ver}/images/{id}", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		for i, img := range e.images {
			tags, _ := img["RepoTags"].([]string)
			if img["Id"] == r.PathValue("id") || (len(tags) > 0 && tags[0] == r.PathValue("id")) {
				e.images = append(e.images[:i], e.images[i+1:]...)
				e.publish("image", "delete", r.PathValue("id"))
				writeJSON(w, 200, []map[string]string{{"Deleted": r.PathValue("id")}})
				return
			}
		}
		writeJSON(w, 404, map[string]string{"message": "No such image"})
	})
	mux.HandleFunc("GET /{ver}/volumes", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		writeJSON(w, 200, map[string]any{"Volumes": e.volumes, "Warnings": []string{}})
	})
	mux.HandleFunc("DELETE /{ver}/volumes/{name}", func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		defer e.mu.Unlock()
		for i, v := range e.volumes {
			if v["Name"] == r.PathValue("name") {
				e.volumes = append(e.volumes[:i], e.volumes[i+1:]...)
				e.publish("volume", "destroy", r.PathValue("name"))
				w.WriteHeader(204)
				return
			}
		}
		writeJSON(w, 404, map[string]string{"message": "No such volume"})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.note(r.Method + " " + r.URL.Path)
		mux.ServeHTTP(w, r)
	})
}

func main() {
	socket := flag.String("socket", "", "Unix socket path to listen on")
	project := flag.String("project", "", "fixture project folder (This Project)")
	requests := flag.String("requests", "", "file that receives one line per request")
	flag.Parse()
	if *socket == "" || *project == "" {
		log.Fatal("usage: fake-engine -socket path -project dir [-requests file]")
	}
	os.Remove(*socket)
	ln, err := net.Listen("unix", *socket)
	if err != nil {
		log.Fatal(err)
	}
	e := newEngine(*project)
	if *requests != "" {
		if e.requests, err = os.Create(*requests); err != nil {
			log.Fatal(err)
		}
	}
	var open atomic.Int64
	srv := &http.Server{Handler: e.routes(), ConnState: func(_ net.Conn, st http.ConnState) {
		switch st {
		case http.StateNew:
			open.Add(1)
		case http.StateClosed, http.StateHijacked:
			open.Add(-1)
		default:
			return
		}
		e.note(fmt.Sprintf("CONN %s open=%d", st, open.Load()))
	}}
	go srv.Serve(ln)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGUSR1)
	for s := range sig {
		if s != syscall.SIGUSR1 {
			break
		}
		e.stopExternally("svcdemo-api-1")
	}
	srv.Close()
	os.Remove(*socket)
}
