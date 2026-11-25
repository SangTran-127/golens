package analysis

import (
	"go/ast"
	"go/token"
)

type guardPositions map[string]token.Pos

func (g guardPositions) record(name string, pos token.Pos) {
	if name == "" {
		return
	}
	if existing, ok := g[name]; !ok || pos < existing {
		g[name] = pos
	}
}

func (g guardPositions) before(name string, targetPos token.Pos) bool {
	if name == "" {
		return false
	}
	pos, ok := g[name]
	return ok && pos < targetPos
}

type guardIndexCache map[ast.Node]guardPositions

func (c guardIndexCache) get(root ast.Node, build func(ast.Node) guardPositions) guardPositions {
	if c == nil {
		return build(root)
	}
	if idx, ok := c[root]; ok {
		return idx
	}
	idx := build(root)
	c[root] = idx
	return idx
}

func inspectWithReachPos(root ast.Node, visit func(n ast.Node, reach token.Pos)) {
	stack := make([]token.Pos, 0, 32)
	ast.Inspect(root, func(n ast.Node) bool {
		if n == nil {
			stack = stack[:len(stack)-1]
			return false
		}
		reach := n.Pos()
		if len(stack) > 0 && stack[len(stack)-1] > reach {
			reach = stack[len(stack)-1]
		}
		stack = append(stack, reach)
		visit(n, reach)
		return true
	})
}

func collectIdentNames(expr ast.Expr, into map[string]bool) {
	if expr == nil {
		return
	}
	ast.Inspect(expr, func(n ast.Node) bool {
		if ident, ok := n.(*ast.Ident); ok {
			into[ident.Name] = true
		}
		return true
	})
}

func buildBoundsGuardIndex(root ast.Node) guardPositions {
	idx := guardPositions{}
	if root == nil {
		return idx
	}
	inspectWithReachPos(root, func(n ast.Node, reach token.Pos) {
		ifStmt, ok := n.(*ast.IfStmt)
		if !ok || ifStmt.Cond == nil {
			return
		}
		names := make(map[string]bool)
		ast.Inspect(ifStmt.Cond, func(cn ast.Node) bool {
			if bin, isBin := cn.(*ast.BinaryExpr); isBin {
				switch bin.Op {
				case token.LSS, token.LEQ, token.GTR, token.GEQ:
					collectIdentNames(bin.X, names)
					collectIdentNames(bin.Y, names)
				default:
				}
			}
			return true
		})
		for name := range names {
			idx.record(name, reach)
		}
	})
	return idx
}

func buildZeroDivisorGuardIndex(root ast.Node) guardPositions {
	idx := guardPositions{}
	if root == nil {
		return idx
	}
	inspectWithReachPos(root, func(n ast.Node, reach token.Pos) {
		switch node := n.(type) {
		case *ast.BinaryExpr:
			switch node.Op {
			case token.EQL, token.NEQ, token.LEQ, token.GTR, token.LSS, token.GEQ:
				if ident, ok := unwrapNumericParens(node.X).(*ast.Ident); ok && isZeroOrPositiveGuardBound(node.Y) {
					idx.record(ident.Name, reach)
				}
				if ident, ok := unwrapNumericParens(node.Y).(*ast.Ident); ok && isZeroOrPositiveGuardBound(node.X) {
					idx.record(ident.Name, reach)
				}
			default:
			}
		case *ast.AssignStmt:
			if len(node.Lhs) == 1 && len(node.Rhs) == 1 {
				if ident, ok := unwrapNumericParens(node.Lhs[0]).(*ast.Ident); ok {
					if isMaxGuardCallForIdent(node.Rhs[0], ident.Name) || isNonZeroNumericLiteralExpr(node.Rhs[0]) {
						idx.record(ident.Name, reach)
					}
				}
			}
		}
	})
	return idx
}

func unsafeMatchedIdentName(expr ast.Expr) string {
	switch e := unwrapUnsafeParens(expr).(type) {
	case *ast.Ident:
		return e.Name
	case *ast.SelectorExpr:
		if e.Sel != nil {
			return e.Sel.Name
		}
	}
	return ""
}

func buildNonNegativeBoundsGuardIndex(root ast.Node) guardPositions {
	idx := guardPositions{}
	if root == nil {
		return idx
	}
	inspectWithReachPos(root, func(n ast.Node, reach token.Pos) {
		switch node := n.(type) {
		case *ast.BinaryExpr:
			switch node.Op {
			case token.GTR, token.GEQ, token.LSS, token.LEQ, token.EQL, token.NEQ:
				if name := unsafeMatchedIdentName(node.X); name != "" && unsafeIdentMatches(node.X, name) && isNonNegativeIntBound(node.Y) {
					idx.record(name, reach)
				}
				if name := unsafeMatchedIdentName(node.Y); name != "" && unsafeIdentMatches(node.Y, name) && isNonNegativeIntBound(node.X) {
					idx.record(name, reach)
				}
			default:
			}
		case *ast.AssignStmt:
			if len(node.Lhs) == 1 && len(node.Rhs) == 1 {
				if name := unsafeMatchedIdentName(node.Lhs[0]); name != "" && unsafeIdentMatches(node.Lhs[0], name) && isMaxZeroClampExprForVar(node.Rhs[0], name) {
					idx.record(name, reach)
				}
			}
		}
	})
	return idx
}

func collectDeferredOrReturnedNames(body *ast.BlockStmt) map[string]bool {
	names := make(map[string]bool)
	if body == nil {
		return names
	}
	ast.Inspect(body, func(n ast.Node) bool {
		switch stmt := n.(type) {
		case *ast.DeferStmt:
			ast.Inspect(stmt.Call, func(inner ast.Node) bool {
				if call, ok := inner.(*ast.CallExpr); ok {
					if ident, ok := call.Fun.(*ast.Ident); ok {
						names[ident.Name] = true
					}
				}
				return true
			})
		case *ast.ReturnStmt:
			for _, res := range stmt.Results {
				if ident, ok := res.(*ast.Ident); ok {
					names[ident.Name] = true
				}
			}
		}
		return true
	})
	return names
}
