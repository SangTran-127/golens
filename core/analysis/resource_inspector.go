package analysis

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type ResourceRiskFinding struct {
	Kind         string `json:"kind"`
	Severity     string `json:"severity"`
	Title        string `json:"title"`
	Message      string `json:"message"`
	File         string `json:"file"`
	Line         int    `json:"line"`
	Col          int    `json:"col"`
	FunctionName string `json:"functionName"`
	TargetName   string `json:"targetName"`
	Snippet      string `json:"snippet"`
	SuggestedFix string `json:"suggestedFix"`
	CanQuickFix  bool   `json:"canQuickFix"`
}

type ResourceRiskReport struct {
	TotalFindings int                   `json:"totalFindings"`
	UnclosedCount int                   `json:"unclosedCount"`
	SQLRiskCount  int                   `json:"sqlRiskCount"`
	CmdRiskCount  int                   `json:"cmdRiskCount"`
	Findings      []ResourceRiskFinding `json:"findings"`
	Error         string                `json:"error,omitempty"`
}

func InspectResourceAndInjectionRisks(workspaceDir, filePath, content string, includeWorkspace bool) (ResourceRiskReport, error) {
	report := ResourceRiskReport{
		Findings: []ResourceRiskFinding{},
	}

	workspaceDir = strings.TrimSpace(workspaceDir)
	filePath = strings.TrimSpace(filePath)

	var absWorkspace string
	if workspaceDir != "" {
		if abs, err := filepath.Abs(workspaceDir); err == nil {
			absWorkspace = abs
		} else {
			absWorkspace = workspaceDir
		}
	}

	var absActiveFile string
	if filePath != "" {
		if abs, err := filepath.Abs(filePath); err == nil {
			absActiveFile = abs
		} else {
			absActiveFile = filePath
		}
	}

	var targets []goSourceTarget

	if includeWorkspace && absWorkspace != "" {
		targets = collectWorkspaceGoTargets(absWorkspace, absActiveFile, content, false)
	} else {
		var src []byte
		targetPath := filePath
		if content != "" {
			src = []byte(content)
			if targetPath == "" {
				targetPath = "input.go"
			}
		} else if targetPath != "" {
			data, err := os.ReadFile(targetPath)
			if err != nil {
				report.Error = err.Error()
				return report, err
			}
			src = data
		} else {
			return report, nil
		}
		targets = append(targets, loadedGoSourceTarget(targetPath, src))
	}

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) []ResourceRiskFinding {
		return inspectASTFileResourceAndInjection(src.fset, src.file, src.path, string(src.content))
	})
	findings := flattenGoSourceResults(perFile)

	if len(targets) == 1 && len(findings) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		return report, firstParseErr
	}

	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		if findings[i].Col != findings[j].Col {
			return findings[i].Col < findings[j].Col
		}
		return findings[i].Kind < findings[j].Kind
	})

	for _, f := range findings {
		switch f.Kind {
		case "RESOURCE_UNCLOSED":
			report.UnclosedCount++
		case "SQL_INJECTION":
			report.SQLRiskCount++
		case "CMD_INJECTION":
			report.CmdRiskCount++
		}
	}

	report.TotalFindings = len(findings)
	if findings != nil {
		report.Findings = findings
	}

	return report, nil
}

type resourceAcquisitionMatch struct {
	assignStmt  *ast.AssignStmt
	varName     string
	closeTarget string
	callDesc    string
	line        int
	col         int
}

func inspectASTFileResourceAndInjection(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
) []ResourceRiskFinding {
	var findings []ResourceRiskFinding

	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	inspectFuncBody := func(fnName string, fnType *ast.FuncType, body *ast.BlockStmt, declCloseCalls []resourceCloseCall) {
		if body == nil {
			return
		}

		dynamicVars := collectDynamicStringVars(fset, body)
		rootVars := collectOSRootVars(fset, fnType, body)

		var acquisitions []resourceAcquisitionMatch
		ast.Inspect(body, func(n ast.Node) bool {
			if _, isNestedFunc := n.(*ast.FuncLit); isNestedFunc {
				return false
			}
			assign, ok := n.(*ast.AssignStmt)
			if !ok {
				return true
			}
			if m, ok := matchResourceAcquisitionAssignWithRoots(fset, assign, rootVars); ok {
				acquisitions = append(acquisitions, m)
			}
			return true
		})

		var closedTargets map[string]bool
		if len(acquisitions) > 0 {
			closedTargets = closedTargetsWithin(declCloseCalls, body)
		}
		for _, acq := range acquisitions {
			flow := analyzeResourceAcquisitionFlow(fset, body, acq)
			if !flow.leaked {
				continue
			}
			fnLabel := fnName
			if fnLabel == "" {
				fnLabel = "the function"
			}
			title := fmt.Sprintf("%s from %s is never closed; add defer %s.Close()", acq.closeTarget, acq.callDesc, acq.closeTarget)
			msg := fmt.Sprintf("Resource '%s' acquired via %s is never closed before %s returns; add 'defer %s.Close()' after error checking to prevent resource leaks.", acq.closeTarget, acq.callDesc, fnLabel, acq.closeTarget)
			if closedTargets[acq.varName] || closedTargets[acq.closeTarget] {
				title = fmt.Sprintf("%s from %s may leak on early return; add defer %s.Close()", acq.closeTarget, acq.callDesc, acq.closeTarget)
				msg = fmt.Sprintf("Resource '%s' acquired via %s may leak on early return at line %d without 'defer %s.Close()'; add 'defer %s.Close()' after error checking to prevent resource leaks.", acq.closeTarget, acq.callDesc, flow.leakLine, acq.closeTarget, acq.closeTarget)
			}
			suggestedFix := "Insert defer " + acq.closeTarget + ".Close()"
			if flow.inLoop {
				suggestedFix = fmt.Sprintf("Close %s before each loop iteration ends or extract the loop body into a helper function", acq.closeTarget)
			}
			findings = append(findings, ResourceRiskFinding{
				Kind:         "RESOURCE_UNCLOSED",
				Severity:     "warning",
				Title:        title,
				Message:      msg,
				File:         filePath,
				Line:         acq.line,
				Col:          acq.col,
				FunctionName: fnName,
				TargetName:   acq.closeTarget,
				Snippet:      lineAt(acq.line),
				SuggestedFix: suggestedFix,
				CanQuickFix:  flow.canFix,
			})
		}

		ast.Inspect(body, func(n ast.Node) bool {
			if _, isNestedFunc := n.(*ast.FuncLit); isNestedFunc {
				return false
			}
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}

			if sqlMatch, ok := matchSQLInjectionCall(fset, call, dynamicVars); ok {
				pos := fset.Position(call.Pos())
				findings = append(findings, ResourceRiskFinding{
					Kind:         "SQL_INJECTION",
					Severity:     "high",
					Title:        fmt.Sprintf("SQL query built from dynamic strings in %s", sqlMatch.callName),
					Message:      "Constructing SQL queries with string concatenation (+) or fmt.Sprintf risks SQL injection; use parameterized placeholders (? or $1) and pass query arguments separately.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   sqlMatch.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: "Use parameterized query placeholders (? or $1) instead of dynamic string construction",
					CanQuickFix:  false,
				})
			}

			if cmdMatch, ok := matchCmdInjectionCall(fset, call, dynamicVars); ok {
				pos := fset.Position(call.Pos())
				findings = append(findings, ResourceRiskFinding{
					Kind:         "CMD_INJECTION",
					Severity:     "high",
					Title:        fmt.Sprintf("Command built from dynamic strings in %s", cmdMatch.callName),
					Message:      "Building shell or command arguments via string concatenation (+) or fmt.Sprintf risks command injection; pass a static executable name and separate argument tokens.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   cmdMatch.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: "Pass static binary name and separate argument parameters to exec.Command",
					CanQuickFix:  false,
				})
			}

			return true
		})
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}
		declCloseCalls := collectResourceCloseCalls(fset, fn.Body)
		inspectFuncBody(fnName, fn.Type, fn.Body, declCloseCalls)

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			lit, ok := n.(*ast.FuncLit)
			if ok && lit.Body != nil {
				inspectFuncBody(fnName, lit.Type, lit.Body, declCloseCalls)
			}
			return true
		})
	}

	return findings
}

type resourceCloseCall struct {
	pos  token.Pos
	recv string
}

func collectResourceCloseCalls(fset *token.FileSet, body *ast.BlockStmt) []resourceCloseCall {
	var calls []resourceCloseCall
	if body == nil {
		return calls
	}
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		if sel.Sel.Name == "Close" || sel.Sel.Name == "Rollback" || sel.Sel.Name == "Commit" {
			if recv := resourceExprString(fset, sel.X); recv != "" {
				calls = append(calls, resourceCloseCall{pos: call.Pos(), recv: recv})
			}
		}
		return true
	})
	return calls
}

func closedTargetsWithin(calls []resourceCloseCall, body *ast.BlockStmt) map[string]bool {
	closed := make(map[string]bool)
	if body == nil {
		return closed
	}
	start := sort.Search(len(calls), func(i int) bool { return calls[i].pos >= body.Pos() })
	for i := start; i < len(calls) && calls[i].pos < body.End(); i++ {
		closed[calls[i].recv] = true
	}
	return closed
}

func resourceExprString(fset *token.FileSet, expr ast.Expr) string {
	if name, ok := identChainString(expr); ok {
		return name
	}
	return exprToString(fset, expr)
}

func identChainString(expr ast.Expr) (string, bool) {
	switch e := expr.(type) {
	case *ast.Ident:
		return e.Name, true
	case *ast.SelectorExpr:
		if e.Sel == nil {
			return "", false
		}
		base, ok := identChainString(e.X)
		if !ok {
			return "", false
		}
		return base + "." + e.Sel.Name, true
	}
	return "", false
}

func isResourceCallMethod(method string) bool {
	switch method {
	case "Open", "OpenFile", "OpenRoot", "Create", "CreateTemp",
		"Get", "Post", "PostForm", "Head",
		"OpenDB",
		"Dial", "DialTimeout", "Listen", "ListenPacket",
		"NewReader", "NewWriter",
		"OpenReader",
		"Do",
		"Query", "QueryContext",
		"Prepare", "PrepareContext", "Conn":
		return true
	}
	return false
}

func matchResourceAcquisitionAssign(fset *token.FileSet, assign *ast.AssignStmt) (resourceAcquisitionMatch, bool) {
	return matchResourceAcquisitionAssignWithRoots(fset, assign, nil)
}

func matchResourceAcquisitionAssignWithRoots(fset *token.FileSet, assign *ast.AssignStmt, rootVars map[string]bool) (resourceAcquisitionMatch, bool) {
	if assign == nil || len(assign.Rhs) != 1 || len(assign.Lhs) < 1 {
		return resourceAcquisitionMatch{}, false
	}
	lhsIdent, ok := assign.Lhs[0].(*ast.Ident)
	if !ok || lhsIdent.Name == "" || lhsIdent.Name == "_" {
		return resourceAcquisitionMatch{}, false
	}
	call, ok := assign.Rhs[0].(*ast.CallExpr)
	if !ok {
		return resourceAcquisitionMatch{}, false
	}

	callDesc, needsBodyClose, matched := classifyResourceCallWithRoots(fset, call, rootVars)
	if !matched {
		return resourceAcquisitionMatch{}, false
	}
	if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
		if (sel.Sel.Name == "Query" || sel.Sel.Name == "QueryContext") && len(assign.Lhs) < 2 {
			return resourceAcquisitionMatch{}, false
		}
	}

	varName := lhsIdent.Name
	closeTarget := varName
	if needsBodyClose {
		closeTarget = varName + ".Body"
	}

	pos := fset.Position(assign.Pos())
	return resourceAcquisitionMatch{
		assignStmt:  assign,
		varName:     varName,
		closeTarget: closeTarget,
		callDesc:    callDesc,
		line:        pos.Line,
		col:         pos.Column,
	}, true
}

func classifyResourceCall(fset *token.FileSet, call *ast.CallExpr) (callDesc string, needsBodyClose bool, matched bool) {
	return classifyResourceCallWithRoots(fset, call, nil)
}

func classifyResourceCallWithRoots(fset *token.FileSet, call *ast.CallExpr, rootVars map[string]bool) (callDesc string, needsBodyClose bool, matched bool) {
	if call == nil {
		return "", false, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false, false
	}
	method := sel.Sel.Name
	if !isResourceCallMethod(method) {
		return "", false, false
	}
	recvStr := resourceExprString(fset, sel.X)
	if recvStr == "" {
		return "", false, false
	}

	switch recvStr {
	case "os":
		switch method {
		case "Open", "OpenFile", "Create", "CreateTemp":
			return "os." + method, false, true
		case "OpenRoot":
			if rootVars != nil {
				return "os." + method, false, true
			}
		}
	case "http":
		switch method {
		case "Get", "Post", "PostForm", "Head":
			return "http." + method, true, true
		}
	case "sql":
		if method == "Open" || method == "OpenDB" {
			return "sql." + method, false, true
		}
	case "net":
		if method == "Dial" || method == "DialTimeout" || method == "Listen" || method == "ListenPacket" {
			return "net." + method, false, true
		}
	case "gzip", "zlib", "multipart":
		if method == "NewReader" || method == "NewWriter" {
			return recvStr + "." + method, false, true
		}
	case "zip":
		if method == "OpenReader" {
			return "zip.OpenReader", false, true
		}
	}

	if rootVars != nil && rootVars[recvStr] {
		switch method {
		case "Open", "OpenFile", "OpenRoot", "Create":
			return recvStr + "." + method, false, true
		}
	}

	if method == "Do" {
		lowerRecv := strings.ToLower(recvStr)
		if strings.Contains(lowerRecv, "client") || strings.Contains(lowerRecv, "http") || recvStr == "c" || recvStr == "cli" {
			return recvStr + ".Do", true, true
		}
	}

	if (method == "Get" || method == "Post" || method == "PostForm" || method == "Head") &&
		(strings.Contains(strings.ToLower(recvStr), "client") || strings.HasSuffix(recvStr, " DefaultClient")) {
		return recvStr + "." + method, true, true
	}

	if method == "Query" || method == "QueryContext" {
		if recvStr != "url" && !strings.HasSuffix(recvStr, ".URL") {
			return recvStr + "." + method, false, true
		}
	}

	if method == "Begin" || method == "BeginTx" || method == "Prepare" || method == "PrepareContext" || method == "Conn" {
		lowerRecv := strings.ToLower(recvStr)
		if strings.Contains(lowerRecv, "db") || strings.Contains(lowerRecv, "conn") || strings.Contains(lowerRecv, "tx") || strings.Contains(lowerRecv, "sql") {
			if method == "Prepare" || method == "PrepareContext" || method == "Conn" {
				return recvStr + "." + method, false, true
			}
		}
	}

	return "", false, false
}

func collectClosedTargets(fset *token.FileSet, body *ast.BlockStmt) map[string]bool {
	closed := make(map[string]bool)
	if body == nil {
		return closed
	}

	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		if sel.Sel.Name == "Close" || sel.Sel.Name == "Rollback" || sel.Sel.Name == "Commit" {
			if recv := resourceExprString(fset, sel.X); recv != "" {
				closed[recv] = true
			}
		}
		return true
	})

	return closed
}

func collectReturnedVars(fset *token.FileSet, body *ast.BlockStmt) map[string]bool {
	returned := make(map[string]bool)
	if body == nil {
		return returned
	}

	ast.Inspect(body, func(n ast.Node) bool {
		if _, isNestedFunc := n.(*ast.FuncLit); isNestedFunc {
			return false
		}
		ret, ok := n.(*ast.ReturnStmt)
		if !ok {
			return true
		}
		for _, res := range ret.Results {
			exprStr := resourceExprString(fset, res)
			if exprStr != "" {
				returned[exprStr] = true
			}
			if ident, ok := res.(*ast.Ident); ok && ident.Name != "" {
				returned[ident.Name] = true
			}
		}
		return true
	})

	return returned
}

func collectDynamicStringVars(fset *token.FileSet, body *ast.BlockStmt) map[string]bool {
	dynamicVars := make(map[string]bool)
	if body == nil {
		return dynamicVars
	}

	ast.Inspect(body, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.AssignStmt:
			for i, rhs := range node.Rhs {
				if i >= len(node.Lhs) {
					break
				}
				ident, ok := node.Lhs[i].(*ast.Ident)
				if !ok || ident.Name == "" || ident.Name == "_" {
					continue
				}
				if node.Tok == token.ADD_ASSIGN {
					if !isPureStringLiteralExpr(rhs) {
						dynamicVars[ident.Name] = true
					}
					continue
				}
				if isDynamicStringExpr(fset, rhs, dynamicVars) {
					dynamicVars[ident.Name] = true
				}
			}
		case *ast.ValueSpec:
			for i, rhs := range node.Values {
				if i >= len(node.Names) {
					break
				}
				ident := node.Names[i]
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				if isDynamicStringExpr(fset, rhs, dynamicVars) {
					dynamicVars[ident.Name] = true
				}
			}
		}
		return true
	})

	return dynamicVars
}

func isPureStringLiteralExpr(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	switch e := expr.(type) {
	case *ast.BasicLit:
		return e.Kind == token.STRING
	case *ast.ParenExpr:
		return isPureStringLiteralExpr(e.X)
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			return isPureStringLiteralExpr(e.X) && isPureStringLiteralExpr(e.Y)
		}
		return false
	default:
		return false
	}
}

func isFmtSprintfCall(fset *token.FileSet, expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	if sel.Sel.Name != "Sprintf" && sel.Sel.Name != "Sprint" && sel.Sel.Name != "Sprintln" {
		return false
	}
	return resourceExprString(fset, sel.X) == "fmt"
}

func isDynamicStringConcatExpr(_ *token.FileSet, expr ast.Expr, _ map[string]bool) bool {
	bin, ok := expr.(*ast.BinaryExpr)
	if !ok || bin.Op != token.ADD {
		return false
	}
	if isPureStringLiteralExpr(bin) {
		return false
	}
	return true
}

func isDynamicStringExpr(fset *token.FileSet, expr ast.Expr, dynamicVars map[string]bool) bool {
	if expr == nil {
		return false
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isDynamicStringExpr(fset, e.X, dynamicVars)
	case *ast.BinaryExpr:
		if isDynamicStringConcatExpr(fset, e, dynamicVars) {
			return true
		}
	case *ast.CallExpr:
		if isFmtSprintfCall(fset, e) {
			return true
		}
	case *ast.Ident:
		if dynamicVars != nil && dynamicVars[e.Name] {
			return true
		}
	}
	return false
}

type injectionMatch struct {
	callName   string
	targetName string
}

func matchSQLInjectionCall(fset *token.FileSet, call *ast.CallExpr, dynamicVars map[string]bool) (injectionMatch, bool) {
	if call == nil || len(call.Args) == 0 {
		return injectionMatch{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return injectionMatch{}, false
	}
	method := sel.Sel.Name
	var queryArgIdx int
	switch method {
	case "Query", "QueryRow", "Exec", "Prepare":
		queryArgIdx = 0
	case "QueryContext", "QueryRowContext", "ExecContext", "PrepareContext":
		queryArgIdx = 1
	default:
		return injectionMatch{}, false
	}
	recvStr := resourceExprString(fset, sel.X)
	if recvStr == "" || recvStr == "url" || strings.HasSuffix(recvStr, ".URL") {
		return injectionMatch{}, false
	}

	if queryArgIdx >= len(call.Args) {
		return injectionMatch{}, false
	}

	queryArg := call.Args[queryArgIdx]
	if !isDynamicStringExpr(fset, queryArg, dynamicVars) {
		return injectionMatch{}, false
	}

	callName := recvStr + "." + method
	targetName := exprToString(fset, queryArg)
	if targetName == "" {
		targetName = callName
	}
	return injectionMatch{
		callName:   callName,
		targetName: targetName,
	}, true
}

func matchCmdInjectionCall(fset *token.FileSet, call *ast.CallExpr, dynamicVars map[string]bool) (injectionMatch, bool) {
	if call == nil || len(call.Args) == 0 {
		return injectionMatch{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return injectionMatch{}, false
	}
	method := sel.Sel.Name
	if method != "Command" && method != "CommandContext" {
		return injectionMatch{}, false
	}
	if recvStr := resourceExprString(fset, sel.X); recvStr != "exec" {
		return injectionMatch{}, false
	}

	cmdIdx := 0
	if method == "CommandContext" {
		cmdIdx = 1
	}
	if cmdIdx >= len(call.Args) {
		return injectionMatch{}, false
	}

	callName := "exec." + method
	cmdArg := call.Args[cmdIdx]

	if isDynamicStringExpr(fset, cmdArg, dynamicVars) {
		return injectionMatch{
			callName:   callName,
			targetName: exprToString(fset, cmdArg),
		}, true
	}

	cmdLit := stringLiteralValue(cmdArg)
	isShell := isShellBinaryName(cmdLit)

	for i := cmdIdx + 1; i < len(call.Args); i++ {
		arg := call.Args[i]
		argLit := stringLiteralValue(arg)
		if (argLit == "-c" || argLit == "/c" || argLit == "/C" || strings.HasSuffix(argLit, "c")) && i+1 < len(call.Args) {
			payloadArg := call.Args[i+1]
			if isDynamicStringExpr(fset, payloadArg, dynamicVars) {
				return injectionMatch{
					callName:   callName,
					targetName: exprToString(fset, payloadArg),
				}, true
			}
		}
		if isShell && isDynamicStringExpr(fset, arg, dynamicVars) {
			return injectionMatch{
				callName:   callName,
				targetName: exprToString(fset, arg),
			}, true
		}
	}

	return injectionMatch{}, false
}

func stringLiteralValue(expr ast.Expr) string {
	lit, ok := expr.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return ""
	}
	return strings.Trim(lit.Value, "\"`")
}

func isShellBinaryName(name string) bool {
	if name == "" {
		return false
	}
	base := filepath.Base(name)
	switch strings.ToLower(base) {
	case "sh", "bash", "zsh", "dash", "ksh", "csh", "cmd", "cmd.exe", "powershell", "pwsh":
		return true
	default:
		return false
	}
}

func FixResourceRiskIssue(filePath, content string, line int, kind, targetName string) (string, error) {
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return "", err
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return content, fmt.Errorf("empty Go source content")
	}

	if kind != "RESOURCE_UNCLOSED" {
		return content, fmt.Errorf("unsupported resource risk quick fix kind %q", kind)
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil || astFile == nil {
		return content, err
	}

	trimmedTarget := strings.TrimSpace(targetName)

	type stmtContext struct {
		scopeBody *ast.BlockStmt
		match     resourceAcquisitionMatch
		flow      resourceFlowResult
	}

	var candidates []stmtContext
	collectScopeCandidates := func(fnType *ast.FuncType, scopeBody *ast.BlockStmt) {
		if scopeBody == nil {
			return
		}
		rootVars := collectOSRootVars(fset, fnType, scopeBody)
		ast.Inspect(scopeBody, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}
			assign, ok := n.(*ast.AssignStmt)
			if !ok {
				return true
			}
			m, ok := matchResourceAcquisitionAssignWithRoots(fset, assign, rootVars)
			if !ok {
				return true
			}
			flow := analyzeResourceAcquisitionFlow(fset, scopeBody, m)
			if !flow.leaked {
				return true
			}
			candidates = append(candidates, stmtContext{
				scopeBody: scopeBody,
				match:     m,
				flow:      flow,
			})
			return true
		})
	}

	for _, decl := range astFile.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		collectScopeCandidates(fn.Type, fn.Body)
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
				collectScopeCandidates(lit.Type, lit.Body)
			}
			return true
		})
	}

	if len(candidates) == 0 {
		return formatGoSourceOrFallback(content), nil
	}

	matchesTarget := func(m resourceAcquisitionMatch, target string) bool {
		if target == "" {
			return true
		}
		return m.closeTarget == target || m.varName == target
	}

	var chosen *stmtContext
	for i := range candidates {
		if candidates[i].match.line == line && matchesTarget(candidates[i].match, trimmedTarget) {
			chosen = &candidates[i]
			break
		}
	}
	if chosen == nil {
		for i := range candidates {
			if candidates[i].match.line == line {
				chosen = &candidates[i]
				break
			}
		}
	}
	if chosen == nil && trimmedTarget != "" {
		bestDist := 1000000
		for i := range candidates {
			if matchesTarget(candidates[i].match, trimmedTarget) {
				dist := absInt(candidates[i].match.line - line)
				if dist < bestDist && dist <= 12 {
					bestDist = dist
					chosen = &candidates[i]
				}
			}
		}
	}
	if chosen == nil {
		return formatGoSourceOrFallback(content), nil
	}

	closeTarget := chosen.match.closeTarget
	if trimmedTarget != "" && trimmedTarget != chosen.match.varName {
		closeTarget = trimmedTarget
	}

	if chosen.flow.inLoop {
		return content, fmt.Errorf("cannot safely add defer %s.Close() inside a loop; close %s before each loop exit", closeTarget, closeTarget)
	}
	if isBufferTrailerWriterDesc(chosen.match.callDesc) {
		if suppress, disallowFix := analyzeBufferTrailerWriter(fset, chosen.scopeBody, chosen.match); suppress || disallowFix || !chosen.flow.canFix {
			return content, fmt.Errorf("cannot safely convert %s Close() to defer before buffer read", closeTarget)
		}
	}

	assignCtx, ok := findResourceAssignContext(chosen.scopeBody, chosen.match.assignStmt)
	if !ok {
		return formatGoSourceOrFallback(content), nil
	}

	return insertDeferredGuardAndCleanup(
		fset,
		content,
		chosen.scopeBody,
		assignCtx,
		chosen.match.assignStmt.End(),
		chosen.match.line,
		chosen.match.varName,
		closeTarget,
		extractAssignErrVar(chosen.match.assignStmt),
		closeTarget+".Close()",
		true,
		"Close",
		chosen.match.callDesc,
	)
}

func isErrNotNilCheck(fset *token.FileSet, cond ast.Expr) bool {
	if cond == nil {
		return false
	}
	if paren, ok := cond.(*ast.ParenExpr); ok {
		return isErrNotNilCheck(fset, paren.X)
	}
	bin, ok := cond.(*ast.BinaryExpr)
	if !ok {
		return false
	}
	if bin.Op == token.LOR || bin.Op == token.LAND {
		return isErrNotNilCheck(fset, bin.X) || isErrNotNilCheck(fset, bin.Y)
	}
	if bin.Op != token.NEQ {
		return false
	}
	if isNilIdent(bin.Y) {
		lhs := strings.ToLower(resourceExprString(fset, bin.X))
		return lhs == "err" || strings.HasSuffix(lhs, "err") || strings.HasPrefix(lhs, "err")
	}
	if isNilIdent(bin.X) {
		rhs := strings.ToLower(resourceExprString(fset, bin.Y))
		return rhs == "err" || strings.HasSuffix(rhs, "err") || strings.HasPrefix(rhs, "err")
	}
	return false
}

func isResourceNilGuardExpr(fset *token.FileSet, cond ast.Expr, varName, closeTarget string) bool {
	if cond == nil {
		return false
	}
	if paren, ok := cond.(*ast.ParenExpr); ok {
		return isResourceNilGuardExpr(fset, paren.X, varName, closeTarget)
	}
	bin, ok := cond.(*ast.BinaryExpr)
	if !ok {
		return false
	}
	if bin.Op == token.LOR || bin.Op == token.LAND {
		return isResourceNilGuardExpr(fset, bin.X, varName, closeTarget) ||
			isResourceNilGuardExpr(fset, bin.Y, varName, closeTarget)
	}
	if bin.Op != token.EQL {
		return false
	}
	matchesResource := func(expr ast.Expr) bool {
		s := strings.TrimSpace(resourceExprString(fset, expr))
		if s == "" {
			return false
		}
		return (varName != "" && s == varName) || (closeTarget != "" && s == closeTarget)
	}
	if isNilIdent(bin.Y) && matchesResource(bin.X) {
		return true
	}
	if isNilIdent(bin.X) && matchesResource(bin.Y) {
		return true
	}
	return false
}

func ifBlockTerminatesExecution(fset *token.FileSet, body *ast.BlockStmt) bool {
	if body == nil || len(body.List) == 0 {
		return false
	}
	for _, stmt := range body.List {
		if stmtTerminatesExecution(fset, stmt) {
			return true
		}
	}
	return false
}

func stmtTerminatesExecution(fset *token.FileSet, stmt ast.Stmt) bool {
	if stmt == nil {
		return false
	}
	switch s := stmt.(type) {
	case *ast.ReturnStmt:
		return true
	case *ast.BranchStmt:
		return s.Tok == token.BREAK || s.Tok == token.CONTINUE || s.Tok == token.GOTO
	case *ast.BlockStmt:
		return ifBlockTerminatesExecution(fset, s)
	case *ast.IfStmt:
		if s.Else != nil && ifBlockTerminatesExecution(fset, s.Body) && stmtTerminatesExecution(fset, s.Else) {
			return true
		}
		return false
	case *ast.ExprStmt:
		call, ok := s.X.(*ast.CallExpr)
		if !ok {
			return false
		}
		if ident, ok := call.Fun.(*ast.Ident); ok && ident.Name == "panic" {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			recv := strings.TrimSpace(resourceExprString(fset, sel.X))
			method := sel.Sel.Name
			if recv == "os" && method == "Exit" {
				return true
			}
			switch method {
			case "Fatal", "Fatalf", "Fatalln", "FailNow", "Panic", "Panicf", "Panicln":
				return true
			}
		}
	}
	return false
}

func collectOSRootVars(fset *token.FileSet, fnType *ast.FuncType, body *ast.BlockStmt) map[string]bool {
	roots := make(map[string]bool)
	if fnType != nil && fnType.Params != nil {
		for _, fld := range fnType.Params.List {
			typeStr := strings.TrimSpace(exprToString(fset, fld.Type))
			if typeStr == "*os.Root" || typeStr == "os.Root" {
				for _, name := range fld.Names {
					if name != nil && name.Name != "" && name.Name != "_" {
						roots[name.Name] = true
					}
				}
			}
		}
	}
	if body == nil {
		return roots
	}
	ast.Inspect(body, func(n ast.Node) bool {
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		assign, ok := n.(*ast.AssignStmt)
		if !ok || len(assign.Rhs) != 1 || len(assign.Lhs) < 1 {
			return true
		}
		id, ok := assign.Lhs[0].(*ast.Ident)
		if !ok || id.Name == "" || id.Name == "_" {
			return true
		}
		if call, ok := unwrapSafetyParens(assign.Rhs[0]).(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == "OpenRoot" {
				recv := resourceExprString(fset, sel.X)
				if recv == "os" || roots[recv] {
					roots[id.Name] = true
				}
			}
		}
		return true
	})
	return roots
}

func findResourceAssignContext(body *ast.BlockStmt, target *ast.AssignStmt) (resourceAssignContext, bool) {
	if body == nil || target == nil {
		return resourceAssignContext{}, false
	}
	var walkBlock func(block *ast.BlockStmt, inLoop bool, outerCont [][]ast.Stmt) (resourceAssignContext, bool)
	var walkStmt func(stmt ast.Stmt, inLoop bool, cont [][]ast.Stmt) (resourceAssignContext, bool)
	walkSubList := func(stmts []ast.Stmt, inLoop bool, cont [][]ast.Stmt) (resourceAssignContext, bool) {
		for _, sub := range stmts {
			if ctx, ok := walkStmt(sub, inLoop, cont); ok {
				return ctx, true
			}
		}
		return resourceAssignContext{}, false
	}
	walkStmt = func(stmt ast.Stmt, inLoop bool, cont [][]ast.Stmt) (resourceAssignContext, bool) {
		switch s := stmt.(type) {
		case *ast.BlockStmt:
			return walkBlock(s, inLoop, cont)
		case *ast.IfStmt:
			if s.Init == target {
				return resourceAssignContext{inLoop: inLoop, inIfInit: true, ifInitStmt: s}, true
			}
			if ctx, ok := walkBlock(s.Body, inLoop, cont); ok {
				return ctx, true
			}
			if s.Else != nil {
				return walkStmt(s.Else, inLoop, cont)
			}
		case *ast.ForStmt:
			if s.Init == target {
				return resourceAssignContext{inLoop: true, inIfInit: true}, true
			}
			return walkBlock(s.Body, true, cont)
		case *ast.RangeStmt:
			return walkBlock(s.Body, true, cont)
		case *ast.SwitchStmt:
			if s.Init == target {
				return resourceAssignContext{inLoop: inLoop, inIfInit: true}, true
			}
			if s.Body != nil {
				return walkSubList(s.Body.List, inLoop, cont)
			}
		case *ast.TypeSwitchStmt:
			if s.Init == target || s.Assign == target {
				return resourceAssignContext{inLoop: inLoop, inIfInit: true}, true
			}
			if s.Body != nil {
				return walkSubList(s.Body.List, inLoop, cont)
			}
		case *ast.SelectStmt:
			if s.Body != nil {
				return walkSubList(s.Body.List, inLoop, cont)
			}
		case *ast.CaseClause:
			return walkSubList(s.Body, inLoop, cont)
		case *ast.CommClause:
			return walkSubList(s.Body, inLoop, cont)
		case *ast.LabeledStmt:
			return walkStmt(s.Stmt, inLoop, cont)
		}
		return resourceAssignContext{}, false
	}
	walkBlock = func(block *ast.BlockStmt, inLoop bool, outerCont [][]ast.Stmt) (resourceAssignContext, bool) {
		if block == nil {
			return resourceAssignContext{}, false
		}
		for i, stmt := range block.List {
			if stmt == target {
				return resourceAssignContext{block: block, idx: i, inLoop: inLoop, outerCont: outerCont}, true
			}
			nextCont := outerCont
			if i+1 < len(block.List) {
				nextCont = append([][]ast.Stmt{block.List[i+1:]}, outerCont...)
			}
			if ctx, ok := walkStmt(stmt, inLoop, nextCont); ok {
				return ctx, true
			}
		}
		return resourceAssignContext{}, false
	}
	return walkBlock(body, false, nil)
}

func hasNonBlockElseAfterAssign(fset *token.FileSet, blk *ast.BlockStmt, idx int, errVar, varName, closeTarget string) bool {
	if blk == nil || idx+1 >= len(blk.List) {
		return false
	}
	ifStmt, ok := blk.List[idx+1].(*ast.IfStmt)
	if !ok || ifStmt.Else == nil {
		return false
	}
	if isErrNotNilGuardCond(fset, ifStmt.Cond, errVar) || isResourceNilGuardExpr(fset, ifStmt.Cond, varName, closeTarget) {
		if _, isBlock := ifStmt.Else.(*ast.BlockStmt); !isBlock {
			return true
		}
	}
	return false
}

func extractAssignErrVar(assign *ast.AssignStmt) string {
	if assign == nil || len(assign.Lhs) < 2 {
		return ""
	}
	if id, ok := assign.Lhs[len(assign.Lhs)-1].(*ast.Ident); ok && id.Name != "" && id.Name != "_" {
		return id.Name
	}
	return ""
}

func blockDeclaresVar(block *ast.BlockStmt, name string) bool {
	if block == nil || name == "" {
		return false
	}
	for _, stmt := range block.List {
		switch s := stmt.(type) {
		case *ast.AssignStmt:
			if s.Tok == token.DEFINE {
				for _, lhs := range s.Lhs {
					if id, ok := lhs.(*ast.Ident); ok && id.Name == name {
						return true
					}
				}
			}
		case *ast.DeclStmt:
			if gd, ok := s.Decl.(*ast.GenDecl); ok {
				for _, spec := range gd.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, n := range vs.Names {
							if n != nil && n.Name == name {
								return true
							}
						}
					}
				}
			}
		}
	}
	return false
}

func matchesResourceTargetExpr(fset *token.FileSet, expr ast.Expr, spec *resourceTargetSpec) bool {
	if expr == nil {
		return false
	}
	s := strings.TrimSpace(resourceExprString(fset, unwrapSafetyParens(expr)))
	return s != "" && (s == spec.varName || s == spec.closeTarget || spec.aliases[s])
}

func exprEscapesTargetValue(fset *token.FileSet, expr ast.Expr, spec *resourceTargetSpec) bool {
	e := unwrapSafetyParens(expr)
	if u, ok := e.(*ast.UnaryExpr); ok && u.Op == token.AND {
		e = unwrapSafetyParens(u.X)
	}
	comp, ok := e.(*ast.CompositeLit)
	if !ok {
		return false
	}
	for _, elt := range comp.Elts {
		val := elt
		if kv, ok := elt.(*ast.KeyValueExpr); ok {
			val = kv.Value
		}
		if matchesResourceTargetExpr(fset, val, spec) || exprReferencesCleanupVar(val, spec.cleanupVars) {
			return true
		}
		if lit, ok := unwrapSafetyParens(val).(*ast.FuncLit); ok && lit.Body != nil && funcLitClosesResource(fset, lit.Body, spec, nil) {
			return true
		}
	}
	return false
}

func exprReferencesCleanupVar(expr ast.Expr, cleanupVars map[string]bool) bool {
	if len(cleanupVars) == 0 {
		return false
	}
	id, ok := unwrapSafetyParens(expr).(*ast.Ident)
	return ok && cleanupVars[id.Name]
}

func argsContainTargetExpr(fset *token.FileSet, args []ast.Expr, spec *resourceTargetSpec) bool {
	for _, arg := range args {
		if matchesResourceTargetExpr(fset, arg, spec) || exprEscapesTargetValue(fset, arg, spec) {
			return true
		}
	}
	return false
}

func funcLitClosesInArgs(fset *token.FileSet, args []ast.Expr, spec *resourceTargetSpec) bool {
	for _, arg := range args {
		if lit, ok := unwrapSafetyParens(arg).(*ast.FuncLit); ok && lit.Body != nil && funcLitClosesResource(fset, lit.Body, spec, nil) {
			return true
		}
	}
	return false
}

func deferGuardsResourceTarget(fset *token.FileSet, stmt *ast.DeferStmt, spec *resourceTargetSpec) bool {
	if stmt == nil || stmt.Call == nil {
		return false
	}
	if sel, ok := stmt.Call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
		if (sel.Sel.Name == "Close" || sel.Sel.Name == "Rollback" || sel.Sel.Name == "Commit") && matchesResourceTargetExpr(fset, sel.X, spec) {
			return true
		}
	}
	if id, ok := unwrapSafetyParens(stmt.Call.Fun).(*ast.Ident); ok && spec.cleanupVars[id.Name] {
		return true
	}
	if lit, ok := unwrapSafetyParens(stmt.Call.Fun).(*ast.FuncLit); ok && lit.Body != nil {
		var paramAliases []string
		if lit.Type != nil && lit.Type.Params != nil {
			argIdx := 0
			for _, fld := range lit.Type.Params.List {
				if len(fld.Names) == 0 {
					argIdx++
					continue
				}
				for _, nm := range fld.Names {
					if argIdx < len(stmt.Call.Args) && matchesResourceTargetExpr(fset, stmt.Call.Args[argIdx], spec) {
						paramAliases = append(paramAliases, nm.Name)
					}
					argIdx++
				}
			}
		}
		if funcLitClosesResource(fset, lit.Body, spec, paramAliases) {
			return true
		}
	}
	fnName := strings.ToLower(exprToString(fset, stmt.Call.Fun))
	if strings.Contains(fnName, "close") || strings.Contains(fnName, "clean") || strings.Contains(fnName, "release") || strings.Contains(fnName, "discard") {
		return argsContainTargetExpr(fset, stmt.Call.Args, spec)
	}
	return false
}

func funcLitClosesResource(fset *token.FileSet, body *ast.BlockStmt, spec *resourceTargetSpec, paramAliases []string) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		if sel.Sel.Name == "Close" || sel.Sel.Name == "Rollback" || sel.Sel.Name == "Commit" {
			if matchesResourceTargetExpr(fset, sel.X, spec) {
				found = true
				return false
			}
			recv := strings.TrimSpace(resourceExprString(fset, sel.X))
			for _, pa := range paramAliases {
				if recv == pa {
					found = true
					return false
				}
			}
		}
		return true
	})
	return found
}

func stmtReassignsResourceVar(stmt ast.Stmt, varName string) bool {
	assign, ok := stmt.(*ast.AssignStmt)
	if !ok || varName == "" {
		return false
	}
	for i, lhs := range assign.Lhs {
		if id, ok := unwrapSafetyParens(lhs).(*ast.Ident); ok && id.Name == varName {
			if i < len(assign.Rhs) && isNilIdent(assign.Rhs[i]) {
				return false
			}
			return true
		}
	}
	return false
}

func isErrNotNilGuardCond(fset *token.FileSet, cond ast.Expr, errVar string) bool {
	if errVar != "" {
		if bin, ok := unwrapSafetyParens(cond).(*ast.BinaryExpr); ok && bin.Op == token.NEQ {
			if isNilIdent(bin.Y) && strings.TrimSpace(resourceExprString(fset, bin.X)) == errVar {
				return true
			}
			if isNilIdent(bin.X) && strings.TrimSpace(resourceExprString(fset, bin.Y)) == errVar {
				return true
			}
		}
	}
	return isErrNotNilCheck(fset, cond)
}

func isResourceSuccessCond(fset *token.FileSet, cond ast.Expr, errVar, varName, closeTarget string) bool {
	c := unwrapSafetyParens(cond)
	if c == nil {
		return false
	}
	bin, ok := c.(*ast.BinaryExpr)
	if !ok {
		return false
	}
	if bin.Op == token.LAND {
		return isResourceSuccessCond(fset, bin.X, errVar, varName, closeTarget) ||
			isResourceSuccessCond(fset, bin.Y, errVar, varName, closeTarget)
	}
	if bin.Op == token.EQL && errVar != "-" {
		checkErr := func(expr ast.Expr) bool {
			s := strings.ToLower(strings.TrimSpace(resourceExprString(fset, expr)))
			if errVar != "" && strings.TrimSpace(resourceExprString(fset, expr)) == errVar {
				return true
			}
			return s == "err"
		}
		return (isNilIdent(bin.Y) && checkErr(bin.X)) || (isNilIdent(bin.X) && checkErr(bin.Y))
	}
	if bin.Op == token.NEQ {
		checkVar := func(expr ast.Expr) bool {
			s := strings.TrimSpace(resourceExprString(fset, expr))
			return (varName != "" && s == varName) || (closeTarget != "" && s == closeTarget)
		}
		return (isNilIdent(bin.Y) && checkVar(bin.X)) || (isNilIdent(bin.X) && checkVar(bin.Y))
	}
	return false
}

func isSQLTxErrorSelCheck(fset *token.FileSet, cond ast.Expr, txVar string) bool {
	bin, ok := unwrapSafetyParens(cond).(*ast.BinaryExpr)
	if !ok || bin.Op != token.NEQ || !isNilIdent(bin.Y) {
		return false
	}
	sel, ok := unwrapSafetyParens(bin.X).(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Error" {
		return false
	}
	id, ok := unwrapSafetyParens(sel.X).(*ast.Ident)
	return ok && id.Name == txVar
}

func stmtInsideLoopOrNonBlock(root *ast.BlockStmt, target ast.Node) bool {
	if root == nil || target == nil {
		return false
	}
	loopNodes := make(map[ast.Node]bool)
	inspectLoopBodiesOnce(root, func(n ast.Node) {
		loopNodes[n] = true
	})
	if loopNodes[target] {
		return true
	}
	directStmt := false
	ast.Inspect(root, func(n ast.Node) bool {
		if directStmt {
			return false
		}
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		blk, ok := n.(*ast.BlockStmt)
		if !ok {
			return true
		}
		for _, stmt := range blk.List {
			if stmt == target {
				directStmt = true
				return false
			}
			if exprStmt, ok := stmt.(*ast.ExprStmt); ok && exprStmt.X == target {
				directStmt = true
				return false
			}
		}
		return true
	})
	return !directStmt
}

func inspectStmtResourceEffects(fset *token.FileSet, stmt ast.Stmt, spec *resourceTargetSpec, cur *resourceFlowState) {
	ast.Inspect(stmt, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		switch node := n.(type) {
		case *ast.FuncLit:
			return false
		case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt, *ast.TypeSwitchStmt, *ast.SelectStmt, *ast.BlockStmt:
			if n == stmt {
				switch s := n.(type) {
				case *ast.IfStmt:
					recordResourceCleanupOrEscape(fset, s.Init, spec, cur)
				case *ast.ForStmt:
					recordResourceCleanupOrEscape(fset, s.Init, spec, cur)
				case *ast.SwitchStmt:
					recordResourceCleanupOrEscape(fset, s.Init, spec, cur)
				}
			}
			return false
		case *ast.CallExpr:
			if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
				m := sel.Sel.Name
				if (m == "Close" || m == "Rollback" || m == "Commit") && matchesResourceTargetExpr(fset, sel.X, spec) {
					cur.closed = true
				}
				if (m == "Stop" || m == "Close") && exprReferencesCleanupVar(sel.X, spec.wrapperVars) {
					cur.escaped = true
				}
				if m == "Cleanup" && funcLitClosesInArgs(fset, node.Args, spec) {
					cur.deferred = true
				}
			}
			if id, ok := unwrapSafetyParens(node.Fun).(*ast.Ident); ok {
				if spec.cleanupVars[id.Name] {
					cur.closed = true
				}
				if id.Name == "append" && len(node.Args) >= 2 && argsContainTargetExpr(fset, node.Args[1:], spec) {
					cur.escaped = true
				}
			}
			for _, arg := range node.Args {
				if exprEscapesTargetValue(fset, arg, spec) || exprReferencesCleanupVar(arg, spec.wrapperVars) {
					cur.escaped = true
				}
			}
		case *ast.CompositeLit:
			if exprEscapesTargetValue(fset, node, spec) {
				cur.escaped = true
			}
		}
		return true
	})
}

func stmtAssignsIdent(assign *ast.AssignStmt, name string) bool {
	if assign == nil || name == "" {
		return false
	}
	for _, lhs := range assign.Lhs {
		if id, ok := unwrapSafetyParens(lhs).(*ast.Ident); ok && id.Name == name {
			return true
		}
	}
	return false
}

func goroutineHandlesResource(fset *token.FileSet, stmt *ast.GoStmt, spec *resourceTargetSpec) bool {
	if stmt == nil || stmt.Call == nil {
		return false
	}
	if lit, ok := unwrapSafetyParens(stmt.Call.Fun).(*ast.FuncLit); ok && lit.Body != nil {
		if funcLitClosesResource(fset, lit.Body, spec, nil) {
			return true
		}
		found := false
		ast.Inspect(lit.Body, func(n ast.Node) bool {
			if found || n == nil {
				return false
			}
			if ta, ok := n.(*ast.TypeAssertExpr); ok && matchesResourceTargetExpr(fset, ta.X, spec) {
				found = true
				return false
			}
			if call, ok := n.(*ast.CallExpr); ok && argsContainTargetExpr(fset, call.Args, spec) {
				found = true
				return false
			}
			return true
		})
		return found
	}
	return argsContainTargetExpr(fset, stmt.Call.Args, spec)
}

func forLoopActsAsAcceptDaemon(fset *token.FileSet, body *ast.BlockStmt, spec *resourceTargetSpec) bool {
	if body == nil {
		return false
	}
	callsAccept := false
	hasReturn := false
	ast.Inspect(body, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		if _, isRet := n.(*ast.ReturnStmt); isRet {
			hasReturn = true
		}
		if call, ok := n.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == "Accept" && matchesResourceTargetExpr(fset, sel.X, spec) {
				callsAccept = true
			}
		}
		return true
	})
	return callsAccept && !hasReturn
}

func isResourceReturningTransferCall(fset *token.FileSet, expr ast.Expr, spec *resourceTargetSpec) bool {
	call, ok := unwrapSafetyParens(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	if isNonOwningWrapperCall(fset, call) {
		return false
	}
	if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
		recv := resourceExprString(fset, sel.X)
		if recv == "fmt" || recv == "errors" || recv == "log" || recv == "slog" || recv == "strings" || recv == "bytes" || recv == "strconv" {
			return false
		}
		if matchesResourceTargetExpr(fset, sel.X, spec) {
			return false
		}
	}
	return argsContainTargetExpr(fset, call.Args, spec)
}

func isNonOwningWrapperCall(fset *token.FileSet, call *ast.CallExpr) bool {
	if call == nil {
		return true
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	recv := resourceExprString(fset, sel.X)
	switch recv {
	case "bufio", "json", "xml", "csv", "gzip", "zlib", "flate", "fmt", "log", "slog", "strings", "bytes", "errors":
		return true
	case "io":
		switch sel.Sel.Name {
		case "ReadAll", "Copy", "CopyBuffer", "CopyN", "LimitReader", "TeeReader":
			return true
		}
	}
	return false
}

