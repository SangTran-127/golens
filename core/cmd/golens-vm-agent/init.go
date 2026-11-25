//go:build linux && arm64

package main

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

const agentChildEnv = "GOLENS_AGENT_CHILD"

func isInitProcess() bool {
	return os.Getpid() == 1 && os.Getenv(agentChildEnv) == ""
}

func runInit() {
	for {
		agent := &exec.Cmd{
			Path:   os.Args[0],
			Args:   os.Args,
			Env:    append(os.Environ(), agentChildEnv+"=1"),
			Stdin:  os.Stdin,
			Stdout: os.Stdout,
			Stderr: os.Stderr,
		}
		if err := agent.Start(); err != nil {
			time.Sleep(time.Second)
			continue
		}
		reapUntilExit(agent.Process.Pid)
		time.Sleep(200 * time.Millisecond)
	}
}

func reapUntilExit(agentPid int) {
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if pid == agentPid {
			return
		}
	}
}
