package kube

import (
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type testContext struct {
	name      string
	server    string
	namespace string
	token     string
	execCmd   string
	execArgs  []string
}

func writeKubeconfig(t *testing.T, current string, contexts ...testContext) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("apiVersion: v1\nkind: Config\ncurrent-context: " + current + "\nclusters:\n")
	for _, c := range contexts {
		fmt.Fprintf(&b, "- name: %s-cluster\n  cluster:\n    server: %s\n", c.name, c.server)
		if ca, ok := fakeCAs.Load(c.server); ok {
			fmt.Fprintf(&b, "    certificate-authority-data: %s\n", ca)
		}
	}
	b.WriteString("users:\n")
	for _, c := range contexts {
		fmt.Fprintf(&b, "- name: %s-user\n  user:\n", c.name)
		switch {
		case c.execCmd != "":
			fmt.Fprintf(&b, "    exec:\n      apiVersion: client.authentication.k8s.io/v1\n      command: %s\n      interactiveMode: Never\n", c.execCmd)
			if len(c.execArgs) > 0 {
				b.WriteString("      args:\n")
				for _, a := range c.execArgs {
					fmt.Fprintf(&b, "      - %q\n", a)
				}
			}
		case c.token != "":
			fmt.Fprintf(&b, "    token: %s\n", c.token)
		default:
			b.WriteString("    {}\n")
		}
	}
	b.WriteString("contexts:\n")
	for _, c := range contexts {
		fmt.Fprintf(&b, "- name: %s\n  context:\n    cluster: %s-cluster\n    user: %s-user\n", c.name, c.name, c.name)
		if c.namespace != "" {
			fmt.Fprintf(&b, "    namespace: %s\n", c.namespace)
		}
	}
	path := filepath.Join(t.TempDir(), "kubeconfig")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KUBECONFIG", path)
	t.Cleanup(closeClients)
	return path
}

var fakeCAs sync.Map

type fakeAPI struct {
	t       *testing.T
	srv     *httptest.Server
	mu      sync.Mutex
	handler func(w http.ResponseWriter, r *http.Request) bool
	calls   []string
	open    atomic.Int32
}

func newFakeAPI(t *testing.T, handler func(w http.ResponseWriter, r *http.Request) bool) *fakeAPI {
	f := &fakeAPI{t: t, handler: handler}
	f.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.calls = append(f.calls, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery)
		f.mu.Unlock()
		if !f.handler(w, r) {
			writeStatus(w, http.StatusNotFound, "NotFound", "the server could not find the requested resource")
		}
	}))
	f.srv.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		switch state {
		case http.StateNew:
			f.open.Add(1)
		case http.StateClosed, http.StateHijacked:
			f.open.Add(-1)
		}
	}
	f.srv.EnableHTTP2 = true
	f.srv.StartTLS()
	fakeCAs.Store(f.srv.URL, base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.srv.Certificate().Raw})))
	t.Cleanup(func() {
		f.srv.Close()
		fakeCAs.Delete(f.srv.URL)
	})
	return f
}

func (f *fakeAPI) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeStatus(w http.ResponseWriter, code int, reason, message string) {
	writeJSON(w, code, map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": reason, "message": message, "code": code})
}

func podJSON(name, rv string, mutate func(map[string]any)) map[string]any {
	p := map[string]any{
		"metadata": map[string]any{"name": name, "namespace": "api", "resourceVersion": rv, "creationTimestamp": "2026-11-16T08:00:00Z",
			"labels": map[string]any{"app": "api"}},
		"spec": map[string]any{"nodeName": "node-1", "containers": []any{map[string]any{"name": "app", "image": "api:1",
			"ports": []any{map[string]any{"containerPort": 8080}}}}},
		"status": map[string]any{"phase": "Running", "containerStatuses": []any{map[string]any{
			"name": "app", "ready": true, "restartCount": 0, "state": map[string]any{"running": map[string]any{"startedAt": "2026-11-16T08:00:05Z"}}}}},
	}
	if mutate != nil {
		mutate(p)
	}
	return p
}

type collector struct {
	mu     sync.Mutex
	topics map[string][]string
}

func collectStatus(t *testing.T) *collector {
	c := &collector{topics: map[string][]string{}}
	prev, prevDelay, prevLogs, prevDelays := emitStatus, coalesceDelay, logsFlushDelay, reconnectDelays
	emitStatus = func(topic, payload string) {
		c.mu.Lock()
		c.topics[topic] = append(c.topics[topic], payload)
		c.mu.Unlock()
	}
	coalesceDelay, logsFlushDelay = 20*time.Millisecond, 20*time.Millisecond
	reconnectDelays = []time.Duration{10 * time.Millisecond}
	t.Cleanup(func() {
		emitStatus, coalesceDelay, logsFlushDelay, reconnectDelays = prev, prevDelay, prevLogs, prevDelays
	})
	return c
}

func (c *collector) batches() []Batch {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := []Batch{}
	for _, p := range c.topics[BatchTopic] {
		var b Batch
		_ = json.Unmarshal([]byte(p), &b)
		out = append(out, b)
	}
	return out
}

func (c *collector) logs() []LogsEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := []LogsEvent{}
	for _, p := range c.topics[LogsTopic] {
		var e LogsEvent
		_ = json.Unmarshal([]byte(p), &e)
		out = append(out, e)
	}
	return out
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
