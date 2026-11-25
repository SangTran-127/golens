package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

func TestTerminalDockerCommandsUseTheChosenContext(t *testing.T) {
	shell := []string{"docker", "exec", "-it", "abc", "sh", "-c", "exec sh"}
	if got := withDockerContext(shell, nil); !reflect.DeepEqual(got, shell) {
		t.Fatalf("without a chosen context = %v", got)
	}
	want := []string{"docker", "--context", "vps", "exec", "-it", "abc", "sh", "-c", "exec sh"}
	if got := withDockerContext(shell, []string{"--context", "vps"}); !reflect.DeepEqual(got, want) {
		t.Fatalf("with a chosen context = %v", got)
	}
	own := []string{"/usr/local/bin/docker", "--context", "dev", "ps"}
	if got := withDockerContext(own, []string{"--context", "vps"}); !reflect.DeepEqual(got, own) {
		t.Fatalf("an explicit context must stay = %v", got)
	}
	if got := withDockerContext([]string{"kubectl", "get", "pods"}, []string{"--context", "vps"}); len(got) != 3 {
		t.Fatalf("other tools stay unchanged = %v", got)
	}
}

func TestComposeLogsRunReportsEngineDownInTheConsole(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "glsv")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("DOCKER_HOST", "unix://"+filepath.Join(dir, "missing.sock"))
	events := make(chan map[string]any, 16)
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "runEvent" {
			var m map[string]any
			if json.Unmarshal([]byte(payload), &m) == nil {
				events <- m
			}
		}
	}))
	id := composeLogsRun("/Users/me/src/velo/compose.yaml", "Compose Logs", "compose-logs:test")
	if id == 0 {
		t.Fatal("no run id")
	}
	deadline := time.After(5 * time.Second)
	sawLine := false
	for {
		select {
		case m := <-events:
			if lines, ok := m["lines"].([]any); ok && len(lines) > 0 {
				sawLine = strings.Contains(lines[0].(map[string]any)["text"].(string), "isn’t running")
			}
			if m["state"] == "failed" {
				if !sawLine || !strings.HasPrefix(m["error"].(string), "Docker Engine isn’t running at ") {
					t.Fatalf("failed event = %v (line shown: %v)", m, sawLine)
				}
				return
			}
		case <-deadline:
			t.Fatal("compose logs run never failed")
		}
	}
}
