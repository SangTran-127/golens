package remote

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/dap"
	"golens/core/runner"
)

type recorder struct {
	mu      sync.Mutex
	lines   []string
	issues  []Issue
	started map[string]int64
	exited  map[int64]string
	tests   []runner.TestResult
	debug   []string
}

func newRecorder(t *testing.T) *recorder {
	r := &recorder{started: map[string]int64{}, exited: map[int64]string{}}
	oldTest := runner.TestEvent
	t.Cleanup(func() { runner.TestEvent = oldTest })
	t.Cleanup(bridge.SetLog(func(msg string) {
		r.mu.Lock()
		r.lines = append(r.lines, msg)
		r.mu.Unlock()
	}))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		r.mu.Lock()
		defer r.mu.Unlock()
		switch topic {
		case "remoteIssue":
			var i Issue
			_ = json.Unmarshal([]byte(payload), &i)
			r.issues = append(r.issues, i)
		case "runEvent", "taskLog":
			var ev struct {
				ID    int64  `json:"id"`
				Key   string `json:"key"`
				State string `json:"state"`
				Lines []struct {
					Text string `json:"text"`
				} `json:"lines"`
			}
			_ = json.Unmarshal([]byte(payload), &ev)
			switch ev.State {
			case "started":
				r.started[ev.Key] = ev.ID
			case "":
				for _, l := range ev.Lines {
					r.lines = append(r.lines, l.Text)
				}
			default:
				r.exited[ev.ID] = ev.State
			}
		}
	}))
	runner.TestEvent = func(payload string) {
		var res runner.TestResult
		_ = json.Unmarshal([]byte(payload), &res)
		r.mu.Lock()
		r.tests = append(r.tests, res)
		r.mu.Unlock()
	}
	t.Cleanup(bridge.SetDebugEvent(func(event, payload string) {
		r.mu.Lock()
		r.debug = append(r.debug, event+" "+payload)
		r.mu.Unlock()
	}))
	return r
}

func (r *recorder) waitFor(t *testing.T, what string, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		ok := cond()
		r.mu.Unlock()
		if ok {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	t.Fatalf("timed out waiting for %s\nlines:\n%s\nissues: %+v\ndebug: %v", what, strings.Join(r.lines, "\n"), r.issues, r.debug)
}

func (r *recorder) has(sub string) bool {
	for _, l := range r.lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (r *recorder) testStatus(name string) string {
	status := ""
	for _, res := range r.tests {
		if res.Kind == "test" && res.Test == name && res.Status != "running" {
			status = res.Status
		}
	}
	return status
}

func (r *recorder) done() *runner.TestResult {
	for i := range r.tests {
		if r.tests[i].Kind == "done" {
			return &r.tests[i]
		}
	}
	return nil
}

func e2eRoot(t *testing.T) string {
	root := os.Getenv("GOLENS_REMOTE_E2E")
	if root == "" {
		t.Skip("set GOLENS_REMOTE_E2E to the run-target fixture to run against live Compose and SSH targets")
	}
	return root
}

func configJSON(t *testing.T, cfg RunConfig) string {
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func compose(t *testing.T, root string, args ...string) string {
	cmd := exec.Command("docker", append([]string{"compose", "-f", filepath.Join(root, "compose.yaml")}, args...)...)
	out, _ := cmd.CombinedOutput()
	return string(out)
}

func processesIn(t *testing.T, root, service string) string {
	return compose(t, root, "exec", "-T", service, "sh", "-c", "for d in /proc/[0-9]*; do readlink $d/exe; tr '\\000' ' ' < $d/cmdline; echo; done 2>/dev/null")
}

func TestE2EComposeRunStreamsAndStops(t *testing.T) {
	root := e2eRoot(t)
	r := newRecorder(t)
	cfg := RunConfig{Name: "ticker", WorkingDirectory: "cmd/ticker", Args: "--who \"it's me\"", EnvVars: map[string]string{"GREETING": "hi there"}, Target: &Target{Kind: KindCompose, Service: "slim"}}
	Run(root, configJSON(t, cfg))
	r.waitFor(t, "tick 2", 3*time.Minute, func() bool { return r.has("tick 2") })
	if !r.has("linux/arm64 cgo=false") && !r.has("linux/amd64 cgo=false") {
		t.Errorf("not cross-compiled for linux: %v", r.lines)
	}
	if !r.has(`args=["--who" "it's me"]`) || !r.has("env=hi there") || !r.has("stderr line") {
		t.Errorf("args, env or stderr lost: %v", r.lines)
	}
	if !strings.Contains(processesIn(t, root, "slim"), "/tmp/golens/rt-fixture/ticker/run/app") {
		t.Fatal("program not running in the container")
	}
	id := r.started["config:ticker"]
	runner.StopProgramRun(id)
	r.waitFor(t, "exit", 20*time.Second, func() bool { return r.exited[id] != "" })
	if ps := processesIn(t, root, "slim"); strings.Contains(ps, "/run/app") {
		t.Fatalf("remote program survived Stop:\n%s", ps)
	}
}

func TestE2EComposeCgoBuildsInsideTheService(t *testing.T) {
	root := e2eRoot(t)
	r := newRecorder(t)
	cfg := RunConfig{Name: "ticker cgo", WorkingDirectory: "cmd/ticker", EnvVars: map[string]string{"CGO_ENABLED": "1"}, Target: &Target{Kind: KindCompose, Service: "gosvc"}}
	Run(root, configJSON(t, cfg))
	r.waitFor(t, "tick 1", 5*time.Minute, func() bool { return r.has("tick 1") })
	if !r.has("cgo=true") || !r.has("wd=/srv") {
		t.Errorf("expected an in-container cgo build running in the service workdir: %v", r.lines)
	}
	id := r.started["config:ticker cgo"]
	runner.StopProgramRun(id)
	r.waitFor(t, "exit", 20*time.Second, func() bool { return r.exited[id] != "" })
	if ps := processesIn(t, root, "gosvc"); strings.Contains(ps, "/run/app") {
		t.Fatalf("remote program survived Stop:\n%s", ps)
	}
}

func TestE2EComposeCgoWithoutGoExplainsWhy(t *testing.T) {
	root := e2eRoot(t)
	r := newRecorder(t)
	Run(root, configJSON(t, RunConfig{Name: "x", WorkingDirectory: "cmd/ticker", EnvVars: map[string]string{"CGO_ENABLED": "1"}, Target: &Target{Kind: KindCompose, Service: "slim"}}))
	if len(r.issues) != 1 || r.issues[0].Code != CodeGoMissing {
		t.Fatalf("issues = %+v", r.issues)
	}
}

func runTestsAndWait(t *testing.T, r *recorder, root string, req TestRequest) *runner.TestResult {
	b, _ := json.Marshal(req)
	if id := RunTests(root, string(b)); id == 0 {
		t.Fatalf("tests didn't start: %+v %v", r.issues, r.lines)
	}
	r.waitFor(t, "test run done", 5*time.Minute, func() bool { return r.done() != nil })
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.done()
}

func TestE2EComposeTestsReportPerTestResults(t *testing.T) {
	root := e2eRoot(t)
	for _, svc := range []string{"slim", "gosvc"} {
		t.Run(svc, func(t *testing.T) {
			r := newRecorder(t)
			env := map[string]string{"RT_FAIL": "1"}
			if svc == "gosvc" {
				env["CGO_ENABLED"] = "1"
			}
			req := TestRequest{Name: "tests", EnvVars: env, Target: &Target{Kind: KindCompose, Service: svc}}
			req.Dir = root
			req.Packages = []string{"./..."}
			done := runTestsAndWait(t, r, root, req)
			r.mu.Lock()
			defer r.mu.Unlock()
			for name, want := range map[string]string{"TestSum": "pass", "TestRunsOnLinux": "pass", "TestTestdata": "pass", "TestTable/one": "pass", "TestDeliberateFailure": "fail"} {
				if got := r.testStatus(name); got != want {
					t.Errorf("%s = %q, want %q", name, got, want)
				}
			}
			if done.Status != "fail" || done.Failed != 1 || done.Passed < 5 {
				t.Errorf("done = %+v", done)
			}
			for _, res := range r.tests {
				if res.Test == "TestDeliberateFailure" && res.Status == "fail" && len(res.Failures) == 0 {
					t.Errorf("failure location not parsed: %+v", res)
				}
			}
		})
	}
}

func installDelve(t *testing.T, root string, target Target) {
	r := newRecorder(t)
	tb, _ := json.Marshal(target)
	id := Fix(root, string(tb), FixInstallDelve)
	if id == 0 {
		t.Fatalf("install didn't start: %+v", r.issues)
	}
	r.waitFor(t, "delve install", 10*time.Minute, func() bool { return r.exited[id] != "" })
	if r.exited[id] != "exited" {
		t.Fatalf("install %s: %v", r.exited[id], r.lines)
	}
}

func debugAndHitBreakpoint(t *testing.T, root string, cfg RunConfig, service string) *recorder {
	r := newRecorder(t)
	if err := Debug(root, configJSON(t, cfg)); err != nil {
		t.Fatalf("debug: %v\n%v", err, r.lines)
	}
	client := dap.GetClient()
	if client == nil {
		t.Fatal("no DAP client")
	}
	file := filepath.Join(root, "cmd", "ticker", "main.go")
	out, err := client.SetBreakpoints(file, []dap.Breakpoint{{Line: 23}})
	if err != nil || !strings.Contains(string(out), `"verified":true`) {
		t.Fatalf("breakpoint not verified: %s %v", out, err)
	}
	if err := client.ConfigurationDone(); err != nil {
		t.Fatal(err)
	}
	r.waitFor(t, "stopped at breakpoint", 60*time.Second, func() bool {
		for _, e := range r.debug {
			if strings.HasPrefix(e, "stopped") {
				return true
			}
		}
		return false
	})
	stack, err := client.GetStackTrace(1)
	if err != nil {
		var threads []byte
		threads, _ = client.GetThreads()
		t.Fatalf("stack: %v threads=%s", err, threads)
	}
	if !strings.Contains(string(stack), file) || !strings.Contains(string(stack), `"line":23`) {
		t.Errorf("top frame should map to the local file %s line 23: %s", file, stack)
	}
	id := r.started[runKey(cfg.Name)]
	client.Stop()
	r.waitFor(t, "debug session end", 30*time.Second, func() bool { return r.exited[id] != "" })
	if service != "" {
		if ps := processesIn(t, root, service); strings.Contains(ps, "dlv") || strings.Contains(ps, "/run/app") {
			t.Fatalf("debugger or program survived Stop:\n%s", ps)
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r
}

func TestE2EComposeDebug(t *testing.T) {
	root := e2eRoot(t)
	target := Target{Kind: KindCompose, Service: "gosvc"}
	r := newRecorder(t)
	compose(t, root, "exec", "-T", "gosvc", "rm", "-rf", "/tmp/golens/bin/dlv")
	err := Debug(root, configJSON(t, RunConfig{Name: "dbg", WorkingDirectory: "cmd/ticker", Target: &target}))
	if err == nil || len(r.issues) == 0 || r.issues[0].Code != CodeDlvMissing || r.issues[0].Fix != FixInstallDelve {
		t.Fatalf("expected a Delve-missing issue with an install fix, got %v %+v", err, r.issues)
	}
	installDelve(t, root, target)
	t.Run("cross-compiled via relay", func(t *testing.T) {
		debugAndHitBreakpoint(t, root, RunConfig{Name: "dbg", WorkingDirectory: "cmd/ticker", Target: &target}, "gosvc")
	})
	t.Run("built in the service with substitutePath", func(t *testing.T) {
		debugAndHitBreakpoint(t, root, RunConfig{Name: "dbg cgo", WorkingDirectory: "cmd/ticker", EnvVars: map[string]string{"CGO_ENABLED": "1"}, Target: &target}, "gosvc")
	})
}

func TestE2EComposePublishedPortAndStartService(t *testing.T) {
	root := e2eRoot(t)
	target := Target{Kind: KindCompose, Service: "published"}
	compose(t, root, "stop", "published")
	r := newRecorder(t)
	Run(root, configJSON(t, RunConfig{Name: "p", WorkingDirectory: "cmd/ticker", Target: &target}))
	if len(r.issues) != 1 || r.issues[0].Code != CodeServiceNotRunning || r.issues[0].Fix != FixStartService {
		t.Fatalf("issues = %+v", r.issues)
	}
	tb, _ := json.Marshal(target)
	id := Fix(root, string(tb), FixStartService)
	r.waitFor(t, "service start", 2*time.Minute, func() bool { return r.exited[id] != "" })
	installDelve(t, root, target)
	debugAndHitBreakpoint(t, root, RunConfig{Name: "pub", WorkingDirectory: "cmd/ticker", Target: &target}, "published")
}

func sshTarget(t *testing.T, root string) Target {
	kh := filepath.Join(t.TempDir(), "known_hosts")
	ctl := "/tmp/golens-e2e-ssh"
	_ = os.MkdirAll(ctl, 0o700)
	oldDir, oldExtra := sshControlDir, extraSSHOptions
	sshControlDir = func() string { return ctl }
	extraSSHOptions = []string{"-o", "IdentityFile=" + filepath.Join(root, "test_key"), "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=" + kh}
	target := Target{Kind: KindSSH, Host: "dev@127.0.0.1", Port: 42222}
	t.Cleanup(func() {
		runArgv(10*time.Second, NewTransport(target).SSHControl("exit"), "")
		sshControlDir, extraSSHOptions = oldDir, oldExtra
	})
	return target
}

func TestE2ESSHErrorsAreExplained(t *testing.T) {
	root := e2eRoot(t)
	target := sshTarget(t, root)
	if _, iss := Check(target); iss == nil || iss.Code != CodeHostKeyUnknown || !strings.Contains(iss.Command, "ssh -p 42222") {
		t.Fatalf("unknown host key: %+v", iss)
	}
	extraSSHOptions = append(extraSSHOptions, "-o", "StrictHostKeyChecking=accept-new")
	bad := target
	bad.Host = "nobody@127.0.0.1"
	if _, iss := Check(bad); iss == nil || iss.Code != CodeAuthFailed {
		t.Fatalf("auth failure: %+v", iss)
	}
	closed := target
	closed.Port = 1
	if _, iss := Check(closed); iss == nil || iss.Code != CodeUnreachable {
		t.Fatalf("closed port: %+v", iss)
	}
	if _, iss := Check(Target{Kind: KindSSH, Host: "dev@no-such-host.invalid"}); iss == nil || iss.Code != CodeHostNotFound {
		t.Fatalf("unknown host: %+v", iss)
	}
}

func TestE2ESSHRunTestDebug(t *testing.T) {
	root := e2eRoot(t)
	target := sshTarget(t, root)
	extraSSHOptions = append(extraSSHOptions, "-o", "StrictHostKeyChecking=accept-new")
	p, iss := Check(target)
	if iss != nil {
		t.Fatal(iss)
	}
	if p.Go != "" {
		t.Logf("host has Go %s", p.GoVersion)
	}
	t.Run("run and stop", func(t *testing.T) {
		r := newRecorder(t)
		Run(root, configJSON(t, RunConfig{Name: "ssh ticker", WorkingDirectory: "cmd/ticker", Target: &target}))
		r.waitFor(t, "tick 2", 3*time.Minute, func() bool { return r.has("tick 2") })
		if !r.has("wd=/home/dev") {
			t.Errorf("expected home as working directory: %v", r.lines)
		}
		id := r.started["config:ssh ticker"]
		start := time.Now()
		runner.StopProgramRun(id)
		r.waitFor(t, "exit", 20*time.Second, func() bool { return r.exited[id] != "" })
		t.Logf("stop took %s", time.Since(start).Round(time.Millisecond))
		if ps := processesIn(t, root, "sshd"); strings.Contains(ps, "/run/app") {
			t.Fatalf("remote program survived Stop:\n%s", ps)
		}
	})
	t.Run("tests", func(t *testing.T) {
		r := newRecorder(t)
		req := TestRequest{Name: "ssh tests", Target: &target}
		req.Dir = filepath.Join(root, "calc")
		req.Packages = []string{"."}
		done := runTestsAndWait(t, r, root, req)
		if done.Status != "pass" || r.testStatus("TestTestdata") != "pass" || r.testStatus("TestRunsOnLinux") != "pass" {
			t.Fatalf("done=%+v lines=%v", done, r.lines)
		}
	})
	t.Run("debug", func(t *testing.T) {
		compose(t, root, "exec", "-T", "sshd", "rm", "-f", "/home/dev/.cache/golens/bin/dlv")
		r := newRecorder(t)
		err := Debug(root, configJSON(t, RunConfig{Name: "ssh dbg", WorkingDirectory: "cmd/ticker", Target: &target}))
		if err == nil || len(r.issues) == 0 || r.issues[0].Code != CodeDlvMissing {
			t.Fatalf("expected Delve missing: %v %+v", err, r.issues)
		}
		installDelve(t, root, target)
		compose(t, root, "exec", "-T", "sshd", "sh", "-c", "sed -i '/^AllowTcpForwarding/d' /etc/ssh/sshd_config; echo 'AllowTcpForwarding no' >> /etc/ssh/sshd_config; kill -HUP 1")
		time.Sleep(time.Second)
		runArgv(10*time.Second, NewTransport(target).SSHControl("exit"), "")
		fallback := debugAndHitBreakpoint(t, root, RunConfig{Name: "ssh dbg", WorkingDirectory: "cmd/ticker", Target: &target}, "sshd")
		if !fallback.has("doesn’t allow SSH port forwarding") {
			t.Error("expected the relay fallback when forwarding is off")
		}
		compose(t, root, "exec", "-T", "sshd", "sh", "-c", "sed -i '/^AllowTcpForwarding/d' /etc/ssh/sshd_config; echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config; kill -HUP 1")
		time.Sleep(time.Second)
		runArgv(10*time.Second, NewTransport(target).SSHControl("exit"), "")
		direct := debugAndHitBreakpoint(t, root, RunConfig{Name: "ssh dbg", WorkingDirectory: "cmd/ticker", Target: &target}, "sshd")
		if direct.has("doesn’t allow SSH port forwarding") {
			t.Error("expected ssh -L when forwarding is allowed")
		}
	})
}
