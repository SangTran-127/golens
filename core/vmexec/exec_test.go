package vmexec_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func setupMockVsock(t *testing.T, handler func(fc *vmexec.FrameConn)) {
	t.Helper()
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			sfc := vmexec.NewFrameConn(server)
			defer sfc.Close()
			handler(sfc)
		}()
		return client, nil
	})
	t.Cleanup(func() {
		bridge.SetVsockConnDialer(nil)
	})
}

func TestProtocol_EncodeDecode(t *testing.T) {
	header := vmexec.FrameHeader{
		Version: vmexec.ProtocolVersion,
		Type:    vmexec.FrameStdout,
		Flags:   vmexec.FlagEOF,
		Length:  1024,
	}
	var buf [vmexec.HeaderSize]byte
	header.Encode(buf[:])

	decoded, err := vmexec.DecodeHeader(buf[:])
	if err != nil {
		t.Fatalf("DecodeHeader failed: %v", err)
	}
	if decoded.Version != header.Version || decoded.Type != header.Type || decoded.Flags != header.Flags || decoded.Length != header.Length {
		t.Fatalf("Header mismatch: got %+v, want %+v", decoded, header)
	}

	// Version mismatch test
	buf[0] = 0x99
	if _, err := vmexec.DecodeHeader(buf[:]); err == nil {
		t.Fatal("expected error on version mismatch, got nil")
	}

	// Payload limit test
	buf[0] = vmexec.ProtocolVersion
	binary.BigEndian.PutUint32(buf[4:8], vmexec.MaxPayloadSize+1)
	if _, err := vmexec.DecodeHeader(buf[:]); err == nil {
		t.Fatal("expected error on payload limit exceed, got nil")
	}

	// Short header test
	if _, err := vmexec.DecodeHeader(buf[:4]); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("expected io.ErrUnexpectedEOF, got %v", err)
	}
}

func TestCommandRun_Success(t *testing.T) {
	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		// Read FrameExecInit
		h, _, err := fc.ReadFrame()
		if err != nil || h.Type != vmexec.FrameExecInit {
			return
		}
		// Write stdout
		_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("go version go1.24.1 linux/arm64\n"))
		// Write exit 0
		var exitPayload [4]byte
		binary.BigEndian.PutUint32(exitPayload[:], 0)
		_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
	})

	cmd := vmexec.Command("go", "version")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("Command.Output failed: %v", err)
	}

	expected := "go version go1.24.1 linux/arm64\n"
	if string(out) != expected {
		t.Fatalf("unexpected output: got %q, want %q", string(out), expected)
	}
}

func TestCommandRun_NonZeroExit(t *testing.T) {
	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		h, _, err := fc.ReadFrame()
		if err != nil || h.Type != vmexec.FrameExecInit {
			return
		}
		// Write stderr
		_ = fc.WriteFrame(vmexec.FrameStderr, 0, []byte("compilation error\n"))
		// Write exit 1 with error diagnostic
		exitPayload := make([]byte, 4+len("exit message"))
		binary.BigEndian.PutUint32(exitPayload[:4], 1)
		copy(exitPayload[4:], "exit message")
		_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload)
	})

	var stderrBuf bytes.Buffer
	cmd := vmexec.Command("go", "build", "./...")
	cmd.Stderr = &stderrBuf
	err := cmd.Run()
	if err == nil {
		t.Fatal("expected error on non-zero exit, got nil")
	}

	var exitErr *vmexec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected *vmexec.ExitError, got %T: %v", err, err)
	}
	if exitErr.ExitCode() != 1 {
		t.Fatalf("expected exit code 1, got %d", exitErr.ExitCode())
	}
	if !strings.Contains(stderrBuf.String(), "compilation error") {
		t.Fatalf("expected stderr output, got %q", stderrBuf.String())
	}
}

func TestCommandStdin_Streaming(t *testing.T) {
	inputData := "hello from host stdin\n"

	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		h, _, err := fc.ReadFrame()
		if err != nil || h.Type != vmexec.FrameExecInit {
			return
		}

		// Read FrameStdin
		var accumulated []byte
		for {
			fh, payload, rerr := fc.ReadFrame()
			if rerr != nil {
				return
			}
			if fh.Type == vmexec.FrameStdinClose {
				break
			}
			if fh.Type == vmexec.FrameStdin {
				accumulated = append(accumulated, payload...)
			}
		}

		// Echo back to stdout
		_ = fc.WriteFrame(vmexec.FrameStdout, 0, accumulated)
		var exitPayload [4]byte
		binary.BigEndian.PutUint32(exitPayload[:], 0)
		_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
	})

	cmd := vmexec.Command("cat")
	cmd.Stdin = strings.NewReader(inputData)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("cmd.Output failed: %v", err)
	}
	if string(out) != inputData {
		t.Fatalf("echo mismatch: got %q, want %q", string(out), inputData)
	}
}

func TestCommand_ContextCancellation(t *testing.T) {
	sigReceived := make(chan uint32, 1)

	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		h, _, err := fc.ReadFrame()
		if err != nil || h.Type != vmexec.FrameExecInit {
			return
		}

		// Read frames in a loop until FrameSignal is received (handles interleaved FrameStdinClose)
		for {
			fh, payload, err := fc.ReadFrame()
			if err != nil {
				return
			}
			if fh.Type == vmexec.FrameSignal && len(payload) >= 4 {
				sig := binary.BigEndian.Uint32(payload[:4])
				sigReceived <- sig
				break
			}
		}

		// Send exit
		var exitPayload [4]byte
		binary.BigEndian.PutUint32(exitPayload[:], 143) // 128 + 15
		_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
	})

	ctx, cancel := context.WithCancel(context.Background())
	cmd := vmexec.CommandContext(ctx, "sleep", "60")

	if err := cmd.Start(); err != nil {
		t.Fatalf("cmd.Start failed: %v", err)
	}

	// Trigger cancellation
	cancel()

	_ = cmd.Wait()

	select {
	case sig := <-sigReceived:
		if sig != 15 {
			t.Fatalf("expected signal 15 (SIGTERM), got %d", sig)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for FrameSignal")
	}
}

func TestCommand_ColdBootRetry(t *testing.T) {
	attempts := 0
	var mu sync.Mutex

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		mu.Lock()
		attempts++
		att := attempts
		mu.Unlock()

		if att <= 2 {
			return nil, errors.New("connection refused (guest initializing)")
		}

		client, server := net.Pipe()
		go func() {
			sfc := vmexec.NewFrameConn(server)
			defer sfc.Close()
			_, _, _ = sfc.ReadFrame() // Init
			var exitPayload [4]byte
			binary.BigEndian.PutUint32(exitPayload[:], 0)
			_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
		}()
		return client, nil
	})
	t.Cleanup(func() {
		bridge.SetVsockConnDialer(nil)
	})

	cmd := vmexec.Command("go", "env")
	err := cmd.Run()
	if err != nil {
		t.Fatalf("cmd.Run with retry failed: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if attempts < 3 {
		t.Fatalf("expected at least 3 dial attempts, got %d", attempts)
	}
}

func TestCommand_LargeDataStreaming(t *testing.T) {
	const totalSize = 2 * 1024 * 1024 // 2 MB
	chunk := bytes.Repeat([]byte("A"), 64*1024)

	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		_, _, _ = fc.ReadFrame() // Init

		bytesSent := 0
		for bytesSent < totalSize {
			toSend := len(chunk)
			if bytesSent+toSend > totalSize {
				toSend = totalSize - bytesSent
			}
			_ = fc.WriteFrame(vmexec.FrameStdout, 0, chunk[:toSend])
			bytesSent += toSend
		}

		var exitPayload [4]byte
		binary.BigEndian.PutUint32(exitPayload[:], 0)
		_ = fc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
	})

	cmd := vmexec.Command("cat", "bigfile")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("cmd.Output failed: %v", err)
	}
	if len(out) != totalSize {
		t.Fatalf("length mismatch: got %d bytes, want %d bytes", len(out), totalSize)
	}
}

func TestClient_PingPong(t *testing.T) {
	setupMockVsock(t, func(fc *vmexec.FrameConn) {
		h, _, err := fc.ReadFrame()
		if err == nil && h.Type == vmexec.FramePing {
			_ = fc.WriteFrame(vmexec.FramePong, 0, nil)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if err := vmexec.Ping(ctx, vmexec.DefaultPort); err != nil {
		t.Fatalf("Ping failed: %v", err)
	}
}

func BenchmarkFrameHeader_EncodeDecode(b *testing.B) {
	header := vmexec.FrameHeader{
		Version: vmexec.ProtocolVersion,
		Type:    vmexec.FrameStdout,
		Flags:   0,
		Length:  65536,
	}
	var buf [vmexec.HeaderSize]byte
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		header.Encode(buf[:])
		_, _ = vmexec.DecodeHeader(buf[:])
	}
}

func BenchmarkGVBP_FrameStream64KB(b *testing.B) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	writer := vmexec.NewFrameConn(c1)
	reader := vmexec.NewFrameConn(c2)
	payload := bytes.Repeat([]byte("A"), 64*1024)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < b.N; i++ {
			_, _, err := reader.ReadFrame()
			if err != nil {
				return
			}
		}
	}()

	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := writer.WriteFrame(vmexec.FrameStdout, 0, payload); err != nil {
			b.Fatal(err)
		}
	}
	<-done
}

