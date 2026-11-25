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

type ModernizeFinding struct {
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

type ModernizeReport struct {
	TotalFindings int                `json:"totalFindings"`
	AnyCount      int                `json:"anyCount"`
	RangeIntCount int                `json:"rangeIntCount"`
	MinMaxCount   int                `json:"minMaxCount"`
	Findings      []ModernizeFinding `json:"findings"`
	Error         string             `json:"error,omitempty"`
}

func InspectGoModernization(workspaceDir, filePath, content string, includeWorkspace bool) (ModernizeReport, error) {
	report := ModernizeReport{
		Findings: []ModernizeFinding{},
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

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) []ModernizeFinding {
		return inspectASTFileModernization(src.fset, src.file, src.path, string(src.content))
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
		case "MODERN_ANY":
			report.AnyCount++
		case "MODERN_RANGE_INT":
			report.RangeIntCount++
		case "MODERN_MIN_MAX":
			report.MinMaxCount++
		}
	}

	report.TotalFindings = len(findings)
	if findings != nil {
		report.Findings = findings
	}

	return report, nil
}

func inspectASTFileModernization(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
) []ModernizeFinding {
	var findings []ModernizeFinding
	anyIsPredeclared := !fileDeclaresIdent(file, "any")

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
		case *ast.InterfaceType:
			if isEmptyInterfaceType(node) {
				pos := fset.Position(node.Pos())
				findings = append(findings, ModernizeFinding{
					Kind:         "MODERN_ANY",
					Severity:     "info",
					Title:        "Use any instead of interface{}",
					Message:      "Empty interface{} can be replaced with the predeclared 'any' type alias introduced in Go 1.18.",
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   "interface{}",
					Snippet:      lineAt(pos.Line),
					SuggestedFix: "Replace interface{} with any",
					CanQuickFix:  anyIsPredeclared,
				})
			}

		case *ast.ForStmt:
			if m, ok := matchModernRangeIntLoop(fset, node); ok {
				pos := fset.Position(node.Pos())
				findings = append(findings, ModernizeFinding{
					Kind:         "MODERN_RANGE_INT",
					Severity:     "info",
					Title:        "Use a range-over-int loop: for " + m.loopVar + " := range " + m.boundExpr,
					Message:      fmt.Sprintf("Classic 3-clause loop from 0 to %s without mutating %s can use Go 1.22+ range-over-int syntax.", m.boundExpr, m.loopVar),
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   m.loopVar,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: "Rewrite loop header to 'for " + m.loopVar + " := range " + m.boundExpr + "'",
					CanQuickFix:  true,
				})
			}

		case *ast.IfStmt:
			if m, ok := matchModernMinMaxIf(fset, node); ok {
				pos := fset.Position(node.Pos())
				findings = append(findings, ModernizeFinding{
					Kind:         "MODERN_MIN_MAX",
					Severity:     "info",
					Title:        "Use the built-in min or max",
					Message:      fmt.Sprintf("Conditional comparison between %s and %s can be simplified using the Go 1.21+ %s() builtin.", m.lhsExpr, m.rhsExpr, m.builtinName),
					File:         filePath,
					Line:         pos.Line,
					Col:          pos.Column,
					FunctionName: fnName,
					TargetName:   m.targetName,
					Snippet:      lineAt(pos.Line),
					SuggestedFix: m.suggestedFix,
					CanQuickFix:  false,
				})
			}
		}

		return true
	})

	return findings
}

func fileDeclaresIdent(file *ast.File, name string) bool {
	declared := false
	ast.Inspect(file, func(n ast.Node) bool {
		if ident, ok := n.(*ast.Ident); ok && ident.Name == name && ident.Obj != nil {
			declared = true
		}
		return !declared
	})
	return declared
}

func isEmptyInterfaceType(iface *ast.InterfaceType) bool {
	if iface == nil {
		return false
	}
	return iface.Methods == nil || len(iface.Methods.List) == 0
}

type rangeIntMatchInfo struct {
	forStmt   *ast.ForStmt
	loopVar   string
	boundExpr string
}

func matchModernRangeIntLoop(fset *token.FileSet, forStmt *ast.ForStmt) (rangeIntMatchInfo, bool) {
	if forStmt == nil || forStmt.Init == nil || forStmt.Cond == nil || forStmt.Post == nil || forStmt.Body == nil {
		return rangeIntMatchInfo{}, false
	}

	initAssign, ok := forStmt.Init.(*ast.AssignStmt)
	if !ok || initAssign.Tok != token.DEFINE || len(initAssign.Lhs) != 1 || len(initAssign.Rhs) != 1 {
		return rangeIntMatchInfo{}, false
	}
	loopVarIdent, ok := initAssign.Lhs[0].(*ast.Ident)
	if !ok || loopVarIdent.Name == "" {
		return rangeIntMatchInfo{}, false
	}
	initLit, ok := initAssign.Rhs[0].(*ast.BasicLit)
	if !ok || initLit.Kind != token.INT || initLit.Value != "0" {
		return rangeIntMatchInfo{}, false
	}

	condBin, ok := forStmt.Cond.(*ast.BinaryExpr)
	if !ok || condBin.Op != token.LSS {
		return rangeIntMatchInfo{}, false
	}
	condVarIdent, ok := condBin.X.(*ast.Ident)
	if !ok || condVarIdent.Name != loopVarIdent.Name {
		return rangeIntMatchInfo{}, false
	}

	postInc, ok := forStmt.Post.(*ast.IncDecStmt)
	if !ok || postInc.Tok != token.INC {
		return rangeIntMatchInfo{}, false
	}
	postVarIdent, ok := postInc.X.(*ast.Ident)
	if !ok || postVarIdent.Name != loopVarIdent.Name {
		return rangeIntMatchInfo{}, false
	}

	if isLoopVarMutatedInBody(forStmt.Body, loopVarIdent.Name) {
		return rangeIntMatchInfo{}, false
	}
	if isBoundExprUnsafeForRangeInt(forStmt.Body, condBin.Y) {
		return rangeIntMatchInfo{}, false
	}

	boundStr := strings.TrimSpace(exprToString(fset, condBin.Y))
	if boundStr == "" {
		return rangeIntMatchInfo{}, false
	}

	return rangeIntMatchInfo{
		forStmt:   forStmt,
		loopVar:   loopVarIdent.Name,
		boundExpr: boundStr,
	}, true
}

func isBoundExprUnsafeForRangeInt(body *ast.BlockStmt, boundExpr ast.Expr) bool {
	if boundExpr == nil {
		return true
	}
	unsafe := false
	ast.Inspect(boundExpr, func(n ast.Node) bool {
		if unsafe || n == nil {
			return false
		}
		switch expr := n.(type) {
		case *ast.CallExpr:
			funIdent, ok := expr.Fun.(*ast.Ident)
			if !ok || (funIdent.Name != "len" && funIdent.Name != "cap") {
				unsafe = true
				return false
			}
		case *ast.Ident:
			if expr.Name == "len" || expr.Name == "cap" || expr.Name == "_" {
				return true
			}
			if isLoopVarMutatedInBody(body, expr.Name) {
				unsafe = true
				return false
			}
		}
		return true
	})
	return unsafe
}

func isLoopVarMutatedInBody(body *ast.BlockStmt, varName string) bool {
	if body == nil || varName == "" || varName == "_" {
		return false
	}
	mutated := false
	ast.Inspect(body, func(n ast.Node) bool {
		if mutated || n == nil {
			return false
		}
		switch stmt := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range stmt.Lhs {
				if id, ok := lhs.(*ast.Ident); ok && id.Name == varName {
					mutated = true
					return false
				}
				if sel, ok := lhs.(*ast.SelectorExpr); ok {
					if xId, ok := sel.X.(*ast.Ident); ok && xId.Name == varName {
						mutated = true
						return false
					}
				}
			}
		case *ast.IncDecStmt:
			if id, ok := stmt.X.(*ast.Ident); ok && id.Name == varName {
				mutated = true
				return false
			}
		case *ast.UnaryExpr:
			if stmt.Op == token.AND {
				if id, ok := stmt.X.(*ast.Ident); ok && id.Name == varName {
					mutated = true
					return false
				}
			}
		}
		return true
	})
	return mutated
}

type minMaxMatchInfo struct {
	ifStmt       *ast.IfStmt
	lhsExpr      string
	rhsExpr      string
	targetName   string
	builtinName  string
	suggestedFix string
}

func matchModernMinMaxIf(fset *token.FileSet, ifStmt *ast.IfStmt) (minMaxMatchInfo, bool) {
	if ifStmt == nil || ifStmt.Init != nil || ifStmt.Body == nil || len(ifStmt.Body.List) != 1 {
		return minMaxMatchInfo{}, false
	}

	condBin, ok := ifStmt.Cond.(*ast.BinaryExpr)
	if !ok {
		return minMaxMatchInfo{}, false
	}
	switch condBin.Op {
	case token.LSS, token.LEQ, token.GTR, token.GEQ:
	default:
		return minMaxMatchInfo{}, false
	}

	lhs := strings.TrimSpace(exprToString(fset, condBin.X))
	rhs := strings.TrimSpace(exprToString(fset, condBin.Y))
	if lhs == "" || rhs == "" || lhs == "nil" || rhs == "nil" || lhs == rhs {
		return minMaxMatchInfo{}, false
	}

	isLess := condBin.Op == token.LSS || condBin.Op == token.LEQ

	switch bodyStmt := ifStmt.Body.List[0].(type) {
	case *ast.ReturnStmt:
		if len(bodyStmt.Results) != 1 {
			return minMaxMatchInfo{}, false
		}
		retStr := strings.TrimSpace(exprToString(fset, bodyStmt.Results[0]))
		if retStr != lhs && retStr != rhs {
			return minMaxMatchInfo{}, false
		}
		if ifStmt.Else != nil {
			elseBlock, ok := ifStmt.Else.(*ast.BlockStmt)
			if !ok || len(elseBlock.List) != 1 {
				return minMaxMatchInfo{}, false
			}
			elseRet, ok := elseBlock.List[0].(*ast.ReturnStmt)
			if !ok || len(elseRet.Results) != 1 {
				return minMaxMatchInfo{}, false
			}
			elseRetStr := strings.TrimSpace(exprToString(fset, elseRet.Results[0]))
			if (retStr == lhs && elseRetStr != rhs) || (retStr == rhs && elseRetStr != lhs) {
				return minMaxMatchInfo{}, false
			}
		}

		builtin := "min"
		if (isLess && retStr == rhs) || (!isLess && retStr == lhs) {
			builtin = "max"
		}
		return minMaxMatchInfo{
			ifStmt:       ifStmt,
			lhsExpr:      lhs,
			rhsExpr:      rhs,
			targetName:   lhs,
			builtinName:  builtin,
			suggestedFix: fmt.Sprintf("return %s(%s, %s)", builtin, lhs, rhs),
		}, true

	case *ast.AssignStmt:
		if bodyStmt.Tok != token.ASSIGN || len(bodyStmt.Lhs) != 1 || len(bodyStmt.Rhs) != 1 {
			return minMaxMatchInfo{}, false
		}
		assignLhs := strings.TrimSpace(exprToString(fset, bodyStmt.Lhs[0]))
		assignRhs := strings.TrimSpace(exprToString(fset, bodyStmt.Rhs[0]))
		if assignLhs == "" || assignRhs == "" {
			return minMaxMatchInfo{}, false
		}

		if ifStmt.Else == nil {
			if assignLhs == lhs && assignRhs == rhs {
				builtin := "max"
				if !isLess {
					builtin = "min"
				}
				return minMaxMatchInfo{
					ifStmt:       ifStmt,
					lhsExpr:      lhs,
					rhsExpr:      rhs,
					targetName:   assignLhs,
					builtinName:  builtin,
					suggestedFix: fmt.Sprintf("%s = %s(%s, %s)", assignLhs, builtin, lhs, rhs),
				}, true
			}
			if assignLhs == rhs && assignRhs == lhs {
				builtin := "min"
				if !isLess {
					builtin = "max"
				}
				return minMaxMatchInfo{
					ifStmt:       ifStmt,
					lhsExpr:      lhs,
					rhsExpr:      rhs,
					targetName:   assignLhs,
					builtinName:  builtin,
					suggestedFix: fmt.Sprintf("%s = %s(%s, %s)", assignLhs, builtin, lhs, rhs),
				}, true
			}
		} else if elseBlock, ok := ifStmt.Else.(*ast.BlockStmt); ok && len(elseBlock.List) == 1 {
			if elseAssign, ok := elseBlock.List[0].(*ast.AssignStmt); ok && elseAssign.Tok == token.ASSIGN && len(elseAssign.Lhs) == 1 && len(elseAssign.Rhs) == 1 {
				elseLhs := strings.TrimSpace(exprToString(fset, elseAssign.Lhs[0]))
				elseRhs := strings.TrimSpace(exprToString(fset, elseAssign.Rhs[0]))
				if elseLhs == assignLhs && ((assignRhs == lhs && elseRhs == rhs) || (assignRhs == rhs && elseRhs == lhs)) {
					builtin := "min"
					if (isLess && assignRhs == rhs) || (!isLess && assignRhs == lhs) {
						builtin = "max"
					}
					return minMaxMatchInfo{
						ifStmt:       ifStmt,
						lhsExpr:      lhs,
						rhsExpr:      rhs,
						targetName:   assignLhs,
						builtinName:  builtin,
						suggestedFix: fmt.Sprintf("%s = %s(%s, %s)", assignLhs, builtin, lhs, rhs),
					}, true
				}
			}
		}
	}

	return minMaxMatchInfo{}, false
}

func FixGoModernizationIssue(filePath, content string, line int, kind, targetName string) (string, error) {
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

	trimmedTarget := strings.TrimSpace(targetName)

	switch kind {
	case "MODERN_ANY":
		if fileDeclaresIdent(astFile, "any") {
			return content, fmt.Errorf("the file declares its own any, so interface{} cannot be replaced")
		}
		return applyModernizeAnyFix(fset, astFile, content, line)
	case "MODERN_RANGE_INT":
		return applyModernizeRangeIntFix(fset, astFile, content, line, trimmedTarget)
	case "MODERN_MIN_MAX":
		return applyModernizeMinMaxFix(fset, astFile, content, line, trimmedTarget)
	default:
		return content, fmt.Errorf("unsupported modernization fix kind %q", kind)
	}
}

func applyModernizeAnyFix(
	fset *token.FileSet,
	file *ast.File,
	content string,
	line int,
) (string, error) {
	type ifaceCandidate struct {
		node     *ast.InterfaceType
		line     int
		startOff int
		endOff   int
	}

	var all []ifaceCandidate
	ast.Inspect(file, func(n ast.Node) bool {
		iface, ok := n.(*ast.InterfaceType)
		if !ok || !isEmptyInterfaceType(iface) {
			return true
		}
		pos := fset.Position(iface.Pos())
		startOff := pos.Offset
		endOff := fset.Position(iface.End()).Offset
		if startOff >= 0 && endOff > startOff && endOff <= len(content) {
			all = append(all, ifaceCandidate{
				node:     iface,
				line:     pos.Line,
				startOff: startOff,
				endOff:   endOff,
			})
		}
		return true
	})

	if len(all) == 0 {
		return formatGoSourceOrFallback(content), nil
	}

	var sameLine []ifaceCandidate
	for _, c := range all {
		if c.line == line {
			sameLine = append(sameLine, c)
		}
	}

	if len(sameLine) == 0 {
		lines := strings.Split(content, "\n")
		if line >= 1 && line <= len(lines) && strings.Contains(lines[line-1], "any") && !strings.Contains(lines[line-1], "interface{}") {
			return formatGoSourceOrFallback(content), nil
		}
		bestDist := 1000000
		var nearest *ifaceCandidate
		for i := range all {
			dist := absInt(all[i].line - line)
			if dist < bestDist && dist <= 5 {
				bestDist = dist
				nearest = &all[i]
			}
		}
		if nearest != nil {
			sameLine = append(sameLine, *nearest)
		}
	}

	if len(sameLine) == 0 {
		return formatGoSourceOrFallback(content), nil
	}

	sort.Slice(sameLine, func(i, j int) bool {
		return sameLine[i].startOff > sameLine[j].startOff
	})

	updated := content
	for _, c := range sameLine {
		if c.startOff >= 0 && c.endOff > c.startOff && c.endOff <= len(updated) {
			updated = updated[:c.startOff] + "any" + updated[c.endOff:]
		}
	}

	return formatGoSourceOrFallback(updated), nil
}

func applyModernizeRangeIntFix(
	fset *token.FileSet,
	file *ast.File,
	content string,
	line int,
	targetName string,
) (string, error) {
	type rangeCandidate struct {
		match rangeIntMatchInfo
		line  int
	}

	var all []rangeCandidate
	ast.Inspect(file, func(n ast.Node) bool {
		forStmt, ok := n.(*ast.ForStmt)
		if !ok {
			return true
		}
		if m, ok := matchModernRangeIntLoop(fset, forStmt); ok {
			posLine := fset.Position(forStmt.Pos()).Line
			all = append(all, rangeCandidate{
				match: m,
				line:  posLine,
			})
		}
		return true
	})

	if len(all) == 0 {
		return formatGoSourceOrFallback(content), nil
	}

	var chosen *rangeCandidate
	for i := range all {
		if all[i].line == line && (targetName == "" || all[i].match.loopVar == targetName) {
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
	if chosen == nil {
		lines := strings.Split(content, "\n")
		if line >= 1 && line <= len(lines) && strings.Contains(lines[line-1], "range ") {
			return formatGoSourceOrFallback(content), nil
		}
		bestDist := 1000000
		for i := range all {
			if targetName == "" || all[i].match.loopVar == targetName {
				dist := absInt(all[i].line - line)
				if dist < bestDist && dist <= 5 {
					bestDist = dist
					chosen = &all[i]
				}
			}
		}
	}

	if chosen == nil {
		return formatGoSourceOrFallback(content), nil
	}

	startOff := fset.Position(chosen.match.forStmt.Pos()).Offset
	lbraceOff := fset.Position(chosen.match.forStmt.Body.Lbrace).Offset
	if startOff < 0 || lbraceOff <= startOff || lbraceOff > len(content) {
		return content, fmt.Errorf("invalid source span for range-int loop on line %d", line)
	}

	var header string
	if chosen.match.loopVar == "_" {
		header = fmt.Sprintf("for range %s ", chosen.match.boundExpr)
	} else {
		header = fmt.Sprintf("for %s := range %s ", chosen.match.loopVar, chosen.match.boundExpr)
	}

	updated := content[:startOff] + header + content[lbraceOff:]
	return formatGoSourceOrFallback(updated), nil
}

func applyModernizeMinMaxFix(
	fset *token.FileSet,
	file *ast.File,
	content string,
	line int,
	targetName string,
) (string, error) {
	var matched *minMaxMatchInfo
	ast.Inspect(file, func(n ast.Node) bool {
		ifStmt, ok := n.(*ast.IfStmt)
		if !ok {
			return true
		}
		if fset.Position(ifStmt.Pos()).Line != line {
			return true
		}
		if m, ok := matchModernMinMaxIf(fset, ifStmt); ok {
			if targetName == "" || m.targetName == targetName {
				matched = &m
				return false
			}
		}
		return true
	})

	if matched == nil {
		return formatGoSourceOrFallback(content), nil
	}

	if _, isAssign := matched.ifStmt.Body.List[0].(*ast.AssignStmt); isAssign {
		startOff := fset.Position(matched.ifStmt.Pos()).Offset
		endOff := fset.Position(matched.ifStmt.End()).Offset
		if startOff >= 0 && endOff > startOff && endOff <= len(content) {
			updated := content[:startOff] + matched.suggestedFix + content[endOff:]
			return formatGoSourceOrFallback(updated), nil
		}
	}

	return formatGoSourceOrFallback(content), nil
}
