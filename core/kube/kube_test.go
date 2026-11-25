package kube

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestContextsReportServerDefaultNamespaceAndLocality(t *testing.T) {
	writeKubeconfig(t, "staging",
		testContext{name: "kind-dev", server: "https://127.0.0.1:6443", token: "x"},
		testContext{name: "staging", server: "https://k8s.example.test", namespace: "api", execCmd: "gke-gcloud-auth-plugin"},
	)
	r := Contexts()
	if !r.Available || r.Current != "staging" || r.Error != nil || len(r.Contexts) != 2 {
		t.Fatalf("reply = %+v", r)
	}
	dev, staging := r.Contexts[0], r.Contexts[1]
	if dev.Name != "kind-dev" || dev.Namespace != "default" || !dev.Local || dev.Current || dev.Server != "https://127.0.0.1:6443" {
		t.Fatalf("dev = %+v", dev)
	}
	if staging.Namespace != "api" || staging.Local || !staging.Current || staging.Server != "https://k8s.example.test" || staging.AuthPlugin != "gke-gcloud-auth-plugin" {
		t.Fatalf("staging = %+v", staging)
	}
}

func TestContextsWithoutKubeconfigAreUnavailable(t *testing.T) {
	t.Setenv("KUBECONFIG", filepath.Join(t.TempDir(), "missing"))
	r := Contexts()
	if r.Available || len(r.Contexts) != 0 || r.Error != nil {
		t.Fatalf("reply = %+v", r)
	}
}

func TestLooksLocal(t *testing.T) {
	cases := map[[2]string]bool{
		{"orbstack", "https://k8s.orb.local:26443"}:   true,
		{"x", "https://localhost:6443"}:               true,
		{"x", "https://[::1]:6443"}:                   true,
		{"docker-desktop", "https://10.0.0.1"}:        true,
		{"x", "https://kubernetes.docker.internal"}:   true,
		{"prod", "https://34.1.2.3"}:                  false,
		{"prod", "https://abc.gr7.eks.amazonaws.com"}: false,
	}
	for in, want := range cases {
		if got := looksLocal(in[0], in[1]); got != want {
			t.Errorf("looksLocal(%q, %q) = %v", in[0], in[1], got)
		}
	}
}

func TestNamespacesForbiddenKeepsDefaultNamespace(t *testing.T) {
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path == "/api/v1/namespaces" {
			writeStatus(w, http.StatusForbidden, "Forbidden", `namespaces is forbidden: User "dev" cannot list resource "namespaces"`)
			return true
		}
		return false
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	r := Namespaces("")
	if r.Context != "dev" || r.DefaultNamespace != "api" || r.Error == nil {
		t.Fatalf("reply = %+v", r)
	}
	e := r.Error
	if e.Kind != KindForbidden || e.Verb != "list" || e.Resource != "namespaces" || e.Namespace != "" ||
		e.Message != "Your account can’t list namespaces in this cluster." {
		t.Fatalf("error = %+v", e)
	}
}

func TestNamespacesListDefaultFirst(t *testing.T) {
	var auth atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		auth.Store(r.Header.Get("Authorization"))
		writeJSON(w, 200, map[string]any{"items": []any{
			map[string]any{"metadata": map[string]any{"name": "a"}, "status": map[string]any{"phase": "Active"}},
			map[string]any{"metadata": map[string]any{"name": "api"}, "status": map[string]any{"phase": "Active"}},
			map[string]any{"metadata": map[string]any{"name": "b"}, "status": map[string]any{"phase": "Terminating"}},
		}})
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "secret-token"})
	r := Namespaces("dev")
	got := []string{}
	for _, n := range r.Namespaces {
		got = append(got, n.Name)
	}
	if r.Error != nil || !reflect.DeepEqual(got, []string{"api", "a", "b"}) || r.Namespaces[2].Phase != "Terminating" {
		t.Fatalf("reply = %+v", r)
	}
	if auth.Load() != "Bearer secret-token" {
		t.Fatalf("authorization = %v", auth.Load())
	}
}

func TestWatchRelistsAfterExpiredResourceVersion(t *testing.T) {
	c := collectStatus(t)
	var lists, watchCalls atomic.Int32
	var bookmarks atomic.Bool
	closed := make(chan struct{}, 4)
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/api/v1/namespaces/api/pods" {
			return false
		}
		q := r.URL.Query()
		if q.Get("watch") == "" {
			n := lists.Add(1)
			items := []any{podJSON("a", "5", nil), podJSON("b", "6", nil)}
			if n > 1 {
				items = append(items, podJSON("c", "19", nil))
			}
			writeJSON(w, 200, map[string]any{"metadata": map[string]any{"resourceVersion": strconv.Itoa(int(n) * 10)}, "items": items})
			return true
		}
		bookmarks.Store(q.Get("allowWatchBookmarks") == "true")
		switch watchCalls.Add(1) {
		case 1:
			if q.Get("resourceVersion") != "10" {
				t.Errorf("first watch rv = %q", q.Get("resourceVersion"))
			}
			writeJSON(w, 200, map[string]any{"type": "ERROR", "object": map[string]any{"kind": "Status", "code": 410, "reason": "Expired", "message": "too old resource version"}})
		case 2:
			writeStatus(w, http.StatusGone, "Gone", "too old resource version")
		default:
			if q.Get("resourceVersion") != "30" {
				t.Errorf("watch after relist rv = %q", q.Get("resourceVersion"))
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			enc := json.NewEncoder(w)
			_ = enc.Encode(map[string]any{"type": "BOOKMARK", "object": map[string]any{"metadata": map[string]any{"resourceVersion": "31"}}})
			_ = enc.Encode(map[string]any{"type": "MODIFIED", "object": podJSON("a", "32", func(p map[string]any) {
				p["status"].(map[string]any)["containerStatuses"] = []any{map[string]any{"name": "app", "restartCount": 5,
					"state": map[string]any{"waiting": map[string]any{"reason": "CrashLoopBackOff"}}}}
			})})
			_ = enc.Encode(map[string]any{"type": "DELETED", "object": podJSON("b", "33", nil)})
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			closed <- struct{}{}
		}
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	id := WatchStart("dev", "", []string{"pods"})
	waitFor(t, "incremental batch after relist", func() bool {
		for _, b := range c.batches() {
			if !b.Reset && len(b.Removals) == 1 {
				return true
			}
		}
		return false
	})
	WatchStop(id)
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("watch connection stayed open after stop")
	}
	if !bookmarks.Load() {
		t.Error("watch did not ask for bookmarks")
	}
	var states []string
	var resets []int
	var last Batch
	for _, b := range c.batches() {
		if b.Watch != id || b.Kind != "pods" || b.Context != "dev" || b.Namespace != "api" {
			t.Fatalf("batch = %+v", b)
		}
		states = append(states, b.State)
		if b.Reset {
			resets = append(resets, len(b.Upserts))
		}
		last = b
	}
	if !reflect.DeepEqual(resets, []int{2, 3, 3}) || states[1] != StateRelisting {
		t.Fatalf("states = %v resets = %v", states, resets)
	}
	var a Pod
	_ = json.Unmarshal(last.Upserts[0], &a)
	if last.Total != 2 || len(last.Upserts) != 1 || a.Name != "a" || a.Status != "CrashLoopBackOff" || a.Tone != ToneFailure || a.Restarts != 5 ||
		!reflect.DeepEqual(last.Removals, []string{"b"}) {
		t.Fatalf("last = %+v pod = %+v", last, a)
	}
	n := len(c.batches())
	time.Sleep(50 * time.Millisecond)
	if len(c.batches()) != n {
		t.Fatal("batches arrived after stop")
	}
}

func TestWatchCapsRowsAndCountsTotal(t *testing.T) {
	c := collectStatus(t)
	const total = 620
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/api/v1/namespaces/api/pods" {
			return false
		}
		q := r.URL.Query()
		if q.Get("watch") != "" {
			<-r.Context().Done()
			return true
		}
		limit, _ := strconv.Atoi(q.Get("limit"))
		start, _ := strconv.Atoi(q.Get("continue"))
		end := min(start+limit, total)
		items := []any{}
		for i := start; i < end; i++ {
			items = append(items, podJSON(fmt.Sprintf("pod-%04d", total-1-i), "1", nil))
		}
		meta := map[string]any{"resourceVersion": "7"}
		if end < total {
			meta["continue"] = strconv.Itoa(end)
		}
		writeJSON(w, 200, map[string]any{"metadata": meta, "items": items})
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	id := WatchStart("dev", "api", []string{"pod"})
	defer WatchStop(id)
	waitFor(t, "reset batch", func() bool { return len(c.batches()) > 0 })
	b := c.batches()[0]
	var first, lastPod Pod
	_ = json.Unmarshal(b.Upserts[0], &first)
	_ = json.Unmarshal(b.Upserts[len(b.Upserts)-1], &lastPod)
	if !b.Reset || b.Total != total || !b.Truncated || len(b.Upserts) != MaxRows || first.Name != "pod-0000" || lastPod.Name != "pod-0499" {
		t.Fatalf("batch total=%d truncated=%v rows=%d first=%s last=%s", b.Total, b.Truncated, len(b.Upserts), first.Name, lastPod.Name)
	}
}

func TestWatchChangesNamespaceClosesPreviousWatch(t *testing.T) {
	collectStatus(t)
	open := map[string]*atomic.Int32{"a": {}, "b": {}}
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		_, rest, _ := strings.Cut(r.URL.Path, "/namespaces/")
		ns, _, _ := strings.Cut(rest, "/")
		if r.URL.Query().Get("watch") == "" {
			writeJSON(w, 200, map[string]any{"metadata": map[string]any{"resourceVersion": "1"}, "items": []any{}})
			return true
		}
		open[ns].Add(1)
		<-r.Context().Done()
		open[ns].Add(-1)
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, token: "t"})
	first := WatchStart("dev", "a", []string{"pods", "services"})
	waitFor(t, "two watches in a", func() bool { return open["a"].Load() == 2 })
	if again := WatchStart("dev", "a", []string{"pods"}); again != first {
		t.Fatalf("same namespace changed the id: %d != %d", again, first)
	}
	waitFor(t, "services watch closed", func() bool { return open["a"].Load() == 1 })
	second := WatchStart("dev", "b", []string{"deployments"})
	defer WatchStop(second)
	if second == first {
		t.Fatal("a new namespace kept the old id")
	}
	waitFor(t, "namespace a closed and b open", func() bool { return open["a"].Load() == 0 && open["b"].Load() == 1 })
}

func TestLogsPreviousForContainer(t *testing.T) {
	c := collectStatus(t)
	var query atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/api/v1/namespaces/api/pods/api-1/log" {
			return false
		}
		query.Store(r.URL.Query())
		io.WriteString(w, "2026-11-16T08:00:00.000000001Z panic: boom\n2026-11-16T08:00:00.000000002Z goroutine 1 [running]:\n")
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	id := LogsOpen(LogsOptions{Context: "dev", Pod: "api-1", Container: "sidecar", Previous: true, Tail: 500})
	waitFor(t, "closed event", func() bool {
		ev := c.logs()
		return len(ev) > 0 && ev[len(ev)-1].Closed
	})
	q := query.Load().(url.Values)
	if q["previous"][0] != "true" || q["container"][0] != "sidecar" || q["tailLines"][0] != "500" || q["follow"] != nil {
		t.Fatalf("query = %v", q)
	}
	var text []string
	for _, ev := range c.logs() {
		if ev.Stream != id {
			t.Fatalf("stream = %d", ev.Stream)
		}
		for _, l := range ev.Lines {
			text = append(text, l.Text)
		}
	}
	last := c.logs()[len(c.logs())-1]
	if !reflect.DeepEqual(text, []string{"panic: boom", "goroutine 1 [running]:"}) || last.Reason != "ended" || last.Error != nil {
		t.Fatalf("lines = %q last = %+v", text, last)
	}
}

func TestLogsFollowResumesWithoutDuplicates(t *testing.T) {
	c := collectStatus(t)
	var calls atomic.Int32
	var second atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		switch r.URL.Path {
		case "/api/v1/namespaces/api/pods/api-1":
			writeJSON(w, 200, podJSON("api-1", "1", nil))
		case "/api/v1/namespaces/api/pods/api-1/log":
			switch calls.Add(1) {
			case 1:
				io.WriteString(w, "2026-11-16T08:00:01Z one\n2026-11-16T08:00:02Z two\n")
			case 2:
				second.Store(r.URL.Query())
				io.WriteString(w, "2026-11-16T08:00:02Z two\n2026-11-16T08:00:03Z three\n")
				w.(http.Flusher).Flush()
				<-r.Context().Done()
			}
		default:
			return false
		}
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	id := LogsOpen(LogsOptions{Context: "dev", Pod: "api-1", Tail: 10})
	lines := func() []string {
		var out []string
		for _, ev := range c.logs() {
			for _, l := range ev.Lines {
				out = append(out, l.Text)
			}
		}
		return out
	}
	waitFor(t, "three lines", func() bool { return len(lines()) >= 3 })
	LogsClose(id)
	if got := lines(); !reflect.DeepEqual(got, []string{"one", "two", "three"}) {
		t.Fatalf("lines = %q", got)
	}
	q := second.Load().(url.Values)
	if q["sinceTime"][0] != "2026-11-16T08:00:02Z" || q["tailLines"] != nil || q["follow"][0] != "true" {
		t.Fatalf("resume query = %v", q)
	}
}

func TestDeletePod(t *testing.T) {
	var got atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		got.Store(r.Method + " " + r.URL.Path)
		if r.URL.Path == "/api/v1/namespaces/api/pods/locked" {
			writeStatus(w, http.StatusForbidden, "Forbidden", "pods \"locked\" is forbidden")
			return true
		}
		writeJSON(w, 200, map[string]any{"kind": "Pod"})
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	if r := DeletePod("dev", "api", "api-1"); !r.OK || r.Error != nil || got.Load() != "DELETE /api/v1/namespaces/api/pods/api-1" {
		t.Fatalf("reply = %+v request = %v", r, got.Load())
	}
	r := DeletePod("dev", "api", "locked")
	if r.OK || r.Error == nil || r.Error.Kind != KindForbidden || r.Error.Verb != "delete" || r.Error.Resource != "pods" ||
		r.Error.Message != "Your account can’t delete pods in “api”." {
		t.Fatalf("reply = %+v", r.Error)
	}
}

func TestRolloutRestartPatchBody(t *testing.T) {
	prev := now
	now = func() time.Time { return time.Date(2026, 11, 16, 17, 30, 0, 0, time.FixedZone("ICT", 7*3600)) }
	t.Cleanup(func() { now = prev })
	var method, path, contentType, body atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		b, _ := io.ReadAll(r.Body)
		method.Store(r.Method)
		path.Store(r.URL.Path)
		contentType.Store(r.Header.Get("Content-Type"))
		body.Store(string(b))
		writeJSON(w, 200, map[string]any{"kind": "Deployment"})
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	if r := RolloutRestart("dev", "", "api"); !r.OK {
		t.Fatalf("reply = %+v", r.Error)
	}
	want := `{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"2026-11-16T17:30:00+07:00"}}}}}`
	if method.Load() != "PATCH" || path.Load() != "/apis/apps/v1/namespaces/api/deployments/api" ||
		contentType.Load() != "application/strategic-merge-patch+json" || body.Load() != want {
		t.Fatalf("%v %v %v %v", method.Load(), path.Load(), contentType.Load(), body.Load())
	}
}

func TestWatchStopClosesHTTP2Connections(t *testing.T) {
	collectStatus(t)
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/api/v1/namespaces/api/pods" {
			return false
		}
		if r.URL.Query().Get("watch") == "" {
			writeJSON(w, 200, map[string]any{"metadata": map[string]any{"resourceVersion": "1"}, "items": []any{podJSON("a", "1", nil)}})
			return true
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	id := WatchStart("dev", "api", []string{"pods"})
	waitFor(t, "the watch request", func() bool {
		for _, call := range f.requests() {
			if strings.Contains(call, "watch=1") || strings.Contains(call, "watch=true") {
				return true
			}
		}
		return false
	})
	if n := f.open.Load(); n < 1 {
		t.Fatalf("open connections while watching = %d", n)
	}
	WatchStop(id)
	waitFor(t, "every connection to close", func() bool { return f.open.Load() == 0 })
}

func TestMissingObjectsReadAsPlainSentences(t *testing.T) {
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		parts := strings.Split(r.URL.Path, "/")
		name, resource := parts[len(parts)-1], parts[len(parts)-2]
		writeJSON(w, http.StatusNotFound, map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "NotFound",
			"message": resource + ".apps \"" + name + "\" not found", "code": 404,
			"details": map[string]any{"name": name, "group": "apps", "kind": resource}})
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	restart := RolloutRestart("dev", "api", "x")
	if restart.Error == nil || restart.Error.Kind != KindNotFound || restart.Error.Message != "The deployment “x” doesn’t exist in “api”." {
		t.Fatalf("restart error = %+v", restart.Error)
	}
	del := DeletePod("dev", "api", "gone-1")
	if del.Error == nil || del.Error.Kind != KindNotFound || del.Error.Message != "The pod “gone-1” doesn’t exist in “api”." {
		t.Fatalf("delete error = %+v", del.Error)
	}
}

func TestExecPluginNotFound(t *testing.T) {
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool { return false })
	writeKubeconfig(t, "gke", testContext{name: "gke", server: f.srv.URL, execCmd: "golens-test-missing-auth-plugin"})
	r := Namespaces("gke")
	if r.Error == nil || r.Error.Kind != KindPluginMissing || r.Error.Plugin != "golens-test-missing-auth-plugin" ||
		r.Error.Message != "Couldn’t sign in to “gke” because the credential helper “golens-test-missing-auth-plugin” wasn’t found." {
		t.Fatalf("error = %+v", r.Error)
	}
	if n := len(f.requests()); n != 0 {
		t.Fatalf("%d requests reached the cluster", n)
	}
}

func TestExpiredSignInSuggestsTerminalCommand(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\necho 'Error when retrieving token from sso: Token has expired and refresh failed' >&2\nexit 255\n"
	if err := os.WriteFile(filepath.Join(dir, "aws"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool { return false })
	writeKubeconfig(t, "eks", testContext{name: "eks", server: f.srv.URL, execCmd: filepath.Join(dir, "aws"),
		execArgs: []string{"eks", "get-token", "--cluster-name", "demo", "--profile", "dev"}})
	r := Namespaces("eks")
	e := r.Error
	if e == nil || e.Kind != KindNeedsSignIn || e.Plugin != "aws" || !reflect.DeepEqual(e.SignInCommand, []string{"aws", "sso", "login", "--profile", "dev"}) ||
		e.Message != "Your sign-in for “eks” has expired; run “aws sso login --profile dev” in Terminal to sign in again." {
		t.Fatalf("error = %+v", e)
	}
	if n := len(f.requests()); n != 0 {
		t.Fatalf("%d requests reached the cluster", n)
	}
}

func TestUnreachableNamesServer(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := "http://" + l.Addr().String()
	l.Close()
	writeKubeconfig(t, "dev", testContext{name: "dev", server: server, token: "t"})
	r := Namespaces("dev")
	if r.Error == nil || r.Error.Kind != KindUnreachable || r.Error.Server != server ||
		r.Error.Message != "GoLens can’t reach the cluster at "+server+"." {
		t.Fatalf("error = %+v", r.Error)
	}
}

func TestDetailsOfPodWithEvents(t *testing.T) {
	var selector atomic.Value
	f := newFakeAPI(t, func(w http.ResponseWriter, r *http.Request) bool {
		switch r.URL.Path {
		case "/api/v1/namespaces/api/pods/api-1":
			writeJSON(w, 200, podJSON("api-1", "1", func(p map[string]any) {
				p["metadata"].(map[string]any)["ownerReferences"] = []any{map[string]any{"kind": "ReplicaSet", "name": "api-7d9f8", "controller": true}}
				p["status"].(map[string]any)["containerStatuses"] = []any{map[string]any{"name": "app", "ready": true, "restartCount": 1,
					"state":     map[string]any{"running": map[string]any{"startedAt": "2026-11-16T08:10:00Z"}},
					"lastState": map[string]any{"terminated": map[string]any{"reason": "OOMKilled", "exitCode": 137, "finishedAt": "2026-11-16T08:09:59Z"}}}}
			}))
		case "/api/v1/namespaces/api/events":
			selector.Store(r.URL.Query().Get("fieldSelector"))
			writeJSON(w, 200, map[string]any{"items": []any{
				map[string]any{"type": "Normal", "reason": "Pulled", "message": "pulled", "count": 1, "lastTimestamp": "2026-11-16T08:00:02Z"},
				map[string]any{"type": "Warning", "reason": "BackOff", "message": "back-off", "count": 3, "lastTimestamp": "2026-11-16T08:09:58Z"},
			}})
		default:
			return false
		}
		return true
	})
	writeKubeconfig(t, "dev", testContext{name: "dev", server: f.srv.URL, namespace: "api", token: "t"})
	d := DetailsOf("dev", "api", "pod", "api-1")
	if d.Error != nil || d.Kind != "pods" || len(d.Containers) != 1 || len(d.Events) != 2 {
		t.Fatalf("details = %+v", d)
	}
	if selector.Load() != "involvedObject.name=api-1,involvedObject.kind=Pod" {
		t.Fatalf("selector = %v", selector.Load())
	}
	cd := d.Containers[0]
	if cd.State != "running" || cd.Restarts != 1 || cd.LastTermination == nil || cd.LastTermination.Reason != "OOMKilled" || cd.LastTermination.ExitCode != 137 {
		t.Fatalf("container = %+v", cd)
	}
	if d.Events[0].Reason != "BackOff" || d.Events[0].Type != "Warning" {
		t.Fatalf("events not newest first: %+v", d.Events)
	}
	found := false
	for _, it := range d.Overview {
		found = found || it.Label == "Controlled By" && it.Value == "ReplicaSet api-7d9f8"
	}
	if !found {
		t.Fatalf("overview = %+v", d.Overview)
	}
}

func TestClientCacheFollowsKubeconfigChanges(t *testing.T) {
	writeKubeconfig(t, "dev", testContext{name: "dev", server: "https://127.0.0.1:1", token: "a"})
	first, err := clientFor("dev")
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := clientFor("dev"); again != first {
		t.Fatal("unchanged kubeconfig built a new client")
	}
	writeKubeconfig(t, "dev", testContext{name: "dev", server: "https://127.0.0.1:2", token: "a"})
	if changed, _ := clientFor("dev"); changed == first || changed.server != "https://127.0.0.1:2" {
		t.Fatal("changed kubeconfig reused the old client")
	}
}

func TestPodStatusSummary(t *testing.T) {
	waiting := func(reason string) func(map[string]any) {
		return func(p map[string]any) {
			p["status"].(map[string]any)["containerStatuses"] = []any{map[string]any{"name": "app", "restartCount": 2,
				"state": map[string]any{"waiting": map[string]any{"reason": reason}}}}
		}
	}
	cases := []struct {
		name   string
		mutate func(map[string]any)
		status string
		tone   string
		ready  int
	}{
		{"running", nil, "Running", ToneOK, 1},
		{"crash", waiting("CrashLoopBackOff"), "CrashLoopBackOff", ToneFailure, 0},
		{"pull", waiting("ImagePullBackOff"), "ImagePullBackOff", ToneFailure, 0},
		{"creating", waiting("ContainerCreating"), "ContainerCreating", ToneWarning, 0},
		{"init", func(p map[string]any) {
			p["spec"].(map[string]any)["initContainers"] = []any{map[string]any{"name": "migrate"}}
			p["status"].(map[string]any)["initContainerStatuses"] = []any{map[string]any{"name": "migrate",
				"state": map[string]any{"running": map[string]any{}}}}
			p["status"].(map[string]any)["containerStatuses"] = []any{}
		}, "Init:0/1", ToneWarning, 0},
		{"terminating", func(p map[string]any) { p["metadata"].(map[string]any)["deletionTimestamp"] = "2026-11-16T09:00:00Z" }, "Terminating", ToneWarning, 1},
		{"completed", func(p map[string]any) {
			p["status"].(map[string]any)["phase"] = "Succeeded"
			p["status"].(map[string]any)["containerStatuses"] = []any{map[string]any{"name": "app",
				"state": map[string]any{"terminated": map[string]any{"reason": "Completed", "exitCode": 0}}}}
		}, "Completed", ToneNeutral, 0},
		{"evicted", func(p map[string]any) {
			p["status"].(map[string]any)["phase"] = "Failed"
			p["status"].(map[string]any)["reason"] = "Evicted"
			p["status"].(map[string]any)["containerStatuses"] = []any{}
		}, "Evicted", ToneFailure, 0},
	}
	for _, tc := range cases {
		raw, _ := json.Marshal(podJSON(tc.name, "1", tc.mutate))
		var p apiPod
		_ = json.Unmarshal(raw, &p)
		row := podFromAPI(&p)
		if row.Status != tc.status || row.Tone != tc.tone || row.Ready != tc.ready || row.Total != 1 {
			t.Errorf("%s: %+v", tc.name, row)
		}
	}
}
