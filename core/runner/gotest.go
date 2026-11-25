package runner

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golens/core/bridge"
	"golens/core/lsp"
	"golens/core/testutil"
	"golens/core/vmexec"
)

const maxTestOutputLines = 200

type testEvent struct {
	Action  string  `json:"Action"`
	Package string  `json:"Package"`
	Test    string  `json:"Test"`
	Elapsed float64 `json:"Elapsed"`
	Output  string  `json:"Output"`
}

type FileCoverageData = testutil.FileCoverage

type TestResult struct {
	Run             int64                            `json:"run"`
	Kind            string                           `json:"kind"`
	Package         string                           `json:"package,omitempty"`
	Test            string                           `json:"test,omitempty"`
	Status          string                           `json:"status,omitempty"`
	Elapsed         float64                          `json:"elapsed,omitempty"`
	Output          []string                         `json:"output,omitempty"`
	Failures        []testutil.TestFailureAnnotation `json:"failures,omitempty"`
	Passed          int                              `json:"passed,omitempty"`
	Failed          int                              `json:"failed,omitempty"`
	Skipped         int                              `json:"skipped,omitempty"`
	PackageCoverage map[string]float64               `json:"packageCoverage,omitempty"`
	FilesCoverage   []FileCoverageData               `json:"filesCoverage,omitempty"`
	ProfileFiles    map[string][]string              `json:"profileFiles,omitempty"`
	CPUProfile      []testutil.ProfileEntry          `json:"cpuProfile,omitempty"`
	MemProfile      []testutil.ProfileEntry          `json:"memProfile,omitempty"`
	BlockProfile    []testutil.ProfileEntry          `json:"blockProfile,omitempty"`
	MutexProfile    []testutil.ProfileEntry          `json:"mutexProfile,omitempty"`
	BenchMetric     string                           `json:"benchMetric,omitempty"`
}

var TestEvent = func(string) {
}

type ProcessRun struct {
	id       int64
	key      string
	title    string
	dir      string
	cmd      *exec.Cmd
	vmCmd    *vmexec.Cmd
	pid      int
	done     chan struct{}
	stopped  atomic.Bool
	exitErr  error
	stdin    io.WriteCloser
	stdinMu  sync.Mutex
	onStop   func()
	stopHook sync.Once
}

type processRun = ProcessRun

func (r *processRun) closeStdin() error {
	if r == nil {
		return nil
	}
	r.stdinMu.Lock()
	stdin := r.stdin
	r.stdin = nil
	r.stdinMu.Unlock()
	if stdin == nil {
		return nil
	}
	if dl, ok := stdin.(interface{ SetWriteDeadline(time.Time) error }); ok {
		_ = dl.SetWriteDeadline(time.Now())
	}
	return stdin.Close()
}

func (r *processRun) stop() {
	if r == nil {
		return
	}
	r.stopped.Store(true)
	if r.onStop != nil {
		r.stopHook.Do(r.onStop)
	}
	go func() {
		_ = r.closeStdin()
	}()
	if r.vmCmd != nil {
		r.vmCmd.Cancel()
		select {
		case <-r.done:
		case <-time.After(2 * time.Second):
		}
		return
	}
	if r.cmd == nil || r.cmd.Process == nil {
		return
	}
	pid := r.cmd.Process.Pid
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	select {
	case <-r.done:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		select {
		case <-r.done:
		case <-time.After(2 * time.Second):
		}
	}
}

var (
	testMu     sync.Mutex
	currentRun *processRun
	testRuns   = map[int64]*processRun{}
)

func beginTestRun(dir string, run *processRun) {
	root := lsp.OwningRoot(dir)
	if root == "" {
		root = dir
	}
	run.key = root
	var replaced []*processRun
	testMu.Lock()
	for id, r := range testRuns {
		if r.key == root {
			replaced = append(replaced, r)
			delete(testRuns, id)
		}
	}
	testMu.Unlock()
	for _, r := range replaced {
		r.stop()
	}
	testMu.Lock()
	testRuns[run.id] = run
	currentRun = run
	testMu.Unlock()
	emitTaskStarted(run.id, "test", dir)
}

func endTestRun(run *processRun) {
	testMu.Lock()
	delete(testRuns, run.id)
	if currentRun == run {
		currentRun = nil
	}
	testMu.Unlock()
}

func StopTestRun(id int64) {
	testMu.Lock()
	run := testRuns[id]
	delete(testRuns, id)
	if currentRun == run {
		currentRun = nil
	}
	testMu.Unlock()
	run.stop()
}

func testArgs(pattern string, pkgs []string) []string {
	return testArgsWithCover(pattern, pkgs, "")
}

func testArgsWithCover(pattern string, pkgs []string, coverFile string) []string {
	return testArgsWithProfile(pattern, pkgs, coverFile, "", "")
}

func testArgsWithProfile(pattern string, pkgs []string, coverFile, cpuFile, memFile string) []string {
	return testArgsFull(pattern, "", pkgs, coverFile, cpuFile, memFile)
}

type goTestRunOptions struct {
	dir          string
	pattern      string
	benchPattern string
	fuzzPattern  string
	fuzzTime     string
	pkgs         []string
	cover        bool
	profile      bool
	short        bool
	coverFile    string
	cpuFile      string
	memFile      string
	blockFile    string
	mutexFile    string
	target       *TargetConfig
	architecture string
}

func testArgsFull(pattern, benchPattern string, pkgs []string, coverFile, cpuFile, memFile string) []string {
	return testArgsWithFuzz(goTestRunOptions{
		pattern:      pattern,
		benchPattern: benchPattern,
		pkgs:         pkgs,
		coverFile:    coverFile,
		cpuFile:      cpuFile,
		memFile:      memFile,
	})
}

func testArgsFullWithContention(pattern, benchPattern string, pkgs []string, coverFile, cpuFile, memFile, blockFile, mutexFile string) []string {
	return testArgsWithFuzz(goTestRunOptions{
		pattern:      pattern,
		benchPattern: benchPattern,
		pkgs:         pkgs,
		coverFile:    coverFile,
		cpuFile:      cpuFile,
		memFile:      memFile,
		blockFile:    blockFile,
		mutexFile:    mutexFile,
	})
}

func testArgsWithFuzz(opts goTestRunOptions) []string {
	args := []string{"test", "-json"}
	if opts.short {
		args = append(args, "-short")
	}
	if opts.coverFile != "" {
		args = append(args, "-covermode=atomic", "-coverprofile="+opts.coverFile)
	}
	if opts.cpuFile != "" {
		args = append(args, "-cpuprofile="+opts.cpuFile)
	}
	if opts.memFile != "" {
		args = append(args, "-memprofile="+opts.memFile, "-memprofilerate=1")
	}
	if opts.blockFile != "" {
		args = append(args, "-blockprofile="+opts.blockFile, "-blockprofilerate=1")
	}
	if opts.mutexFile != "" {
		args = append(args, "-mutexprofile="+opts.mutexFile, "-mutexprofilefraction=1")
	}
	if opts.fuzzPattern != "" {
		fuzzTime := opts.fuzzTime
		if fuzzTime == "" {
			fuzzTime = "5s"
		}
		args = append(args, "-run=^$", "-fuzz="+opts.fuzzPattern, "-fuzztime="+fuzzTime)
	} else if opts.benchPattern != "" {
		args = append(args, "-run=^$", "-bench="+opts.benchPattern, "-benchmem")
	} else if opts.pattern != "" {
		args = append(args, "-run", opts.pattern)
	}
	pkgs := opts.pkgs
	if len(pkgs) == 0 {
		pkgs = []string{"."}
	}
	return append(args, pkgs...)
}

type TestRequest struct {
	Dir             string        `json:"dir"`
	Packages        []string      `json:"packages"`
	Test            string        `json:"test"`
	Row             string        `json:"row"`
	PatternOverride string        `json:"pattern,omitempty"`
	Failed          []string      `json:"failed"`
	Cover           bool          `json:"cover"`
	Profile         bool          `json:"profile"`
	Bench           bool          `json:"bench"`
	Fuzz            bool          `json:"fuzz"`
	FuzzTime        string        `json:"fuzzTime"`
	Short           bool          `json:"short"`
	Target          *TargetConfig `json:"target,omitempty"`
	Architecture    string        `json:"architecture,omitempty"`
}

func (r TestRequest) isBench() bool {
	return r.Bench || strings.HasPrefix(r.Test, "Benchmark")
}

func (r TestRequest) isFuzz() bool {
	return r.Fuzz || (strings.HasPrefix(r.Test, "Fuzz") && r.Row == "")
}

func (r TestRequest) FuzzPattern() string {
	if !r.isFuzz() || r.Test == "" {
		return ""
	}
	return "^" + regexp.QuoteMeta(r.Test) + "$"
}

func (r TestRequest) effectiveFuzzTime() string {
	if r.FuzzTime != "" {
		return r.FuzzTime
	}
	return "5s"
}

func (r TestRequest) BenchPattern() string {
	if !r.isBench() {
		return ""
	}
	if r.Test != "" {
		return r.Pattern()
	}
	return "."
}

func (r TestRequest) Pattern() string {
	switch {
	case len(r.Failed) > 0:
		return testutil.FailedSubtestPattern(r.Failed)
	case r.PatternOverride != "":
		return r.PatternOverride
	case r.Test != "" && r.Row != "":
		return testutil.RunPattern(r.Test, r.Row)
	case r.Test != "":
		return testutil.RunPattern(r.Test)
	}
	return ""
}

func RunTests(requestJSON string) int64 {
	var req TestRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil || req.Dir == "" {
		bridge.Debug(fmt.Sprintf("invalid test request: %v", err))
		return 0
	}
	return runGoTestWithOptions(goTestRunOptions{
		dir:          req.Dir,
		pattern:      req.Pattern(),
		benchPattern: req.BenchPattern(),
		fuzzPattern:  req.FuzzPattern(),
		fuzzTime:     req.effectiveFuzzTime(),
		pkgs:         req.Packages,
		cover:        req.Cover,
		profile:      req.Profile,
		short:        req.Short,
		target:       req.Target,
		architecture: req.Architecture,
	})
}

func parseBenchmarkOutputLine(line string) (benchName string, metric string, ok bool) {
	trimmed := strings.TrimSpace(line)
	if !strings.HasPrefix(trimmed, "Benchmark") {
		return "", "", false
	}
	fields := strings.Fields(trimmed)
	if len(fields) < 4 {
		return "", "", false
	}
	benchName = fields[0]
	if dash := strings.LastIndexByte(benchName, '-'); dash >= len("Benchmark") && dash+1 < len(benchName) {
		allDigits := true
		for i := dash + 1; i < len(benchName); i++ {
			if benchName[i] < '0' || benchName[i] > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			benchName = benchName[:dash]
		}
	}
	if rest := benchName[len("Benchmark"):]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return "", "", false
	}
	iters, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil || iters <= 0 {
		return "", "", false
	}
	if !strings.HasSuffix(fields[3], "/op") {
		return "", "", false
	}
	var metrics []string
	for i := 2; i+1 < len(fields); i += 2 {
		if strings.HasSuffix(fields[i+1], "/op") {
			metrics = append(metrics, fields[i]+" "+fields[i+1])
		}
	}
	if len(metrics) == 0 {
		return "", "", false
	}
	return benchName, strings.Join(metrics, " · "), true
}

type aggregator struct {
	run           int64
	workspaceRoot string
	dir           string
	suiteDirs     map[string]string
	outputs       map[string][]string
	passed        int
	failed        int
	skipped       int
	emit          func(TestResult)
	hasSubtests   map[string]bool
	subtestFails  map[string]bool
	benchPassed   map[string]bool
}

func newAggregator(run int64, emit func(TestResult)) *aggregator {
	return &aggregator{
		run:          run,
		outputs:      map[string][]string{},
		hasSubtests:  map[string]bool{},
		subtestFails: map[string]bool{},
		benchPassed:  map[string]bool{},
		emit:         emit,
	}
}

func (a *aggregator) markAncestors(pkg, test string, m map[string]bool) {
	for i := strings.LastIndexByte(test, '/'); i > 0; i = strings.LastIndexByte(test[:i], '/') {
		m[pkg+"\x00"+test[:i]] = true
	}
}

func (a *aggregator) feed(ev testEvent) {
	a.handle(ev)
}

func (a *aggregator) handle(ev testEvent) {
	key := ev.Package + "\x00" + ev.Test
	switch ev.Action {
	case "output":
		if ev.Test != "" {
			if out := a.outputs[key]; len(out) < maxTestOutputLines {
				a.outputs[key] = append(out, strings.TrimRight(ev.Output, "\n"))
			}
		}
		if benchName, metric, ok := parseBenchmarkOutputLine(ev.Output); ok {
			if strings.Contains(benchName, "/") {
				a.markAncestors(ev.Package, benchName, a.hasSubtests)
			}
			benchKey := ev.Package + "\x00" + benchName
			if !a.benchPassed[benchKey] {
				a.benchPassed[benchKey] = true
				a.passed++
			}
			a.emit(TestResult{
				Run:         a.run,
				Kind:        "test",
				Package:     ev.Package,
				Test:        benchName,
				Status:      "pass",
				BenchMetric: metric,
			})
			for i := strings.LastIndexByte(benchName, '/'); i > 0; i = strings.LastIndexByte(benchName[:i], '/') {
				a.emit(TestResult{
					Run:     a.run,
					Kind:    "test",
					Package: ev.Package,
					Test:    benchName[:i],
					Status:  "pass",
				})
			}
		}
	case "run":
		a.markAncestors(ev.Package, ev.Test, a.hasSubtests)
		a.emit(TestResult{Run: a.run, Kind: "test", Package: ev.Package, Test: ev.Test, Status: "running"})
	case "pass", "fail", "skip":
		if ev.Test == "" {
			return
		}
		if ev.Action == "fail" {
			a.markAncestors(ev.Package, ev.Test, a.subtestFails)
		}
		switch {
		case a.hasSubtests[key]:
			if ev.Action == "fail" && !a.subtestFails[key] {
				a.failed++
			}
		case ev.Action == "pass":
			if !a.benchPassed[key] {
				a.benchPassed[key] = true
				a.passed++
			}
		case ev.Action == "fail":
			a.failed++
		case ev.Action == "skip":
			a.skipped++
		}
		r := TestResult{Run: a.run, Kind: "test", Package: ev.Package, Test: ev.Test, Status: ev.Action, Elapsed: ev.Elapsed}
		if ev.Action == "fail" {
			r.Output = a.outputs[key]
			pkgDir := a.dir
			if a.suiteDirs != nil && a.suiteDirs[ev.Package] != "" {
				pkgDir = a.suiteDirs[ev.Package]
			}
			r.Failures = testutil.ParseTestFailureLocations(pkgDir, ev.Test, r.Output)
			for i := range r.Failures {
				r.Failures[i].File = vmexec.GuestToHostPath(a.workspaceRoot, r.Failures[i].File)
			}
		}
		delete(a.outputs, key)
		a.emit(r)
	}
}

func parseTestStream(r io.Reader, a *aggregator, line func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var ev testEvent
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil || ev.Action == "" {
			line(sc.Text())
			continue
		}
		if ev.Action == "output" || ev.Action == "build-output" {
			line(strings.TrimRight(ev.Output, "\n"))
		}
		a.handle(ev)
	}
}

func emitResult(r TestResult) {
	if b, err := json.Marshal(r); err == nil {
		TestEvent(string(b))
	}
}

func RunTestsJSON(dir, pattern string, pkgs []string) int64 {
	return runGoTest(dir, pattern, pkgs, false, false)
}

func createTempPath(pattern string) string {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return ""
	}
	name := f.Name()
	_ = f.Close()
	return name
}

func createSharedTempPath(workspaceRoot, pattern string) (hostPath, guestPath string) {
	if workspaceRoot == "" {
		workspaceRoot = lsp.GetActiveDir()
	}
	tmpDir := filepath.Join(workspaceRoot, ".golens", "tmp")
	_ = os.MkdirAll(tmpDir, 0o755)
	f, err := os.CreateTemp(tmpDir, pattern)
	if err != nil {
		f, err = os.CreateTemp("", pattern)
		if err != nil {
			return "", ""
		}
		hostPath = f.Name()
		_ = f.Close()
		return hostPath, hostPath
	}
	hostPath = f.Name()
	_ = f.Close()
	guestPath = vmexec.HostToGuestPath(workspaceRoot, hostPath)
	return hostPath, guestPath
}

func resolveProfileTargets(dir string, pkgs []string) ([]string, map[string]string) {
	var suites []testutil.GoTestSuite
	_ = json.Unmarshal([]byte(testutil.DiscoverTests(dir)), &suites)
	suiteDirs := make(map[string]string, len(suites))
	for _, s := range suites {
		pkgDir := dir
		if s.Dir != "" && s.Dir != "." {
			pkgDir = filepath.Join(dir, s.Dir)
		}
		if s.ImportPath != "" {
			suiteDirs[s.ImportPath] = pkgDir
		}
	}

	if len(pkgs) == 1 && pkgs[0] == "./..." {
		var pkgDirs []string
		seen := make(map[string]bool, len(suites))
		for _, s := range suites {
			pkgDir := dir
			if s.Dir != "" && s.Dir != "." {
				pkgDir = filepath.Join(dir, s.Dir)
			}
			if !seen[pkgDir] {
				seen[pkgDir] = true
				pkgDirs = append(pkgDirs, pkgDir)
			}
		}
		if len(pkgDirs) == 0 {
			pkgDirs = []string{dir}
		}
		return pkgDirs, suiteDirs
	}

	if len(pkgs) == 0 || (len(pkgs) == 1 && pkgs[0] == ".") {
		return []string{dir}, suiteDirs
	}

	var pkgDirs []string
	seen := make(map[string]bool, len(pkgs))
	for _, p := range pkgs {
		pkgDir := dir
		if p != "" && p != "." {
			if filepath.IsAbs(p) {
				pkgDir = p
			} else {
				pkgDir = filepath.Join(dir, p)
			}
		}
		if !seen[pkgDir] {
			seen[pkgDir] = true
			pkgDirs = append(pkgDirs, pkgDir)
		}
	}
	if len(pkgDirs) == 0 {
		pkgDirs = []string{dir}
	}
	return pkgDirs, suiteDirs
}

func runGoTest(dir, pattern string, pkgs []string, cover bool, profile bool) int64 {
	return runGoTestWithBench(dir, pattern, "", pkgs, cover, profile)
}

func runGoTestWithBench(dir, pattern, benchPattern string, pkgs []string, cover bool, profile bool) int64 {
	return runGoTestWithOptions(goTestRunOptions{
		dir:          dir,
		pattern:      pattern,
		benchPattern: benchPattern,
		pkgs:         pkgs,
		cover:        cover,
		profile:      profile,
	})
}

func runGoTestWithOptions(opts goTestRunOptions) int64 {
	dir := opts.dir
	pattern := opts.pattern
	benchPattern := opts.benchPattern
	cover := opts.cover
	profile := opts.profile

	workspaceRoot := dir
	if workspaceRoot == "" {
		workspaceRoot = lsp.GetActiveDir()
	}

	rosetta := opts.architecture == "amd64" || (opts.target != nil && opts.target.IsRosetta())
	goarch := "arm64"
	if rosetta {
		goarch = "amd64"
	}

	var coverFile, cpuFile, memFile, blockFile, mutexFile string
	var guestCoverFile, guestCPUFile, guestMemFile, guestBlockFile, guestMutexFile string

	if opts.cover {
		coverFile, guestCoverFile = createSharedTempPath(workspaceRoot, "golens-cover-*.out")
	}
	var pkgDirs []string
	var suiteDirs map[string]string
	runDir := opts.dir
	runPkgs := opts.pkgs
	if opts.profile {
		pkgDirs, suiteDirs = resolveProfileTargets(opts.dir, opts.pkgs)
		runDir = pkgDirs[0]
		runPkgs = []string{"."}
		cpuFile, guestCPUFile = createSharedTempPath(workspaceRoot, "golens-cpu-*.pprof")
		memFile, guestMemFile = createSharedTempPath(workspaceRoot, "golens-mem-*.pprof")
		blockFile, guestBlockFile = createSharedTempPath(workspaceRoot, "golens-block-*.pprof")
		mutexFile, guestMutexFile = createSharedTempPath(workspaceRoot, "golens-mutex-*.pprof")
	}

	hostArgs := testArgsWithFuzz(goTestRunOptions{
		pattern:      opts.pattern,
		benchPattern: opts.benchPattern,
		fuzzPattern:  opts.fuzzPattern,
		fuzzTime:     opts.fuzzTime,
		pkgs:         runPkgs,
		coverFile:    coverFile,
		cpuFile:      cpuFile,
		memFile:      memFile,
		blockFile:    blockFile,
		mutexFile:    mutexFile,
		short:        opts.short,
	})
	args := testArgsWithFuzz(goTestRunOptions{
		pattern:      opts.pattern,
		benchPattern: opts.benchPattern,
		fuzzPattern:  opts.fuzzPattern,
		fuzzTime:     opts.fuzzTime,
		pkgs:         runPkgs,
		coverFile:    guestCoverFile,
		cpuFile:      guestCPUFile,
		memFile:      guestMemFile,
		blockFile:    guestBlockFile,
		mutexFile:    guestMutexFile,
		short:        opts.short,
	})

	guestRunDir := vmexec.HostToGuestPath(workspaceRoot, runDir)
	vmCmd := vmexec.Command("go", args...)
	vmCmd.Dir = guestRunDir
	vmCmd.Rosetta = rosetta
	vmCmd.Env = vmexec.DefaultVMEnv(goarch, nil)

	run := &processRun{id: newTaskID(), vmCmd: vmCmd, dir: runDir, done: make(chan struct{})}
	beginTestRun(workspaceRoot, run)

	stdout, err := vmCmd.StdoutPipe()
	if err == nil {
		vmCmd.Stderr = vmCmd.Stdout
		err = vmCmd.Start()
	}
	if err != nil && bridge.CanFallbackToHost(err) {
		hostCmd := exec.Command("go", hostArgs...)
		hostCmd.Dir = runDir
		hostCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		testMu.Lock()
		run.cmd = hostCmd
		run.vmCmd = nil
		testMu.Unlock()
		stdout, err = hostCmd.StdoutPipe()
		if err == nil {
			hostCmd.Stderr = hostCmd.Stdout
			err = hostCmd.Start()
		}
		if err == nil && run.stopped.Load() && hostCmd.Process != nil {
			_ = syscall.Kill(-hostCmd.Process.Pid, syscall.SIGKILL)
		}
	} else if err == nil && run.stopped.Load() {
		vmCmd.Cancel()
	}
	if err != nil {
		for _, f := range []string{coverFile, cpuFile, memFile, blockFile, mutexFile} {
			if f != "" {
				_ = os.Remove(f)
			}
		}
		TaskLog(run.id, fmt.Sprintf("Process exited with error: %v", err), false)
		emitResult(TestResult{Run: run.id, Kind: "done", Status: "error"})
		close(run.done)
		endTestRun(run)
		return run.id
	}
	if run.cmd != nil {
		bridge.Debug(fmt.Sprintf("go %s (in %s)", strings.Join(hostArgs, " "), runDir))
	} else {
		bridge.Debug(fmt.Sprintf("go %s (in %s -> %s)", strings.Join(args, " "), runDir, guestRunDir))
	}
	go func() {
		defer close(run.done)
		var cpuFiles, memFiles, blockFiles, mutexFiles, coverFiles []string
		if cpuFile != "" {
			cpuFiles = append(cpuFiles, cpuFile)
		}
		if memFile != "" {
			memFiles = append(memFiles, memFile)
		}
		if blockFile != "" {
			blockFiles = append(blockFiles, blockFile)
		}
		if mutexFile != "" {
			mutexFiles = append(mutexFiles, mutexFile)
		}
		if coverFile != "" {
			coverFiles = append(coverFiles, coverFile)
		}
		defer func() {
			for _, f := range cpuFiles {
				_ = os.Remove(f)
			}
			for _, f := range memFiles {
				_ = os.Remove(f)
			}
			for _, f := range blockFiles {
				_ = os.Remove(f)
			}
			for _, f := range mutexFiles {
				_ = os.Remove(f)
			}
			for _, f := range coverFiles {
				_ = os.Remove(f)
			}
			if profile {
				_ = os.Remove(filepath.Join(runDir, filepath.Base(runDir)+".test"))
				for _, d := range pkgDirs {
					_ = os.Remove(filepath.Join(d, filepath.Base(d)+".test"))
				}
			}
		}()

		agg := newAggregator(run.id, emitResult)
		agg.workspaceRoot = workspaceRoot
		agg.dir = runDir
		agg.suiteDirs = suiteDirs
		output := &runOutputBatcher{id: run.id, emit: emitTaskLog}
		logLine := func(line string) { output.add(line, false) }
		parseTestStream(stdout, agg, logLine)
		var anyFailed bool
		if run.cmd != nil {
			anyFailed = run.cmd.Wait() != nil
		} else {
			anyFailed = vmCmd.Wait() != nil
		}

		if profile && len(pkgDirs) > 1 {
			for _, nextDir := range pkgDirs[1:] {
				if run.stopped.Load() {
					break
				}
				nextCPU, guestNextCPU := createSharedTempPath(workspaceRoot, "golens-cpu-*.pprof")
				nextMem, guestNextMem := createSharedTempPath(workspaceRoot, "golens-mem-*.pprof")
				nextBlock, guestNextBlock := createSharedTempPath(workspaceRoot, "golens-block-*.pprof")
				nextMutex, guestNextMutex := createSharedTempPath(workspaceRoot, "golens-mutex-*.pprof")
				var nextCover, guestNextCover string
				if cover {
					nextCover, guestNextCover = createSharedTempPath(workspaceRoot, "golens-cover-*.out")
					if nextCover != "" {
						coverFiles = append(coverFiles, nextCover)
					}
				}
				if nextCPU != "" {
					cpuFiles = append(cpuFiles, nextCPU)
				}
				if nextMem != "" {
					memFiles = append(memFiles, nextMem)
				}
				if nextBlock != "" {
					blockFiles = append(blockFiles, nextBlock)
				}
				if nextMutex != "" {
					mutexFiles = append(mutexFiles, nextMutex)
				}
				nextArgs := testArgsFullWithContention(pattern, benchPattern, []string{"."}, guestNextCover, guestNextCPU, guestNextMem, guestNextBlock, guestNextMutex)
				hostNextArgs := testArgsFullWithContention(pattern, benchPattern, []string{"."}, nextCover, nextCPU, nextMem, nextBlock, nextMutex)
				nextCmd := vmexec.Command("go", nextArgs...)
				nextCmd.Dir = vmexec.HostToGuestPath(workspaceRoot, nextDir)
				nextCmd.Rosetta = rosetta
				nextCmd.Env = vmexec.DefaultVMEnv(goarch, nil)
				testMu.Lock()
				if run.stopped.Load() {
					testMu.Unlock()
					break
				}
				run.vmCmd = nextCmd
				testMu.Unlock()

				nextOut, startErr := nextCmd.StdoutPipe()
				if startErr == nil {
					nextCmd.Stderr = nextCmd.Stdout
					startErr = nextCmd.Start()
				}
				if startErr != nil && bridge.CanFallbackToHost(startErr) {
					hostNext := exec.Command("go", hostNextArgs...)
					hostNext.Dir = nextDir
					hostNext.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
					testMu.Lock()
					run.cmd = hostNext
					run.vmCmd = nil
					testMu.Unlock()
					nextOut, startErr = hostNext.StdoutPipe()
					if startErr == nil {
						hostNext.Stderr = hostNext.Stdout
						startErr = hostNext.Start()
					}
					if startErr != nil {
						anyFailed = true
						continue
					}
					bridge.Debug(fmt.Sprintf("go %s (in %s)", strings.Join(hostNextArgs, " "), nextDir))
					parseTestStream(nextOut, agg, logLine)
					if hostNext.Wait() != nil {
						anyFailed = true
					}
					continue
				}
				if startErr != nil {
					anyFailed = true
					continue
				}
				bridge.Debug(fmt.Sprintf("go %s (in %s -> %s)", strings.Join(nextArgs, " "), nextDir, nextCmd.Dir))
				parseTestStream(nextOut, agg, logLine)
				if nextCmd.Wait() != nil {
					anyFailed = true
				}
			}
		}

		output.flush()
		status := "pass"
		if run.stopped.Load() {
			status = "cancelled"
		} else if anyFailed {
			status = "fail"
		}
		if len(coverFiles) > 0 && !run.stopped.Load() {
			for _, cf := range coverFiles {
				if filesCov, pkgCov, covErr := testutil.ParseCoverProfile(cf, dir, "", suiteDirs); covErr == nil && (len(filesCov) > 0 || len(pkgCov) > 0) {
					emitResult(TestResult{
						Run:             run.id,
						Kind:            "coverage",
						Status:          "coverage",
						PackageCoverage: pkgCov,
						FilesCoverage:   filesCov,
					})
				}
			}
		}
		if profile && !run.stopped.Load() {
			cpuEntries, memEntries, blockEntries, mutexEntries := testutil.ParseAllPprofFiles(cpuFiles, memFiles, blockFiles, mutexFiles, dir, "", suiteDirs)
			emitResult(TestResult{
				Run:          run.id,
				Kind:         "profile",
				Status:       "profile",
				CPUProfile:   cpuEntries,
				MemProfile:   memEntries,
				BlockProfile: blockEntries,
				MutexProfile: mutexEntries,
				ProfileFiles: persistProfiles(run.id, map[string][]string{"cpu": cpuFiles, "mem": memFiles, "block": blockFiles, "mutex": mutexFiles}),
			})
		}
		emitResult(TestResult{Run: run.id, Kind: "done", Status: status, Passed: agg.passed, Failed: agg.failed, Skipped: agg.skipped})
		endTestRun(run)
	}()
	return run.id
}

func StopTests() {
	testMu.Lock()
	runs := make([]*processRun, 0, len(testRuns))
	for id, r := range testRuns {
		runs = append(runs, r)
		delete(testRuns, id)
	}
	currentRun = nil
	testMu.Unlock()
	for _, r := range runs {
		r.stop()
	}
}
