package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/build"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golens/core/bridge"
	"golens/core/fsutil"
	"golens/core/lsp"
	"golens/core/testutil"
	"golens/core/vmexec"
)

type goOverlay struct {
	Replace map[string]string `json:"Replace"`
}

type appProfilePayload struct {
	ID           int64                   `json:"id"`
	CPU          []testutil.ProfileEntry `json:"cpu"`
	Mem          []testutil.ProfileEntry `json:"mem"`
	Block        []testutil.ProfileEntry `json:"block,omitempty"`
	Mutex        []testutil.ProfileEntry `json:"mutex,omitempty"`
	CPUProfile   []testutil.ProfileEntry `json:"cpuProfile,omitempty"`
	MemProfile   []testutil.ProfileEntry `json:"memProfile,omitempty"`
	BlockProfile []testutil.ProfileEntry `json:"blockProfile,omitempty"`
	MutexProfile []testutil.ProfileEntry `json:"mutexProfile,omitempty"`
}

func ExecuteGoProfileApp(configJSON string) {
	dir := lsp.GetActiveDir()
	if dir == "" {
		bridge.Log("Open a folder to profile it.")
		return
	}
	ProfileWithConfig(dir, configJSON)
}

func ProfileWithConfig(workspacePath, configJSON string) *ProcessRun {
	if workspacePath == "" {
		workspacePath = lsp.GetActiveDir()
	}
	if workspacePath == "" {
		bridge.Log("Open a folder to profile it.")
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

	runDir, note := fsutil.RunDir(workspacePath, config.WorkingDirectory, activeFile)
	if note != "" {
		bridge.Log(note)
	}

	mainFile, err := findMainFileWithConfig(runDir, config.EnvVars, config.BuildFlags)
	if err != nil {
		bridge.Log(fmt.Sprintf("Cannot profile application: %v", err))
		return nil
	}

	rewrittenMain, err := rewriteMainFunc(mainFile)
	if err != nil {
		bridge.Log(fmt.Sprintf("Cannot prepare profile overlay: %v", err))
		return nil
	}

	var tmpBase string
	if workspacePath != "" {
		tmpBase = filepath.Join(workspacePath, ".golens", "tmp")
		_ = os.MkdirAll(tmpBase, 0o755)
	}
	var tempDir string
	if tmpBase != "" {
		tempDir, err = os.MkdirTemp(tmpBase, "golens-app-profile-*")
	}
	if tempDir == "" || err != nil {
		tempDir, err = os.MkdirTemp("", "golens-app-profile-*")
		if err != nil {
			bridge.Log(fmt.Sprintf("Cannot create profile temp dir: %v", err))
			return nil
		}
	}

	cpuPath := filepath.Join(tempDir, "cpu.pprof")
	memPath := filepath.Join(tempDir, "mem.pprof")
	blockPath := filepath.Join(tempDir, "block.pprof")
	mutexPath := filepath.Join(tempDir, "mutex.pprof")
	overlayMainPath := filepath.Join(tempDir, "overlay_"+filepath.Base(mainFile))
	overlayHookPath := filepath.Join(tempDir, "_golens_profile_entry.go")
	overlayJSONPath := filepath.Join(tempDir, "overlay.json")

	guestCPUPath := vmexec.HostToGuestPath(workspacePath, cpuPath)
	guestMemPath := vmexec.HostToGuestPath(workspacePath, memPath)
	guestBlockPath := vmexec.HostToGuestPath(workspacePath, blockPath)
	guestMutexPath := vmexec.HostToGuestPath(workspacePath, mutexPath)
	guestMainFile := vmexec.HostToGuestPath(workspacePath, mainFile)
	guestRunDir := vmexec.HostToGuestPath(workspacePath, runDir)
	guestOverlayMainPath := vmexec.HostToGuestPath(workspacePath, overlayMainPath)
	guestOverlayHookPath := vmexec.HostToGuestPath(workspacePath, overlayHookPath)
	guestOverlayJSONPath := vmexec.HostToGuestPath(workspacePath, overlayJSONPath)

	if err := os.WriteFile(overlayMainPath, rewrittenMain, 0o644); err != nil {
		_ = os.RemoveAll(tempDir)
		bridge.Log(fmt.Sprintf("Cannot write profile overlay: %v", err))
		return nil
	}

	hookSrc := buildProfileHookSource(cpuPath, memPath, blockPath, mutexPath, guestCPUPath, guestMemPath, guestBlockPath, guestMutexPath)
	if err := os.WriteFile(overlayHookPath, []byte(hookSrc), 0o644); err != nil {
		_ = os.RemoveAll(tempDir)
		bridge.Log(fmt.Sprintf("Cannot write profile hook: %v", err))
		return nil
	}

	replaceMap := map[string]string{
		filepath.Join(runDir, filepath.Base(mainFile)):       overlayMainPath,
		filepath.Join(runDir, "golens_profile_entry.go"):      overlayHookPath,
		guestMainFile:                                        guestOverlayMainPath,
		filepath.Join(guestRunDir, "golens_profile_entry.go"): guestOverlayHookPath,
	}
	instrumentOtherMainPackageExitCalls(runDir, mainFile, tempDir, config.EnvVars, config.BuildFlags, replaceMap)
	overlayBytes, err := json.Marshal(goOverlay{Replace: replaceMap})
	if err != nil {
		_ = os.RemoveAll(tempDir)
		bridge.Log(fmt.Sprintf("Cannot marshal profile overlay: %v", err))
		return nil
	}
	if err := os.WriteFile(overlayJSONPath, overlayBytes, 0o644); err != nil {
		_ = os.RemoveAll(tempDir)
		bridge.Log(fmt.Sprintf("Cannot write overlay.json: %v", err))
		return nil
	}

	args := []string{"run", "-overlay", guestOverlayJSONPath}
	if config.BuildFlags != "" {
		args = append(args, fsutil.SplitArgs(config.BuildFlags)...)
	}
	args = append(args, ".")
	if config.Args != "" {
		args = append(args, fsutil.SplitArgs(config.Args)...)
	}

	hostArgs := []string{"run", "-overlay", overlayJSONPath}
	if config.BuildFlags != "" {
		hostArgs = append(hostArgs, fsutil.SplitArgs(config.BuildFlags)...)
	}
	hostArgs = append(hostArgs, ".")
	if config.Args != "" {
		hostArgs = append(hostArgs, fsutil.SplitArgs(config.Args)...)
	}

	hostEnv := os.Environ()
	hostEnv = append(hostEnv, "PWD="+runDir)
	for k, v := range config.EnvVars {
		hostEnv = append(hostEnv, fmt.Sprintf("%s=%s", k, v))
	}

	rosetta := config.Architecture == "amd64" || (config.Target != nil && config.Target.IsRosetta()) || (config.EnvVars != nil && config.EnvVars["GOARCH"] == "amd64")
	goarch := "arm64"
	if rosetta {
		goarch = "amd64"
		hostEnv = append(hostEnv, "GOARCH=amd64")
	}

	vmCmd := vmexec.Command("go", args...)
	vmCmd.HostArgs = hostArgs
	vmCmd.HostEnv = hostEnv
	vmCmd.Dir = guestRunDir
	vmCmd.Rosetta = rosetta
	vmCmd.Env = vmexec.DefaultVMEnv(goarch, config.EnvVars)
	vmCmd.Cgroup = ParseCgroupLimits(config.MemoryLimit, config.CPUQuota)
	vmCmd.EnableTelemetry = true
	vmCmd.OnTelemetry = func(payload []byte) {
		if bridge.HasStatus() {
			bridge.Status("kernelTelemetry", string(payload))
		}
	}
	bridge.Debug(fmt.Sprintf("go %s (in %s -> %s)", strings.Join(args, " "), runDir, guestRunDir))

	key := runDir
	title := relOrBase(workspacePath, runDir)
	if config.Name != "" {
		key = "config:" + config.Name
		title = config.Name
	}

	innerRun := startVMProgramWithMeta(vmCmd, key, title, runDir)
	if innerRun == nil {
		_ = os.RemoveAll(tempDir)
		return nil
	}

	innerRun.stdinMu.Lock()
	innerStdin := innerRun.stdin
	innerRun.stdinMu.Unlock()

	profileDone := make(chan struct{})
	profileRun := &processRun{
		id:     innerRun.id,
		key:    innerRun.key,
		title:  innerRun.title,
		dir:    innerRun.dir,
		cmd:    innerRun.cmd,
		vmCmd:  innerRun.vmCmd,
		onStop: innerRun.onStop,
		pid:    innerRun.pid,
		done:   profileDone,
		stdin:  innerStdin,
	}

	go func() {
		defer close(profileDone)
		defer func() { _ = os.RemoveAll(tempDir) }()
		<-innerRun.done
		if innerRun.stopped.Load() {
			profileRun.stopped.Store(true)
		}
		profileRun.exitErr = innerRun.exitErr

		_, modulePath := testutil.FindModuleRoot(runDir)
		if modulePath == "" {
			_, modulePath = testutil.FindModuleRoot(workspacePath)
		}
		if modulePath == "" {
			modulePath = readModulePathFromGoMod(workspacePath)
		}

		suiteDirs := map[string]string{"main": runDir}
		if imp := testutil.ImportPath(runDir); imp != "" {
			suiteDirs[imp] = runDir
		}

		cpuEntries, memEntries, blockEntries, mutexEntries := testutil.ParseAllPprofFiles([]string{cpuPath}, []string{memPath}, []string{blockPath}, []string{mutexPath}, workspacePath, modulePath, suiteDirs)
		cpuEntries = normalizeAppProfileEntries(cpuEntries, workspacePath, mainFile, overlayMainPath)
		memEntries = normalizeAppProfileEntries(memEntries, workspacePath, mainFile, overlayMainPath)
		blockEntries = normalizeAppProfileEntries(blockEntries, workspacePath, mainFile, overlayMainPath)
		mutexEntries = normalizeAppProfileEntries(mutexEntries, workspacePath, mainFile, overlayMainPath)

		_, cpuStatErr := os.Stat(cpuPath)
		_, memStatErr := os.Stat(memPath)
		noProfileFiles := os.IsNotExist(cpuStatErr) && os.IsNotExist(memStatErr)
		if innerRun.exitErr != nil && !innerRun.stopped.Load() && ((len(cpuEntries) == 0 && len(memEntries) == 0 && len(blockEntries) == 0 && len(mutexEntries) == 0) || noProfileFiles) {
			TaskLog(innerRun.id, fmt.Sprintf("Application profiling failed: %v", innerRun.exitErr), true)
			return
		}

		payload := appProfilePayload{
			ID:           innerRun.id,
			CPU:          cpuEntries,
			Mem:          memEntries,
			Block:        blockEntries,
			Mutex:        mutexEntries,
			CPUProfile:   cpuEntries,
			MemProfile:   memEntries,
			BlockProfile: blockEntries,
			MutexProfile: mutexEntries,
		}
		if payloadJSON, err := json.Marshal(payload); err == nil && bridge.HasStatus() {
			bridge.Status("testProfile", string(payloadJSON))
		}
		TaskLog(innerRun.id, fmt.Sprintf("Application profile captured (%d CPU, %d Memory, %d Block, %d Mutex functions).", len(cpuEntries), len(memEntries), len(blockEntries), len(mutexEntries)), false)
	}()

	return profileRun
}

func extractBuildTagsFromFlags(buildFlags string) []string {
	if strings.TrimSpace(buildFlags) == "" {
		return nil
	}
	tokens := fsutil.SplitArgs(buildFlags)
	var tags []string
	addTags := func(raw string) {
		for _, part := range strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
			if part != "" {
				tags = append(tags, part)
			}
		}
	}
	for i := 0; i < len(tokens); i++ {
		tok := tokens[i]
		if (tok == "-tags" || tok == "--tags") && i+1 < len(tokens) {
			addTags(tokens[i+1])
			i++
		} else if rest, ok := strings.CutPrefix(tok, "-tags="); ok {
			addTags(rest)
		} else if rest, ok := strings.CutPrefix(tok, "--tags="); ok {
			addTags(rest)
		}
	}
	return tags
}

func findMainFile(runDir string) (string, error) {
	return findMainFileWithConfig(runDir, nil, "")
}

func findMainFileWithConfig(runDir string, envVars map[string]string, buildFlags string) (string, error) {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return "", err
	}
	bctx := build.Default
	if goos := strings.TrimSpace(envVars["GOOS"]); goos != "" {
		bctx.GOOS = goos
	} else if goos := strings.TrimSpace(os.Getenv("GOOS")); goos != "" {
		bctx.GOOS = goos
	}
	if goarch := strings.TrimSpace(envVars["GOARCH"]); goarch != "" {
		bctx.GOARCH = goarch
	} else if goarch := strings.TrimSpace(os.Getenv("GOARCH")); goarch != "" {
		bctx.GOARCH = goarch
	}
	if tags := extractBuildTagsFromFlags(buildFlags); len(tags) > 0 {
		bctx.BuildTags = append(append([]string(nil), bctx.BuildTags...), tags...)
	}

	fset := token.NewFileSet()
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		if match, err := bctx.MatchFile(runDir, name); err != nil || !match {
			continue
		}
		fullPath := filepath.Join(runDir, name)
		f, err := parser.ParseFile(fset, fullPath, nil, parser.SkipObjectResolution)
		if err != nil || f == nil || f.Name == nil || f.Name.Name != "main" {
			continue
		}
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if ok && fn.Recv == nil && fn.Name != nil && fn.Name.Name == "main" {
				return fullPath, nil
			}
		}
	}
	return "", fmt.Errorf("no package main with func main() found in %s", runDir)
}

type byteReplacement struct {
	start   int
	end     int
	newText string
}

func collectOSExitReplacements(fset *token.FileSet, f *ast.File, src []byte) []byteReplacement {
	if f == nil {
		return nil
	}
	osPkgName := ""
	for _, imp := range f.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		if strings.Trim(imp.Path.Value, "\"`") == "os" {
			if imp.Name != nil && imp.Name.Name != "" {
				if imp.Name.Name == "_" || imp.Name.Name == "." {
					continue
				}
				osPkgName = imp.Name.Name
			} else {
				osPkgName = "os"
			}
			break
		}
	}
	if osPkgName == "" {
		return nil
	}

	var reps []byteReplacement
	ast.Inspect(f, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || len(call.Args) != 1 {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil || sel.Sel.Name != "Exit" {
			return true
		}
		id, ok := sel.X.(*ast.Ident)
		if !ok || id.Name != osPkgName {
			return true
		}
		funStart := fset.Position(call.Fun.Pos()).Offset
		lparenOff := fset.Position(call.Lparen).Offset
		if funStart >= 0 && lparenOff >= funStart && lparenOff < len(src) && src[lparenOff] == '(' {
			reps = append(reps, byteReplacement{
				start:   funStart,
				end:     lparenOff + 1,
				newText: "golensExit(" + osPkgName + ".Exit, ",
			})
		}
		return true
	})
	return reps
}

func applyByteReplacements(src []byte, reps []byteReplacement) []byte {
	if len(reps) == 0 {
		return src
	}
	sort.Slice(reps, func(i, j int) bool {
		return reps[i].start > reps[j].start
	})
	out := append([]byte(nil), src...)
	for _, r := range reps {
		if r.start < 0 || r.end < r.start || r.end > len(out) {
			continue
		}
		var buf bytes.Buffer
		buf.Grow(len(out) + len(r.newText) - (r.end - r.start))
		buf.Write(out[:r.start])
		buf.WriteString(r.newText)
		buf.Write(out[r.end:])
		out = buf.Bytes()
	}
	return out
}

func rewriteMainFunc(mainFile string) ([]byte, error) {
	src, err := os.ReadFile(mainFile)
	if err != nil {
		return nil, err
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, mainFile, src, parser.SkipObjectResolution)
	if err != nil || f == nil {
		return nil, fmt.Errorf("parse %s: %w", mainFile, err)
	}
	var reps []byteReplacement
	foundMain := false
	for _, decl := range f.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv != nil || fn.Name == nil || fn.Name.Name != "main" {
			continue
		}
		offset := fset.Position(fn.Name.Pos()).Offset
		if offset < 0 || offset+len("main") > len(src) || string(src[offset:offset+len("main")]) != "main" {
			return nil, fmt.Errorf("unexpected func main offset in %s", mainFile)
		}
		reps = append(reps, byteReplacement{
			start:   offset,
			end:     offset + len("main"),
			newText: "_golensOriginalMain",
		})
		foundMain = true
		break
	}
	if !foundMain {
		return nil, fmt.Errorf("func main() not found in %s", mainFile)
	}
	reps = append(reps, collectOSExitReplacements(fset, f, src)...)
	return applyByteReplacements(src, reps), nil
}

func instrumentOtherMainPackageExitCalls(
	runDir string,
	mainFile string,
	tempDir string,
	envVars map[string]string,
	buildFlags string,
	replaceMap map[string]string,
) {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return
	}
	bctx := build.Default
	if goos := strings.TrimSpace(envVars["GOOS"]); goos != "" {
		bctx.GOOS = goos
	} else if goos := strings.TrimSpace(os.Getenv("GOOS")); goos != "" {
		bctx.GOOS = goos
	}
	if goarch := strings.TrimSpace(envVars["GOARCH"]); goarch != "" {
		bctx.GOARCH = goarch
	} else if goarch := strings.TrimSpace(os.Getenv("GOARCH")); goarch != "" {
		bctx.GOARCH = goarch
	}
	if tags := extractBuildTagsFromFlags(buildFlags); len(tags) > 0 {
		bctx.BuildTags = append(append([]string(nil), bctx.BuildTags...), tags...)
	}

	mainClean := filepath.Clean(mainFile)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		fullPath := filepath.Clean(filepath.Join(runDir, name))
		if fullPath == mainClean {
			continue
		}
		if match, err := bctx.MatchFile(runDir, name); err != nil || !match {
			continue
		}
		src, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, fullPath, src, parser.SkipObjectResolution)
		if err != nil || f == nil || f.Name == nil || f.Name.Name != "main" {
			continue
		}
		reps := collectOSExitReplacements(fset, f, src)
		if len(reps) == 0 {
			continue
		}
		rewritten := applyByteReplacements(src, reps)
		overlayPath := filepath.Join(tempDir, "overlay_"+name)
		if err := os.WriteFile(overlayPath, rewritten, 0o644); err == nil {
			replaceMap[fullPath] = overlayPath
		}
	}
}

func buildProfileHookSource(cpuPath, memPath, blockPath, mutexPath, guestCPU, guestMem, guestBlock, guestMutex string) string {
	return fmt.Sprintf(`package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"sync"
	"syscall"
)

func _golensResolvePath(guestPath, hostPath string) string {
	if guestPath != "" && guestPath != hostPath {
		if _, err := os.Stat(filepath.Dir(guestPath)); err == nil {
			return guestPath
		}
	}
	return hostPath
}

var (
	_golensCPUPath   = _golensResolvePath(%q, %q)
	_golensMemPath   = _golensResolvePath(%q, %q)
	_golensBlockPath = _golensResolvePath(%q, %q)
	_golensMutexPath = _golensResolvePath(%q, %q)
)

var (
	_golensProfileOnce sync.Once
	_golensCPUFile     *os.File
	_golensCPUErr      error
)

func golensStopProfile() {
	_golensProfileOnce.Do(func() {
		if _golensCPUErr == nil && _golensCPUFile != nil {
			pprof.StopCPUProfile()
			_ = _golensCPUFile.Close()
		}
		runtime.GC()
		if memFile, memErr := os.Create(_golensMemPath); memErr == nil {
			_ = pprof.WriteHeapProfile(memFile)
			_ = memFile.Close()
		}
		if _golensBlockPath != "" {
			if blockFile, blockErr := os.Create(_golensBlockPath); blockErr == nil {
				if p := pprof.Lookup("block"); p != nil {
					_ = p.WriteTo(blockFile, 0)
				}
				_ = blockFile.Close()
			}
		}
		if _golensMutexPath != "" {
			if mutexFile, mutexErr := os.Create(_golensMutexPath); mutexErr == nil {
				if p := pprof.Lookup("mutex"); p != nil {
					_ = p.WriteTo(mutexFile, 0)
				}
				_ = mutexFile.Close()
			}
		}
	})
}

func golensExit(exitFn func(int), code int) {
	golensStopProfile()
	exitFn(code)
}

func main() {
	runtime.MemProfileRate = 1
	runtime.SetBlockProfileRate(1)
	runtime.SetMutexProfileFraction(1)
	_golensCPUFile, _golensCPUErr = os.Create(_golensCPUPath)
	if _golensCPUErr == nil {
		_ = pprof.StartCPUProfile(_golensCPUFile)
	}
	defer golensStopProfile()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		if _, ok := <-sigCh; ok {
			golensStopProfile()
			os.Exit(0)
		}
	}()
	_golensOriginalMain()
	signal.Stop(sigCh)
	close(sigCh)
}
`, guestCPU, cpuPath, guestMem, memPath, guestBlock, blockPath, guestMutex, mutexPath)
}

func readModulePathFromGoMod(workspacePath string) string {
	data, err := os.ReadFile(filepath.Join(workspacePath, "go.mod"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(line, "module"); ok && (rest == "" || rest[0] == ' ' || rest[0] == '\t') {
			rest = strings.TrimSpace(rest)
			if i := strings.Index(rest, "//"); i >= 0 {
				rest = strings.TrimSpace(rest[:i])
			}
			return strings.Trim(rest, "\"`")
		}
	}
	return ""
}

func normalizeAppProfileEntries(entries []testutil.ProfileEntry, workspacePath, mainFile, overlayMainPath string) []testutil.ProfileEntry {
	if len(entries) == 0 {
		return []testutil.ProfileEntry{}
	}
	realWorkspace, _ := filepath.EvalSymlinks(workspacePath)
	realMain, _ := filepath.EvalSymlinks(mainFile)
	realOverlayMain, _ := filepath.EvalSymlinks(overlayMainPath)

	out := make([]testutil.ProfileEntry, 0, len(entries))
	for _, e := range entries {
		base := filepath.Base(e.File)
		if base == "_golens_profile_entry.go" || base == "golens_profile_entry.go" {
			continue
		}
		if strings.HasSuffix(e.Function, ".golensStopProfile") || strings.HasSuffix(e.Function, ".golensExit") {
			continue
		}
		e.Function = strings.ReplaceAll(e.Function, "_golensOriginalMain", "main")
		e.File = normalizeProfileFilePath(e.File, workspacePath, realWorkspace, mainFile, realMain, overlayMainPath, realOverlayMain)
		e.Callers = normalizeEdgeList(e.Callers)
		e.Children = normalizeEdgeList(e.Children)
		out = append(out, e)
	}
	return out
}

func normalizeProfileFilePath(file, workspacePath, realWorkspace, mainFile, realMain, overlayMainPath, realOverlayMain string) string {
	if file == "" {
		return ""
	}
	cleaned := filepath.Clean(file)
	if cleaned == overlayMainPath || (realOverlayMain != "" && cleaned == realOverlayMain) {
		return mainFile
	}
	if overlayDir := filepath.Dir(overlayMainPath); overlayDir != "" && filepath.Dir(cleaned) == overlayDir {
		if origBase, ok := strings.CutPrefix(filepath.Base(cleaned), "overlay_"); ok && origBase != "" {
			return filepath.Join(filepath.Dir(mainFile), origBase)
		}
	}
	if cleaned == mainFile || (realMain != "" && cleaned == realMain) {
		return mainFile
	}
	if realFile, err := filepath.EvalSymlinks(cleaned); err == nil {
		if realMain != "" && realFile == realMain {
			return mainFile
		}
		if realOverlayMain != "" && realFile == realOverlayMain {
			return mainFile
		}
		if realWorkspace != "" {
			if rel, relErr := filepath.Rel(realWorkspace, realFile); relErr == nil && rel != "." && !strings.HasPrefix(rel, "..") {
				return filepath.Join(workspacePath, rel)
			}
		}
	}
	if realWorkspace != "" && realWorkspace != workspacePath {
		if rel, err := filepath.Rel(realWorkspace, cleaned); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			return filepath.Join(workspacePath, rel)
		}
	}
	return cleaned
}

func normalizeEdgeList(edges []string) []string {
	if len(edges) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(edges))
	out := make([]string, 0, len(edges))
	for _, edge := range edges {
		if strings.Contains(edge, "golensStopProfile") || strings.Contains(edge, "golensExit") {
			continue
		}
		normalized := strings.ReplaceAll(edge, "_golensOriginalMain", "main")
		if !seen[normalized] {
			seen[normalized] = true
			out = append(out, normalized)
		}
	}
	return out
}
