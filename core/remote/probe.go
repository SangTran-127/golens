package remote

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golens/core/bridge"
	"golens/core/docker"
	"golens/core/vmexec"
)

type Probe struct {
	Machine   string `json:"machine"`
	GOARCH    string `json:"goarch"`
	GOARM     string `json:"goarm,omitempty"`
	Home      string `json:"home"`
	Base      string `json:"base"`
	Go        string `json:"go,omitempty"`
	GoVersion string `json:"goVersion,omitempty"`
	Dlv       string `json:"dlv,omitempty"`
	Tar       string `json:"tar,omitempty"`
	Pwd       string `json:"pwd,omitempty"`
}

const probeMarker = "golens-probe"

func remotePathPrefix() string {
	return `PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:/usr/local/bin"; export PATH; `
}

func baseExpr(t Target) string {
	if t.Kind == KindSSH {
		return `"$HOME/.cache/golens"`
	}
	return composeBase
}

func ProbeScript(t Target) string {
	return remotePathPrefix() + "B=" + baseExpr(t) + "; " +
		`echo ` + probeMarker + `; ` +
		`echo "machine=$(uname -m)"; ` +
		`echo "home=$HOME"; ` +
		`echo "base=$B"; ` +
		`g=$(command -v go 2>/dev/null); echo "go=$g"; ` +
		`[ -n "$g" ] && echo "goversion=$("$g" env GOVERSION 2>/dev/null)"; ` +
		`d=$(command -v dlv 2>/dev/null); [ -z "$d" ] && [ -x "$B/bin/dlv" ] && d="$B/bin/dlv"; echo "dlv=$d"; ` +
		`echo "tar=$(command -v tar 2>/dev/null)"; ` +
		`echo "pwd=$(pwd)"`
}

func ParseProbe(out string) (Probe, bool) {
	var p Probe
	found := false
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == probeMarker {
			found = true
			continue
		}
		if !found {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch k {
		case "machine":
			p.Machine = v
		case "home":
			p.Home = v
		case "base":
			p.Base = v
		case "go":
			p.Go = v
		case "goversion":
			p.GoVersion = v
		case "dlv":
			p.Dlv = v
		case "tar":
			p.Tar = v
		case "pwd":
			p.Pwd = v
		}
	}
	if found {
		p.GOARCH, p.GOARM, _ = GoArch(p.Machine)
	}
	return p, found
}

type cmdResult struct {
	stdout, stderr string
	err            error
	timedOut       bool
}

func runArgv(timeout time.Duration, argv []string, stdin string) cmdResult {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var timedOut atomic.Bool
	timer := time.AfterFunc(timeout, func() {
		timedOut.Store(true)
		cancel()
	})
	defer timer.Stop()

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	env := docker.Env()
	if home := vmexec.RealHomeDir(); home != "" {
		env = append(env, "HOME="+home)
	}
	cmd.Env = env
	cmd.WaitDelay = time.Second
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout bytes.Buffer
	cmd.Stdout = &stdout

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return cmdResult{err: err}
	}
	if err := cmd.Start(); err != nil {
		return cmdResult{err: err}
	}

	var (
		stderrMu     sync.Mutex
		stderrBuf    bytes.Buffer
		emittedTouch bool
	)
	defer func() {
		stderrMu.Lock()
		wasEmitted := emittedTouch
		emittedTouch = false
		stderrMu.Unlock()
		if wasEmitted && bridge.HasStatus() {
			bridge.Status("remoteTouchSecurityKey", "done")
		}
	}()

	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		tmp := make([]byte, 512)
		for {
			n, rerr := stderrPipe.Read(tmp)
			if n > 0 {
				stderrMu.Lock()
				stderrBuf.Write(tmp[:n])
				current := stderrBuf.String()
				if strings.Contains(current, "Confirm user presence") && !emittedTouch {
					emittedTouch = true
					timer.Reset(25 * time.Second)
					if bridge.HasStatus() {
						bridge.Status("remoteTouchSecurityKey", "waiting")
					}
				}
				stderrMu.Unlock()
			}
			if rerr != nil {
				return
			}
		}
	}()

	waitErr := cmd.Wait()
	<-stderrDone

	stderrMu.Lock()
	stderrStr := stderrBuf.String()
	stderrMu.Unlock()

	r := cmdResult{stdout: stdout.String(), stderr: stderrStr, err: waitErr}
	if timedOut.Load() {
		r.timedOut = true
		if strings.TrimSpace(r.stderr) == "" {
			r.stderr = "timed out"
		}
	}
	return r
}

var probeTimeout = 25 * time.Second

func Check(t Target) (Probe, *Issue) {
	tr := NewTransport(t)
	switch t.Kind {
	case KindCompose:
		if docker.LookPath("docker") == "" {
			i := issue(CodeDockerMissing, "Docker Isn’t Installed", "Running on a Compose service needs the docker command, and it wasn’t found. Install OrbStack, Docker Desktop or Colima, then try again.")
			i.Fix, i.FixTitle = FixRetry, "Try Again"
			return Probe{}, i.with(t)
		}
		ps := runArgv(probeTimeout, tr.ComposeArgs("ps", "--status", "running", "--services"), "")
		if ps.err != nil {
			return Probe{}, classifyCompose(t, ps.stderr)
		}
		running := false
		for _, s := range strings.Fields(ps.stdout) {
			if s == t.Service {
				running = true
			}
		}
		if !running {
			cfg := runArgv(probeTimeout, tr.ComposeArgs("config", "--services"), "")
			if cfg.err == nil && !containsField(cfg.stdout, t.Service) {
				return Probe{}, classifyCompose(t, "no such service: "+t.Service)
			}
			return Probe{}, classifyCompose(t, "service \""+t.Service+"\" is not running")
		}
	case KindSSH:
		if err := os.MkdirAll(tr.ControlDir, 0o700); err != nil {
			return Probe{}, issue(CodeFailed, "Couldn’t Prepare SSH", err.Error()).with(t)
		}
	}
	r := runArgv(probeTimeout, tr.Shell(ProbeScript(t)), "")
	p, ok := ParseProbe(r.stdout)
	if r.err != nil || !ok {
		if t.Kind == KindSSH {
			return p, classifySSH(t, r.stderr)
		}
		return p, classifyCompose(t, r.stderr)
	}
	if p.GOARCH == "" {
		return p, archIssue(t, p.Machine)
	}
	if p.Tar == "" {
		return p, noTarIssue(t)
	}
	return p, nil
}

func containsField(s, want string) bool {
	for _, f := range strings.Fields(s) {
		if f == want {
			return true
		}
	}
	return false
}
