package database

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type SSH struct {
	Destination string `json:"destination"`
	Port        int    `json:"port"`
}

type TunnelInfo struct {
	DataSourceID string `json:"dataSourceId"`
	PID          int    `json:"pid"`
	LocalPort    int    `json:"localPort"`
	Destination  string `json:"destination"`
}

var (
	sshPath            = "/usr/bin/ssh"
	tunnelStartTimeout = 20 * time.Second
	tunnelStopTimeout  = 2 * time.Second
	sshDestinationRe   = regexp.MustCompile(`^([A-Za-z0-9._-]+@)?[A-Za-z0-9._:\[\]-]+$`)
)

const tunnelAttempts = 3

const tunnelScript = `exec 3<&0
"$0" "$@" </dev/null >/dev/null 3<&- &
p=$!
echo "$p"
( read -r _ <&3; kill "$p" 2>/dev/null ) &
w=$!
wait "$p"
s=$?
kill "$w" 2>/dev/null
exit "$s"`

func validSSHDestination(dest string) bool {
	return !strings.HasPrefix(dest, "-") && sshDestinationRe.MatchString(dest)
}

func validateSSH(d Definition, add func(id, field, msg string)) {
	dest := strings.TrimSpace(d.SSH.Destination)
	if dest == "" {
		if d.SSH.Port != 0 {
			add(d.ID, "ssh.destination", "Enter the SSH destination, such as user@bastion or a Host alias from ~/.ssh/config.")
		}
		return
	}
	if d.Engine == EngineSQLite {
		add(d.ID, "ssh.destination", "A SQLite database is a file on this Mac, so it doesn’t use an SSH tunnel.")
		return
	}
	if !validSSHDestination(dest) {
		add(d.ID, "ssh.destination", fmt.Sprintf("“%s” isn’t a valid SSH destination. Use user@host or a Host alias from ~/.ssh/config.", dest))
	}
	if d.SSH.Port < 0 || d.SSH.Port > 65535 {
		add(d.ID, "ssh.port", "Enter an SSH port between 1 and 65535, or leave it empty to use the port from ~/.ssh/config.")
	}
}

func usesTunnel(d Definition) bool {
	return d.Engine != EngineSQLite && strings.TrimSpace(d.SSH.Destination) != ""
}

type sshError struct{ message string }

func (e *sshError) Error() string { return e.message }

type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	b.buf = append(b.buf, p...)
	if len(b.buf) > 4096 {
		b.buf = b.buf[len(b.buf)-4096:]
	}
	b.mu.Unlock()
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

type tunnel struct {
	key         string
	dsID        string
	destination string
	refs        int
	ready       chan struct{}
	startErr    error
	port        int
	pid         int
	cmd         *exec.Cmd
	stdin       io.WriteCloser
	done        chan struct{}
	stopOnce    sync.Once
}

func (t *tunnel) alive() bool {
	select {
	case <-t.ready:
	default:
		return true
	}
	if t.startErr != nil || t.done == nil {
		return false
	}
	select {
	case <-t.done:
		return false
	default:
		return true
	}
}

func (t *tunnel) stop() {
	t.stopOnce.Do(func() {
		if t.cmd == nil || t.cmd.Process == nil {
			return
		}
		if t.stdin != nil {
			_ = t.stdin.Close()
		}
		select {
		case <-t.done:
			return
		case <-time.After(tunnelStopTimeout):
		}
		if t.pid > 0 {
			_ = syscall.Kill(t.pid, syscall.SIGKILL)
		}
		_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
		select {
		case <-t.done:
		case <-time.After(tunnelStopTimeout):
		}
	})
}

type tunnelRegistry struct {
	mu    sync.Mutex
	byKey map[string]*tunnel
}

var tunnels = &tunnelRegistry{byKey: map[string]*tunnel{}}

func tunnelKey(d Definition) string {
	return strings.Join([]string{d.ID, d.SSH.Destination, strconv.Itoa(d.SSH.Port), d.Host, strconv.Itoa(d.Port)}, "|")
}

func (r *tunnelRegistry) acquire(ctx context.Context, d Definition) (*tunnel, error) {
	key := tunnelKey(d)
	r.mu.Lock()
	t := r.byKey[key]
	if t == nil || !t.alive() {
		t = &tunnel{key: key, dsID: d.ID, destination: d.SSH.Destination, ready: make(chan struct{})}
		r.byKey[key] = t
		t.refs = 1
		r.mu.Unlock()
		t.startErr = startTunnel(ctx, t, d)
		close(t.ready)
		if t.startErr != nil {
			r.release(t)
			return nil, t.startErr
		}
		return t, nil
	}
	t.refs++
	r.mu.Unlock()
	select {
	case <-t.ready:
	case <-ctx.Done():
		r.release(t)
		return nil, ctx.Err()
	}
	if t.startErr != nil {
		r.release(t)
		return nil, t.startErr
	}
	return t, nil
}

func (r *tunnelRegistry) release(t *tunnel) {
	r.mu.Lock()
	t.refs--
	last := t.refs <= 0
	if last && r.byKey[t.key] == t {
		delete(r.byKey, t.key)
	}
	r.mu.Unlock()
	if last {
		t.stop()
	}
}

func (r *tunnelRegistry) stopWhere(match func(*tunnel) bool) {
	r.mu.Lock()
	var stopping []*tunnel
	for k, t := range r.byKey {
		if match(t) {
			stopping = append(stopping, t)
			delete(r.byKey, k)
		}
	}
	r.mu.Unlock()
	for _, t := range stopping {
		<-t.ready
		t.stop()
	}
}

func (r *tunnelRegistry) stopDataSource(id string) {
	r.stopWhere(func(t *tunnel) bool { return t.dsID == id })
}

func StopAllTunnels() {
	tunnels.stopWhere(func(*tunnel) bool { return true })
}

func (r *tunnelRegistry) info() []TunnelInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []TunnelInfo{}
	for _, t := range r.byKey {
		select {
		case <-t.ready:
		default:
			continue
		}
		if t.alive() && t.pid > 0 {
			out = append(out, TunnelInfo{DataSourceID: t.dsID, PID: t.pid, LocalPort: t.port, Destination: t.destination})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DataSourceID < out[j].DataSourceID })
	return out
}

func freeLocalPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	return port, l.Close()
}

func forwardSpec(port int, host string, hostPort int) string {
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return fmt.Sprintf("127.0.0.1:%d:%s:%d", port, host, hostPort)
}

func sshArgs(d Definition, port int) []string {
	args := []string{"-N", "-L", forwardSpec(port, d.Host, d.Port),
		"-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30"}
	if d.SSH.Port > 0 {
		args = append(args, "-p", strconv.Itoa(d.SSH.Port))
	}
	return append(args, d.SSH.Destination)
}

func forwardFailed(stderr string) bool {
	s := strings.ToLower(stderr)
	return strings.Contains(s, "address already in use") || strings.Contains(s, "cannot listen to port") || strings.Contains(s, "could not request local forwarding")
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

func sshFailure(dest, stderr string) error {
	s := strings.ToLower(stderr)
	switch {
	case strings.Contains(s, "host key verification failed"), strings.Contains(s, "no ecdsa host key is known"), strings.Contains(s, "host key for") && strings.Contains(s, "has changed"):
		return &sshError{fmt.Sprintf("SSH could not verify the host key of %s. Connect once with “ssh %s” in Terminal to accept the key, then try again.", dest, dest)}
	case strings.Contains(s, "permission denied"):
		return &sshError{fmt.Sprintf("SSH could not sign in to %s with your keys or SSH agent. GoLens doesn’t support SSH passwords; add a key to ssh-agent or ~/.ssh/config, then try again.", dest)}
	case strings.Contains(s, "could not resolve hostname"):
		return &sshError{fmt.Sprintf("SSH could not find the host %s. Check the destination or its Host entry in ~/.ssh/config.", dest)}
	case strings.Contains(s, "connection refused"), strings.Contains(s, "operation timed out"), strings.Contains(s, "connection timed out"), strings.Contains(s, "no route to host"):
		return &sshError{fmt.Sprintf("SSH could not reach %s: %s", dest, lastLine(stderr))}
	case strings.TrimSpace(stderr) == "":
		return &sshError{fmt.Sprintf("SSH to %s stopped before the tunnel opened.", dest)}
	}
	return &sshError{fmt.Sprintf("SSH to %s failed: %s", dest, lastLine(stderr))}
}

func startTunnel(ctx context.Context, t *tunnel, d Definition) error {
	ctx, cancel := context.WithTimeout(ctx, tunnelStartTimeout)
	defer cancel()
	for attempt := 1; ; attempt++ {
		port, err := freeLocalPort()
		if err != nil {
			return &sshError{"GoLens could not find a free local port for the SSH tunnel."}
		}
		retry, err := launchTunnel(ctx, t, d, port)
		if err == nil {
			return nil
		}
		if !retry || attempt >= tunnelAttempts {
			return err
		}
	}
}

func launchTunnel(ctx context.Context, t *tunnel, d Definition, port int) (bool, error) {
	dest := d.SSH.Destination
	cmd := exec.Command("/bin/sh", append([]string{"-c", tunnelScript, sshPath}, sshArgs(d, port)...)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stderr := &tailBuffer{}
	cmd.Stderr = stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return false, &sshError{"GoLens could not start ssh: " + err.Error()}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return false, &sshError{"GoLens could not start ssh: " + err.Error()}
	}
	if err := cmd.Start(); err != nil {
		return false, &sshError{"GoLens could not start ssh: " + err.Error()}
	}
	done := make(chan struct{})
	pidLine := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		pidLine <- strings.TrimSpace(line)
		_, _ = io.Copy(io.Discard, stdout)
	}()
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	attempt := &tunnel{key: t.key, cmd: cmd, stdin: stdin, done: done, ready: t.ready}
	fail := func(err error) (bool, error) {
		attempt.stop()
		return false, err
	}
	select {
	case line := <-pidLine:
		attempt.pid, _ = strconv.Atoi(line)
	case <-ctx.Done():
		return fail(&sshError{fmt.Sprintf("SSH to %s didn’t start in time.", dest)})
	}
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-done:
			msg := stderr.String()
			if forwardFailed(msg) {
				return true, &sshError{fmt.Sprintf("SSH to %s could not open the local port for the tunnel after %d tries.", dest, tunnelAttempts)}
			}
			return false, sshFailure(dest, msg)
		case <-ctx.Done():
			return fail(&sshError{fmt.Sprintf("SSH to %s didn’t open the tunnel within %d seconds. Check that “ssh %s” works in Terminal.", dest, int(tunnelStartTimeout.Seconds()), dest)})
		case <-tick.C:
		}
		if attempt.pid <= 0 {
			continue
		}
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			continue
		}
		_ = c.Close()
		t.cmd, t.stdin, t.done, t.pid, t.port = cmd, stdin, done, attempt.pid, port
		return false, nil
	}
}

type tunnelHold struct {
	once sync.Once
	t    *tunnel
}

func (h *tunnelHold) holdTunnel(t *tunnel) { h.t = t }

func (h *tunnelHold) releaseTunnel() {
	h.once.Do(func() {
		if h.t != nil {
			tunnels.release(h.t)
		}
	})
}

type tunnelHolder interface{ holdTunnel(*tunnel) }
