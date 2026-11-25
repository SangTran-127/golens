package guestres

import (
	"errors"
	"fmt"
	"slices"
)

const SandboxExecName = "golens-sandbox-exec"

var SandboxReadOnlyPaths = []string{"/workspaces", "/cache/gomod"}

type SandboxSpec struct {
	ReadOnly     bool
	LoopbackOnly bool
	Path         string
	Argv         []string
}

func (s SandboxSpec) Active() bool {
	return s.ReadOnly || s.LoopbackOnly
}

func SandboxExecArgs(spec SandboxSpec) []string {
	args := []string{SandboxExecName}
	if spec.ReadOnly {
		args = append(args, "--read-only")
	}
	if spec.LoopbackOnly {
		args = append(args, "--loopback-only")
	}
	args = append(args, "--", spec.Path)
	return append(args, spec.Argv...)
}

func ParseSandboxExecArgs(args []string) (SandboxSpec, error) {
	var spec SandboxSpec
	sep := slices.Index(args, "--")
	if sep < 0 {
		return spec, errors.New("missing -- before the command")
	}
	for _, opt := range args[:sep] {
		switch opt {
		case "--read-only":
			spec.ReadOnly = true
		case "--loopback-only":
			spec.LoopbackOnly = true
		default:
			return spec, fmt.Errorf("unknown option %q", opt)
		}
	}
	rest := args[sep+1:]
	if len(rest) < 2 || rest[0] == "" {
		return spec, errors.New("missing command path and argv")
	}
	if !spec.Active() {
		return spec, errors.New("no isolation requested")
	}
	spec.Path = rest[0]
	spec.Argv = rest[1:]
	return spec, nil
}
