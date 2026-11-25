package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type UnsafeSafetyIssue struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	FuncName           string `json:"funcName"`
	Expr               string `json:"expr"`
	Message            string `json:"message"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	ReplacementPreview string `json:"replacementPreview"`
	CanAutoFix         bool   `json:"canAutoFix"`
}

type UnsafeSafetyInspectResult struct {
	Issues            []UnsafeSafetyIssue `json:"issues"`
	CgoLeakCount      int                 `json:"cgoLeakCount"`
	UintptrSplitCount int                 `json:"uintptrSplitCount"`
	UnsafeSliceCount  int                 `json:"unsafeSliceCount"`
	Error             string              `json:"error,omitempty"`
}

type UnsafeSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type UnsafeSafetyIssueItem = UnsafeSafetyIssue
type UnsafeSafetyInspectResponse = UnsafeSafetyInspectResult
type UnsafeSafetyFixResponse = UnsafeSafetyFixResult

type UnsafeSafetyInspectRequest struct {
	Content   string `json:"content"`
	FilePath  string `json:"filePath"`
	Path      string `json:"path,omitempty"`
	Workspace string `json:"workspace,omitempty"`
}

type UnsafeSafetyFixRequest struct {
	Content   string `json:"content"`
	FilePath  string `json:"filePath"`
	Path      string `json:"path,omitempty"`
	Workspace string `json:"workspace,omitempty"`
	IssueID   string `json:"issueId"`
	All       bool   `json:"all"`
	ApplyAll  bool   `json:"applyAll,omitempty"`
}

type unsafeSafetyCandidate struct {
	issue          UnsafeSafetyIssue
	replaceStart   int
	replaceEnd     int
	replaceText    string
	needsUnsafePkg bool
}

type unsafeScopeInfo struct {
	unsafePkgAliases map[string]bool
	constIdents      map[string]bool
	unsafePtrIdents  map[string]bool
	boundsGuards     guardIndexCache
}

type uintptrVarBinding struct {
	varName   string
	rhsExpr   ast.Expr
	rhsText   string
	assignPos token.Pos
}

func InspectGoUnsafeSafety(content string, filePath string) (UnsafeSafetyInspectResult, error) {
	return inspectGoUnsafeSafetyWithWorkspace(content, filePath, "")
}

func inspectGoUnsafeSafetyWithWorkspace(content string, filePath string, workspace string) (UnsafeSafetyInspectResult, error) {
	res := UnsafeSafetyInspectResult{
		Issues: []UnsafeSafetyIssue{},
	}

	src, parsePath, err := resolveUnsafeSafetySource(filePath, content, workspace)
	if err != nil {
		res.Error = err.Error()
		return res, err
	}
	if strings.TrimSpace(src) == "" {
		return res, nil
	}

	fset := token.NewFileSet()
	astFile, parseErr := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		if parseErr != nil {
			res.Error = parseErr.Error()
			return res, parseErr
		}
		return res, nil
	}

	candidates := collectUnsafeSafetyCandidates(fset, astFile, src)
	issues := make([]UnsafeSafetyIssue, 0, len(candidates))
	for _, cand := range candidates {
		iss := cand.issue
		issues = append(issues, iss)
		switch iss.Category {
		case "cgo_cstring_leak":
			res.CgoLeakCount++
		case "uintptr_split_conversion":
			res.UintptrSplitCount++
		case "unsafe_slice_bounds":
			res.UnsafeSliceCount++
		}
	}
	res.Issues = issues

	return res, nil
}

func ApplyGoUnsafeSafetyFixes(content string, filePath string, issueID string, applyAll bool) (UnsafeSafetyFixResult, error) {
	return applyGoUnsafeSafetyFixesWithWorkspace(content, filePath, "", issueID, applyAll)
}

func applyGoUnsafeSafetyFixesWithWorkspace(
	content string,
	filePath string,
	workspace string,
	issueID string,
	applyAll bool,
) (UnsafeSafetyFixResult, error) {
	src, parsePath, err := resolveUnsafeSafetySource(filePath, content, workspace)
	if err != nil {
		return UnsafeSafetyFixResult{
			NewContent: content,
			Error:      err.Error(),
		}, err
	}
	if strings.TrimSpace(src) == "" {
		return UnsafeSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
		}, nil
	}

	currentSrc := src
	fixedCount := 0
	needsUnsafeImport := false
	targetID := strings.TrimSpace(issueID)

	if !applyAll {
		fset := token.NewFileSet()
		astFile, parseErr := parser.ParseFile(fset, parsePath, currentSrc, parser.ParseComments)
		if astFile == nil {
			errMsg := "failed to parse Go source"
			if parseErr != nil {
				errMsg = parseErr.Error()
			} else {
				parseErr = fmt.Errorf("%s", errMsg)
			}
			return UnsafeSafetyFixResult{
				NewContent: currentSrc,
				Error:      errMsg,
			}, parseErr
		}

		candidates := collectUnsafeSafetyCandidates(fset, astFile, currentSrc)
		var chosen *unsafeSafetyCandidate
		for i := range candidates {
			if !candidates[i].issue.CanAutoFix {
				continue
			}
			if targetID == "" || candidates[i].issue.ID == targetID {
				chosen = &candidates[i]
				break
			}
		}

		if chosen == nil {
			if targetID != "" {
				notFoundErr := fmt.Errorf("unsafe safety issue %q not found", targetID)
				return UnsafeSafetyFixResult{
					NewContent: currentSrc,
					FixedCount: 0,
					Error:      notFoundErr.Error(),
				}, notFoundErr
			}
			return UnsafeSafetyFixResult{
				NewContent: currentSrc,
				FixedCount: 0,
			}, nil
		}

		updatedSrc, ok := applySingleUnsafeSafetyCandidate(currentSrc, *chosen)
		if ok && updatedSrc != currentSrc {
			currentSrc = updatedSrc
			fixedCount = 1
			if chosen.needsUnsafePkg {
				needsUnsafeImport = true
			}
		}
	} else {
		fixer := unsafeSafetyFixer(parsePath)
		fixer.applied = func(c unsafeSafetyCandidate) {
			if c.needsUnsafePkg {
				needsUnsafeImport = true
			}
		}
		var firstErr error
		currentSrc, fixedCount, firstErr = fixer.run(currentSrc)
		if fixedCount == 0 && firstErr != nil {
			return UnsafeSafetyFixResult{
				NewContent: currentSrc,
				Error:      firstErr.Error(),
			}, firstErr
		}
	}

	if fixedCount > 0 {
		if needsUnsafeImport {
			currentSrc = ensureUnsafeImportInFile(parsePath, currentSrc)
		}
		if formatted, fmtErr := format.Source([]byte(currentSrc)); fmtErr == nil {
			currentSrc = string(formatted)
		}
	}

	return UnsafeSafetyFixResult{
		NewContent: currentSrc,
		FixedCount: fixedCount,
	}, nil
}

func InspectUnsafeSafety(reqJSON string) string {
	var req UnsafeSafetyInspectRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalUnsafeInspectResult(UnsafeSafetyInspectResult{
				Issues: []UnsafeSafetyIssue{},
				Error:  err.Error(),
			})
		}
	}
	targetPath := strings.TrimSpace(req.FilePath)
	if targetPath == "" {
		targetPath = strings.TrimSpace(req.Path)
	}
	res, _ := inspectGoUnsafeSafetyWithWorkspace(req.Content, targetPath, req.Workspace)
	return marshalUnsafeInspectResult(res)
}

func ApplyUnsafeSafetyFix(reqJSON string) string {
	var req UnsafeSafetyFixRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalUnsafeFixResult(UnsafeSafetyFixResult{
				Error: err.Error(),
			})
		}
		if strings.TrimSpace(req.IssueID) == "" {
			var alt struct {
				IssueID string `json:"issueID"`
			}
			if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.IssueID) != "" {
				req.IssueID = alt.IssueID
			}
		}
	}
	targetPath := strings.TrimSpace(req.FilePath)
	if targetPath == "" {
		targetPath = strings.TrimSpace(req.Path)
	}
	applyAll := req.All || req.ApplyAll
	res, _ := applyGoUnsafeSafetyFixesWithWorkspace(req.Content, targetPath, req.Workspace, req.IssueID, applyAll)
	return marshalUnsafeFixResult(res)
}

func marshalUnsafeInspectResult(res UnsafeSafetyInspectResult) string {
	if res.Issues == nil {
		res.Issues = []UnsafeSafetyIssue{}
	}
	data, err := json.Marshal(res)
	if err != nil {
		return `{"issues":[],"cgoLeakCount":0,"uintptrSplitCount":0,"unsafeSliceCount":0,"error":"failed to marshal unsafe safety inspect result"}`
	}
	return string(data)
}

func marshalUnsafeFixResult(res UnsafeSafetyFixResult) string {
	data, err := json.Marshal(res)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"failed to marshal unsafe safety fix result"}`
	}
	return string(data)
}

func resolveUnsafeSafetySource(filePath, content, workspace string) (string, string, error) {
	trimmedPath := strings.TrimSpace(filePath)
	parsePath := trimmedPath
	if parsePath == "" {
		parsePath = "input.go"
	}

	if content != "" {
		return content, parsePath, nil
	}
	if trimmedPath == "" {
		return "", parsePath, nil
	}

	if !filepath.IsAbs(trimmedPath) && strings.TrimSpace(workspace) != "" {
		candidate := filepath.Join(strings.TrimSpace(workspace), trimmedPath)
		if data, err := os.ReadFile(candidate); err == nil {
			return string(data), candidate, nil
		}
	}

	data, err := os.ReadFile(trimmedPath)
	if err != nil {
		return "", parsePath, err
	}
	return string(data), trimmedPath, nil
}

func applySingleUnsafeSafetyCandidate(src string, cand unsafeSafetyCandidate) (string, bool) {
	if cand.replaceStart < 0 || cand.replaceEnd < cand.replaceStart || cand.replaceEnd > len(src) {
		return src, false
	}
	updated := src[:cand.replaceStart] + cand.replaceText + src[cand.replaceEnd:]
	return updated, true
}

func collectUnsafeSafetyCandidates(
	fset *token.FileSet,
	file *ast.File,
	src string,
) []unsafeSafetyCandidate {
	var candidates []unsafeSafetyCandidate
	baseScope := collectPackageUnsafeScope(file)

	inspectBlockList := func(stmts []ast.Stmt, enclosingRoot ast.Node, funcName string, scope unsafeScopeInfo) {
		if len(stmts) == 0 {
			return
		}

		for idx, stmt := range stmts {
			varName, cgoMethod, ok := extractCgoAllocationStmt(stmt)
			if !ok {
				continue
			}
			if !blockFreesCgoVar(stmts[idx+1:], varName, scope.unsafePkgAliases) && !stmtReturnsBareIdent(stmts[idx+1:], varName) {
				if cand, ok := buildCgoCStringLeakCandidate(fset, stmt, varName, cgoMethod, funcName, src); ok {
					candidates = append(candidates, cand)
				}
			}
		}

		bindings := make(map[string]uintptrVarBinding)
		for _, stmt := range stmts {
			if varName, rhsExpr, ok := extractUintptrSplitBinding(stmt, scope); ok {
				rhsText := strings.TrimSpace(unsafeSliceNodeText(fset, src, rhsExpr))
				if rhsText != "" {
					bindings[varName] = uintptrVarBinding{
						varName:   varName,
						rhsExpr:   rhsExpr,
						rhsText:   rhsText,
						assignPos: stmt.Pos(),
					}
				}
				continue
			}

			if len(bindings) > 0 {
				ast.Inspect(stmt, func(n ast.Node) bool {
					if n == nil {
						return false
					}
					if _, isLit := n.(*ast.FuncLit); isLit {
						return false
					}
					if _, isBlk := n.(*ast.BlockStmt); isBlk {
						return true
					}
					call, isCall := n.(*ast.CallExpr)
					if !isCall {
						return true
					}
					pkgAlias, isUnsafePtr := matchUnsafePointerConversionCall(call, scope.unsafePkgAliases)
					if !isUnsafePtr || len(call.Args) != 1 {
						return true
					}
					arg := call.Args[0]
					for _, b := range bindings {
						if call.Pos() > b.assignPos && unsafeExprReferencesIdent(arg, b.varName) {
							if cand, ok := buildUintptrSplitCandidate(fset, call, pkgAlias, arg, b, funcName, src); ok {
								candidates = append(candidates, cand)
								break
							}
						}
					}
					return true
				})
			}

			if assign, isAssign := stmt.(*ast.AssignStmt); isAssign {
				for _, lhs := range assign.Lhs {
					if ident, isIdent := lhs.(*ast.Ident); isIdent {
						if _, exists := bindings[ident.Name]; exists {
							if _, _, stillUintptr := extractUintptrSplitBinding(stmt, scope); !stillUintptr {
								delete(bindings, ident.Name)
							}
						}
					}
				}
			}
		}
	}

	var walkBlocks func(root ast.Node, funcName string, scope unsafeScopeInfo)
	walkBlocks = func(root ast.Node, funcName string, scope unsafeScopeInfo) {
		if root == nil {
			return
		}
		if blk, isBlk := root.(*ast.BlockStmt); isBlk {
			inspectBlockList(blk.List, root, funcName, scope)
		}

		ast.Inspect(root, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if n != root {
				if _, isLit := n.(*ast.FuncLit); isLit {
					return false
				}
			}

			switch node := n.(type) {
			case *ast.BlockStmt:
				if node != root {
					inspectBlockList(node.List, root, funcName, scope)
				}
			case *ast.CaseClause:
				inspectBlockList(node.Body, root, funcName, scope)
			case *ast.CommClause:
				inspectBlockList(node.Body, root, funcName, scope)
			case *ast.CallExpr:
				if cand, ok := detectUnsafeSliceBounds(fset, node, root, funcName, scope, src); ok {
					candidates = append(candidates, cand)
				}
			}
			return true
		})
	}

	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			fnName := ""
			if d.Name != nil {
				fnName = d.Name.Name
			}
			scope := cloneUnsafeScope(baseScope)
			populateFuncUnsafeScope(&scope, d.Recv, d.Type, d.Body)
			if d.Body != nil {
				walkBlocks(d.Body, fnName, scope)
				ast.Inspect(d.Body, func(n ast.Node) bool {
					if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
						litScope := cloneUnsafeScope(scope)
						populateFuncUnsafeScope(&litScope, nil, lit.Type, lit.Body)
						walkBlocks(lit.Body, fnName, litScope)
					}
					return true
				})
			}

		case *ast.GenDecl:
			if d.Tok == token.IMPORT {
				continue
			}
			ast.Inspect(d, func(n ast.Node) bool {
				if n == nil {
					return false
				}
				if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
					litScope := cloneUnsafeScope(baseScope)
					populateFuncUnsafeScope(&litScope, nil, lit.Type, lit.Body)
					walkBlocks(lit.Body, "", litScope)
					return false
				}
				if call, ok := n.(*ast.CallExpr); ok {
					if cand, matched := detectUnsafeSliceBounds(fset, call, d, "", baseScope, src); matched {
						candidates = append(candidates, cand)
					}
				}
				return true
			})
		}
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].issue.Line != candidates[j].issue.Line {
			return candidates[i].issue.Line < candidates[j].issue.Line
		}
		if candidates[i].issue.Column != candidates[j].issue.Column {
			return candidates[i].issue.Column < candidates[j].issue.Column
		}
		return candidates[i].issue.Category < candidates[j].issue.Category
	})

	return candidates
}

func collectPackageUnsafeScope(file *ast.File) unsafeScopeInfo {
	scope := unsafeScopeInfo{
		unsafePkgAliases: map[string]bool{"unsafe": true},
		constIdents:      make(map[string]bool),
		unsafePtrIdents:  make(map[string]bool),
		boundsGuards:     guardIndexCache{},
	}
	if file == nil {
		return scope
	}

	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		importPath := strings.Trim(imp.Path.Value, `"`+"`")
		if importPath == "unsafe" {
			if imp.Name != nil && imp.Name.Name != "" && imp.Name.Name != "_" && imp.Name.Name != "." {
				scope.unsafePkgAliases[imp.Name.Name] = true
			}
		}
	}

	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gd.Specs {
			vs, isVS := spec.(*ast.ValueSpec)
			if !isVS {
				continue
			}
			isUnsafePtr := isUnsafePointerTypeExpr(vs.Type, scope.unsafePkgAliases)
			for _, ident := range vs.Names {
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				if gd.Tok == token.CONST {
					scope.constIdents[ident.Name] = true
				}
				if isUnsafePtr {
					scope.unsafePtrIdents[ident.Name] = true
				}
			}
		}
	}

	return scope
}

func cloneUnsafeScope(src unsafeScopeInfo) unsafeScopeInfo {
	dst := unsafeScopeInfo{
		unsafePkgAliases: make(map[string]bool, len(src.unsafePkgAliases)),
		constIdents:      make(map[string]bool, len(src.constIdents)),
		unsafePtrIdents:  make(map[string]bool, len(src.unsafePtrIdents)),
		boundsGuards:     src.boundsGuards,
	}
	for k, v := range src.unsafePkgAliases {
		dst.unsafePkgAliases[k] = v
	}
	for k, v := range src.constIdents {
		dst.constIdents[k] = v
	}
	for k, v := range src.unsafePtrIdents {
		dst.unsafePtrIdents[k] = v
	}
	return dst
}

func populateFuncUnsafeScope(
	scope *unsafeScopeInfo,
	recv *ast.FieldList,
	fnType *ast.FuncType,
	body *ast.BlockStmt,
) {
	if scope == nil {
		return
	}
	recordFields := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, field := range fl.List {
			if isUnsafePointerTypeExpr(field.Type, scope.unsafePkgAliases) {
				for _, ident := range field.Names {
					if ident != nil && ident.Name != "" && ident.Name != "_" {
						scope.unsafePtrIdents[ident.Name] = true
					}
				}
			}
		}
	}
	recordFields(recv)
	if fnType != nil {
		recordFields(fnType.Params)
		recordFields(fnType.Results)
	}
	if body == nil {
		return
	}

	ast.Inspect(body, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if n != body {
			if _, isLit := n.(*ast.FuncLit); isLit {
				return false
			}
		}
		switch node := n.(type) {
		case *ast.DeclStmt:
			gd, ok := node.Decl.(*ast.GenDecl)
			if !ok {
				return true
			}
			for _, spec := range gd.Specs {
				vs, isVS := spec.(*ast.ValueSpec)
				if !isVS {
					continue
				}
				isUnsafePtr := isUnsafePointerTypeExpr(vs.Type, scope.unsafePkgAliases)
				for idx, ident := range vs.Names {
					if ident == nil || ident.Name == "" || ident.Name == "_" {
						continue
					}
					if gd.Tok == token.CONST {
						scope.constIdents[ident.Name] = true
					}
					if isUnsafePtr {
						scope.unsafePtrIdents[ident.Name] = true
					} else if idx < len(vs.Values) {
						if _, ok := matchUnsafePointerConversionExpr(vs.Values[idx], scope.unsafePkgAliases); ok {
							scope.unsafePtrIdents[ident.Name] = true
						}
					}
				}
			}
		case *ast.AssignStmt:
			for idx, lhs := range node.Lhs {
				ident, isIdent := lhs.(*ast.Ident)
				if !isIdent || ident.Name == "" || ident.Name == "_" {
					continue
				}
				if idx < len(node.Rhs) {
					if _, ok := matchUnsafePointerConversionExpr(node.Rhs[idx], scope.unsafePkgAliases); ok {
						scope.unsafePtrIdents[ident.Name] = true
					}
				}
			}
		}
		return true
	})
}

func isUnsafePointerTypeExpr(typeExpr ast.Expr, unsafeAliases map[string]bool) bool {
	if typeExpr == nil {
		return false
	}
	sel, ok := unwrapUnsafeParens(typeExpr).(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Pointer" {
		return false
	}
	pkgIdent, ok := unwrapUnsafeParens(sel.X).(*ast.Ident)
	return ok && unsafeAliases[pkgIdent.Name]
}

func extractCgoAllocationStmt(stmt ast.Stmt) (varName string, cgoMethod string, ok bool) {
	switch s := stmt.(type) {
	case *ast.AssignStmt:
		if len(s.Lhs) != len(s.Rhs) {
			return "", "", false
		}
		for idx, rhs := range s.Rhs {
			method, isCgoAlloc := matchCgoAllocCall(rhs)
			if !isCgoAlloc {
				continue
			}
			ident, isIdent := s.Lhs[idx].(*ast.Ident)
			if !isIdent || ident.Name == "" || ident.Name == "_" {
				continue
			}
			return ident.Name, method, true
		}
	case *ast.DeclStmt:
		gd, isGen := s.Decl.(*ast.GenDecl)
		if !isGen || gd.Tok != token.VAR {
			return "", "", false
		}
		for _, spec := range gd.Specs {
			vs, isVS := spec.(*ast.ValueSpec)
			if !isVS || len(vs.Names) != len(vs.Values) {
				continue
			}
			for idx, val := range vs.Values {
				method, isCgoAlloc := matchCgoAllocCall(val)
				if !isCgoAlloc {
					continue
				}
				ident := vs.Names[idx]
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				return ident.Name, method, true
			}
		}
	}
	return "", "", false
}

func matchCgoAllocCall(expr ast.Expr) (string, bool) {
	call, ok := unwrapUnsafeParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) != 1 {
		return "", false
	}
	sel, ok := unwrapUnsafeParens(call.Fun).(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false
	}
	pkgIdent, ok := unwrapUnsafeParens(sel.X).(*ast.Ident)
	if !ok || pkgIdent.Name != "C" {
		return "", false
	}
	switch sel.Sel.Name {
	case "CString", "CBytes":
		return sel.Sel.Name, true
	default:
		return "", false
	}
}

func blockFreesCgoVar(stmts []ast.Stmt, varName string, unsafeAliases map[string]bool) bool {
	if varName == "" {
		return false
	}
	freed := false
	for _, stmt := range stmts {
		ast.Inspect(stmt, func(n ast.Node) bool {
			if freed || n == nil {
				return false
			}
			call, isCall := n.(*ast.CallExpr)
			if !isCall || len(call.Args) != 1 {
				return true
			}
			sel, isSel := unwrapUnsafeParens(call.Fun).(*ast.SelectorExpr)
			if !isSel || sel.Sel == nil || sel.Sel.Name != "free" {
				return true
			}
			pkgIdent, isIdent := unwrapUnsafeParens(sel.X).(*ast.Ident)
			if !isIdent || pkgIdent.Name != "C" {
				return true
			}
			if cgoFreeArgMatchesVar(call.Args[0], varName, unsafeAliases) {
				freed = true
				return false
			}
			return true
		})
		if freed {
			return true
		}
	}
	return false
}

func cgoFreeArgMatchesVar(arg ast.Expr, varName string, unsafeAliases map[string]bool) bool {
	unwrapped := unwrapUnsafeParens(arg)
	if ident, isIdent := unwrapped.(*ast.Ident); isIdent && ident.Name == varName {
		return true
	}
	if call, isCall := unwrapped.(*ast.CallExpr); isCall && len(call.Args) == 1 {
		if _, isUnsafePtr := matchUnsafePointerConversionCall(call, unsafeAliases); isUnsafePtr {
			if ident, isIdent := unwrapUnsafeParens(call.Args[0]).(*ast.Ident); isIdent && ident.Name == varName {
				return true
			}
		}
	}
	return unsafeExprReferencesIdent(unwrapped, varName)
}

func stmtReturnsBareIdent(stmts []ast.Stmt, varName string) bool {
	for _, stmt := range stmts {
		ret, isRet := stmt.(*ast.ReturnStmt)
		if !isRet {
			continue
		}
		for _, res := range ret.Results {
			if ident, isIdent := unwrapUnsafeParens(res).(*ast.Ident); isIdent && ident.Name == varName {
				return true
			}
		}
	}
	return false
}

func buildCgoCStringLeakCandidate(
	fset *token.FileSet,
	stmt ast.Stmt,
	varName string,
	cgoMethod string,
	funcName string,
	src string,
) (unsafeSafetyCandidate, bool) {
	pos := fset.Position(stmt.Pos())
	endPos := fset.Position(stmt.End())
	if pos.Offset < 0 || endPos.Offset <= pos.Offset || endPos.Offset > len(src) {
		return unsafeSafetyCandidate{}, false
	}

	stmtText := strings.TrimSpace(unsafeSliceNodeText(fset, src, stmt))
	deferStmt := fmt.Sprintf("defer C.free(unsafe.Pointer(%s))", varName)
	replacement := src[pos.Offset:endPos.Offset] + "\n\t" + deferStmt
	preview := fmt.Sprintf("%s; %s", stmtText, deferStmt)
	id := fmt.Sprintf("cgo_cstring_leak:%d:%d", pos.Line, pos.Column)

	return unsafeSafetyCandidate{
		issue: UnsafeSafetyIssue{
			ID:                 id,
			Category:           "cgo_cstring_leak",
			Severity:           "error",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               stmtText,
			Message:            fmt.Sprintf("CGO allocation %q from C.%s is never freed with C.free in this block, leaking native heap memory", varName, cgoMethod),
			Suggestion:         fmt.Sprintf("Add '%s' immediately after allocating %s so native memory is released on scope exit", deferStmt, varName),
			FixTitle:           fmt.Sprintf("Insert %s", deferStmt),
			ReplacementPreview: preview,
			CanAutoFix:         true,
		},
		replaceStart:   pos.Offset,
		replaceEnd:     endPos.Offset,
		replaceText:    replacement,
		needsUnsafePkg: true,
	}, true
}

func extractUintptrSplitBinding(stmt ast.Stmt, scope unsafeScopeInfo) (varName string, rhsExpr ast.Expr, ok bool) {
	switch s := stmt.(type) {
	case *ast.AssignStmt:
		if len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			return "", nil, false
		}
		ident, isIdent := s.Lhs[0].(*ast.Ident)
		if !isIdent || ident.Name == "" || ident.Name == "_" {
			return "", nil, false
		}
		if isUintptrFromUnsafePointerExpr(s.Rhs[0], scope) {
			return ident.Name, s.Rhs[0], true
		}
	case *ast.DeclStmt:
		gd, isGen := s.Decl.(*ast.GenDecl)
		if !isGen || gd.Tok != token.VAR || len(gd.Specs) != 1 {
			return "", nil, false
		}
		vs, isVS := gd.Specs[0].(*ast.ValueSpec)
		if !isVS || len(vs.Names) != 1 || len(vs.Values) != 1 {
			return "", nil, false
		}
		ident := vs.Names[0]
		if ident == nil || ident.Name == "" || ident.Name == "_" {
			return "", nil, false
		}
		if isUintptrFromUnsafePointerExpr(vs.Values[0], scope) {
			return ident.Name, vs.Values[0], true
		}
	}
	return "", nil, false
}

func isUintptrFromUnsafePointerExpr(expr ast.Expr, scope unsafeScopeInfo) bool {
	if expr == nil {
		return false
	}
	unwrapped := unwrapUnsafeParens(expr)

	if call, isCall := unwrapped.(*ast.CallExpr); isCall && len(call.Args) == 1 {
		if fnIdent, isIdent := unwrapUnsafeParens(call.Fun).(*ast.Ident); isIdent && fnIdent.Name == "uintptr" {
			arg := unwrapUnsafeParens(call.Args[0])
			if _, isUnsafePtr := matchUnsafePointerConversionExpr(arg, scope.unsafePkgAliases); isUnsafePtr {
				return true
			}
			if argIdent, isArgIdent := arg.(*ast.Ident); isArgIdent && scope.unsafePtrIdents[argIdent.Name] {
				return true
			}
		}
	}

	if bin, isBin := unwrapped.(*ast.BinaryExpr); isBin {
		switch bin.Op {
		case token.ADD, token.SUB, token.AND_NOT, token.AND, token.OR, token.XOR:
			return isUintptrFromUnsafePointerExpr(bin.X, scope) || isUintptrFromUnsafePointerExpr(bin.Y, scope)
		default:
		}
	}

	return false
}

func matchUnsafePointerConversionExpr(expr ast.Expr, unsafeAliases map[string]bool) (string, bool) {
	call, ok := unwrapUnsafeParens(expr).(*ast.CallExpr)
	if !ok {
		return "", false
	}
	return matchUnsafePointerConversionCall(call, unsafeAliases)
}

func matchUnsafePointerConversionCall(call *ast.CallExpr, unsafeAliases map[string]bool) (string, bool) {
	if call == nil || len(call.Args) != 1 {
		return "", false
	}
	sel, ok := unwrapUnsafeParens(call.Fun).(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Pointer" {
		return "", false
	}
	pkgIdent, ok := unwrapUnsafeParens(sel.X).(*ast.Ident)
	if !ok || !unsafeAliases[pkgIdent.Name] {
		return "", false
	}
	return pkgIdent.Name, true
}

func buildUintptrSplitCandidate(
	fset *token.FileSet,
	call *ast.CallExpr,
	pkgAlias string,
	arg ast.Expr,
	binding uintptrVarBinding,
	funcName string,
	src string,
) (unsafeSafetyCandidate, bool) {
	pos := fset.Position(call.Pos())
	endPos := fset.Position(call.End())
	if pos.Offset < 0 || endPos.Offset <= pos.Offset || endPos.Offset > len(src) {
		return unsafeSafetyCandidate{}, false
	}

	inlinedArg := inlineIdentInExprText(fset, src, arg, binding.varName, binding.rhsExpr, binding.rhsText)
	if inlinedArg == "" {
		return unsafeSafetyCandidate{}, false
	}

	replacement := fmt.Sprintf("%s.Pointer(%s)", pkgAlias, inlinedArg)
	exprStr := strings.TrimSpace(unsafeSliceNodeText(fset, src, call))
	id := fmt.Sprintf("uintptr_split_conversion:%d:%d", pos.Line, pos.Column)

	return unsafeSafetyCandidate{
		issue: UnsafeSafetyIssue{
			ID:                 id,
			Category:           "uintptr_split_conversion",
			Severity:           "error",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               exprStr,
			Message:            fmt.Sprintf("Splitting uintptr variable %q and %s across statements violates Go unsafe.Pointer GC pinning rules", binding.varName, exprStr),
			Suggestion:         fmt.Sprintf("Inline %s directly inside %s or use unsafe.Add so the pointer conversion happens in a single expression", binding.rhsText, replacement),
			FixTitle:           fmt.Sprintf("Inline %s inside %s.Pointer(...)", binding.rhsText, pkgAlias),
			ReplacementPreview: replacement,
			CanAutoFix:         true,
		},
		replaceStart:   pos.Offset,
		replaceEnd:     endPos.Offset,
		replaceText:    replacement,
		needsUnsafePkg: true,
	}, true
}

func inlineIdentInExprText(
	fset *token.FileSet,
	src string,
	expr ast.Expr,
	varName string,
	rhsExpr ast.Expr,
	rhsText string,
) string {
	exprStart := fset.Position(expr.Pos()).Offset
	exprEnd := fset.Position(expr.End()).Offset
	if exprStart < 0 || exprEnd <= exprStart || exprEnd > len(src) {
		return ""
	}

	type span struct {
		start int
		end   int
	}
	var spans []span
	ast.Inspect(expr, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if sel, isSel := n.(*ast.SelectorExpr); isSel {
			ast.Inspect(sel.X, func(sub ast.Node) bool {
				if ident, ok := sub.(*ast.Ident); ok && ident.Name == varName {
					s := fset.Position(ident.Pos()).Offset
					e := fset.Position(ident.End()).Offset
					if s >= exprStart && e <= exprEnd {
						spans = append(spans, span{start: s, end: e})
					}
				}
				return true
			})
			return false
		}
		if ident, ok := n.(*ast.Ident); ok && ident.Name == varName {
			s := fset.Position(ident.Pos()).Offset
			e := fset.Position(ident.End()).Offset
			if s >= exprStart && e <= exprEnd {
				spans = append(spans, span{start: s, end: e})
			}
		}
		return true
	})

	if len(spans) == 0 {
		return ""
	}

	subText := rhsText
	if _, isRhsBin := unwrapUnsafeParens(rhsExpr).(*ast.BinaryExpr); isRhsBin {
		if _, isOuterIdent := unwrapUnsafeParens(expr).(*ast.Ident); !isOuterIdent {
			subText = "(" + rhsText + ")"
		}
	}

	out := src[exprStart:exprEnd]
	for i := len(spans) - 1; i >= 0; i-- {
		relStart := spans[i].start - exprStart
		relEnd := spans[i].end - exprStart
		if relStart >= 0 && relEnd >= relStart && relEnd <= len(out) {
			out = out[:relStart] + subText + out[relEnd:]
		}
	}
	return strings.TrimSpace(out)
}

func detectUnsafeSliceBounds(
	fset *token.FileSet,
	call *ast.CallExpr,
	enclosingRoot ast.Node,
	funcName string,
	scope unsafeScopeInfo,
	src string,
) (unsafeSafetyCandidate, bool) {
	if call == nil || len(call.Args) != 2 {
		return unsafeSafetyCandidate{}, false
	}

	sel, ok := unwrapUnsafeParens(call.Fun).(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return unsafeSafetyCandidate{}, false
	}
	pkgIdent, ok := unwrapUnsafeParens(sel.X).(*ast.Ident)
	if !ok || !scope.unsafePkgAliases[pkgIdent.Name] {
		return unsafeSafetyCandidate{}, false
	}

	method := sel.Sel.Name
	if method != "Slice" && method != "String" {
		return unsafeSafetyCandidate{}, false
	}

	lenArg := call.Args[1]
	if isSafeUnsafeSliceLenExpr(lenArg, scope) {
		return unsafeSafetyCandidate{}, false
	}

	varName := extractPrimaryVarIdentFromLenExpr(lenArg, scope)
	if varName == "" {
		return unsafeSafetyCandidate{}, false
	}

	if enclosingRoot != nil && scope.boundsGuards.get(enclosingRoot, buildNonNegativeBoundsGuardIndex).before(varName, call.Pos()) {
		return unsafeSafetyCandidate{}, false
	}

	pos := fset.Position(call.Pos())
	lenStart := fset.Position(lenArg.Pos()).Offset
	lenEnd := fset.Position(lenArg.End()).Offset
	if lenStart < 0 || lenEnd <= lenStart || lenEnd > len(src) {
		return unsafeSafetyCandidate{}, false
	}

	ptrStr := strings.TrimSpace(unsafeSliceNodeText(fset, src, call.Args[0]))
	lenStr := strings.TrimSpace(unsafeSliceNodeText(fset, src, lenArg))
	if ptrStr == "" || lenStr == "" {
		return unsafeSafetyCandidate{}, false
	}

	wrappedLen := fmt.Sprintf("max(0, %s)", lenStr)
	preview := fmt.Sprintf("%s.%s(%s, %s)", pkgIdent.Name, method, ptrStr, wrappedLen)
	exprStr := strings.TrimSpace(unsafeSliceNodeText(fset, src, call))
	id := fmt.Sprintf("unsafe_slice_bounds:%d:%d", pos.Line, pos.Column)

	return unsafeSafetyCandidate{
		issue: UnsafeSafetyIssue{
			ID:                 id,
			Category:           "unsafe_slice_bounds",
			Severity:           "warning",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               exprStr,
			Message:            fmt.Sprintf("Unchecked length %q in %s.%s(%s, %s) panics or corrupts memory bounds if negative", lenStr, pkgIdent.Name, method, ptrStr, lenStr),
			Suggestion:         fmt.Sprintf("Validate %s >= 0 before calling %s.%s or clamp the length with %s", varName, pkgIdent.Name, method, wrappedLen),
			FixTitle:           fmt.Sprintf("Wrap length with %s", wrappedLen),
			ReplacementPreview: preview,
			CanAutoFix:         true,
		},
		replaceStart:   lenStart,
		replaceEnd:     lenEnd,
		replaceText:    wrappedLen,
		needsUnsafePkg: false,
	}, true
}

func isSafeUnsafeSliceLenExpr(expr ast.Expr, scope unsafeScopeInfo) bool {
	if expr == nil {
		return true
	}
	unwrapped := unwrapUnsafeParens(expr)

	switch node := unwrapped.(type) {
	case *ast.BasicLit:
		return node.Kind == token.INT || node.Kind == token.CHAR
	case *ast.Ident:
		if scope.constIdents[node.Name] || node.Name == "iota" {
			return true
		}
		if node.Obj != nil && node.Obj.Kind == ast.Con {
			return true
		}
		return false
	case *ast.CallExpr:
		if fnIdent, isIdent := unwrapUnsafeParens(node.Fun).(*ast.Ident); isIdent {
			switch fnIdent.Name {
			case "max":
				if len(node.Args) >= 2 {
					for _, arg := range node.Args {
						if isZeroIntLiteral(arg) {
							return true
						}
					}
				}
			case "len", "cap":
				return true
			}
		}
		if sel, isSel := unwrapUnsafeParens(node.Fun).(*ast.SelectorExpr); isSel && sel.Sel != nil {
			if pkgIdent, isIdent := unwrapUnsafeParens(sel.X).(*ast.Ident); isIdent && scope.unsafePkgAliases[pkgIdent.Name] {
				if sel.Sel.Name == "Sizeof" || sel.Sel.Name == "Alignof" || sel.Sel.Name == "Offsetof" {
					return true
				}
			}
		}
	case *ast.BinaryExpr:
		if isSafeUnsafeSliceLenExpr(node.X, scope) && isSafeUnsafeSliceLenExpr(node.Y, scope) {
			return true
		}
	}

	return false
}

func extractPrimaryVarIdentFromLenExpr(expr ast.Expr, scope unsafeScopeInfo) string {
	unwrapped := unwrapUnsafeParens(expr)
	switch node := unwrapped.(type) {
	case *ast.Ident:
		if !scope.constIdents[node.Name] && node.Name != "iota" && node.Name != "_" {
			return node.Name
		}
	case *ast.SelectorExpr:
		if node.Sel != nil {
			return node.Sel.Name
		}
	case *ast.CallExpr:
		if len(node.Args) == 1 {
			if fnIdent, isIdent := unwrapUnsafeParens(node.Fun).(*ast.Ident); isIdent {
				switch fnIdent.Name {
				case "int", "int64", "int32", "int16", "int8", "uint", "uint64", "uint32", " uintptr":
					return extractPrimaryVarIdentFromLenExpr(node.Args[0], scope)
				}
			}
		}
	case *ast.BinaryExpr:
		if left := extractPrimaryVarIdentFromLenExpr(node.X, scope); left != "" {
			return left
		}
		return extractPrimaryVarIdentFromLenExpr(node.Y, scope)
	}
	return ""
}

func unsafeIdentMatches(expr ast.Expr, varName string) bool {
	unwrapped := unwrapUnsafeParens(expr)
	if ident, ok := unwrapped.(*ast.Ident); ok && ident.Name == varName {
		return true
	}
	if sel, ok := unwrapped.(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == varName {
		return true
	}
	return false
}

func isNonNegativeIntBound(expr ast.Expr) bool {
	lit, ok := unwrapUnsafeParens(expr).(*ast.BasicLit)
	if !ok || lit.Kind != token.INT {
		return false
	}
	val, err := strconv.ParseInt(lit.Value, 0, 64)
	return err == nil && val >= 0
}

func isZeroIntLiteral(expr ast.Expr) bool {
	lit, ok := unwrapUnsafeParens(expr).(*ast.BasicLit)
	if !ok || lit.Kind != token.INT {
		return false
	}
	val, err := strconv.ParseInt(lit.Value, 0, 64)
	return err == nil && val == 0
}

func isMaxZeroClampExprForVar(expr ast.Expr, varName string) bool {
	call, ok := unwrapUnsafeParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) < 2 {
		return false
	}
	fnIdent, ok := unwrapUnsafeParens(call.Fun).(*ast.Ident)
	if !ok || fnIdent.Name != "max" {
		return false
	}
	hasZero := false
	hasVar := false
	for _, arg := range call.Args {
		if isZeroIntLiteral(arg) {
			hasZero = true
		}
		if unsafeExprReferencesIdent(arg, varName) {
			hasVar = true
		}
	}
	return hasZero && hasVar
}

func unsafeExprReferencesIdent(expr ast.Expr, name string) bool {
	if expr == nil || name == "" {
		return false
	}
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if ident, ok := n.(*ast.Ident); ok && ident.Name == name {
			found = true
			return false
		}
		return true
	})
	return found
}

func ensureUnsafeImportInFile(filePath, src string) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil || file == nil {
		return src
	}

	for _, imp := range file.Imports {
		if imp != nil && imp.Path != nil && strings.Trim(imp.Path.Value, `"`+"`") == "unsafe" {
			return src
		}
	}

	var nonCImportDecl *ast.GenDecl
	var cImportDecl *ast.GenDecl
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.IMPORT {
			continue
		}
		if isStandaloneCImportDecl(gd) {
			if cImportDecl == nil {
				cImportDecl = gd
			}
			continue
		}
		nonCImportDecl = gd
		break
	}

	if nonCImportDecl != nil {
		if nonCImportDecl.Lparen.IsValid() && nonCImportDecl.Rparen.IsValid() {
			rparenOff := fset.Position(nonCImportDecl.Rparen).Offset
			if rparenOff >= 0 && rparenOff <= len(src) {
				return src[:rparenOff] + "\t\"unsafe\"\n" + src[rparenOff:]
			}
		}
		startOff := fset.Position(nonCImportDecl.Pos()).Offset
		endOff := fset.Position(nonCImportDecl.End()).Offset
		if startOff >= 0 && endOff >= startOff && endOff <= len(src) {
			var specs []string
			for _, spec := range nonCImportDecl.Specs {
				is, ok := spec.(*ast.ImportSpec)
				if !ok || is.Path == nil {
					continue
				}
				if is.Name != nil && is.Name.Name != "" {
					specs = append(specs, fmt.Sprintf("\t%s %s", is.Name.Name, is.Path.Value))
				} else {
					specs = append(specs, fmt.Sprintf("\t%s", is.Path.Value))
				}
			}
			specs = append(specs, "\t\"unsafe\"")
			replacement := "import (\n" + strings.Join(specs, "\n") + "\n)"
			return src[:startOff] + replacement + src[endOff:]
		}
	}

	if cImportDecl != nil {
		endOff := fset.Position(cImportDecl.End()).Offset
		if endOff >= 0 && endOff <= len(src) {
			return src[:endOff] + "\n\nimport \"unsafe\"" + src[endOff:]
		}
	}

	return ensureGoImport(filePath, src, "unsafe")
}

func isStandaloneCImportDecl(gd *ast.GenDecl) bool {
	if gd == nil || gd.Tok != token.IMPORT || len(gd.Specs) != 1 {
		return false
	}
	imp, ok := gd.Specs[0].(*ast.ImportSpec)
	if !ok || imp.Path == nil {
		return false
	}
	return strings.Trim(imp.Path.Value, `"`+"`") == "C"
}

func unwrapUnsafeParens(expr ast.Expr) ast.Expr {
	curr := expr
	for {
		paren, ok := curr.(*ast.ParenExpr)
		if !ok {
			return curr
		}
		curr = paren.X
	}
}

func unsafeSliceNodeText(fset *token.FileSet, src string, node ast.Node) string {
	if node == nil {
		return ""
	}
	start := fset.Position(node.Pos()).Offset
	end := fset.Position(node.End()).Offset
	if start >= 0 && end > start && end <= len(src) {
		return src[start:end]
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, node); err == nil {
		return buf.String()
	}
	return ""
}

func unsafeSafetyFixer(parsePath string) lastCandidateFixer[unsafeSafetyCandidate] {
	return lastCandidateFixer[unsafeSafetyCandidate]{
		maxFixes: 64,
		scan: func(s string) ([]unsafeSafetyCandidate, bool, error) {
			fset := token.NewFileSet()
			astFile, parseErr := parser.ParseFile(fset, parsePath, s, parser.ParseComments)
			if astFile == nil || parseErr != nil {
				return nil, false, parseErr
			}
			return collectUnsafeSafetyCandidates(fset, astFile, s), true, nil
		},
		fixable: func(c unsafeSafetyCandidate) bool {
			return c.issue.CanAutoFix
		},
		span: func(_ string, c unsafeSafetyCandidate) (int, int, bool) {
			return c.replaceStart, c.replaceEnd, true
		},
		apply: applySingleUnsafeSafetyCandidate,
	}
}
