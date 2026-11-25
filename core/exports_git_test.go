package main

import (
	"encoding/json"
	"testing"

	"golens/core/bridge"
	"golens/core/fsutil"
)

func TestRunGitCommandRejectsMalformedArguments(t *testing.T) {
	prev := bridge.ExecutionMode()
	bridge.SetExecutionMode("host")
	t.Cleanup(func() { bridge.SetExecutionMode(prev) })
	dir := t.TempDir()

	var out fsutil.GitExecResult
	if err := json.Unmarshal([]byte(runGitCommandJSON(dir, "{not json", nil)), &out); err != nil {
		t.Fatalf("reply is not JSON: %v", err)
	}
	if out.Error == "" || out.ExitCode != -1 || out.Output != "" {
		t.Fatalf("expected an error reply without running git, got %+v", out)
	}

	res := runGitCommandEx(0, dir, dir, `["status"`, nil, 0)
	if res.Err == nil || res.ExitCode != -1 || len(res.Output) != 0 {
		t.Fatalf("expected an error result without running git, got exit %d err %v output %q", res.ExitCode, res.Err, res.Output)
	}
}
