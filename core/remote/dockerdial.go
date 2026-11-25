package remote

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golens/core/docker"
	"golens/core/vmexec"
)

var (
	newDockerTransport = NewTransport
	dockerTransports   sync.Map
	dialExitWait       = 2 * time.Second
)

func dockerSSHTarget(host string) (Target, error) {
	u, err := url.Parse(host)
	if err != nil || u.Scheme != "ssh" || u.Hostname() == "" {
		return Target{}, fmt.Errorf("Docker host %s isn’t a valid ssh:// address.", host)
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return Target{}, fmt.Errorf("Docker host %s has a path or query, which an ssh:// Docker host can’t have.", host)
	}
	if _, ok := u.User.Password(); ok {
		return Target{}, fmt.Errorf("Docker host %s contains a password; use an SSH key instead.", host)
	}
	t := Target{Kind: KindSSH, Host: u.Hostname()}
	if name := u.User.Username(); name != "" {
		t.Host = name + "@" + t.Host
	}
	if p := u.Port(); p != "" {
		t.Port, _ = strconv.Atoi(p)
	}
	if strings.HasPrefix(t.Host, "-") || !sshHostRe.MatchString(t.Host) {
		return Target{}, fmt.Errorf("Docker host %s isn’t a valid ssh:// address.", host)
	}
	return t, nil
}

func dockerTransport(t Target) Transport {
	if tr, ok := dockerTransports.Load(t); ok {
		return tr.(Transport)
	}
	tr, _ := dockerTransports.LoadOrStore(t, newDockerTransport(t))
	return tr.(Transport)
}

type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	if over := len(b.buf) - 16<<10; over > 0 {
		b.buf = b.buf[over:]
	}
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

type dialConn struct {
	target  Target
	cmd     *exec.Cmd
	stdin   *os.File
	stdout  *os.File
	stderr  *tailBuffer
	exited  chan struct{}
	waitErr error
	closing atomic.Bool
	once    sync.Once
}

type dialAddr string

func (a dialAddr) Network() string { return "ssh" }
func (a dialAddr) String() string  { return string(a) }

func DialDockerSSH(ctx context.Context, host string) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	t, err := dockerSSHTarget(host)
	if err != nil {
		return nil, err
	}
	tr := dockerTransport(t)
	if tr.ControlDir != "" {
		_ = os.MkdirAll(tr.ControlDir, 0o700)
	}
	argv := append([]string{tr.SSHPath}, tr.SSHOptions()...)
	argv = append(argv, "-T", "--", t.Host, "docker", "system", "dial-stdio")
	inR, inW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		return nil, err
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	env := docker.Env()
	if home := vmexec.RealHomeDir(); home != "" {
		env = append(env, "HOME="+home)
	}
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = time.Second
	cmd.Stdin, cmd.Stdout = inR, outW
	c := &dialConn{target: t, cmd: cmd, stdin: inW, stdout: outR, stderr: &tailBuffer{}, exited: make(chan struct{})}
	cmd.Stderr = c.stderr
	err = cmd.Start()
	inR.Close()
	outW.Close()
	if err != nil {
		inW.Close()
		outR.Close()
		return nil, fmt.Errorf("GoLens couldn’t start ssh: %v", err)
	}
	go func() {
		c.waitErr = cmd.Wait()
		close(c.exited)
	}()
	return c, nil
}

func (c *dialConn) Read(p []byte) (int, error) {
	n, err := c.stdout.Read(p)
	if err != nil && n == 0 {
		return 0, c.failure(err)
	}
	return n, nil
}

func (c *dialConn) Write(p []byte) (int, error) {
	n, err := c.stdin.Write(p)
	if err != nil {
		return n, c.failure(err)
	}
	return n, nil
}

func (c *dialConn) failure(err error) error {
	if c.closing.Load() {
		return err
	}
	t := time.NewTimer(dialExitWait)
	defer t.Stop()
	select {
	case <-c.exited:
	case <-t.C:
		return err
	}
	var exit *exec.ExitError
	if !errors.As(c.waitErr, &exit) {
		return err
	}
	i := classifyDockerDial(c.target, c.stderr.String(), exit.ExitCode())
	return &docker.IssueError{Issue: docker.Issue{Code: i.Code, Title: i.Title, Message: i.Message, Fix: i.Fix, FixTitle: i.FixTitle, Command: i.Command}}
}

func (c *dialConn) Close() error {
	c.once.Do(func() {
		c.closing.Store(true)
		c.stdin.Close()
		c.stdout.Close()
		select {
		case <-c.exited:
			return
		default:
		}
		pid := c.cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		t := time.NewTimer(dialExitWait)
		defer t.Stop()
		select {
		case <-c.exited:
			return
		case <-t.C:
		}
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		select {
		case <-c.exited:
		case <-time.After(dialExitWait):
		}
	})
	return nil
}

func (c *dialConn) LocalAddr() net.Addr                { return dialAddr("golens") }
func (c *dialConn) RemoteAddr() net.Addr               { return dialAddr(c.target.Host) }
func (c *dialConn) SetDeadline(t time.Time) error      { return nil }
func (c *dialConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *dialConn) SetWriteDeadline(t time.Time) error { return nil }

func classifyDockerDial(t Target, stderr string, code int) *Issue {
	low := strings.ToLower(stderr)
	where := t.Label()
	var i *Issue
	switch {
	case code == 127 || strings.Contains(low, "docker: command not found") || strings.Contains(low, "docker: not found"):
		i = issue(CodeDockerMissing, "Docker Isn’t Installed on "+where, where+" has no docker command, which GoLens needs to reach its Docker engine over SSH. Install Docker on "+where+" (see docs.docker.com/engine/install), then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	case strings.Contains(low, "dial-stdio") && (strings.Contains(low, "unknown command") || strings.Contains(low, "is not a docker command")):
		i = issue(CodeDockerMissing, "Docker on "+where+" Is Too Old", "The docker command on "+where+" can’t relay its engine over SSH (it needs Docker 18.09 or later). Update Docker on "+where+", then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	case strings.Contains(low, "permission denied while trying to connect to the docker"):
		i = issue(CodeEngineDown, "No Access to Docker on "+where, "Your SSH user on "+where+" isn’t allowed to open the Docker socket. Add it to the docker group there (sudo usermod -aG docker $USER), sign in again, then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	case strings.Contains(low, "cannot connect to the docker daemon"), strings.Contains(low, "is the docker daemon running"):
		i = issue(CodeEngineDown, "Docker Engine Isn’t Running on "+where, where+" has Docker installed, but its engine isn’t running. Start it there (for example sudo systemctl start docker), then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	default:
		return classifySSH(t, stderr)
	}
	i.Detail = strings.TrimSpace(stderr)
	return i.with(t)
}
