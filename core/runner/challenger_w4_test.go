package runner_test

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golens/core/runner"
	"golens/core/vmexec"
)

// TestChallenger_CgroupsLimitsBoundaryAndOverflow tests edge cases and overflow resistance in cgroups limit parsing.
func TestChallenger_CgroupsLimitsBoundaryAndOverflow(t *testing.T) {
	cases := []struct {
		name       string
		mem        string
		cpu        string
		wantNil    bool
		wantMemMax uint64
		wantCPUQ   uint32
	}{
		{"BothEmpty", "", "", true, 0, 0},
		{"BothUnlimited", "unlimited", "unlimited", true, 0, 0},
		{"CaseInsensitiveCheck", "128mb", "1.0", false, 0, 100000}, // ParseCgroupLimits uses exact case match
		{"UnknownMemoryKnownCPU", "999GB", "0.5", false, 0, 50000},
		{"KnownMemoryUnknownCPU", "512MB", "99.0", false, 512 * 1024 * 1024, 0},
		{"NegativeValues", "-128MB", "-1.0", true, 0, 0},
		{"FractionalMemory", "128.5MB", "0.5", false, 0, 50000},
		{"OverflowLikeStrings", "18446744073709551616MB", "999999999999", true, 0, 0},
		{"ZeroValues", "0MB", "0.0", true, 0, 0},
		{"WhitespaceSurrounded", " 128MB ", " 1.0 ", true, 0, 0},
		{"Valid128MB", "128MB", "unlimited", false, 128 * 1024 * 1024, 0},
		{"Valid256MB", "256MB", "unlimited", false, 256 * 1024 * 1024, 0},
		{"Valid512MB", "512MB", "unlimited", false, 512 * 1024 * 1024, 0},
		{"Valid1GB", "1GB", "unlimited", false, 1024 * 1024 * 1024, 0},
		{"Valid025CPU", "unlimited", "0.25", false, 0, 25000},
		{"Valid05CPU", "unlimited", "0.5", false, 0, 50000},
		{"Valid10CPU", "unlimited", "1.0", false, 0, 100000},
		{"Valid20CPU", "unlimited", "2.0", false, 0, 200000},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := runner.ParseCgroupLimits(tc.mem, tc.cpu)
			if tc.wantNil {
				if res != nil {
					t.Fatalf("expected nil for %s, got %+v", tc.name, res)
				}
				return
			}
			if res == nil {
				t.Fatalf("expected non-nil for %s, got nil", tc.name)
			}
			if res.MemoryMax != tc.wantMemMax {
				t.Fatalf("MemoryMax = %d, expected %d", res.MemoryMax, tc.wantMemMax)
			}
			if res.CPUQuotaUS != tc.wantCPUQ {
				t.Fatalf("CPUQuotaUS = %d, expected %d", res.CPUQuotaUS, tc.wantCPUQ)
			}
		})
	}
}

// TestChallenger_InBandKernelTelemetryMultiplexing tests rapid interleaved telemetry frames.
func TestChallenger_InBandKernelTelemetryMultiplexing(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	cmd := vmexec.Command("stress-app")
	cmd.Port = 2002
	cmd.EnableTelemetry = true

	var telemetryReceived atomic.Int64
	var stdoutBytes atomic.Int64
	var stderrBytes atomic.Int64

	cmd.OnTelemetry = func(payload []byte) {
		telemetryReceived.Add(1)
		var kt map[string]any
		_ = json.Unmarshal(payload, &kt)
	}

	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	// Server goroutine producing interleaved stdout, stderr, and FrameKernelTelemetry
	const numTelemetryFrames = 100
	const numDataFrames = 100

	go func() {
		fcServer := vmexec.NewFrameConn(c2)
		defer fcServer.Close()

		// Read ExecInit
		_, _, _ = fcServer.ReadFrame()

		var wg sync.WaitGroup
		wg.Add(3)

		// Telemetry pump
		go func() {
			defer wg.Done()
			for i := 0; i < numTelemetryFrames; i++ {
				kt := map[string]any{
					"pid":        12345,
					"targetName": "stress-app",
					"timestamp":  time.Now(),
					"openFDs":    map[string]int{"count": 10 + i, "limit": 1024},
				}
				data, _ := json.Marshal(kt)
				_ = fcServer.WriteFrame(vmexec.FrameKernelTelemetry, 0, data)
				time.Sleep(100 * time.Microsecond)
			}
		}()

		// Stdout pump
		go func() {
			defer wg.Done()
			for i := 0; i < numDataFrames; i++ {
				data := []byte(fmt.Sprintf("stdout message %04d\n", i))
				stdoutBytes.Add(int64(len(data)))
				_ = fcServer.WriteFrame(vmexec.FrameStdout, 0, data)
				time.Sleep(100 * time.Microsecond)
			}
		}()

		// Stderr pump
		go func() {
			defer wg.Done()
			for i := 0; i < numDataFrames; i++ {
				data := []byte(fmt.Sprintf("stderr message %04d\n", i))
				stderrBytes.Add(int64(len(data)))
				_ = fcServer.WriteFrame(vmexec.FrameStderr, 0, data)
				time.Sleep(100 * time.Microsecond)
			}
		}()

		wg.Wait()

		// Send exit frame
		var exitPayload [4]byte
		binary.BigEndian.PutUint32(exitPayload[:], 0)
		_ = fcServer.WriteFrame(vmexec.FrameExit, 0, exitPayload[:])
	}()

	// Connect cmd to pipe
	// Start manually with frame conn
	fcClient := vmexec.NewFrameConn(c1)
	init := vmexec.ExecInit{
		Argv:            cmd.Args,
		EnableTelemetry: true,
	}
	if err := fcClient.SendExecInit(init); err != nil {
		t.Fatalf("SendExecInit failed: %v", err)
	}

	// Read frames in client
	doneCh := make(chan struct{})
	go func() {
		defer close(doneCh)
		for {
			hdr, payload, err := fcClient.ReadFrame()
			if err != nil {
				return
			}
			switch hdr.Type {
			case vmexec.FrameStdout:
				stdoutBuf.Write(payload)
			case vmexec.FrameStderr:
				stderrBuf.Write(payload)
			case vmexec.FrameKernelTelemetry:
				cmd.OnTelemetry(payload)
			case vmexec.FrameExit:
				return
			}
		}
	}()

	select {
	case <-doneCh:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for execution completion")
	}

	if telemetryReceived.Load() != numTelemetryFrames {
		t.Fatalf("telemetry received count = %d, expected %d", telemetryReceived.Load(), numTelemetryFrames)
	}
	if int64(stdoutBuf.Len()) != stdoutBytes.Load() {
		t.Fatalf("stdout bytes = %d, expected %d", stdoutBuf.Len(), stdoutBytes.Load())
	}
	if int64(stderrBuf.Len()) != stderrBytes.Load() {
		t.Fatalf("stderr bytes = %d, expected %d", stderrBuf.Len(), stderrBytes.Load())
	}
}
