package main

import "C"

import (
	"encoding/json"
	"fmt"

	"golens/core/analysis"
	"golens/core/bridge"
	"golens/core/fsutil"
	"golens/core/lsp"
	"golens/core/remote"
	"golens/core/runner"
	"golens/core/testutil"
)

//export WriteProgramStdin
func WriteProgramStdin(runId C.longlong, cInput *C.char, length C.int) {
	data := bytesArg(cInput, length)
	if len(data) == 0 {
		return
	}
	if err := runner.WriteProgramStdin(int64(runId), string(data)); err != nil {
		bridge.Debug(fmt.Sprintf("WriteProgramStdin(%d): %v", int64(runId), err))
	}
}

//export CloseProgramStdin
func CloseProgramStdin(runId C.longlong) {
	if err := runner.CloseProgramStdin(int64(runId)); err != nil {
		bridge.Debug(fmt.Sprintf("CloseProgramStdin(%d): %v", int64(runId), err))
	}
}

//export StopProgramRun
func StopProgramRun(runId C.longlong) {
	runner.StopProgramRun(int64(runId))
}

//export ExecuteGoRun
func ExecuteGoRun(configJson *C.char) {
	cfg := C.GoString(configJson)
	if remote.WantsRemote(cfg) {
		dir := lsp.GetActiveDir()
		if dir == "" {
			bridge.Log("Open a folder to run it.")
			return
		}
		remote.Run(dir, cfg)
		return
	}
	runner.ExecuteGoRun(cfg)
}

//export RunGoCommand
func RunGoCommand(args *C.char) {
	runner.RunGoCommand(fsutil.SplitArgs(C.GoString(args)))
}

//export RunTests
func RunTests(cRequest *C.char) C.longlong {
	req := C.GoString(cRequest)
	if remote.WantsRemote(req) {
		return C.longlong(remote.RunTests(lsp.GetActiveDir(), req))
	}
	return C.longlong(runner.RunTests(req))
}

//export StopTestRun
func StopTestRun(runId C.longlong) {
	runner.StopTestRun(int64(runId))
}

//export FileTests
func FileTests(cPath *C.char) *C.char {
	path := C.GoString(cPath)
	src, err := lsp.DocumentContent(path)
	if err != nil {
		return C.CString(`{"importPath":"","tests":[]}`)
	}
	b, _ := json.Marshal(testutil.FileTests(path, src))
	return C.CString(string(b))
}

//export ResolveCaretTestTarget
func ResolveCaretTestTarget(cPath *C.char, line C.int) *C.char {
	if cPath == nil || line <= 0 {
		return C.CString(`{"found":false}`)
	}
	path := C.GoString(cPath)
	src, err := lsp.DocumentContent(path)
	if err != nil {
		return C.CString(`{"found":false}`)
	}
	b, err := json.Marshal(testutil.ResolveCaretTargetInFile(path, src, int(line), lsp.DocumentContent))
	if err != nil {
		return C.CString(`{"found":false}`)
	}
	return C.CString(string(b))
}

//export DiscoverGoTests
func DiscoverGoTests(cDir *C.char) *C.char {
	return C.CString(testutil.DiscoverTests(C.GoString(cDir)))
}

//export ParseGoProfileFile
func ParseGoProfileFile(cPath *C.char) *C.char {
	return C.CString(testutil.ParseProfileFileJSON(C.GoString(cPath)))
}

//export ParseGoProfileDetailed
func ParseGoProfileDetailed(cPath *C.char, cSampleType *C.char) *C.char {
	detail, err := testutil.ParseProfileDetailedWithOptions(C.GoString(cPath), testutil.ProfileDetailOptions{SampleTypeOverride: C.GoString(cSampleType)})
	if err != nil {
		encoded, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(encoded))
	}
	encoded, err := json.Marshal(detail)
	if err != nil {
		return C.CString(`{"error":"profile detail could not be encoded"}`)
	}
	return C.CString(string(encoded))
}

//export ExecuteGoProfileApp
func ExecuteGoProfileApp(configJson *C.char) {
	runner.ExecuteGoProfileApp(C.GoString(configJson))
}

//export CompareGoBenchmarks
func CompareGoBenchmarks(baselineInput *C.char, currentInput *C.char) *C.char {
	res, err := analysis.CompareBenchmarkRuns(C.GoString(baselineInput), C.GoString(currentInput))
	if err != nil {
		return C.CString(`{"items":[],"fasterCount":0,"regressedCount":0,"unchangedCount":0}`)
	}
	return C.CString(res)
}

//export ParseGoTraceFile
func ParseGoTraceFile(cTracePath *C.char) *C.char {
	var tracePath string
	if cTracePath != nil {
		tracePath = C.GoString(cTracePath)
	}
	res, err := testutil.ParseGoTraceFile(tracePath)
	if err != nil {
		errMap := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(errMap)
		return C.CString(string(b))
	}
	b, err := json.Marshal(res)
	if err != nil {
		errMap := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(errMap)
		return C.CString(string(b))
	}
	return C.CString(string(b))
}

//export UntestedPackageFunctions
func UntestedPackageFunctions(cPkgDir *C.char) *C.char {
	if cPkgDir == nil {
		return C.CString("[]")
	}
	b, err := json.Marshal(testutil.UntestedPackageFunctions(C.GoString(cPkgDir)))
	if err != nil {
		return C.CString("[]")
	}
	return C.CString(string(b))
}

//export RunExternalCommand
func RunExternalCommand(cArgvJSON, cDir, cTitle, cKey *C.char) C.longlong {
	return C.longlong(runner.RunExternalCommand(C.GoString(cArgvJSON), C.GoString(cDir), C.GoString(cTitle), C.GoString(cKey)))
}
