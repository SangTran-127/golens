package fsutil

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/bridge"
)

const scopeTestToken = "ghp_scopeCanary0000"

func TestGitArgsNeedAuth(t *testing.T) {
	cases := []struct {
		args []string
		want bool
	}{
		{[]string{"fetch"}, true},
		{[]string{"fetch", "--prune", "origin"}, true},
		{[]string{"pull", "--rebase"}, true},
		{[]string{"push", "-u", "origin", "main"}, true},
		{[]string{"clone", "https://github.com/a/b.git", "b"}, true},
		{[]string{"ls-remote", "origin"}, true},
		{[]string{"-c", "core.editor=true", "push"}, true},
		{[]string{"-C", "/tmp/repo", "fetch"}, true},
		{[]string{"--no-optional-locks", "-c", "http.version=HTTP/1.1", "pull"}, true},
		{[]string{"remote", "update"}, true},
		{[]string{"remote", "-v", "prune", "origin"}, true},
		{[]string{"submodule", "update", "--init"}, true},
		{[]string{"lfs", "push", "origin"}, true},
		{[]string{"commit", "-m", "x"}, false},
		{[]string{"-c", "commit.gpgsign=false", "commit", "-m", "fetch"}, false},
		{[]string{"-c", "push", "status"}, false},
		{[]string{"--no-optional-locks", "status", "--porcelain=v2"}, false},
		{[]string{"diff", "--cached"}, false},
		{[]string{"log", "--format=%H"}, false},
		{[]string{"remote", "-v"}, false},
		{[]string{"remote", "add", "origin", "https://github.com/a/b.git"}, false},
		{[]string{"submodule", "status"}, false},
		{[]string{"config", "--get", "remote.origin.url"}, false},
		{nil, false},
	}
	for _, c := range cases {
		if got := gitArgsNeedAuth(c.args); got != c.want {
			t.Errorf("gitArgsNeedAuth(%q) = %v, want %v", c.args, got, c.want)
		}
	}
}

func envHasToken(env []string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, "GIT_CONFIG_VALUE_") || strings.Contains(kv, scopeTestToken) {
			return true
		}
	}
	return false
}

func TestGitAuthEnvOnlyForRemoteCommands(t *testing.T) {
	defer SetGitHostCredentials(nil)
	SetGitHostCredentials([]GitHostCredential{{Provider: "github", Host: "github.com", Token: scopeTestToken}})

	if envHasToken(buildHostGitEnv(nil, false)) {
		t.Fatal("host env without auth must not carry the auth config")
	}
	if !envHasToken(buildHostGitEnv(nil, true)) {
		t.Fatal("host env with auth must carry the extraheader config")
	}

	ctx := context.Background()
	if envHasToken(GitCommand(ctx, "/Users/test/ws", "/Users/test/ws", "commit", "-m", "x").Env) {
		t.Fatal("VM commit must not carry auth config")
	}
	if envHasToken(GitCommand(ctx, "/Users/test/ws", "/Users/test/ws", "status").Env) {
		t.Fatal("VM status must not carry auth config")
	}
	if !envHasToken(GitCommand(ctx, "/Users/test/ws", "/Users/test/ws", "push", "origin").Env) {
		t.Fatal("VM push must carry auth config")
	}
}

func TestHostCommitHookDoesNotSeeGitToken(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	prevMode := bridge.ExecutionMode()
	bridge.SetExecutionMode("host")
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })
	defer SetGitHostCredentials(nil)
	SetGitHostCredentials([]GitHostCredential{{Provider: "github", Host: "github.com", Token: scopeTestToken}})

	repo := t.TempDir()
	ctx := context.Background()
	run := func(args ...string) {
		t.Helper()
		res := RunGitWithOptions(ctx, GitRunOptions{Dir: repo}, args...)
		if res.Err != nil || res.ExitCode != 0 {
			t.Fatalf("git %v failed: %v (%s)", args, res.Err, res.Output)
		}
	}
	run("init", "-q")

	dump := filepath.Join(t.TempDir(), "hook-env")
	hook := "#!/bin/sh\nenv > '" + dump + "'\n"
	if err := os.WriteFile(filepath.Join(repo, ".git", "hooks", "pre-commit"), []byte(hook), 0o755); err != nil {
		t.Fatal(err)
	}
	run("-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false",
		"commit", "--allow-empty", "-q", "-m", "init")

	got, err := os.ReadFile(dump)
	if err != nil {
		t.Fatalf("pre-commit hook did not run: %v", err)
	}
	if strings.Contains(string(got), "GIT_CONFIG_VALUE_") || strings.Contains(string(got), "Authorization") {
		t.Fatal("pre-commit hook environment carries the Git account auth header")
	}
}
