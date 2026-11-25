package goast

import (
	"go/ast"
	"go/token"
)

const (
	errPrefixCannotInlineVar     = "cannot inline variable '"
	errInfixBecause              = "' because '"
	errSuffixModifiedBeforeUsage = "' is modified before usage"
)

func ApplyInlineVariable(req InlineVarReq) ExtractVarReply {
	src, fset, file, tf, errMsg := loadRefactorFile(req.Path, req.Src)
	if errMsg != "" {
		return ExtractVarReply{Error: errMsg}
	}

	offset := req.Offset
	if offset < 0 {
		offset = 0
	}
	if offset > len(src) {
		offset = len(src)
	}
	pos := tf.Pos(offset)
	cursorLine := fset.Position(pos).Line

	_, fnBody := findInnermostEnclosingFunc(fset, file, pos, cursorLine)
	if fnBody == nil {
		return ExtractVarReply{Error: "cursor is not inside a function body"}
	}

	skip := collectSkippedIdents(fnBody)
	var targetIdent *ast.Ident
	ast.Inspect(fnBody, func(n ast.Node) bool {
		id, ok := n.(*ast.Ident)
		if !ok || id == nil || skip[id] {
			return true
		}
		if pos >= id.Pos() && pos <= id.End() {
			targetIdent = id
			return false
		}
		return true
	})

	if targetIdent == nil {
		stmts := collectStmtsInFuncBody(fnBody)
		for _, item := range stmts {
			sLine := fset.Position(item.stmt.Pos()).Line
			eLine := fset.Position(item.stmt.End()).Line
			if cursorLine >= sLine && cursorLine <= eLine {
				if id, _ := extractSingleVarDecl(item.stmt); id != nil {
					targetIdent = id
					break
				}
			}
		}
	}

	if targetIdent == nil || targetIdent.Name == "" || targetIdent.Name == "_" {
		return ExtractVarReply{Error: "no variable identifier found at cursor"}
	}

	declBlock, declStmt, declIdent, rhsExpr := findInlineVarDeclaration(fnBody, targetIdent)
	if declStmt == nil || rhsExpr == nil || declBlock == nil {
		return ExtractVarReply{Error: "no inlineable local variable declaration found for '" + targetIdent.Name + "'"}
	}

	exprText := exprString(fset, src, rhsExpr)
	if exprText == "" {
		return ExtractVarReply{Error: "empty variable initializer"}
	}

	parentMap := map[ast.Node]ast.Node{}
	var stack []ast.Node
	ast.Inspect(declBlock, func(n ast.Node) bool {
		if n == nil {
			stack = stack[:len(stack)-1]
			return false
		}
		if len(stack) > 0 {
			parentMap[n] = stack[len(stack)-1]
		}
		stack = append(stack, n)
		return true
	})

	var uses []*ast.Ident
	reassigned := false
	ast.Inspect(declBlock, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if n.End() <= declStmt.End() {
			return true
		}
		switch s := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range s.Lhs {
				if rootIdentName(lhs) == declIdent.Name {
					reassigned = true
				}
			}
		case *ast.IncDecStmt:
			if rootIdentName(s.X) == declIdent.Name {
				reassigned = true
			}
		case *ast.RangeStmt:
			if rootIdentName(s.Key) == declIdent.Name || rootIdentName(s.Value) == declIdent.Name {
				reassigned = true
			}
		case *ast.UnaryExpr:
			if s.Op == token.AND && rootIdentName(s.X) == declIdent.Name {
				reassigned = true
			}
		case *ast.Ident:
			if !skip[s] && s.Name == declIdent.Name && s.Pos() > declStmt.End() {
				uses = append(uses, s)
			}
		}
		return true
	})

	if reassigned {
		return ExtractVarReply{Error: errPrefixCannotInlineVar + declIdent.Name + "' because it is reassigned"}
	}
	if len(uses) == 0 {
		return ExtractVarReply{Error: "variable '" + declIdent.Name + "' has no references to inline"}
	}
	if len(uses) != 1 && exprHasPotentialSideEffects(rhsExpr) {
		return ExtractVarReply{Error: "cannot inline variable initialized with a function call or side-effecting expression into multiple usages"}
	}
	if unsafeReason := checkInlineOrderAndMutationSafety(declBlock, declStmt, declIdent, rhsExpr, uses, skip); unsafeReason != "" {
		return ExtractVarReply{Error: unsafeReason}
	}

	_, isCompositeWait := rhsExpr.(*ast.BinaryExpr)
	_, isUnary := rhsExpr.(*ast.UnaryExpr)
	needsParensWhenNested := isCompositeWait || isUnary

	var edits []TextEdit
	declLineStart, declLineEnd := fullLineByteSpan(fset, src, declStmt.Pos(), declStmt.End())
	edits = append(edits, TextEdit{
		Range:   lspRange(fset, src, tf.Pos(declLineStart), tf.Pos(declLineEnd)),
		NewText: "",
	})

	for _, u := range uses {
		repl := exprText
		if needsParensWhenNested && parentRequiresParens(parentMap[u], u) {
			repl = "(" + exprText + ")"
		}
		edits = append(edits, TextEdit{
			Range:   lspRange(fset, src, u.Pos(), u.End()),
			NewText: repl,
		})
	}

	return ExtractVarReply{
		VarName: declIdent.Name,
		EditsByPath: map[string][]TextEdit{
			req.Path: edits,
		},
	}
}

func isPureBuiltinOrConversion(fun ast.Expr) bool {
	id, ok := fun.(*ast.Ident)
	if !ok || id == nil {
		return false
	}
	switch id.Name {
	case "len", "cap", "real", "imag", "complex", "min", "max",
		"int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "float32", "float64", "complex64", "complex128",
		"bool", "string":
		return true
	}
	return false
}

func exprHasPotentialSideEffects(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	hasSideEffect := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if hasSideEffect || n == nil {
			return false
		}
		switch x := n.(type) {
		case *ast.CallExpr:
			if !isPureBuiltinOrConversion(x.Fun) {
				hasSideEffect = true
				return false
			}
		case *ast.UnaryExpr:
			if x.Op == token.ARROW {
				hasSideEffect = true
				return false
			}
			if x.Op == token.AND {
				if _, ok := x.X.(*ast.CompositeLit); ok {
					hasSideEffect = true
					return false
				}
			}
		}
		return true
	})
	return hasSideEffect
}

func rootIdentName(expr ast.Expr) string {
	for expr != nil {
		switch x := expr.(type) {
		case *ast.Ident:
			return x.Name
		case *ast.ParenExpr:
			expr = x.X
		case *ast.SelectorExpr:
			expr = x.X
		case *ast.IndexExpr:
			expr = x.X
		case *ast.SliceExpr:
			expr = x.X
		case *ast.StarExpr:
			expr = x.X
		default:
			return ""
		}
	}
	return ""
}

func exprIsOrderSensitive(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	sensitive := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if sensitive || n == nil {
			return false
		}
		switch x := n.(type) {
		case *ast.CallExpr, *ast.StarExpr, *ast.IndexExpr, *ast.SliceExpr, *ast.SelectorExpr:
			sensitive = true
			return false
		case *ast.UnaryExpr:
			if x.Op == token.ARROW {
				sensitive = true
				return false
			}
			if x.Op == token.AND {
				if _, ok := x.X.(*ast.CompositeLit); ok {
					sensitive = true
					return false
				}
			}
		}
		return true
	})
	return sensitive
}

func checkInlineOrderAndMutationSafety(
	declBlock *ast.BlockStmt,
	declStmt ast.Stmt,
	declIdent *ast.Ident,
	rhsExpr ast.Expr,
	uses []*ast.Ident,
	skip map[*ast.Ident]bool,
) string {
	if len(uses) == 0 {
		return ""
	}
	lastUse := uses[len(uses)-1]
	checkEndPos := lastUse.Pos()

	hasInterveningStmt := false
	useInsideLoopOrClosure := false

	ast.Inspect(declBlock, func(n ast.Node) bool {
		if n == nil || n == declBlock || n == declStmt {
			return true
		}
		if n.End() <= declStmt.End() {
			return false
		}
		switch x := n.(type) {
		case *ast.ForStmt:
			if x.Pos() > declStmt.End() {
				for _, u := range uses {
					if u.Pos() >= x.Pos() && u.End() <= x.End() {
						useInsideLoopOrClosure = true
						if x.End() > checkEndPos {
							checkEndPos = x.End()
						}
					}
				}
			}
		case *ast.RangeStmt:
			if x.Pos() > declStmt.End() {
				for _, u := range uses {
					if u.Pos() >= x.Pos() && u.End() <= x.End() {
						useInsideLoopOrClosure = true
						if x.End() > checkEndPos {
							checkEndPos = x.End()
						}
					}
				}
			}
		case *ast.FuncLit:
			if x.Pos() > declStmt.End() {
				for _, u := range uses {
					if u.Pos() >= x.Pos() && u.End() <= x.End() {
						useInsideLoopOrClosure = true
						if x.End() > checkEndPos {
							checkEndPos = x.End()
						}
					}
				}
			}
		}

		if stmt, ok := n.(ast.Stmt); ok {
			if _, isEmpty := stmt.(*ast.EmptyStmt); !isEmpty {
				if stmt.Pos() > declStmt.End() && stmt.End() <= lastUse.Pos() {
					hasInterveningStmt = true
				} else if stmt.Pos() > declStmt.End() && stmt.Pos() < lastUse.Pos() && lastUse.End() <= stmt.End() {
					switch stmt.(type) {
					case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt, *ast.TypeSwitchStmt, *ast.SelectStmt:
						hasInterveningStmt = true
					}
				}
			}
		}

		if call, ok := n.(*ast.CallExpr); ok {
			if call.Pos() > declStmt.End() && call.End() <= lastUse.Pos() && !isPureBuiltinOrConversion(call.Fun) {
				hasInterveningStmt = true
			}
		}
		if ue, ok := n.(*ast.UnaryExpr); ok && ue.Op == token.ARROW {
			if ue.Pos() > declStmt.End() && ue.End() <= lastUse.Pos() {
				hasInterveningStmt = true
			}
		}
		return true
	})

	if (hasInterveningStmt || useInsideLoopOrClosure) && exprIsOrderSensitive(rhsExpr) {
		return errPrefixCannotInlineVar + declIdent.Name + "' across intervening statements because its initializer may have side effects or depend on mutable state"
	}

	rhsIdents := map[string]bool{}
	ast.Inspect(rhsExpr, func(n ast.Node) bool {
		id, ok := n.(*ast.Ident)
		if !ok || id == nil || skip[id] {
			return true
		}
		if id.Name != "" && id.Name != "_" && !isPredeclaredIdent(id.Name) {
			rhsIdents[id.Name] = true
		}
		return true
	})

	if len(rhsIdents) == 0 {
		return ""
	}

	var mutatedReason string
	ast.Inspect(declBlock, func(n ast.Node) bool {
		if mutatedReason != "" || n == nil {
			return false
		}
		if n.End() <= declStmt.End() || n.Pos() >= checkEndPos {
			return true
		}
		switch s := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range s.Lhs {
				if name := rootIdentName(lhs); rhsIdents[name] {
					mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + name + errSuffixModifiedBeforeUsage
					return false
				}
			}
		case *ast.IncDecStmt:
			if name := rootIdentName(s.X); rhsIdents[name] {
				mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + name + errSuffixModifiedBeforeUsage
				return false
			}
		case *ast.RangeStmt:
			if name := rootIdentName(s.Key); rhsIdents[name] {
				mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + name + errSuffixModifiedBeforeUsage
				return false
			}
			if name := rootIdentName(s.Value); rhsIdents[name] {
				mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + name + errSuffixModifiedBeforeUsage
				return false
			}
		case *ast.DeclStmt:
			if gd, ok := s.Decl.(*ast.GenDecl); ok {
				for _, spec := range gd.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, id := range vs.Names {
							if id != nil && rhsIdents[id.Name] {
								mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + id.Name + "' is redeclared before usage"
								return false
							}
						}
					}
				}
			}
		case *ast.UnaryExpr:
			if s.Op == token.AND {
				if name := rootIdentName(s.X); rhsIdents[name] {
					mutatedReason = errPrefixCannotInlineVar + declIdent.Name + "' because address of '" + name + "' is taken before usage"
					return false
				}
			}
		case *ast.CallExpr:
			if id, ok := s.Fun.(*ast.Ident); ok && (id.Name == "delete" || id.Name == "clear" || id.Name == "copy") && len(s.Args) > 0 {
				if name := rootIdentName(s.Args[0]); rhsIdents[name] {
					mutatedReason = errPrefixCannotInlineVar + declIdent.Name + errInfixBecause + name + errSuffixModifiedBeforeUsage
					return false
				}
			}
		}
		return true
	})

	return mutatedReason
}

func extractSingleVarDecl(s ast.Stmt) (*ast.Ident, ast.Expr) {
	switch n := s.(type) {
	case *ast.AssignStmt:
		if n.Tok == token.DEFINE && len(n.Lhs) == 1 && len(n.Rhs) == 1 {
			if id, ok := n.Lhs[0].(*ast.Ident); ok && id != nil && id.Name != "_" {
				return id, n.Rhs[0]
			}
		}
	case *ast.DeclStmt:
		if gd, ok := n.Decl.(*ast.GenDecl); ok && gd.Tok == token.VAR && len(gd.Specs) == 1 {
			if vs, ok := gd.Specs[0].(*ast.ValueSpec); ok && len(vs.Names) == 1 && len(vs.Values) == 1 {
				if vs.Names[0] != nil && vs.Names[0].Name != "_" {
					return vs.Names[0], vs.Values[0]
				}
			}
		}
	}
	return nil, nil
}

func findInlineVarDeclaration(fnBody *ast.BlockStmt, targetIdent *ast.Ident) (*ast.BlockStmt, ast.Stmt, *ast.Ident, ast.Expr) {
	var bestBlock *ast.BlockStmt
	var bestStmt ast.Stmt
	var bestIdent *ast.Ident
	var bestRhs ast.Expr

	ast.Inspect(fnBody, func(n ast.Node) bool {
		block, ok := n.(*ast.BlockStmt)
		if !ok || block == nil {
			return true
		}
		if targetIdent.Pos() < block.Pos() || targetIdent.End() > block.End() {
			return false
		}
		for _, s := range block.List {
			if s.Pos() > targetIdent.Pos() {
				break
			}
			id, rhs := extractSingleVarDecl(s)
			if id != nil && id.Name == targetIdent.Name {
				bestBlock = block
				bestStmt = s
				bestIdent = id
				bestRhs = rhs
			}
		}
		return true
	})

	return bestBlock, bestStmt, bestIdent, bestRhs
}

func parentRequiresParens(parent ast.Node, child *ast.Ident) bool {
	if parent == nil {
		return false
	}
	switch p := parent.(type) {
	case *ast.BinaryExpr, *ast.UnaryExpr, *ast.StarExpr:
		return true
	case *ast.SelectorExpr:
		return p.X == child
	case *ast.IndexExpr:
		return p.X == child
	case *ast.SliceExpr:
		return p.X == child
	case *ast.CallExpr:
		return p.Fun == child
	}
	return false
}

func fullLineByteSpan(fset *token.FileSet, src []byte, startPos, endPos token.Pos) (int, int) {
	sp := fset.Position(startPos)
	lineStart := sp.Offset - (sp.Column - 1)
	if lineStart < 0 {
		lineStart = 0
	}
	ep := fset.Position(endPos)
	lineEnd := ep.Offset
	for lineEnd < len(src) && src[lineEnd] != '\n' {
		lineEnd++
	}
	if lineEnd < len(src) && src[lineEnd] == '\n' {
		lineEnd++
	}
	return lineStart, lineEnd
}
