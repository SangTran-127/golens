package analysis

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
)

const (
	exprContextBackground = "context.Background()"
	exprContextTODO       = "context.TODO()"
)

type ConcurrencyReport struct {
	FilePath         string               `json:"filePath"`
	GoroutineCount   int                  `json:"goroutineCount"`
	ContextCallCount int                  `json:"contextCallCount"`
	Findings         []ConcurrencyFinding `json:"findings"`
}

type ConcurrencyFinding struct {
	ID           string `json:"id"`
	Kind         string `json:"kind"`
	Severity     string `json:"severity"`
	Line         int    `json:"line"`
	FunctionName string `json:"functionName"`
	CodeSnippet  string `json:"codeSnippet"`
	Summary      string `json:"summary"`
	Suggestion   string `json:"suggestion"`
	CanAutoFix   bool   `json:"canAutoFix"`
	FixedPreview string `json:"fixedPreview"`
}

type ConcurrencyFixResult struct {
	UpdatedSource string `json:"updatedSource"`
	Title         string `json:"title"`
	Summary       string `json:"summary"`
	Error         string `json:"error"`
}

func InspectFileConcurrency(filePath string, content string) (string, error) {
	if content == "" && filePath != "" {
		if data, err := os.ReadFile(filePath); err == nil {
			content = string(data)
		}
	}

	report := ConcurrencyReport{
		FilePath: filePath,
		Findings: []ConcurrencyFinding{},
	}

	if strings.TrimSpace(content) == "" {
		out, err := json.Marshal(report)
		return string(out), err
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if file == nil {
		out, _ := json.Marshal(report)
		return string(out), err
	}

	report = inspectConcurrencyAST(fset, file, filePath, content)
	out, marshalErr := json.Marshal(report)
	if marshalErr != nil {
		return "", marshalErr
	}
	return string(out), nil
}

func inspectConcurrencyAST(fset *token.FileSet, file *ast.File, filePath, content string) ConcurrencyReport {
	report := ConcurrencyReport{
		FilePath: filePath,
		Findings: []ConcurrencyFinding{},
	}
	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	ast.Inspect(file, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.GoStmt:
			report.GoroutineCount++
		case *ast.CallExpr:
			if isSelectorCall(node, "context", "") {
				report.ContextCallCount++
			}
		}
		return true
	})

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := "<anonymous>"
		if fn.Name != nil && fn.Name.Name != "" {
			funcName = fn.Name.Name
		}
		ctxParam := findContextParamName(fn)

		inspectBlockForMissingCancel(fset, fn, fn.Body, funcName, lineAt, &report.Findings)
		inspectFuncForContextBackground(fset, fn, funcName, ctxParam, lineAt, &report.Findings)
		inspectFuncForUnboundedGoroutines(fset, fn, funcName, lineAt, &report.Findings)
	}

	sort.SliceStable(report.Findings, func(i, j int) bool {
		if report.Findings[i].Line != report.Findings[j].Line {
			return report.Findings[i].Line < report.Findings[j].Line
		}
		return report.Findings[i].Kind < report.Findings[j].Kind
	})
	return report
}

func ApplyConcurrencyQuickFix(filePath string, content string, line int, kind string) (string, error) {
	if content == "" && filePath != "" {
		if data, err := os.ReadFile(filePath); err == nil {
			content = string(data)
		}
	}

	var fset *token.FileSet
	var file *ast.File
	if line >= 1 && line <= strings.Count(content, "\n")+1 {
		fset = token.NewFileSet()
		file, _ = parser.ParseFile(fset, filePath, content, parser.ParseComments)
	}

	res, fixErr := applyConcurrencyQuickFixAST(fset, file, filePath, content, line, kind)
	out, marshalErr := json.Marshal(res)
	if marshalErr != nil && fixErr == nil {
		return "", marshalErr
	}
	return string(out), fixErr
}

func applyConcurrencyQuickFixAST(fset *token.FileSet, file *ast.File, filePath string, content string, line int, kind string) (ConcurrencyFixResult, error) {
	lines := strings.Split(content, "\n")
	if line < 1 || line > len(lines) {
		res := ConcurrencyFixResult{
			UpdatedSource: content,
			Error:         fmt.Sprintf("line %d is out of range (1..%d)", line, len(lines)),
		}
		return res, fmt.Errorf("%s", res.Error)
	}

	var updated string
	var summary, title string

	switch kind {
	case "missing_cancel_defer":
		var cancelName string
		var fixErr error
		updated, summary, cancelName, fixErr = applyMissingCancelDeferFix(fset, file, content, lines, line)
		if fixErr != nil {
			res := ConcurrencyFixResult{UpdatedSource: content, Error: fixErr.Error()}
			return res, fixErr
		}
		title = fmt.Sprintf("Add defer %s()", cancelName)

	case "context_background_in_func":
		targetLine := lines[line-1]
		var enclosingFn *ast.FuncDecl
		if file != nil {
			enclosingFn = findEnclosingFuncAtLine(fset, file, line)
		}
		ctxParam := ""
		if enclosingFn != nil {
			ctxParam = findContextParamName(enclosingFn)
		}

		if ctxParam == "" || !hasNamedContextParam(enclosingFn) {
			res := ConcurrencyFixResult{UpdatedSource: content, Error: "the function has no named context parameter to pass along"}
			return res, fmt.Errorf("%s", res.Error)
		}

		replaced := strings.ReplaceAll(targetLine, exprContextBackground, ctxParam)
		replaced = strings.ReplaceAll(replaced, exprContextTODO, ctxParam)
		switch {
		case strings.Contains(targetLine, exprContextBackground):
			summary = fmt.Sprintf("Replaced context.Background() with parameter %q on line %d", ctxParam, line)
			title = fmt.Sprintf("Use %s Instead of context.Background()", ctxParam)
		case strings.Contains(targetLine, exprContextTODO):
			summary = fmt.Sprintf("Replaced context.TODO() with parameter %q on line %d", ctxParam, line)
			title = fmt.Sprintf("Use %s Instead of context.TODO()", ctxParam)
		}
		lines[line-1] = replaced
		updated = strings.Join(lines, "\n")

	default:
		res := ConcurrencyFixResult{
			UpdatedSource: content,
			Error:         fmt.Sprintf("unsupported concurrency quick-fix kind %q", kind),
		}
		return res, fmt.Errorf("%s", res.Error)
	}

	if updated != content {
		checkFset := token.NewFileSet()
		if _, parseErr := parser.ParseFile(checkFset, filePath, updated, parser.AllErrors); parseErr != nil {
			res := ConcurrencyFixResult{
				UpdatedSource: content,
				Summary:       "",
				Error:         fmt.Sprintf("quick fix aborted to prevent syntax error: %v", parseErr),
			}
			return res, nil
		}
	}

	res := ConcurrencyFixResult{
		UpdatedSource: updated,
		Title:         title,
		Summary:       summary,
		Error:         "",
	}
	return res, nil
}

func inspectBlockForMissingCancel(
	fset *token.FileSet,
	_ *ast.FuncDecl,
	body *ast.BlockStmt,
	funcName string,
	lineAt func(int) string,
	findings *[]ConcurrencyFinding,
) {
	var deferredOrReturned map[string]bool
	cancelHandled := func(cancelName string) bool {
		if body == nil || cancelName == "" {
			return false
		}
		if deferredOrReturned == nil {
			deferredOrReturned = collectDeferredOrReturnedNames(body)
		}
		return deferredOrReturned[cancelName]
	}
	ast.Inspect(body, func(n ast.Node) bool {
		switch stmt := n.(type) {
		case *ast.AssignStmt:
			if len(stmt.Rhs) != 1 || len(stmt.Lhs) < 2 {
				return true
			}
			call, ok := stmt.Rhs[0].(*ast.CallExpr)
			if !ok {
				return true
			}
			callName := contextCancelFactoryName(call)
			if callName == "" {
				return true
			}
			cancelIdent, ok := stmt.Lhs[1].(*ast.Ident)
			if !ok {
				return true
			}
			line := fset.Position(stmt.Pos()).Line
			cancelName := cancelIdent.Name
			if cancelName == "_" {
				snippet := lineAt(line)
				*findings = append(*findings, ConcurrencyFinding{
					ID:           fmt.Sprintf("missing_cancel_defer:%d", line),
					Kind:         "missing_cancel_defer",
					Severity:     "warning",
					Line:         line,
					FunctionName: funcName,
					CodeSnippet:  snippet,
					Summary:      fmt.Sprintf("Cancel function from context.%s is discarded with '_' in %s, leaking context resources", callName, funcName),
					Suggestion:   "Assign the cancel function to 'cancel' and call 'defer cancel()' immediately",
					CanAutoFix:   stmt.Tok == token.DEFINE,
					FixedPreview: fmt.Sprintf("%s\ndefer cancel()", replaceDiscardedCancelOnLine(snippet, "cancel")),
				})
				return true
			}
			if !cancelHandled(cancelName) {
				snippet := lineAt(line)
				*findings = append(*findings, ConcurrencyFinding{
					ID:           fmt.Sprintf("missing_cancel_defer:%d", line),
					Kind:         "missing_cancel_defer",
					Severity:     "warning",
					Line:         line,
					FunctionName: funcName,
					CodeSnippet:  snippet,
					Summary:      fmt.Sprintf("Cancel function %q from context.%s is not deferred in %s, risking a context or timer leak", cancelName, callName, funcName),
					Suggestion:   fmt.Sprintf("Add 'defer %s()' immediately after creating the derived context", cancelName),
					CanAutoFix:   true,
					FixedPreview: fmt.Sprintf("%s\ndefer %s()", snippet, cancelName),
				})
			}

		case *ast.ValueSpec:
			if len(stmt.Values) != 1 || len(stmt.Names) < 2 {
				return true
			}
			call, ok := stmt.Values[0].(*ast.CallExpr)
			if !ok {
				return true
			}
			callName := contextCancelFactoryName(call)
			if callName == "" {
				return true
			}
			cancelIdent := stmt.Names[1]
			line := fset.Position(stmt.Pos()).Line
			cancelName := cancelIdent.Name
			if cancelName == "_" {
				cancelName = "cancel"
			}
			if cancelIdent.Name == "_" || !cancelHandled(cancelName) {
				snippet := lineAt(line)
				*findings = append(*findings, ConcurrencyFinding{
					ID:           fmt.Sprintf("missing_cancel_defer:%d", line),
					Kind:         "missing_cancel_defer",
					Severity:     "warning",
					Line:         line,
					FunctionName: funcName,
					CodeSnippet:  snippet,
					Summary:      fmt.Sprintf("Cancel function %q from context.%s is not deferred in %s, risking a context or timer leak", cancelName, callName, funcName),
					Suggestion:   fmt.Sprintf("Add 'defer %s()' immediately after creating the derived context", cancelName),
					CanAutoFix:   true,
					FixedPreview: fmt.Sprintf("%s\ndefer %s()", snippet, cancelName),
				})
			}
		}
		return true
	})
}

func inspectFuncForContextBackground(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	funcName string,
	ctxParam string,
	lineAt func(int) string,
	findings *[]ConcurrencyFinding,
) {
	seenLines := make(map[int]bool)
	isEntry := isRootEntryFunc(funcName)

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if n == nil {
			return false
		}

		call, ok := n.(*ast.CallExpr)
		if ok && (isSelectorCall(call, "context", "Background") || isSelectorCall(call, "context", "TODO")) {
			sel := call.Fun.(*ast.SelectorExpr)
			callKind := "context." + sel.Sel.Name + "()"
			line := fset.Position(call.Pos()).Line

			shouldFlag := false
			if sel.Sel.Name == "TODO" {
				if ctxParam != "" {
					shouldFlag = true
				}
			} else {
				if !isEntry {
					shouldFlag = true
				} else if ctxParam != "" {
					shouldFlag = true
				}
			}

			if shouldFlag && !seenLines[line] {
				seenLines[line] = true
				snippet := lineAt(line)
				severity := "warning"
				var summary, suggestion, preview string

				if ctxParam != "" {
					summary = fmt.Sprintf("%s used in %s despite existing '%s context.Context' parameter", callKind, funcName, ctxParam)
					suggestion = fmt.Sprintf("Replace %s with %q to preserve caller cancellation and deadlines", callKind, ctxParam)
					preview = strings.Replace(snippet, callKind, ctxParam, 1)
				} else if sel.Sel.Name == "Background" {
					summary = fmt.Sprintf("%s creates a fresh root context inside %s instead of propagating a caller context", callKind, funcName)
					suggestion = "Accept a 'ctx context.Context' parameter and pass it instead of context.Background()"
					preview = snippet
				} else {
					severity = "info"
					summary = fmt.Sprintf("%s placeholder context used inside %s without a 'ctx context.Context' parameter", callKind, funcName)
					suggestion = fmt.Sprintf("Add 'ctx context.Context' to %s and replace %s with 'ctx'", funcName, callKind)
					preview = strings.Replace(snippet, exprContextTODO, "ctx", 1)
				}

				*findings = append(*findings, ConcurrencyFinding{
					ID:           fmt.Sprintf("context_background_in_func:%d", line),
					Kind:         "context_background_in_func",
					Severity:     severity,
					Line:         line,
					FunctionName: funcName,
					CodeSnippet:  snippet,
					Summary:      summary,
					Suggestion:   suggestion,
					CanAutoFix:   hasNamedContextParam(fn),
					FixedPreview: preview,
				})
			}
		}

		return true
	})
}

func inspectFuncForUnboundedGoroutines(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	funcName string,
	lineAt func(int) string,
	findings *[]ConcurrencyFinding,
) {
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		goStmt, ok := n.(*ast.GoStmt)
		if !ok {
			return true
		}
		if hasLifecycleGuard(goStmt) {
			return true
		}
		line := fset.Position(goStmt.Pos()).Line
		snippet := lineAt(line)
		*findings = append(*findings, ConcurrencyFinding{
			ID:           fmt.Sprintf("unbounded_goroutine:%d", line),
			Kind:         "unbounded_goroutine",
			Severity:     "warning",
			Line:         line,
			FunctionName: funcName,
			CodeSnippet:  snippet,
			Summary:      "Goroutine launched without an explicit cancellation or WaitGroup lifecycle check in this block",
			Suggestion:   "Pass a cancellable context.Context and select on <-ctx.Done(), or coordinate completion with sync.WaitGroup / errgroup",
			CanAutoFix:   false,
			FixedPreview: snippet,
		})
		return true
	})
}

func hasLifecycleGuard(goStmt *ast.GoStmt) bool {
	if goStmt == nil || goStmt.Call == nil {
		return false
	}

	foundGuard := false
	ast.Inspect(goStmt.Call, func(n ast.Node) bool {
		if foundGuard {
			return false
		}
		switch node := n.(type) {
		case *ast.CallExpr:
			if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
				switch sel.Sel.Name {
				case "Done", "Wait", "Cancel":
					foundGuard = true
					return false
				}
			}
		case *ast.UnaryExpr:
			if node.Op == token.ARROW {
				switch x := node.X.(type) {
				case *ast.Ident:
					lower := strings.ToLower(x.Name)
					if strings.Contains(lower, "done") || strings.Contains(lower, "stop") || strings.Contains(lower, "quit") || strings.Contains(lower, "cancel") || strings.Contains(lower, "ctx") {
						foundGuard = true
						return false
					}
				case *ast.CallExpr:
					if sel, ok := x.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == "Done" {
						foundGuard = true
						return false
					}
				}
			}
		}
		return true
	})
	return foundGuard
}

func contextCancelFactoryName(call *ast.CallExpr) string {
	if call == nil {
		return ""
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return ""
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "context" {
		return ""
	}
	switch sel.Sel.Name {
	case "WithCancel", "WithCancelCause", "WithTimeout", "WithTimeoutCause", "WithDeadline", "WithDeadlineCause":
		return sel.Sel.Name
	default:
		return ""
	}
}

func isSelectorCall(call *ast.CallExpr, pkgName string, selName string) bool {
	if call == nil {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	ident, ok := sel.X.(*ast.Ident)
	if !ok || ident.Name != pkgName {
		return false
	}
	if selName != "" && sel.Sel.Name != selName {
		return false
	}
	return true
}

func findContextParamName(fn *ast.FuncDecl) string {
	if fn == nil || fn.Type == nil || fn.Type.Params == nil {
		return ""
	}
	for _, field := range fn.Type.Params.List {
		sel, ok := field.Type.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil || sel.Sel.Name != "Context" {
			continue
		}
		pkgIdent, ok := sel.X.(*ast.Ident)
		if !ok || pkgIdent.Name != "context" {
			continue
		}
		if len(field.Names) > 0 && field.Names[0].Name != "" && field.Names[0].Name != "_" {
			return field.Names[0].Name
		}
		return "ctx"
	}
	return ""
}

func hasNamedContextParam(fn *ast.FuncDecl) bool {
	name := findContextParamName(fn)
	if name == "" || fn.Type.Params == nil {
		return false
	}
	for _, field := range fn.Type.Params.List {
		for _, ident := range field.Names {
			if ident.Name == name {
				return true
			}
		}
	}
	return false
}

func unusedIdentName(scope ast.Node, base string) string {
	used := make(map[string]bool)
	if scope != nil {
		ast.Inspect(scope, func(n ast.Node) bool {
			if ident, ok := n.(*ast.Ident); ok {
				used[ident.Name] = true
			}
			return true
		})
	}
	if !used[base] {
		return base
	}
	for i := 2; ; i++ {
		candidate := fmt.Sprintf("%s%d", base, i)
		if !used[candidate] {
			return candidate
		}
	}
}

func isRootEntryFunc(name string) bool {
	if name == "main" || name == "init" {
		return true
	}
	return strings.HasPrefix(name, "Test") ||
		strings.HasPrefix(name, "Benchmark") ||
		strings.HasPrefix(name, "Example") ||
		strings.HasPrefix(name, "Fuzz")
}

func findEnclosingFuncAtLine(fset *token.FileSet, file *ast.File, line int) *ast.FuncDecl {
	if file == nil {
		return nil
	}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		startLine := fset.Position(fn.Pos()).Line
		endLine := fset.Position(fn.End()).Line
		if line >= startLine && line <= endLine {
			return fn
		}
	}
	return nil
}

func applyMissingCancelDeferFix(fset *token.FileSet, file *ast.File, content string, lines []string, line int) (string, string, string, error) {
	cancelName := "cancel"
	discardAssigned := false
	stmtStartOffset := -1
	stmtEndOffset := -1
	stmtEndLine := line
	rbraceLine := -1
	var assignTok token.Token
	var enclosing *ast.FuncDecl

	if file != nil {
		if fn := findEnclosingFuncAtLine(fset, file, line); fn != nil && fn.Body != nil {
			enclosing = fn
			rbraceLine = fset.Position(fn.Body.Rbrace).Line
		}
		ast.Inspect(file, func(n ast.Node) bool {
			if stmtEndOffset >= 0 {
				return false
			}
			switch stmt := n.(type) {
			case *ast.AssignStmt:
				if fset.Position(stmt.Pos()).Line == line && len(stmt.Lhs) >= 2 && len(stmt.Rhs) == 1 {
					if call, ok := stmt.Rhs[0].(*ast.CallExpr); ok && contextCancelFactoryName(call) != "" {
						if ident, ok := stmt.Lhs[1].(*ast.Ident); ok {
							if ident.Name == "_" {
								discardAssigned = true
							} else {
								cancelName = ident.Name
							}
							assignTok = stmt.Tok
							stmtStartOffset = fset.Position(stmt.Pos()).Offset
							stmtEndOffset = fset.Position(stmt.End()).Offset
							stmtEndLine = fset.Position(stmt.End()).Line
							return false
						}
					}
				}
			case *ast.ValueSpec:
				if fset.Position(stmt.Pos()).Line == line && len(stmt.Names) >= 2 && len(stmt.Values) == 1 {
					if call, ok := stmt.Values[0].(*ast.CallExpr); ok && contextCancelFactoryName(call) != "" {
						ident := stmt.Names[1]
						if ident.Name == "_" {
							discardAssigned = true
						} else {
							cancelName = ident.Name
						}
						assignTok = token.VAR
						stmtStartOffset = fset.Position(stmt.Pos()).Offset
						stmtEndOffset = fset.Position(stmt.End()).Offset
						stmtEndLine = fset.Position(stmt.End()).Line
						return false
					}
				}
			}
			return true
		})
	}

	if discardAssigned {
		if assignTok == token.ASSIGN {
			return content, "", "", fmt.Errorf("the discarded cancel function on line %d is assigned with '=', so there is no new variable to defer", line)
		}
		if enclosing != nil {
			cancelName = unusedIdentName(enclosing, "cancel")
		}
	}

	inlineNeeded := false
	if rbraceLine == stmtEndLine && stmtEndOffset > 0 && stmtEndOffset <= len(content) {
		inlineNeeded = true
	} else if stmtEndOffset > 0 && stmtEndOffset <= len(content) {
		restOfLine := content[stmtEndOffset:]
		if nl := strings.IndexByte(restOfLine, '\n'); nl >= 0 {
			restOfLine = restOfLine[:nl]
		}
		trimmedRest := strings.TrimSpace(restOfLine)
		if idx := strings.Index(trimmedRest, "//"); idx >= 0 {
			trimmedRest = strings.TrimSpace(trimmedRest[:idx])
		}
		if trimmedRest != "" {
			inlineNeeded = true
		}
	}

	if inlineNeeded && stmtStartOffset >= 0 && stmtEndOffset >= stmtStartOffset && stmtEndOffset <= len(content) {
		stmtSegment := content[stmtStartOffset:stmtEndOffset]
		if discardAssigned {
			stmtSegment = replaceDiscardedCancelOnLine(stmtSegment, cancelName)
		}
		updated := content[:stmtStartOffset] + stmtSegment + "; defer " + cancelName + "()" + content[stmtEndOffset:]
		return updated, fmt.Sprintf("Inserted 'defer %s()' on line %d", cancelName, line), cancelName, nil
	}

	if discardAssigned {
		lines[line-1] = replaceDiscardedCancelOnLine(lines[line-1], cancelName)
	}
	if stmtEndLine < line || stmtEndLine > len(lines) {
		stmtEndLine = line
	}
	indent := leadingWhitespace(lines[line-1])
	deferLine := indent + "defer " + cancelName + "()"
	newLines := make([]string, 0, len(lines)+1)
	newLines = append(newLines, lines[:stmtEndLine]...)
	newLines = append(newLines, deferLine)
	newLines = append(newLines, lines[stmtEndLine:]...)
	return strings.Join(newLines, "\n"), fmt.Sprintf("Inserted 'defer %s()' after line %d", cancelName, stmtEndLine), cancelName, nil
}

func replaceDiscardedCancelOnLine(lineText string, replacement string) string {
	for _, sep := range []string{":=", "="} {
		idx := strings.Index(lineText, sep)
		if idx <= 0 {
			continue
		}
		lhs := lineText[:idx]
		rhs := lineText[idx:]
		parts := strings.SplitN(lhs, ",", 2)
		if len(parts) == 2 && strings.TrimSpace(parts[1]) == "_" {
			return parts[0] + ", " + replacement + " " + rhs
		}
	}
	return lineText
}

func leadingWhitespace(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	return s[:i]
}
