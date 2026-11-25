package vmexec

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
)

type ExitError struct {
	code int
	msg  string
}

func (e *ExitError) Error() string {
	if e.msg != "" {
		return fmt.Sprintf("exit status %d: %s", e.code, e.msg)
	}
	return fmt.Sprintf("exit status %d", e.code)
}

func (e *ExitError) ExitCode() int {
	return e.code
}

type Cmd struct {
	Path                string
	Args                []string
	HostArgs            []string
	HostEnv             []string
	Env                 []string
	Dir                 string
	Stdin               io.Reader
	Stdout              io.Writer
	Stderr              io.Writer
	Port                uint32
	Rosetta             bool
	Cgroup              *CgroupLimits
	EnableTelemetry     bool
	ReadOnlyWorkspace   bool
	LoopbackOnlyNetwork bool
	OOMKilled           bool
	OnTelemetry         func(payload []byte)
	OnSignRequest       func(ctx context.Context, payload []byte) ([]byte, error)
	DialTimeout         time.Duration

	ctx      context.Context
	cancel   context.CancelFunc
	fc       *FrameConn
	exitCode int
	err      error
	started  bool
	finished bool
	mu       sync.Mutex
	doneCh   chan struct{}
	stdoutW  io.Closer
	stderrW  io.Closer
	stdinW   io.WriteCloser
}

func Command(name string, arg ...string) *Cmd {
	return CommandContext(context.Background(), name, arg...)
}

func CommandContext(ctx context.Context, name string, arg ...string) *Cmd {
	ctx, cancel := context.WithCancel(ctx)
	args := append([]string{name}, arg...)
	return &Cmd{
		Path:     name,
		Args:     args,
		Port:     DefaultPort,
		ctx:      ctx,
		cancel:   cancel,
		doneCh:   make(chan struct{}),
		exitCode: -1,
	}
}

func (c *Cmd) Start() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.started {
		return errors.New("vmexec: already started")
	}
	c.started = true

	var conn net.Conn
	var err error
	if c.DialTimeout > 0 {
		conn, err = DialWithTimeout(c.ctx, c.Port, c.DialTimeout)
	} else {
		conn, err = bridge.DialSandboxVsockWithRetry(c.ctx, c.Port, 10*time.Second)
	}
	if err != nil {
		c.cancel()
		return fmt.Errorf("vmexec dial failed: %w", err)
	}
	c.fc = NewFrameConn(conn)

	init := ExecInit{
		Argv:                c.Args,
		Env:                 c.Env,
		Cwd:                 c.Dir,
		Rosetta:             c.Rosetta,
		Cgroup:              c.Cgroup,
		EnableTelemetry:     c.EnableTelemetry,
		TelemetryIntervalMs: 500,
		ReadOnlyWorkspace:   c.ReadOnlyWorkspace,
		LoopbackOnlyNetwork: c.LoopbackOnlyNetwork,
		EnableCommitSigning: c.OnSignRequest != nil,
	}
	if err := c.fc.SendExecInit(init); err != nil {
		_ = c.fc.Close()
		c.cancel()
		return fmt.Errorf("vmexec exec_init failed: %w", err)
	}

	go c.pumpStdin()
	go c.readResponses()
	go c.watchCancellation()

	return nil
}

func (c *Cmd) pumpStdin() {
	if c.Stdin == nil {
		_ = c.fc.WriteFrame(FrameStdinClose, 0, nil)
		return
	}

	buf := make([]byte, 32*1024)
	for {
		n, err := c.Stdin.Read(buf)
		if n > 0 {
			if werr := c.fc.WriteFrame(FrameStdin, 0, buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			_ = c.fc.WriteFrame(FrameStdinClose, 0, nil)
			return
		}
	}
}

func (c *Cmd) readResponses() {
	defer func() {
		if c.stdoutW != nil {
			_ = c.stdoutW.Close()
		}
		if c.stderrW != nil {
			_ = c.stderrW.Close()
		}
		close(c.doneCh)
	}()

	for {
		header, payload, err := c.fc.ReadFrame()
		if err != nil {
			c.mu.Lock()
			if !c.finished && c.err == nil {
				c.err = err
			}
			c.mu.Unlock()
			return
		}

		switch header.Type {
		case FrameStdout:
			if c.Stdout != nil && len(payload) > 0 {
				_, _ = c.Stdout.Write(payload)
			}
		case FrameStderr:
			if c.Stderr != nil && len(payload) > 0 {
				_, _ = c.Stderr.Write(payload)
			}
		case FrameKernelTelemetry:
			if c.OnTelemetry != nil && len(payload) > 0 {
				c.OnTelemetry(payload)
			}
		case FrameSignRequest:
			if c.OnSignRequest == nil {
				_ = c.fc.WriteFrame(FrameSignResponse, FlagSignError, []byte("signing not enabled for this command"))
				continue
			}
			if len(payload) > MaxSignPayloadSize {
				_ = c.fc.WriteFrame(FrameSignResponse, FlagSignError, []byte("signing payload exceeds 1 MB limit"))
				continue
			}
			sig, signErr := c.OnSignRequest(c.ctx, payload)
			if signErr != nil {
				_ = c.fc.WriteFrame(FrameSignResponse, FlagSignError, []byte(signErr.Error()))
			} else {
				_ = c.fc.WriteFrame(FrameSignResponse, 0, sig)
			}
		case FrameExit:
			c.mu.Lock()
			c.finished = true
			if header.Flags&FlagOOMKilled != 0 {
				c.OOMKilled = true
			}
			if len(payload) >= 4 {
				c.exitCode = int(int32(binary.BigEndian.Uint32(payload[:4])))
				msg := ""
				if len(payload) > 4 {
					msg = string(payload[4:])
					c.err = &ExitError{code: c.exitCode, msg: msg}
				} else if c.exitCode != 0 {
					c.err = &ExitError{code: c.exitCode}
				}
				if c.exitCode == 137 && (strings.Contains(msg, "OOM") || strings.Contains(msg, "oom_kill")) {
					c.OOMKilled = true
				}
			}
			c.mu.Unlock()
			return
		case FrameError:
			c.mu.Lock()
			c.finished = true
			c.err = fmt.Errorf("guest execution error: %s", string(payload))
			c.mu.Unlock()
			return
		}
	}
}

func (c *Cmd) IsOOMKilled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.OOMKilled
}

func (c *Cmd) watchCancellation() {
	select {
	case <-c.doneCh:
		return
	default:
	}

	select {
	case <-c.doneCh:
		return
	case <-c.ctx.Done():
		select {
		case <-c.doneCh:
			return
		default:
		}

		var sigBuf [4]byte
		binary.BigEndian.PutUint32(sigBuf[:], 15)
		_ = c.fc.WriteFrame(FrameSignal, 0, sigBuf[:])

		select {
		case <-c.doneCh:
			return
		case <-time.After(500 * time.Millisecond):
			select {
			case <-c.doneCh:
				return
			default:
			}

			binary.BigEndian.PutUint32(sigBuf[:], 9)
			_ = c.fc.WriteFrame(FrameSignal, 0, sigBuf[:])

			select {
			case <-c.doneCh:
				return
			case <-time.After(500 * time.Millisecond):
				_ = c.fc.Close()
			}
		}
	}
}

func (c *Cmd) Wait() error {
	<-c.doneCh
	_ = c.fc.Close()
	c.cancel()

	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

func (c *Cmd) Run() error {
	if err := c.Start(); err != nil {
		return err
	}
	return c.Wait()
}

func (c *Cmd) Output() ([]byte, error) {
	var stdout bytes.Buffer
	c.Stdout = &stdout
	err := c.Run()
	return stdout.Bytes(), err
}

func (c *Cmd) CombinedOutput() ([]byte, error) {
	var buf bytes.Buffer
	c.Stdout = &buf
	c.Stderr = &buf
	err := c.Run()
	return buf.Bytes(), err
}

func (c *Cmd) StdoutPipe() (io.ReadCloser, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.started {
		return nil, errors.New("vmexec: StdoutPipe after process started")
	}
	if c.Stdout != nil {
		return nil, errors.New("vmexec: Stdout already set")
	}
	pr, pw := io.Pipe()
	c.Stdout = pw
	c.stdoutW = pw
	return pr, nil
}

func (c *Cmd) StderrPipe() (io.ReadCloser, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.started {
		return nil, errors.New("vmexec: StderrPipe after process started")
	}
	if c.Stderr != nil {
		return nil, errors.New("vmexec: Stderr already set")
	}
	pr, pw := io.Pipe()
	c.Stderr = pw
	c.stderrW = pw
	return pr, nil
}

func (c *Cmd) StdinPipe() (io.WriteCloser, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.started {
		return nil, errors.New("vmexec: StdinPipe after process started")
	}
	if c.Stdin != nil {
		return nil, errors.New("vmexec: Stdin already set")
	}
	pr, pw := io.Pipe()
	c.Stdin = pr
	c.stdinW = pw
	return pw, nil
}

func (c *Cmd) Cancel() {
	if c.cancel != nil {
		c.cancel()
	}
}
