package fsutil

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestGitVMEnv(t *testing.T) {
	env := GitVMEnv(false)
	lookup := make(map[string]string)
	for _, kv := range env {
		parts := strings.SplitN(kv, "=", 2)
		if len(parts) == 2 {
			lookup[parts[0]] = parts[1]
		}
	}

	if lookup["GIT_CONFIG_NOSYSTEM"] != "1" {
		t.Errorf("expected GIT_CONFIG_NOSYSTEM=1, got %q", lookup["GIT_CONFIG_NOSYSTEM"])
	}
	if lookup["GIT_TERMINAL_PROMPT"] != "0" {
		t.Errorf("expected GIT_TERMINAL_PROMPT=0, got %q", lookup["GIT_TERMINAL_PROMPT"])
	}
	if lookup["GIT_ASKPASS"] != "" {
		t.Errorf("expected GIT_ASKPASS='', got %q", lookup["GIT_ASKPASS"])
	}
	if lookup["GIT_PAGER"] != "cat" {
		t.Errorf("expected GIT_PAGER=cat, got %q", lookup["GIT_PAGER"])
	}
}

func TestGitCommand_Structure(t *testing.T) {
	ctx := context.Background()
	ws := "/Users/test/workspace"
	dir := "/Users/test/workspace/sub"

	cmd := GitCommand(ctx, ws, dir, "status", "--porcelain")
	if cmd.Path != "git" {
		t.Errorf("expected cmd.Path == 'git', got %q", cmd.Path)
	}

	expectedDir := vmexec.HostToGuestPath(ws, dir)
	if cmd.Dir != expectedDir {
		t.Errorf("expected cmd.Dir == %q, got %q", expectedDir, cmd.Dir)
	}

	// Args should be ["git", "-c", "credential.helper=", "status", "--porcelain"]
	if len(cmd.Args) < 5 || cmd.Args[1] != "-c" || cmd.Args[2] != "credential.helper=" {
		t.Errorf("expected args to prepend -c credential.helper=, got %v", cmd.Args)
	}
}

func TestRunGit_LocalFallback(t *testing.T) {
	bridge.SetVsockConnDialer(nil)

	tmp := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Initialize a dummy git repo on host to test fallback
	initOut, exitCode, err := RunGit(ctx, tmp, tmp, nil, "init", "-q")
	if err != nil {
		t.Fatalf("git init fallback failed: %v, output: %s", err, string(initOut))
	}
	if exitCode != 0 {
		t.Fatalf("expected exitCode 0, got %d", exitCode)
	}

	statusOut, exitCode, err := RunGit(ctx, tmp, tmp, nil, "status")
	if err != nil {
		t.Fatalf("git status fallback failed: %v, output: %s", err, string(statusOut))
	}
	if exitCode != 0 {
		t.Fatalf("expected exitCode 0, got %d", exitCode)
	}
	if !strings.Contains(string(statusOut), "No commits yet") && !strings.Contains(string(statusOut), "nothing to commit") {
		t.Errorf("unexpected status output: %s", string(statusOut))
	}
}

func TestRunGit_MockVsockExecution(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		if port != 2002 {
			t.Fatalf("expected port 2002, got %d", port)
		}
		return c1, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	go func() {
		// Mock guest agent: read frame header (ExecInit)
		header := make([]byte, 8)
		if _, err := io.ReadFull(c2, header); err != nil {
			return
		}
		frameType := header[0]
		payloadLen := binary.BigEndian.Uint32(header[4:8])
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(c2, payload); err != nil {
			return
		}
		if frameType != 0x01 { // ExecInit
			return
		}

		// Drain remaining frames from client (e.g. Stdin EOF 0x02 with len 0)
		go func() {
			hdr := make([]byte, 8)
			for {
				if _, err := io.ReadFull(c2, hdr); err != nil {
					return
				}
				pLen := binary.BigEndian.Uint32(hdr[4:8])
				if pLen > 0 {
					_, _ = io.CopyN(io.Discard, c2, int64(pLen))
				}
			}
		}()

		// Send Stdout frame (0x04)
		msg := []byte("## main...origin/main\n")
		outHeader := make([]byte, vmexec.HeaderSize)
		vmexec.FrameHeader{
			Version: vmexec.ProtocolVersion,
			Type:    vmexec.FrameStdout,
			Length:  uint32(len(msg)),
		}.Encode(outHeader)
		_, _ = c2.Write(outHeader)
		_, _ = c2.Write(msg)

		// Send Exit frame (0x06)
		exitHeader := make([]byte, vmexec.HeaderSize)
		vmexec.FrameHeader{
			Version: vmexec.ProtocolVersion,
			Type:    vmexec.FrameExit,
			Length:  4,
		}.Encode(exitHeader)
		exitPayload := make([]byte, 4)
		binary.BigEndian.PutUint32(exitPayload, 0) // exit code 0
		_, _ = c2.Write(exitHeader)
		_, _ = c2.Write(exitPayload)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ws := "/Users/test/workspace"
	out, exitCode, err := RunGit(ctx, ws, ws, nil, "status", "-sb")
	if err != nil {
		t.Fatalf("RunGit failed: %v", err)
	}
	if exitCode != 0 {
		t.Errorf("expected exitCode 0, got %d", exitCode)
	}
	if string(out) != "## main...origin/main\n" {
		t.Errorf("unexpected output: %q", string(out))
	}
}

func TestRunGit_RevParseShowToplevel_PathTranslation(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return c1, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	ws := filepath.Clean(os.TempDir() + "/test-repo")
	guestRepoPath := vmexec.HostToGuestPath(ws, ws) + "\n"

	go func() {
		header := make([]byte, 8)
		if _, err := io.ReadFull(c2, header); err != nil {
			return
		}
		pLen := binary.BigEndian.Uint32(header[4:8])
		payload := make([]byte, pLen)
		if _, err := io.ReadFull(c2, payload); err != nil {
			return
		}

		go func() {
			hdr := make([]byte, 8)
			for {
				if _, err := io.ReadFull(c2, hdr); err != nil {
					return
				}
				pl := binary.BigEndian.Uint32(hdr[4:8])
				if pl > 0 {
					_, _ = io.CopyN(io.Discard, c2, int64(pl))
				}
			}
		}()

		// Send Stdout frame with guest path
		outHeader := make([]byte, vmexec.HeaderSize)
		vmexec.FrameHeader{
			Version: vmexec.ProtocolVersion,
			Type:    vmexec.FrameStdout,
			Length:  uint32(len(guestRepoPath)),
		}.Encode(outHeader)
		_, _ = c2.Write(outHeader)
		_, _ = c2.Write([]byte(guestRepoPath))

		// Send Exit frame
		exitHeader := make([]byte, vmexec.HeaderSize)
		vmexec.FrameHeader{
			Version: vmexec.ProtocolVersion,
			Type:    vmexec.FrameExit,
			Length:  4,
		}.Encode(exitHeader)
		exitPayload := make([]byte, 4)
		binary.BigEndian.PutUint32(exitPayload, 0)
		_, _ = c2.Write(exitHeader)
		_, _ = c2.Write(exitPayload)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	out, exitCode, err := RunGit(ctx, ws, ws, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		t.Fatalf("RunGit rev-parse failed: %v", err)
	}
	if exitCode != 0 {
		t.Errorf("expected exitCode 0, got %d", exitCode)
	}

	expectedHost := ws + "\n"
	if string(out) != expectedHost {
		t.Errorf("expected translated host path %q, got %q", expectedHost, string(out))
	}
}
