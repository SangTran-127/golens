package runner

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"

	"golens/core/bridge"
)

type ManagedOptions struct {
	OnStop    func()
	OnLine    func(text string, stderr bool)
	OnExit    func(state string)
	onSuccess func() []string
}

func StartManaged(cmd *exec.Cmd, key, title, dir string, opts ManagedOptions) (int64, <-chan struct{}) {
	run := startProgramWithOptions(cmd, key, title, dir, opts)
	if run.pid == 0 {
		return 0, run.done
	}
	return run.id, run.done
}

func StartTestCommand(cmd *exec.Cmd, dir string, suiteDirs map[string]string, onStop, cleanup func()) int64 {
	run := &processRun{id: newTaskID(), done: make(chan struct{}), onStop: onStop}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	run.cmd = cmd
	beginTestRun(dir, run)

	stdout, err := cmd.StdoutPipe()
	if err == nil {
		cmd.Stderr = cmd.Stdout
		err = cmd.Start()
	}
	if err != nil {
		TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
		emitResult(TestResult{Run: run.id, Kind: "done", Status: "error"})
		close(run.done)
		endTestRun(run)
		if cleanup != nil {
			cleanup()
		}
		return run.id
	}
	bridge.Debug(fmt.Sprintf("%s (in %s)", strings.Join(cmd.Args, " "), dir))
	go func() {
		defer close(run.done)
		if cleanup != nil {
			defer cleanup()
		}
		agg := newAggregator(run.id, emitResult)
		agg.dir = dir
		agg.suiteDirs = suiteDirs
		output := &runOutputBatcher{id: run.id, emit: emitTaskLog}
		parseTestStream(stdout, agg, func(line string) { output.add(line, false) })
		output.flush()
		waitErr := cmd.Wait()
		status := "pass"
		switch {
		case run.stopped.Load():
			status = "cancelled"
		case agg.failed > 0 || waitErr != nil:
			status = "fail"
		}
		emitResult(TestResult{Run: run.id, Kind: "done", Status: status, Passed: agg.passed, Failed: agg.failed, Skipped: agg.skipped})
		endTestRun(run)
	}()
	return run.id
}
