package vmexec

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
)

func TestCmdPipes(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	cmd := Command("echo", "test")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("StdoutPipe failed: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatalf("StderrPipe failed: %v", err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("StdinPipe failed: %v", err)
	}

	// Double pipe should error
	if _, err := cmd.StdoutPipe(); err == nil {
		t.Fatalf("expected error on duplicate StdoutPipe")
	}

	serverFC := NewFrameConn(serverConn)

	var serverWg sync.WaitGroup
	serverWg.Add(1)
	go func() {
		defer serverWg.Done()
		// 1. Read ExecInit
		_, payload, err := serverFC.ReadFrame()
		if err != nil {
			t.Errorf("read init frame failed: %v", err)
			return
		}
		var init ExecInit
		if err := json.Unmarshal(payload, &init); err != nil {
			t.Errorf("decode init failed: %v", err)
			return
		}
		if len(init.Argv) < 2 || init.Argv[0] != "echo" {
			t.Errorf("unexpected argv: %v", init.Argv)
		}

		// 2. Read Stdin from client
		hdr, stdinData, err := serverFC.ReadFrame()
		if err != nil || hdr.Type != FrameStdin {
			t.Errorf("expected FrameStdin, got %v: %v", hdr, err)
			return
		}

		// 3. Write FrameStdout and FrameStderr
		_ = serverFC.WriteFrame(FrameStdout, 0, append([]byte("out: "), stdinData...))
		_ = serverFC.WriteFrame(FrameStderr, 0, []byte("err: warning\n"))

		// 4. Send Exit
		exitPayload := make([]byte, 4)
		_ = serverFC.WriteFrame(FrameExit, 0, exitPayload)
	}()

	if err := cmd.Start(); err != nil {
		t.Fatalf("cmd.Start() failed: %v", err)
	}

	// Test after started error
	if _, err := cmd.StdoutPipe(); err == nil {
		t.Fatalf("expected error calling StdoutPipe after start")
	}

	// Write to stdin
	if _, err := stdin.Write([]byte("hello world\n")); err != nil {
		t.Fatalf("stdin.Write failed: %v", err)
	}
	_ = stdin.Close()

	// Read from stdout and stderr pipes concurrently
	var outBuf, errBuf bytes.Buffer
	var readWg sync.WaitGroup
	readWg.Add(2)

	go func() {
		defer readWg.Done()
		_, _ = io.Copy(&outBuf, stdout)
	}()

	go func() {
		defer readWg.Done()
		_, _ = io.Copy(&errBuf, stderr)
	}()

	readWg.Wait()

	if err := cmd.Wait(); err != nil {
		t.Fatalf("cmd.Wait() failed: %v", err)
	}
	serverWg.Wait()

	if !bytes.Contains(outBuf.Bytes(), []byte("out: hello world\n")) {
		t.Fatalf("unexpected stdout: %q", outBuf.String())
	}
	if !bytes.Contains(errBuf.Bytes(), []byte("err: warning\n")) {
		t.Fatalf("unexpected stderr: %q", errBuf.String())
	}
}

func TestCmdCancel(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	cmd := Command("sleep", "100")
	serverFC := NewFrameConn(serverConn)

	var serverWg sync.WaitGroup
	serverWg.Add(1)
	go func() {
		defer serverWg.Done()
		_, _, _ = serverFC.ReadFrame() // Init

		// Read frames until FrameSignal
		for {
			hdr, payload, err := serverFC.ReadFrame()
			if err != nil {
				return
			}
			if hdr.Type == FrameSignal && len(payload) >= 4 {
				// Respond with exit 143 (SIGTERM)
				exitPayload := make([]byte, 4)
				exitPayload[3] = 143
				_ = serverFC.WriteFrame(FrameExit, 0, exitPayload)
				return
			}
		}
	}()

	if err := cmd.Start(); err != nil {
		t.Fatalf("cmd.Start failed: %v", err)
	}

	time.Sleep(20 * time.Millisecond)
	cmd.Cancel()

	_ = cmd.Wait()
	serverWg.Wait()
}
