package main

import "C"

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"

	"golens/core/analysis"
	"golens/core/goast"
	"golens/core/lsp"
	"golens/core/movedecl"
	"golens/core/refactor"
)

// Ownership: path is copied; returns a C.malloc'd identifier name when byteOffset is inside a declaration, else NULL; freed with FreeGoCString.
//
//export DeclarationAt
func DeclarationAt(cPath *C.char, byteOffset C.int) *C.char {
	src, err := lsp.DocumentContent(C.GoString(cPath))
	if err != nil {
		return nil
	}
	if name, ok := goast.DeclarationAt(src, int(byteOffset)); ok {
		return C.CString(name)
	}
	return nil
}

// Ownership: source is copied; returns a C.malloc'd JSON array of {name, kind, line, col} (1-based, UTF-16
//
//export GoDeclarations
func GoDeclarations(cSrc *C.char) *C.char {
	b, _ := json.Marshal(goast.Declarations([]byte(C.GoString(cSrc))))
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON FuncSignatureSpec (or "") freed with FreeGoCString.
//
//export InspectGoFuncSignature
func InspectGoFuncSignature(cPath *C.char, cSrc *C.char, offset C.int) *C.char {
	return C.CString(goast.InspectFuncSignature(C.GoString(cPath), []byte(C.GoString(cSrc)), int(offset)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ChangeSignatureResponse freed with FreeGoCString.
//
//export ApplyGoChangeSignature
func ApplyGoChangeSignature(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyChangeSignature(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ChangeSignatureResponse freed with FreeGoCString.
//
//export GenerateGoCode
func GenerateGoCode(cReqJSON *C.char) *C.char {
	reqJSON := C.GoString(cReqJSON)
	if out, ok := moveToOtherPackage(reqJSON); ok {
		return C.CString(out)
	}
	return C.CString(goast.GenerateCode(reqJSON))
}

func moveToOtherPackage(reqJSON string) (string, bool) {
	var req goast.GenerateCodeRequest
	if json.Unmarshal([]byte(reqJSON), &req) != nil {
		return "", false
	}
	kind := req.Kind
	if kind == "" {
		kind = req.Action
	}
	target := strings.TrimSpace(req.TargetName)
	if target == "" {
		target = strings.TrimSpace(req.Target)
	}
	if kind != "move_symbol" || !strings.ContainsRune(target, filepath.Separator) {
		return "", false
	}
	dest := target
	if !filepath.IsAbs(dest) {
		base := req.WorkspaceDir
		if base == "" {
			base = filepath.Dir(req.Path)
		}
		dest = filepath.Join(base, dest)
	}
	dest = filepath.Clean(dest)
	if !strings.HasSuffix(dest, ".go") {
		dest = filepath.Join(dest, filepath.Base(dest)+".go")
	}
	if filepath.Dir(dest) == filepath.Dir(filepath.Clean(req.Path)) {
		return "", false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	resp := movedecl.Move(ctx, movedecl.Request{Path: req.Path, Offset: req.Offset, Dest: dest, WorkspaceDir: req.WorkspaceDir, Buffers: req.Buffers})
	b, _ := json.Marshal(resp)
	return string(b), true
}

// Ownership: source is copied; returns a C.malloc'd JSON array of {startByte, endByte} spans freed with FreeGoCString.
//
//export GoSyntaxSelectionRanges
func GoSyntaxSelectionRanges(cSrc *C.char, offset C.int) *C.char {
	return C.CString(goast.SyntaxSelectionRanges(C.GoString(cSrc), int(offset)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON array of InterfaceCandidate freed with FreeGoCString.
//
//export ListGoWorkspaceInterfaces
func ListGoWorkspaceInterfaces(cWorkspaceDir *C.char, cCurrentPath *C.char) *C.char {
	return C.CString(goast.ListWorkspaceInterfaces(C.GoString(cWorkspaceDir), C.GoString(cCurrentPath)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON GenerateCodeResponse freed with FreeGoCString.
//
//export ModifyGoStructTags
func ModifyGoStructTags(cReqJSON *C.char) *C.char {
	return C.CString(goast.ModifyStructTags(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON JSONToStructResponse freed with FreeGoCString.
//
//export ConvertJSONToGoStruct
func ConvertJSONToGoStruct(cReqJSON *C.char) *C.char {
	return C.CString(goast.JSONToGoStruct(C.GoString(cReqJSON)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON StructLayoutReport freed with FreeGoCString.
//
//export InspectGoStructLayout
func InspectGoStructLayout(cPath *C.char, cSrc *C.char, offset C.int, cGoarch *C.char) *C.char {
	return C.CString(goast.InspectStructLayoutJSON(C.GoString(cPath), []byte(C.GoString(cSrc)), int(offset), C.GoString(cGoarch)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON IntentionReply freed with FreeGoCString.
//
//export ApplyGoASTIntention
func ApplyGoASTIntention(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyGoIntentionJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractMethodReply freed with FreeGoCString.
//
//export InspectGoExtractMethod
func InspectGoExtractMethod(cReqJSON *C.char) *C.char {
	return C.CString(goast.InspectExtractMethodJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractMethodReply freed with FreeGoCString.
//
//export ApplyGoExtractMethod
func ApplyGoExtractMethod(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyExtractMethodJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractVarReply freed with FreeGoCString.
//
//export ApplyGoExtractVariable
func ApplyGoExtractVariable(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyExtractVariableJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractVarReply freed with FreeGoCString.
//
//export ApplyGoInlineVariable
func ApplyGoInlineVariable(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyInlineVariableJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON GenerateTestReply freed with FreeGoCString.
//
//export GenerateGoTableDrivenTest
func GenerateGoTableDrivenTest(cReqJSON *C.char) *C.char {
	return C.CString(goast.GenerateTableDrivenTestJSON(C.GoString(cReqJSON)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON EscapeAnalysisResult freed with FreeGoCString.
//
//export AnalyzeGoEscape
func AnalyzeGoEscape(cWorkspacePath *C.char, cFilePath *C.char) *C.char {
	res, _ := goast.AnalyzeEscape(C.GoString(cWorkspacePath), C.GoString(cFilePath))
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON DisasmResult freed with FreeGoCString.
//
//export DisassembleGoFunction
func DisassembleGoFunction(cPkgDir, cFuncName, cArch *C.char) *C.char {
	var pkgDir, funcName, arch string
	if cPkgDir != nil {
		pkgDir = C.GoString(cPkgDir)
	}
	if cFuncName != nil {
		funcName = C.GoString(cFuncName)
	}
	if cArch != nil {
		arch = C.GoString(cArch)
	}
	res, err := goast.DisassembleFunction(pkgDir, funcName, arch)
	if err != nil {
		if res == nil {
			res = &goast.DisasmResult{
				Function:     funcName,
				TargetArch:   arch,
				Instructions: []goast.DisasmInstruction{},
				Error:        err.Error(),
			}
		} else if res.Error == "" {
			res.Error = err.Error()
		}
	}
	b, _ := json.Marshal(res)
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON array of GoGenerateDirective freed with FreeGoCString.
//
//export ScanGoGenerateFile
func ScanGoGenerateFile(cFilePath *C.char, cSrc *C.char) *C.char {
	res, _ := goast.ScanGoGenerateDirectives(C.GoString(cFilePath), C.GoString(cSrc))
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON array of WorkspaceSymbolItem freed with FreeGoCString.
//
//export SearchGoWorkspaceSymbols
func SearchGoWorkspaceSymbols(cWorkspacePath *C.char, cQuery *C.char, limit C.int) *C.char {
	return C.CString(goast.SearchWorkspaceSymbolsJSON(C.GoString(cWorkspacePath), C.GoString(cQuery), int(limit)))
}

// Ownership: path is copied; marks a saved, created or deleted .go file for re-indexing on the next symbol and usage query; a go.mod, go.work or go.sum change rebuilds the usage index.
//
//export InvalidateWorkspaceSymbolFile
func InvalidateWorkspaceSymbolFile(cPath *C.char) {
	path := C.GoString(cPath)
	goast.InvalidateWorkspaceSymbolFile(path)
	usageIndex.Invalidate(path)
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractTypeReply freed with FreeGoCString.
//
//export InspectGoExtractType
func InspectGoExtractType(cReqJSON *C.char) *C.char {
	return C.CString(goast.InspectExtractTypeJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractTypeReply freed with FreeGoCString.
//
//export ApplyGoExtractType
func ApplyGoExtractType(cReqJSON *C.char) *C.char {
	return C.CString(goast.ApplyExtractTypeJSON(C.GoString(cReqJSON)))
}

// Ownership: request JSON is copied; returns a C.malloc'd JSON ExtractTypeReply freed with FreeGoCString.
//
//export PropagateGoInterfaceMethods
func PropagateGoInterfaceMethods(cReqJSON *C.char) *C.char {
	return C.CString(goast.PropagateInterfaceMethodsJSON(C.GoString(cReqJSON)))
}

// Ownership: returns a C.malloc'd JSON array of ContextualQuickFix freed with FreeGoCString.
//
//export ContextualASTQuickFixes
func ContextualASTQuickFixes(cFilePath, cContent *C.char, line C.int) *C.char {
	var filePath, content string
	if cFilePath != nil {
		filePath = C.GoString(cFilePath)
	}
	if cContent != nil {
		content = C.GoString(cContent)
	}
	fixes, _ := analysis.ContextualASTQuickFixes("", filePath, content, int(line))
	if fixes == nil {
		return C.CString("[]")
	}
	b, err := json.Marshal(fixes)
	if err != nil {
		return C.CString("[]")
	}
	return C.CString(string(b))
}

// Ownership: returns a C.malloc'd JSON MultiBufferResult freed with FreeGoCString.
//
//export BuildGoMultiBuffer
func BuildGoMultiBuffer(cQuery, cDir, cFilesJSON *C.char) *C.char {
	var query, dir, filesJSON string
	if cQuery != nil {
		query = C.GoString(cQuery)
	}
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	if cFilesJSON != nil {
		filesJSON = C.GoString(cFilesJSON)
	}

	var files []string
	if filesJSON != "" && filesJSON != "[]" {
		_ = json.Unmarshal([]byte(filesJSON), &files)
	}

	res, err := refactor.BuildGoMultiBuffer(query, dir, files)
	if err != nil {
		res = &refactor.MultiBufferResult{Error: err.Error()}
	}
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString(`{"error":"failed to marshal multi-buffer result"}`)
	}
	return C.CString(string(b))
}

//export BuildGoMultiBufferFromLocations
func BuildGoMultiBufferFromLocations(cDir, cLocationsJSON *C.char, contextLines C.int) *C.char {
	var dir, locsJSON string
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	if cLocationsJSON != nil {
		locsJSON = C.GoString(cLocationsJSON)
	}

	var locs []refactor.MatchLocation
	if locsJSON != "" {
		_ = json.Unmarshal([]byte(locsJSON), &locs)
	}

	res, err := refactor.BuildGoMultiBufferFromLocations(dir, locs, int(contextLines))
	if err != nil {
		res = &refactor.MultiBufferResult{Error: err.Error()}
	}
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString(`{"error":"failed to marshal multi-buffer locations result"}`)
	}
	return C.CString(string(b))
}

//export ApplyGoMultiBufferEdits
func ApplyGoMultiBufferEdits(cEditsJSON *C.char) *C.char {
	var editsJSON string
	if cEditsJSON != nil {
		editsJSON = C.GoString(cEditsJSON)
	}

	var fileEdits []refactor.MultiBufferFileEdit
	if err := json.Unmarshal([]byte(editsJSON), &fileEdits); err != nil {
		var excerpts []refactor.MultiBufferExcerpt
		if err2 := json.Unmarshal([]byte(editsJSON), &excerpts); err2 == nil {
			fileEdits = refactor.ExcerptsToFileEdits(excerpts)
		} else {
			res := &refactor.ApplyResult{Success: false, ErrorMessage: err.Error()}
			b, _ := json.Marshal(res)
			return C.CString(string(b))
		}
	}

	res, _ := refactor.ApplyGoMultiBufferEdits(fileEdits)
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString(`{"success":false,"errorMessage":"failed to marshal apply result"}`)
	}
	return C.CString(string(b))
}
