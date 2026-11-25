package docker

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func connectFake(t *testing.T, f *fakeEngine) *Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	c, err := Connect(ctx, f.Endpoint())
	if err != nil {
		t.Fatalf("Connect: %v", err)
	}
	return c
}

func engineErr(t *testing.T, err error, reason, socket string) *EngineError {
	t.Helper()
	var ee *EngineError
	if !errors.As(err, &ee) {
		t.Fatalf("want *EngineError (%s), got %T %v", reason, err, err)
	}
	if ee.Reason != reason {
		t.Fatalf("reason = %s, want %s (%s)", ee.Reason, reason, ee.Message)
	}
	if socket != "" && !strings.Contains(ee.Message, socket) {
		t.Fatalf("message should name the socket %s: %s", socket, ee.Message)
	}
	if strings.Count(strings.TrimSuffix(ee.Message, "."), ". ") != 0 || !strings.HasSuffix(ee.Message, ".") {
		t.Fatalf("message should be one sentence: %q", ee.Message)
	}
	return ee
}

func TestNegotiateVersion(t *testing.T) {
	cases := []struct{ server, pinned string }{
		{"1.47", "1.47"},
		{"1.40", "1.40"},
		{"1.56", "1.56"},
		{"1.60", "1.56"},
		{"2.0", "1.56"},
	}
	for _, tc := range cases {
		f := newFakeEngine(t, func(f *fakeEngine) { f.APIVersion = tc.server })
		c := connectFake(t, f)
		if c.APIVersion != tc.pinned {
			t.Errorf("server %s pinned %s, want %s", tc.server, c.APIVersion, tc.pinned)
		}
		v, err := c.Version(context.Background())
		if err != nil || v.Version != "27.3.1" {
			t.Errorf("Version over %s = %+v, %v", tc.pinned, v, err)
		}
		reqs := f.Requests()
		if reqs[len(reqs)-1] != "GET /v"+tc.pinned+"/version" {
			t.Errorf("requests = %v", reqs)
		}
	}
}

func TestNegotiateRefusesOldEngine(t *testing.T) {
	f := newFakeEngine(t, func(f *fakeEngine) { f.APIVersion = "1.39" })
	_, err := Connect(context.Background(), f.Endpoint())
	ee := engineErr(t, err, ReasonTooOld, f.Socket)
	if !strings.Contains(ee.Message, "1.39") || !strings.Contains(ee.Message, "1.40") {
		t.Fatalf("message = %s", ee.Message)
	}
	f2 := newFakeEngine(t, func(f *fakeEngine) { f.APIVersion = "" })
	_, err = Connect(context.Background(), f2.Endpoint())
	engineErr(t, err, ReasonTooOld, f2.Socket)
}

func TestFakeEngineServesContainersEventsAndLogs(t *testing.T) {
	f := newFakeEngine(t, func(f *fakeEngine) {
		f.Containers = []map[string]any{{"Id": "abc", "Names": []string{"/web"}, "State": "running"}}
		f.Logs["abc"] = []fakeLogLine{{Text: "listening on :8080"}, {Stderr: true, Text: "warning"}}
	})
	c := connectFake(t, f)
	ctx := context.Background()

	var list []struct {
		ID    string `json:"Id"`
		State string `json:"State"`
	}
	if err := c.GetJSON(ctx, "/containers/json", url.Values{"all": {"1"}}, &list); err != nil || len(list) != 1 || list[0].ID != "abc" {
		t.Fatalf("containers = %+v, %v", list, err)
	}

	resp, err := c.Do(ctx, "GET", "/containers/abc/logs", url.Values{"stdout": {"1"}, "stderr": {"1"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if len(data) < 8 || data[0] != 1 || !strings.Contains(string(data), "listening on :8080") || !strings.Contains(string(data), "\x02\x00\x00\x00") {
		t.Fatalf("logs frames = %q", data)
	}

	var apiErr *APIError
	if _, err := c.Do(ctx, "GET", "/containers/missing/logs", nil, nil); !errors.As(err, &apiErr) || apiErr.StatusCode != 404 || apiErr.Message != "No such container: missing" {
		t.Fatalf("missing container error = %v", err)
	}

	sctx, cancel := context.WithCancel(ctx)
	resp, err = c.Do(sctx, "GET", "/events", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.Events <- map[string]any{"Type": "container", "Action": "start", "Actor": map[string]any{"ID": "abc"}}
	var ev struct{ Type, Action string }
	line, err := bufio.NewReader(resp.Body).ReadBytes('\n')
	if err != nil || json.Unmarshal(line, &ev) != nil || ev.Action != "start" {
		t.Fatalf("event = %q, %v", line, err)
	}
	cancel()
	resp.Body.Close()
}

func TestEngineDown(t *testing.T) {
	missing := filepath.Join(shortTempDir(t), "docker.sock")
	c, err := NewClient(Endpoint{Kind: KindUnix, Host: "unix://" + missing, Socket: missing})
	if err != nil {
		t.Fatal(err)
	}
	engineErr(t, c.Negotiate(context.Background()), ReasonDown, missing)

	stale := filepath.Join(shortTempDir(t), "docker.sock")
	ln, err := net.Listen("unix", stale)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	c, _ = NewClient(Endpoint{Kind: KindUnix, Host: "unix://" + stale, Socket: stale})
	ee := engineErr(t, c.Negotiate(context.Background()), ReasonDown, stale)
	if ee.Message != "Docker Engine isn’t running at "+stale+"." {
		t.Fatalf("message = %q", ee.Message)
	}
}

func TestSocketPermissionDenied(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores socket permissions")
	}
	f := newFakeEngine(t, nil)
	if err := os.Chmod(f.Socket, 0); err != nil {
		t.Fatal(err)
	}
	c, _ := NewClient(f.Endpoint())
	engineErr(t, c.Negotiate(context.Background()), ReasonPermission, f.Socket)
}

func TestSlowEngineTimesOut(t *testing.T) {
	f := newFakeEngine(t, func(f *fakeEngine) { f.Delay = 5 * time.Second })
	c, _ := NewClient(f.Endpoint())
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := c.Negotiate(ctx)
	if time.Since(start) > time.Second {
		t.Fatalf("timeout took %s", time.Since(start))
	}
	ee := engineErr(t, err, ReasonTimeout, f.Socket)
	if !strings.Contains(ee.Message, "didn’t answer within") {
		t.Fatalf("message = %s", ee.Message)
	}
}

func fakeDockerCLI(t *testing.T) (marker string) {
	t.Helper()
	dir := shortTempDir(t)
	marker = filepath.Join(dir, "calls.log")
	script := "#!/bin/sh\necho \"$@\" >> " + marker + "\nif [ \"$1\" = compose ]; then echo 2.40.3; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return marker
}

func resetComposeCache(t *testing.T) {
	reset := func() {
		composeCache.Lock()
		composeCache.version, composeCache.missing, composeCache.err = "", false, ""
		composeCache.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func calls(marker string) string {
	data, _ := os.ReadFile(marker)
	return string(data)
}

func TestStatusUsesSocketAndSpawnsNothing(t *testing.T) {
	marker := fakeDockerCLI(t)
	resetComposeCache(t)
	f := newFakeEngine(t, func(f *fakeEngine) { f.Version = "28.5.2" })
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	st := Status("")
	if st.State != "ok" || st.ServerVersion != "28.5.2" || st.Endpoint != "unix://"+f.Socket || st.Context != "default" || st.Error != "" {
		t.Fatalf("Status = %+v", st)
	}
	if !strings.HasSuffix(st.CLIPath, "/docker") {
		t.Fatalf("CLIPath = %q", st.CLIPath)
	}
	if got := calls(marker); got != "" {
		t.Fatalf("Status spawned docker: %q", got)
	}
	var shape map[string]any
	if err := json.Unmarshal([]byte(StatusJSON("")), &shape); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"state", "cliPath", "cliVersion", "composeVersion", "context", "endpoint", "serverVersion", "provider", "providerApp", "error"} {
		if _, ok := shape[k]; !ok {
			t.Errorf("StatusJSON lost key %q", k)
		}
	}
	if len(shape) != 10 {
		t.Errorf("StatusJSON keys = %v", shape)
	}
}

func TestStatusEngineDownAndSlow(t *testing.T) {
	marker := fakeDockerCLI(t)
	resetComposeCache(t)
	missing := filepath.Join(shortTempDir(t), "docker.sock")
	t.Setenv("DOCKER_HOST", "unix://"+missing)
	st := Status("")
	if st.State != "engineDown" || st.Error != "Docker Engine isn’t running at "+missing+"." {
		t.Fatalf("Status = %+v", st)
	}

	old := statusTimeout
	statusTimeout = 200 * time.Millisecond
	t.Cleanup(func() { statusTimeout = old })
	f := newFakeEngine(t, func(f *fakeEngine) { f.Delay = 5 * time.Second })
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	start := time.Now()
	st = Status("")
	if time.Since(start) > 2*time.Second || st.State != "engineDown" || !strings.Contains(st.Error, "didn’t answer within") {
		t.Fatalf("slow Status = %+v after %s", st, time.Since(start))
	}
	if got := calls(marker); got != "" {
		t.Fatalf("Status spawned docker: %q", got)
	}
}

func TestStatusMissingCLI(t *testing.T) {
	t.Setenv("PATH", shortTempDir(t))
	if LookPath("docker") != "" {
		t.Skip("docker is installed in a fixed location on this machine")
	}
	if st := Status(""); st.State != "missingCLI" || st.Error == "" {
		t.Fatalf("Status = %+v", st)
	}
}

func TestComposeVersionIsLazyAndCached(t *testing.T) {
	marker := fakeDockerCLI(t)
	resetComposeCache(t)
	f := newFakeEngine(t, nil)
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	Status("")
	if got := calls(marker); got != "" {
		t.Fatalf("Status ran compose: %q", got)
	}
	for range 3 {
		if v, err := ComposeVersion(""); err != nil || v != "2.40.3" {
			t.Fatalf("ComposeVersion = %q, %v", v, err)
		}
	}
	if got := calls(marker); got != "compose version --short\n" {
		t.Fatalf("compose should run once per session: %q", got)
	}
	if st := Status(""); st.ComposeVersion != "2.40.3" || st.State != "ok" {
		t.Fatalf("Status after compose check = %+v", st)
	}
}

func TestComposeMissingSurfacesInStatus(t *testing.T) {
	dir := shortTempDir(t)
	os.WriteFile(filepath.Join(dir, "docker"), []byte("#!/bin/sh\necho \"docker: 'compose' is not a docker command.\" >&2\nexit 1\n"), 0o755)
	t.Setenv("PATH", dir)
	resetComposeCache(t)
	f := newFakeEngine(t, nil)
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	if _, err := ComposeVersion(""); err == nil {
		t.Fatal("missing compose should fail")
	}
	if st := Status(""); st.State != "missingCompose" || !strings.Contains(st.Error, "not a docker command") {
		t.Fatalf("Status = %+v", st)
	}
}
