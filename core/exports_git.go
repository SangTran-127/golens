package main

import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
	"unsafe"

	"golens/core/fsutil"
)

const (
	gitCommandTimeout        = 60 * time.Second
	legacyGitCommandMaxBytes = 32 << 20
)

// Ownership: returns C.CString JSON GitExecResult freed with FreeGoCString. The path is the folder to run in; the mounted workspace root is inferred from opened workspaces.
//
//export RunGitCommand
func RunGitCommand(cWorkspacePath *C.char, cArgsJSON *C.char, cInput *C.char, inputLen C.int) *C.char {
	workspacePath := ""
	if cWorkspacePath != nil {
		workspacePath = C.GoString(cWorkspacePath)
	}
	argsJSON := ""
	if cArgsJSON != nil {
		argsJSON = C.GoString(cArgsJSON)
	}
	var input []byte
	if cInput != nil && inputLen > 0 {
		input = C.GoBytes(unsafe.Pointer(cInput), inputLen)
	}
	return C.CString(runGitCommandJSON(workspacePath, argsJSON, input))
}

func runGitCommandJSON(workspacePath, argsJSON string, input []byte) string {
	var res fsutil.GitRunResult
	if args, err := decodeGitArgs(argsJSON); err != nil {
		res = fsutil.GitRunResult{ExitCode: -1, Err: err}
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), gitCommandTimeout)
		defer cancel()
		res = fsutil.RunGitWithOptions(ctx, fsutil.GitRunOptions{Dir: workspacePath, Input: input, MaxOutput: legacyGitCommandMaxBytes}, args...)
	}
	out := fsutil.GitExecResult{
		Output:   string(res.Output),
		ExitCode: res.ExitCode,
	}
	if res.Err != nil {
		out.Error = res.Err.Error()
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// Ownership: strings and input are copied. root is the mounted workspace root (empty: only opened workspaces count) and dir the folder to run in. id (non-zero) lets CancelGitCommand stop the call; maxOutput (> 0) caps the bytes kept, the command is stopped once it is reached. Returns a C.malloc'd buffer of *outLen bytes freed with FreeGoBuffer: little-endian int32 exit code, uint32 flags (1 truncated, 2 VM unavailable, 4 cancelled, 8 outside the shared folders), uint32 error length, uint32 output length, then the error text and the raw output.
//
//export RunGitCommandEx
func RunGitCommandEx(id C.longlong, cRoot, cDir, cArgsJSON *C.char, cInput *C.char, inputLen C.int, maxOutput C.longlong, outLen *C.longlong) unsafe.Pointer {
	root := ""
	if cRoot != nil {
		root = C.GoString(cRoot)
	}
	dir := ""
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	argsJSON := ""
	if cArgsJSON != nil {
		argsJSON = C.GoString(cArgsJSON)
	}
	var input []byte
	if cInput != nil && inputLen > 0 {
		input = C.GoBytes(unsafe.Pointer(cInput), inputLen)
	}

	res := runGitCommandEx(int64(id), root, dir, argsJSON, input, int(maxOutput))
	size := fsutil.EncodedGitResultSize(res)
	buf := C.malloc(C.size_t(size))
	if buf == nil {
		if outLen != nil {
			*outLen = 0
		}
		return nil
	}
	fsutil.EncodeGitResult(unsafe.Slice((*byte)(buf), size), res)
	if outLen != nil {
		*outLen = C.longlong(size)
	}
	return buf
}

func runGitCommandEx(id int64, root, dir, argsJSON string, input []byte, maxOutput int) fsutil.GitRunResult {
	args, err := decodeGitArgs(argsJSON)
	if err != nil {
		return fsutil.GitRunResult{ExitCode: -1, Err: err}
	}
	fsutil.RegisterWorkspaceRoot(root)
	callCtx, done := fsutil.BeginGitCall(context.Background(), id)
	defer done()
	ctx, cancel := context.WithTimeout(callCtx, gitCommandTimeout)
	defer cancel()
	return fsutil.RunGitWithOptions(ctx, fsutil.GitRunOptions{Root: root, Dir: dir, Input: input, MaxOutput: maxOutput, Mounted: true}, args...)
}

func decodeGitArgs(argsJSON string) ([]string, error) {
	var args []string
	if argsJSON == "" {
		return args, nil
	}
	if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
		return nil, fmt.Errorf("invalid Git arguments: %v", err)
	}
	return args, nil
}

// Ownership: no pointers involved; stops the RunGitCommandEx call with this id, or the next one to start with it.
//
//export CancelGitCommand
func CancelGitCommand(id C.longlong) {
	fsutil.CancelGitCall(int64(id))
}

// Ownership: string is copied; sets the in-memory host credentials injected into Git commands.
//
//export SetGitCredentialsJSON
func SetGitCredentialsJSON(cJSON *C.char) {
	if cJSON == nil {
		fsutil.SetGitHostCredentials(nil)
		return
	}
	fsutil.SetGitHostCredentialsJSON(C.GoString(cJSON))
}

// Ownership: returns C.CString JSON SSHSigningDiscoveryResult freed with FreeGoCString.
//
//export DiscoverSSHSigningKeysJSON
func DiscoverSSHSigningKeysJSON(cExtraPathsJSON *C.char) *C.char {
	var extraPaths []string
	if cExtraPathsJSON != nil {
		_ = json.Unmarshal([]byte(C.GoString(cExtraPathsJSON)), &extraPaths)
	}
	res := fsutil.DiscoverSSHSigningKeys(extraPaths)
	b, _ := json.Marshal(res)
	return C.CString(string(b))
}

// Ownership: strings are copied. id lets CancelGitCommand stop the call (including an active security key touch prompt). Returns a C.malloc'd buffer of *outLen bytes freed with FreeGoBuffer using the same wire layout as RunGitCommandEx.
//
//export RunSignedGitCommitEx
func RunSignedGitCommitEx(id C.longlong, cRoot, cDir, cKeyPath, cMessage *C.char, amend C.int, outLen *C.longlong) unsafe.Pointer {
	root := ""
	if cRoot != nil {
		root = C.GoString(cRoot)
	}
	dir := ""
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	keyPath := ""
	if cKeyPath != nil {
		keyPath = C.GoString(cKeyPath)
	}
	message := ""
	if cMessage != nil {
		message = C.GoString(cMessage)
	}

	fsutil.RegisterWorkspaceRoot(root)
	callCtx, done := fsutil.BeginGitCall(context.Background(), int64(id))
	defer done()
	ctx, cancel := context.WithTimeout(callCtx, gitCommandTimeout)
	defer cancel()

	res := fsutil.RunSignedGitCommit(ctx, root, dir, keyPath, message, amend != 0)
	size := fsutil.EncodedGitResultSize(res)
	buf := C.malloc(C.size_t(size))
	if buf == nil {
		if outLen != nil {
			*outLen = 0
		}
		return nil
	}
	fsutil.EncodeGitResult(unsafe.Slice((*byte)(buf), size), res)
	if outLen != nil {
		*outLen = C.longlong(size)
	}
	return buf
}

// Ownership: strings are copied. id lets CancelGitCommand stop the call. Returns a C.malloc'd buffer of *outLen bytes freed with FreeGoBuffer using the same wire layout as RunGitCommandEx.
//
//export RunSignedGitTagEx
func RunSignedGitTagEx(id C.longlong, cRoot, cDir, cKeyPath, cTagName, cRevision, cMessage *C.char, outLen *C.longlong) unsafe.Pointer {
	root := ""
	if cRoot != nil {
		root = C.GoString(cRoot)
	}
	dir := ""
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	keyPath := ""
	if cKeyPath != nil {
		keyPath = C.GoString(cKeyPath)
	}
	tagName := ""
	if cTagName != nil {
		tagName = C.GoString(cTagName)
	}
	revision := ""
	if cRevision != nil {
		revision = C.GoString(cRevision)
	}
	message := ""
	if cMessage != nil {
		message = C.GoString(cMessage)
	}

	fsutil.RegisterWorkspaceRoot(root)
	callCtx, done := fsutil.BeginGitCall(context.Background(), int64(id))
	defer done()
	ctx, cancel := context.WithTimeout(callCtx, gitCommandTimeout)
	defer cancel()

	res := fsutil.RunSignedGitTag(ctx, root, dir, keyPath, tagName, revision, message)
	size := fsutil.EncodedGitResultSize(res)
	buf := C.malloc(C.size_t(size))
	if buf == nil {
		if outLen != nil {
			*outLen = 0
		}
		return nil
	}
	fsutil.EncodeGitResult(unsafe.Slice((*byte)(buf), size), res)
	if outLen != nil {
		*outLen = C.longlong(size)
	}
	return buf
}

// Ownership: returns C.CString JSON CommitSignatureVerification freed with FreeGoCString.
//
//export VerifyGitCommitSignatureJSON
func VerifyGitCommitSignatureJSON(cRawCommit *C.char, rawLen C.int, cAllowedSignersPath *C.char) *C.char {
	var raw []byte
	if cRawCommit != nil && rawLen > 0 {
		raw = C.GoBytes(unsafe.Pointer(cRawCommit), rawLen)
	}
	allowedPath := ""
	if cAllowedSignersPath != nil {
		allowedPath = C.GoString(cAllowedSignersPath)
	}
	email, pubKey := fsutil.ReadAllowedSigner(allowedPath)
	res := fsutil.VerifyCommitSignature(raw, email, pubKey)
	b, _ := json.Marshal(res)
	return C.CString(string(b))
}

// Ownership: returns C.CString (empty on success, error text on failure) freed with FreeGoCString.
//
//export WriteGitAllowedSigners
func WriteGitAllowedSigners(cPath, cEmail, cPubKey *C.char) *C.char {
	path := ""
	if cPath != nil {
		path = C.GoString(cPath)
	}
	email := ""
	if cEmail != nil {
		email = C.GoString(cEmail)
	}
	pubKey := ""
	if cPubKey != nil {
		pubKey = C.GoString(cPubKey)
	}
	if err := fsutil.WriteAllowedSignersFile(path, email, pubKey); err != nil {
		return C.CString(err.Error())
	}
	return C.CString("")
}
