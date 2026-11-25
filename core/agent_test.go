package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVMStartTerminal_HandshakeAndCwd(t *testing.T) {
	terminalsMu.Lock()
	terminals = make(map[string]*terminalSession)
	terminalsMu.Unlock()

	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		if port == TerminalVsockPort {
			return client, nil
		}
		return nil, fmt.Errorf("unexpected port: %d", port)
	})
	defer bridge.SetVsockConnDialer(nil)

	handshakeDone := make(chan struct{})
	go func() {
		fc := vmexec.NewFrameConn(server)

		// 1. Read FrameExecInit
		hdr, payload, err := fc.ReadFrame()
		if err != nil {
			t.Errorf("failed to read exec init: %v", err)
			return
		}
		if hdr.Type != vmexec.FrameExecInit {
			t.Errorf("expected FrameExecInit, got %v", hdr.Type)
			return
		}
		var init vmexec.ExecInit
		if err := json.Unmarshal(payload, &init); err != nil {
			t.Errorf("failed to unmarshal ExecInit: %v", err)
			return
		}
		if !init.TTY {
			t.Errorf("expected TTY=true")
		}
		if len(init.Argv) == 0 || init.Argv[0] != "/bin/bash" {
			t.Errorf("expected /bin/bash, got %v", init.Argv)
		}
		if !strings.HasPrefix(init.Cwd, "/workspaces/") {
			t.Errorf("expected guest Cwd starting with /workspaces/, got %s", init.Cwd)
		}

		// 2. Read initial FrameResize (24x80)
		hdrResize, resizePayload, err := fc.ReadFrame()
		if err != nil {
			t.Errorf("failed to read resize frame: %v", err)
			return
		}
		if hdrResize.Type != vmexec.FrameResize || len(resizePayload) < 4 {
			t.Errorf("expected FrameResize, got %v len=%d", hdrResize.Type, len(resizePayload))
			return
		}
		rows := binary.BigEndian.Uint16(resizePayload[0:2])
		cols := binary.BigEndian.Uint16(resizePayload[2:4])
		if rows != 24 || cols != 80 {
			t.Errorf("expected 24x80, got %dx%d", rows, cols)
		}

		close(handshakeDone)

		for {
			_, _, err := fc.ReadFrame()
			if err != nil {
				return
			}
		}
	}()

	err := startTerminal("term-1", "/Users/testuser/project")
	if err != nil {
		t.Fatalf("startTerminal failed: %v", err)
	}
	defer closeTerminal("term-1")

	select {
	case <-handshakeDone:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for handshake")
	}
}

func TestVMTerminal_RawByteStreamingAndResize(t *testing.T) {
	terminalsMu.Lock()
	terminals = make(map[string]*terminalSession)
	terminalsMu.Unlock()

	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return client, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	var receivedStdin bytesHolder
	var receivedResize rowsColsHolder

	serverReady := make(chan struct{})
	go func() {
		fc := vmexec.NewFrameConn(server)
		_, _, _ = fc.ReadFrame() // FrameExecInit
		_, _, _ = fc.ReadFrame() // FrameResize initial
		close(serverReady)

		for {
			hdr, payload, err := fc.ReadFrame()
			if err != nil {
				return
			}
			switch hdr.Type {
			case vmexec.FrameStdin:
				receivedStdin.set(payload)
				// Echo output back to client
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("echo: "+string(payload)))
			case vmexec.FrameResize:
				if len(payload) >= 4 {
					r := binary.BigEndian.Uint16(payload[0:2])
					c := binary.BigEndian.Uint16(payload[2:4])
					receivedResize.set(int(r), int(c))
				}
			}
		}
	}()

	err := startTerminal("term-stream", "/Users/testuser/project")
	if err != nil {
		t.Fatalf("startTerminal failed: %v", err)
	}
	defer closeTerminal("term-stream")

	select {
	case <-serverReady:
	case <-time.After(2 * time.Second):
		t.Fatalf("server not ready")
	}

	// Test writeTerminalBytes
	inputStr := "uname -a\n"
	writeTerminalBytes("term-stream", []byte(inputStr))

	// Check stdin was delivered immediately without buffering
	time.Sleep(100 * time.Millisecond)
	if string(receivedStdin.get()) != inputStr {
		t.Fatalf("expected stdin %q, got %q", inputStr, string(receivedStdin.get()))
	}

	// Test resizeTerminalInternal (8-byte binary framing)
	resizeTerminalInternal("term-stream", 45, 132)
	time.Sleep(100 * time.Millisecond)
	rows, cols := receivedResize.get()
	if rows != 45 || cols != 132 {
		t.Fatalf("expected resize 45x132, got %dx%d", rows, cols)
	}
}

func TestVMTerminal_SessionCap(t *testing.T) {
	terminalsMu.Lock()
	terminals = make(map[string]*terminalSession)
	for i := 0; i < maxTerminals; i++ {
		terminals[fmt.Sprintf("term-cap-%d", i)] = &terminalSession{}
	}
	terminalsMu.Unlock()
	defer func() {
		terminalsMu.Lock()
		terminals = make(map[string]*terminalSession)
		terminalsMu.Unlock()
	}()

	err := startTerminal("term-cap-exceed", "/Users/testuser/project")
	if err == nil || !strings.Contains(err.Error(), "at most 8 terminal sessions") {
		t.Fatalf("expected session cap error, got: %v", err)
	}
}

func TestHostTerminal_PTYWriteResizeAndClose(t *testing.T) {
	terminalsMu.Lock()
	terminals = make(map[string]*terminalSession)
	terminalsMu.Unlock()

	prevMode := bridge.ExecutionMode()
	bridge.SetExecutionMode("host")
	defer bridge.SetExecutionMode(prevMode)

	dir := t.TempDir()
	if err := startTerminal("host-term-1", dir); err != nil {
		t.Fatalf("startTerminal in host mode failed: %v", err)
	}
	defer closeTerminal("host-term-1")

	resizeTerminalInternal("host-term-1", 40, 120)
	writeTerminalBytes("host-term-1", []byte("echo golens_pty_ok\n"))
	time.Sleep(150 * time.Millisecond)

	terminalsMu.Lock()
	s := terminals["host-term-1"]
	terminalsMu.Unlock()
	if s == nil || s.ptyMaster == nil || s.hostCmd == nil {
		t.Fatalf("expected active host PTY session, got %+v", s)
	}

	closeTerminal("host-term-1")
	if terminalCount() != 0 {
		t.Fatalf("expected 0 open terminals after closeTerminal, got %d", terminalCount())
	}
}

type bytesHolder struct {
	mu   sync.Mutex
	data []byte
}

func (h *bytesHolder) set(b []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.data = append(h.data, b...)
}

func (h *bytesHolder) get() []byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.data
}

type rowsColsHolder struct {
	mu   sync.Mutex
	rows int
	cols int
}

func (h *rowsColsHolder) set(r, c int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.rows = r
	h.cols = c
}

func (h *rowsColsHolder) get() (int, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rows, h.cols
}

func terminalCount() int {
	terminalsMu.Lock()
	defer terminalsMu.Unlock()
	return len(terminals)
}
