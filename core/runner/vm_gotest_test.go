package runner

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVMRunTests_PathTranslationAndEnv(t *testing.T) {
	dir := t.TempDir()
	slug := vmexec.WorkspaceSlug(dir)
	expectedGuestDir := "/workspaces/" + slug

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	serverFC := vmexec.NewFrameConn(serverConn)

	var capturedInit vmexec.ExecInit
	var initReceived = make(chan struct{})

	go func() {
		hdr, payload, err := serverFC.ReadFrame()
		if err != nil {
			return
		}
		if hdr.Type == vmexec.FrameExecInit {
			_ = json.Unmarshal(payload, &capturedInit)
			close(initReceived)
		}

		guestFilePath := expectedGuestDir + "/sample_test.go"
		// Simulate `go test -json` streaming frames
		events := []string{
			`{"Action":"run","Package":"sample","Test":"TestFail"}` + "\n",
			`{"Action":"output","Package":"sample","Test":"TestFail","Output":"    ` + guestFilePath + `:42: assertion failed\n"}` + "\n",
			`{"Action":"fail","Package":"sample","Test":"TestFail","Elapsed":0.01}` + "\n",
			`{"Action":"fail","Package":"sample","Elapsed":0.02}` + "\n",
		}

		for _, ev := range events {
			_ = serverFC.WriteFrame(vmexec.FrameStdout, 0, []byte(ev))
		}

		exitPayload := make([]byte, 4)
		exitPayload[3] = 1
		_ = serverFC.WriteFrame(vmexec.FrameExit, 0, exitPayload)
	}()

	// Intercept test events
	runID := runGoTestWithOptions(goTestRunOptions{
		dir:     dir,
		pattern: "TestFail",
		pkgs:    []string{"."},
	})

	select {
	case <-initReceived:
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for ExecInit")
	}

	if capturedInit.Cwd != expectedGuestDir {
		t.Fatalf("expected guest Cwd %q, got %q", expectedGuestDir, capturedInit.Cwd)
	}

	var hasGoCache, hasLinux, hasArm64 bool
	for _, env := range capturedInit.Env {
		if env == "GOCACHE=/cache/gobuild" {
			hasGoCache = true
		}
		if env == "GOOS=linux" {
			hasLinux = true
		}
		if env == "GOARCH=arm64" {
			hasArm64 = true
		}
	}
	if !hasGoCache || !hasLinux || !hasArm64 {
		t.Fatalf("missing expected container env: cache=%v, linux=%v, arm64=%v",
			hasGoCache, hasLinux, hasArm64)
	}

	// Verify StopTests/cleanup
	currentRunMu := &testMu
	currentRunMu.Lock()
	r := currentRun
	currentRunMu.Unlock()

	if r != nil && r.id == runID {
		select {
		case <-r.done:
		case <-time.After(3 * time.Second):
			t.Fatal("timeout waiting for test run completion")
		}
	}
}

func TestVMRunTests_RosettaAmd64(t *testing.T) {
	dir := t.TempDir()

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	serverFC := vmexec.NewFrameConn(serverConn)

	var capturedInit vmexec.ExecInit
	var initReceived = make(chan struct{})

	go func() {
		hdr, payload, err := serverFC.ReadFrame()
		if err != nil {
			return
		}
		if hdr.Type == vmexec.FrameExecInit {
			_ = json.Unmarshal(payload, &capturedInit)
			close(initReceived)
		}

		exitPayload := make([]byte, 4)
		_ = serverFC.WriteFrame(vmexec.FrameExit, 0, exitPayload)
	}()

	runID := runGoTestWithOptions(goTestRunOptions{
		dir:          dir,
		pkgs:         []string{"."},
		architecture: "amd64",
	})

	select {
	case <-initReceived:
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for ExecInit")
	}

	if !capturedInit.Rosetta {
		t.Fatalf("expected Rosetta=true for amd64 architecture")
	}

	var hasAmd64 bool
	for _, env := range capturedInit.Env {
		if env == "GOARCH=amd64" {
			hasAmd64 = true
		}
	}
	if !hasAmd64 {
		t.Fatalf("expected GOARCH=amd64 in container env")
	}

	testMu.Lock()
	r := currentRun
	testMu.Unlock()
	if r != nil && r.id == runID {
		select {
		case <-r.done:
		case <-time.After(3 * time.Second):
			t.Fatal("timeout waiting for run to complete")
		}
	}
}

func TestCreateSharedTempPath(t *testing.T) {
	dir := t.TempDir()
	hostPath, guestPath := createSharedTempPath(dir, "test-cover-*.out")
	if hostPath == "" || guestPath == "" {
		t.Fatalf("createSharedTempPath failed: host=%q, guest=%q", hostPath, guestPath)
	}
	defer os.Remove(hostPath)

	expectedPrefix := filepath.Join(dir, ".golens", "tmp")
	if !filepath.HasPrefix(hostPath, expectedPrefix) {
		t.Errorf("hostPath %q should start with %q", hostPath, expectedPrefix)
	}

	slug := vmexec.WorkspaceSlug(dir)
	expectedGuestPrefix := "/workspaces/" + slug + "/.golens/tmp/"
	if !filepath.HasPrefix(guestPath, expectedGuestPrefix) {
		t.Errorf("guestPath %q should start with %q", guestPath, expectedGuestPrefix)
	}
}
