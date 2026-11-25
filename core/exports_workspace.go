package main

import "C"

import (
	"encoding/json"
	"errors"
	"os/exec"
	"strings"

	"golens/core/bridge"
	"golens/core/fsutil"
	"golens/core/lsp"
	"golens/core/search"
	"golens/core/toolchain"
)

// Ownership: mode ("host" or "vm") is copied; restarts gopls asynchronously when switching an active workspace.
//
//export SetExecutionEnvironment
func SetExecutionEnvironment(cMode *C.char) {
	if cMode == nil {
		return
	}
	mode := strings.ToLower(strings.TrimSpace(C.GoString(cMode)))
	prev := bridge.ExecutionMode()
	if prev != mode {
		bridge.SetExecutionMode(mode)
		if prev != "" && lsp.GetActiveDir() != "" {
			go lsp.RestartServer()
		}
	}
}

// Ownership: returns the tool's absolute path on GoLens's PATH, or "" when it is missing; free with FreeGoCString.
//
//export FindTool
func FindTool(cName *C.char) *C.char {
	path, err := exec.LookPath(C.GoString(cName))
	if err != nil {
		path = ""
	}
	return C.CString(path)
}

//export SetHostGoBinary
func SetHostGoBinary(cGoBinaryPath *C.char) {
	var goPath string
	if cGoBinaryPath != nil {
		goPath = C.GoString(cGoBinaryPath)
	}
	if applyCustomHostGoBinary(goPath) && bridge.ExecutionMode() == "host" && lsp.GetActiveDir() != "" {
		go lsp.RestartServer()
	}
}

// Ownership: path is copied; the caller keeps ownership.
//
//export OpenWorkspace
func OpenWorkspace(path *C.char) {
	root := C.GoString(path)
	fsutil.RegisterWorkspaceRoot(root)
	usageIndex.Open(root)
	lsp.OpenWorkspace(root)
}

// Ownership: path is copied; removes that project root from gopls and drops its usage index, stopping gopls when it was the last root.
//
//export CloseWorkspaceFolder
func CloseWorkspaceFolder(path *C.char) {
	root := C.GoString(path)
	usageIndex.CloseRoot(root)
	lsp.CloseWorkspaceFolder(root)
}

// Ownership: no pointers involved; stops gopls asynchronously.
//
//export CloseWorkspace
func CloseWorkspace() {
	fsutil.ForgetWorkspaceRoots()
	usageIndex.Close()
	lsp.CloseWorkspace()
}

// Ownership: arguments are copied; cancels the previous search and returns the new search id; results stream to the search callback.
//
//export StartProjectSearch
func StartProjectSearch(cRoot *C.char, cQuery *C.char) C.longlong {
	return C.longlong(search.Start(C.GoString(cRoot), C.GoString(cQuery)))
}

// Ownership: root is copied; returns a C.malloc'd JSON array of root-relative paths (project-search filters) freed with FreeGoCString.
//
//export ListProjectFiles
func ListProjectFiles(cRoot *C.char) *C.char {
	data, _ := json.Marshal(search.Files(C.GoString(cRoot)))
	return C.CString(string(data))
}

// Ownership: no pointers involved.
//
//export CancelProjectSearch
func CancelProjectSearch() {
	search.Cancel()
}

func conciseFSErrorReason(err error) string {
	if err == nil {
		return ""
	}
	cur := err
	for {
		next := errors.Unwrap(cur)
		if next == nil {
			break
		}
		cur = next
	}
	if msg := strings.TrimSpace(cur.Error()); msg != "" {
		return msg
	}
	return err.Error()
}

// Ownership: path is copied; returns NULL on success or a C.malloc'd UTF-8 error string freed with FreeGoCString.
//
//export CreateFileOrFolder
func CreateFileOrFolder(cPath *C.char, isFolder C.int) *C.char {
	if err := fsutil.CreateFileOrFolderWithError(C.GoString(cPath), isFolder != 0); err != nil {
		return C.CString(conciseFSErrorReason(err))
	}
	return nil
}

// Ownership: root is copied; returns a C.malloc'd JSON toolchain report freed with FreeGoCString.
//
//export ToolchainHealth
func ToolchainHealth(cRoot *C.char) *C.char {
	return C.CString(toolchain.CheckJSON(C.GoString(cRoot)))
}

// Ownership: returns a C.malloc'd error message ("" on success) freed with FreeGoCString.
//
//export AllowAutomaticToolchain
func AllowAutomaticToolchain() *C.char {
	return C.CString(toolchain.AllowAutomatic())
}
