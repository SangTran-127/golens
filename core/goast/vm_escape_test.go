package goast

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestVMAnalyzeEscape_MockVsock2002(t *testing.T) {
	tmpDir := t.TempDir()
	goMod := "module testescape\n\ngo 1.22\n"
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644)
	mainSrc := "package main\n\nfunc main() {\n\ts := \"hello\"\n\tprintln(s)\n}\n"
	mainFile := filepath.Join(tmpDir, "main.go")
	_ = os.WriteFile(mainFile, []byte(mainSrc), 0644)

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

			hdr, payload, err := fc.ReadFrame()
			if err != nil || hdr.Type != vmexec.FrameExecInit {
				return
			}
			var init vmexec.ExecInit
			_ = json.Unmarshal(payload, &init)

			if init.Cwd != guestRoot {
				t.Errorf("expected Cwd %s, got %s", guestRoot, init.Cwd)
			}

			// Mock compiler escape output with guest path
			mockOutput := fmt.Sprintf("%s/main.go:4:9: \"hello\" escapes to heap\n", guestRoot)
			_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(mockOutput))

			exitPayload := make([]byte, 4)
			binary.BigEndian.PutUint32(exitPayload, 0)
			_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
		}()
		return client, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	resJSON, err := AnalyzeEscape(tmpDir, mainFile)
	if err != nil {
		t.Fatalf("AnalyzeEscape failed: %v", err)
	}

	var res EscapeAnalysisResult
	if err := json.Unmarshal([]byte(resJSON), &res); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}

	if len(res.Items) == 0 {
		t.Fatalf("expected escape items, got 0")
	}

	item := res.Items[0]
	if item.File != mainFile {
		t.Fatalf("expected item.File translated to host path %s, got %s", mainFile, item.File)
	}
	if item.Kind != "heap" {
		t.Fatalf("expected kind heap, got %s", item.Kind)
	}
}
