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
	"sort"
	"strings"
)

type TestingSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type TestingSafetyIssue struct {
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

type TestingSafetyInspectResult struct {
	Issues                     []TestingSafetyIssue `json:"issues"`
	FatalInGoroutineCount      int                  `json:"fatalInGoroutineCount"`
	ParallelSetenvCount        int                  `json:"parallelSetenvCount"`
	MissingHelperCount         int                  `json:"missingHelperCount"`
	SynctestBubbleCaptureCount int                  `json:"synctestBubbleCaptureCount,omitempty"`
	Error                      string               `json:"error,omitempty"`
}

type TestingSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type TestingSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type testingSafetyCandidate struct {
	issue        TestingSafetyIssue
	replaceStart int
	replaceEnd   int
	replaceText  string
}

func InspectTestingSafety(reqJSON string) string {
	var req TestingSafetyInspectRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			res := TestingSafetyInspectResult{
				Issues: []TestingSafetyIssue{},
				Error:  err.Error(),
			}
			return marshalTestingSafetyInspectResult(res)
		}
		if strings.TrimSpace(req.FilePath) == "" {
			var alt struct {
				Path string `json:"path"`
			}
			if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.Path) != "" {
				req.FilePath = alt.Path
			}
		}
	}

	res, err := InspectGoTestingSafety(req.Content, req.FilePath)
	if err != nil && res.Error == "" {
		res.Error = err.Error()
	}
	return marshalTestingSafetyInspectResult(res)
}

func ApplyTestingSafetyFix(reqJSON string) string {
	var req TestingSafetyFixRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalTestingSafetyFixResult(TestingSafetyFixResult{
				Error: err.Error(),
			})
		}
		var alt struct {
			Path    string `json:"path"`
			IssueID string `json:"issueID"`
		}
		if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil {
			if strings.TrimSpace(req.FilePath) == "" && strings.TrimSpace(alt.Path) != "" {
				req.FilePath = alt.Path
			}
			if strings.TrimSpace(req.IssueID) == "" && strings.TrimSpace(alt.IssueID) != "" {
				req.IssueID = alt.IssueID
			}
		}
	}

	res, err := ApplyGoTestingSafetyFixes(req.Content, req.FilePath, req.IssueID, req.All)
	if err != nil && res.Error == "" {
		res.Error = err.Error()
	}
	return marshalTestingSafetyFixResult(res)
}

func InspectGoTestingSafety(content string, filePath string) (TestingSafetyInspectResult, error) {
	res := TestingSafetyInspectResult{
		Issues: []TestingSafetyIssue{},
	}

	src, parsePath, err := resolveTestingSafetySource(content, filePath)
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

	fillTestingSafetyResult(&res, fset, astFile, src)

	if parseErr != nil && len(res.Issues) == 0 {
		res.Error = parseErr.Error()
		return res, parseErr
	}
	return res, nil
}

func ApplyGoTestingSafetyFixes(content string, filePath string, issueID string, applyAll bool) (TestingSafetyFixResult, error) {
	src, parsePath, err := resolveTestingSafetySource(content, filePath)
	if err != nil {
		return TestingSafetyFixResult{
			NewContent: content,
			Error:      err.Error(),
		}, err
	}
	if strings.TrimSpace(src) == "" {
		return TestingSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
		}, nil
	}

	fset := token.NewFileSet()
	astFile, parseErr := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		errMsg := "failed to parse Go source"
		if parseErr != nil {
			errMsg = parseErr.Error()
		}
		return TestingSafetyFixResult{
			NewContent: src,
			Error:      errMsg,
		}, parseErr
	}

	candidates := collectTestingSafetyCandidates(fset, astFile, src)
	targetID := strings.TrimSpace(issueID)
	if !applyAll && targetID == "" {
		applyAll = true
	}

	var selected []testingSafetyCandidate
	for _, cand := range candidates {
		if !cand.issue.CanAutoFix {
			continue
		}
		if !applyAll && cand.issue.ID != targetID {
			continue
		}
		if cand.replaceStart < 0 || cand.replaceEnd < cand.replaceStart || cand.replaceEnd > len(src) {
			continue
		}
		selected = append(selected, cand)
		if !applyAll && cand.issue.ID == targetID {
			break
		}
	}

	if len(selected) == 0 {
		if !applyAll && targetID != "" {
			notFoundErr := fmt.Errorf("testing safety issue %q not found", targetID)
			return TestingSafetyFixResult{
				NewContent: src,
				FixedCount: 0,
				Error:      notFoundErr.Error(),
			}, notFoundErr
		}
		return TestingSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
		}, nil
	}

	sort.SliceStable(selected, func(i, j int) bool {
		if selected[i].replaceStart != selected[j].replaceStart {
			return selected[i].replaceStart > selected[j].replaceStart
		}
		return selected[i].replaceEnd > selected[j].replaceEnd
	})

	updated := src
	applied := 0
	lastStart := len(src) + 1

	for _, cand := range selected {
		if cand.replaceEnd > lastStart {
			continue
		}
		updated = updated[:cand.replaceStart] + cand.replaceText + updated[cand.replaceEnd:]
		lastStart = cand.replaceStart
		applied++
	}

	if formatted, fmtErr := format.Source([]byte(updated)); fmtErr == nil {
		updated = string(formatted)
	} else if _, parseErr := parser.ParseFile(token.NewFileSet(), parsePath, updated, parser.AllErrors); parseErr != nil {
		return TestingSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
			Error:      fmt.Sprintf("aborted unsafe testing quick-fix: %v", parseErr),
		}, parseErr
	}

	return TestingSafetyFixResult{
		NewContent: updated,
		FixedCount: applied,
	}, nil
}

func fillTestingSafetyResult(res *TestingSafetyInspectResult, fset *token.FileSet, astFile *ast.File, src string) {
	candidates := collectTestingSafetyCandidates(fset, astFile, src)
	issues := make([]TestingSafetyIssue, 0, len(candidates))
	for _, cand := range candidates {
		iss := cand.issue
		issues = append(issues, iss)
		switch iss.Category {
		case "t_fatal_in_goroutine":
			res.FatalInGoroutineCount++
		case "parallel_setenv_conflict":
			res.ParallelSetenvCount++
		case "missing_test_helper":
			res.MissingHelperCount++
		case "synctest_bubble_capture":
			res.SynctestBubbleCaptureCount++
		}
	}
	res.Issues = issues
}

func resolveTestingSafetySource(content string, filePath string) (string, string, error) {
	trimmedPath := strings.TrimSpace(filePath)
	parsePath := trimmedPath
	if parsePath == "" {
		parsePath = "input_test.go"
	}
	if content != "" {
		return content, parsePath, nil
	}
	if trimmedPath != "" {
		data, err := os.ReadFile(trimmedPath)
		if err != nil {
			return "", parsePath, err
		}
		return string(data), parsePath, nil
	}
	return "", parsePath, nil
}

func collectTestingSafetyCandidates(
	fset *token.FileSet,
	file *ast.File,
	src string,
) []testingSafetyCandidate {
	var candidates []testingSafetyCandidate

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}

		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}

		knownTestingVars := make(map[string]bool)
		paramName, paramIsTesting := extractTestingParamFromFieldList(fset, fn.Type.Params)
		if paramIsTesting && paramName != "" {
			knownTestingVars[paramName] = true
		}
		collectTestingVarsInSubtests(fset, fn.Body, knownTestingVars)

		goroutineCandidates := detectFatalInGoroutines(fset, fn.Body, src, fnName, knownTestingVars)
		candidates = append(candidates, goroutineCandidates...)

		parallelCandidates := detectParallelSetenvConflicts(fset, fn.Body, src, fnName, knownTestingVars)
		candidates = append(candidates, parallelCandidates...)

		if fn.Recv == nil && paramIsTesting && paramName != "" && !isTopLevelTestEntryFunc(fnName) {
			if helperCand, ok := detectMissingTestHelper(fset, fn, src, fnName, paramName); ok {
				candidates = append(candidates, helperCand)
			}
		}
	}

	candidates = append(candidates, collectSynctestBubbleCaptureCandidates(fset, file, src)...)

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

func detectFatalInGoroutines(
	fset *token.FileSet,
	body *ast.BlockStmt,
	src string,
	enclosingFunc string,
	knownTestingVars map[string]bool,
) []testingSafetyCandidate {
	var results []testingSafetyCandidate
	seenCallPos := make(map[token.Pos]bool)

	checkFatalCall := func(call *ast.CallExpr, inBlock bool, canBareReturn bool) {
		if call == nil || seenCallPos[call.Pos()] {
			return
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return
		}
		recvIdent, ok := sel.X.(*ast.Ident)
		if !ok || !isTestingVarIdent(recvIdent.Name, knownTestingVars) {
			return
		}

		method := sel.Sel.Name
		var replacementMethod string
		switch method {
		case "Fatal":
			replacementMethod = "Error"
		case "Fatalf":
			replacementMethod = "Errorf"
		case "FailNow":
			replacementMethod = "Fail"
		case "SkipNow":
			replacementMethod = ""
		default:
			return
		}

		seenCallPos[call.Pos()] = true
		pos := fset.Position(call.Pos())
		callStart := fset.Position(call.Pos()).Offset
		callEnd := fset.Position(call.End()).Offset
		selStart := fset.Position(sel.Sel.Pos()).Offset
		selEnd := fset.Position(sel.Sel.End()).Offset
		if callStart < 0 || selStart < callStart || selEnd < selStart || callEnd < selEnd || callEnd > len(src) {
			return
		}

		origExpr := testingSafetyNodeString(fset, src, call)
		issueID := fmt.Sprintf("t_fatal_in_goroutine:%d:%d:%s", pos.Line, pos.Column, enclosingFunc)

		if replacementMethod == "" {
			results = append(results, testingSafetyCandidate{
				issue: TestingSafetyIssue{
					ID:         issueID,
					Category:   "t_fatal_in_goroutine",
					Severity:   "error",
					Line:       pos.Line,
					Column:     pos.Column,
					FuncName:   enclosingFunc,
					Expr:       origExpr,
					Message:    fmt.Sprintf("%s.%s called inside a spawned goroutine invokes runtime.Goexit() on a non-test goroutine", recvIdent.Name, method),
					Suggestion: fmt.Sprintf("Decide whether to skip before starting the goroutine; %s.%s must run on the test goroutine.", recvIdent.Name, method),
				},
				replaceStart: -1,
				replaceEnd:   -1,
			})
			return
		}

		previewExpr := buildRewrittenMethodCallPreview(fset, src, call, sel, replacementMethod)
		rewrittenCall := src[callStart:selStart] + replacementMethod + src[selEnd:callEnd]

		replaceStart := callStart
		replaceEnd := callEnd
		replaceText := rewrittenCall
		canAutoFix := true
		fixTitle := fmt.Sprintf("Replace %s.%s With %s.%s", recvIdent.Name, method, recvIdent.Name, replacementMethod)
		suggestion := fmt.Sprintf("Replace %s.%s with %s.%s and return inside goroutines so failure is recorded safely and execution stops without calling Goexit.", recvIdent.Name, method, recvIdent.Name, replacementMethod)

		if inBlock {
			if !canBareReturn {
				canAutoFix = false
				fixTitle = ""
			} else {
				lineEnd := callEnd
				for lineEnd < len(src) && src[lineEnd] != '\n' {
					lineEnd++
				}
				afterOnLine := strings.TrimSpace(src[callEnd:lineEnd])
				if afterOnLine == "" {
					replaceText = rewrittenCall + "\n\treturn"
				} else {
					replaceText = rewrittenCall + "; return"
				}
				previewExpr = previewExpr + "; return"
				fixTitle = fmt.Sprintf("Replace %s.%s With %s.%s and Return", recvIdent.Name, method, recvIdent.Name, replacementMethod)
			}
		}

		results = append(results, testingSafetyCandidate{
			issue: TestingSafetyIssue{
				ID:                 issueID,
				Category:           "t_fatal_in_goroutine",
				Severity:           "error",
				Line:               pos.Line,
				Column:             pos.Column,
				FuncName:           enclosingFunc,
				Expr:               origExpr,
				Message:            fmt.Sprintf("%s.%s called inside a spawned goroutine invokes runtime.Goexit() on a non-test goroutine", recvIdent.Name, method),
				Suggestion:         suggestion,
				FixTitle:           fixTitle,
				ReplacementPreview: previewExpr,
				CanAutoFix:         canAutoFix,
			},
			replaceStart: replaceStart,
			replaceEnd:   replaceEnd,
			replaceText:  replaceText,
		})
	}

	ast.Inspect(body, func(n ast.Node) bool {
		goStmt, ok := n.(*ast.GoStmt)
		if !ok || goStmt.Call == nil {
			return true
		}

		checkFatalCall(goStmt.Call, false, false)

		if fnLit := unwrapFuncLit(goStmt.Call.Fun); fnLit != nil && fnLit.Body != nil {
			var inspectGoroutineBody func(node ast.Node, curFuncType *ast.FuncType)
			inspectGoroutineBody = func(node ast.Node, curFuncType *ast.FuncType) {
				if node == nil {
					return
				}
				ast.Inspect(node, func(inner ast.Node) bool {
					if inner == nil || inner == node {
						return true
					}
					if nestedLit, isLit := inner.(*ast.FuncLit); isLit {
						if nestedLit.Body != nil {
							inspectGoroutineBody(nestedLit.Body, nestedLit.Type)
						}
						return false
					}
					if call, ok := inner.(*ast.CallExpr); ok {
						canBare := curFuncType == nil || curFuncType.Results == nil || len(curFuncType.Results.List) == 0
						checkFatalCall(call, true, canBare)
					}
					return true
				})
			}
			inspectGoroutineBody(fnLit.Body, fnLit.Type)
		}
		return true
	})

	return results
}

func detectParallelSetenvConflicts(
	fset *token.FileSet,
	fnBody *ast.BlockStmt,
	src string,
	enclosingFunc string,
	knownTestingVars map[string]bool,
) []testingSafetyCandidate {
	var results []testingSafetyCandidate
	seenParallelPos := make(map[token.Pos]bool)

	var inspectScope func(scopeBody *ast.BlockStmt, scopeName string)
	inspectScope = func(scopeBody *ast.BlockStmt, scopeName string) {
		if scopeBody == nil {
			return
		}

		var parallelCalls []*ast.CallExpr
		var setenvCalls []*ast.CallExpr

		var walkDirect func(node ast.Node)
		walkDirect = func(node ast.Node) {
			if node == nil {
				return
			}
			if subLit, ok := node.(*ast.FuncLit); ok {
				if subLit.Body != nil {
					inspectScope(subLit.Body, scopeName)
				}
				return
			}

			if call, ok := node.(*ast.CallExpr); ok {
				if isTestingParallelCall(call, knownTestingVars) {
					parallelCalls = append(parallelCalls, call)
				} else if isSetenvCall(call, knownTestingVars) {
					setenvCalls = append(setenvCalls, call)
				}
				if subName, subLit := matchSubtestRunCall(call, knownTestingVars); subLit != nil && subLit.Body != nil {
					childScope := scopeName
					if subName != "" {
						childScope = scopeName + "/" + subName
					}
					inspectScope(subLit.Body, childScope)
					for _, arg := range call.Args {
						if arg != subLit {
							walkDirect(arg)
						}
					}
					return
				}
			}

			ast.Inspect(node, func(child ast.Node) bool {
				if child == nil || child == node {
					return true
				}
				if _, isLit := child.(*ast.FuncLit); isLit {
					walkDirect(child)
					return false
				}
				if call, ok := child.(*ast.CallExpr); ok {
					if isTestingParallelCall(call, knownTestingVars) {
						parallelCalls = append(parallelCalls, call)
					} else if isSetenvCall(call, knownTestingVars) {
						setenvCalls = append(setenvCalls, call)
					}
					if subName, subLit := matchSubtestRunCall(call, knownTestingVars); subLit != nil && subLit.Body != nil {
						childScope := scopeName
						if subName != "" {
							childScope = scopeName + "/" + subName
						}
						inspectScope(subLit.Body, childScope)
						return false
					}
				}
				return true
			})
		}

		walkDirect(scopeBody)

		if len(parallelCalls) > 0 && len(setenvCalls) == 0 {
			ast.Inspect(scopeBody, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if isSetenvCall(call, knownTestingVars) {
					setenvCalls = append(setenvCalls, call)
				}
				return true
			})
		}

		if len(parallelCalls) == 0 || len(setenvCalls) == 0 {
			return
		}

		setenvExpr := testingSafetyNodeString(fset, src, setenvCalls[0])
		setenvLine := fset.Position(setenvCalls[0].Pos()).Line

		for _, pCall := range parallelCalls {
			if seenParallelPos[pCall.Pos()] {
				continue
			}
			seenParallelPos[pCall.Pos()] = true

			pos := fset.Position(pCall.Pos())
			parallelExpr := testingSafetyNodeString(fset, src, pCall)
			remStart, remEnd := computeStmtRemovalOffsets(fset, src, pCall)
			issueID := fmt.Sprintf("parallel_setenv_conflict:%d:%d:%s", pos.Line, pos.Column, scopeName)

			results = append(results, testingSafetyCandidate{
				issue: TestingSafetyIssue{
					ID:                 issueID,
					Category:           "parallel_setenv_conflict",
					Severity:           "error",
					Line:               pos.Line,
					Column:             pos.Column,
					FuncName:           scopeName,
					Expr:               parallelExpr,
					Message:            fmt.Sprintf("%s conflicts with %s (line %d) in the same test scope and panics at runtime", parallelExpr, setenvExpr, setenvLine),
					Suggestion:         fmt.Sprintf("Remove %s when mutating process environment variables with %s.", parallelExpr, setenvExpr),
					FixTitle:           fmt.Sprintf("Remove %s", parallelExpr),
					ReplacementPreview: fmt.Sprintf("// %s removed (incompatible with %s)", parallelExpr, setenvExpr),
					CanAutoFix:         remStart >= 0 && remEnd > remStart,
				},
				replaceStart: remStart,
				replaceEnd:   remEnd,
				replaceText:  "",
			})
		}
	}

	inspectScope(fnBody, enclosingFunc)
	return results
}

func detectMissingTestHelper(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	src string,
	fnName string,
	paramName string,
) (testingSafetyCandidate, bool) {
	if fn == nil || fn.Body == nil {
		return testingSafetyCandidate{}, false
	}

	hasHelperCall := false
	var firstAssertionCall *ast.CallExpr

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		recv, ok := sel.X.(*ast.Ident)
		if !ok || recv.Name != paramName {
			return true
		}
		switch sel.Sel.Name {
		case "Helper":
			hasHelperCall = true
		case "Fatal", "Fatalf", "Error", "Errorf", "Fail", "FailNow":
			if firstAssertionCall == nil {
				firstAssertionCall = call
			}
		}
		return true
	})

	if hasHelperCall || firstAssertionCall == nil {
		return testingSafetyCandidate{}, false
	}

	lbracePos := fset.Position(fn.Body.Lbrace)
	insertOffset := lbracePos.Offset + 1
	if insertOffset < 1 || insertOffset > len(src) {
		return testingSafetyCandidate{}, false
	}

	fnPos := fset.Position(fn.Pos())
	assertExpr := testingSafetyNodeString(fset, src, firstAssertionCall)
	helperStmt := paramName + ".Helper()"

	insertText := "\n\t" + helperStmt
	rbracePos := fset.Position(fn.Body.Rbrace)
	if lbracePos.Line == rbracePos.Line {
		insertText = "\n\t" + helperStmt + "\n"
	}

	sigPreview := fmt.Sprintf("func %s(%s *testing.T)", fnName, paramName)
	if fn.Type != nil {
		sigText := strings.TrimSpace(testingSafetyNodeString(fset, src, fn.Type))
		if strings.HasPrefix(sigText, "func") {
			sigPreview = "func " + fnName + strings.TrimPrefix(sigText, "func")
		}
	}

	issueID := fmt.Sprintf("missing_test_helper:%d:%d:%s", fnPos.Line, fnPos.Column, fnName)
	return testingSafetyCandidate{
		issue: TestingSafetyIssue{
			ID:                 issueID,
			Category:           "missing_test_helper",
			Severity:           "warning",
			Line:               fnPos.Line,
			Column:             fnPos.Column,
			FuncName:           fnName,
			Expr:               sigPreview,
			Message:            fmt.Sprintf("Test helper %s calls %s without calling %s at the start of the function", fnName, assertExpr, helperStmt),
			Suggestion:         fmt.Sprintf("Call %s as the first statement of %s so failure stack traces report the caller's line number.", helperStmt, fnName),
			FixTitle:           fmt.Sprintf("Add %s to %s", helperStmt, fnName),
			ReplacementPreview: fmt.Sprintf("%s { %s; ... }", sigPreview, helperStmt),
			CanAutoFix:         true,
		},
		replaceStart: insertOffset,
		replaceEnd:   insertOffset,
		replaceText:  insertText,
	}, true
}

func extractTestingParamFromFieldList(fset *token.FileSet, fields *ast.FieldList) (string, bool) {
	if fields == nil {
		return "", false
	}
	for _, field := range fields.List {
		if field == nil || field.Type == nil {
			continue
		}
		if !isTestingTypeExpr(fset, field.Type) {
			continue
		}
		for _, nameIdent := range field.Names {
			if nameIdent != nil && nameIdent.Name != "" && nameIdent.Name != "_" {
				return nameIdent.Name, true
			}
		}
	}
	return "", false
}

func isTestingTypeExpr(fset *token.FileSet, expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, expr); err != nil {
		return false
	}
	typeStr := strings.TrimSpace(buf.String())
	switch typeStr {
	case "*testing.T", "*testing.B", "*testing.F", "testing.TB", "*testing.TB", "*T", "*B", "*F", "TB":
		return true
	default:
		return false
	}
}

func collectTestingVarsInSubtests(fset *token.FileSet, body *ast.BlockStmt, vars map[string]bool) {
	if body == nil {
		return
	}
	ast.Inspect(body, func(n ast.Node) bool {
		lit, ok := n.(*ast.FuncLit)
		if !ok || lit.Type == nil {
			return true
		}
		if name, ok := extractTestingParamFromFieldList(fset, lit.Type.Params); ok && name != "" {
			vars[name] = true
		}
		return true
	})
}

func isTestingVarIdent(name string, knownTestingVars map[string]bool) bool {
	if knownTestingVars[name] {
		return true
	}
	switch name {
	case "t", "tb", "b", "f":
		return true
	default:
		return false
	}
}

func isTopLevelTestEntryFunc(name string) bool {
	if name == "" || name == "TestMain" {
		return true
	}
	for _, prefix := range []string{"Test", "Benchmark", "Fuzz", "Example"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func isTestingParallelCall(call *ast.CallExpr, knownTestingVars map[string]bool) bool {
	if call == nil || len(call.Args) != 0 {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Parallel" {
		return false
	}
	recv, ok := sel.X.(*ast.Ident)
	return ok && isTestingVarIdent(recv.Name, knownTestingVars)
}

func isSetenvCall(call *ast.CallExpr, knownTestingVars map[string]bool) bool {
	if call == nil || len(call.Args) < 2 {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Setenv" {
		return false
	}
	recv, ok := sel.X.(*ast.Ident)
	if !ok {
		return false
	}
	return recv.Name == "os" || isTestingVarIdent(recv.Name, knownTestingVars)
}

func matchSubtestRunCall(call *ast.CallExpr, knownTestingVars map[string]bool) (string, *ast.FuncLit) {
	if call == nil || len(call.Args) != 2 {
		return "", nil
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Run" {
		return "", nil
	}
	recv, ok := sel.X.(*ast.Ident)
	if !ok || !isTestingVarIdent(recv.Name, knownTestingVars) {
		return "", nil
	}
	fnLit := unwrapFuncLit(call.Args[1])
	if fnLit == nil {
		return "", nil
	}
	subName := ""
	if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
		subName = strings.Trim(lit.Value, "`\"")
	}
	return subName, fnLit
}

func unwrapFuncLit(expr ast.Expr) *ast.FuncLit {
	for expr != nil {
		if p, ok := expr.(*ast.ParenExpr); ok {
			expr = p.X
			continue
		}
		if lit, ok := expr.(*ast.FuncLit); ok {
			return lit
		}
		return nil
	}
	return nil
}

func computeStmtRemovalOffsets(fset *token.FileSet, src string, call *ast.CallExpr) (int, int) {
	startOff := fset.Position(call.Pos()).Offset
	endOff := fset.Position(call.End()).Offset
	if startOff < 0 || endOff < startOff || endOff > len(src) {
		return -1, -1
	}

	lineStart := startOff
	for lineStart > 0 && src[lineStart-1] != '\n' {
		lineStart--
	}
	lineEnd := endOff
	for lineEnd < len(src) && src[lineEnd] != '\n' {
		lineEnd++
	}

	beforeOnLine := strings.TrimSpace(src[lineStart:startOff])
	afterOnLine := strings.TrimSpace(src[endOff:lineEnd])
	if beforeOnLine == "" && (afterOnLine == "" || strings.HasPrefix(afterOnLine, "//")) {
		if lineEnd < len(src) && src[lineEnd] == '\n' {
			return lineStart, lineEnd + 1
		}
		return lineStart, lineEnd
	}

	curEnd := endOff
	for curEnd < lineEnd && (src[curEnd] == ' ' || src[curEnd] == '\t') {
		curEnd++
	}
	if curEnd < lineEnd && src[curEnd] == ';' {
		curEnd++
		for curEnd < lineEnd && (src[curEnd] == ' ' || src[curEnd] == '\t') {
			curEnd++
		}
	}
	return startOff, curEnd
}

func buildRewrittenMethodCallPreview(
	fset *token.FileSet,
	src string,
	call *ast.CallExpr,
	sel *ast.SelectorExpr,
	replacementMethod string,
) string {
	callStart := fset.Position(call.Pos()).Offset
	callEnd := fset.Position(call.End()).Offset
	selStart := fset.Position(sel.Sel.Pos()).Offset
	selEnd := fset.Position(sel.Sel.End()).Offset
	if callStart >= 0 && selStart >= callStart && selEnd >= selStart && callEnd >= selEnd && callEnd <= len(src) {
		rewritten := src[callStart:selStart] + replacementMethod + src[selEnd:callEnd]
		return collapseTestingSafetyWhitespace(rewritten)
	}
	return replacementMethod + "(...)"
}

func testingSafetyNodeString(fset *token.FileSet, src string, node ast.Node) string {
	if node == nil {
		return ""
	}
	start := fset.Position(node.Pos()).Offset
	end := fset.Position(node.End()).Offset
	if start >= 0 && end >= start && end <= len(src) {
		return collapseTestingSafetyWhitespace(src[start:end])
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, node); err == nil {
		return collapseTestingSafetyWhitespace(buf.String())
	}
	return ""
}

func collapseTestingSafetyWhitespace(s string) string {
	fields := strings.Fields(strings.TrimSpace(s))
	return strings.Join(fields, " ")
}

func marshalTestingSafetyInspectResult(res TestingSafetyInspectResult) string {
	if res.Issues == nil {
		res.Issues = []TestingSafetyIssue{}
	}
	data, err := json.Marshal(res)
	if err != nil {
		return `{"issues":[],"fatalInGoroutineCount":0,"parallelSetenvCount":0,"missingHelperCount":0,"error":"failed to marshal testing safety inspect result"}`
	}
	return string(data)
}

func marshalTestingSafetyFixResult(res TestingSafetyFixResult) string {
	data, err := json.Marshal(res)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"failed to marshal testing safety fix result"}`
	}
	return string(data)
}

type synctestVarKind string

const (
	synctestKindNone    synctestVarKind = ""
	synctestKindSafe    synctestVarKind = "safe"
	synctestKindChannel synctestVarKind = "channel"
	synctestKindTimer   synctestVarKind = "*time.Timer"
	synctestKindTicker  synctestVarKind = "*time.Ticker"
)

type synctestImports struct {
	hasSynctest   bool
	synctestAlias string
	timeAlias     string
}

func collectSynctestImports(file *ast.File) synctestImports {
	info := synctestImports{
		synctestAlias: "synctest",
		timeAlias:     "time",
	}
	if file == nil {
		return info
	}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.Trim(imp.Path.Value, `"`+"`")
		alias := ""
		if imp.Name != nil {
			alias = imp.Name.Name
		}
		if alias == "_" {
			continue
		}
		switch p {
		case "testing/synctest":
			info.hasSynctest = true
			if alias != "" {
				info.synctestAlias = alias
			}
		case "time":
			if alias != "" && alias != "." {
				info.timeAlias = alias
			}
		}
	}
	return info
}

func collectSynctestBubbleCaptureIssues(fset *token.FileSet, file *ast.File, src string) []TestingSafetyIssue {
	cands := collectSynctestBubbleCaptureCandidates(fset, file, src)
	if len(cands) == 0 {
		return nil
	}
	issues := make([]TestingSafetyIssue, 0, len(cands))
	for _, c := range cands {
		issues = append(issues, c.issue)
	}
	return issues
}

func collectSynctestBubbleCaptureCandidates(fset *token.FileSet, file *ast.File, src string) []testingSafetyCandidate {
	if fset == nil || file == nil {
		return nil
	}
	imports := collectSynctestImports(file)
	if !imports.hasSynctest {
		return nil
	}

	pkgScope := make(map[string]synctestVarKind)
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.VAR {
			continue
		}
		for _, spec := range gd.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			recordSynctestValueSpec(vs, []map[string]synctestVarKind{pkgScope}, imports, true)
		}
	}

	var candidates []testingSafetyCandidate
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}
		scopes := []map[string]synctestVarKind{pkgScope, make(map[string]synctestVarKind)}
		bindSynctestFieldList(fn.Recv, scopes[1], imports, true)
		bindSynctestFieldList(fn.Type.Params, scopes[1], imports, true)
		bindSynctestFieldList(fn.Type.Results, scopes[1], imports, true)
		localLits := make(map[string]*ast.FuncLit)
		walkSynctestScopes(fset, src, fn.Body, fnName, scopes, localLits, imports, &candidates)
	}

	return candidates
}

func bindSynctestFieldList(fl *ast.FieldList, scope map[string]synctestVarKind, imports synctestImports, recordUnsafe bool) {
	if fl == nil {
		return
	}
	for _, field := range fl.List {
		if field == nil {
			continue
		}
		kind := synctestTypeKind(field.Type, imports)
		if !recordUnsafe || kind == synctestKindNone {
			kind = synctestKindSafe
		}
		for _, id := range field.Names {
			if id != nil && id.Name != "" && id.Name != "_" {
				scope[id.Name] = kind
			}
		}
	}
}

func recordSynctestValueSpec(vs *ast.ValueSpec, scopes []map[string]synctestVarKind, imports synctestImports, recordUnsafe bool) {
	if vs == nil || len(scopes) == 0 {
		return
	}
	cur := scopes[len(scopes)-1]
	explicitKind := synctestTypeKind(vs.Type, imports)
	for i, id := range vs.Names {
		if id == nil || id.Name == "" || id.Name == "_" {
			continue
		}
		kind := explicitKind
		if kind == synctestKindNone && i < len(vs.Values) {
			kind = synctestExprKind(vs.Values[i], scopes, imports)
		}
		if !recordUnsafe || kind == synctestKindNone {
			kind = synctestKindSafe
		}
		cur[id.Name] = kind
	}
}

func synctestTypeKind(expr ast.Expr, imports synctestImports) synctestVarKind {
	if expr == nil {
		return synctestKindNone
	}
	switch t := unwrapTestingParens(expr).(type) {
	case *ast.ChanType:
		return synctestKindChannel
	case *ast.StarExpr:
		if sel, ok := unwrapTestingParens(t.X).(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok && pkgIdent.Name == imports.timeAlias {
				if sel.Sel.Name == "Timer" {
					return synctestKindTimer
				}
				if sel.Sel.Name == "Ticker" {
					return synctestKindTicker
				}
			}
		}
	}
	return synctestKindNone
}

func synctestExprKind(expr ast.Expr, scopes []map[string]synctestVarKind, imports synctestImports) synctestVarKind {
	if expr == nil {
		return synctestKindNone
	}
	switch e := unwrapTestingParens(expr).(type) {
	case *ast.Ident:
		return lookupSynctestVar(e.Name, scopes)
	case *ast.CallExpr:
		if fnIdent, ok := e.Fun.(*ast.Ident); ok && fnIdent.Name == "make" && len(e.Args) >= 1 {
			if _, isChan := unwrapTestingParens(e.Args[0]).(*ast.ChanType); isChan {
				return synctestKindChannel
			}
		}
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok && pkgIdent.Name == imports.timeAlias {
				switch sel.Sel.Name {
				case "NewTimer", "AfterFunc":
					return synctestKindTimer
				case "NewTicker":
					return synctestKindTicker
				case "After":
					return synctestKindChannel
				}
			}
		}
	}
	return synctestKindNone
}

func lookupSynctestVar(name string, scopes []map[string]synctestVarKind) synctestVarKind {
	for i := len(scopes) - 1; i >= 0; i-- {
		if k, ok := scopes[i][name]; ok {
			return k
		}
	}
	return synctestKindNone
}

func walkSynctestScopes(
	fset *token.FileSet,
	src string,
	node ast.Node,
	enclosingFunc string,
	scopes []map[string]synctestVarKind,
	localLits map[string]*ast.FuncLit,
	imports synctestImports,
	out *[]testingSafetyCandidate,
) {
	if node == nil {
		return
	}
	switch n := node.(type) {
	case *ast.BlockStmt:
		scopes = append(scopes, make(map[string]synctestVarKind))
		for _, st := range n.List {
			walkSynctestScopes(fset, src, st, enclosingFunc, scopes, localLits, imports, out)
		}
	case *ast.DeclStmt:
		if gd, ok := n.Decl.(*ast.GenDecl); ok && gd.Tok == token.VAR {
			for _, spec := range gd.Specs {
				if vs, ok := spec.(*ast.ValueSpec); ok {
					for _, val := range vs.Values {
						walkSynctestScopes(fset, src, val, enclosingFunc, scopes, localLits, imports, out)
					}
					recordSynctestValueSpec(vs, scopes, imports, true)
				}
			}
		}
	case *ast.AssignStmt:
		for _, rhs := range n.Rhs {
			walkSynctestScopes(fset, src, rhs, enclosingFunc, scopes, localLits, imports, out)
		}
		cur := scopes[len(scopes)-1]
		if len(n.Lhs) == 1 && len(n.Rhs) == 1 {
			if id, ok := n.Lhs[0].(*ast.Ident); ok && id.Name != "_" {
				if lit := unwrapFuncLit(n.Rhs[0]); lit != nil {
					localLits[id.Name] = lit
				}
			}
		}
		for i, lhs := range n.Lhs {
			id, ok := lhs.(*ast.Ident)
			if !ok || id.Name == "_" {
				continue
			}
			var kind synctestVarKind
			if i < len(n.Rhs) {
				kind = synctestExprKind(n.Rhs[i], scopes, imports)
			}
			if kind == synctestKindNone {
				kind = synctestKindSafe
			}
			if n.Tok == token.DEFINE {
				cur[id.Name] = kind
			} else if kind != synctestKindSafe {
				cur[id.Name] = kind
			}
		}
	case *ast.IfStmt:
		scopes = append(scopes, make(map[string]synctestVarKind))
		if n.Init != nil {
			walkSynctestScopes(fset, src, n.Init, enclosingFunc, scopes, localLits, imports, out)
		}
		walkSynctestScopes(fset, src, n.Cond, enclosingFunc, scopes, localLits, imports, out)
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
		if n.Else != nil {
			walkSynctestScopes(fset, src, n.Else, enclosingFunc, scopes, localLits, imports, out)
		}
	case *ast.ForStmt:
		scopes = append(scopes, make(map[string]synctestVarKind))
		if n.Init != nil {
			walkSynctestScopes(fset, src, n.Init, enclosingFunc, scopes, localLits, imports, out)
		}
		walkSynctestScopes(fset, src, n.Cond, enclosingFunc, scopes, localLits, imports, out)
		walkSynctestScopes(fset, src, n.Post, enclosingFunc, scopes, localLits, imports, out)
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
	case *ast.RangeStmt:
		walkSynctestScopes(fset, src, n.X, enclosingFunc, scopes, localLits, imports, out)
		scopes = append(scopes, make(map[string]synctestVarKind))
		cur := scopes[len(scopes)-1]
		if n.Tok == token.DEFINE {
			if k, ok := n.Key.(*ast.Ident); ok && k.Name != "_" {
				cur[k.Name] = synctestKindSafe
			}
			if v, ok := n.Value.(*ast.Ident); ok && v.Name != "_" {
				cur[v.Name] = synctestKindSafe
			}
		}
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
	case *ast.SwitchStmt:
		scopes = append(scopes, make(map[string]synctestVarKind))
		if n.Init != nil {
			walkSynctestScopes(fset, src, n.Init, enclosingFunc, scopes, localLits, imports, out)
		}
		walkSynctestScopes(fset, src, n.Tag, enclosingFunc, scopes, localLits, imports, out)
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
	case *ast.TypeSwitchStmt:
		scopes = append(scopes, make(map[string]synctestVarKind))
		if n.Init != nil {
			walkSynctestScopes(fset, src, n.Init, enclosingFunc, scopes, localLits, imports, out)
		}
		if n.Assign != nil {
			walkSynctestScopes(fset, src, n.Assign, enclosingFunc, scopes, localLits, imports, out)
		}
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
	case *ast.SelectStmt:
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, scopes, localLits, imports, out)
	case *ast.CaseClause:
		scopes = append(scopes, make(map[string]synctestVarKind))
		for _, e := range n.List {
			walkSynctestScopes(fset, src, e, enclosingFunc, scopes, localLits, imports, out)
		}
		for _, st := range n.Body {
			walkSynctestScopes(fset, src, st, enclosingFunc, scopes, localLits, imports, out)
		}
	case *ast.CommClause:
		scopes = append(scopes, make(map[string]synctestVarKind))
		if n.Comm != nil {
			walkSynctestScopes(fset, src, n.Comm, enclosingFunc, scopes, localLits, imports, out)
		}
		for _, st := range n.Body {
			walkSynctestScopes(fset, src, st, enclosingFunc, scopes, localLits, imports, out)
		}
	case *ast.ExprStmt:
		walkSynctestScopes(fset, src, n.X, enclosingFunc, scopes, localLits, imports, out)
	case *ast.DeferStmt:
		walkSynctestScopes(fset, src, n.Call, enclosingFunc, scopes, localLits, imports, out)
	case *ast.GoStmt:
		walkSynctestScopes(fset, src, n.Call, enclosingFunc, scopes, localLits, imports, out)
	case *ast.ReturnStmt:
		for _, res := range n.Results {
			walkSynctestScopes(fset, src, res, enclosingFunc, scopes, localLits, imports, out)
		}
	case *ast.SendStmt:
		walkSynctestScopes(fset, src, n.Chan, enclosingFunc, scopes, localLits, imports, out)
		walkSynctestScopes(fset, src, n.Value, enclosingFunc, scopes, localLits, imports, out)
	case *ast.IncDecStmt:
		walkSynctestScopes(fset, src, n.X, enclosingFunc, scopes, localLits, imports, out)
	case *ast.FuncLit:
		litScopes := append(cloneSynctestScopes(scopes), make(map[string]synctestVarKind))
		if n.Type != nil {
			bindSynctestFieldList(n.Type.Params, litScopes[len(litScopes)-1], imports, true)
			bindSynctestFieldList(n.Type.Results, litScopes[len(litScopes)-1], imports, true)
		}
		walkSynctestScopes(fset, src, n.Body, enclosingFunc, litScopes, localLits, imports, out)
	case *ast.CallExpr:
		if bubbleLabel, fnLit, ok := matchSynctestCall(n, localLits, imports); ok {
			outerSnapshot := cloneSynctestScopes(scopes)
			inspectSynctestBubbleClosure(fset, src, bubbleLabel, enclosingFunc, fnLit, outerSnapshot, localLits, imports, out)
			return
		}
		walkSynctestScopes(fset, src, n.Fun, enclosingFunc, scopes, localLits, imports, out)
		for _, a := range n.Args {
			walkSynctestScopes(fset, src, a, enclosingFunc, scopes, localLits, imports, out)
		}
	default:
		ast.Inspect(node, func(sub ast.Node) bool {
			if sub == nil || sub == node {
				return true
			}
			switch s := sub.(type) {
			case *ast.CallExpr, *ast.FuncLit:
				walkSynctestScopes(fset, src, s, enclosingFunc, scopes, localLits, imports, out)
				return false
			}
			return true
		})
	}
}

func cloneSynctestScopes(scopes []map[string]synctestVarKind) []map[string]synctestVarKind {
	out := make([]map[string]synctestVarKind, len(scopes))
	for i, s := range scopes {
		cp := make(map[string]synctestVarKind, len(s))
		for k, v := range s {
			cp[k] = v
		}
		out[i] = cp
	}
	return out
}

func matchSynctestCall(call *ast.CallExpr, localLits map[string]*ast.FuncLit, imports synctestImports) (string, *ast.FuncLit, bool) {
	if call == nil {
		return "", nil, false
	}
	var method string
	var label string
	switch fn := call.Fun.(type) {
	case *ast.SelectorExpr:
		if fn.Sel == nil {
			return "", nil, false
		}
		if pkgIdent, ok := fn.X.(*ast.Ident); ok && pkgIdent.Name == imports.synctestAlias {
			method = fn.Sel.Name
			label = pkgIdent.Name + "." + method
		}
	case *ast.Ident:
		if imports.synctestAlias == "." {
			method = fn.Name
			label = method
		}
	}
	var arg ast.Expr
	switch method {
	case "Test":
		if len(call.Args) != 2 {
			return "", nil, false
		}
		arg = call.Args[1]
	case "Run":
		if len(call.Args) != 1 {
			return "", nil, false
		}
		arg = call.Args[0]
	default:
		return "", nil, false
	}
	if lit := unwrapFuncLit(arg); lit != nil {
		return label, lit, true
	}
	if id, ok := unwrapTestingParens(arg).(*ast.Ident); ok {
		if lit, exists := localLits[id.Name]; exists && lit != nil {
			return label, lit, true
		}
	}
	return "", nil, false
}

func inspectSynctestBubbleClosure(
	fset *token.FileSet,
	src string,
	bubbleLabel string,
	enclosingFunc string,
	fnLit *ast.FuncLit,
	outerSnapshot []map[string]synctestVarKind,
	localLits map[string]*ast.FuncLit,
	imports synctestImports,
	out *[]testingSafetyCandidate,
) {
	if fnLit == nil || fnLit.Body == nil {
		return
	}
	reported := make(map[string]bool)
	innerScopes := []map[string]synctestVarKind{make(map[string]synctestVarKind)}
	if fnLit.Type != nil {
		bindSynctestFieldList(fnLit.Type.Params, innerScopes[0], imports, false)
		bindSynctestFieldList(fnLit.Type.Results, innerScopes[0], imports, false)
	}

	var checkExprRef func(expr ast.Node, curInner []map[string]synctestVarKind)
	var walkInner func(node ast.Node, curInner []map[string]synctestVarKind)

	checkExprRef = func(node ast.Node, curInner []map[string]synctestVarKind) {
		if node == nil {
			return
		}
		switch e := node.(type) {
		case *ast.Ident:
			name := e.Name
			if name == "" || name == "_" {
				return
			}
			if lookupSynctestVar(name, curInner) != synctestKindNone {
				return
			}
			kind := lookupSynctestVar(name, outerSnapshot)
			if kind != synctestKindChannel && kind != synctestKindTimer && kind != synctestKindTicker {
				return
			}
			if reported[name] {
				return
			}
			reported[name] = true
			pos := fset.Position(e.Pos())
			*out = append(*out, testingSafetyCandidate{
				issue: TestingSafetyIssue{
					ID:         fmt.Sprintf("synctest_bubble_capture:%d:%d:%s", pos.Line, pos.Column, name),
					Category:   "synctest_bubble_capture",
					Severity:   "error",
					Line:       pos.Line,
					Column:     pos.Column,
					FuncName:   enclosingFunc,
					Expr:       testingSafetyNodeString(fset, src, e),
					Message:    fmt.Sprintf("Captured outer %s %q inside %s violates synctest bubble isolation and panics at runtime; declare it inside the bubble", kind, name, bubbleLabel),
					Suggestion: fmt.Sprintf("Move %s declaration inside %s instead of capturing it from the outer scope.", name, bubbleLabel),
					CanAutoFix: false,
				},
				replaceStart: -1,
				replaceEnd:   -1,
			})
		case *ast.SelectorExpr:
			checkExprRef(e.X, curInner)
		case *ast.KeyValueExpr:
			checkExprRef(e.Value, curInner)
		case *ast.CallExpr:
			if subLabel, subLit, ok := matchSynctestCall(e, localLits, imports); ok {
				nestedOuter := append(cloneSynctestScopes(outerSnapshot), cloneSynctestScopes(curInner)...)
				inspectSynctestBubbleClosure(fset, src, subLabel, enclosingFunc, subLit, nestedOuter, localLits, imports, out)
				return
			}
			checkExprRef(e.Fun, curInner)
			for _, a := range e.Args {
				checkExprRef(a, curInner)
			}
		case *ast.FuncLit:
			nextInner := append(cloneSynctestScopes(curInner), make(map[string]synctestVarKind))
			if e.Type != nil {
				bindSynctestFieldList(e.Type.Params, nextInner[len(nextInner)-1], imports, false)
				bindSynctestFieldList(e.Type.Results, nextInner[len(nextInner)-1], imports, false)
			}
			walkInner(e.Body, nextInner)
		default:
			ast.Inspect(node, func(sub ast.Node) bool {
				if sub == nil || sub == node {
					return true
				}
				switch s := sub.(type) {
				case *ast.Ident, *ast.SelectorExpr, *ast.KeyValueExpr, *ast.CallExpr, *ast.FuncLit:
					checkExprRef(s, curInner)
					return false
				}
				return true
			})
		}
	}

	walkInner = func(node ast.Node, curInner []map[string]synctestVarKind) {
		if node == nil {
			return
		}
		switch s := node.(type) {
		case *ast.BlockStmt:
			next := append(curInner, make(map[string]synctestVarKind))
			for _, st := range s.List {
				walkInner(st, next)
			}
		case *ast.DeclStmt:
			if gd, ok := s.Decl.(*ast.GenDecl); ok && gd.Tok == token.VAR {
				for _, spec := range gd.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, v := range vs.Values {
							checkExprRef(v, curInner)
						}
						recordSynctestValueSpec(vs, curInner, imports, true)
					}
				}
			}
		case *ast.AssignStmt:
			for _, rhs := range s.Rhs {
				checkExprRef(rhs, curInner)
			}
			if s.Tok == token.DEFINE {
				top := curInner[len(curInner)-1]
				for i, lhs := range s.Lhs {
					if id, ok := lhs.(*ast.Ident); ok && id.Name != "_" {
						var k synctestVarKind
						if i < len(s.Rhs) {
							k = synctestExprKind(s.Rhs[i], append(cloneSynctestScopes(outerSnapshot), curInner...), imports)
						}
						if k == synctestKindNone {
							k = synctestKindSafe
						}
						top[id.Name] = k
					}
				}
			} else {
				for _, lhs := range s.Lhs {
					checkExprRef(lhs, curInner)
				}
			}
		case *ast.IfStmt:
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Init != nil {
				walkInner(s.Init, next)
			}
			checkExprRef(s.Cond, next)
			walkInner(s.Body, next)
			if s.Else != nil {
				walkInner(s.Else, next)
			}
		case *ast.ForStmt:
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Init != nil {
				walkInner(s.Init, next)
			}
			checkExprRef(s.Cond, next)
			if s.Post != nil {
				walkInner(s.Post, next)
			}
			walkInner(s.Body, next)
		case *ast.RangeStmt:
			checkExprRef(s.X, curInner)
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Tok == token.DEFINE {
				top := next[len(next)-1]
				if k, ok := s.Key.(*ast.Ident); ok && k.Name != "_" {
					top[k.Name] = synctestKindSafe
				}
				if v, ok := s.Value.(*ast.Ident); ok && v.Name != "_" {
					top[v.Name] = synctestKindSafe
				}
			}
			walkInner(s.Body, next)
		case *ast.SwitchStmt:
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Init != nil {
				walkInner(s.Init, next)
			}
			checkExprRef(s.Tag, next)
			walkInner(s.Body, next)
		case *ast.TypeSwitchStmt:
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Init != nil {
				walkInner(s.Init, next)
			}
			if s.Assign != nil {
				walkInner(s.Assign, next)
			}
			walkInner(s.Body, next)
		case *ast.SelectStmt:
			walkInner(s.Body, curInner)
		case *ast.CaseClause:
			next := append(curInner, make(map[string]synctestVarKind))
			for _, e := range s.List {
				checkExprRef(e, next)
			}
			for _, st := range s.Body {
				walkInner(st, next)
			}
		case *ast.CommClause:
			next := append(curInner, make(map[string]synctestVarKind))
			if s.Comm != nil {
				walkInner(s.Comm, next)
			}
			for _, st := range s.Body {
				walkInner(st, next)
			}
		case *ast.ExprStmt:
			checkExprRef(s.X, curInner)
		case *ast.DeferStmt:
			checkExprRef(s.Call, curInner)
		case *ast.GoStmt:
			checkExprRef(s.Call, curInner)
		case *ast.ReturnStmt:
			for _, res := range s.Results {
				checkExprRef(res, curInner)
			}
		case *ast.SendStmt:
			checkExprRef(s.Chan, curInner)
			checkExprRef(s.Value, curInner)
		case *ast.IncDecStmt:
			checkExprRef(s.X, curInner)
		case *ast.BranchStmt:
		case *ast.LabeledStmt:
			walkInner(s.Stmt, curInner)
		default:
			checkExprRef(node, curInner)
		}
	}

	walkInner(fnLit.Body, innerScopes)
}

func unwrapTestingParens(expr ast.Expr) ast.Expr {
	for expr != nil {
		if p, ok := expr.(*ast.ParenExpr); ok {
			expr = p.X
			continue
		}
		return expr
	}
	return nil
}
