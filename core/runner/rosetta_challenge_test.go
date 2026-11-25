package runner

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestAdversarialRosettaRunnerMatrix(t *testing.T) {
	cases := []struct {
		name        string
		configJSON  string
		wantRosetta bool
		wantGOARCH  string
	}{
		{
			name:        "PureArm64Native",
			configJSON:  `{"name":"arm64_app","architecture":"arm64"}`,
			wantRosetta: false,
			wantGOARCH:  "GOARCH=arm64",
		},
		{
			name:        "RosettaViaArchitectureField",
			configJSON:  `{"name":"amd64_arch","architecture":"amd64"}`,
			wantRosetta: true,
			wantGOARCH:  "GOARCH=amd64",
		},
		{
			name:        "RosettaViaTargetObject",
			configJSON:  `{"name":"amd64_target","target":{"kind":"vm_amd64"}}`,
			wantRosetta: true,
			wantGOARCH:  "GOARCH=amd64",
		},
		{
			name:        "RosettaViaEnvVarGOARCH",
			configJSON:  `{"name":"amd64_env","envVars":{"GOARCH":"amd64"}}`,
			wantRosetta: true,
			wantGOARCH:  "GOARCH=amd64",
		},
		{
			name:        "RosettaTargetOverridingArm64Architecture",
			configJSON:  `{"name":"override_test","architecture":"arm64","target":{"kind":"vm_amd64"}}`,
			wantRosetta: true,
			wantGOARCH:  "GOARCH=amd64",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
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
			initReceived := make(chan struct{})

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

			run := RunWithConfig(dir, tc.configJSON)
			if run == nil {
				t.Fatal("RunWithConfig returned nil")
			}

			select {
			case <-initReceived:
			case <-time.After(2 * time.Second):
				t.Fatal("timeout waiting for ExecInit")
			}

			if capturedInit.Rosetta != tc.wantRosetta {
				t.Errorf("Rosetta = %v, want %v", capturedInit.Rosetta, tc.wantRosetta)
			}

			var foundArch bool
			for _, env := range capturedInit.Env {
				if env == tc.wantGOARCH {
					foundArch = true
					break
				}
			}
			if !foundArch {
				t.Errorf("expected %s in env, got: %v", tc.wantGOARCH, capturedInit.Env)
			}

			select {
			case <-run.done:
			case <-time.After(2 * time.Second):
				t.Fatal("timeout waiting for run done")
			}
		})
	}
}
