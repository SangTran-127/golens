package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

func TestStartTerminalCommandRunsArgvInPTY(t *testing.T) {
	exits := make(chan map[string]any, 8)
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "terminalExit" {
			var m map[string]any
			if json.Unmarshal([]byte(payload), &m) == nil {
				exits <- m
			}
		}
	}))
	waitExit := func(id string) float64 {
		t.Helper()
		select {
		case m := <-exits:
			if m["id"] != id {
				t.Fatalf("exit for %v, want %s", m["id"], id)
			}
			return m["code"].(float64)
		case <-time.After(5 * time.Second):
			t.Fatalf("%s did not exit", id)
		}
		return -1
	}

	if err := startTerminalCommand("cmd-echo", "", []string{"/bin/echo", "ok"}); err != nil {
		t.Fatal(err)
	}
	if code := waitExit("cmd-echo"); code != 0 {
		t.Fatalf("echo exit = %v", code)
	}

	dir := t.TempDir()
	script := `printf '%s|%s' "$0" "$(pwd -P)" > out.txt; test -t 0 && test -t 1`
	if err := startTerminalCommand("cmd-sh", dir, []string{"sh", "-c", script, "hello world"}); err != nil {
		t.Fatal(err)
	}
	if code := waitExit("cmd-sh"); code != 0 {
		t.Fatalf("sh exit = %v (stdin and stdout must be a TTY)", code)
	}
	realDir, _ := filepath.EvalSymlinks(dir)
	if got, _ := os.ReadFile(filepath.Join(dir, "out.txt")); string(got) != "hello world|"+realDir {
		t.Fatalf("argv or cwd not passed: %q", got)
	}
	if terminalCount() != 0 {
		t.Fatal("exited sessions must leave the table")
	}

	if err := startTerminalCommand("cmd-missing", dir, []string{"golens-no-such-command"}); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing command = %v", err)
	}
	if err := startTerminalCommand("cmd-empty", dir, nil); err == nil {
		t.Fatal("empty argv must fail")
	}
}
