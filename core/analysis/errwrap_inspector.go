package analysis

import (
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type ErrorWrappingFinding struct {
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
	FixTitle     string `json:"fixTitle,omitempty"`
}

type ErrorWrappingReport struct {
	TotalFindings   int                    `json:"totalFindings"`
	VerbCount       int                    `json:"verbCount"`
	EqualityCount   int                    `json:"equalityCount"`
	TypeAssertCount int                    `json:"typeAssertCount"`
	Findings        []ErrorWrappingFinding `json:"findings"`
	Error           string                 `json:"error,omitempty"`
}

func InspectErrorWrapping(workspaceDir, filePath, content string, includeWorkspace bool) (ErrorWrappingReport, error) {
	report := ErrorWrappingReport{
		Findings: []ErrorWrappingFinding{},
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

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) []ErrorWrappingFinding {
		return inspectASTFileErrorWrapping(src.fset, src.file, src.path, string(src.content))
	})
	findings := flattenGoSourceResults(perFile)

	if len(targets) == 1 && len(findings) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		return report, firstParseErr
	}

	sortErrorWrappingFindings(findings)

	for _, f := range findings {
		switch f.Kind {
		case "ERRWRAP_VERB":
			report.VerbCount++
		case "ERRWRAP_EQUALITY":
			report.EqualityCount++
		case "ERRWRAP_TYPE_ASSERT":
			report.TypeAssertCount++
		}
	}

	report.TotalFindings = len(findings)
	if findings != nil {
		report.Findings = findings
	}

	return report, nil
}

func inspectASTFileErrorWrapping(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
) []ErrorWrappingFinding {
	var findings []ErrorWrappingFinding
	errorVars := collectErrorVarNames(file)
	errorsImportFree := !importNameTaken(file, "errors", "errors")

	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	var funcStack []string
	currentFuncName := func() string {
		if len(funcStack) == 0 {
			return ""
		}
		return funcStack[len(funcStack)-1]
	}

	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			if len(funcStack) > 0 {
				funcStack = funcStack[:len(funcStack)-1]
			}
			return false
		}

		fnName := currentFuncName()
		if fn, ok := n.(*ast.FuncDecl); ok && fn.Name != nil {
			fnName = fn.Name.Name
		}
		funcStack = append(funcStack, fnName)

		switch node := n.(type) {
		case *ast.CallExpr:
			if match, ok := matchErrorWrapVerbCall(fset, node, errorVars); ok {
				pos := fset.Position(node.Pos())
				findings = append(findings, ErrorWrappingFinding{
					Kind:         "ERRWRAP_VERB",
					Severity:     "warning",
					Title:        "fmt.Errorf formats the error with %v instead of %w",
					Message:      "Formatting an error with %v or %s discards the underlying error chain; use %w so callers can inspect it with errors.Is and errors.As.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   match.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: match.suggestedFix,
					CanQuickFix:  true,
					FixTitle:     "Wrap the Error With %w",
				})
			}

		case *ast.BinaryExpr:
			if match, ok := matchErrorEqualityExpr(fset, node, errorVars); ok {
				pos := fset.Position(node.Pos())
				fixTitle := ""
				if errorsImportFree {
					fixTitle = "Use errors.Is"
				}
				findings = append(findings, ErrorWrappingFinding{
					Kind:         "ERRWRAP_EQUALITY",
					Severity:     "warning",
					Title:        fmt.Sprintf("Error compared with %s instead of errors.Is", match.opStr),
					Message:      "Direct equality comparison fails when the sentinel error is wrapped; use errors.Is(err, target) to unwrap the error chain.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   match.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: match.suggestedFix,
					CanQuickFix:  errorsImportFree,
					FixTitle:     fixTitle,
				})
			}

		case *ast.TypeAssertExpr:
			if match, ok := matchErrorTypeAssertExpr(fset, node, errorVars); ok {
				pos := fset.Position(node.Pos())
				findings = append(findings, ErrorWrappingFinding{
					Kind:         "ERRWRAP_TYPE_ASSERT",
					Severity:     "warning",
					Title:        "Type assertion on an error instead of errors.As",
					Message:      "Type assertion on an error value fails when the error is wrapped; use errors.As(err, &target) to inspect the error chain.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   match.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: match.suggestedFix,
					CanQuickFix:  false,
				})
			}
		}

		return true
	})

	return findings
}

type printfVerbSpan struct {
	start            int
	end              int
	verbChar         byte
	argIndex         int
	hasExplicitIndex bool
}

func parseBracketedArgIndex(rawLit string, pos int, limit int) (int, int, bool) {
	if pos >= limit || rawLit[pos] != '[' {
		return 0, pos, false
	}
	k := pos + 1
	val := 0
	digits := 0
	for k < limit && rawLit[k] >= '0' && rawLit[k] <= '9' {
		val = val*10 + int(rawLit[k]-'0')
		digits++
		k++
	}
	if digits > 0 && k < limit && rawLit[k] == ']' {
		return val, k + 1, true
	}
	for k < limit && rawLit[k] != ']' {
		k++
	}
	if k < limit && rawLit[k] == ']' {
		k++
	}
	return 0, k, false
}

func parsePrintfVerbsInLiteral(rawLit string) []printfVerbSpan {
	if len(rawLit) < 2 {
		return nil
	}
	quote := rawLit[0]
	var spans []printfVerbSpan
	limit := len(rawLit) - 1
	argNum := 1
	for i := 1; i < limit; i++ {
		ch := rawLit[i]
		if quote == '"' && ch == '\\' {
			i++
			continue
		}
		if ch != '%' {
			continue
		}
		if i+1 < limit && rawLit[i+1] == '%' {
			i++
			continue
		}
		verbStart := i
		j := i + 1
		for j < limit && strings.ContainsRune("+-# 0", rune(rawLit[j])) {
			j++
		}
		idx1, nextJ, hasIdx1 := parseBracketedArgIndex(rawLit, j, limit)
		j = nextJ
		if j < limit && rawLit[j] == '*' {
			j++
			if hasIdx1 && idx1 > 0 {
				argNum = idx1 + 1
				hasIdx1 = false
			} else {
				argNum++
			}
		} else {
			for j < limit && rawLit[j] >= '0' && rawLit[j] <= '9' {
				j++
			}
		}
		if j < limit && rawLit[j] == '.' {
			j++
			idx2, nextJ2, hasIdx2 := parseBracketedArgIndex(rawLit, j, limit)
			j = nextJ2
			if j < limit && rawLit[j] == '*' {
				j++
				if hasIdx2 && idx2 > 0 {
					argNum = idx2 + 1
				} else {
					argNum++
				}
			} else {
				if hasIdx2 && idx2 > 0 {
					idx1 = idx2
					hasIdx1 = true
				}
				for j < limit && rawLit[j] >= '0' && rawLit[j] <= '9' {
					j++
				}
			}
		}
		idx3, nextJ3, hasIdx3 := parseBracketedArgIndex(rawLit, j, limit)
		j = nextJ3
		if hasIdx3 && idx3 > 0 {
			idx1 = idx3
			hasIdx1 = true
		}
		if j < limit && ((rawLit[j] >= 'a' && rawLit[j] <= 'z') || (rawLit[j] >= 'A' && rawLit[j] <= 'Z')) {
			verbArgIdx := argNum
			explicit := false
			if hasIdx1 && idx1 > 0 {
				verbArgIdx = idx1
				explicit = true
			}
			argNum = verbArgIdx + 1
			spans = append(spans, printfVerbSpan{
				start:            verbStart,
				end:              j + 1,
				verbChar:         rawLit[j],
				argIndex:         verbArgIdx,
				hasExplicitIndex: explicit,
			})
			i = j
		}
	}
	return spans
}

type verbMatchInfo struct {
	formatLit    *ast.BasicLit
	verbSpan     printfVerbSpan
	newFormatLit string
	errArg       ast.Expr
	targetName   string
	suggestedFix string
}

func matchErrorWrapVerbCall(fset *token.FileSet, call *ast.CallExpr, errorVars map[string]bool) (verbMatchInfo, bool) {
	if call == nil || len(call.Args) < 2 {
		return verbMatchInfo{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Errorf" {
		return verbMatchInfo{}, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "fmt" {
		return verbMatchInfo{}, false
	}
	formatLit, ok := call.Args[0].(*ast.BasicLit)
	if !ok || formatLit.Kind != token.STRING {
		return verbMatchInfo{}, false
	}

	verbs := parsePrintfVerbsInLiteral(formatLit.Value)
	if len(verbs) == 0 {
		return verbMatchInfo{}, false
	}
	for _, v := range verbs {
		if v.verbChar == 'w' {
			return verbMatchInfo{}, false
		}
	}

	args := call.Args[1:]
	matchedIdx := -1
	var matchedArg ast.Expr

	for idx := len(verbs) - 1; idx >= 0; idx-- {
		v := verbs[idx]
		if v.verbChar != 'v' && v.verbChar != 's' {
			continue
		}
		argIdx := v.argIndex - 1
		if argIdx >= 0 && argIdx < len(args) && isErrorValueExpr(args[argIdx], errorVars) {
			matchedIdx = idx
			matchedArg = args[argIdx]
			break
		}
	}

	if matchedIdx < 0 {
		lastVerb := verbs[len(verbs)-1]
		lastArg := args[len(args)-1]
		if !lastVerb.hasExplicitIndex && (lastVerb.verbChar == 'v' || lastVerb.verbChar == 's') && isErrorValueExpr(lastArg, errorVars) {
			matchedIdx = len(verbs) - 1
			matchedArg = lastArg
		}
	}

	if matchedIdx < 0 || matchedArg == nil {
		return verbMatchInfo{}, false
	}

	span := verbs[matchedIdx]
	replacementVerb := "%w"
	if span.hasExplicitIndex {
		replacementVerb = fmt.Sprintf("%%[%d]w", span.argIndex)
	}
	newLit := formatLit.Value[:span.start] + replacementVerb + formatLit.Value[span.end:]
	targetName := exprToString(fset, matchedArg)

	var argStrings []string
	argStrings = append(argStrings, newLit)
	for _, a := range args {
		argStrings = append(argStrings, exprToString(fset, a))
	}
	suggestedFix := fmt.Sprintf("fmt.Errorf(%s)", strings.Join(argStrings, ", "))

	return verbMatchInfo{
		formatLit:    formatLit,
		verbSpan:     span,
		newFormatLit: newLit,
		errArg:       matchedArg,
		targetName:   targetName,
		suggestedFix: suggestedFix,
	}, true
}

type equalityMatchInfo struct {
	binExpr      *ast.BinaryExpr
	opStr        string
	targetName   string
	suggestedFix string
}

func matchErrorEqualityExpr(fset *token.FileSet, bin *ast.BinaryExpr, errorVars map[string]bool) (equalityMatchInfo, bool) {
	if bin == nil || (bin.Op != token.EQL && bin.Op != token.NEQ) {
		return equalityMatchInfo{}, false
	}
	if isNilIdent(bin.X) || isNilIdent(bin.Y) {
		return equalityMatchInfo{}, false
	}

	lhsErr := isErrorVarExpr(bin.X, errorVars)
	rhsErr := isErrorVarExpr(bin.Y, errorVars)
	lhsSentinel := isSentinelErrorExpr(bin.X)
	rhsSentinel := isSentinelErrorExpr(bin.Y)

	var targetExpr ast.Expr
	if lhsErr && rhsSentinel {
		targetExpr = bin.Y
	} else if lhsSentinel && rhsErr {
		targetExpr = bin.X
	} else if lhsErr && rhsErr {
		targetExpr = bin.Y
	} else {
		return equalityMatchInfo{}, false
	}

	lhsStr := exprToString(fset, bin.X)
	rhsStr := exprToString(fset, bin.Y)
	targetStr := exprToString(fset, targetExpr)
	opStr := bin.Op.String()

	var suggestedFix string
	if bin.Op == token.EQL {
		suggestedFix = fmt.Sprintf("errors.Is(%s, %s)", lhsStr, rhsStr)
	} else {
		suggestedFix = fmt.Sprintf("!errors.Is(%s, %s)", lhsStr, rhsStr)
	}

	return equalityMatchInfo{
		binExpr:      bin,
		opStr:        opStr,
		targetName:   targetStr,
		suggestedFix: suggestedFix,
	}, true
}

type typeAssertMatchInfo struct {
	taExpr       *ast.TypeAssertExpr
	targetName   string
	suggestedFix string
}

func matchErrorTypeAssertExpr(fset *token.FileSet, ta *ast.TypeAssertExpr, errorVars map[string]bool) (typeAssertMatchInfo, bool) {
	if ta == nil || ta.Type == nil {
		return typeAssertMatchInfo{}, false
	}
	if !isErrorVarExpr(ta.X, errorVars) {
		return typeAssertMatchInfo{}, false
	}
	typeStr := exprToString(fset, ta.Type)
	if typeStr == "error" || typeStr == "any" || typeStr == "interface{}" {
		return typeAssertMatchInfo{}, false
	}
	errStr := exprToString(fset, ta.X)
	return typeAssertMatchInfo{
		taExpr:       ta,
		targetName:   typeStr,
		suggestedFix: fmt.Sprintf("errors.As(%s, &target)", errStr),
	}, true
}

func collectErrorVarNames(file *ast.File) map[string]bool {
	out := make(map[string]bool)
	if file == nil {
		return out
	}

	ast.Inspect(file, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.Field:
			if isErrorTypeExpr(node.Type) {
				for _, ident := range node.Names {
					if ident != nil && ident.Name != "" && ident.Name != "_" {
						out[ident.Name] = true
					}
				}
			}
		case *ast.ValueSpec:
			if isErrorTypeExpr(node.Type) {
				for _, ident := range node.Names {
					if ident != nil && ident.Name != "" && ident.Name != "_" {
						out[ident.Name] = true
					}
				}
			}
			for i, val := range node.Values {
				if isErrorProducingCall(val) && i < len(node.Names) {
					if ident := node.Names[i]; ident != nil && ident.Name != "" && ident.Name != "_" {
						out[ident.Name] = true
					}
				}
			}
		case *ast.AssignStmt:
			for i, rhs := range node.Rhs {
				if isErrorProducingCall(rhs) && i < len(node.Lhs) {
					if ident, ok := node.Lhs[i].(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
						out[ident.Name] = true
					}
				}
			}
		}
		return true
	})

	return out
}

func isErrorTypeExpr(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	if ident, ok := expr.(*ast.Ident); ok {
		return ident.Name == "error"
	}
	return false
}

func isErrorProducingCall(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return false
	}
	if pkgIdent.Name == "errors" && (sel.Sel.Name == "New" || sel.Sel.Name == "Join") {
		return true
	}
	if pkgIdent.Name == "fmt" && sel.Sel.Name == "Errorf" {
		return true
	}
	return false
}

func isNilIdent(expr ast.Expr) bool {
	ident, ok := expr.(*ast.Ident)
	return ok && ident.Name == "nil"
}

func isErrorVarName(name string, errorVars map[string]bool) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || trimmed == "_" || trimmed == "nil" || trimmed == "true" || trimmed == "false" {
		return false
	}
	if errorVars != nil && errorVars[trimmed] {
		return true
	}
	lower := strings.ToLower(trimmed)
	for _, nonErrSuffix := range []string{"msg", "message", "str", "string", "text", "code", "count"} {
		if strings.HasSuffix(lower, nonErrSuffix) {
			return false
		}
	}
	if lower == "err" || lower == "error" {
		return true
	}
	if strings.HasPrefix(trimmed, "err") {
		return true
	}
	if strings.HasSuffix(trimmed, "Err") || strings.HasSuffix(trimmed, "Error") || strings.HasSuffix(lower, "_err") || strings.HasSuffix(lower, "_error") {
		return true
	}
	return false
}

func isErrorVarExpr(expr ast.Expr, errorVars map[string]bool) bool {
	switch e := expr.(type) {
	case *ast.Ident:
		return isErrorVarName(e.Name, errorVars)
	case *ast.SelectorExpr:
		if e.Sel == nil {
			return false
		}
		if isSentinelErrorExpr(e) {
			return false
		}
		return isErrorVarName(e.Sel.Name, nil)
	default:
		return false
	}
}

func isErrorValueExpr(expr ast.Expr, errorVars map[string]bool) bool {
	if isErrorVarExpr(expr, errorVars) || isSentinelErrorExpr(expr) || isErrorProducingCall(expr) {
		return true
	}
	if ident, ok := expr.(*ast.Ident); ok {
		if strings.Contains(ident.Name, "Err") || strings.Contains(ident.Name, "Error") {
			return true
		}
	}
	if sel, ok := expr.(*ast.SelectorExpr); ok && sel.Sel != nil {
		if strings.Contains(sel.Sel.Name, "Err") || strings.Contains(sel.Sel.Name, "Error") {
			return true
		}
	}
	return false
}

func isSentinelErrorExpr(expr ast.Expr) bool {
	switch e := expr.(type) {
	case *ast.Ident:
		name := e.Name
		if name == "" || name == "nil" || name == "err" {
			return false
		}
		if strings.HasPrefix(name, "Err") || strings.HasPrefix(name, "err") && len(name) > 3 {
			return true
		}
		if strings.Contains(name, "Err") || strings.Contains(name, "Error") || name == "EOF" {
			return true
		}
		return false

	case *ast.SelectorExpr:
		if e.Sel == nil {
			return false
		}
		selName := e.Sel.Name
		if strings.HasPrefix(selName, "Err") || strings.Contains(selName, "Err") || strings.Contains(selName, "Error") {
			return true
		}
		if pkgIdent, ok := e.X.(*ast.Ident); ok {
			switch pkgIdent.Name + "." + selName {
			case "io.EOF", "context.Canceled", "context.DeadlineExceeded", "sql.ErrNoRows", "os.ErrNotExist", "os.ErrPermission", "os.ErrClosed", "fs.ErrNotExist", "fs.ErrPermission", "fs.ErrClosed", "http.ErrServerClosed":
				return true
			}
		}
		return false

	default:
		return false
	}
}

func FixErrorWrappingIssue(filePath, content string, line int, kind, targetName string) (string, error) {
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

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil || astFile == nil {
		return content, err
	}

	errorVars := collectErrorVarNames(astFile)
	trimmedTarget := strings.TrimSpace(targetName)

	switch kind {
	case "ERRWRAP_VERB":
		return applyErrorWrapVerbFix(fset, astFile, content, line, trimmedTarget, errorVars)
	case "ERRWRAP_EQUALITY":
		if importNameTaken(astFile, "errors", "errors") {
			return content, fmt.Errorf("another import already uses the name errors")
		}
		return applyErrorEqualityFix(fset, astFile, filePath, content, line, trimmedTarget, errorVars)
	case "ERRWRAP_TYPE_ASSERT":
		return applyErrorTypeAssertFix(fset, astFile, filePath, content, line, trimmedTarget, errorVars)
	default:
		return content, fmt.Errorf("unsupported error wrapping fix kind %q", kind)
	}
}

func applyErrorWrapVerbFix(
	fset *token.FileSet,
	file *ast.File,
	content string,
	line int,
	targetName string,
	errorVars map[string]bool,
) (string, error) {
	type candidate struct {
		match verbMatchInfo
		line  int
	}
	var all []candidate

	ast.Inspect(file, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if m, ok := matchErrorWrapVerbCall(fset, call, errorVars); ok {
			callLine := fset.Position(call.Pos()).Line
			litLine := fset.Position(m.formatLit.Pos()).Line
			effLine := callLine
			if line == litLine {
				effLine = litLine
			}
			all = append(all, candidate{match: m, line: effLine})
		}
		return true
	})

	if len(all) == 0 {
		return formatGoSourceOrFallback(content), nil
	}

	lines := strings.Split(content, "\n")
	if line >= 1 && line <= len(lines) && strings.Contains(lines[line-1], "fmt.Errorf") && strings.Contains(lines[line-1], "%w") {
		return formatGoSourceOrFallback(content), nil
	}

	var chosen *candidate
	for i := range all {
		if all[i].line == line && (targetName == "" || all[i].match.targetName == targetName) {
			chosen = &all[i]
			break
		}
	}
	if chosen == nil {
		for i := range all {
			if all[i].line == line {
				chosen = &all[i]
				break
			}
		}
	}
	if chosen == nil && targetName != "" {
		bestDist := 1000000
		for i := range all {
			if all[i].match.targetName == targetName {
				dist := absInt(all[i].line - line)
				if dist < bestDist && dist <= 12 {
					bestDist = dist
					chosen = &all[i]
				}
			}
		}
	}
	if chosen == nil {
		return formatGoSourceOrFallback(content), nil
	}

	startOff := fset.Position(chosen.match.formatLit.Pos()).Offset
	endOff := fset.Position(chosen.match.formatLit.End()).Offset
	if startOff < 0 || endOff <= startOff || endOff > len(content) {
		return content, fmt.Errorf("invalid source span for format literal on line %d", line)
	}

	updated := content[:startOff] + chosen.match.newFormatLit + content[endOff:]
	return formatGoSourceOrFallback(updated), nil
}

func applyErrorEqualityFix(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
	line int,
	targetName string,
	errorVars map[string]bool,
) (string, error) {
	type candidate struct {
		match equalityMatchInfo
		line  int
	}
	var all []candidate

	ast.Inspect(file, func(n ast.Node) bool {
		bin, ok := n.(*ast.BinaryExpr)
		if !ok {
			return true
		}
		if m, ok := matchErrorEqualityExpr(fset, bin, errorVars); ok {
			binLine := fset.Position(bin.Pos()).Line
			all = append(all, candidate{match: m, line: binLine})
		}
		return true
	})

	if len(all) == 0 {
		withImport := ensureGoImport(filePath, content, "errors")
		return formatGoSourceOrFallback(withImport), nil
	}

	lines := strings.Split(content, "\n")
	if line >= 1 && line <= len(lines) && strings.Contains(lines[line-1], "errors.Is(") {
		hasSameLineCandidate := false
		for _, c := range all {
			if c.line == line {
				hasSameLineCandidate = true
				break
			}
		}
		if !hasSameLineCandidate {
			return formatGoSourceOrFallback(content), nil
		}
	}

	var chosen *candidate
	for i := range all {
		if all[i].line == line && (targetName == "" || all[i].match.targetName == targetName) {
			chosen = &all[i]
			break
		}
	}
	if chosen == nil {
		for i := range all {
			if all[i].line == line {
				chosen = &all[i]
				break
			}
		}
	}
	if chosen == nil && targetName != "" {
		bestDist := 1000000
		for i := range all {
			if all[i].match.targetName == targetName {
				dist := absInt(all[i].line - line)
				if dist < bestDist && dist <= 12 {
					bestDist = dist
					chosen = &all[i]
				}
			}
		}
	}
	if chosen == nil {
		return formatGoSourceOrFallback(content), nil
	}

	startOff := fset.Position(chosen.match.binExpr.Pos()).Offset
	endOff := fset.Position(chosen.match.binExpr.End()).Offset
	if startOff < 0 || endOff <= startOff || endOff > len(content) {
		return content, fmt.Errorf("invalid source span for error comparison on line %d", line)
	}

	updated := content[:startOff] + chosen.match.suggestedFix + content[endOff:]
	withImport := ensureGoImport(filePath, updated, "errors")
	return formatGoSourceOrFallback(withImport), nil
}

func applyErrorTypeAssertFix(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
	line int,
	targetName string,
	errorVars map[string]bool,
) (string, error) {
	var matchedIf *ast.IfStmt
	var matchedTa *ast.TypeAssertExpr
	var targetVarName string

	ast.Inspect(file, func(n ast.Node) bool {
		ifStmt, ok := n.(*ast.IfStmt)
		if !ok || ifStmt.Init == nil {
			return true
		}
		ifLine := fset.Position(ifStmt.Pos()).Line
		if ifLine != line {
			return true
		}
		assign, ok := ifStmt.Init.(*ast.AssignStmt)
		if !ok || len(assign.Rhs) != 1 || len(assign.Lhs) < 1 {
			return true
		}
		ta, ok := assign.Rhs[0].(*ast.TypeAssertExpr)
		if !ok {
			return true
		}
		m, ok := matchErrorTypeAssertExpr(fset, ta, errorVars)
		if !ok {
			return true
		}
		if targetName != "" && m.targetName != targetName {
			return true
		}
		matchedIf = ifStmt
		matchedTa = ta
		if ident, ok := assign.Lhs[0].(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
			targetVarName = ident.Name
		} else {
			targetVarName = "targetErr"
		}
		return false
	})

	if matchedIf != nil && matchedTa != nil && matchedIf.Body != nil {
		startOff := fset.Position(matchedIf.Pos()).Offset
		bodyOff := fset.Position(matchedIf.Body.Lbrace).Offset
		if startOff >= 0 && bodyOff > startOff && bodyOff <= len(content) {
			typeStr := exprToString(fset, matchedTa.Type)
			errStr := exprToString(fset, matchedTa.X)
			replacement := fmt.Sprintf("var %s %s\n\tif errors.As(%s, &%s) ", targetVarName, typeStr, errStr, targetVarName)
			updated := content[:startOff] + replacement + content[bodyOff:]
			withImport := ensureGoImport(filePath, updated, "errors")
			return formatGoSourceOrFallback(withImport), nil
		}
	}

	return formatGoSourceOrFallback(content), nil
}

func ensureGoImport(filePath, src, importPath string) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil || file == nil {
		return src
	}

	for _, imp := range file.Imports {
		if imp.Path != nil && strings.Trim(imp.Path.Value, "\"`") == importPath {
			return src
		}
	}

	var firstImportDecl *ast.GenDecl
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if ok && gd.Tok == token.IMPORT {
			firstImportDecl = gd
			break
		}
	}

	if firstImportDecl != nil {
		if firstImportDecl.Lparen.IsValid() && firstImportDecl.Rparen.IsValid() {
			rparenOff := fset.Position(firstImportDecl.Rparen).Offset
			if rparenOff >= 0 && rparenOff <= len(src) {
				return src[:rparenOff] + fmt.Sprintf("\t%q\n", importPath) + src[rparenOff:]
			}
		}
		startOff := fset.Position(firstImportDecl.Pos()).Offset
		endOff := fset.Position(firstImportDecl.End()).Offset
		if startOff >= 0 && endOff >= startOff && endOff <= len(src) {
			var specs []string
			for _, spec := range firstImportDecl.Specs {
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
			specs = append(specs, fmt.Sprintf("\t%q", importPath))
			replacement := "import (\n" + strings.Join(specs, "\n") + "\n)"
			return src[:startOff] + replacement + src[endOff:]
		}
	}

	if file.Name != nil {
		pkgEndOff := fset.Position(file.Name.End()).Offset
		if pkgEndOff >= 0 && pkgEndOff <= len(src) {
			for pkgEndOff < len(src) && src[pkgEndOff] != '\n' {
				pkgEndOff++
			}
			return src[:pkgEndOff] + fmt.Sprintf("\n\nimport %q", importPath) + src[pkgEndOff:]
		}
	}

	return src
}

func importNameTaken(file *ast.File, name, wantPath string) bool {
	if file == nil {
		return false
	}
	for _, imp := range file.Imports {
		if imp.Path == nil {
			continue
		}
		path := strings.Trim(imp.Path.Value, "\"`")
		local := path[strings.LastIndex(path, "/")+1:]
		if imp.Name != nil {
			local = imp.Name.Name
		}
		if local == name && path != wantPath {
			return true
		}
		if path == wantPath && local != name {
			return true
		}
	}
	return false
}

func formatGoSourceOrFallback(src string) string {
	formatted, err := format.Source([]byte(src))
	if err != nil {
		return src
	}
	return string(formatted)
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func sortErrorWrappingFindings(findings []ErrorWrappingFinding) {
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
}
