package remote

import (
	"os"
	"path/filepath"
	"testing"
)

func composeAccessWithMapping(t *testing.T, mapping string) debugAccess {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	relayDir := relayCacheDir("arm64", "")
	if err := os.MkdirAll(relayDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(relayDir, relayBin), []byte("stub"), 0o755); err != nil {
		t.Fatal(err)
	}
	docker := filepath.Join(t.TempDir(), "docker")
	script := "#!/bin/sh\nprintf '%s\\n' '" + mapping + "'\n"
	if err := os.WriteFile(docker, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	target := Target{Kind: KindCompose, ComposeFile: filepath.Join(t.TempDir(), "compose.yaml"), Service: "api", DebugPort: 2345}
	access, iss := prepareAccess(prepared{
		plan: Plan{Target: target, Probe: Probe{GOARCH: "arm64"}},
		tr:   Transport{Target: target, DockerPath: docker},
	})
	if iss != nil {
		t.Fatalf("prepareAccess: %v", iss)
	}
	return access
}

func TestComposeDebugUsesLoopbackPublishedPortDirectly(t *testing.T) {
	access := composeAccessWithMapping(t, "127.0.0.1:2345")
	if access.listen != "0.0.0.0:2345" || access.relayDir != "" {
		t.Fatalf("loopback mapping should dial the published port, got listen=%q relay=%q", access.listen, access.relayDir)
	}
}

func TestComposeDebugKeepsDelveOffNetworkPublishedPort(t *testing.T) {
	access := composeAccessWithMapping(t, "0.0.0.0:2345")
	if access.listen != "127.0.0.1:2345" {
		t.Fatalf("Delve must stay on the container loopback when the port is published on all interfaces, got %q", access.listen)
	}
	if access.relayDir == "" {
		t.Fatal("expected the docker compose exec relay when the published port is not loopback-only")
	}
}
