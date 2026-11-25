package guestres

import (
	"slices"
	"testing"
)

func TestSandboxExecArgsRoundTrip(t *testing.T) {
	cases := []SandboxSpec{
		{ReadOnly: true, LoopbackOnly: true, Path: "/usr/local/go/bin/go", Argv: []string{"go", "test", "-run", "^TestX$", "--", "./..."}},
		{ReadOnly: true, Path: "/usr/local/go/bin/go", Argv: []string{"go", "vet"}},
		{LoopbackOnly: true, Path: "/bin/sh", Argv: []string{"sh", "-c", "--read-only"}},
	}
	for _, want := range cases {
		args := SandboxExecArgs(want)
		if args[0] != SandboxExecName {
			t.Fatalf("argv[0] = %q, want %q", args[0], SandboxExecName)
		}
		got, err := ParseSandboxExecArgs(args[1:])
		if err != nil {
			t.Fatalf("ParseSandboxExecArgs(%q): %v", args, err)
		}
		if got.ReadOnly != want.ReadOnly || got.LoopbackOnly != want.LoopbackOnly || got.Path != want.Path || !slices.Equal(got.Argv, want.Argv) {
			t.Fatalf("round trip = %+v, want %+v", got, want)
		}
	}
}

func TestParseSandboxExecArgsRejectsIncompleteRequests(t *testing.T) {
	bad := [][]string{
		nil,
		{"--read-only"},
		{"--read-only", "--"},
		{"--read-only", "--", "/bin/go"},
		{"--", "/bin/go", "go"},
		{"--writable", "--", "/bin/go", "go"},
	}
	for _, args := range bad {
		if spec, err := ParseSandboxExecArgs(args); err == nil {
			t.Fatalf("ParseSandboxExecArgs(%q) = %+v, want an error", args, spec)
		}
	}
}

func TestSandboxReadOnlyPathsCoverWorkspaceAndModuleCache(t *testing.T) {
	for _, p := range []string{"/workspaces", "/cache/gomod"} {
		if !slices.Contains(SandboxReadOnlyPaths, p) {
			t.Fatalf("SandboxReadOnlyPaths = %q, missing %q", SandboxReadOnlyPaths, p)
		}
	}
	if slices.Contains(SandboxReadOnlyPaths, "/cache/gobuild") {
		t.Fatal("the build cache must stay writable so go test can compile")
	}
}
