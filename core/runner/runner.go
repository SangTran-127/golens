package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golens/core/bridge"
	"golens/core/docker"
	"golens/core/fsutil"
	"golens/core/lsp"
	"golens/core/vmexec"
)

const (
	msgOpenFolderToRun = "Open a folder to run it."
)

const (
	maxConcurrentPrograms = 8
	maxOutputLine         = 4096
	promptFlushDelay      = 40 * time.Millisecond
	runOutputFlushDelay   = 16 * time.Millisecond
	runOutputFlushBytes   = 64 << 10
)

type TargetConfig struct {
	Kind        string `json:"kind"`
	ComposeFile string `json:"composeFile,omitempty"`
	Service     string `json:"service,omitempty"`
	Host        string `json:"host,omitempty"`
	Port        int    `json:"port,omitempty"`
	WorkDir     string `json:"workDir,omitempty"`
	DebugPort   int    `json:"debugPort,omitempty"`
}

func (t *TargetConfig) IsRosetta() bool {
	return t != nil && t.Kind == "vm_amd64"
}

type RunConfig struct {
	Name             string            `json:"name"`
	EnvVars          map[string]string `json:"envVars"`
	BuildFlags       string            `json:"buildFlags"`
	Args             string            `json:"args"`
	WorkingDirectory string            `json:"workingDirectory"`
	ActiveFilePath   string            `json:"activeFilePath"`
	ActiveFile       string            `json:"activeFile"`
	Target           *TargetConfig     `json:"target,omitempty"`
	Architecture     string            `json:"architecture,omitempty"`
	MemoryLimit      string            `json:"memoryLimit,omitempty"`
	CPUQuota         string            `json:"cpuQuota,omitempty"`
}

func ParseCgroupLimits(memoryLimit, cpuQuota string) *vmexec.CgroupLimits {
	var limits vmexec.CgroupLimits
	hasLimit := false

	switch memoryLimit {
	case "128MB":
		limits.MemoryMax = 128 * 1024 * 1024
		hasLimit = true
	case "256MB":
		limits.MemoryMax = 256 * 1024 * 1024
		hasLimit = true
	case "512MB":
		limits.MemoryMax = 512 * 1024 * 1024
		hasLimit = true
	case "1GB":
		limits.MemoryMax = 1024 * 1024 * 1024
		hasLimit = true
	}

	const periodUS uint32 = 100000
	switch cpuQuota {
	case "0.25":
		limits.CPUQuotaUS = 25000
		limits.CPUPeriodUS = periodUS
		hasLimit = true
	case "0.5":
		limits.CPUQuotaUS = 50000
		limits.CPUPeriodUS = periodUS
		hasLimit = true
	case "1.0":
		limits.CPUQuotaUS = 100000
		limits.CPUPeriodUS = periodUS
		hasLimit = true
	case "2.0":
		limits.CPUQuotaUS = 200000
		limits.CPUPeriodUS = periodUS
		hasLimit = true
	}

	if !hasLimit {
		return nil
	}
	return &limits
}

type runStartedEvent struct {
	ID    int64  `json:"id"`
	Key   string `json:"key"`
	Title string `json:"title"`
	Dir   string `json:"dir"`
	State string `json:"state"`
}

type runOutputLine struct {
	Text   string `json:"text"`
	Stderr bool   `json:"stderr"`
}

type runOutputEvent struct {
	ID    int64           `json:"id"`
	Lines []runOutputLine `json:"lines"`
}

type runExitedEvent struct {
	ID        int64  `json:"id"`
	Key       string `json:"key"`
	Title     string `json:"title"`
	State     string `json:"state"`
	Error     string `json:"error"`
	OOMKilled bool   `json:"oomKilled,omitempty"`
	MemoryMax uint64 `json:"memoryMax,omitempty"`
}

func emitRunStarted(r *processRun) {
	if !bridge.HasStatus() {
		return
	}
	b, err := json.Marshal(runStartedEvent{
		ID:    r.id,
		Key:   r.key,
		Title: r.title,
		Dir:   r.dir,
		State: "started",
	})
	if err == nil {
		bridge.Status("runEvent", string(b))
	}
}

func emitRunOutput(id int64, lines []runOutputLine) {
	if !bridge.HasStatus() || len(lines) == 0 {
		return
	}
	b, err := json.Marshal(runOutputEvent{ID: id, Lines: lines})
	if err == nil {
		bridge.Status("runEvent", string(b))
	}
}

type runOutputBatcher struct {
	id      int64
	emit    func(int64, []runOutputLine)
	mu      sync.Mutex
	lines   []runOutputLine
	size    int
	timer   *time.Timer
	pending int
	drained chan struct{}
}

func (b *runOutputBatcher) add(text string, isStderr bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, runOutputLine{Text: text, Stderr: isStderr})
	b.size += len(text)
	if b.size >= runOutputFlushBytes {
		b.flushLocked()
		return
	}
	if b.timer == nil {
		b.pending++
		var t *time.Timer
		t = time.AfterFunc(runOutputFlushDelay, func() {
			b.mu.Lock()
			if b.timer == t {
				b.timer = nil
				b.flushLocked()
			}
			b.pending--
			if b.pending == 0 && b.drained != nil {
				close(b.drained)
				b.drained = nil
			}
			b.mu.Unlock()
		})
		b.timer = t
	}
}

func (b *runOutputBatcher) flush() {
	for {
		b.mu.Lock()
		b.flushLocked()
		if b.pending == 0 {
			b.mu.Unlock()
			return
		}
		ch := b.drained
		if ch == nil {
			ch = make(chan struct{})
			b.drained = ch
		}
		b.mu.Unlock()
		<-ch
	}
}

func (b *runOutputBatcher) flushLocked() {
	if b.timer != nil {
		if b.timer.Stop() {
			b.pending--
			if b.pending == 0 && b.drained != nil {
				close(b.drained)
				b.drained = nil
			}
		}
		b.timer = nil
	}
	if len(b.lines) == 0 {
		return
	}
	lines := b.lines
	b.lines = nil
	b.size = 0
	if b.emit != nil {
		b.emit(b.id, lines)
		return
	}
	emitRunOutput(b.id, lines)
}

func emitRunExited(r *processRun, state, errStr string) {
	if !bridge.HasStatus() {
		return
	}
	var oomKilled bool
	var memoryMax uint64
	if r != nil && r.vmCmd != nil {
		oomKilled = r.vmCmd.IsOOMKilled()
		if r.vmCmd.Cgroup != nil {
			memoryMax = r.vmCmd.Cgroup.MemoryMax
		}
	}
	b, err := json.Marshal(runExitedEvent{
		ID:        r.id,
		Key:       r.key,
		Title:     r.title,
		State:     state,
		Error:     errStr,
		OOMKilled: oomKilled,
		MemoryMax: memoryMax,
	})
	if err == nil {
		bridge.Status("runEvent", string(b))
	}
}

func relOrBase(workspacePath, runDir string) string {
	if workspacePath != "" {
		if rel, err := filepath.Rel(workspacePath, runDir); err == nil && rel != "." && rel != "" && !strings.HasPrefix(rel, "..") {
			return filepath.ToSlash(rel)
		}
	}
	base := filepath.Base(runDir)
	if base == "." || base == "/" || base == "" {
		return "program"
	}
	return base
}

func ExecuteGoRun(configJson string) {
	dir := lsp.GetActiveDir()
	if dir == "" {
		bridge.Log(msgOpenFolderToRun)
		return
	}
	RunWithConfig(dir, configJson)
}

func RunProject(workspacePath string) *ProcessRun {
	if workspacePath == "" {
		workspacePath = lsp.GetActiveDir()
	}
	if workspacePath == "" {
		bridge.Log(msgOpenFolderToRun)
		return nil
	}
	runDir, note := fsutil.RunDir(workspacePath, "", "")
	if note != "" {
		bridge.Log(note)
	}
	key := runDir
	title := relOrBase(workspacePath, runDir)
	guestDir := vmexec.HostToGuestPath(workspacePath, runDir)
	vmCmd := vmexec.Command("go", "run", ".")
	vmCmd.Dir = guestDir
	vmCmd.Env = vmexec.DefaultVMEnv("arm64", nil)
	bridge.Debug(fmt.Sprintf("go run . (in %s -> %s)", runDir, guestDir))
	return startVMProgramWithMeta(vmCmd, key, title, runDir)
}

func RunWithConfig(workspacePath, configJSON string) *ProcessRun {
	if workspacePath == "" {
		workspacePath = lsp.GetActiveDir()
	}
	if workspacePath == "" {
		bridge.Log(msgOpenFolderToRun)
		return nil
	}

	var config RunConfig
	if configJSON != "" {
		if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
			bridge.Debug(fmt.Sprintf("invalid run configuration: %v", err))
		}
	}

	activeFile := config.ActiveFile
	if activeFile == "" {
		activeFile = config.ActiveFilePath
	}

	args := []string{"run"}
	if config.BuildFlags != "" {
		args = append(args, fsutil.SplitArgs(config.BuildFlags)...)
	}
	args = append(args, ".")
	if config.Args != "" {
		args = append(args, fsutil.SplitArgs(config.Args)...)
	}

	runDir, note := fsutil.RunDir(workspacePath, config.WorkingDirectory, activeFile)
	if note != "" {
		bridge.Log(note)
	}

	rosetta := config.Architecture == "amd64" || (config.Target != nil && config.Target.IsRosetta()) || (config.EnvVars != nil && config.EnvVars["GOARCH"] == "amd64")
	goarch := "arm64"
	if rosetta {
		goarch = "amd64"
	}

	guestDir := vmexec.HostToGuestPath(workspacePath, runDir)
	vmCmd := vmexec.Command("go", args...)
	hostEnv := os.Environ()
	hostEnv = append(hostEnv, "PWD="+runDir)
	for k, v := range config.EnvVars {
		hostEnv = append(hostEnv, fmt.Sprintf("%s=%s", k, v))
	}
	vmCmd.HostEnv = hostEnv
	vmCmd.Dir = guestDir
	vmCmd.Rosetta = rosetta
	vmCmd.Env = vmexec.DefaultVMEnv(goarch, config.EnvVars)
	vmCmd.Cgroup = ParseCgroupLimits(config.MemoryLimit, config.CPUQuota)
	vmCmd.EnableTelemetry = true
	vmCmd.OnTelemetry = func(payload []byte) {
		if bridge.HasStatus() {
			bridge.Status("kernelTelemetry", string(payload))
		}
	}
	bridge.Debug(fmt.Sprintf("go %s (in %s -> %s)", strings.Join(args, " "), runDir, guestDir))

	key := runDir
	title := relOrBase(workspacePath, runDir)
	if config.Name != "" {
		key = "config:" + config.Name
		title = config.Name
	}
	return startVMProgramWithMeta(vmCmd, key, title, runDir)
}

func RunGoCommand(args []string) {
	dir := lsp.GetActiveDir()
	if dir == "" {
		bridge.Log("Open a folder first.")
		return
	}
	guestDir := vmexec.HostToGuestPath(dir, dir)
	vmCmd := vmexec.Command("go", args...)
	vmCmd.Dir = guestDir
	vmCmd.Env = vmexec.DefaultVMEnv("arm64", nil)
	label := "go " + strings.Join(args, " ")
	bridge.Debug(fmt.Sprintf("%s (in %s -> %s)", label, dir, guestDir))
	startVMProgramWithMeta(vmCmd, "cmd:"+label, label, dir)
}

var (
	programMu   sync.Mutex
	programs    = map[int64]*processRun{}
	latestRunID int64
)

func startVMProgramWithMeta(cmd *vmexec.Cmd, key, title, dir string) *processRun {
	return startVMProgramWithOptions(cmd, key, title, dir, ManagedOptions{})
}

func startVMProgramWithOptions(cmd *vmexec.Cmd, key, title, dir string, opts ManagedOptions) *processRun {
	onSuccess := opts.onSuccess
	var toStop []*processRun
	programMu.Lock()
	for id, r := range programs {
		if r.key == key {
			toStop = append(toStop, r)
			delete(programs, id)
		}
	}
	for len(programs) >= maxConcurrentPrograms {
		var oldestID int64
		var oldest *processRun
		for id, r := range programs {
			if oldest == nil || id < oldestID {
				oldestID = id
				oldest = r
			}
		}
		if oldest == nil {
			break
		}
		toStop = append(toStop, oldest)
		delete(programs, oldestID)
	}
	runID := newTaskID()
	programMu.Unlock()

	for _, r := range toStop {
		r.stop()
	}

	stdoutPipe, _ := cmd.StdoutPipe()
	stderrPipe, _ := cmd.StderrPipe()
	stdinPipe, _ := cmd.StdinPipe()
	run := &processRun{
		id:     runID,
		key:    key,
		title:  title,
		dir:    dir,
		vmCmd:  cmd,
		stdin:  stdinPipe,
		done:   make(chan struct{}),
		onStop: opts.OnStop,
	}
	if err := cmd.Start(); err != nil {
		if bridge.CanFallbackToHost(err) {
			hostArgs := cmd.Args[1:]
			if len(cmd.HostArgs) > 0 {
				hostArgs = cmd.HostArgs
			}
			hostCmd := exec.Command(cmd.Path, hostArgs...)
			hostCmd.Dir = dir
			if len(cmd.HostEnv) > 0 {
				hostCmd.Env = cmd.HostEnv
			}
			return startProgramWithOptions(hostCmd, key, title, dir, opts)
		}
		run.exitErr = err
		_ = run.closeStdin()
		close(run.done)
		emitRunExited(run, "failed", err.Error())
		if opts.OnExit != nil {
			opts.OnExit("failed")
		}
		TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
		return run
	}

	programMu.Lock()
	programs[run.id] = run
	latestRunID = run.id
	programMu.Unlock()

	emitRunStarted(run)

	go func() {
		defer close(run.done)
		output := &runOutputBatcher{id: run.id}
		defer output.flush()
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			streamLines(stdoutPipe, func(line string) {
				if opts.OnLine != nil {
					opts.OnLine(line, false)
				}
				output.add(line, false)
			})
		}()
		go func() {
			defer wg.Done()
			streamLines(stderrPipe, func(line string) {
				if opts.OnLine != nil {
					opts.OnLine(line, true)
				}
				output.add(line, true)
			})
		}()
		wg.Wait()
		output.flush()
		err := cmd.Wait()
		_ = run.closeStdin()
		run.exitErr = err
		programMu.Lock()
		delete(programs, run.id)
		if latestRunID == run.id {
			var maxID int64
			for id := range programs {
				if id > maxID {
					maxID = id
				}
			}
			latestRunID = maxID
		}
		programMu.Unlock()
		if opts.OnExit != nil {
			state := "exited"
			if run.stopped.Load() {
				state = "stopped"
			} else if err != nil {
				state = "failed"
			}
			defer opts.OnExit(state)
		}
		switch {
		case run.stopped.Load():
			emitRunExited(run, "stopped", "")
			TaskLog(run.id, "Process stopped.", false)
		case err != nil:
			errMsg := err.Error()
			if cmd.IsOOMKilled() {
				errMsg = "OOMKilled: memory limit exceeded"
				TaskLog(run.id, "Process terminated by Linux OOM Killer (cgroups memory limit exceeded).", false)
			} else {
				TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
			}
			emitRunExited(run, "failed", errMsg)
		default:
			if onSuccess != nil {
				var lines []runOutputLine
				for _, text := range onSuccess() {
					lines = append(lines, runOutputLine{Text: text})
				}
				emitRunOutput(run.id, lines)
			}
			emitRunExited(run, "exited", "")
			TaskLog(run.id, "Process exited successfully.", false)
		}
	}()
	return run
}

func startProgram(cmd *exec.Cmd) *processRun {
	dir := cmd.Dir
	key := dir
	if key == "" {
		key = "default"
	}
	title := filepath.Base(dir)
	if dir == "" || title == "." || title == "/" {
		title = filepath.Base(cmd.Path)
	}
	return startProgramWithMeta(cmd, key, title, dir)
}

func startProgramWithMeta(cmd *exec.Cmd, key, title, dir string) *processRun {
	return startProgramWithHook(cmd, key, title, dir, nil)
}

func startProgramWithHook(cmd *exec.Cmd, key, title, dir string, onSuccess func() []string) *processRun {
	return startProgramWithOptions(cmd, key, title, dir, ManagedOptions{onSuccess: onSuccess})
}

func startProgramWithOptions(cmd *exec.Cmd, key, title, dir string, opts ManagedOptions) *processRun {
	onSuccess := opts.onSuccess
	var toStop []*processRun
	programMu.Lock()
	for id, r := range programs {
		if r.key == key {
			toStop = append(toStop, r)
			delete(programs, id)
		}
	}
	for len(programs) >= maxConcurrentPrograms {
		var oldestID int64
		var oldest *processRun
		for id, r := range programs {
			if oldest == nil || id < oldestID {
				oldestID = id
				oldest = r
			}
		}
		if oldest == nil {
			break
		}
		toStop = append(toStop, oldest)
		delete(programs, oldestID)
	}
	runID := newTaskID()
	programMu.Unlock()

	for _, r := range toStop {
		r.stop()
	}

	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdoutPipe, _ := cmd.StdoutPipe()
	stderrPipe, _ := cmd.StderrPipe()
	stdinPipe, _ := cmd.StdinPipe()
	run := &processRun{
		id:     runID,
		key:    key,
		title:  title,
		dir:    dir,
		cmd:    cmd,
		stdin:  stdinPipe,
		done:   make(chan struct{}),
		onStop: opts.OnStop,
	}
	if err := cmd.Start(); err != nil {
		run.exitErr = err
		_ = run.closeStdin()
		close(run.done)
		emitRunExited(run, "failed", err.Error())
		if opts.OnExit != nil {
			opts.OnExit("failed")
		}
		TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
		return run
	}
	run.pid = cmd.Process.Pid

	programMu.Lock()
	programs[run.id] = run
	latestRunID = run.id
	programMu.Unlock()

	emitRunStarted(run)

	go func() {
		defer close(run.done)
		output := &runOutputBatcher{id: run.id}
		defer output.flush()
		var wg sync.WaitGroup
		wg.Go(func() {
			streamLines(stdoutPipe, func(line string) {
				if opts.OnLine != nil {
					opts.OnLine(line, false)
				}
				output.add(line, false)
			})
		})
		wg.Go(func() {
			streamLines(stderrPipe, func(line string) {
				if opts.OnLine != nil {
					opts.OnLine(line, true)
				}
				output.add(line, true)
			})
		})
		wg.Wait()
		output.flush()
		err := cmd.Wait()
		_ = run.closeStdin()
		run.exitErr = err
		programMu.Lock()
		delete(programs, run.id)
		if latestRunID == run.id {
			var maxID int64
			for id := range programs {
				if id > maxID {
					maxID = id
				}
			}
			latestRunID = maxID
		}
		programMu.Unlock()
		if opts.OnExit != nil {
			state := "exited"
			if run.stopped.Load() {
				state = "stopped"
			} else if err != nil {
				state = "failed"
			}
			defer opts.OnExit(state)
		}
		switch {
		case run.stopped.Load():
			emitRunExited(run, "stopped", "")
			TaskLog(run.id, "Process stopped.", false)
		case err != nil:
			emitRunExited(run, "failed", err.Error())
			TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
		default:
			if onSuccess != nil {
				var lines []runOutputLine
				for _, text := range onSuccess() {
					lines = append(lines, runOutputLine{Text: text})
				}
				emitRunOutput(run.id, lines)
			}
			emitRunExited(run, "exited", "")
			TaskLog(run.id, "Process exited successfully.", false)
		}
	}()
	return run
}

func RunExternalCommand(argvJSON, dir, title, key string) int64 {
	var argv []string
	if err := json.Unmarshal([]byte(argvJSON), &argv); err != nil || len(argv) == 0 || argv[0] == "" {
		bridge.Log("Couldn’t run the command: its arguments are not a JSON array of strings.")
		return 0
	}
	bin := docker.LookPath(argv[0])
	if bin == "" {
		bridge.Log(fmt.Sprintf("Couldn’t run %s: it was not found on PATH.", argv[0]))
		return 0
	}
	if dir == "" {
		dir = lsp.GetActiveDir()
	}
	if st, err := os.Stat(dir); dir != "" && (err != nil || !st.IsDir()) {
		bridge.Log(fmt.Sprintf("Couldn’t run %s: folder %s doesn’t exist.", argv[0], dir))
		return 0
	}
	if title == "" {
		title = strings.Join(argv, " ")
	}
	if key == "" {
		key = "ext:" + title
	}
	cmd := exec.Command(bin, argv[1:]...)
	cmd.Dir = dir
	cmd.Env = docker.Env()
	bridge.Debug(fmt.Sprintf("%s (in %s)", strings.Join(argv, " "), dir))
	run := startProgramWithHook(cmd, key, title, dir, docker.BuildSummaryHook(bin, argv))
	if run.pid == 0 {
		return 0
	}
	return run.id
}

func lookupProgram(runID int64) *processRun {
	programMu.Lock()
	defer programMu.Unlock()
	if runID <= 0 {
		runID = latestRunID
	}
	return programs[runID]
}

func WriteProgramStdin(runID int64, data string) error {
	run := lookupProgram(runID)
	if run == nil {
		return fmt.Errorf("no active program for run %d", runID)
	}
	if run.stopped.Load() {
		return fmt.Errorf("stdin is closed for run %d", run.id)
	}
	run.stdinMu.Lock()
	stdin := run.stdin
	run.stdinMu.Unlock()
	if stdin == nil {
		return fmt.Errorf("stdin is closed for run %d", run.id)
	}
	_, err := io.WriteString(stdin, data)
	return err
}

func CloseProgramStdin(runID int64) error {
	run := lookupProgram(runID)
	if run == nil {
		return fmt.Errorf("no active program for run %d", runID)
	}
	return run.closeStdin()
}

func StopProgramRun(runID int64) {
	if runID > 0 {
		programMu.Lock()
		run := programs[runID]
		programMu.Unlock()
		if run != nil {
			run.stop()
		}
		return
	}
	programMu.Lock()
	runs := make([]*processRun, 0, len(programs))
	for _, r := range programs {
		runs = append(runs, r)
	}
	programMu.Unlock()
	var wg sync.WaitGroup
	for _, r := range runs {
		wg.Go(func() { r.stop() })
	}
	wg.Wait()
}

func StopRun() {
	StopProgramRun(0)
}

type readChunk struct {
	buf []byte
	n   int
	err error
}

func streamLines(r io.Reader, emit func(string)) {
	if r == nil {
		return
	}
	ch := make(chan readChunk, 2)
	free := make(chan []byte, 2)
	free <- make([]byte, 32<<10)
	free <- make([]byte, 32<<10)

	go func() {
		defer close(ch)
		for {
			buf := <-free
			n, err := r.Read(buf)
			ch <- readChunk{buf: buf, n: n, err: err}
			if err != nil {
				return
			}
		}
	}()

	var (
		pending    = make([]byte, 0, 256)
		overflow   bool
		hasPending bool
		timer      *time.Timer
	)
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()

	appendPending := func(part []byte) {
		if len(pending) < maxOutputLine {
			rem := maxOutputLine - len(pending)
			if len(part) > rem {
				pending = append(pending, part[:rem]...)
				overflow = true
			} else {
				pending = append(pending, part...)
			}
		} else if len(part) > 0 {
			overflow = true
		}
	}

	flushPending := func() {
		if !hasPending {
			return
		}
		text := strings.TrimRight(string(pending), "\r\n")
		if overflow {
			text += "…"
		}
		emit(text)
		pending = pending[:0]
		overflow = false
		hasPending = false
	}

	processChunk := func(c readChunk) bool {
		data := c.buf[:c.n]
		for len(data) > 0 {
			idx := bytes.IndexByte(data, '\n')
			if idx >= 0 {
				appendPending(data[:idx])
				hasPending = true
				flushPending()
				data = data[idx+1:]
			} else {
				appendPending(data)
				hasPending = true
				data = nil
			}
		}
		free <- c.buf
		if c.err != nil {
			flushPending()
			return false
		}
		return true
	}

	for {
		if !hasPending {
			c, ok := <-ch
			if !ok {
				return
			}
			if !processChunk(c) {
				return
			}
			continue
		}

		select {
		case c, ok := <-ch:
			if !ok {
				flushPending()
				return
			}
			if !processChunk(c) {
				return
			}
			continue
		default:
		}

		if timer == nil {
			timer = time.NewTimer(promptFlushDelay)
		} else {
			timer.Reset(promptFlushDelay)
		}

		select {
		case c, ok := <-ch:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			if !ok {
				flushPending()
				return
			}
			if !processChunk(c) {
				return
			}
		case <-timer.C:
			flushPending()
		}
	}
}
