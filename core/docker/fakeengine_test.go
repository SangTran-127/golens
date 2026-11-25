package docker

import (
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeLogLine struct {
	Stderr bool
	Text   string
}

type fakeEngine struct {
	Socket     string
	APIVersion string
	Version    string
	Delay      time.Duration
	Containers []map[string]any
	Events     chan map[string]any
	Logs       map[string][]fakeLogLine

	mu       sync.Mutex
	requests []string
	mux      *http.ServeMux
	srv      *http.Server
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "gldk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func newFakeEngine(t *testing.T, configure func(*fakeEngine)) *fakeEngine {
	t.Helper()
	f := &fakeEngine{
		Socket:     filepath.Join(shortTempDir(t), "docker.sock"),
		APIVersion: "1.47",
		Version:    "27.3.1",
		Events:     make(chan map[string]any, 16),
		Logs:       map[string][]fakeLogLine{},
		mux:        http.NewServeMux(),
	}
	if configure != nil {
		configure(f)
	}
	ln, err := net.Listen("unix", f.Socket)
	if err != nil {
		t.Fatal(err)
	}
	f.mux.HandleFunc("GET /_ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("API-Version", f.APIVersion)
		w.Write([]byte("OK"))
	})
	f.mux.HandleFunc("GET /{ver}/version", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"Version": f.Version, "ApiVersion": f.APIVersion, "MinAPIVersion": "1.24", "Os": "linux", "Arch": "arm64"})
	})
	f.mux.HandleFunc("GET /{ver}/containers/json", func(w http.ResponseWriter, r *http.Request) {
		list := f.Containers
		if list == nil {
			list = []map[string]any{}
		}
		writeJSON(w, list)
	})
	f.mux.HandleFunc("GET /{ver}/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		enc := json.NewEncoder(w)
		for {
			select {
			case <-r.Context().Done():
				return
			case ev, ok := <-f.Events:
				if !ok {
					return
				}
				enc.Encode(ev)
				w.(http.Flusher).Flush()
			}
		}
	})
	f.mux.HandleFunc("GET /{ver}/containers/{id}/logs", func(w http.ResponseWriter, r *http.Request) {
		lines, ok := f.Logs[r.PathValue("id")]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			writeJSON(w, map[string]string{"message": "No such container: " + r.PathValue("id")})
			return
		}
		w.Header().Set("Content-Type", "application/vnd.docker.multiplexed-stream")
		for _, l := range lines {
			w.Write(muxFrame(l.Stderr, l.Text+"\n"))
		}
	})
	f.srv = &http.Server{Handler: http.HandlerFunc(f.serve)}
	go f.srv.Serve(ln)
	t.Cleanup(func() { f.srv.Close() })
	return f
}

func (f *fakeEngine) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests = append(f.requests, r.Method+" "+r.URL.Path)
	f.mu.Unlock()
	if f.Delay > 0 {
		select {
		case <-time.After(f.Delay):
		case <-r.Context().Done():
			return
		}
	}
	if r.URL.Path != "/_ping" && !strings.HasPrefix(r.URL.Path, "/v"+f.APIVersionPinned()+"/") {
		w.WriteHeader(http.StatusBadRequest)
		writeJSON(w, map[string]string{"message": "unexpected API version in " + r.URL.Path})
		return
	}
	f.mux.ServeHTTP(w, r)
}

func (f *fakeEngine) APIVersionPinned() string {
	if compareAPIVersion(f.APIVersion, maxAPIVersion) > 0 {
		return maxAPIVersion
	}
	return f.APIVersion
}

func (f *fakeEngine) Handle(pattern string, h http.HandlerFunc) { f.mux.HandleFunc(pattern, h) }

func (f *fakeEngine) Requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.requests...)
}

func (f *fakeEngine) Endpoint() Endpoint {
	return Endpoint{Kind: KindUnix, Host: "unix://" + f.Socket, Socket: f.Socket, Context: "fake", Source: "test"}
}

func muxFrame(stderr bool, text string) []byte {
	hdr := make([]byte, 8)
	hdr[0] = 1
	if stderr {
		hdr[0] = 2
	}
	binary.BigEndian.PutUint32(hdr[4:], uint32(len(text)))
	return append(hdr, text...)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
