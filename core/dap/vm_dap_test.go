package dap

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"

	"github.com/google/go-dap"
)

func TestVMStartDebug_VsockDAPAndSubstitutePath(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module myapp\n\ngo 1.22\n"), 0o644)
	mainGo := filepath.Join(dir, "main.go")
	_ = os.WriteFile(mainGo, []byte("package main\n\nfunc main() {}\n"), 0o644)

	slug := vmexec.WorkspaceSlug(dir)
	expectedGuestDir := "/workspaces/" + slug

	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	var dialedPort uint32
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		dialedPort = port
		return clientConn, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	serverReader := bufio.NewReader(serverConn)
	var capturedLaunchArgs map[string]any
	launchReceived := make(chan struct{})

	go func() {
		// 1. Read initialize request
		msg, err := dap.ReadProtocolMessage(serverReader)
		if err != nil {
			return
		}
		initReq, ok := msg.(*dap.InitializeRequest)
		if !ok {
			return
		}
		initResp := &dap.InitializeResponse{
			Response: dap.Response{
				ProtocolMessage: dap.ProtocolMessage{Seq: 1, Type: "response"},
				Command:         initReq.Command,
				RequestSeq:      initReq.Seq,
				Success:         true,
			},
		}
		_ = dap.WriteProtocolMessage(serverConn, initResp)

		// 2. Read launch request
		msg, err = dap.ReadProtocolMessage(serverReader)
		if err != nil {
			return
		}
		launchReq, ok := msg.(*dap.LaunchRequest)
		if !ok {
			return
		}
		_ = json.Unmarshal(launchReq.Arguments, &capturedLaunchArgs)
		close(launchReceived)

		launchResp := &dap.LaunchResponse{
			Response: dap.Response{
				ProtocolMessage: dap.ProtocolMessage{Seq: 2, Type: "response"},
				Command:         launchReq.Command,
				RequestSeq:      launchReq.Seq,
				Success:         true,
			},
		}
		_ = dap.WriteProtocolMessage(serverConn, launchResp)

		// Read until disconnect or close
		for {
			m, err := dap.ReadProtocolMessage(serverReader)
			if err != nil {
				return
			}
			if disc, ok := m.(*dap.DisconnectRequest); ok {
				discResp := &dap.DisconnectResponse{
					Response: dap.Response{
						ProtocolMessage: dap.ProtocolMessage{Seq: 3, Type: "response"},
						Command:         disc.Command,
						RequestSeq:      disc.Seq,
						Success:         true,
					},
				}
				_ = dap.WriteProtocolMessage(serverConn, discResp)
				return
			}
		}
	}()

	cfgJSON, _ := json.Marshal(RunConfig{
		WorkingDirectory: dir,
		ActiveFilePath:   mainGo,
	})

	err := StartDebug(string(cfgJSON))
	if err != nil {
		t.Fatalf("StartDebug failed: %v", err)
	}

	if dialedPort != 2345 {
		t.Fatalf("expected vsock port 2345, got %d", dialedPort)
	}

	select {
	case <-launchReceived:
	case <-time.After(3 * time.Second):
		t.Fatal("timeout waiting for LaunchRequest")
	}

	// Verify cwd is in guest workspace
	if capturedLaunchArgs["cwd"] != expectedGuestDir {
		t.Fatalf("expected guest cwd %q, got %q", expectedGuestDir, capturedLaunchArgs["cwd"])
	}

	// Verify substitutePath
	subRaw, ok := capturedLaunchArgs["substitutePath"]
	if !ok {
		t.Fatal("missing substitutePath in launch arguments")
	}
	subBytes, _ := json.Marshal(subRaw)
	var subs []SubstitutePath
	_ = json.Unmarshal(subBytes, &subs)

	var foundWorkspace, foundGoMod bool
	for _, s := range subs {
		if s.From == dir && s.To == expectedGuestDir {
			foundWorkspace = true
		}
		if s.To == "/cache/gomod" {
			foundGoMod = true
		}
	}
	if !foundWorkspace {
		t.Fatalf("expected substitutePath for workspace %q -> %q, got %+v", dir, expectedGuestDir, subs)
	}
	if !foundGoMod {
		t.Fatalf("expected substitutePath for /cache/gomod, got %+v", subs)
	}

	client := GetClient()
	if client == nil {
		t.Fatal("GetClient returned nil")
	}
	if client.cmd != nil {
		t.Fatal("expected client.cmd to be nil for Micro-VM session")
	}

	client.Stop()
	if GetClient() != nil {
		t.Fatal("expected GetClient() to be nil after Stop()")
	}
}
