package runner

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVMRunProject(t *testing.T) {
	dir := t.TempDir()
	slug := vmexec.WorkspaceSlug(dir)
	expectedGuestDir := "/workspaces/" + slug

	var capturedInit vmexec.ExecInit
	var initReceived = make(chan struct{})

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	serverFC := vmexec.NewFrameConn(serverConn)

	go func() {
		hdr, payload, err := serverFC.ReadFrame()
		if err != nil {
			return
		}
		if hdr.Type == vmexec.FrameExecInit {
			_ = json.Unmarshal(payload, &capturedInit)
			close(initReceived)
		}

		// Stream stdout
		_ = serverFC.WriteFrame(vmexec.FrameStdout, 0, []byte("Server started on :8080\n"))

		// Exit
		exitPayload := make([]byte, 4)
		_ = serverFC.WriteFrame(vmexec.FrameExit, 0, exitPayload)
	}()

	run := RunProject(dir)
	if run == nil {
		t.Fatal("RunProject returned nil")
	}

	select {
	case <-initReceived:
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for ExecInit")
	}

	if capturedInit.Cwd != expectedGuestDir {
		t.Fatalf("expected guest cwd %q, got %q", expectedGuestDir, capturedInit.Cwd)
	}

	var hasGoCache, hasGoModCache, hasLinux, hasArm64 bool
	for _, env := range capturedInit.Env {
		if env == "GOCACHE=/cache/gobuild" {
			hasGoCache = true
		}
		if env == "GOMODCACHE=/cache/gomod" {
			hasGoModCache = true
		}
		if env == "GOOS=linux" {
			hasLinux = true
		}
		if env == "GOARCH=arm64" {
			hasArm64 = true
		}
	}

	if !hasGoCache || !hasGoModCache || !hasLinux || !hasArm64 {
		t.Fatalf("missing container env: cache=%v, mod=%v, os=%v, arch=%v",
			hasGoCache, hasGoModCache, hasLinux, hasArm64)
	}

	select {
	case <-run.done:
	case <-time.After(3 * time.Second):
		t.Fatal("timeout waiting for run to complete")
	}
}

func TestVMRunWithConfig_Rosetta(t *testing.T) {
	dir := t.TempDir()

	var capturedInit vmexec.ExecInit
	var initReceived = make(chan struct{})

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	serverFC := vmexec.NewFrameConn(serverConn)

	go func() {
		hdr, payload, err := serverFC.ReadFrame()
		if err != nil {
			return
		}
		if hdr.Type == vmexec.FrameExecInit {
			_ = json.Unmarshal(payload, &capturedInit)
			close(initReceived)
		}

		// Read frames until FrameSignal or close
		for {
			h, _, err := serverFC.ReadFrame()
			if err != nil {
				return
			}
			if h.Type == vmexec.FrameSignal {
				exitPayload := make([]byte, 4)
				exitPayload[3] = 143
				_ = serverFC.WriteFrame(vmexec.FrameExit, 0, exitPayload)
				return
			}
		}
	}()

	configJSON := `{"name":"Amd64Service","architecture":"amd64","envVars":{"FOO":"BAR"}}`
	run := RunWithConfig(dir, configJSON)
	if run == nil {
		t.Fatal("RunWithConfig returned nil")
	}

	select {
	case <-initReceived:
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for ExecInit")
	}

	if !capturedInit.Rosetta {
		t.Fatalf("expected Rosetta to be true for amd64 target")
	}

	var hasAmd64, hasCustomVar bool
	for _, env := range capturedInit.Env {
		if env == "GOARCH=amd64" {
			hasAmd64 = true
		}
		if env == "FOO=BAR" {
			hasCustomVar = true
		}
	}
	if !hasAmd64 {
		t.Fatalf("expected GOARCH=amd64 in env")
	}
	if !hasCustomVar {
		t.Fatalf("expected FOO=BAR in env")
	}

	// Verify Stop sends SIGTERM over vsock
	run.stop()
	select {
	case <-run.done:
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for stop")
	}
}
