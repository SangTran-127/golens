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

type TimeSafetyInspectRequest struct {
	FilePath      string `json:"filePath"`
	WorkspacePath string `json:"workspacePath"`
	Content       string `json:"content"`
	Scope         string `json:"scope"`
}

type TimeSafetyFinding struct {
	ID          string `json:"id"`
	Category    string `json:"category"`
	Severity    string `json:"severity"`
	Title       string `json:"title"`
	Message     string `json:"message"`
	File        string `json:"file"`
	Line        int    `json:"line"`
	EnclosingFn string `json:"enclosingFn"`
	VarName     string `json:"varName"`
	Snippet     string `json:"snippet"`
	Replacement string `json:"replacement"`
	CanAutoFix  bool   `json:"canAutoFix"`
}

type TimeSafetyInspectReport struct {
	Findings        []TimeSafetyFinding `json:"findings"`
	TotalCount      int                 `json:"totalCount"`
	TimeAfterLoop   int                 `json:"timeAfterLoop"`
	UnstoppedTicker int                 `json:"unstoppedTicker"`
	TimeEquality    int                 `json:"timeEquality"`
	AutoFixable     int                 `json:"autoFixable"`
	Error           string              `json:"error,omitempty"`
}

type TimeSafetyFixRequest struct {
	FilePath  string `json:"filePath"`
	Content   string `json:"content"`
	FindingID string `json:"findingId"`
}

type TimeSafetyFixResult struct {
	AppliedCount int    `json:"appliedCount"`
	NewContent   string `json:"newContent"`
	Error        string `json:"error,omitempty"`
}

func InspectTimeSafety(req TimeSafetyInspectRequest) TimeSafetyInspectReport {
	report := TimeSafetyInspectReport{
		Findings: []TimeSafetyFinding{},
	}

	workspaceDir := strings.TrimSpace(req.WorkspacePath)
	filePath := strings.TrimSpace(req.FilePath)
	scope := strings.ToLower(strings.TrimSpace(req.Scope))
	includeWorkspace := scope == "workspace"

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
		targets = collectWorkspaceGoTargets(absWorkspace, absActiveFile, req.Content, false)
	} else {
		var src []byte
		targetPath := filePath
		if req.Content != "" {
			src = []byte(req.Content)
			if targetPath == "" {
				targetPath = "input.go"
			}
		} else if targetPath != "" {
			data, err := os.ReadFile(targetPath)
			if err != nil {
				report.Error = err.Error()
				return report
			}
			src = data
		} else {
			return report
		}
		targets = append(targets, loadedGoSourceTarget(targetPath, src))
	}

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) []TimeSafetyFinding {
		return inspectASTFileTimeSafety(src.fset, src.file, src.path, string(src.content))
	})
	findings := flattenGoSourceResults(perFile)

	if len(targets) == 1 && len(findings) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		return report
	}

	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Category < findings[j].Category
	})

	for _, f := range findings {
		switch f.Category {
		case "TIME_AFTER_LOOP":
			report.TimeAfterLoop++
		case "TICKER_UNSTOPPED":
			report.UnstoppedTicker++
		case "TIME_EQUALITY":
			report.TimeEquality++
		}
		if f.CanAutoFix {
			report.AutoFixable++
		}
	}

	report.TotalCount = len(findings)
	if findings != nil {
		report.Findings = findings
	}

	return report
}

func ApplyTimeSafetyFixes(req TimeSafetyFixRequest) TimeSafetyFixResult {
	content := req.Content
	filePath := strings.TrimSpace(req.FilePath)
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return TimeSafetyFixResult{
				Error: err.Error(),
			}
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return TimeSafetyFixResult{
			NewContent: content,
			Error:      "empty Go source content",
		}
	}

	if filePath == "" {
		filePath = "input.go"
	}

	report := InspectTimeSafety(TimeSafetyInspectRequest{
		FilePath: filePath,
		Content:  content,
		Scope:    "file",
	})
	if report.Error != "" {
		return TimeSafetyFixResult{
			NewContent: content,
			Error:      report.Error,
		}
	}

	targetID := strings.TrimSpace(req.FindingID)
	var selected []TimeSafetyFinding
	seenKey := make(map[string]bool)

	for _, f := range report.Findings {
		if !f.CanAutoFix || f.Replacement == "" {
			continue
		}
		if targetID != "" && f.ID != targetID {
			continue
		}
		key := fmt.Sprintf("%s:%d:%s", f.Category, f.Line, f.VarName)
		if seenKey[key] {
			continue
		}
		seenKey[key] = true
		selected = append(selected, f)
	}

	if len(selected) == 0 {
		if targetID != "" {
			return TimeSafetyFixResult{
				AppliedCount: 0,
				NewContent:   content,
				Error:        fmt.Sprintf("finding %q not found", targetID),
			}
		}
		return TimeSafetyFixResult{
			AppliedCount: 0,
			NewContent:   formatGoSourceOrFallback(content),
		}
	}

	fset := token.NewFileSet()
	astFile, _ := parser.ParseFile(fset, filePath, content, parser.ParseComments)

	sort.Slice(selected, func(i, j int) bool {
		if selected[i].Line != selected[j].Line {
			return selected[i].Line > selected[j].Line
		}
		return selected[i].Category > selected[j].Category
	})

	lines := strings.Split(content, "\n")
	applied := 0

	for _, f := range selected {
		if f.Line < 1 || f.Line > len(lines) {
			continue
		}

		switch f.Category {
		case "TICKER_UNSTOPPED":
			deferStmt := f.Replacement
			if !strings.HasPrefix(deferStmt, "defer ") {
				deferStmt = fmt.Sprintf("defer %s.Stop()", f.VarName)
			}
			lines = insertTickerStopDeferOnLines(filePath, lines, f.Line, f.VarName, deferStmt)
			applied++

		case "TIME_EQUALITY":
			origLine := lines[f.Line-1]
			codePart, commentSuffix := splitTimeSafetyCodeAndComment(origLine)
			replacedLine, ok := replaceTimeEqualityOnLine(fset, astFile, f.Line, f.Replacement, codePart)
			if ok {
				lines[f.Line-1] = replacedLine + commentSuffix
				applied++
			}
		}
	}

	updated := strings.Join(lines, "\n")
	formatted, err := format.Source([]byte(updated))
	if err == nil {
		updated = string(formatted)
	}

	return TimeSafetyFixResult{
		AppliedCount: applied,
		NewContent:   updated,
	}
}

func insertTickerStopDeferOnLines(
	filePath string,
	lines []string,
	startLine int,
	varName string,
	deferStmt string,
) []string {
	curSrc := strings.Join(lines, "\n")
	curFset := token.NewFileSet()
	curFile, _ := parser.ParseFile(curFset, filePath, curSrc, parser.ParseComments)
	if curFile != nil {
		var matchedStmt ast.Stmt
		bestDist := 1 << 30
		ast.Inspect(curFile, func(n ast.Node) bool {
			stmt, ok := n.(ast.Stmt)
			if !ok {
				return true
			}
			m, ok := matchTickerOrTimerCreationStmt(curFset, stmt)
			if !ok || m.varName != varName {
				return true
			}
			dist := m.line - startLine
			if dist < 0 {
				dist = -dist
			}
			if dist < bestDist {
				bestDist = dist
				matchedStmt = stmt
			}
			return true
		})

		if matchedStmt != nil {
			endPos := curFset.Position(matchedStmt.End())
			endLineIdx := endPos.Line - 1
			colIdx := endPos.Column - 1
			if endLineIdx >= 0 && endLineIdx < len(lines) && colIdx >= 0 && colIdx <= len(lines[endLineIdx]) {
				lineStr := lines[endLineIdx]
				rest := lineStr[colIdx:]
				codeAfter, _ := splitTimeSafetyCodeAndComment(rest)
				codeAfter = stripInlineBlockComments(codeAfter)
				if strings.TrimSpace(codeAfter) != "" {
					lines[endLineIdx] = lineStr[:colIdx] + "; " + deferStmt + lineStr[colIdx:]
					return lines
				}
				indent := leadingWhitespace(lines[startLine-1])
				lines[endLineIdx] = lineStr + "\n" + indent + deferStmt
				return lines
			}
		}
	}

	origLine := lines[startLine-1]
	indent := leadingWhitespace(origLine)
	lines[startLine-1] = origLine + "\n" + indent + deferStmt
	return lines
}

func stripInlineBlockComments(s string) string {
	for {
		start := strings.Index(s, "/*")
		if start < 0 {
			return s
		}
		end := strings.Index(s[start+2:], "*/")
		if end < 0 {
			return s[:start]
		}
		s = s[:start] + " " + s[start+2+end+2:]
	}
}

func replaceTimeEqualityOnLine(
	fset *token.FileSet,
	file *ast.File,
	line int,
	replacement string,
	codePart string,
) (string, bool) {
	if file != nil && fset != nil {
		var matchedExprStr string
		ast.Inspect(file, func(n ast.Node) bool {
			if matchedExprStr != "" || n == nil {
				return false
			}
			bin, ok := n.(*ast.BinaryExpr)
			if !ok || (bin.Op != token.EQL && bin.Op != token.NEQ) {
				return true
			}
			if fset.Position(bin.Pos()).Line != line {
				return true
			}
			lhsStr := strings.TrimSpace(exprToString(fset, bin.X))
			rhsStr := strings.TrimSpace(exprToString(fset, bin.Y))
			if lhsStr == "" || rhsStr == "" {
				return true
			}
			var candReplacement string
			if bin.Op == token.EQL {
				candReplacement = fmt.Sprintf("%s.Equal(%s)", lhsStr, rhsStr)
			} else {
				candReplacement = fmt.Sprintf("!%s.Equal(%s)", lhsStr, rhsStr)
			}
			if candReplacement == replacement {
				matchedExprStr = strings.TrimSpace(exprToString(fset, bin))
				return false
			}
			return true
		})

		if matchedExprStr != "" && strings.Contains(codePart, matchedExprStr) {
			return strings.Replace(codePart, matchedExprStr, replacement, 1), true
		}
	}

	if strings.Contains(codePart, "==") || strings.Contains(codePart, "!=") {
		indent := leadingWhitespace(codePart)
		trimmed := strings.TrimSpace(codePart)
		if strings.HasPrefix(trimmed, "if ") && strings.HasSuffix(trimmed, "{") {
			return fmt.Sprintf("%sif %s {", indent, replacement), true
		}
		if strings.HasPrefix(trimmed, "return ") {
			return fmt.Sprintf("%sreturn %s", indent, replacement), true
		}
	}

	return codePart, false
}

func inspectASTFileTimeSafety(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
) []TimeSafetyFinding {
	var findings []TimeSafetyFinding

	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	fileTimeVars, fileNonTimeVars := collectTimeSafetyVarTypes(fset, file)

	inspectFuncScope := func(fnName string, fnType *ast.FuncType, root *ast.BlockStmt) {
		if root == nil {
			return
		}

		scopeTimeVars := copyBoolMap(fileTimeVars)
		scopeNonTimeVars := copyBoolMap(fileNonTimeVars)
		collectFuncSignatureTimeVars(fnType, scopeTimeVars, scopeNonTimeVars)
		collectBlockTimeVars(fset, root, scopeTimeVars, scopeNonTimeVars)

		stoppedVars := collectStoppedTickerVars(fset, root)
		returnedVars := collectReturnedVars(fset, root)

		fnLabel := fnName
		if fnLabel == "" {
			fnLabel = "the enclosing function"
		}

		ast.Inspect(root, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}
			stmt, ok := n.(ast.Stmt)
			if !ok {
				return true
			}
			m, ok := matchTickerOrTimerCreationStmt(fset, stmt)
			if !ok {
				return true
			}
			if stoppedVars[m.varName] || returnedVars[m.varName] {
				return true
			}
			replacement := fmt.Sprintf("defer %s.Stop()", m.varName)
			findings = append(findings, TimeSafetyFinding{
				ID:          fmt.Sprintf("TICKER_UNSTOPPED:%s:%d:%s", filePath, m.line, m.varName),
				Category:    "TICKER_UNSTOPPED",
				Severity:    "warning",
				Title:       fmt.Sprintf("Unstopped %s '%s' without defer %s.Stop()", m.callName, m.varName, m.varName),
				Message:     fmt.Sprintf("'%s' created by %s is never stopped in %s; add '%s' to prevent timer/goroutine leaks.", m.varName, m.callName, fnLabel, replacement),
				File:        filePath,
				Line:        m.line,
				EnclosingFn: fnName,
				VarName:     m.varName,
				Snippet:     lineAt(m.line),
				Replacement: replacement,
				CanAutoFix:  !stmtInsideLoopOrNonBlock(root, stmt),
			})
			return true
		})

		ast.Inspect(root, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}
			bin, ok := n.(*ast.BinaryExpr)
			if !ok {
				return true
			}
			m, ok := matchTimeEqualityBinaryExpr(fset, bin, scopeTimeVars, scopeNonTimeVars)
			if !ok {
				return true
			}
			line := fset.Position(bin.Pos()).Line
			findings = append(findings, TimeSafetyFinding{
				ID:          fmt.Sprintf("TIME_EQUALITY:%s:%d:%s", filePath, line, m.varName),
				Category:    "TIME_EQUALITY",
				Severity:    "warning",
				Title:       fmt.Sprintf("Direct '%s' comparison on time.Time instead of .Equal()", m.opStr),
				Message:     fmt.Sprintf("Comparing time.Time values with '%s' compares monotonic clock readings and Location pointers; rewrite '%s' to '%s'.", m.opStr, m.origExpr, m.replacement),
				File:        filePath,
				Line:        line,
				EnclosingFn: fnName,
				VarName:     m.varName,
				Snippet:     lineAt(line),
				Replacement: m.replacement,
				CanAutoFix:  true,
			})
			return true
		})

		seenTimeAfter := make(map[token.Pos]bool)
		inspectLoopBodiesOnce(root, func(n ast.Node) {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return
			}
			if seenTimeAfter[call.Pos()] {
				return
			}
			argStr, ok := matchTimeAfterCall(fset, call)
			if !ok {
				return
			}
			seenTimeAfter[call.Pos()] = true
			line := fset.Position(call.Pos()).Line
			if argStr == "" {
				argStr = "d"
			}
			replacement := fmt.Sprintf("timer := time.NewTimer(%s); defer timer.Stop()", argStr)
			findings = append(findings, TimeSafetyFinding{
				ID:          fmt.Sprintf("TIME_AFTER_LOOP:%s:%d:time.After", filePath, line),
				Category:    "TIME_AFTER_LOOP",
				Severity:    "warning",
				Title:       "time.After called inside loop leaks timer until it fires",
				Message:     fmt.Sprintf("time.After(%s) inside a loop allocates a new timer on every iteration that is not garbage-collected until it expires; use time.NewTicker or time.NewTimer with defer Stop().", argStr),
				File:        filePath,
				Line:        line,
				EnclosingFn: fnName,
				VarName:     "time.After",
				Snippet:     lineAt(line),
				Replacement: replacement,
				CanAutoFix:  false,
			})
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
		inspectFuncScope(fnName, fn.Type, fn.Body)

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			lit, ok := n.(*ast.FuncLit)
			if ok && lit.Body != nil {
				inspectFuncScope(fnName, lit.Type, lit.Body)
			}
			return true
		})
	}

	return findings
}

type tickerCreationMatch struct {
	varName  string
	callName string
	line     int
}

func matchTickerOrTimerCreationStmt(fset *token.FileSet, stmt ast.Stmt) (tickerCreationMatch, bool) {
	switch s := stmt.(type) {
	case *ast.AssignStmt:
		if len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			return tickerCreationMatch{}, false
		}
		ident, ok := s.Lhs[0].(*ast.Ident)
		if !ok || ident.Name == "" || ident.Name == "_" {
			return tickerCreationMatch{}, false
		}
		callName, ok := matchNewTickerOrTimerCall(fset, s.Rhs[0])
		if !ok {
			return tickerCreationMatch{}, false
		}
		return tickerCreationMatch{
			varName:  ident.Name,
			callName: callName,
			line:     fset.Position(s.Pos()).Line,
		}, true

	case *ast.DeclStmt:
		genDecl, ok := s.Decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.VAR || len(genDecl.Specs) != 1 {
			return tickerCreationMatch{}, false
		}
		vs, ok := genDecl.Specs[0].(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || vs.Names[0] == nil || len(vs.Values) != 1 {
			return tickerCreationMatch{}, false
		}
		varName := vs.Names[0].Name
		if varName == "" || varName == "_" {
			return tickerCreationMatch{}, false
		}
		callName, ok := matchNewTickerOrTimerCall(fset, vs.Values[0])
		if !ok {
			return tickerCreationMatch{}, false
		}
		return tickerCreationMatch{
			varName:  varName,
			callName: callName,
			line:     fset.Position(s.Pos()).Line,
		}, true
	}

	return tickerCreationMatch{}, false
}

func matchNewTickerOrTimerCall(_ *token.FileSet, expr ast.Expr) (string, bool) {
	call, ok := expr.(*ast.CallExpr)
	if !ok || len(call.Args) != 1 {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "time" {
		return "", false
	}
	switch sel.Sel.Name {
	case "NewTicker", "NewTimer":
		return "time." + sel.Sel.Name, true
	default:
		return "", false
	}
}

func matchTimeAfterCall(fset *token.FileSet, call *ast.CallExpr) (string, bool) {
	if call == nil || len(call.Args) != 1 {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "After" {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "time" {
		return "", false
	}
	return strings.TrimSpace(exprToString(fset, call.Args[0])), true
}

func collectStoppedTickerVars(fset *token.FileSet, body *ast.BlockStmt) map[string]bool {
	stopped := make(map[string]bool)
	if body == nil {
		return stopped
	}

	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil || sel.Sel.Name != "Stop" {
			return true
		}
		recv := strings.TrimSpace(exprToString(fset, sel.X))
		if recv != "" {
			stopped[recv] = true
		}
		return true
	})

	return stopped
}

type timeEqualityMatch struct {
	varName     string
	opStr       string
	origExpr    string
	replacement string
}

func matchTimeEqualityBinaryExpr(
	fset *token.FileSet,
	bin *ast.BinaryExpr,
	timeVars map[string]bool,
	nonTimeVars map[string]bool,
) (timeEqualityMatch, bool) {
	if bin == nil || (bin.Op != token.EQL && bin.Op != token.NEQ) {
		return timeEqualityMatch{}, false
	}
	if isNilOrLiteralOrBoolExpr(bin.X) || isNilOrLiteralOrBoolExpr(bin.Y) {
		return timeEqualityMatch{}, false
	}
	if isExplicitlyNonTimeExpr(fset, bin.X, nonTimeVars) || isExplicitlyNonTimeExpr(fset, bin.Y, nonTimeVars) {
		return timeEqualityMatch{}, false
	}

	lhsIsTime := isTimeValueExpr(fset, bin.X, timeVars, nonTimeVars)
	rhsIsTime := isTimeValueExpr(fset, bin.Y, timeVars, nonTimeVars)
	if !lhsIsTime && !rhsIsTime {
		return timeEqualityMatch{}, false
	}

	lhsStr := strings.TrimSpace(exprToString(fset, bin.X))
	rhsStr := strings.TrimSpace(exprToString(fset, bin.Y))
	if lhsStr == "" || rhsStr == "" {
		return timeEqualityMatch{}, false
	}

	origExpr := strings.TrimSpace(exprToString(fset, bin))
	opStr := bin.Op.String()

	var replacement string
	if bin.Op == token.EQL {
		replacement = fmt.Sprintf("%s.Equal(%s)", lhsStr, rhsStr)
	} else {
		replacement = fmt.Sprintf("!%s.Equal(%s)", lhsStr, rhsStr)
	}

	varName := lhsStr
	if !lhsIsTime {
		varName = rhsStr
	}

	return timeEqualityMatch{
		varName:     varName,
		opStr:       opStr,
		origExpr:    origExpr,
		replacement: replacement,
	}, true
}

func isNilOrLiteralOrBoolExpr(expr ast.Expr) bool {
	if expr == nil {
		return true
	}
	switch e := expr.(type) {
	case *ast.BasicLit:
		return true
	case *ast.Ident:
		return e.Name == "nil" || e.Name == "true" || e.Name == "false" || e.Name == "iota"
	case *ast.ParenExpr:
		return isNilOrLiteralOrBoolExpr(e.X)
	case *ast.UnaryExpr:
		return isNilOrLiteralOrBoolExpr(e.X)
	}
	return false
}

func isExplicitlyNonTimeExpr(fset *token.FileSet, expr ast.Expr, nonTimeVars map[string]bool) bool {
	if expr == nil {
		return true
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isExplicitlyNonTimeExpr(fset, e.X, nonTimeVars)
	case *ast.Ident:
		return nonTimeVars != nil && nonTimeVars[e.Name]
	case *ast.SelectorExpr:
		if pkgIdent, ok := e.X.(*ast.Ident); ok && pkgIdent.Name == "time" {
			return true
		}
		return false
	case *ast.CallExpr:
		if ident, ok := e.Fun.(*ast.Ident); ok {
			switch ident.Name {
			case "len", "cap", "string", "int", "int64", "uint64", "float64", "bool":
				return true
			}
		}
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok && pkgIdent.Name == "time" {
				switch sel.Sel.Name {
				case "Now", "Date", "Unix", "UnixMilli", "UnixMicro":
					return false
				default:
					return true
				}
			}
			switch sel.Sel.Name {
			case "Unix", "UnixNano", "UnixMilli", "UnixMicro", "Format", "String", "Sub",
				"Year", "Month", "Day", "Hour", "Minute", "Second", "Nanosecond", "YearDay",
				"Weekday", "Location", "IsZero", "Before", "After", "Equal", "Compare":
				return true
			}
		}
	}
	return false
}

func isTimeValueExpr(
	fset *token.FileSet,
	expr ast.Expr,
	timeVars map[string]bool,
	nonTimeVars map[string]bool,
) bool {
	if expr == nil {
		return false
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isTimeValueExpr(fset, e.X, timeVars, nonTimeVars)

	case *ast.Ident:
		if nonTimeVars != nil && nonTimeVars[e.Name] {
			return false
		}
		if timeVars != nil && timeVars[e.Name] {
			return true
		}
		return isTimeRelatedIdentifierName(e.Name)

	case *ast.SelectorExpr:
		if e.Sel == nil {
			return false
		}
		if pkgIdent, ok := e.X.(*ast.Ident); ok && pkgIdent.Name == "time" {
			return false
		}
		return isTimeRelatedIdentifierName(e.Sel.Name)

	case *ast.CallExpr:
		return isTimeProducingCallExpr(fset, e, timeVars, nonTimeVars)

	case *ast.CompositeLit:
		return isTimeTypeExpr(e.Type)
	}
	return false
}

func isTimeProducingCallExpr(
	fset *token.FileSet,
	call *ast.CallExpr,
	timeVars map[string]bool,
	nonTimeVars map[string]bool,
) bool {
	if call == nil {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	if pkgIdent, ok := sel.X.(*ast.Ident); ok && pkgIdent.Name == "time" {
		switch sel.Sel.Name {
		case "Now", "Date", "Unix", "UnixMilli", "UnixMicro":
			return true
		default:
			return false
		}
	}

	switch sel.Sel.Name {
	case "Add", "AddDate", "UTC", "Local", "In", "Truncate", "Round":
		return isTimeValueExpr(fset, sel.X, timeVars, nonTimeVars)
	}
	return false
}

func isTimeParseCallExpr(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "time" {
		return false
	}
	return sel.Sel.Name == "Parse" || sel.Sel.Name == "ParseInLocation"
}

func isTimeTypeExpr(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Time" {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	return ok && pkgIdent.Name == "time"
}

func isTimeRelatedIdentifierName(name string) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || trimmed == "_" || trimmed == "nil" || trimmed == "true" || trimmed == "false" {
		return false
	}

	lower := strings.ToLower(trimmed)
	if lower == "runtime" || lower == "lifetime" || lower == "overtime" || lower == "downtime" || lower == "uptime" || lower == "meantime" || lower == "sometime" {
		return false
	}

	for _, nonTimeSuffix := range []string{
		"str", "string", "fmt", "format", "layout", "dur", "duration",
		"timeout", "interval", "sec", "secs", "seconds", "ms", "millis",
		"micros", "nanos", "unix", "err", "error", "count", "ok", "valid",
		"zone", "loc", "location", "ticker", "timer",
	} {
		if strings.HasSuffix(lower, nonTimeSuffix) {
			return false
		}
	}

	switch lower {
	case "now", "deadline", "timestamp", "ts", "expiry", "expiration",
		"createdat", "updatedat", "deletedat", "expiresat", "expiredat",
		"startedat", "endedat", "finishedat", "completedat", "publishedat",
		"scheduledat", "issuedat", "modifiedat", "accessedat", "lastseenat",
		"sentat", "receivedat", "triggeredat", "firedat", "recordedat",
		"occurredat", "observedat":
		return true
	}

	for _, snakeSuffix := range []string{"_at", "_time", "_ts", "_timestamp", "_deadline"} {
		if strings.HasSuffix(lower, snakeSuffix) {
			return true
		}
	}

	if strings.HasSuffix(trimmed, "Time") && len(trimmed) > 4 {
		return true
	}
	if strings.HasSuffix(trimmed, "Timestamp") || strings.HasSuffix(trimmed, "Deadline") {
		return true
	}

	for _, prefix := range []string{"now", "deadline", "timestamp", "expiresat", "createdat", "updatedat"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}

	if len(lower) == 3 && strings.HasPrefix(lower, "ts") && lower[2] >= '0' && lower[2] <= '9' {
		return true
	}

	return false
}

func collectTimeSafetyVarTypes(fset *token.FileSet, file *ast.File) (map[string]bool, map[string]bool) {
	timeVars := make(map[string]bool)
	nonTimeVars := make(map[string]bool)
	if file == nil {
		return timeVars, nonTimeVars
	}

	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gd.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			recordValueSpecTimeVars(fset, vs, timeVars, nonTimeVars)
		}
	}

	return timeVars, nonTimeVars
}

func collectFuncSignatureTimeVars(fnType *ast.FuncType, timeVars map[string]bool, nonTimeVars map[string]bool) {
	if fnType == nil {
		return
	}
	recordFieldList := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, field := range fl.List {
			if field == nil || field.Type == nil {
				continue
			}
			isTime := isTimeTypeExpr(field.Type)
			for _, ident := range field.Names {
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				if isTime {
					timeVars[ident.Name] = true
					delete(nonTimeVars, ident.Name)
				} else {
					nonTimeVars[ident.Name] = true
				}
			}
		}
	}
	recordFieldList(fnType.Params)
	recordFieldList(fnType.Results)
}

func collectBlockTimeVars(fset *token.FileSet, root *ast.BlockStmt, timeVars map[string]bool, nonTimeVars map[string]bool) {
	if root == nil {
		return
	}
	for pass := 0; pass < 2; pass++ {
		ast.Inspect(root, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}
			switch node := n.(type) {
			case *ast.ValueSpec:
				recordValueSpecTimeVars(fset, node, timeVars, nonTimeVars)

			case *ast.AssignStmt:
				if len(node.Rhs) == 1 && len(node.Lhs) >= 2 && isTimeParseCallExpr(node.Rhs[0]) {
					if ident, ok := node.Lhs[0].(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
						timeVars[ident.Name] = true
						delete(nonTimeVars, ident.Name)
					}
					return true
				}
				for i, rhs := range node.Rhs {
					if i >= len(node.Lhs) {
						break
					}
					ident, ok := node.Lhs[i].(*ast.Ident)
					if !ok || ident.Name == "" || ident.Name == "_" {
						continue
					}
					if isTimeValueExpr(fset, rhs, timeVars, nonTimeVars) {
						timeVars[ident.Name] = true
						delete(nonTimeVars, ident.Name)
					} else if _, isTicker := matchNewTickerOrTimerCall(fset, rhs); isTicker || isNilOrLiteralOrBoolExpr(rhs) {
						if !timeVars[ident.Name] {
							nonTimeVars[ident.Name] = true
						}
					}
				}
			}
			return true
		})
	}
}

func recordValueSpecTimeVars(
	fset *token.FileSet,
	vs *ast.ValueSpec,
	timeVars map[string]bool,
	nonTimeVars map[string]bool,
) {
	if vs == nil {
		return
	}
	if vs.Type != nil {
		isTime := isTimeTypeExpr(vs.Type)
		for _, ident := range vs.Names {
			if ident == nil || ident.Name == "" || ident.Name == "_" {
				continue
			}
			if isTime {
				timeVars[ident.Name] = true
				delete(nonTimeVars, ident.Name)
			} else {
				nonTimeVars[ident.Name] = true
			}
		}
	}
	if len(vs.Values) == 1 && len(vs.Names) >= 2 && isTimeParseCallExpr(vs.Values[0]) {
		if ident := vs.Names[0]; ident != nil && ident.Name != "" && ident.Name != "_" {
			timeVars[ident.Name] = true
			delete(nonTimeVars, ident.Name)
		}
		return
	}
	for i, val := range vs.Values {
		if i >= len(vs.Names) {
			break
		}
		ident := vs.Names[i]
		if ident == nil || ident.Name == "" || ident.Name == "_" {
			continue
		}
		if isTimeValueExpr(fset, val, timeVars, nonTimeVars) {
			timeVars[ident.Name] = true
			delete(nonTimeVars, ident.Name)
		} else if _, isTicker := matchNewTickerOrTimerCall(fset, val); isTicker || isNilOrLiteralOrBoolExpr(val) {
			if !timeVars[ident.Name] {
				nonTimeVars[ident.Name] = true
			}
		}
	}
}

func copyBoolMap(src map[string]bool) map[string]bool {
	dst := make(map[string]bool, len(src))
	for k, v := range src {
		dst[k] = v
	}
	return dst
}

func splitTimeSafetyCodeAndComment(line string) (string, string) {
	idx := findLineCommentOutsideTicks(line)
	if idx < 0 {
		return line, ""
	}
	return line[:idx], line[idx:]
}
