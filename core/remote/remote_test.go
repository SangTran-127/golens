package remote

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestQuoteRoundTripsThroughTheShell(t *testing.T) {
	args := []string{"plain", "with space", "it's", `"double"`, "$HOME", "a;b", "", "tab\tx", "-gcflags=all=-N -l"}
	out, err := exec.Command("/bin/sh", "-c", "printf '%s\\n' "+QuoteArgv(args)).Output()
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if !reflect.DeepEqual(got, args) {
		t.Fatalf("round trip = %q, want %q", got, args)
	}
}

func TestNestedQuotingSurvivesTwoShells(t *testing.T) {
	inner := "printf '%s\\n' " + QuoteArgv([]string{"it's", "$x y"})
	outer := "sh -c " + Quote(inner)
	out, err := exec.Command("/bin/sh", "-c", outer).Output()
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "it's\n$x y\n" {
		t.Fatalf("got %q", out)
	}
}

func TestGoArch(t *testing.T) {
	cases := map[string][2]string{
		"x86_64":  {"amd64", ""},
		"aarch64": {"arm64", ""},
		"arm64":   {"arm64", ""},
		"armv7l":  {"arm", "7"},
		"i686":    {"386", ""},
	}
	for m, want := range cases {
		a, arm, ok := GoArch(m + "\n")
		if !ok || a != want[0] || arm != want[1] {
			t.Errorf("GoArch(%q) = %q %q %v", m, a, arm, ok)
		}
	}
	if _, _, ok := GoArch("sparc"); ok {
		t.Error("sparc should be unknown")
	}
}

func TestSlug(t *testing.T) {
	if got := Slug("My API Server"); got != "my-api-server" {
		t.Errorf("got %q", got)
	}
	if got := Slug("../../etc"); got != "etc" {
		t.Errorf("path traversal slug = %q", got)
	}
	if got := Slug("$$$"); got != "default" {
		t.Errorf("got %q", got)
	}
	long := Slug(strings.Repeat("abc", 30))
	if len(long) > 40 {
		t.Errorf("slug too long: %d", len(long))
	}
}

func composeTarget(t *testing.T) Target {
	dir := t.TempDir()
	file := filepath.Join(dir, "compose.yaml")
	if err := os.WriteFile(file, []byte("services:\n  api:\n    image: golang\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tg, iss := Target{Kind: KindCompose, Service: "api"}.Resolve(dir)
	if iss != nil {
		t.Fatal(iss)
	}
	return tg
}

func TestResolveFindsTheComposeFile(t *testing.T) {
	tg := composeTarget(t)
	if filepath.Base(tg.ComposeFile) != "compose.yaml" || !filepath.IsAbs(tg.ComposeFile) {
		t.Fatalf("compose file = %q", tg.ComposeFile)
	}
}

func TestResolveRejectsBadInput(t *testing.T) {
	root := t.TempDir()
	cases := []Target{
		{Kind: KindCompose, Service: ""},
		{Kind: KindCompose, Service: "api"},
		{Kind: KindSSH, Host: ""},
		{Kind: KindSSH, Host: "-oProxyCommand=evil"},
		{Kind: KindSSH, Host: "a b"},
		{Kind: "k8s"},
	}
	for _, c := range cases {
		if _, iss := c.Resolve(root); iss == nil {
			t.Errorf("Resolve(%+v) accepted bad input", c)
		}
	}
	if _, iss := (Target{Kind: KindSSH, Host: "dev@build-box.local"}).Resolve(root); iss != nil {
		t.Errorf("valid host rejected: %v", iss)
	}
}

func TestComposeShellArgv(t *testing.T) {
	tg := composeTarget(t)
	tr := Transport{Target: tg, DockerPath: "/usr/bin/docker"}
	got := tr.Shell("echo hi")
	want := []string{"/usr/bin/docker", "compose", "-f", tg.ComposeFile, "--project-directory", filepath.Dir(tg.ComposeFile), "exec", "-T", "api", "sh", "-c", "echo hi"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}
}

func TestSSHShellArgvMultiplexesAndNeverPrompts(t *testing.T) {
	tr := Transport{Target: Target{Kind: KindSSH, Host: "dev@box", Port: 2222}, SSHPath: "/usr/bin/ssh", ControlDir: "/tmp/cm"}
	got := tr.Shell("echo 'hi'")
	line := strings.Join(got, " ")
	for _, want := range []string{"BatchMode=yes", "ControlMaster=auto", "ControlPath=/tmp/cm/%C", "ControlPersist=600", "-p 2222", "-T dev@box"} {
		if !strings.Contains(line, want) {
			t.Errorf("missing %q in %q", want, line)
		}
	}
	if last := got[len(got)-1]; last != "sh -c 'echo '\\''hi'\\'''" {
		t.Errorf("remote command = %q", last)
	}
	fwd := tr.SSHControl("forward", "-L", "127.0.0.1:5000:127.0.0.1:2345")
	if strings.Join(fwd[len(fwd)-5:], " ") != "-O forward -L 127.0.0.1:5000:127.0.0.1:2345 dev@box" {
		t.Errorf("forward argv = %q", fwd)
	}
}

func TestParseProbe(t *testing.T) {
	out := "motd noise\ngolens-probe\nmachine=aarch64\nhome=/root\nbase=/tmp/golens\ngo=/usr/local/go/bin/go\ngoversion=go1.23.1\ndlv=\ntar=/bin/tar\npwd=/app\n"
	p, ok := ParseProbe(out)
	if !ok {
		t.Fatal("marker not found")
	}
	want := Probe{Machine: "aarch64", GOARCH: "arm64", Home: "/root", Base: "/tmp/golens", Go: "/usr/local/go/bin/go", GoVersion: "go1.23.1", Tar: "/bin/tar", Pwd: "/app"}
	if p != want {
		t.Fatalf("got %+v", p)
	}
	if _, ok := ParseProbe("Permission denied"); ok {
		t.Error("probe without marker parsed")
	}
}

func TestProbeScriptRunsInAPosixShell(t *testing.T) {
	out, err := exec.Command("/bin/sh", "-c", ProbeScript(Target{Kind: KindSSH})).Output()
	if err != nil {
		t.Fatal(err)
	}
	p, ok := ParseProbe(string(out))
	if !ok || p.Machine == "" || !strings.HasSuffix(p.Base, "/.cache/golens") {
		t.Fatalf("probe = %+v ok=%v", p, ok)
	}
}

func TestClassifySSH(t *testing.T) {
	tg := Target{Kind: KindSSH, Host: "dev@box"}
	cases := map[string]string{
		"dev@box: Permission denied (publickey,password).":                                                            CodeAuthFailed,
		"No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.": CodeHostKeyUnknown,
		"@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.":                     CodeHostKeyChanged,
		"ssh: Could not resolve hostname box: nodename nor servname provided, or not known":                           CodeHostNotFound,
		"ssh: connect to host box port 22: Connection refused":                                                        CodeUnreachable,
		"ssh: connect to host box port 22: Operation timed out":                                                       CodeUnreachable,
		"something odd": CodeFailed,
	}
	for stderr, code := range cases {
		i := classifySSH(tg, stderr)
		if i.Code != code {
			t.Errorf("%q → %s, want %s", stderr, i.Code, code)
		}
		if i.Title == "" || i.Message == "" {
			t.Errorf("%q has no explanation", stderr)
		}
	}
	if i := classifySSH(tg, "Permission denied"); i.Fix != FixOpenTerminal || !strings.Contains(i.Command, "ssh-copy-id") {
		t.Errorf("auth failure fix = %q %q", i.Fix, i.Command)
	}
	if i := classifySSH(tg, "Host key verification failed."); !strings.HasPrefix(i.Command, "ssh ") || strings.Contains(i.Command, " -p ") {
		t.Errorf("host key fix = %q", i.Command)
	}
	custom := tg
	custom.Port = 2222
	if i := classifySSH(custom, "Host key verification failed."); !strings.HasPrefix(i.Command, "ssh -p 2222 ") {
		t.Errorf("host key fix with port = %q", i.Command)
	}
}

func TestSSHOptionsLeavePortToSSHConfig(t *testing.T) {
	for _, tc := range []struct {
		port int
		want string
	}{{0, ""}, {22, ""}, {2222, "2222"}} {
		tr := Transport{Target: Target{Kind: KindSSH, Host: "golens-sandbox", Port: tc.port}, ControlDir: "/tmp"}
		opts := tr.SSHOptions()
		got := ""
		for i, o := range opts {
			if o == "-p" && i+1 < len(opts) {
				got = opts[i+1]
			}
		}
		if got != tc.want {
			t.Errorf("port %d: -p %q, want %q (opts %v)", tc.port, got, tc.want, opts)
		}
	}
}

func TestClassifyCompose(t *testing.T) {
	tg := Target{Kind: KindCompose, Service: "api"}
	cases := map[string]string{
		"Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?": CodeEngineDown,
		`service "api" is not running`: CodeServiceNotRunning,
		"no such service: api":         CodeUnknownService,
		`OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH`: CodeNoShell,
	}
	for stderr, code := range cases {
		if i := classifyCompose(tg, stderr); i.Code != code {
			t.Errorf("%q → %s, want %s", stderr, i.Code, code)
		}
	}
	if i := classifyCompose(tg, `service "api" is not running`); i.Fix != FixStartService {
		t.Errorf("not running fix = %q", i.Fix)
	}
}

func testPlan(t *testing.T, kind string) Plan {
	tg := Target{Kind: KindSSH, Host: "dev@box"}
	base := "/home/dev/.cache/golens"
	if kind == KindCompose {
		tg = composeTarget(t)
		base = composeBase
	}
	return Plan{
		Target:     tg,
		Probe:      Probe{Machine: "x86_64", GOARCH: "amd64", Base: base, Dlv: "/usr/local/bin/dlv", Tar: "/bin/tar"},
		Name:       "API Server",
		Project:    "shop",
		ModuleRoot: "/Users/me/shop",
		RunDir:     "/Users/me/shop/cmd/api",
		BuildFlags: []string{"-tags", "dev"},
		Args:       []string{"--port", "8080", "it's"},
		Env:        map[string]string{"DB_URL": "postgres://db/x?a=1&b=2", "GOFLAGS": "-mod=mod", "CGO_ENABLED": "0", "bad key": "x"},
		LocalTmp:   "/tmp/golens-remote-1",
	}
}

func bashSyntaxOK(t *testing.T, script string) {
	t.Helper()
	cmd := exec.Command("/bin/bash", "-n")
	cmd.Stdin = strings.NewReader(script)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("script has a syntax error: %v %s\n%s", err, out, script)
	}
}

func TestRunScriptCrossCompilesAndRunsRemotely(t *testing.T) {
	for _, kind := range []string{KindCompose, KindSSH} {
		p := testPlan(t, kind)
		s := p.RunScript()
		bashSyntaxOK(t, s)
		for _, want := range []string{
			"env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-mod=mod go build -tags dev -o /tmp/golens-remote-1/app .",
			"cd /Users/me/shop/cmd/api",
			"/usr/bin/tar --no-mac-metadata --no-xattrs --format=gnutar -C /tmp/golens-remote-1 -cf - app",
		} {
			if !strings.Contains(s, want) {
				t.Errorf("%s: missing %q in\n%s", kind, want, s)
			}
		}
		if strings.Contains(s, "bad key") {
			t.Errorf("%s: invalid env key leaked into the script", kind)
		}
		if !strings.Contains(s, "/shop/api-server/run/app") {
			t.Errorf("%s: stage path missing:\n%s", kind, s)
		}
		if strings.Count(s, "exec ") < 1 || !strings.Contains(s, "golens.pid") {
			t.Errorf("%s: final command must exec and record its pid", kind)
		}
	}
}

func TestRunScriptBuildsInsideTheTargetWithCgo(t *testing.T) {
	p := testPlan(t, KindCompose)
	p.Env["CGO_ENABLED"] = "1"
	p.InTarget = CgoEnabled(p.Env)
	s := p.RunScript()
	bashSyntaxOK(t, s)
	if strings.Contains(s, "GOOS=linux") {
		t.Error("in-target build must not cross-compile")
	}
	for _, want := range []string{"--no-xattrs", "--exclude .git", "/tmp/golens/shop/api-server/src", "export CGO_ENABLED=1"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q", want)
		}
	}
	subs := SubstitutePath(p)
	if len(subs) != 1 || subs[0]["from"] != "/Users/me/shop" || subs[0]["to"] != "/tmp/golens/shop/api-server/src" {
		t.Errorf("substitutePath = %v", subs)
	}
	if SubstitutePath(testPlan(t, KindCompose)) != nil {
		t.Error("a binary built on the Mac keeps local paths and needs no mapping")
	}
}

func TestDebugScriptStartsHeadlessDelve(t *testing.T) {
	p := testPlan(t, KindSSH)
	p.Debug = true
	p.DebugAddr = "127.0.0.1:2345"
	s := p.RunScript()
	bashSyntaxOK(t, s)
	for _, want := range []string{"-gcflags=all=-N -l", "exec --headless --listen=127.0.0.1:2345 --accept-multiclient --api-version=2", "/usr/local/bin/dlv"} {
		if !strings.Contains(s, want) && !strings.Contains(s, Quote(want)) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
	p.TestPkg = &TestPackage{Dir: p.RunDir}
	p.TestArgs = []string{"-test.run", "^TestX$", "-test.v"}
	s = p.RunScript()
	bashSyntaxOK(t, s)
	if !strings.Contains(s, "go test -c") || !strings.Contains(s, "Copying sources") {
		t.Errorf("debugging a test builds the test binary and copies sources:\n%s", s)
	}
}

func TestTestScriptPipesThroughTest2json(t *testing.T) {
	p := testPlan(t, KindCompose)
	pkgs := []TestPackage{{ImportPath: "shop/cmd/api", Dir: "/Users/me/shop/cmd/api"}, {ImportPath: "shop/store", Dir: "/Users/me/shop/store"}}
	s := p.TestScript(pkgs, TestArgs("^TestA$", "", true))
	bashSyntaxOK(t, s)
	for _, want := range []string{
		"go test -c -tags dev -o /tmp/golens-remote-1/bin/pkg0.test shop/cmd/api",
		"go test -c -tags dev -o /tmp/golens-remote-1/bin/pkg1.test shop/store",
		"go tool test2json -t -p shop/cmd/api",
		"go tool test2json -t -p shop/store",
		"-test.v=test2json",
		"exit $status",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
	p.Env["CGO_ENABLED"] = "1"
	p.InTarget = true
	s = p.TestScript(pkgs, TestArgs("^TestA$", "", false))
	bashSyntaxOK(t, s)
	if !strings.Contains(s, "go test -json -tags dev -run=^TestA$ ./cmd/api ./store") && !strings.Contains(s, Quote("-run=^TestA$")) {
		t.Errorf("in-target test command missing:\n%s", s)
	}
}

func TestTestArgs(t *testing.T) {
	if got := TestArgs("^TestA$", "", false); !reflect.DeepEqual(got, []string{"-test.run=^TestA$"}) {
		t.Errorf("got %q", got)
	}
	if got := TestArgs("", ".", true); !reflect.DeepEqual(got, []string{"-test.short", "-test.run=^$", "-test.bench=.", "-test.benchmem"}) {
		t.Errorf("got %q", got)
	}
	if got := goTestFlags([]string{"-test.run=^A$", "-test.short"}); !reflect.DeepEqual(got, []string{"-run=^A$", "-short"}) {
		t.Errorf("got %q", got)
	}
}

func TestStopScriptKillsOnlyTheStagedProgram(t *testing.T) {
	s := StopScript("/tmp/golens/shop/api/run")
	bashSyntaxOK(t, s)
	for _, want := range []string{"kill -TERM", "kill -KILL", "/tmp/golens/shop/api/run/golens.pid", "/tmp/golens/shop/api/run/*)"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in %s", want, s)
		}
	}
	dir := t.TempDir()
	cmd := exec.Command("/bin/sh", "-c", "echo $$ > "+Quote(filepath.Join(dir, pidName))+"; exec sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	waitFile(t, filepath.Join(dir, pidName))
	if out, err := exec.Command("/bin/sh", "-c", StopScript(dir)).CombinedOutput(); err != nil {
		t.Fatalf("stop script failed: %v %s", err, out)
	}
	if err := cmd.Wait(); err == nil {
		t.Fatal("the staged program was not stopped")
	}
	if _, err := os.Stat(filepath.Join(dir, pidName)); !os.IsNotExist(err) {
		t.Error("pid file left behind")
	}
}

func waitFile(t *testing.T, p string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if b, err := os.ReadFile(p); err == nil && len(b) > 0 {
			return
		}
		exec.Command("/bin/sleep", "0.05").Run()
	}
	t.Fatalf("%s never appeared", p)
}

func TestInstallDelveScript(t *testing.T) {
	p := testPlan(t, KindSSH)
	s := p.InstallDelveScript()
	bashSyntaxOK(t, s)
	for _, want := range []string{"go get github.com/go-delve/delve@latest", "env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/golens-remote-1/dlvbin/dlv github.com/go-delve/delve/cmd/dlv", "/home/dev/.cache/golens/bin"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
}

func TestWorkDirExpandsHome(t *testing.T) {
	p := testPlan(t, KindSSH)
	p.Target.WorkDir = "~/srv/app"
	if got := p.cdWorkDir(""); got != `cd "$HOME"/srv/app || exit 1; ` {
		t.Errorf("got %q", got)
	}
	p.Target.WorkDir = ""
	if got := p.cdWorkDir(""); got != "" {
		t.Errorf("empty work dir should keep the default, got %q", got)
	}
}

func TestParsePublishedPort(t *testing.T) {
	for in, want := range map[string]string{
		"127.0.0.1:49153\n":              "127.0.0.1:49153",
		"[::1]:2345\n":                   "[::1]:2345",
		"0.0.0.0:2345\n127.0.0.1:2345\n": "127.0.0.1:2345",
		"localhost:2345":                 "127.0.0.1:2345",
		"127.0.0.2:2345\r\n":             "127.0.0.2:2345",
	} {
		if got, ok := ParsePublishedPort(in); !ok || got != want {
			t.Errorf("%q → %q %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "0.0.0.0:49153\n", "[::]:2345\n0.0.0.0:2345\n", "192.168.1.20:2345", ":2345", "127.0.0.1:0", "127.0.0.1:x", "2345"} {
		if got, ok := ParsePublishedPort(in); ok {
			t.Errorf("%q must not be accepted, got %q", in, got)
		}
	}
}

func TestParseComposeServices(t *testing.T) {
	yaml := "version: '3'\nservices:\n  api:\n    build: .\n    ports:\n      - \"8080:8080\"\n  db:\n    image: postgres\n  # comment\n  \"worker\":\n    image: x\nvolumes:\n  data:\n"
	if got := ParseComposeServices(yaml); !reflect.DeepEqual(got, []string{"api", "db", "worker"}) {
		t.Errorf("got %q", got)
	}
}

func TestWantsRemote(t *testing.T) {
	if WantsRemote(`{"name":"x"}`) || WantsRemote(`{"target":{"kind":"local"}}`) || WantsRemote("not json") {
		t.Error("local configs must stay local")
	}
	if !WantsRemote(`{"target":{"kind":"ssh","host":"a@b"}}`) || !WantsRemote(`{"dir":"/x","target":{"kind":"compose","service":"api"}}`) {
		t.Error("remote target not detected")
	}
}

func TestLabel(t *testing.T) {
	if got := (Target{Kind: KindSSH, Host: "dev@box", Port: 2222}).Label(); got != "dev@box:2222" {
		t.Errorf("got %q", got)
	}
	if got := (Target{Kind: KindCompose, Service: "api"}).Label(); got != "api (Compose)" {
		t.Errorf("got %q", got)
	}
}

func TestRelSlashSeesThroughSymlinks(t *testing.T) {
	real := t.TempDir()
	if err := os.MkdirAll(filepath.Join(real, "calc", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if got := relSlash(link, filepath.Join(real, "calc", "sub")); got != "calc/sub" {
		t.Errorf("symlinked root: got %q", got)
	}
	if got := relSlash(real, filepath.Join(link, "calc")); got != "calc" {
		t.Errorf("symlinked dir: got %q", got)
	}
}

func TestSSHSecurityKeyDetectionAndUseKeychainConfig(t *testing.T) {
	tmp := t.TempDir()

	// 1. Non-existent default identityfile from ssh -G must be ignored
	outNonExistent := "identityfile " + filepath.Join(tmp, "missing_id_ed25519_sk") + "\n"
	if SSHConfigOutputUsesSecurityKey(outNonExistent) {
		t.Fatal("non-existent identityfile must not be treated as a security key")
	}

	// 2. Existing standard ed25519 key must not trigger security key mode
	stdKey := filepath.Join(tmp, "id_ed25519")
	if out, err := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "", "-f", stdKey).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen failed: %v (%s)", err, string(out))
	}
	if SSHConfigOutputUsesSecurityKey("identityfile " + stdKey + "\n") {
		t.Fatal("standard ed25519 key must not be treated as a security key")
	}

	// 3. Existing -sk key (with sk-ssh-ed25519@openssh.com .pub) triggers security key mode
	skKey := filepath.Join(tmp, "id_ed25519_sk")
	if err := os.WriteFile(skKey, []byte("-----BEGIN OPENSSH PRIVATE KEY-----\n-----END OPENSSH PRIVATE KEY-----\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skKey+".pub", []byte("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIA== test@sk\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if !SSHConfigOutputUsesSecurityKey("identityfile " + skKey + "\n") {
		t.Fatal("existing sk-ssh-ed25519@openssh.com key must be detected as a security key")
	}

	// 4. Verify Transport options and UseKeychain compatibility with Homebrew ssh
	trStd := Transport{Target: Target{Kind: KindSSH, Host: "dev@box"}, SSHPath: "/usr/bin/ssh", ControlDir: "/tmp"}
	optsStd := strings.Join(trStd.SSHOptions(), " ")
	if strings.Contains(optsStd, "IgnoreUnknown=UseKeychain") || !strings.Contains(optsStd, "ControlPath=/tmp/%C") {
		t.Fatalf("unexpected standard SSH options: %s", optsStd)
	}

	trSK := Transport{Target: Target{Kind: KindSSH, Host: "dev@box"}, SSHPath: "/opt/homebrew/bin/ssh", ControlDir: "/tmp", UsesSecurityKey: true}
	optsSK := strings.Join(trSK.SSHOptions(), " ")
	if !strings.Contains(optsSK, "IgnoreUnknown=UseKeychain") || !strings.Contains(optsSK, "ControlPath=/tmp/hb-%C") {
		t.Fatalf("expected IgnoreUnknown=UseKeychain and separate ControlPath=/tmp/hb-%%C, got: %s", optsSK)
	}

	if hbSSH := FindHomebrewSSH(); hbSSH != "" {
		cfgPath := filepath.Join(tmp, "ssh_config")
		cfgContent := "Host skbox\n  HostName 127.0.0.1\n  User dev\n  UseKeychain yes\n  IdentityFile " + skKey + "\n"
		if err := os.WriteFile(cfgPath, []byte(cfgContent), 0600); err != nil {
			t.Fatal(err)
		}
		prevExtra := extraSSHOptions
		extraSSHOptions = []string{"-F", cfgPath}
		defer func() { extraSSHOptions = prevExtra }()

		if !TargetUsesSecurityKey(Target{Kind: KindSSH, Host: "skbox"}) {
			t.Fatal("TargetUsesSecurityKey failed to detect sk key from ssh_config")
		}
		trResolved := NewTransport(Target{Kind: KindSSH, Host: "skbox"})
		checkArgs := append([]string{"-G"}, trResolved.SSHOptions()...)
		checkArgs = append(checkArgs, "skbox")
		if out, err := exec.Command(trResolved.SSHPath, checkArgs...).CombinedOutput(); err != nil {
			t.Fatalf("Homebrew ssh failed on config with UseKeychain yes: %v (%s)", err, string(out))
		}
	}
}

func TestListComposeServicesReadsPlainFilesWithoutDocker(t *testing.T) {
	bin := t.TempDir()
	marker := filepath.Join(bin, "called")
	script := "#!/bin/sh\necho called >> " + marker + "\necho fromcli\n"
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "compose.yaml"), []byte("services:\n  api:\n    image: x\n  db:\n    image: y\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := ListComposeServices(root, "")
	if !reflect.DeepEqual(got.Services, []string{"api", "db"}) {
		t.Fatalf("services = %v", got.Services)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("docker ran for a compose file the parser can read")
	}
	if err := os.WriteFile(filepath.Join(root, "compose.yaml"), []byte("include:\n  - other.yaml\nservices:\n  api:\n    image: x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got = ListComposeServices(root, "")
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("docker did not run for a compose file with include")
	}
	if !reflect.DeepEqual(got.Services, []string{"fromcli"}) {
		t.Fatalf("services with include = %v", got.Services)
	}
}

func TestDebugTestArgsBenchmarksAndTests(t *testing.T) {
	cases := []struct {
		name string
		cfg  RunConfig
		want []string
	}{
		{
			name: "top-level benchmark",
			cfg:  RunConfig{Test: "BenchmarkEncode"},
			want: []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$", "-test.benchmem", "-test.v"},
		},
		{
			name: "sub-benchmark row",
			cfg:  RunConfig{Test: "BenchmarkEncode", TestRow: "small payload"},
			want: []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^small_payload$", "-test.benchmem", "-test.v"},
		},
		{
			name: "benchmark pattern override",
			cfg:  RunConfig{TestPattern: "^BenchmarkEncode$/^v2$"},
			want: []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^v2$", "-test.benchmem", "-test.v"},
		},
		{
			name: "normal test",
			cfg:  RunConfig{Test: "TestEncode"},
			want: []string{"-test.run", "^TestEncode$", "-test.v"},
		},
		{
			name: "fuzz target",
			cfg:  RunConfig{Test: "FuzzEncode"},
			want: []string{"-test.run", "^FuzzEncode$", "-test.v"},
		},
		{
			name: "lowercase benchmark prefix guard",
			cfg:  RunConfig{Test: "Benchmarklower"},
			want: []string{"-test.run", "^Benchmarklower$", "-test.v"},
		},
	}
	for _, tc := range cases {
		if got := debugTestArgs(tc.cfg); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("%s: debugTestArgs = %v, want %v", tc.name, got, tc.want)
		}
	}

	p := testPlan(t, KindSSH)
	p.Debug = true
	p.DebugAddr = "127.0.0.1:2345"
	p.TestPkg = &TestPackage{Dir: p.RunDir}
	p.TestArgs = debugTestArgs(RunConfig{Test: "BenchmarkEncode", TestRow: "small payload"})
	s := p.RunScript()
	bashSyntaxOK(t, s)
	for _, want := range []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^small_payload$", "-test.benchmem"} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in remote debug script:\n%s", want, s)
		}
	}
}
