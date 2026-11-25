package analysis

import (
	"fmt"
	"go/ast"
	"go/token"
	"strings"
)

func insertDeferredGuardAndCleanup(
	fset *token.FileSet,
	content string,
	scopeBody *ast.BlockStmt,
	ctx resourceAssignContext,
	assignEnd token.Pos,
	assignLine int,
	varName string,
	closeTarget string,
	errVar string,
	deferCall string,
	stripRedundantSyncClose bool,
	closeMethod string,
	callDesc string,
) (string, error) {
	if ctx.inLoop {
		return content, fmt.Errorf("cannot safely add defer %s inside a loop", deferCall)
	}
	if ctx.inIfInit || ctx.block == nil || ctx.idx < 0 || ctx.idx >= len(ctx.block.List) {
		return content, fmt.Errorf("cannot insert defer %s for scoped acquisition", deferCall)
	}

	assignStmt := ctx.block.List[ctx.idx]
	insertAfterLine := fset.Position(assignStmt.End()).Line

	sawGuard := false
	guardTerminates := false
	afterGuardIdx := ctx.idx + 1
	var elseBlockInsert *ast.BlockStmt

	for scanIdx := ctx.idx + 1; scanIdx < len(ctx.block.List); scanIdx++ {
		nextIf, ok := ctx.block.List[scanIdx].(*ast.IfStmt)
		if !ok {
			break
		}
		isErrCheck := isErrNotNilGuardCond(fset, nextIf.Cond, errVar) || isSQLTxErrorSelCheck(fset, nextIf.Cond, varName)
		isNilGuard := isResourceNilGuardExpr(fset, nextIf.Cond, varName, closeTarget)
		if !isErrCheck && !isNilGuard {
			break
		}
		if nextIf.Else != nil {
			if eb, ok := nextIf.Else.(*ast.BlockStmt); ok {
				elseBlockInsert = eb
				guardTerminates = ifBlockTerminatesExecution(fset, nextIf.Body)
				sawGuard = true
				afterGuardIdx = scanIdx + 1
				break
			}
			sawGuard = true
			guardTerminates = false
			ifEndLine := fset.Position(nextIf.End()).Line
			if ifEndLine >= insertAfterLine {
				insertAfterLine = ifEndLine
			}
			afterGuardIdx = scanIdx + 1
			break
		}
		sawGuard = true
		ifEndLine := fset.Position(nextIf.End()).Line
		if ifEndLine >= insertAfterLine {
			insertAfterLine = ifEndLine
		}
		if ifBlockTerminatesExecution(fset, nextIf.Body) {
			guardTerminates = true
		}
		afterGuardIdx = scanIdx + 1
	}

	lines := strings.Split(content, "\n")
	if elseBlockInsert != nil {
		openLine := fset.Position(elseBlockInsert.Lbrace).Line
		closeLine := fset.Position(elseBlockInsert.Rbrace).Line
		if openLine < 1 || openLine > len(lines) {
			return content, fmt.Errorf("target insertion line %d out of range", openLine)
		}
		indent := "\t"
		if len(elseBlockInsert.List) > 0 {
			firstLine := fset.Position(elseBlockInsert.List[0].Pos()).Line
			if firstLine >= 1 && firstLine <= len(lines) {
				raw := lines[firstLine-1]
				indent = raw[:len(raw)-len(strings.TrimLeft(raw, " \t"))]
			}
		} else if assignLine >= 1 && assignLine <= len(lines) {
			raw := lines[assignLine-1]
			indent = raw[:len(raw)-len(strings.TrimLeft(raw, " \t"))] + "\t"
		}
		if closeLine == openLine || (len(elseBlockInsert.List) > 0 && fset.Position(elseBlockInsert.List[0].Pos()).Line == openLine) {
			lbraceOffset := fset.Position(elseBlockInsert.Lbrace).Offset
			if lbraceOffset >= 0 && lbraceOffset < len(content) && content[lbraceOffset] == '{' {
				patched := content[:lbraceOffset+1] + "\n" + indent + "defer " + deferCall + "\n" + content[lbraceOffset+1:]
				return formatGoSourceOrFallback(patched), nil
			}
		}
		deferStmt := fmt.Sprintf("%sdefer %s", indent, deferCall)
		updatedLines := make([]string, 0, len(lines)+1)
		updatedLines = append(updatedLines, lines[:openLine]...)
		updatedLines = append(updatedLines, deferStmt)
		updatedLines = append(updatedLines, lines[openLine:]...)
		return formatGoSourceOrFallback(strings.Join(updatedLines, "\n")), nil
	}

	if insertAfterLine < 1 || insertAfterLine > len(lines) {
		return content, fmt.Errorf("target insertion line %d out of range", insertAfterLine)
	}

	if stripRedundantSyncClose && afterGuardIdx < len(ctx.block.List) {
		redundant := findRedundantTopLevelSyncCloses(fset, scopeBody, ctx, assignEnd, ctx.block.List[afterGuardIdx:], varName, closeTarget, closeMethod, callDesc)
		for i := len(redundant) - 1; i >= 0; i-- {
			r := redundant[i]
			if r[0] > insertAfterLine && r[1] <= len(lines) {
				lines = append(lines[:r[0]-1], lines[r[1]:]...)
			}
		}
	}

	assignLineIdx := assignLine - 1
	indent := "\t"
	if assignLineIdx >= 0 && assignLineIdx < len(lines) {
		rawLine := lines[assignLineIdx]
		trimmed := strings.TrimLeft(rawLine, " \t")
		indent = rawLine[:len(rawLine)-len(trimmed)]
	}

	var deferStmt string
	if sawGuard && !guardTerminates {
		if strings.Contains(closeTarget, ".") && varName != "" && closeTarget != varName {
			deferStmt = fmt.Sprintf("%sif %s != nil && %s != nil {\n%s\tdefer %s\n%s}", indent, varName, closeTarget, indent, deferCall, indent)
		} else {
			deferStmt = fmt.Sprintf("%sif %s != nil {\n%s\tdefer %s\n%s}", indent, closeTarget, indent, deferCall, indent)
		}
	} else {
		deferStmt = fmt.Sprintf("%sdefer %s", indent, deferCall)
	}

	updatedLines := make([]string, 0, len(lines)+1)
	updatedLines = append(updatedLines, lines[:insertAfterLine]...)
	updatedLines = append(updatedLines, deferStmt)
	updatedLines = append(updatedLines, lines[insertAfterLine:]...)

	return formatGoSourceOrFallback(strings.Join(updatedLines, "\n")), nil
}

func isBufferTrailerWriterDesc(callDesc string) bool {
	return callDesc == "multipart.NewWriter" || callDesc == "gzip.NewWriter" || callDesc == "zlib.NewWriter"
}

func extractWriterBufferTarget(fset *token.FileSet, assign *ast.AssignStmt) string {
	if assign == nil || len(assign.Rhs) != 1 {
		return ""
	}
	call, ok := unwrapSafetyParens(assign.Rhs[0]).(*ast.CallExpr)
	if !ok || len(call.Args) == 0 {
		return ""
	}
	arg := unwrapSafetyParens(call.Args[0])
	if u, ok := arg.(*ast.UnaryExpr); ok && u.Op == token.AND {
		arg = unwrapSafetyParens(u.X)
	}
	return strings.TrimSpace(resourceExprString(fset, arg))
}

func analyzeBufferTrailerWriter(fset *token.FileSet, scopeBody *ast.BlockStmt, acq resourceAcquisitionMatch) (bool, bool) {
	if !isBufferTrailerWriterDesc(acq.callDesc) || scopeBody == nil || acq.assignStmt == nil {
		return false, false
	}
	assignEnd := acq.assignStmt.End()
	bufTarget := extractWriterBufferTarget(fset, acq.assignStmt)
	var syncClosePos token.Pos
	bufRefAfterAssign := false
	bufRefAfterSyncClose := false

	ast.Inspect(scopeBody, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		if _, isDefer := n.(*ast.DeferStmt); isDefer {
			return false
		}
		if n.End() <= assignEnd {
			return false
		}
		if call, ok := n.(*ast.CallExpr); ok && n.Pos() > assignEnd {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == "Close" {
				recv := strings.TrimSpace(resourceExprString(fset, sel.X))
				if recv == acq.closeTarget || recv == acq.varName {
					if syncClosePos == token.NoPos || n.Pos() < syncClosePos {
						syncClosePos = n.Pos()
					}
				}
			}
		}
		if bufTarget != "" && n.Pos() > assignEnd {
			matchesBuf := false
			switch e := n.(type) {
			case *ast.Ident:
				matchesBuf = e.Name == bufTarget
			case *ast.SelectorExpr:
				matchesBuf = strings.TrimSpace(resourceExprString(fset, e)) == bufTarget
			}
			if matchesBuf {
				bufRefAfterAssign = true
				if syncClosePos != token.NoPos && n.Pos() > syncClosePos {
					bufRefAfterSyncClose = true
				}
			}
		}
		return true
	})

	if syncClosePos != token.NoPos && bufRefAfterSyncClose {
		return true, true
	}
	if syncClosePos != token.NoPos || bufRefAfterAssign {
		return false, true
	}
	return false, false
}

func hasPostAssignReassignmentOrAddr(fset *token.FileSet, scopeBody *ast.BlockStmt, assignEnd token.Pos, varName, closeTarget string) bool {
	if scopeBody == nil || (varName == "" && closeTarget == "") {
		return false
	}
	found := false
	matchesTargetLHS := func(expr ast.Expr) bool {
		e := unwrapSafetyParens(expr)
		if id, ok := e.(*ast.Ident); ok && varName != "" && id.Name == varName {
			return true
		}
		if closeTarget != "" && closeTarget != varName {
			if strings.TrimSpace(resourceExprString(fset, e)) == closeTarget {
				return true
			}
		}
		return false
	}
	ast.Inspect(scopeBody, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if n.Pos() <= assignEnd {
			if n.End() <= assignEnd {
				return false
			}
			return true
		}
		switch s := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range s.Lhs {
				if matchesTargetLHS(lhs) {
					found = true
					return false
				}
			}
		case *ast.ValueSpec:
			for _, name := range s.Names {
				if name != nil && varName != "" && name.Name == varName {
					found = true
					return false
				}
			}
		case *ast.UnaryExpr:
			if s.Op == token.AND && matchesTargetLHS(s.X) {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

func isPureReturnStmt(stmt ast.Stmt) bool {
	ret, ok := stmt.(*ast.ReturnStmt)
	if !ok {
		return false
	}
	for _, res := range ret.Results {
		if !isPureReturnExpr(res) {
			return false
		}
	}
	return true
}

func isPureReturnExpr(expr ast.Expr) bool {
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isPureReturnExpr(e.X)
	case *ast.BasicLit, *ast.Ident:
		return true
	case *ast.UnaryExpr:
		return e.Op != token.ARROW && isPureReturnExpr(e.X)
	case *ast.BinaryExpr:
		return isPureReturnExpr(e.X) && isPureReturnExpr(e.Y)
	default:
		return false
	}
}

func outerStmtsEmpty(outerCont [][]ast.Stmt) bool {
	for _, seg := range outerCont {
		if len(seg) > 0 {
			return false
		}
	}
	return true
}

func findRedundantTopLevelSyncCloses(
	fset *token.FileSet,
	scopeBody *ast.BlockStmt,
	ctx resourceAssignContext,
	assignEnd token.Pos,
	stmts []ast.Stmt,
	varName, closeTarget, method, callDesc string,
) [][2]int {
	if len(stmts) == 0 || isBufferTrailerWriterDesc(callDesc) {
		return nil
	}
	if hasPostAssignReassignmentOrAddr(fset, scopeBody, assignEnd, varName, closeTarget) {
		return nil
	}
	candIdx := -1
	lastIdx := len(stmts) - 1
	if _, ok := stmts[lastIdx].(*ast.ReturnStmt); ok {
		if len(stmts) < 2 || !isPureReturnStmt(stmts[lastIdx]) {
			return nil
		}
		candIdx = lastIdx - 1
	} else {
		if scopeBody != nil && ctx.block != scopeBody && !outerStmtsEmpty(ctx.outerCont) {
			return nil
		}
		candIdx = lastIdx
	}
	stmt := stmts[candIdx]
	var call *ast.CallExpr
	switch s := stmt.(type) {
	case *ast.ExprStmt:
		call, _ = unwrapSafetyParens(s.X).(*ast.CallExpr)
	case *ast.AssignStmt:
		if len(s.Rhs) == 1 && allBlankIdents(s.Lhs) {
			call, _ = unwrapSafetyParens(s.Rhs[0]).(*ast.CallExpr)
		}
	}
	if call == nil {
		return nil
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != method {
		return nil
	}
	recv := strings.TrimSpace(resourceExprString(fset, sel.X))
	if recv != closeTarget {
		return nil
	}
	startLine := fset.Position(stmt.Pos()).Line
	endLine := fset.Position(stmt.End()).Line
	if startLine > 0 && endLine >= startLine {
		return [][2]int{{startLine, endLine}}
	}
	return nil
}

func allBlankIdents(lhs []ast.Expr) bool {
	if len(lhs) == 0 {
		return false
	}
	for _, expr := range lhs {
		id, ok := unwrapSafetyParens(expr).(*ast.Ident)
		if !ok || id.Name != "_" {
			return false
		}
	}
	return true
}
