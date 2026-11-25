package remote

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/runner"
)

func preserveGoCache(t *testing.T) {
	t.Helper()
	if os.Getenv("GOCACHE") != "" {
		return
	}
	if out, err := exec.Command("go", "env", "GOCACHE").Output(); err == nil {
		if dir := strings.TrimSpace(string(out)); dir != "" {
			t.Setenv("GOCACHE", dir)
		}
	}
}

func writeRemoteStub(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func prependRemotePATH(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func setRemoteGlobals(t *testing.T, ctrlFn func() string, sshOpts []string) {
	t.Helper()
	oldCtrl, oldOpts := sshControlDir, extraSSHOptions
	t.Cleanup(func() {
		sshControlDir = oldCtrl
		extraSSHOptions = oldOpts
	})
	if ctrlFn != nil {
		sshControlDir = ctrlFn
	}
	extraSSHOptions = sshOpts
}

type fakeRWCloser struct {
	io.Reader
	io.Writer
}

func (fakeRWCloser) Close() error { return nil }

func waitRunExit(t *testing.T, r *recorder, id int64) {
	t.Helper()
	if id == 0 {
		return
	}
	r.waitFor(t, "run exit", 30*time.Second, func() bool {
		return r.exited[id] != ""
	})
}

func TestIssueFormattingAndClassifiers(t *testing.T) {
	iss := issue(CodeFailed, "Some Title", "Some msg")
	if iss.Error() != "Some Title" {
		t.Fatalf("Issue.Error() = %q", iss.Error())
	}
	if got := lastLine("\n  \n\t\n"); got != "" {
		t.Fatalf("lastLine blank = %q", got)
	}
	if got := hostOnly("host-only.local"); got != "host-only.local" {
		t.Fatalf("hostOnly = %q", got)
	}

	composeTarget := Target{Kind: KindCompose, Service: "api"}
	if got := classifyCompose(composeTarget, "error during connect: dial unix"); got.Code != CodeEngineDown {
		t.Fatalf("error during connect -> %+v", got)
	}
	if got := classifyCompose(composeTarget, "container api is restarting"); got.Code != CodeServiceNotRunning {
		t.Fatalf("is restarting -> %+v", got)
	}
	if got := classifyCompose(composeTarget, "no container found for api"); got.Code != CodeServiceNotRunning {
		t.Fatalf("no container found -> %+v", got)
	}
	if got := classifyCompose(composeTarget, "  \n "); got.Code != CodeFailed || !strings.Contains(got.Message, "without an error message") {
		t.Fatalf("empty compose stderr -> %+v", got)
	}

	sshCustom := Target{Kind: KindSSH, Host: "deploy@box", Port: 2222}
	for _, tc := range []struct {
		stderr   string
		wantCode string
		wantMsg  string
	}{
		{"sign_and_send_pubkey: device not found", CodeAuthFailed, "Security Key Not Detected"},
		{"agent refused: PIN required", CodeAuthFailed, "PIN Required"},
		{"Connection closed by remote host", CodeUnreachable, "port 2222"},
		{"   \n ", CodeFailed, "without an error message"},
	} {
		got := classifySSH(sshCustom, tc.stderr)
		if got.Code != tc.wantCode || !strings.Contains(got.Title+got.Message, tc.wantMsg) {
			t.Errorf("classifySSH(%q) = %+v", tc.stderr, got)
		}
	}

	if got := dlvMissingIssue(sshCustom); got.Code != CodeDlvMissing || got.Fix != FixInstallDelve {
		t.Fatalf("dlvMissingIssue = %+v", got)
	}
	if got := goMissingIssue(composeTarget); got.Code != CodeGoMissing || got.Fix != FixEditTarget {
		t.Fatalf("goMissingIssue = %+v", got)
	}
	if got := archIssue(composeTarget, "sparc64"); got.Code != CodeArchUnknown || !strings.Contains(got.Message, "sparc64") {
		t.Fatalf("archIssue = %+v", got)
	}
	if got := noTarIssue(sshCustom); got.Code != CodeNoTar {
		t.Fatalf("noTarIssue = %+v", got)
	}
	if got := ptraceIssue(composeTarget); got.Code != CodePtrace || !strings.Contains(got.Message, "SYS_PTRACE") {
		t.Fatalf("compose ptraceIssue = %+v", got)
	}
	if got := ptraceIssue(sshCustom); got.Code != CodePtrace || !strings.Contains(got.Message, "ptrace_scope") {
		t.Fatalf("ssh ptraceIssue = %+v", got)
	}
}

func TestTargetAndPlanEdges(t *testing.T) {
	if p := (Target{DebugPort: 0}).debugPort(); p != DefaultDebugPort {
		t.Fatalf("default debugPort = %d", p)
	}
	if p := (Target{DebugPort: 70000}).debugPort(); p != DefaultDebugPort {
		t.Fatalf("oversize debugPort = %d", p)
	}
	if p := (Target{DebugPort: 4567}).debugPort(); p != 4567 {
		t.Fatalf("custom debugPort = %d", p)
	}

	root := t.TempDir()
	for _, tc := range []struct {
		target   Target
		wantCode string
	}{
		{Target{Kind: KindCompose, Service: "bad service!"}, CodeConfig},
		{Target{Kind: KindCompose, Service: "api", ComposeFile: "missing.yaml"}, CodeConfig},
		{Target{Kind: KindCompose, Service: "api", ComposeFile: root}, CodeConfig},
		{Target{Kind: KindSSH, Host: "-oProxyCommand=evil"}, CodeConfig},
	} {
		_, iss := tc.target.Resolve(root)
		if iss == nil || iss.Code != tc.wantCode {
			t.Errorf("Resolve(%+v) = %+v, want %s", tc.target, iss, tc.wantCode)
		}
	}

	for _, k := range []string{KindLocal, KindVMArm64, KindVMAmd64} {
		rt, iss := (Target{Kind: k}).Resolve(root)
		if iss != nil || rt.Label() == "" {
			t.Errorf("Resolve(%s) = (%+v, %+v)", k, rt, iss)
		}
	}

	if TargetUsesSecurityKey(Target{Kind: KindCompose, Service: "api"}) {
		t.Fatal("non-SSH target should not use security key")
	}
	setRemoteGlobals(t, nil, []string{"-F", filepath.Join(root, "does-not-exist")})
	if TargetUsesSecurityKey(Target{Kind: KindSSH, Host: "host.invalid"}) {
		t.Fatal("failing ssh -G should return false")
	}

	skPub := filepath.Join(root, "id_ed25519_sk.pub")
	if err := os.WriteFile(skPub, []byte("sk-ecdsa-sha2-nistp256@openssh.com AAAA test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !isSecurityKeyIdentityFile(skPub) {
		t.Fatal("expected sk-ecdsa pub key to be detected")
	}
	if isSecurityKeyIdentityFile(filepath.Join(root, "missing_key")) {
		t.Fatal("missing key path should be false")
	}

	t.Setenv("HOME", filepath.Join(root, strings.Repeat("a", 80)))
	if got := controlDir(); !strings.HasPrefix(got, "/tmp/golens-ssh-") {
		t.Fatalf("long HOME controlDir = %q", got)
	}
	trLocal := NewTransport(Target{Kind: KindVMArm64})
	if argv := trLocal.Shell("echo hi"); len(argv) < 3 || argv[0] != "/bin/sh" {
		t.Fatalf("local shell argv = %v", argv)
	}

	for _, tc := range []struct {
		m        string
		arch     string
		arm      string
		wantOkay bool
	}{
		{"armv7l", "arm", "7", true},
		{"armv7", "arm", "7", true},
		{"armv6l", "arm", "6", true},
		{"i686", "386", "", true},
		{"mips64", "", "", false},
	} {
		a, arm, ok := GoArch(tc.m)
		if a != tc.arch || arm != tc.arm || ok != tc.wantOkay {
			t.Errorf("GoArch(%q) = (%q, %q, %v)", tc.m, a, arm, ok)
		}
	}

	if got := (Plan{Probe: Probe{Base: "/opt/base"}}).Base(); got != "/opt/base" {
		t.Fatalf("Plan.Base = %q, want /opt/base", got)
	}
	if rel := relSlash(filepath.Join(root, "sub"), root); rel != "." {
		t.Fatalf("relSlash outside root = %q, want .", rel)
	}

	p := Plan{
		Target:     Target{Kind: KindSSH, Host: "u@h"},
		Probe:      Probe{GOARCH: "arm", GOARM: "7"},
		Name:       "armtest",
		Project:    "proj",
		ModuleRoot: root,
		RunDir:     root,
		RelayDir:   root,
		Debug:      true,
		DebugAddr:  "127.0.0.1:40000",
		InTarget:   true,
	}
	if p.platform() != "linux/armv7" || !strings.Contains(strings.Join(p.crossEnv(), " "), "GOARM=7") || !strings.Contains(strings.Join(p.crossEnvOnly(), " "), "GOARM=7") {
		t.Fatalf("arm7 plan helpers unexpected: %q / %v", p.platform(), p.crossEnv())
	}
	if p.cdWorkDir("") != "" || p.cdWorkDir("fallback") != "cd fallback || exit 1; " {
		t.Fatalf("cdWorkDir empty = %q", p.cdWorkDir("fallback"))
	}
	p.Target.WorkDir = "~"
	if p.cdWorkDir("fallback") != `cd "$HOME" || exit 1; ` {
		t.Fatalf("cdWorkDir bare tilde = %q", p.cdWorkDir("fallback"))
	}
	p.Target.WorkDir = "~/app"
	if !strings.Contains(p.cdWorkDir("fallback"), `"$HOME"/app`) {
		t.Fatalf("cdWorkDir tilde = %q", p.cdWorkDir("fallback"))
	}
	p.Target.WorkDir = "/srv/app"
	if !strings.Contains(p.cdWorkDir("fallback"), `cd /srv/app`) {
		t.Fatalf("cdWorkDir abs = %q", p.cdWorkDir("fallback"))
	}
	if !strings.Contains(p.RunScript(), "export ") {
		t.Fatalf("RunScript(InTarget+Debug) = %q", p.RunScript())
	}
	pkgs := make([]TestPackage, 11)
	for i := range pkgs {
		pkgs[i] = TestPackage{ImportPath: "example.com/p" + itoa(i), Dir: root}
	}
	p.InTarget = false
	script := p.TestScript(pkgs, nil)
	if !strings.Contains(script, "bin/pkg10.test") || !strings.Contains(script, "-test.v") {
		t.Fatalf("TestScript with 11 pkgs / empty args = %q", script)
	}
}

func TestRunArgvTimeoutsAndSecurityKeyPrompt(t *testing.T) {
	if r := runArgv(time.Second, []string{"/nonexistent/binary/xyz"}, ""); r.err == nil {
		t.Fatal("expected error for missing binary")
	}

	r := runArgv(2*time.Second, []string{"/bin/sh", "-c", "cat; echo err-line >&2; exit 3"}, "hello-in")
	if r.err == nil || r.stdout != "hello-in" || !strings.Contains(r.stderr, "err-line") {
		t.Fatalf("runArgv stdin/exit = %+v", r)
	}

	rTO := runArgv(120*time.Millisecond, []string{"/bin/sh", "-c", "exec /bin/sleep 5"}, "")
	if !rTO.timedOut || rTO.stderr != "timed out" {
		t.Fatalf("runArgv empty timeout = %+v", rTO)
	}

	rPartial := runArgv(250*time.Millisecond, []string{"/bin/sh", "-c", "echo partial >&2; exec /bin/sleep 5"}, "")
	if !rPartial.timedOut || !strings.Contains(rPartial.stderr, "partial") {
		t.Fatalf("runArgv partial timeout = %+v", rPartial)
	}

	rec := newRecorder(t)
	var topics []string
	t.Cleanup(bridge.WrapStatus(func(topic, payload string, oldStatus func(string, string)) {
		if topic == "remoteTouchSecurityKey" {
			rec.mu.Lock()
			topics = append(topics, payload)
			rec.mu.Unlock()
		}
		if oldStatus != nil {
			oldStatus(topic, payload)
		}
	}))
	rSK := runArgv(2*time.Second, []string{"/bin/sh", "-c", "echo 'Confirm user presence for key' >&2"}, "")
	if rSK.err != nil {
		t.Fatalf("runArgv SK prompt err = %v", rSK.err)
	}
	if len(topics) != 2 || topics[0] != "waiting" || topics[1] != "done" {
		t.Fatalf("security key status events = %v", topics)
	}
}

func TestCheckAndServicesWithStubCLI(t *testing.T) {
	root := t.TempDir()
	composePath := filepath.Join(root, "compose.yaml")
	if err := os.WriteFile(composePath, []byte("services:\n  api:\n    image: alpine\n  worker:\n    image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	stubDir := t.TempDir()
	prependRemotePATH(t, stubDir)
	t.Setenv("HOME", t.TempDir())

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "error during connect" >&2; exit 1 ;;
esac
`)
	target := Target{Kind: KindCompose, Service: "api", ComposeFile: composePath}
	if _, iss := Check(target); iss == nil || iss.Code != CodeEngineDown {
		t.Fatalf("ps error = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "other" ;;
  *"config --services"*) printf "other\nworker\n" ;;
esac
`)
	if _, iss := Check(target); iss == nil || iss.Code != CodeUnknownService {
		t.Fatalf("missing service = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "worker" ;;
  *"config --services"*) printf "api\nworker\n" ;;
esac
`)
	if _, iss := Check(target); iss == nil || iss.Code != CodeServiceNotRunning {
		t.Fatalf("stopped service = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) echo "not-probe-output"; exit 1 ;;
esac
`)
	if _, iss := Check(target); iss == nil || iss.Code != CodeFailed {
		t.Fatalf("failed probe exec = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) printf "golens-probe\nmachine=sparc64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/usr/bin/tar\n" ;;
esac
`)
	if _, iss := Check(target); iss == nil || iss.Code != CodeArchUnknown {
		t.Fatalf("unknown arch = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=\n" ;;
esac
`)
	if _, iss := Check(target); iss == nil || iss.Code != CodeNoTar {
		t.Fatalf("missing tar = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n" ;;
esac
`)
	p, iss := Check(target)
	if iss != nil || p.GOARCH != "amd64" || p.Tar != "/bin/tar" {
		t.Fatalf("valid probe = (%+v, %+v)", p, iss)
	}

	fileAsCtrl := filepath.Join(root, "ctrl-file")
	if err := os.WriteFile(fileAsCtrl, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	setRemoteGlobals(t, func() string { return fileAsCtrl }, []string{"-F", "/dev/null"})
	if _, iss := Check(Target{Kind: KindSSH, Host: "127.0.0.1"}); iss == nil || iss.Code != CodeFailed || !strings.Contains(iss.Title, "Prepare SSH") {
		t.Fatalf("MkdirAll failure = %+v", iss)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedPort := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	setRemoteGlobals(t, controlDir, []string{"-F", "/dev/null", "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no"})
	if _, iss := Check(Target{Kind: KindSSH, Host: "127.0.0.1", Port: closedPort}); iss == nil || iss.Code != CodeUnreachable {
		t.Fatalf("closed local SSH port = %+v", iss)
	}

	setRemoteGlobals(t, controlDir, []string{"-F", filepath.Join(root, "missing-ssh-config")})
	if _, iss := Check(Target{Kind: KindSSH, Host: "127.0.0.1"}); iss == nil || iss.Code != CodeFailed {
		t.Fatalf("bad SSH config = %+v", iss)
	}

	emptyDir := t.TempDir()
	if got := ListComposeServices(emptyDir, ""); got.Error == "" {
		t.Fatalf("expected error when no compose file: %+v", got)
	}
	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"config --services"*) printf "zsvc\nasvc\n" ;;
esac
`)
	includePath := filepath.Join(root, "with-include.yaml")
	if err := os.WriteFile(includePath, []byte("include:\n  - other.yaml\nservices:\n  worker:\n    image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	svcs := ListComposeServices(root, "with-include.yaml")
	if svcs.Error != "" || !reflect.DeepEqual(svcs.Services, []string{"asvc", "zsvc"}) {
		t.Fatalf("ListComposeServices via docker CLI = %+v", svcs)
	}
	writeRemoteStub(t, stubDir, "docker", "exit 1\n")
	if out := ComposeServicesJSON(root, includePath); !strings.Contains(out, `"services":["worker"]`) {
		t.Fatalf("ComposeServicesJSON fallback = %s", out)
	}
	if os.Geteuid() != 0 {
		unreadable := filepath.Join(root, "locked.yaml")
		if err := os.WriteFile(unreadable, []byte("services:\n  a:\n"), 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(unreadable, 0o644) })
		if got := ListComposeServices(root, unreadable); !strings.Contains(got.Error, "Couldn’t read") {
			t.Fatalf("unreadable compose = %+v", got)
		}
	}
	if got := ParseComposeServices("# comment\nnot_services:\n  x: 1\nservices:\n  bad line no colon\n  'quoted-svc':\n    image: alpine\n"); len(got) != 1 || got[0] != "quoted-svc" {
		t.Fatalf("ParseComposeServices = %v", got)
	}
}

func TestRelayBuildAndCmdConn(t *testing.T) {
	preserveGoCache(t)
	homeBlocked := t.TempDir()
	if err := os.WriteFile(filepath.Join(homeBlocked, "Library"), []byte("block"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", homeBlocked)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(homeBlocked, "Library"))
	if !strings.HasSuffix(relayCacheDir("arm", "7"), "linux-armv7") {
		t.Fatalf("relayCacheDir = %q", relayCacheDir("arm", "7"))
	}
	if _, err := BuildRelay("amd64", ""); err == nil {
		t.Fatal("expected MkdirAll error when cache root is regular file")
	}

	homeOK := t.TempDir()
	t.Setenv("HOME", homeOK)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(homeOK, ".cache"))
	if _, err := BuildRelay("bogusarch", ""); err == nil || !strings.Contains(err.Error(), "couldn’t build the debugger relay") {
		t.Fatalf("bogus arch BuildRelay = %v", err)
	}
	relayDir, err := BuildRelay("amd64", "")
	if err != nil {
		t.Fatalf("BuildRelay(amd64) = %v", err)
	}
	if relayDir2, err := BuildRelay("amd64", ""); err != nil || relayDir2 != relayDir {
		t.Fatalf("cached BuildRelay = (%q, %v)", relayDir2, err)
	}

	origPath, hadPath := os.LookupEnv("PATH")
	_ = os.Unsetenv("PATH")
	t.Cleanup(func() {
		if hadPath {
			_ = os.Setenv("PATH", origPath)
		} else {
			_ = os.Unsetenv("PATH")
		}
	})
	_ = LocalEnv()
	if hadPath {
		_ = os.Setenv("PATH", origPath)
	}

	if _, err := dialCommand([]string{"/nonexistent/relay-cmd"}); err == nil {
		t.Fatal("expected dialCommand error on missing binary")
	}

	conn, err := dialCommand([]string{"/bin/sh", "-c", "cat"})
	if err != nil {
		t.Fatalf("dialCommand(cat) = %v", err)
	}
	if _, err := conn.Write([]byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 16)
	n, err := conn.Read(buf)
	if err != nil || string(buf[:n]) != "ping\n" {
		t.Fatalf("cmdConn read = (%q, %v)", string(buf[:n]), err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}

	stubborn, err := dialCommand([]string{"/bin/sh", "-c", "trap '' TERM; /bin/sleep 5"})
	if err != nil {
		t.Fatalf("dialCommand(stubborn) = %v", err)
	}
	if err := stubborn.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSessionErrorsWithStubs(t *testing.T) {
	rec := newRecorder(t)
	var dbgLogs []string
	t.Cleanup(bridge.SetDebug(func(msg string) { dbgLogs = append(dbgLogs, msg) }))

	EmitIssue(nil)
	EmitIssue(issue(CodeFailed, "T", "M"))
	if len(rec.issues) != 1 {
		t.Fatalf("EmitIssue recorded %+v", rec.issues)
	}

	noModRoot := t.TempDir()
	if got := findModuleRoot(noModRoot, "/fallback"); got != "/fallback" {
		t.Fatalf("findModuleRoot fallback = %q", got)
	}
	if _, err := parseRunConfig("{bad"); err == nil {
		t.Fatal("expected error for invalid JSON")
	}
	if _, err := parseRunConfig(`{"name":"x"}`); err == nil {
		t.Fatal("expected error when target is nil")
	}
	if runKey("") != "config:default" || runKey("api") != "config:api" {
		t.Fatal("runKey mismatch")
	}

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module example.com/rem\n\ngo 1.24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\nfunc main() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "compose.yaml"), []byte("services:\n  api:\n    image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	stubDir := t.TempDir()
	prependRemotePATH(t, stubDir)
	preserveGoCache(t)
	homeOK := t.TempDir()
	t.Setenv("HOME", homeOK)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(homeOK, ".cache"))

	writeRemoteStub(t, stubDir, "docker", "echo stop-fail >&2; exit 1\n")
	stopRemote(Transport{Target: Target{Kind: KindCompose, Service: "api", ComposeFile: filepath.Join(root, "compose.yaml")}, DockerPath: filepath.Join(stubDir, "docker")}, "/tmp/s")()
	if len(dbgLogs) == 0 {
		t.Fatal("expected stopRemote failure to call bridge.Debug")
	}

	Run(root, "{bad json")

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=\ndlv=/usr/bin/dlv\ntar=/bin/tar\n" ;;
esac
`)
	if _, iss := prepare(root, Target{Kind: KindCompose, Service: "bad!"}, "", nil, "", root); iss == nil || iss.Code != CodeConfig {
		t.Fatalf("prepare invalid target = %+v", iss)
	}
	if _, iss := prepare(root, Target{Kind: KindCompose, Service: "api"}, "", map[string]string{"CGO_ENABLED": "1"}, "", root); iss == nil || iss.Code != CodeGoMissing {
		t.Fatalf("prepare CGO without go = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    fi
    exit 0
    ;;
  *"port api"*) exit 1 ;;
esac
`)
	Run(root, `{"name":"cgoMissing","envVars":{"CGO_ENABLED":"1"},"target":{"kind":"compose","service":"nope"}}`)

	Run(root, `{"name":"okrun","workingDirectory":".","target":{"kind":"compose","service":"api"}}`)
	rec.waitFor(t, "run started", 30*time.Second, func() bool { return rec.started["config:okrun"] != 0 })
	if id := rec.started["config:okrun"]; id != 0 {
		runner.StopProgramRun(id)
		waitRunExit(t, rec, id)
	}

	if id := RunTests(root, "{bad"); id != 0 {
		t.Fatalf("bad RunTests id = %d", id)
	}
	if id := RunTests(root, `{"dir":"`+root+`","target":{"kind":"compose","service":"missing"}}`); id != 0 {
		t.Fatalf("bad target RunTests id = %d", id)
	}
	emptyGoDir := t.TempDir()
	if id := RunTests(emptyGoDir, `{"dir":"`+emptyGoDir+`","target":{"kind":"compose","service":"api","composeFile":"`+filepath.Join(root, "compose.yaml")+`"}}`); id != 0 {
		t.Fatalf("goList fail RunTests id = %d", id)
	}
	testReqJSON, _ := json.Marshal(TestRequest{
		TestRequest: runner.TestRequest{Dir: root, Packages: []string{"."}, Cover: true},
		Name:        "rt",
		Target:      &Target{Kind: KindCompose, Service: "api"},
	})
	if tid := RunTests(root, string(testReqJSON)); tid != 0 {
		rec.waitFor(t, "test done", 45*time.Second, func() bool { return rec.done() != nil })
	}

	CancelDebug()

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"port api"*) echo "0.0.0.0:2345" ;;
esac
`)
	if _, ok := composePublishedPort(Transport{Target: Target{Kind: KindCompose, Service: "api", ComposeFile: filepath.Join(root, "compose.yaml")}, DockerPath: filepath.Join(stubDir, "docker")}, 2345); ok {
		t.Fatal("non-loopback published port should return false")
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    fi
    ;;
  *"port api"*) exit 1 ;;
esac
`)
	p, iss := prepare(root, Target{Kind: KindCompose, Service: "api"}, "dbg", nil, "", root)
	if iss != nil {
		t.Fatalf("prepare dbg: %+v", iss)
	}
	defer func() { _ = os.RemoveAll(p.plan.LocalTmp) }()

	if _, iss := prepareAccess(prepared{plan: Plan{Target: Target{Kind: "bogus"}}}); iss == nil || iss.Code != CodeConfig {
		t.Fatalf("prepareAccess bogus = %+v", iss)
	}
	if _, iss := prepareAccess(p); iss != nil {
		t.Fatalf("prepareAccess compose relay = %+v", iss)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"port api"*) echo "127.0.0.1:23456" ;;
esac
`)
	accPub, iss := prepareAccess(p)
	if iss != nil || accPub.listen != "0.0.0.0:2345" {
		t.Fatalf("prepareAccess compose published = (%+v, %+v)", accPub, iss)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		c, _ := ln.Accept()
		if c != nil {
			_ = c.Close()
		}
	}()
	if c, err := dialTCP(ln.Addr().String(), 1); err != nil {
		t.Fatal(err)
	} else {
		_ = c.Close()
	}
	_ = ln.Close()
	if _, err := dialTCP("127.0.0.1:1", 1); err == nil {
		t.Fatal("expected dialTCP failure on closed port")
	}

	if !forwardAlive(fakeRWCloser{}) {
		t.Fatal("non-net.Conn should return forwardAlive true")
	}
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()
	if !forwardAlive(c1) {
		t.Fatal("quiet net.Pipe should time out and return forwardAlive true")
	}
	go func() { _, _ = c2.Write([]byte("x")) }()
	if forwardAlive(c1) {
		t.Fatal("conn with readable byte should return forwardAlive false")
	}
	c3, c4 := net.Pipe()
	_ = c4.Close()
	if forwardAlive(c3) {
		_ = c3.Close()
		t.Fatal("closed peer conn should return forwardAlive false")
	}
	_ = c3.Close()

	if err := Debug(root, "{bad"); err == nil {
		t.Fatal("expected Debug bad JSON error")
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*) printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=\ntar=/bin/tar\n" ;;
esac
`)
	dbgCfg := `{"name":"d1","target":{"kind":"compose","service":"api"}}`
	if err := Debug(root, dbgCfg); err == nil || !strings.Contains(err.Error(), "Delve") {
		t.Fatalf("Debug missing dlv = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    elif echo "$*" | grep -q -- "--headless"; then
      echo "operation not permitted" >&2; exit 1
    fi
    ;;
  *"port api"*) exit 1 ;;
esac
`)
	if err := Debug(root, dbgCfg); err == nil || !strings.Contains(err.Error(), "Allowed") {
		t.Fatalf("Debug ptrace error = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    elif echo "$*" | grep -q -- "--headless"; then
      echo "address already in use" >&2; exit 1
    fi
    ;;
  *"port api"*) exit 1 ;;
esac
`)
	if err := Debug(root, dbgCfg); err == nil || !strings.Contains(err.Error(), "Busy") {
		t.Fatalf("Debug busy port = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    elif echo "$*" | grep -q -- "--headless"; then
      echo "boom" >&2; exit 1
    fi
    ;;
  *"port api"*) exit 1 ;;
esac
`)
	if err := Debug(root, dbgCfg); err == nil || !strings.Contains(err.Error(), "didn’t start under Delve") {
		t.Fatalf("Debug generic start error = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    elif echo "$*" | grep -q -- "--headless"; then
      echo "API server listening at: 127.0.0.1:40000"
      sleep 5
    fi
    ;;
  *"port api"*) echo "127.0.0.1:1" ;;
esac
`)
	dbgDialCfg := `{"name":"d2","target":{"kind":"compose","service":"api","debugPort":40000}}`
	if err := Debug(root, dbgDialCfg); err == nil || !strings.Contains(err.Error(), "Couldn’t Connect to Delve") {
		t.Fatalf("Debug dial fail = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    elif echo "$*" | grep -q -- "--headless"; then
      sleep 5
    fi
    ;;
  *"port api"*) echo "127.0.0.1:1" ;;
esac
`)
	go func() {
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			debugMu.Lock()
			ready := debugCancel != nil
			debugMu.Unlock()
			if ready {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		CancelDebug()
	}()
	if err := Debug(root, dbgDialCfg); err == nil || !strings.Contains(err.Error(), "stopped") {
		t.Fatalf("Debug cancelled = %v", err)
	}

	writeRemoteStub(t, stubDir, "docker", `
case "$*" in
  *"ps --status running"*) echo "api" ;;
  *"exec -T api"*)
    if echo "$*" | grep -q "golens-probe"; then
      printf "golens-probe\nmachine=x86_64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n"
    elif echo "$*" | grep -q "tar -x"; then
      cat >/dev/null
    fi
    ;;
esac
`)
	if out := CheckJSON(root, "{bad"); !strings.Contains(out, `"ok":false`) {
		t.Fatalf("CheckJSON bad = %s", out)
	}
	if out := CheckJSON(root, `{"kind":"compose","service":"bad!"}`); !strings.Contains(out, `"code":"config"`) {
		t.Fatalf("CheckJSON invalid target = %s", out)
	}
	if out := CheckJSON(root, `{"kind":"compose","service":"api"}`); !strings.Contains(out, `"ok":true`) {
		t.Fatalf("CheckJSON ok = %s", out)
	}

	if id := Fix(root, "{bad", FixStartService); id != 0 {
		t.Fatalf("Fix bad json = %d", id)
	}
	if id := Fix(root, `{"kind":"compose","service":"bad!"}`, FixStartService); id != 0 {
		t.Fatalf("Fix bad target = %d", id)
	}
	if id := Fix(root, `{"kind":"compose","service":"api"}`, "unknownFix"); id != 0 {
		t.Fatalf("Fix unknown = %d", id)
	}
	if id := Fix(root, `{"kind":"compose","service":"api"}`, FixStartService); id != 0 {
		waitRunExit(t, rec, id)
	}
	if id := Fix(root, `{"kind":"compose","service":"api"}`, FixInstallDelve); id != 0 {
		runner.StopProgramRun(id)
		waitRunExit(t, rec, id)
	}

	setRemoteGlobals(t, controlDir, []string{"-F", "/dev/null", "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no"})
	sshPlan := p.plan
	closedLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedSSHPort := closedLn.Addr().(*net.TCPAddr).Port
	_ = closedLn.Close()
	sshPlan.Target = Target{Kind: KindSSH, Host: "127.0.0.1", Port: closedSSHPort}
	sshAcc, iss := prepareAccess(prepared{plan: sshPlan, tr: NewTransport(sshPlan.Target)})
	if iss != nil {
		t.Fatalf("prepareAccess ssh = %+v", iss)
	}
	if c, derr := sshAcc.dial(); derr == nil {
		_ = c.Close()
	}
	if sshAcc.teardown != nil {
		sshAcc.teardown()
	}
}

func TestRemoteDebugCleanupWhenStartManagedFails(t *testing.T) {
	root := t.TempDir()
	tmpBox := t.TempDir()
	t.Setenv("TMPDIR", tmpBox)

	stubDir := t.TempDir()
	prependRemotePATH(t, stubDir)
	t.Setenv("HOME", t.TempDir())

	sshLog := filepath.Join(t.TempDir(), "ssh.log")
	sshStub := writeRemoteStub(t, stubDir, "ssh", `
printf '%s\n' "$*" >> "`+sshLog+`"
case "$*" in
  *"uname -m"*) printf "golens-probe\nmachine=arm64\nhome=/root\nbase=/tmp/.golens\ngo=/usr/bin/go\ndlv=/usr/bin/dlv\ntar=/bin/tar\n" ;;
esac
`)
	oldSSH := sshBinary
	sshBinary = sshStub
	t.Cleanup(func() { sshBinary = oldSSH })
	setRemoteGlobals(t, controlDir, []string{"-F", "/dev/null"})

	oldStart := startManaged
	startManaged = func(_ *exec.Cmd, _, _, _ string, _ runner.ManagedOptions) (int64, <-chan struct{}) {
		ch := make(chan struct{})
		close(ch)
		return 0, ch
	}
	t.Cleanup(func() { startManaged = oldStart })

	err := Debug(root, `{"name":"d-fail","target":{"kind":"ssh","host":"127.0.0.1"}}`)
	if err == nil {
		t.Fatal("expected Debug error when StartManaged returns 0")
	}
	entries, rerr := os.ReadDir(tmpBox)
	if rerr != nil {
		t.Fatal(rerr)
	}
	if len(entries) != 0 {
		t.Fatalf("LocalTmp leaked after StartManaged returned 0: %+v", entries)
	}
	logBytes, rerr := os.ReadFile(sshLog)
	if rerr != nil {
		t.Fatal(rerr)
	}
	if !strings.Contains(string(logBytes), "-O cancel") {
		t.Fatalf("teardown was not called when StartManaged returned 0; ssh log = %q", string(logBytes))
	}
}
