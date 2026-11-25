package analysis

import (
	"go/ast"
	"go/token"
	"strings"
)

func referenceClassifyResourceCall(fset *token.FileSet, call *ast.CallExpr) (callDesc string, needsBodyClose bool, matched bool) {
	if call == nil {
		return "", false, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false, false
	}
	method := sel.Sel.Name
	recvStr := exprToString(fset, sel.X)
	if recvStr == "" {
		return "", false, false
	}

	switch recvStr {
	case "os":
		switch method {
		case "Open", "OpenFile", "Create", "CreateTemp":
			return "os." + method, false, true
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

func referenceMatchSQLInjectionCall(fset *token.FileSet, call *ast.CallExpr, dynamicVars map[string]bool) (injectionMatch, bool) {
	if call == nil || len(call.Args) == 0 {
		return injectionMatch{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return injectionMatch{}, false
	}
	method := sel.Sel.Name
	recvStr := exprToString(fset, sel.X)
	if recvStr == "" || recvStr == "url" || strings.HasSuffix(recvStr, ".URL") {
		return injectionMatch{}, false
	}

	var queryArgIdx int
	switch method {
	case "Query", "QueryRow", "Exec", "Prepare":
		queryArgIdx = 0
	case "QueryContext", "QueryRowContext", "ExecContext", "PrepareContext":
		queryArgIdx = 1
	default:
		return injectionMatch{}, false
	}

	if queryArgIdx >= len(call.Args) {
		return injectionMatch{}, false
	}

	queryArg := call.Args[queryArgIdx]
	if !referenceIsDynamicStringExpr(fset, queryArg, dynamicVars) {
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

func referenceMatchCmdInjectionCall(fset *token.FileSet, call *ast.CallExpr, dynamicVars map[string]bool) (injectionMatch, bool) {
	if call == nil || len(call.Args) == 0 {
		return injectionMatch{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return injectionMatch{}, false
	}
	recvStr := exprToString(fset, sel.X)
	method := sel.Sel.Name
	if recvStr != "exec" || (method != "Command" && method != "CommandContext") {
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

	if referenceIsDynamicStringExpr(fset, cmdArg, dynamicVars) {
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
			if referenceIsDynamicStringExpr(fset, payloadArg, dynamicVars) {
				return injectionMatch{
					callName:   callName,
					targetName: exprToString(fset, payloadArg),
				}, true
			}
		}
		if isShell && referenceIsDynamicStringExpr(fset, arg, dynamicVars) {
			return injectionMatch{
				callName:   callName,
				targetName: exprToString(fset, arg),
			}, true
		}
	}

	return injectionMatch{}, false
}

func referenceIsFmtSprintfCall(fset *token.FileSet, expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	recv := exprToString(fset, sel.X)
	if recv == "fmt" && (sel.Sel.Name == "Sprintf" || sel.Sel.Name == "Sprint" || sel.Sel.Name == "Sprintln") {
		return true
	}
	return false
}

func referenceIsDynamicStringExpr(fset *token.FileSet, expr ast.Expr, dynamicVars map[string]bool) bool {
	if expr == nil {
		return false
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return referenceIsDynamicStringExpr(fset, e.X, dynamicVars)
	case *ast.BinaryExpr:
		if isDynamicStringConcatExpr(fset, e, dynamicVars) {
			return true
		}
	case *ast.CallExpr:
		if referenceIsFmtSprintfCall(fset, e) {
			return true
		}
	case *ast.Ident:
		if dynamicVars != nil && dynamicVars[e.Name] {
			return true
		}
	}
	return false
}
