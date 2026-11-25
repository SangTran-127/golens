package vmexec_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

// TestScenario1_ColdBootRetry verifies cold boot retry under simulated network refusal.
func TestScenario1_ColdBootRetry(t *testing.T) {
	t.Run("EventualRecovery", func(t *testing.T) {
		var attempts int32
		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			att := atomic.AddInt32(&attempts, 1)
			if att < 4 {
				return nil, errors.New("connection refused: guest kernel booting")
			}
			client, server := net.Pipe()
			go func() {
				sfc := vmexec.NewFrameConn(server)
				defer sfc.Close()
				_, _, _ = sfc.ReadFrame()
				var exitPayload [4]byte
				binary.BigEndian.PutUint32(exitPayload[:], 0)
				_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
			}()
			return client, nil
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		conn, err := bridge.DialSandboxVsockWithRetry(ctx, 2002, 3*time.Second)
		if err != nil {
			t.Fatalf("expected successful connection after retries, got error: %v", err)
		}
		_ = conn.Close()

		if finalAttempts := atomic.LoadInt32(&attempts); finalAttempts < 4 {
			t.Fatalf("expected at least 4 attempts, got %d", finalAttempts)
		}
	})

	t.Run("PermanentRefusalTimeout", func(t *testing.T) {
		var attempts int32
		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			atomic.AddInt32(&attempts, 1)
			return nil, errors.New("connection refused: port closed")
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx := context.Background()
		start := time.Now()
		conn, err := bridge.DialSandboxVsockWithRetry(ctx, 2002, 300*time.Millisecond)
		elapsed := time.Since(start)

		if conn != nil {
			_ = conn.Close()
			t.Fatal("expected nil conn on permanent refusal, got non-nil")
		}
		if err == nil {
			t.Fatal("expected error on permanent refusal, got nil")
		}
		if !errors.Is(err, bridge.ErrConnectionTimeout) {
			t.Fatalf("expected ErrConnectionTimeout, got: %v", err)
		}
		if elapsed < 250*time.Millisecond || elapsed > 800*time.Millisecond {
			t.Fatalf("expected timeout around 300ms, took %v", elapsed)
		}
	})

	t.Run("ContextCancellationDuringRetry", func(t *testing.T) {
		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			return nil, errors.New("connection refused")
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
		defer cancel()

		start := time.Now()
		conn, err := bridge.DialSandboxVsockWithRetry(ctx, 2002, 10*time.Second)
		elapsed := time.Since(start)

		if conn != nil {
			_ = conn.Close()
			t.Fatal("expected nil conn, got non-nil")
		}
		if err == nil {
			t.Fatal("expected error on canceled context, got nil")
		}
		// Notice: does the error preserve context cancellation?
		if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) && !errors.Is(err, bridge.ErrConnectionTimeout) {
			t.Fatalf("unexpected error type: %v", err)
		}
		if elapsed > 1*time.Second {
			t.Fatalf("did not abort promptly on context cancellation, took %v", elapsed)
		}
	})

	t.Run("ImmediateFailOnVMNotRunning", func(t *testing.T) {
		var attempts int32
		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			atomic.AddInt32(&attempts, 1)
			return nil, bridge.ErrVMNotRunning
		})
		defer bridge.SetVsockConnDialer(nil)

		start := time.Now()
		_, err := bridge.DialSandboxVsockWithRetry(context.Background(), 2002, 5*time.Second)
		elapsed := time.Since(start)

		if !errors.Is(err, bridge.ErrVMNotRunning) {
			t.Fatalf("expected ErrVMNotRunning, got %v", err)
		}
		if atomic.LoadInt32(&attempts) != 1 {
			t.Fatalf("expected exactly 1 attempt for fatal ErrVMNotRunning, got %d", attempts)
		}
		if elapsed > 200*time.Millisecond {
			t.Fatalf("retry was attempted despite ErrVMNotRunning: took %v", elapsed)
		}
	})
}

// TestScenario2_ContextCancellation verifies behavior when context is cancelled.
func TestScenario2_ContextCancellation(t *testing.T) {
	t.Run("RobustFrameHandlingCancellation", func(t *testing.T) {
		sigReceived := make(chan uint32, 1)
		serverDone := make(chan struct{})

		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				sfc := vmexec.NewFrameConn(server)
				defer func() {
					sfc.Close()
					close(serverDone)
				}()

				// Read FrameExecInit
				h, _, err := sfc.ReadFrame()
				if err != nil || h.Type != vmexec.FrameExecInit {
					return
				}

				// Loop reading frames (handles FrameStdinClose and FrameSignal in any order)
				for {
					fh, payload, rerr := sfc.ReadFrame()
					if rerr != nil {
						return
					}
					if fh.Type == vmexec.FrameSignal && len(payload) >= 4 {
						sig := binary.BigEndian.Uint32(payload[:4])
						select {
						case sigReceived <- sig:
						default:
						}
						// Exit with signal code
						var exitPayload [4]byte
						binary.BigEndian.PutUint32(exitPayload[:], 128+sig)
						_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
						return
					}
				}
			}()
			return client, nil
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx, cancel := context.WithCancel(context.Background())
		cmd := vmexec.CommandContext(ctx, "sleep", "100")

		if err := cmd.Start(); err != nil {
			t.Fatalf("cmd.Start failed: %v", err)
		}

		// Cancel context immediately
		cancel()

		waitErr := cmd.Wait()
		if waitErr == nil {
			t.Fatal("expected non-zero exit error on cancellation, got nil")
		}

		select {
		case sig := <-sigReceived:
			if sig != 15 {
				t.Fatalf("expected signal 15 (SIGTERM), got %d", sig)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for FrameSignal")
		}

		select {
		case <-serverDone:
		case <-time.After(2 * time.Second):
			t.Fatal("server goroutine did not terminate")
		}
	})

	t.Run("PreCanceledContext", func(t *testing.T) {
		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			return nil, errors.New("should not dial when canceled")
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel before command creation

		cmd := vmexec.CommandContext(ctx, "echo", "hello")
		err := cmd.Run()
		if err == nil {
			t.Fatal("expected error with pre-canceled context, got nil")
		}
	})

	t.Run("UnresponsiveGuestSIGKILLFallback", func(t *testing.T) {
		signals := make([]uint32, 0, 2)
		var sigMu sync.Mutex

		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				sfc := vmexec.NewFrameConn(server)
				defer sfc.Close()

				// Read Init
				_, _, _ = sfc.ReadFrame()

				// Read incoming frames until EOF or connection close
				for {
					fh, payload, rerr := sfc.ReadFrame()
					if rerr != nil {
						return
					}
					if fh.Type == vmexec.FrameSignal && len(payload) >= 4 {
						sig := binary.BigEndian.Uint32(payload[:4])
						sigMu.Lock()
						signals = append(signals, sig)
						sigMu.Unlock()
						// Deliberately ignore SIGTERM (15); wait for SIGKILL (9)
						if sig == 9 {
							var exitPayload [4]byte
							binary.BigEndian.PutUint32(exitPayload[:], 137) // 128 + 9
							_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
							return
						}
					}
				}
			}()
			return client, nil
		})
		defer bridge.SetVsockConnDialer(nil)

		ctx, cancel := context.WithCancel(context.Background())
		cmd := vmexec.CommandContext(ctx, "busy_loop")
		if err := cmd.Start(); err != nil {
			t.Fatalf("cmd.Start failed: %v", err)
		}

		// Cancel to trigger SIGTERM followed by SIGKILL
		cancel()

		err := cmd.Wait()
		if err == nil {
			t.Fatal("expected error on killed command, got nil")
		}

		sigMu.Lock()
		defer sigMu.Unlock()
		if len(signals) < 2 {
			t.Fatalf("expected at least 2 signals (SIGTERM then SIGKILL), got %v", signals)
		}
		if signals[0] != 15 || signals[1] != 9 {
			t.Fatalf("expected signals [15, 9], got %v", signals)
		}
	})
}

// TestScenario3_LargePayloadStreaming verifies streaming > 1MB data without corruption or truncation.
func TestScenario3_LargePayloadStreaming(t *testing.T) {
	t.Run("MultiMegaByteIntegrity", func(t *testing.T) {
		const totalBytes = 4 * 1024 * 1024 // 4 MB
		// Generate deterministic pattern
		sourceData := make([]byte, totalBytes)
		for i := range sourceData {
			sourceData[i] = byte((i*31 + 17) % 256)
		}
		expectedHash := sha256.Sum256(sourceData)

		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				sfc := vmexec.NewFrameConn(server)
				defer sfc.Close()

				_, _, _ = sfc.ReadFrame() // Init

				// Send in 32KB chunks
				chunkSize := 32 * 1024
				for offset := 0; offset < totalBytes; offset += chunkSize {
					end := offset + chunkSize
					if end > totalBytes {
						end = totalBytes
					}
					if err := sfc.WriteFrame(vmexec.FrameStdout, 0, sourceData[offset:end]); err != nil {
						return
					}
				}

				var exitPayload [4]byte
				binary.BigEndian.PutUint32(exitPayload[:], 0)
				_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
			}()
			return client, nil
		})
		defer bridge.SetVsockConnDialer(nil)

		cmd := vmexec.Command("stream_large")
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("cmd.Output failed: %v", err)
		}

		if len(out) != totalBytes {
			t.Fatalf("length mismatch: got %d bytes, want %d bytes", len(out), totalBytes)
		}

		actualHash := sha256.Sum256(out)
		if actualHash != expectedHash {
			t.Fatalf("SHA256 hash mismatch! Data corrupted during streaming")
		}
	})

	t.Run("CombinedStdoutStderrInterleaving", func(t *testing.T) {
		const chunks = 100
		chunkStdout := bytes.Repeat([]byte("OUT_CHUNK\n"), 100) // 1000 bytes
		chunkStderr := bytes.Repeat([]byte("ERR_CHUNK\n"), 100) // 1000 bytes

		bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				sfc := vmexec.NewFrameConn(server)
				defer sfc.Close()

				_, _, _ = sfc.ReadFrame() // Init

				for i := 0; i < chunks; i++ {
					_ = sfc.WriteFrame(vmexec.FrameStdout, 0, chunkStdout)
					_ = sfc.WriteFrame(vmexec.FrameStderr, 0, chunkStderr)
				}

				var exitPayload [4]byte
				binary.BigEndian.PutUint32(exitPayload[:], 0)
				_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
			}()
			return client, nil
		})
		defer bridge.SetVsockConnDialer(nil)

		var stdoutBuf, stderrBuf bytes.Buffer
		cmd := vmexec.Command("interleaved")
		cmd.Stdout = &stdoutBuf
		cmd.Stderr = &stderrBuf

		if err := cmd.Run(); err != nil {
			t.Fatalf("cmd.Run failed: %v", err)
		}

		expectedStdoutLen := chunks * len(chunkStdout)
		expectedStderrLen := chunks * len(chunkStderr)

		if stdoutBuf.Len() != expectedStdoutLen {
			t.Fatalf("stdout length mismatch: got %d, want %d", stdoutBuf.Len(), expectedStdoutLen)
		}
		if stderrBuf.Len() != expectedStderrLen {
			t.Fatalf("stderr length mismatch: got %d, want %d", stderrBuf.Len(), expectedStderrLen)
		}
	})

	t.Run("ExceedMaxPayloadSizeRejection", func(t *testing.T) {
		var headerBuf [vmexec.HeaderSize]byte
		header := vmexec.FrameHeader{
			Version: vmexec.ProtocolVersion,
			Type:    vmexec.FrameStdout,
			Flags:   0,
			Length:  vmexec.MaxPayloadSize + 1,
		}
		header.Encode(headerBuf[:])

		_, err := vmexec.DecodeHeader(headerBuf[:])
		if err == nil {
			t.Fatal("expected DecodeHeader to reject payload exceeding MaxPayloadSize, got nil")
		}
		if !strings.Contains(err.Error(), "exceeds limit") {
			t.Fatalf("unexpected error message: %v", err)
		}
	})
}

// TestScenario4_ExitCodeAndSignalHandling tests exit codes and signal propagation.
func TestScenario4_ExitCodeAndSignalHandling(t *testing.T) {
	testCases := []struct {
		name         string
		exitCode     int32
		exitMessage  string
		wantExitCode int
	}{
		{"ExitZero", 0, "", 0},
		{"Exit1_GeneralError", 1, "build failed", 1},
		{"Exit2_Misuse", 2, "syntax error", 2},
		{"Exit127_NotFound", 127, "command not found: go-tool", 127},
		{"Exit137_SIGKILL", 137, "killed by SIGKILL", 137},
		{"Exit143_SIGTERM", 143, "terminated by SIGTERM", 143},
		{"Exit255_OutOfRange", 255, "fatal error", 255},
		{"NegativeExitMinusOne", -1, "crash", -1},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
				client, server := net.Pipe()
				go func() {
					sfc := vmexec.NewFrameConn(server)
					defer sfc.Close()

					_, _, _ = sfc.ReadFrame() // Init

					payload := make([]byte, 4+len(tc.exitMessage))
					binary.BigEndian.PutUint32(payload[:4], uint32(tc.exitCode))
					copy(payload[4:], tc.exitMessage)

					_ = sfc.WriteFrame(vmexec.FrameExit, 0, payload)
				}()
				return client, nil
			})
			defer bridge.SetVsockConnDialer(nil)

			cmd := vmexec.Command("test_exit", tc.name)
			err := cmd.Run()

			if tc.wantExitCode == 0 {
				if err != nil {
					t.Fatalf("expected nil error for exit 0, got %v", err)
				}
			} else {
				if err == nil {
					t.Fatalf("expected error for exit code %d, got nil", tc.wantExitCode)
				}
				var exitErr *vmexec.ExitError
				if !errors.As(err, &exitErr) {
					t.Fatalf("expected *vmexec.ExitError, got %T: %v", err, err)
				}
				if exitErr.ExitCode() != tc.wantExitCode {
					t.Fatalf("exit code mismatch: got %d, want %d", exitErr.ExitCode(), tc.wantExitCode)
				}
				if tc.exitMessage != "" && !strings.Contains(exitErr.Error(), tc.exitMessage) {
					t.Fatalf("expected error message %q in %q", tc.exitMessage, exitErr.Error())
				}
			}
		})
	}
}

// TestScenario5_ConcurrentDialingThreadSafety tests thread safety of DialSandboxVsockWithRetry.
func TestScenario5_ConcurrentDialingThreadSafety(t *testing.T) {
	const goroutines = 40
	var successCount int32
	var failCount int32

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		// Simulate occasional refusal
		if time.Now().UnixNano()%3 == 0 {
			return nil, errors.New("simulated transient contention")
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
	defer bridge.SetVsockConnDialer(nil)

	var wg sync.WaitGroup
	wg.Add(goroutines)

	for i := 0; i < goroutines; i++ {
		go func(id int) {
			defer wg.Done()

			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()

			cmd := vmexec.CommandContext(ctx, "concurrent_test", fmt.Sprintf("%d", id))
			err := cmd.Run()
			if err == nil {
				atomic.AddInt32(&successCount, 1)
			} else {
				atomic.AddInt32(&failCount, 1)
			}
		}(i)
	}

	wg.Wait()

	succ := atomic.LoadInt32(&successCount)
	fail := atomic.LoadInt32(&failCount)
	t.Logf("Concurrent execution results: %d succeeded, %d failed out of %d total", succ, fail, goroutines)

	if succ == 0 {
		t.Fatalf("all %d concurrent runs failed", goroutines)
	}
}

// TestScenario6_ZeroTCPHostIsolation validates host isolation: no TCP listening ports opened.
func TestScenario6_ZeroTCPHostIsolation(t *testing.T) {
	// Baseline check: list listening TCP ports using lsof
	getListeningTCPPorts := func() (map[string]bool, error) {
		out, err := exec.Command("lsof", "-a", "-p", strconv.Itoa(os.Getpid()), "-iTCP", "-sTCP:LISTEN", "-n", "-P").Output()
		if err != nil {
			// lsof returns exit 1 if no files match
			return make(map[string]bool), nil
		}
		lines := strings.Split(string(out), "\n")
		ports := make(map[string]bool)
		for _, line := range lines {
			fields := strings.Fields(line)
			if len(fields) >= 9 {
				ports[fields[8]] = true
			}
		}
		return ports, nil
	}

	baselinePorts, err := getListeningTCPPorts()
	if err != nil {
		t.Fatalf("failed to get baseline TCP ports: %v", err)
	}

	// Dial vsock connection and run command
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			sfc := vmexec.NewFrameConn(server)
			defer sfc.Close()
			_, _, _ = sfc.ReadFrame()
			var exitPayload [4]byte
			binary.BigEndian.PutUint32(exitPayload[:], 0)
			_ = sfc.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
		}()
		return client, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	cmd := vmexec.Command("isolation_check")
	if err := cmd.Run(); err != nil {
		t.Fatalf("cmd.Run failed: %v", err)
	}

	activePorts, err := getListeningTCPPorts()
	if err != nil {
		t.Fatalf("failed to get active TCP ports: %v", err)
	}

	// Verify no new TCP listeners appeared
	for port := range activePorts {
		if !baselinePorts[port] {
			// A new TCP port was opened during execution!
			t.Errorf("VIOLATION: new TCP listening port detected during vsock operation: %s", port)
		}
	}
}

// TestScenario7_Wave5_ReadOnlyAndLoopbackFramingFlags tests that ReadOnlyWorkspace and LoopbackOnlyNetwork
// properly set the FlagReadOnly (0x0010) and FlagLoopbackOnly (0x0020) flags in the FrameExecInit header.
func TestScenario7_Wave5_ReadOnlyAndLoopbackFramingFlags(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	cfc := vmexec.NewFrameConn(client)
	sfc := vmexec.NewFrameConn(server)

	go func() {
		init := vmexec.ExecInit{
			Argv:                []string{"go", "test", "./..."},
			Cwd:                 "/workspaces/test",
			ReadOnlyWorkspace:   true,
			LoopbackOnlyNetwork: true,
		}
		_ = cfc.SendExecInit(init)
	}()

	hdr, payload, err := sfc.ReadFrame()
	if err != nil {
		t.Fatalf("failed to read frame: %v", err)
	}

	if hdr.Type != vmexec.FrameExecInit {
		t.Fatalf("expected FrameExecInit (0x01), got 0x%02x", hdr.Type)
	}

	const expectedFlags = vmexec.FlagReadOnly | vmexec.FlagLoopbackOnly
	if hdr.Flags&expectedFlags != expectedFlags {
		t.Fatalf("expected flags 0x%04x to be set, got header flags 0x%04x", expectedFlags, hdr.Flags)
	}

	if !strings.Contains(string(payload), `"read_only_workspace":true`) {
		t.Fatalf("expected read_only_workspace in JSON payload, got: %s", string(payload))
	}
	if !strings.Contains(string(payload), `"loopback_only_network":true`) {
		t.Fatalf("expected loopback_only_network in JSON payload, got: %s", string(payload))
	}
}
