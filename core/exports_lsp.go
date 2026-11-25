package main

/*
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"strings"
	"unsafe"

	"golens/core/goast"
	"golens/core/lsp"
	"golens/core/syntaxcheck"
)

//export RestartLanguageServer
func RestartLanguageServer() {
	lsp.RestartServer()
}

//export CheckGoSyntax
func CheckGoSyntax(cPath *C.char, cSource *C.char, length C.int) *C.char {
	path := C.GoString(cPath)
	var source []byte
	if cSource != nil && length > 0 {
		source = C.GoBytes(unsafe.Pointer(cSource), length)
	}
	return C.CString(syntaxcheck.CheckJSON(path, source))
}

// Ownership: reason is copied; answers the server's workspace/applyEdit request identified by token.
//
//export ApplyEditResult
func ApplyEditResult(token C.longlong, applied C.int, cReason *C.char) {
	reason := ""
	if cReason != nil {
		reason = C.GoString(cReason)
	}
	lsp.FinishApplyEdit(int64(token), applied != 0, reason)
}

// Ownership: JSON {analyses:{name:bool}, hints:{name:bool}} is copied; gopls is told to reload its configuration.
//
//export SetGoplsOptions
func SetGoplsOptions(cJSON *C.char) {
	var o struct {
		Analyses map[string]bool `json:"analyses"`
		Hints    map[string]bool `json:"hints"`
	}
	if json.Unmarshal([]byte(C.GoString(cJSON)), &o) == nil {
		lsp.SetUserOptions(o.Analyses, o.Hints)
	}
}

// Ownership: path is copied; returns a C.malloc'd JSON {notes, error?} freed with FreeGoCString; runs go list -m -u (network), so call it off the main thread.
//
//export ModuleNotes
func ModuleNotes(cPath *C.char) *C.char {
	return C.CString(lsp.ModuleNotes(C.GoString(cPath)))
}

// Ownership: returns a C.malloc'd JSON {result|error} freed with FreeGoCString.
//
//export CodeLenses
func CodeLenses(cPath *C.char) *C.char {
	return C.CString(lsp.CodeLenses(C.GoString(cPath)))
}

// Ownership: params JSON {command, arguments, formAnswers} is copied; returns a C.malloc'd JSON {result|error} freed with FreeGoCString; blocks until gopls answers.
//
//export ExecuteCommand
func ExecuteCommand(cParams *C.char) *C.char {
	return C.CString(lsp.ExecuteCommand(C.GoString(cParams)))
}

// Ownership: params JSON is copied; returns a C.malloc'd JSON {result|error} freed with FreeGoCString.
//
//export ResolveCommand
func ResolveCommand(cParams *C.char) *C.char {
	return C.CString(lsp.ResolveCommand(C.GoString(cParams)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {result|error} freed with FreeGoCString.
//
//export ListEnum
func ListEnum(cSource *C.char, cConfig *C.char, cQuery *C.char) *C.char {
	var config json.RawMessage
	if cConfig != nil {
		if s := C.GoString(cConfig); s != "" && json.Valid([]byte(s)) {
			config = json.RawMessage(s)
		}
	}
	return C.CString(lsp.ListEnum(C.GoString(cSource), config, C.GoString(cQuery)))
}

// Ownership: arguments are copied; only is comma-separated kinds, diagnostics a JSON array; returns a C.malloc'd JSON {result|error} freed with FreeGoCString.
//
//export CodeActions
func CodeActions(cPath *C.char, startByte, endByte C.int, cOnly *C.char, cDiagnostics *C.char) *C.char {
	var only []string
	for _, k := range strings.Split(C.GoString(cOnly), ",") {
		if k != "" {
			only = append(only, k)
		}
	}
	var diags json.RawMessage
	if s := C.GoString(cDiagnostics); json.Valid([]byte(s)) {
		diags = json.RawMessage(s)
	}
	return C.CString(lsp.CodeActions(C.GoString(cPath), int(startByte), int(endByte), only, diags))
}

// Ownership: action JSON is copied; returns a C.malloc'd JSON {result|error} freed with FreeGoCString.
//
//export ResolveCodeAction
func ResolveCodeAction(cAction *C.char) *C.char {
	return C.CString(lsp.ResolveCodeAction(C.GoString(cAction)))
}

// Ownership: path and text (length bytes, not NUL-terminated) are copied before returning.
//
//export NotifyFileOpen
func NotifyFileOpen(cPath *C.char, cText *C.char, length C.int) {
	lsp.OpenDocument(C.GoString(cPath), bytesArg(cText, length))
}

// Ownership: text is read only during the call; returns 0 applied, 1 unknown document, 2 desync.
//
//export NotifyIncrementalChange
func NotifyIncrementalChange(cPath *C.char, startByte, endByte C.int, cText *C.char, length C.int, expectedLength C.int) C.int {
	path := C.GoString(cPath)
	usageIndex.MarkDirty(path)
	return C.int(lsp.ChangeDocument(path, int(startByte), int(endByte), bytesArg(cText, length), int(expectedLength)))
}

// Ownership: text is copied; full transfers are only for open, reload and replace-all.
//
//export NotifyFullChange
func NotifyFullChange(cPath *C.char, cText *C.char, length C.int) C.int {
	path := C.GoString(cPath)
	usageIndex.MarkDirty(path)
	return C.int(lsp.ReplaceDocument(path, bytesArg(cText, length)))
}

// Ownership: path is copied; the document and all its state are released.
//
//export NotifyFileClose
func NotifyFileClose(cPath *C.char) {
	path := C.GoString(cPath)
	lsp.CloseDocument(path)
	usageIndex.MarkDirty(path)
}

// Ownership: message is copied; returns 1 when queued for gopls, 0 when no server is ready.
//
//export SendLSPMessage
func SendLSPMessage(jsonMsg *C.char) C.int {
	if lsp.SendSwiftMessage([]byte(C.GoString(jsonMsg))) {
		return 1
	}
	return 0
}

// Ownership: no pointers involved; 1 while the VM guest's swap pool is nearly full.
//
//export GuestMemoryPressure
func GuestMemoryPressure() C.int {
	if lsp.GuestMemoryPressure() {
		return 1
	}
	return 0
}

// Ownership: no pointers involved; sizes are MiB. Returns the size the VM's memory balloon should target now.
//
//export GuestMemoryStepTarget
func GuestMemoryStepTarget(currentMB, baseMB, ceilingMB, idle C.int) C.int {
	if currentMB <= 0 || baseMB <= 0 || ceilingMB <= 0 {
		return currentMB
	}
	target := lsp.GuestMemoryStepTarget(uint64(currentMB)<<20, uint64(baseMB)<<20, uint64(ceilingMB)<<20, idle != 0)
	return C.int(target >> 20)
}

// Ownership: no pointers involved; sizes are MiB. Records the balloon target the app just set, so gopls started before the balloon inflates is sized for it.
//
//export GuestMemoryStepApplied
func GuestMemoryStepApplied(stepMB, ceilingMB C.int) {
	if stepMB <= 0 || ceilingMB <= 0 {
		return
	}
	lsp.SetGuestMemoryStep(uint64(stepMB)<<20, uint64(ceilingMB)<<20)
}

// Ownership: no pointers involved.
//
//export CancelLSPRequest
func CancelLSPRequest(id C.longlong) {
	lsp.CancelSwiftRequest(int64(id))
}

// Ownership: path copied; returns a C.malloc'd int32 array of (start, length, type) byte triples, freed with FreeGoBuffer; NULL when stale or unavailable.
//
//export GetSemanticTokens
func GetSemanticTokens(cPath *C.char, startByte, endByte C.int, outCount *C.int) *C.int32_t {
	*outCount = 0
	tokens, ok := lsp.SemanticTokens(C.GoString(cPath), int(startByte), int(endByte))
	if !ok {
		return nil
	}
	n := len(tokens)
	buf := (*C.int32_t)(C.malloc(C.size_t(max(n, 1)) * 4))
	if n > 0 {
		copy(unsafe.Slice((*int32)(unsafe.Pointer(buf)), n), tokens)
	}
	*outCount = C.int(n)
	return buf
}

// Ownership: newline-separated paths are copied; semantic tokens are served only for these documents.
//
//export SetVisibleDocuments
func SetVisibleDocuments(cPaths *C.char) {
	var paths []string
	for _, p := range strings.Split(C.GoString(cPaths), "\n") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	lsp.SetVisibleDocuments(paths)
}

// Ownership: returns a C.malloc'd JSON string freed with FreeGoCString.
//
//export GetSignatureHelp
func GetSignatureHelp(cPath *C.char, byteOffset C.int) *C.char {
	return C.CString(lsp.SignatureHelp(C.GoString(cPath), int(byteOffset)))
}

// Ownership: returns a C.malloc'd JSON WorkspaceEdit envelope freed with FreeGoCString.
//
//export RenameSymbol
func RenameSymbol(cPath *C.char, byteOffset C.int, cNewName *C.char) *C.char {
	return C.CString(lsp.Rename(C.GoString(cPath), int(byteOffset), C.GoString(cNewName)))
}

// Ownership: returns a C.malloc'd JSON {version, edits} string freed with FreeGoCString.
//
//export FormattingEdits
func FormattingEdits(cPath *C.char, tabSize C.int) *C.char {
	return C.CString(lsp.FormattingEdits(C.GoString(cPath), int(tabSize)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {text, stops, final} string freed with FreeGoCString.
//
//export ExpandLiveTemplate
func ExpandLiveTemplate(cBody, cIndent, cSelection *C.char) *C.char {
	data, err := json.Marshal(lsp.ExpandTemplate(C.GoString(cBody), C.GoString(cIndent), C.GoString(cSelection)))
	if err != nil {
		return C.CString(`{"text":"","stops":[],"final":0}`)
	}
	return C.CString(string(data))
}

// Ownership: returns a C.malloc'd JSON {version, edits} string freed with FreeGoCString.
//
//export OrganizeImportsEdits
func OrganizeImportsEdits(cPath *C.char) *C.char {
	return C.CString(lsp.OrganizeImportsEdits(C.GoString(cPath)))
}

// Ownership: returns a C.malloc'd JSON string freed with FreeGoCString; blocks up to the completion budget.
//
//export CompletionStart
func CompletionStart(cPath *C.char, caretByte, triggerKind C.int, cTriggerChar *C.char) *C.char {
	trigger := ""
	if cTriggerChar != nil {
		trigger = C.GoString(cTriggerChar)
	}
	return C.CString(lsp.StartCompletion(C.GoString(cPath), int(caretByte), int(triggerKind), trigger))
}

// Ownership: returns a C.malloc'd JSON string freed with FreeGoCString; never blocks on gopls.
//
//export CompletionFilter
func CompletionFilter(session C.longlong, cPath *C.char, caretByte C.int, cQuery *C.char) *C.char {
	return C.CString(lsp.FilterCompletion(int64(session), C.GoString(cPath), int(caretByte), C.GoString(cQuery)))
}

// Ownership: returns a C.malloc'd JSON string freed with FreeGoCString.
//
//export CompletionDoc
func CompletionDoc(session C.longlong, index C.int) *C.char {
	return C.CString(lsp.CompletionDoc(int64(session), int(index)))
}

// Ownership: returns a C.malloc'd JSON string freed with FreeGoCString; ends the session. Start/End are the byte range to replace.
//
//export CompletionCommit
func CompletionCommit(session C.longlong, index C.int, caretByte C.int) *C.char {
	return C.CString(lsp.CommitCompletion(int64(session), int(index), int(caretByte)))
}

// Ownership: no pointers involved.
//
//export CompletionCancel
func CompletionCancel() {
	lsp.CancelCompletion()
}

// Ownership: arguments are copied; updates gopls GOOS, GOARCH, and build tags.
//
//export SetGoplsBuildTarget
func SetGoplsBuildTarget(cGoos *C.char, cGoarch *C.char, cTags *C.char) {
	lsp.SetBuildTarget(C.GoString(cGoos), C.GoString(cGoarch), C.GoString(cTags))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON BuildTargetStatus freed with FreeGoCString.
//
//export CheckGoBuildTarget
func CheckGoBuildTarget(cPath *C.char, cContent *C.char, cGoos *C.char, cGoarch *C.char, cTags *C.char) *C.char {
	res, err := goast.CheckBuildTarget(C.GoString(cPath), C.GoString(cContent), C.GoString(cGoos), C.GoString(cGoarch), C.GoString(cTags))
	if err != nil {
		return C.CString(`{"excluded":false}`)
	}
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON GoModInspectReport freed with FreeGoCString.
//
//export InspectGoModFile
func InspectGoModFile(cPath *C.char, cContent *C.char, checkUpdates C.int) *C.char {
	path := C.GoString(cPath)
	content := C.GoString(cContent)
	switch checkUpdates {
	case 2:
		return C.CString(lsp.GoModWhyJSON(path, content))
	case 3:
		return C.CString(lsp.GoWorkSyncJSON(path))
	default:
		return C.CString(lsp.InspectGoModJSON(path, content, checkUpdates != 0))
	}
}
