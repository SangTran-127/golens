package remote

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golens/core/docker"
)

const relaySource = `package main

import (
	"io"
	"net"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		os.Stderr.WriteString("usage: golens-relay host:port\n")
		os.Exit(2)
	}
	c, err := net.Dial("tcp", os.Args[1])
	if err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
	go func() {
		io.Copy(c, os.Stdin)
		c.(*net.TCPConn).CloseWrite()
	}()
	io.Copy(os.Stdout, c)
}
`

var relayMu sync.Mutex

func relayCacheDir(goarch, goarm string) string {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	name := "linux-" + goarch
	if goarm != "" {
		name += "v" + goarm
	}
	return filepath.Join(base, "GoLens", "relay", name)
}

func BuildRelay(goarch, goarm string) (string, error) {
	relayMu.Lock()
	defer relayMu.Unlock()
	dir := relayCacheDir(goarch, goarm)
	bin := filepath.Join(dir, relayBin)
	if st, err := os.Stat(bin); err == nil && st.Size() > 0 {
		return dir, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte(relaySource), 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module golensrelay\n\ngo 1.21\n"), 0o644); err != nil {
		return "", err
	}
	cmd := exec.Command("go", "build", "-trimpath", "-ldflags=-s -w", "-o", bin, ".")
	cmd.Dir = dir
	env := append(LocalEnv(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+goarch, "GOWORK=off", "GOFLAGS=")
	if goarm != "" {
		env = append(env, "GOARM="+goarm)
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("couldn’t build the debugger relay: %s", strings.TrimSpace(string(out)))
	}
	return dir, nil
}

func LocalEnv() []string {
	env := docker.Env()
	home, _ := os.UserHomeDir()
	extra := []string{"/usr/local/go/bin", "/opt/homebrew/bin", "/usr/local/bin"}
	if home != "" {
		extra = append(extra, filepath.Join(home, "go", "bin"))
	}
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = kv + ":" + strings.Join(extra, ":")
			return env
		}
	}
	return append(env, "PATH=/usr/bin:/bin:/usr/sbin:/sbin:"+strings.Join(extra, ":"))
}

type cmdConn struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	once   sync.Once
}

func (c *cmdConn) Read(p []byte) (int, error)  { return c.stdout.Read(p) }
func (c *cmdConn) Write(p []byte) (int, error) { return c.stdin.Write(p) }

func (c *cmdConn) Close() error {
	c.once.Do(func() {
		_ = c.stdin.Close()
		if c.cmd.Process != nil {
			_ = syscall.Kill(-c.cmd.Process.Pid, syscall.SIGTERM)
			done := make(chan struct{})
			go func() {
				_ = c.cmd.Wait()
				close(done)
			}()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				_ = syscall.Kill(-c.cmd.Process.Pid, syscall.SIGKILL)
			}
		}
	})
	return nil
}

func dialCommand(argv []string) (io.ReadWriteCloser, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = docker.Env()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &cmdConn{cmd: cmd, stdin: stdin, stdout: stdout}, nil
}
