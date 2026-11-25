package runner

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"testing"

	"golens/core/vmexec"
)

func TestParseCgroupLimits(t *testing.T) {
	tests := []struct {
		name        string
		mem         string
		cpu         string
		wantMemMax  uint64
		wantQuotaUS uint32
		wantNil     bool
	}{
		{
			name:    "unlimited",
			mem:     "unlimited",
			cpu:     "unlimited",
			wantNil: true,
		},
		{
			name:    "empty strings",
			mem:     "",
			cpu:     "",
			wantNil: true,
		},
		{
			name:       "128MB only",
			mem:        "128MB",
			cpu:        "unlimited",
			wantMemMax: 128 * 1024 * 1024,
		},
		{
			name:       "256MB and 0.5 CPU",
			mem:        "256MB",
			cpu:        "0.5",
			wantMemMax: 256 * 1024 * 1024,
			wantQuotaUS: 50000,
		},
		{
			name:       "512MB and 1.0 CPU",
			mem:        "512MB",
			cpu:        "1.0",
			wantMemMax: 512 * 1024 * 1024,
			wantQuotaUS: 100000,
		},
		{
			name:       "1GB and 2.0 CPU",
			mem:        "1GB",
			cpu:        "2.0",
			wantMemMax: 1024 * 1024 * 1024,
			wantQuotaUS: 200000,
		},
		{
			name:        "0.25 CPU only",
			mem:         "unlimited",
			cpu:         "0.25",
			wantQuotaUS: 25000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ParseCgroupLimits(tt.mem, tt.cpu)
			if tt.wantNil {
				if got != nil {
					t.Fatalf("expected nil limits, got %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("expected non-nil limits, got nil")
			}
			if got.MemoryMax != tt.wantMemMax {
				t.Errorf("MemoryMax = %d, want %d", got.MemoryMax, tt.wantMemMax)
			}
			if got.CPUQuotaUS != tt.wantQuotaUS {
				t.Errorf("CPUQuotaUS = %d, want %d", got.CPUQuotaUS, tt.wantQuotaUS)
			}
			if tt.wantQuotaUS > 0 && got.CPUPeriodUS != 100000 {
				t.Errorf("CPUPeriodUS = %d, want 100000", got.CPUPeriodUS)
			}
		})
	}
}

func TestExecInitFramingFlags(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	fc := vmexec.NewFrameConn(c1)

	limits := &vmexec.CgroupLimits{
		MemoryMax:   128 * 1024 * 1024,
		CPUQuotaUS:  25000,
		CPUPeriodUS: 100000,
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- fc.SendExecInit(vmexec.ExecInit{
			Argv:    []string{"go", "run", "."},
			Rosetta: true,
			Cgroup:  limits,
		})
	}()

	hdrBuf := make([]byte, vmexec.HeaderSize)
	if _, err := io.ReadFull(c2, hdrBuf); err != nil {
		t.Fatalf("failed to read header: %v", err)
	}
	hdr, err := vmexec.DecodeHeader(hdrBuf)
	if err != nil {
		t.Fatalf("failed to decode header: %v", err)
	}

	if hdr.Type != vmexec.FrameExecInit {
		t.Errorf("header type = 0x%02x, want 0x01", hdr.Type)
	}
	expectedFlags := vmexec.FlagRosetta | vmexec.FlagCgroup
	if hdr.Flags&expectedFlags != expectedFlags {
		t.Errorf("header flags = 0x%04x, want 0x%04x", hdr.Flags, expectedFlags)
	}

	payload := make([]byte, hdr.Length)
	if _, err := io.ReadFull(c2, payload); err != nil {
		t.Fatalf("failed to read payload: %v", err)
	}

	var init vmexec.ExecInit
	if err := json.Unmarshal(payload, &init); err != nil {
		t.Fatalf("failed to unmarshal ExecInit: %v", err)
	}
	if init.Cgroup == nil || init.Cgroup.MemoryMax != limits.MemoryMax {
		t.Errorf("init.Cgroup = %+v, want %+v", init.Cgroup, limits)
	}

	if err := <-errCh; err != nil {
		t.Fatalf("SendExecInit returned error: %v", err)
	}
}

func TestOOMExitDetection(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	cmd := vmexec.Command("echo", "test")
	cmd.Port = 2002

	// Mock server that returns FrameExit with FlagOOMKilled
	go func() {
		hdrBuf := make([]byte, vmexec.HeaderSize)
		_, _ = io.ReadFull(c2, hdrBuf)
		hdr, _ := vmexec.DecodeHeader(hdrBuf)
		payload := make([]byte, hdr.Length)
		_, _ = io.ReadFull(c2, payload)

		fc := vmexec.NewFrameConn(c2)
		exitPayload := make([]byte, 4)
		binary.BigEndian.PutUint32(exitPayload, 137) // 128 + 9 = SIGKILL (OOM)
		_ = fc.WriteFrame(vmexec.FrameExit, vmexec.FlagOOMKilled, exitPayload)
	}()

	// Connect cmd to pipe
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf

	// Launch reader pump directly using NewFrameConn on c1
	fc1 := vmexec.NewFrameConn(c1)
	init := vmexec.ExecInit{Argv: cmd.Args}
	if err := fc1.SendExecInit(init); err != nil {
		t.Fatalf("SendExecInit failed: %v", err)
	}

	hdr, payload, err := fc1.ReadFrame()
	if err != nil {
		t.Fatalf("ReadFrame failed: %v", err)
	}
	if hdr.Type != vmexec.FrameExit {
		t.Fatalf("frame type = %d, want FrameExit", hdr.Type)
	}
	if hdr.Flags&vmexec.FlagOOMKilled == 0 {
		t.Fatalf("header flags do not have FlagOOMKilled: 0x%04x", hdr.Flags)
	}
	exitCode := int(int32(binary.BigEndian.Uint32(payload[:4])))
	if exitCode != 137 {
		t.Fatalf("exit code = %d, want 137", exitCode)
	}
}
