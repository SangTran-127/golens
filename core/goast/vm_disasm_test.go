package goast

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVMDisassembleFunction_MockVsock2002(t *testing.T) {
	tmpDir := t.TempDir()
	goMod := "module testdisasm\n\ngo 1.22\n"
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644)
	mainSrc := "package main\n\nfunc MyFunc() int { return 42 }\nfunc main() {}\n"
	_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(mainSrc), 0644)

	slug := vmexec.WorkspaceSlug(tmpDir)
	guestRoot := "/workspaces/" + slug

	// Mock server over vsock Port 2002
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		if port != 2002 {
			return nil, fmt.Errorf("unexpected port: %d", port)
		}
		client, server := net.Pipe()
		go func() {
			defer server.Close()
			fc := vmexec.NewFrameConn(server)

			// 1. Read FrameExecInit
			hdr, payload, err := fc.ReadFrame()
			if err != nil {
				return
			}
			if hdr.Type != vmexec.FrameExecInit {
				return
			}
			var init vmexec.ExecInit
			_ = json.Unmarshal(payload, &init)

			if len(init.Argv) < 2 || init.Argv[0] != "go" {
				// Unexpected command
				_ = fc.WriteFrame(vmexec.FrameExit, 0, []byte{0, 0, 0, 1})
				return
			}

			if init.Argv[1] == "build" {
				// Assert Cwd is guest workspace
				if init.Cwd != guestRoot {
					t.Errorf("expected Cwd %s, got %s", guestRoot, init.Cwd)
				}
				// Verify env contains container cache mounts
				hasCache := false
				for _, e := range init.Env {
					if strings.HasPrefix(e, "GOCACHE=/cache/gobuild") {
						hasCache = true
					}
				}
				if !hasCache {
					t.Errorf("expected GOCACHE=/cache/gobuild in env")
				}
				// Return success for build
				exitPayload := make([]byte, 4)
				binary.BigEndian.PutUint32(exitPayload, 0)
				_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
				return
			}

			if init.Argv[1] == "tool" && len(init.Argv) >= 3 && init.Argv[2] == "objdump" {
				// Send mock objdump output with guest workspace path
				out := fmt.Sprintf("TEXT main.MyFunc(SB) %s/main.go\n  %s/main.go:10 0x1000 90 NOP\n", guestRoot, guestRoot)
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(out))
				exitPayload := make([]byte, 4)
				binary.BigEndian.PutUint32(exitPayload, 0)
				_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
				return
			}

			// Clean up rm -f command
			if init.Argv[0] == "rm" {
				exitPayload := make([]byte, 4)
				binary.BigEndian.PutUint32(exitPayload, 0)
				_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
				return
			}
		}()
		return client, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	res, err := DisassembleFunction(tmpDir, "MyFunc", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}

	if len(res.Instructions) == 0 {
		t.Fatalf("expected instructions, got 0")
	}

	// Verify path translation: source path must be host path, not guest path
	inst := res.Instructions[0]
	expectedSource := filepath.Join(tmpDir, "main.go")
	if inst.Source != expectedSource {
		t.Fatalf("expected source path translated to host %s, got %s", expectedSource, inst.Source)
	}
	if inst.Mnemonic != "NOP" {
		t.Fatalf("expected mnemonic NOP, got %s", inst.Mnemonic)
	}
}

func TestVMDisassembleFunction_Rosetta(t *testing.T) {
	tmpDir := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module testrosetta\n\ngo 1.22\n"), 0644)

	rosettaSeen := false
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			defer server.Close()
			fc := vmexec.NewFrameConn(server)
			hdr, payload, err := fc.ReadFrame()
			if err == nil && hdr.Type == vmexec.FrameExecInit {
				var init vmexec.ExecInit
				_ = json.Unmarshal(payload, &init)
				if init.Rosetta {
					rosettaSeen = true
				}
			}
			exitPayload := make([]byte, 4)
			binary.BigEndian.PutUint32(exitPayload, 0)
			_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
		}()
		return client, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	_, _ = DisassembleFunction(tmpDir, "MyFunc", "amd64")
	if !rosettaSeen {
		t.Fatalf("expected Rosetta=true in ExecInit when arch=amd64")
	}
}
