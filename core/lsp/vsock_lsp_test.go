package lsp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVsockLSP_LifecycleAndRewriting(t *testing.T) {
	wsRoot := "/Users/testuser/workspaces/app"
	slug := vmexec.WorkspaceSlug(wsRoot)
	guestRoot := "/workspaces/" + slug

	clientPipe, serverPipe := net.Pipe()
	defer clientPipe.Close()
	defer serverPipe.Close()

	// Register in-memory vsock dialer for port 2001
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		if port == 2001 {
			return clientPipe, nil
		}
		return nil, fmt.Errorf("unexpected port: %d", port)
	})
	defer bridge.SetVsockConnDialer(nil)
	stubShareWaiter(t, func(context.Context, string) guestProbeResult { return guestDirVisible })

	// Mock gopls server running in background
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		reader := bufio.NewReader(serverPipe)

		// 1. Read initialize request
		body, err := readLSPFrame(reader)
		if err != nil {
			t.Errorf("mock gopls failed to read initialize: %v", err)
			return
		}

		var initReq struct {
			ID     int64          `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		if err := json.Unmarshal(body, &initReq); err != nil {
			t.Errorf("mock gopls failed to unmarshal initialize: %v", err)
			return
		}

		// Verify rootUri was rewritten to guest root
		rootURI, _ := initReq.Params["rootUri"].(string)
		expectedGuestURI := "file://" + guestRoot
		if rootURI != expectedGuestURI {
			t.Errorf("expected initialize rootUri %s, got %s", expectedGuestURI, rootURI)
			return
		}

		// Send initialize response
		initResp := map[string]any{
			"jsonrpc": "2.0",
			"id":      initReq.ID,
			"result": map[string]any{
				"capabilities": map[string]any{
					"textDocumentSync": 1,
				},
			},
		}
		respBytes, _ := json.Marshal(initResp)
		if err := writeLSPFrame(serverPipe, respBytes); err != nil {
			t.Errorf("mock gopls failed to write initialize response: %v", err)
			return
		}

		// 2. Read initialized notification
		_, err = readLSPFrame(reader)
		if err != nil {
			t.Errorf("mock gopls failed to read initialized: %v", err)
			return
		}

		// 3. Mock server responds to shutdown & exit
		for {
			body, err := readLSPFrame(reader)
			if err != nil {
				return
			}
			var req struct {
				ID     int64  `json:"id"`
				Method string `json:"method"`
			}
			_ = json.Unmarshal(body, &req)
			if req.Method == "shutdown" {
				resp := map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": nil}
				b, _ := json.Marshal(resp)
				_ = writeLSPFrame(serverPipe, b)
			} else if req.Method == "exit" {
				return
			}
		}
	}()

	srv, err := startServer(wsRoot, nil)
	if err != nil {
		t.Fatalf("startServer failed: %v", err)
	}
	defer srv.stop()

	// Verify server identifies as remote vsock server
	if !srv.isRemote {
		t.Fatalf("expected srv.isRemote to be true")
	}

	// Verify ServerPID returns virtual port PID 2001
	life.mu.Lock()
	life.srv = srv
	life.mu.Unlock()

	pid := ServerPID()
	if pid != 2001 {
		t.Fatalf("expected ServerPID() == 2001, got %d", pid)
	}

	// Verify shutdown
	srv.stop()
	select {
	case <-serverDone:
	case <-time.After(2 * time.Second):
		t.Fatalf("mock server did not exit in time")
	}
}

func TestVsockLSP_FallbackWhenDialerUnset(t *testing.T) {
	// Ensure dialer is unset
	bridge.SetVsockConnDialer(nil)
	bridge.SetVsockDialer(nil)

	// In an environment without Micro-VM running, startServer must either find local gopls or return errGoplsNotFound
	_, err := startServer("/nonexistent/path", nil)
	if err != nil && !strings.Contains(err.Error(), "gopls not found") && !strings.Contains(err.Error(), "gopls") {
		t.Fatalf("expected fallback to local server or errGoplsNotFound, got: %v", err)
	}
}

func stubShareWaiter(t *testing.T, probe func(context.Context, string) guestProbeResult) {
	t.Helper()
	old := newShareWaiter
	t.Cleanup(func() { newShareWaiter = old })
	newShareWaiter = func() shareWaiter {
		now := time.Unix(0, 0)
		return shareWaiter{
			probe:  probe,
			sleep:  func(_ context.Context, d time.Duration) bool { now = now.Add(d); return true },
			now:    func() time.Time { return now },
			budget: shareWaitBudget,
		}
	}
}

func TestVsockLSP_WorkspaceNotVisibleFailsBeforeInitialize(t *testing.T) {
	clientPipe, serverPipe := net.Pipe()
	defer serverPipe.Close()
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		if port == 2001 {
			return clientPipe, nil
		}
		return nil, fmt.Errorf("unexpected port: %d", port)
	})
	defer bridge.SetVsockConnDialer(nil)
	var probed []string
	stubShareWaiter(t, func(_ context.Context, dir string) guestProbeResult {
		probed = append(probed, dir)
		return guestDirMissing
	})

	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := serverPipe.Read(buf)
		got <- buf[:n]
	}()

	_, err := startServer("/Users/testuser/workspaces/app", nil)
	if !errors.Is(err, errWorkspaceNotVisible) {
		t.Fatalf("startServer err = %v, want errWorkspaceNotVisible", err)
	}
	if len(probed) == 0 || probed[0] != "/workspaces/"+vmexec.WorkspaceSlug("/Users/testuser/workspaces/app") {
		t.Fatalf("probed %v", probed)
	}
	select {
	case b := <-got:
		if len(b) > 0 {
			t.Fatalf("gopls received %q although the folder was missing", b)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("vsock connection to gopls was left open")
	}
}
