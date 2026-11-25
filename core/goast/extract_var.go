package goast

import (
	"fmt"
	"go/ast"
	"go/format"
	"go/token"
	"strings"
	"unicode"
)

func ApplyExtractVariable(req ExtractVarReq) ExtractVarReply {
	src, fset, file, tf, errMsg := loadRefactorFile(req.Path, req.Src)
	if errMsg != "" {
		return ExtractVarReply{Error: errMsg}
	}
	startByte, endByte := max(0, min(req.StartByte, len(src))), max(0, min(req.EndByte, len(src)))
	if startByte > endByte {
		startByte, endByte = endByte, startByte
	}
	trimStart, trimEnd := startByte, endByte
	for trimStart < trimEnd && strings.ContainsRune(" \t\r\n", rune(src[trimStart])) {
		trimStart++
	}
	for trimEnd > trimStart && strings.ContainsRune(" \t\r\n", rune(src[trimEnd-1])) {
		trimEnd--
	}
	cursorLine := fset.Position(tf.Pos(startByte)).Line
	targetExpr := findExtractableExpr(fset, file, tf.Pos(trimStart), tf.Pos(trimEnd), trimStart == trimEnd, cursorLine)
	if targetExpr == nil {
		return ExtractVarReply{Error: "no extractable expression found at selection"}
	}
	exprText := exprString(fset, src, targetExpr)
	if exprText == "" {
		return ExtractVarReply{Error: "empty expression"}
	}
	_, fnBody := findInnermostEnclosingFunc(fset, file, targetExpr.Pos(), fset.Position(targetExpr.Pos()).Line)
	if fnBody == nil || targetExpr.Pos() < fnBody.Lbrace || targetExpr.End() > fnBody.Rbrace {
		return ExtractVarReply{Error: "Select an expression inside a function body to extract a variable."}
	}
	enclosingStmt := findEnclosingBlockStmt(fnBody, targetExpr.Pos(), targetExpr.End())
	if enclosingStmt == nil {
		return ExtractVarReply{Error: "failed to locate enclosing statement"}
	}
	if es, ok := enclosingStmt.(*ast.ExprStmt); ok && es.X == targetExpr {
		return ExtractVarReply{Error: "The selection is a whole statement; select an expression inside it."}
	}
	varName := strings.TrimSpace(req.VarName)
	if varName == "" {
		varName = deriveSmartVarName(targetExpr, collectUsedIdents(fnBody))
	}
	stmtOff := fset.Position(enclosingStmt.Pos()).Offset
	exprStart := fset.Position(targetExpr.Pos()).Offset
	exprEnd := fset.Position(targetExpr.End()).Offset
	insertAt := stmtOff
	decl := "\n" + varName + " := " + exprText + "\n"
	if lineStart := stmtOff - (fset.Position(enclosingStmt.Pos()).Column - 1); lineStart >= 0 && strings.TrimSpace(string(src[lineStart:stmtOff])) == "" {
		insertAt = lineStart
		decl = varName + " := " + exprText + "\n"
	}
	edited := string(src[:insertAt]) + decl + string(src[insertAt:exprStart]) + varName + string(src[exprEnd:])
	formatted, err := format.Source([]byte(edited))
	if err != nil {
		return ExtractVarReply{Error: "Extract Variable would not produce valid Go here: " + err.Error()}
	}
	out, orig := string(formatted), string(src)
	p := 0
	for p < len(orig) && p < len(out) && orig[p] == out[p] {
		p++
	}
	for p > 0 && orig[p-1] != '\n' {
		p--
	}
	s := 0
	for s < len(orig)-p && s < len(out)-p && orig[len(orig)-1-s] == out[len(out)-1-s] {
		s++
	}
	for s > 0 && orig[len(orig)-s] != '\n' {
		s--
	}
	return ExtractVarReply{
		VarName: varName,
		EditsByPath: map[string][]TextEdit{
			req.Path: {{Range: lspRange(fset, src, tf.Pos(p), tf.Pos(len(orig)-s)), NewText: out[p : len(out)-s]}},
		},
	}
}

func findExtractableExpr(fset *token.FileSet, file *ast.File, startPos, endPos token.Pos, isCursor bool, cursorLine int) ast.Expr {
	callFuns := map[ast.Expr]bool{}
	typeExprs := map[ast.Expr]bool{}
	lhsAssigns := map[ast.Expr]bool{}

	ast.Inspect(file, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.CallExpr:
			if x.Fun != nil {
				callFuns[x.Fun] = true
			}
		case *ast.CompositeLit:
			if x.Type != nil {
				typeExprs[x.Type] = true
			}
		case *ast.ValueSpec:
			if x.Type != nil {
				typeExprs[x.Type] = true
			}
		case *ast.Field:
			if x.Type != nil {
				typeExprs[x.Type] = true
			}
		case *ast.AssignStmt:
			for _, lhs := range x.Lhs {
				lhsAssigns[lhs] = true
			}
		}
		return true
	})

	isAllowedExpr := func(e ast.Expr) bool {
		if e == nil || callFuns[e] || typeExprs[e] || lhsAssigns[e] {
			return false
		}
		switch e.(type) {
		case *ast.KeyValueExpr, *ast.ArrayType, *ast.MapType, *ast.StructType, *ast.InterfaceType, *ast.FuncType, *ast.ChanType, *ast.Ellipsis:
			return false
		}
		return true
	}

	if !isCursor {
		var exactMatch ast.Expr
		var bestContaining ast.Expr
		ast.Inspect(file, func(n ast.Node) bool {
			e, ok := n.(ast.Expr)
			if !ok || !isAllowedExpr(e) {
				return true
			}
			if e.Pos() == startPos && e.End() == endPos {
				exactMatch = e
				return true
			}
			if e.Pos() <= startPos && e.End() >= endPos {
				if bestContaining == nil || (e.End()-e.Pos()) <= (bestContaining.End()-bestContaining.Pos()) {
					bestContaining = e
				}
			}
			return true
		})
		if exactMatch != nil {
			return exactMatch
		}
		return bestContaining
	}

	isCursorCandidate := func(e ast.Expr) bool {
		if !isAllowedExpr(e) {
			return false
		}
		switch e.(type) {
		case *ast.CallExpr, *ast.BinaryExpr, *ast.CompositeLit, *ast.BasicLit, *ast.SelectorExpr, *ast.UnaryExpr, *ast.IndexExpr, *ast.SliceExpr:
			return true
		}
		return false
	}

	var bestAtPos ast.Expr
	var bestOnLine ast.Expr
	ast.Inspect(file, func(n ast.Node) bool {
		e, ok := n.(ast.Expr)
		if !ok || !isCursorCandidate(e) {
			return true
		}
		if startPos >= e.Pos() && startPos <= e.End() {
			if bestAtPos == nil || (e.End()-e.Pos()) <= (bestAtPos.End()-bestAtPos.Pos()) {
				bestAtPos = e
			}
		} else if fset.Position(e.Pos()).Line == cursorLine {
			if bestOnLine == nil || (e.End()-e.Pos()) < (bestOnLine.End()-bestOnLine.Pos()) {
				bestOnLine = e
			}
		}
		return true
	})

	if bestAtPos != nil {
		return bestAtPos
	}
	return bestOnLine
}

func findEnclosingBlockStmt(body *ast.BlockStmt, exprStart, exprEnd token.Pos) ast.Stmt {
	var best ast.Stmt
	var walkList func(list []ast.Stmt)
	var walkStmt func(s ast.Stmt)

	walkList = func(list []ast.Stmt) {
		for _, s := range list {
			if exprStart >= s.Pos() && exprEnd <= s.End() {
				best = s
				walkStmt(s)
			}
		}
	}

	walkStmt = func(s ast.Stmt) {
		switch n := s.(type) {
		case *ast.BlockStmt:
			walkList(n.List)
		case *ast.IfStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
			if n.Else != nil && exprStart >= n.Else.Pos() && exprEnd <= n.Else.End() {
				walkStmt(n.Else)
			}
		case *ast.ForStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
		case *ast.RangeStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
		case *ast.SwitchStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
		case *ast.TypeSwitchStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
		case *ast.SelectStmt:
			if n.Body != nil && exprStart >= n.Body.Pos() && exprEnd <= n.Body.End() {
				walkList(n.Body.List)
			}
		case *ast.CaseClause:
			walkList(n.Body)
		case *ast.CommClause:
			walkList(n.Body)
		case *ast.LabeledStmt:
			if n.Stmt != nil {
				walkStmt(n.Stmt)
			}
		}
	}

	walkList(body.List)
	return best
}

func collectUsedIdents(root ast.Node) map[string]bool {
	used := map[string]bool{}
	ast.Inspect(root, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok && id != nil && id.Name != "" {
			used[id.Name] = true
		}
		return true
	})
	return used
}

func deriveSmartVarName(expr ast.Expr, used map[string]bool) string {
	base := rawVarNameCandidate(expr)
	base = sanitizeLowerCamelIdent(base)
	if base == "" || isGoKeyword(base) || isPredeclaredIdent(base) {
		base = "extracted"
	}
	if !used[base] {
		return base
	}
	for i := 2; i < 100; i++ {
		cand := fmt.Sprintf("%s%d", base, i)
		if !used[cand] {
			return cand
		}
	}
	return "extractedVal"
}

func rawVarNameCandidate(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return rawVarNameCandidate(e.X)
	case *ast.CallExpr:
		if id := extractCalleeIdent(e.Fun); id != nil {
			name := id.Name
			for _, prefix := range []string{"get", "Get", "fetch", "Fetch", "compute", "Compute", "calculate", "Calculate", "build", "Build", "create", "Create", "new", "New", "parse", "Parse", "load", "Load", "read", "Read", "format", "Format"} {
				if strings.HasPrefix(name, prefix) && len(name) > len(prefix) {
					rem := name[len(prefix):]
					r := []rune(rem)
					if unicode.IsUpper(r[0]) {
						return rem
					}
				}
			}
			return name
		}
	case *ast.SelectorExpr:
		if e.Sel != nil {
			return e.Sel.Name
		}
	case *ast.CompositeLit:
		if b := baseTypeName(e.Type); b != "" {
			return b
		}
	case *ast.UnaryExpr:
		if cl, ok := e.X.(*ast.CompositeLit); ok {
			if b := baseTypeName(cl.Type); b != "" {
				return b
			}
		}
	case *ast.BasicLit:
		switch e.Kind {
		case token.STRING:
			return "str"
		case token.INT, token.FLOAT:
			return "val"
		case token.CHAR:
			return "ch"
		default:
		}
	}
	return "extracted"
}

func sanitizeLowerCamelIdent(raw string) string {
	var runes []rune
	for _, r := range raw {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
			runes = append(runes, r)
		}
	}
	if len(runes) == 0 {
		return ""
	}
	i := 0
	for i < len(runes) && unicode.IsUpper(runes[i]) {
		i++
	}
	if i == 1 {
		runes[0] = unicode.ToLower(runes[0])
	} else if i > 1 {
		limit := i - 1
		if i == len(runes) {
			limit = i
		}
		for j := 0; j < limit; j++ {
			runes[j] = unicode.ToLower(runes[j])
		}
	}
	if unicode.IsDigit(runes[0]) {
		return "v" + string(runes)
	}
	return string(runes)
}

func isGoKeyword(s string) bool {
	switch s {
	case "break", "default", "func", "interface", "select",
		"case", "defer", "go", "map", "struct",
		"chan", "else", "goto", "package", "switch",
		"const", "fallthrough", "if", "range", "type",
		"continue", "for", "import", "return", "var":
		return true
	}
	return false
}
