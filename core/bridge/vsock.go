package bridge

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

var (
	ErrVMNotRunning      = errors.New("linux micro-vm is not running")
	ErrDialerUnset       = errors.New("sandbox vsock dialer is not set")
	ErrConnectionTimeout = errors.New("vsock connection timed out")
)

type VsockDialerFunc func(port uint32) (int, error)

var (
	vsockMu         sync.RWMutex
	vsockDialer     VsockDialerFunc
	vsockConnDialer func(ctx context.Context, port uint32) (net.Conn, error)
	execMode        string
)

func init() {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("GOLENS_EXECUTION_MODE"))) {
	case "host":
		execMode = "host"
	case "vm":
		execMode = "vm"
	case "auto":
		execMode = "auto"
	}
}

func SetExecutionMode(mode string) {
	m := strings.ToLower(strings.TrimSpace(mode))
	switch m {
	case "host", "vm", "auto", "":
	default:
		return
	}
	vsockMu.Lock()
	execMode = m
	vsockMu.Unlock()
}

func ExecutionMode() string {
	vsockMu.RLock()
	defer vsockMu.RUnlock()
	return execMode
}

func IsHostMode() bool {
	return ExecutionMode() == "host"
}

func CanFallbackToHost(err error) bool {
	if IsHostMode() {
		return true
	}
	return !IsSandboxed() && (errors.Is(err, ErrDialerUnset) || errors.Is(err, ErrVMNotRunning))
}

func SetVsockDialer(fn VsockDialerFunc) {
	vsockMu.Lock()
	defer vsockMu.Unlock()
	vsockDialer = fn
}

func SetVsockConnDialer(fn func(ctx context.Context, port uint32) (net.Conn, error)) {
	vsockMu.Lock()
	defer vsockMu.Unlock()
	vsockConnDialer = fn
}

func GetVsockDialer() VsockDialerFunc {
	vsockMu.RLock()
	defer vsockMu.RUnlock()
	return vsockDialer
}

func DialSandboxVsock(ctx context.Context, port uint32) (net.Conn, error) {
	vsockMu.RLock()
	connDialer := vsockConnDialer
	dialer := vsockDialer
	mode := execMode
	vsockMu.RUnlock()

	if connDialer != nil {
		return connDialer(ctx, port)
	}

	if mode == "host" {
		return nil, ErrVMNotRunning
	}

	if dialer == nil {
		return nil, ErrDialerUnset
	}

	fd, err := dialer(port)
	if err != nil {
		return nil, err
	}

	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock-%d", port))
	if f == nil {
		return nil, fmt.Errorf("failed to create os.File from fd %d", fd)
	}

	conn, err := net.FileConn(f)
	if err == nil {
		_ = f.Close()
		return conn, nil
	}

	return newFileConn(f, port), nil
}

func DialSandboxVsockWithRetry(ctx context.Context, port uint32, timeout time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(timeout)
	delay := 50 * time.Millisecond
	const maxDelay = 1 * time.Second

	for {
		conn, err := DialSandboxVsock(ctx, port)
		if err == nil {
			return conn, nil
		}

		if errors.Is(err, ErrVMNotRunning) || errors.Is(err, ErrDialerUnset) {
			return nil, err
		}

		if ctx.Err() != nil {
			return nil, ctx.Err()
		}

		if time.Now().After(deadline) {
			return nil, fmt.Errorf("%w: port %d (%v)", ErrConnectionTimeout, port, err)
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}

		delay = delay * 3 / 2
		if delay > maxDelay {
			delay = maxDelay
		}
	}
}

type vsockAddr struct {
	port uint32
}

func (a vsockAddr) Network() string { return "vsock" }
func (a vsockAddr) String() string  { return fmt.Sprintf("vsock:%d", a.port) }

type fileConn struct {
	f    *os.File
	port uint32
}

func newFileConn(f *os.File, port uint32) net.Conn {
	return &fileConn{f: f, port: port}
}

func (c *fileConn) Read(b []byte) (n int, err error) {
	return c.f.Read(b)
}

func (c *fileConn) Write(b []byte) (n int, err error) {
	return c.f.Write(b)
}

func (c *fileConn) Close() error {
	return c.f.Close()
}

func (c *fileConn) LocalAddr() net.Addr {
	return vsockAddr{port: 0}
}

func (c *fileConn) RemoteAddr() net.Addr {
	return vsockAddr{port: c.port}
}

func (c *fileConn) SetDeadline(t time.Time) error {
	return c.f.SetDeadline(t)
}

func (c *fileConn) SetReadDeadline(t time.Time) error {
	return c.f.SetReadDeadline(t)
}

func (c *fileConn) SetWriteDeadline(t time.Time) error {
	return c.f.SetWriteDeadline(t)
}

func IsSandboxed() bool {
	if os.Getenv("APP_SANDBOX_CONTAINER_ID") != "" {
		return true
	}
	if strings.Contains(os.Getenv("HOME"), "/Library/Containers/") {
		return true
	}
	return false
}
