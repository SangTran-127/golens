package main

/*
#include <stdlib.h>
#include <stdint.h>

typedef void (*SwiftCallback)(const char* msg, int stream);
typedef void (*DiagnosticsCallback)(const char* path, const char* jsonPayload);
typedef void (*LSPResponseCallback)(const char* jsonPayload);
typedef void (*DebugEventCallback)(const char* event, const char* jsonPayload);
typedef void (*ApplyEditCallback)(long long token, const char* jsonPayload);
typedef void (*TestEventCallback)(const char* jsonPayload);
typedef void (*SearchCallback)(const char* jsonPayload);
typedef void (*StatusEventCallback)(const char* topic, const char* jsonPayload);

static void callSwiftCallback(SwiftCallback cb, const char* msg, int stream) {
    if (cb != NULL) cb(msg, stream);
}
static void callDiagnosticsCallback(DiagnosticsCallback cb, const char* path, const char* payload) {
    if (cb != NULL) cb(path, payload);
}
static void callLSPResponseCallback(LSPResponseCallback cb, const char* payload) {
    if (cb != NULL) cb(payload);
}
static void callDebugEventCallback(DebugEventCallback cb, const char* event, const char* payload) {
    if (cb != NULL) cb(event, payload);
}
static void callTestEventCallback(TestEventCallback cb, const char* payload) {
    if (cb != NULL) cb(payload);
}
static void callSearchCallback(SearchCallback cb, const char* payload) {
    if (cb != NULL) cb(payload);
}
static void callStatusEventCallback(StatusEventCallback cb, const char* topic, const char* payload) {
    if (cb != NULL) cb(topic, payload);
}
static void callApplyEditCallback(ApplyEditCallback cb, long long token, const char* payload) {
    if (cb != NULL) cb(token, payload);
}
typedef int (*VsockDialCallback)(uint32_t port);
static int callVsockDialCallback(VsockDialCallback cb, uint32_t port) {
    if (cb != NULL) return cb(port);
    return -1;
}
typedef int (*VsockTimeoutDialCallback)(uint32_t port, uint32_t timeoutMs);
static int callVsockTimeoutDialCallback(VsockTimeoutDialCallback cb, uint32_t port, uint32_t timeoutMs) {
    if (cb != NULL) return cb(port, timeoutMs);
    return -1;
}
*/
import "C"

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golens/core/analysis"
	"golens/core/bridge"
	"golens/core/database"
	"golens/core/lsp"
	"golens/core/refactor"
	"golens/core/runner"
	"golens/core/search"
	"golens/core/usageindex"
	"golens/core/vmexec"
)

var (
	swiftLogCb              C.SwiftCallback
	swiftDiagCb             C.DiagnosticsCallback
	swiftLspResCb           C.LSPResponseCallback
	swiftDebugEvCb          C.DebugEventCallback
	swiftApplyCb            C.ApplyEditCallback
	swiftTestEvCb           C.TestEventCallback
	swiftSearchCb           C.SearchCallback
	swiftStatusCb           C.StatusEventCallback
	swiftVsockDialCb        C.VsockDialCallback
	swiftVsockTimeoutDialCb C.VsockTimeoutDialCallback
	customHostGoMu          sync.Mutex
	baseHostPath            string
	customHostGoBinary      string
)

func enrichHostPath() {
	customHostGoMu.Lock()
	defer customHostGoMu.Unlock()
	path := os.Getenv("PATH")
	parts := filepath.SplitList(path)
	have := make(map[string]bool, len(parts))
	for _, p := range parts {
		if p != "" {
			have[p] = true
		}
	}
	extra := []string{"/opt/homebrew/bin", "/usr/local/go/bin", "/usr/local/bin"}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		extra = append(extra, filepath.Join(home, "go", "bin"))
	}
	for _, p := range extra {
		if !have[p] {
			have[p] = true
			parts = append(parts, p)
		}
	}
	baseHostPath = strings.Join(parts, string(os.PathListSeparator))
	_ = os.Setenv("PATH", baseHostPath)
}

func applyCustomHostGoBinary(goBinaryPath string) bool {
	customHostGoMu.Lock()
	defer customHostGoMu.Unlock()
	trimmed := strings.TrimSpace(goBinaryPath)
	if trimmed == customHostGoBinary {
		return false
	}
	customHostGoBinary = trimmed
	if trimmed == "" {
		_ = os.Setenv("PATH", baseHostPath)
		return true
	}
	binDir := filepath.Dir(trimmed)
	var updated []string
	updated = append(updated, binDir)
	for _, p := range filepath.SplitList(baseHostPath) {
		if p != "" && p != binDir {
			updated = append(updated, p)
		}
	}
	_ = os.Setenv("PATH", strings.Join(updated, string(os.PathListSeparator)))
	return true
}

func init() {
	enrichHostPath()
	bridge.SetLog(func(msg string) { logToSwift(msg, 1) })
	bridge.SetStderr(func(msg string) { logToSwift(msg, 2) })
	bridge.SetDebug(func(msg string) { logToSwift(msg, 3) })
	refactor.OverlayReader = lsp.DocumentContent
	analysis.OverlayReader = lsp.DocumentContent
	usageindex.DefaultOverlayFiles = lsp.OpenDocumentPaths
	usageIndex.OnInvalidate = lsp.SyncSavedIfClean

	bridge.SetDiagnostics(func(path, payload string) {
		if swiftDiagCb != nil {
			cPath := C.CString(path)
			cPayload := C.CString(payload)
			C.callDiagnosticsCallback(swiftDiagCb, cPath, cPayload)
			C.free(unsafe.Pointer(cPath))
			C.free(unsafe.Pointer(cPayload))
		}
	})

	bridge.SetLSPResponse(func(body []byte) {
		if swiftLspResCb != nil && len(body) > 0 {
			cPayload := C.CString(unsafe.String(&body[0], len(body)))
			C.callLSPResponseCallback(swiftLspResCb, cPayload)
			C.free(unsafe.Pointer(cPayload))
		}
	})

	bridge.SetApplyEdit(func(token int64, edit string) bool {
		if swiftApplyCb == nil {
			return false
		}
		cPayload := C.CString(edit)
		C.callApplyEditCallback(swiftApplyCb, C.longlong(token), cPayload)
		C.free(unsafe.Pointer(cPayload))
		return true
	})

	runner.TestEvent = func(payload string) {
		if swiftTestEvCb != nil {
			cPayload := C.CString(payload)
			C.callTestEventCallback(swiftTestEvCb, cPayload)
			C.free(unsafe.Pointer(cPayload))
		}
	}

	search.Emit = func(payload string) {
		if swiftSearchCb != nil {
			cPayload := C.CString(payload)
			C.callSearchCallback(swiftSearchCb, cPayload)
			C.free(unsafe.Pointer(cPayload))
		}
	}

	bridge.SetStatus(func(topic, payload string) {
		if swiftStatusCb != nil {
			cTopic := C.CString(topic)
			cPayload := C.CString(payload)
			C.callStatusEventCallback(swiftStatusCb, cTopic, cPayload)
			C.free(unsafe.Pointer(cTopic))
			C.free(unsafe.Pointer(cPayload))
		}
	})

	bridge.SetDebugEvent(func(event string, payload string) {
		if swiftDebugEvCb != nil {
			cEvent := C.CString(event)
			cPayload := C.CString(payload)
			C.callDebugEventCallback(swiftDebugEvCb, cEvent, cPayload)
			C.free(unsafe.Pointer(cEvent))
			C.free(unsafe.Pointer(cPayload))
		}
	})
}

func logToSwift(msg string, stream C.int) {
	if swiftLogCb == nil {
		fmt.Println(msg)
		return
	}
	cMsg := C.CString(msg)
	C.callSwiftCallback(swiftLogCb, cMsg, stream)
	C.free(unsafe.Pointer(cMsg))
}

//export RegisterCallback
func RegisterCallback(cb C.SwiftCallback) {
	swiftLogCb = cb
}

//export RegisterDiagnosticsCallback
func RegisterDiagnosticsCallback(cb C.DiagnosticsCallback) {
	swiftDiagCb = cb
}

//export RegisterLSPResponseCallback
func RegisterLSPResponseCallback(cb C.LSPResponseCallback) {
	swiftLspResCb = cb
}

// Ownership: topic and JSON payload are valid only during the call. Topics: "languageServer" {state, detail}, "terminalExit" {id, code}, "services.docker.batch" {seq, reset, upserts, removals, invalidated, engine}, "services.docker.logs" {stream, lines, dropped, closed, reason, error}, "services.docker.stats" {stream, id, cpuPercent, memoryBytes, memoryLimitBytes, closed, error}, "services.kube.batch" {seq, watch, context, namespace, kind, state, reset, upserts, removals, total, truncated, error}, "services.kube.logs" {stream, lines, dropped, closed, reason, error}.
//
//export RegisterStatusEventCallback
func RegisterStatusEventCallback(cb C.StatusEventCallback) {
	swiftStatusCb = cb
}

//export RegisterSandboxVsockDialer
func RegisterSandboxVsockDialer(cb C.VsockDialCallback) {
	swiftVsockDialCb = cb
	bridge.SetVsockDialer(func(port uint32) (int, error) {
		if swiftVsockDialCb == nil {
			return -1, fmt.Errorf("sandbox vsock dialer not registered")
		}
		fd := int(C.callVsockDialCallback(swiftVsockDialCb, C.uint32_t(port)))
		if fd == -2 {
			return -1, bridge.ErrVMNotRunning
		}
		if fd < 0 {
			return -1, fmt.Errorf("vsock dial to port %d failed (code %d)", port, fd)
		}
		return fd, nil
	})
}

// Ownership: no pointers involved. The callback receives a vsock port and a timeout in milliseconds and returns a connected fd, -2 when the Micro-VM is not running, or -1 on failure; Git dials pass a short timeout.
//
//export RegisterSandboxVsockTimeoutDialer
func RegisterSandboxVsockTimeoutDialer(cb C.VsockTimeoutDialCallback) {
	swiftVsockTimeoutDialCb = cb
	if cb == nil {
		vmexec.SetTimeoutDialer(nil)
		return
	}
	vmexec.SetTimeoutDialer(func(port uint32, timeout time.Duration) (int, error) {
		if bridge.IsHostMode() {
			return -1, bridge.ErrVMNotRunning
		}
		dial := swiftVsockTimeoutDialCb
		if dial == nil {
			return -1, bridge.ErrDialerUnset
		}
		ms := timeout.Milliseconds()
		if ms < 1 {
			ms = 1
		}
		fd := int(C.callVsockTimeoutDialCallback(dial, C.uint32_t(port), C.uint32_t(ms)))
		if fd == -2 {
			return -1, bridge.ErrVMNotRunning
		}
		if fd < 0 {
			return -1, fmt.Errorf("vsock dial to port %d failed (code %d)", port, fd)
		}
		return fd, nil
	})
}

//export RegisterDebugEventCallback
func RegisterDebugEventCallback(cb C.DebugEventCallback) {
	swiftDebugEvCb = cb
}

// Ownership: the callback receives a JSON {label, edit} valid only during the call; it must copy it and answer with ApplyEditResult.
//
//export RegisterApplyEditCallback
func RegisterApplyEditCallback(cb C.ApplyEditCallback) {
	swiftApplyCb = cb
}

// Ownership: no pointers retained; does not start gopls (started per workspace).
//
//export InitEditor
func InitEditor() {
	lsp.InitGoLensCore()
}

// Ownership: no pointers involved; blocks until the running program, tests, debugger, gopls and terminals are stopped.
//
//export ShutdownGoLensCore
func ShutdownGoLensCore() {
	runner.StopRun()
	runner.StopTests()
	DebugStop()
	closeAllTerminals()
	database.StopAllTunnels()
	lsp.Shutdown()
}

func bytesArg(p *C.char, n C.int) []byte {
	if p == nil || n <= 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(p)), int(n))
}

// Ownership: the callback receives one JSON batch {id, files | done} valid only during the call; it must copy it.
//
//export RegisterSearchCallback
func RegisterSearchCallback(cb C.SearchCallback) {
	swiftSearchCb = cb
}

// Ownership: the callback receives one JSON test result valid only during the call; it must copy it.
//
//export RegisterTestEventCallback
func RegisterTestEventCallback(cb C.TestEventCallback) {
	swiftTestEvCb = cb
}

// Ownership: returns a C.malloc'd JSON RuntimeDiagnosticsReport freed with FreeGoCString.
//
//export GetGoRuntimeDiagnostics
func GetGoRuntimeDiagnostics() *C.char {
	return C.CString(collectRuntimeDiagnosticsJSON())
}

// Ownership: no pointers involved; runs Go GC and returns free OS pages.
//
//export ReleaseGoMemory
func ReleaseGoMemory() {
	releaseRuntimeMemory()
}

// Ownership: frees a string returned by any export above.
//
//export FreeGoCString
func FreeGoCString(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

// Ownership: frees a buffer returned by GetSemanticTokens.
//
//export FreeGoBuffer
func FreeGoBuffer(ptr unsafe.Pointer) {
	C.free(ptr)
}

func main() {
}
