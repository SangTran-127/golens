package vmexec_test

import (
	"encoding/json"
	"net"
	"sync"
	"testing"

	"golens/core/vmexec"
)

func TestChallenger_Wave5_FramingFlagPermutations(t *testing.T) {
	cases := []struct {
		name             string
		readOnly         bool
		loopbackOnly     bool
		expectedFlags    uint16
		forbiddenFlags   uint16
		expectedROJson   bool
		expectedLoopJson bool
	}{
		{
			name:             "NeitherFlagSet",
			readOnly:         false,
			loopbackOnly:     false,
			expectedFlags:    0x0000,
			forbiddenFlags:   vmexec.FlagReadOnly | vmexec.FlagLoopbackOnly,
			expectedROJson:   false,
			expectedLoopJson: false,
		},
		{
			name:             "OnlyReadOnlySet",
			readOnly:         true,
			loopbackOnly:     false,
			expectedFlags:    vmexec.FlagReadOnly,
			forbiddenFlags:   vmexec.FlagLoopbackOnly,
			expectedROJson:   true,
			expectedLoopJson: false,
		},
		{
			name:             "OnlyLoopbackOnlySet",
			readOnly:         false,
			loopbackOnly:     true,
			expectedFlags:    vmexec.FlagLoopbackOnly,
			forbiddenFlags:   vmexec.FlagReadOnly,
			expectedROJson:   false,
			expectedLoopJson: true,
		},
		{
			name:             "BothFlagsSet",
			readOnly:         true,
			loopbackOnly:     true,
			expectedFlags:    vmexec.FlagReadOnly | vmexec.FlagLoopbackOnly,
			forbiddenFlags:   0x0000,
			expectedROJson:   true,
			expectedLoopJson: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()

			cfc := vmexec.NewFrameConn(client)
			sfc := vmexec.NewFrameConn(server)

			errCh := make(chan error, 1)
			go func() {
				init := vmexec.ExecInit{
					Argv:                []string{"go", "test", "./..."},
					Cwd:                 "/workspaces/test",
					ReadOnlyWorkspace:   tc.readOnly,
					LoopbackOnlyNetwork: tc.loopbackOnly,
				}
				errCh <- cfc.SendExecInit(init)
			}()

			hdr, payload, err := sfc.ReadFrame()
			if err != nil {
				t.Fatalf("ReadFrame failed: %v", err)
			}
			if sendErr := <-errCh; sendErr != nil {
				t.Fatalf("SendExecInit failed: %v", sendErr)
			}

			if hdr.Type != vmexec.FrameExecInit {
				t.Fatalf("expected FrameExecInit (0x01), got 0x%02x", hdr.Type)
			}

			if tc.expectedFlags != 0 && (hdr.Flags&tc.expectedFlags) != tc.expectedFlags {
				t.Fatalf("expected flags 0x%04x to be set, got 0x%04x", tc.expectedFlags, hdr.Flags)
			}
			if tc.forbiddenFlags != 0 && (hdr.Flags&tc.forbiddenFlags) != 0 {
				t.Fatalf("flags 0x%04x should NOT be set, got 0x%04x", tc.forbiddenFlags, hdr.Flags)
			}

			var decoded vmexec.ExecInit
			if err := json.Unmarshal(payload, &decoded); err != nil {
				t.Fatalf("failed to decode JSON payload: %v", err)
			}

			if decoded.ReadOnlyWorkspace != tc.expectedROJson {
				t.Fatalf("expected ReadOnlyWorkspace=%v, got %v", tc.expectedROJson, decoded.ReadOnlyWorkspace)
			}
			if decoded.LoopbackOnlyNetwork != tc.expectedLoopJson {
				t.Fatalf("expected LoopbackOnlyNetwork=%v, got %v", tc.expectedLoopJson, decoded.LoopbackOnlyNetwork)
			}
		})
	}
}

func TestChallenger_Wave5_ConcurrentFrameOperationsRaceFree(t *testing.T) {
	const concurrency = 25
	var wg sync.WaitGroup
	wg.Add(concurrency)

	for i := 0; i < concurrency; i++ {
		go func(idx int) {
			defer wg.Done()
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()

			cfc := vmexec.NewFrameConn(client)
			sfc := vmexec.NewFrameConn(server)

			ro := (idx % 2) == 0
			loop := (idx % 3) == 0

			go func() {
				init := vmexec.ExecInit{
					Argv:                []string{"go", "version"},
					Cwd:                 "/workspaces/bench",
					ReadOnlyWorkspace:   ro,
					LoopbackOnlyNetwork: loop,
				}
				_ = cfc.SendExecInit(init)
			}()

			hdr, payload, err := sfc.ReadFrame()
			if err != nil {
				t.Errorf("[%d] ReadFrame failed: %v", idx, err)
				return
			}
			if hdr.Type != vmexec.FrameExecInit {
				t.Errorf("[%d] expected FrameExecInit, got 0x%02x", idx, hdr.Type)
				return
			}

			var decoded vmexec.ExecInit
			if err := json.Unmarshal(payload, &decoded); err != nil {
				t.Errorf("[%d] json unmarshal failed: %v", idx, err)
				return
			}
			if decoded.ReadOnlyWorkspace != ro || decoded.LoopbackOnlyNetwork != loop {
				t.Errorf("[%d] flag mismatch: ro=%v, loop=%v", idx, decoded.ReadOnlyWorkspace, decoded.LoopbackOnlyNetwork)
			}
		}(i)
	}

	wg.Wait()
}
