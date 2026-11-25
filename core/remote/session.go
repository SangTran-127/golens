package remote

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/dap"
	"golens/core/fsutil"
	"golens/core/runner"
	"golens/core/testutil"
)

type RunConfig struct {
	Name             string            `json:"name"`
	EnvVars          map[string]string `json:"envVars"`
	BuildFlags       string            `json:"buildFlags"`
	Args             string            `json:"args"`
	WorkingDirectory string            `json:"workingDirectory"`
	ActiveFilePath   string            `json:"activeFilePath"`
	Test             string            `json:"test"`
	TestRow          string            `json:"testRow"`
	TestPattern      string            `json:"testPattern,omitempty"`
	Target           *Target           `json:"target"`
}

type TestRequest struct {
	runner.TestRequest
	Name       string            `json:"name"`
	EnvVars    map[string]string `json:"envVars"`
	BuildFlags string            `json:"buildFlags"`
	Target     *Target           `json:"target"`
}

func WantsRemote(configJSON string) bool {
	var probe struct {
		Target *Target `json:"target"`
	}
	if json.Unmarshal([]byte(configJSON), &probe) != nil || probe.Target == nil {
		return false
	}
	return probe.Target.IsRemote()
}

func EmitIssue(i *Issue) {
	if i == nil {
		return
	}
	bridge.Log(i.Title + ". " + i.Message)
	if b, err := json.Marshal(i); err == nil && bridge.HasStatus() {
		bridge.Status("remoteIssue", string(b))
	}
}

func findModuleRoot(dir, fallback string) string {
	for d := dir; ; {
		if st, err := os.Stat(filepath.Join(d, "go.mod")); err == nil && !st.IsDir() {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return fallback
		}
		d = parent
	}
}

func projectName(root string) string {
	return filepath.Base(root)
}

type prepared struct {
	plan Plan
	tr   Transport
}

func prepare(root string, target Target, name string, env map[string]string, buildFlags, runDir string) (prepared, *Issue) {
	t, iss := target.Resolve(root)
	if iss != nil {
		return prepared{}, iss.with(t)
	}
	probe, iss := Check(t)
	if iss != nil {
		return prepared{}, iss
	}
	inTarget := CgoEnabled(env)
	if inTarget && probe.Go == "" {
		return prepared{}, goMissingIssue(t)
	}
	if name == "" {
		name = "default"
	}
	tmp, err := os.MkdirTemp("", "golens-remote-")
	if err != nil {
		return prepared{}, issue(CodeFailed, "Couldn’t Prepare the Build", err.Error()).with(t)
	}
	plan := Plan{
		Target:     t,
		Probe:      probe,
		Name:       name,
		Project:    projectName(root),
		ModuleRoot: findModuleRoot(runDir, root),
		RunDir:     runDir,
		BuildFlags: fsutil.SplitArgs(buildFlags),
		Env:        env,
		LocalTmp:   tmp,
		InTarget:   inTarget,
	}
	return prepared{plan: plan, tr: NewTransport(t)}, nil
}

func bashCommand(script, dir string) *exec.Cmd {
	cmd := exec.Command("/bin/bash", "-c", script)
	cmd.Dir = dir
	cmd.Env = LocalEnv()
	return cmd
}

func stopRemote(tr Transport, stage string) func() {
	return func() {
		r := runArgv(15*time.Second, tr.Shell(StopScript(stage)), "")
		if r.err != nil {
			bridge.Debug(fmt.Sprintf("remote stop on %s: %v %s", tr.Target.Label(), r.err, strings.TrimSpace(r.stderr)))
		}
	}
}

func parseRunConfig(configJSON string) (RunConfig, error) {
	var cfg RunConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return cfg, err
	}
	if cfg.Target == nil {
		return cfg, errors.New("no target")
	}
	return cfg, nil
}

func runKey(name string) string {
	if name == "" {
		return "config:default"
	}
	return "config:" + name
}

func Run(root, configJSON string) {
	cfg, err := parseRunConfig(configJSON)
	if err != nil {
		bridge.Log("Couldn’t read the run configuration: " + err.Error())
		return
	}
	runDir, note := fsutil.RunDir(root, cfg.WorkingDirectory, cfg.ActiveFilePath)
	if note != "" {
		bridge.Log(note)
	}
	p, iss := prepare(root, *cfg.Target, cfg.Name, cfg.EnvVars, cfg.BuildFlags, runDir)
	if iss != nil {
		EmitIssue(iss)
		return
	}
	plan := p.plan
	plan.Args = fsutil.SplitArgs(cfg.Args)
	cmd := bashCommand(plan.RunScript(), runDir)
	tmp := plan.LocalTmp
	if id, _ := startManaged(cmd, runKey(cfg.Name), plan.Name+" on "+plan.Target.Label(), runDir, runner.ManagedOptions{
		OnStop: stopRemote(p.tr, plan.RunStage()),
		OnExit: func(string) { _ = os.RemoveAll(tmp) },
	}); id == 0 {
		_ = os.RemoveAll(tmp)
	}
}

func goList(dir string, pkgs []string) ([]TestPackage, error) {
	if len(pkgs) == 0 {
		pkgs = []string{"."}
	}
	argv := append([]string{"go", "list", "-f", "{{.ImportPath}}\t{{.Dir}}"}, pkgs...)
	cmd := exec.Command("/bin/bash", "-c", QuoteArgv(argv))
	cmd.Dir = dir
	cmd.Env = LocalEnv()
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, errors.New(lastLine(string(ee.Stderr)))
		}
		return nil, err
	}
	var list []TestPackage
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		ip, d, ok := strings.Cut(line, "\t")
		if ok && ip != "" {
			list = append(list, TestPackage{ImportPath: ip, Dir: d})
		}
	}
	return list, nil
}

func RunTests(root, requestJSON string) int64 {
	var req TestRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil || req.Target == nil || req.Dir == "" {
		bridge.Log("Couldn’t read the test request.")
		return 0
	}
	p, iss := prepare(root, *req.Target, req.Name, req.EnvVars, req.BuildFlags, req.Dir)
	if iss != nil {
		EmitIssue(iss)
		return 0
	}
	plan := p.plan
	pkgs, err := goList(req.Dir, req.Packages)
	if err != nil || len(pkgs) == 0 {
		_ = os.RemoveAll(plan.LocalTmp)
		msg := "No packages to test."
		if err != nil {
			msg = err.Error()
		}
		EmitIssue(issue(CodeFailed, "Couldn’t List Test Packages", msg).with(plan.Target))
		return 0
	}
	if req.Cover || req.Profile || req.Fuzz {
		bridge.Log("Coverage, profiles and fuzzing are collected only on My Mac; running the tests on " + plan.Target.Label() + " without them.")
	}
	args := TestArgs(req.Pattern(), req.BenchPattern(), req.Short)
	suiteDirs := make(map[string]string, len(pkgs))
	for _, pkg := range pkgs {
		suiteDirs[pkg.ImportPath] = pkg.Dir
	}
	cmd := bashCommand(plan.TestScript(pkgs, args), plan.ModuleRoot)
	tmp := plan.LocalTmp
	return runner.StartTestCommand(cmd, req.Dir, suiteDirs, stopRemote(p.tr, plan.TestStage()), func() { _ = os.RemoveAll(tmp) })
}

var (
	debugMu     sync.Mutex
	debugCancel chan struct{}
	startManaged = runner.StartManaged
)

func CancelDebug() {
	debugMu.Lock()
	c := debugCancel
	debugCancel = nil
	debugMu.Unlock()
	if c != nil {
		close(c)
	}
}

func composePublishedPort(tr Transport, port int) (string, bool) {
	r := runArgv(15*time.Second, tr.ComposeArgs("port", tr.Target.Service, strconv.Itoa(port)), "")
	if r.err != nil {
		return "", false
	}
	addr, ok := ParsePublishedPort(r.stdout)
	if !ok && strings.TrimSpace(r.stdout) != "" {
		bridge.Log(fmt.Sprintf("%s publishes port %d beyond this Mac, so GoLens keeps Delve on the container’s loopback and reaches it through docker compose exec. To connect directly, publish it as 127.0.0.1:%d:%d.", tr.Target.Label(), port, port, port))
	}
	return addr, ok
}

func ParsePublishedPort(out string) (string, bool) {
	for _, line := range strings.Split(out, "\n") {
		host, port, err := net.SplitHostPort(strings.TrimSpace(line))
		if err != nil {
			continue
		}
		if n, err := strconv.Atoi(port); err != nil || n <= 0 || n > 65535 {
			continue
		}
		if host == "localhost" {
			host = "127.0.0.1"
		}
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			continue
		}
		return net.JoinHostPort(host, port), true
	}
	return "", false
}

func freeLocalPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func dialTCP(addr string, attempts int) (io.ReadWriteCloser, error) {
	var lastErr error
	for i := 0; i < attempts; i++ {
		c, err := net.DialTimeout("tcp", addr, 3*time.Second)
		if err == nil {
			return c, nil
		}
		lastErr = err
		time.Sleep(300 * time.Millisecond)
	}
	return nil, lastErr
}

type debugAccess struct {
	listen   string
	relayDir string
	dial     func() (io.ReadWriteCloser, error)
	teardown func()
}

func prepareAccess(p prepared) (debugAccess, *Issue) {
	t := p.plan.Target
	port := t.debugPort()
	switch t.Kind {
	case KindCompose:
		if addr, ok := composePublishedPort(p.tr, port); ok {
			return debugAccess{
				listen: "0.0.0.0:" + strconv.Itoa(port),
				dial:   func() (io.ReadWriteCloser, error) { return dialTCP(addr, 10) },
			}, nil
		}
		dir, err := BuildRelay(p.plan.Probe.GOARCH, p.plan.Probe.GOARM)
		if err != nil {
			return debugAccess{}, issue(CodeDebugger, "Couldn’t Prepare the Debugger Connection", err.Error()).with(t)
		}
		relay := filepath.ToSlash(filepath.Join(p.plan.BinDir(), relayBin))
		argv := p.tr.ComposeArgs("exec", "-T", t.Service, relay, "127.0.0.1:"+strconv.Itoa(port))
		return debugAccess{
			listen:   "127.0.0.1:" + strconv.Itoa(port),
			relayDir: dir,
			dial:     func() (io.ReadWriteCloser, error) { return dialCommand(argv) },
		}, nil
	case KindSSH:
		local, err := freeLocalPort()
		if err != nil {
			return debugAccess{}, issue(CodeDebugger, "Couldn’t Reserve a Local Port", err.Error()).with(t)
		}
		dir, err := BuildRelay(p.plan.Probe.GOARCH, p.plan.Probe.GOARM)
		if err != nil {
			return debugAccess{}, issue(CodeDebugger, "Couldn’t Prepare the Debugger Connection", err.Error()).with(t)
		}
		addr := "127.0.0.1:" + strconv.Itoa(port)
		relay := filepath.ToSlash(filepath.Join(p.plan.BinDir(), relayBin))
		spec := fmt.Sprintf("127.0.0.1:%d:%s", local, addr)
		var forwarded sync.Once
		cancelForward := func() {
			runArgv(10*time.Second, p.tr.SSHControl("cancel", "-L", spec), "")
		}
		return debugAccess{
			listen:   addr,
			relayDir: dir,
			dial: func() (io.ReadWriteCloser, error) {
				r := runArgv(15*time.Second, p.tr.SSHControl("forward", "-L", spec), "")
				if r.err == nil {
					if conn, err := dialTCP("127.0.0.1:"+strconv.Itoa(local), 5); err == nil {
						if forwardAlive(conn) {
							return conn, nil
						}
						_ = conn.Close()
					}
					forwarded.Do(cancelForward)
				}
				bridge.Log(t.Label() + " doesn’t allow SSH port forwarding, so GoLens reaches Delve through the SSH session instead.")
				return dialCommand(p.tr.Shell("exec " + Quote(relay) + " " + addr))
			},
			teardown: func() {
				forwarded.Do(cancelForward)
			},
		}, nil
	}
	return debugAccess{}, issue(CodeConfig, "Unknown Destination", t.Kind).with(t)
}

func debugTestArgs(cfg RunConfig) []string {
	_, args := testutil.DebugTestArgs(cfg.Test, cfg.TestRow, cfg.TestPattern)
	return args
}

func Debug(root, configJSON string) error {
	cfg, err := parseRunConfig(configJSON)
	if err != nil {
		return err
	}
	runDir, note := fsutil.RunDir(root, cfg.WorkingDirectory, cfg.ActiveFilePath)
	if note != "" {
		bridge.Log(note)
	}
	cancel := make(chan struct{})
	CancelDebug()
	debugMu.Lock()
	debugCancel = cancel
	debugMu.Unlock()
	defer func() {
		debugMu.Lock()
		if debugCancel == cancel {
			debugCancel = nil
		}
		debugMu.Unlock()
	}()

	p, iss := prepare(root, *cfg.Target, cfg.Name, cfg.EnvVars, cfg.BuildFlags, runDir)
	if iss != nil {
		EmitIssue(iss)
		return iss
	}
	tmp := p.plan.LocalTmp
	if p.plan.Probe.Dlv == "" {
		_ = os.RemoveAll(tmp)
		iss := dlvMissingIssue(p.plan.Target)
		EmitIssue(iss)
		return iss
	}
	access, iss := prepareAccess(p)
	if iss != nil {
		_ = os.RemoveAll(tmp)
		EmitIssue(iss)
		return iss
	}
	plan := p.plan
	plan.RelayDir = access.relayDir
	plan.Debug = true
	plan.DebugAddr = access.listen
	plan.Args = fsutil.SplitArgs(cfg.Args)
	if cfg.Test != "" || cfg.TestPattern != "" {
		plan.TestPkg = &TestPackage{Dir: runDir}
		plan.TestArgs = debugTestArgs(cfg)
	}

	ready := make(chan struct{})
	var readyOnce sync.Once
	var ptrace, portBusy bool
	var lineMu sync.Mutex
	onLine := func(text string, _ bool) {
		if strings.Contains(text, "API server listening at") {
			readyOnce.Do(func() { close(ready) })
		}
		low := strings.ToLower(text)
		if strings.Contains(low, "operation not permitted") || strings.Contains(low, "ptrace") && strings.Contains(low, "permission") {
			lineMu.Lock()
			ptrace = true
			lineMu.Unlock()
		}
		if strings.Contains(low, "address already in use") {
			lineMu.Lock()
			portBusy = true
			lineMu.Unlock()
		}
	}
	var teardownOnce sync.Once
	teardown := func() {
		teardownOnce.Do(func() {
			if access.teardown != nil {
				access.teardown()
			}
		})
	}
	cmd := bashCommand(plan.RunScript(), runDir)
	id, done := startManaged(cmd, runKey(cfg.Name), plan.Name+" on "+plan.Target.Label(), runDir, runner.ManagedOptions{
		OnStop: stopRemote(p.tr, plan.RunStage()),
		OnLine: onLine,
		OnExit: func(string) {
			_ = os.RemoveAll(tmp)
			teardown()
		},
	})
	if id == 0 {
		_ = os.RemoveAll(tmp)
		teardown()
		return errors.New("couldn’t start the build")
	}
	stop := func() {
		go runner.StopProgramRun(id)
	}
	select {
	case <-ready:
	case <-done:
		lineMu.Lock()
		denied, busy := ptrace, portBusy
		lineMu.Unlock()
		if busy {
			iss := issue(CodeDebugger, "Debugger Port Is Busy", fmt.Sprintf("Another program on %s already listens on port %d, so Delve couldn’t start there. Choose a different Debugger Port in Edit Run Configurations, then debug again.", plan.Target.Label(), plan.Target.debugPort())).with(plan.Target)
			iss.Fix, iss.FixTitle = FixEditTarget, "Edit Destination…"
			EmitIssue(iss)
			return iss
		}
		if denied {
			iss := ptraceIssue(plan.Target)
			EmitIssue(iss)
			return iss
		}
		return errors.New("the program didn’t start under Delve on " + plan.Target.Label() + "; the console shows why")
	case <-cancel:
		stop()
		return errors.New("debugging was stopped")
	case <-time.After(15 * time.Minute):
		stop()
		return errors.New("Delve didn’t start on " + plan.Target.Label() + " within 15 minutes")
	}
	conn, err := access.dial()
	if err != nil {
		stop()
		iss := issue(CodeDebugger, "Couldn’t Connect to Delve", "Delve started on "+plan.Target.Label()+" but GoLens couldn’t reach it: "+err.Error()).with(plan.Target)
		iss.Fix, iss.FixTitle = FixRetry, "Try Again"
		EmitIssue(iss)
		return iss
	}
	select {
	case <-cancel:
		_ = conn.Close()
		stop()
		return errors.New("debugging was stopped")
	default:
	}
	var subs []dap.SubstitutePath
	for _, m := range SubstitutePath(plan) {
		subs = append(subs, dap.SubstitutePath{From: m["from"], To: m["to"]})
	}
	err = dap.StartRemoteAttach(conn, dap.RunConfig{RemoteAddr: plan.Target.Label(), SubstitutePath: subs}, func() {
		runner.StopProgramRun(id)
		teardown()
	})
	if err != nil {
		stop()
		return fmt.Errorf("couldn’t attach to Delve on %s: %w", plan.Target.Label(), err)
	}
	return nil
}

func forwardAlive(conn io.ReadWriteCloser) bool {
	c, ok := conn.(net.Conn)
	if !ok {
		return true
	}
	_ = c.SetReadDeadline(time.Now().Add(400 * time.Millisecond))
	buf := make([]byte, 1)
	n, err := c.Read(buf)
	_ = c.SetReadDeadline(time.Time{})
	if n > 0 {
		return false
	}
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

type CheckResult struct {
	OK     bool   `json:"ok"`
	Label  string `json:"label"`
	Probe  Probe  `json:"probe"`
	Issue  *Issue `json:"issue,omitempty"`
	Remote string `json:"remote,omitempty"`
}

func CheckJSON(root, targetJSON string) string {
	var t Target
	res := CheckResult{}
	if err := json.Unmarshal([]byte(targetJSON), &t); err != nil {
		res.Issue = issue(CodeConfig, "Invalid Destination", err.Error())
	} else if rt, iss := t.Resolve(root); iss != nil {
		res.Issue = iss.with(rt)
		res.Label = rt.Label()
	} else {
		res.Label = rt.Label()
		res.Probe, res.Issue = Check(rt)
		res.OK = res.Issue == nil
	}
	b, _ := json.Marshal(res)
	return string(b)
}

func Fix(root, targetJSON, fix string) int64 {
	var t Target
	if err := json.Unmarshal([]byte(targetJSON), &t); err != nil {
		bridge.Log("Couldn’t read the destination: " + err.Error())
		return 0
	}
	rt, iss := t.Resolve(root)
	if iss != nil {
		EmitIssue(iss.with(rt))
		return 0
	}
	tr := NewTransport(rt)
	switch fix {
	case FixStartService:
		cmd := exec.Command(tr.DockerPath, tr.ComposeArgs("up", "-d", rt.Service)[1:]...)
		cmd.Dir = filepath.Dir(rt.ComposeFile)
		cmd.Env = LocalEnv()
		id, _ := runner.StartManaged(cmd, "cmd:compose up "+rt.Service, "docker compose up -d "+rt.Service, cmd.Dir, runner.ManagedOptions{})
		return id
	case FixInstallDelve:
		probe, iss := Check(rt)
		if iss != nil {
			EmitIssue(iss)
			return 0
		}
		tmp, err := os.MkdirTemp("", "golens-dlv-")
		if err != nil {
			bridge.Log(err.Error())
			return 0
		}
		plan := Plan{Target: rt, Probe: probe, Name: "delve", Project: projectName(root), LocalTmp: tmp}
		cmd := bashCommand(plan.InstallDelveScript(), tmp)
		id, _ := startManaged(cmd, "cmd:install delve "+rt.Label(), "Install Delve on "+rt.Label(), root, runner.ManagedOptions{
			OnExit: func(string) { _ = os.RemoveAll(tmp) },
		})
		if id == 0 {
			_ = os.RemoveAll(tmp)
		}
		return id
	}
	return 0
}
