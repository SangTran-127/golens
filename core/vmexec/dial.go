package vmexec

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"golens/core/bridge"
)

var ErrVMUnavailable = errors.New("linux micro-vm is not ready")

type TimeoutDialerFunc func(port uint32, timeout time.Duration) (int, error)

var (
	timeoutDialerMu sync.RWMutex
	timeoutDialer   TimeoutDialerFunc
	stalledDials    atomic.Int32
)

const timeoutDialerSlack = 500 * time.Millisecond

func SetTimeoutDialer(fn TimeoutDialerFunc) {
	timeoutDialerMu.Lock()
	defer timeoutDialerMu.Unlock()
	timeoutDialer = fn
}

func currentTimeoutDialer() TimeoutDialerFunc {
	timeoutDialerMu.RLock()
	defer timeoutDialerMu.RUnlock()
	return timeoutDialer
}

func StalledDials() int {
	return int(stalledDials.Load())
}

type dialResult struct {
	conn net.Conn
	err  error
}

func DialWithTimeout(ctx context.Context, port uint32, timeout time.Duration) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if stalledDials.Load() > 0 {
		return nil, fmt.Errorf("%w: an earlier connection attempt is still waiting", ErrVMUnavailable)
	}

	fn := currentTimeoutDialer()
	wait := timeout
	if fn != nil {
		wait += timeoutDialerSlack
	}

	ch := make(chan dialResult, 1)
	go func() {
		var res dialResult
		if fn != nil {
			fd, err := fn(port, timeout)
			if err != nil {
				res.err = err
			} else {
				res.conn, res.err = connFromFD(fd, port)
			}
		} else {
			res.conn, res.err = bridge.DialSandboxVsock(context.Background(), port)
		}
		ch <- res
	}()

	timer := time.NewTimer(wait)
	defer timer.Stop()

	select {
	case res := <-ch:
		if res.err != nil {
			return nil, fmt.Errorf("%w: %w", ErrVMUnavailable, res.err)
		}
		return res.conn, nil
	case <-timer.C:
		stalledDials.Add(1)
		go func() {
			res := <-ch
			if res.conn != nil {
				_ = res.conn.Close()
			}
			stalledDials.Add(-1)
		}()
		return nil, fmt.Errorf("%w: %w (port %d after %v)", ErrVMUnavailable, bridge.ErrConnectionTimeout, port, timeout)
	case <-ctx.Done():
		go func() {
			res := <-ch
			if res.conn != nil {
				_ = res.conn.Close()
			}
		}()
		return nil, ctx.Err()
	}
}

func connFromFD(fd int, port uint32) (net.Conn, error) {
	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock-%d", port))
	if f == nil {
		return nil, fmt.Errorf("invalid vsock descriptor %d", fd)
	}
	if conn, err := net.FileConn(f); err == nil {
		_ = f.Close()
		return conn, nil
	}
	return &fdConn{f: f, port: port}, nil
}

type fdAddr struct {
	port uint32
}

func (a fdAddr) Network() string { return "vsock" }
func (a fdAddr) String() string  { return fmt.Sprintf("vsock:%d", a.port) }

type fdConn struct {
	f    *os.File
	port uint32
}

func (c *fdConn) Read(b []byte) (int, error)         { return c.f.Read(b) }
func (c *fdConn) Write(b []byte) (int, error)        { return c.f.Write(b) }
func (c *fdConn) Close() error                       { return c.f.Close() }
func (c *fdConn) LocalAddr() net.Addr                { return fdAddr{} }
func (c *fdConn) RemoteAddr() net.Addr               { return fdAddr{port: c.port} }
func (c *fdConn) SetDeadline(t time.Time) error      { return c.f.SetDeadline(t) }
func (c *fdConn) SetReadDeadline(t time.Time) error  { return c.f.SetReadDeadline(t) }
func (c *fdConn) SetWriteDeadline(t time.Time) error { return c.f.SetWriteDeadline(t) }
