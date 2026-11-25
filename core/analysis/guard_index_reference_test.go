package analysis

import (
	"go/ast"
	"go/token"
)

func referenceHasBoundsGuardBeforePos(root ast.Node, varName string, targetPos token.Pos) bool {
	if root == nil || varName == "" {
		return false
	}
	guarded := false
	ast.Inspect(root, func(n ast.Node) bool {
		if guarded || n == nil {
			return false
		}
		if n.Pos() >= targetPos {
			return false
		}
		ifStmt, ok := n.(*ast.IfStmt)
		if !ok || ifStmt.Cond == nil {
			return true
		}
		ast.Inspect(ifStmt.Cond, func(cn ast.Node) bool {
			if guarded || cn == nil {
				return false
			}
			bin, isBin := cn.(*ast.BinaryExpr)
			if !isBin {
				return true
			}
			switch bin.Op {
			case token.LSS, token.LEQ, token.GTR, token.GEQ:
				if exprReferencesIdent(bin.X, varName) || exprReferencesIdent(bin.Y, varName) {
					guarded = true
					return false
				}
			default:
			}
			return true
		})
		return !guarded
	})
	return guarded
}

func referenceHasZeroDivisorGuardBeforePos(root ast.Node, varName string, targetPos token.Pos) bool {
	if root == nil || varName == "" {
		return false
	}
	guarded := false

	ast.Inspect(root, func(n ast.Node) bool {
		if guarded || n == nil {
			return false
		}
		if n.Pos() >= targetPos {
			return false
		}

		switch node := n.(type) {
		case *ast.BinaryExpr:
			switch node.Op {
			case token.EQL, token.NEQ, token.LEQ, token.GTR, token.LSS, token.GEQ:
				if (numericIsIdentNamed(node.X, varName) && isZeroOrPositiveGuardBound(node.Y)) ||
					(numericIsIdentNamed(node.Y, varName) && isZeroOrPositiveGuardBound(node.X)) {
					guarded = true
					return false
				}
			default:
			}

		case *ast.AssignStmt:
			if len(node.Lhs) == 1 && len(node.Rhs) == 1 && numericIsIdentNamed(node.Lhs[0], varName) {
				if isMaxGuardCallForIdent(node.Rhs[0], varName) || isNonZeroNumericLiteralExpr(node.Rhs[0]) {
					guarded = true
					return false
				}
			}
		}

		return true
	})

	return guarded
}

func referenceHasNonNegativeBoundsGuardBeforePos(root ast.Node, varName string, targetPos token.Pos) bool {
	if root == nil || varName == "" {
		return false
	}
	guarded := false
	ast.Inspect(root, func(n ast.Node) bool {
		if guarded || n == nil {
			return false
		}
		if n.Pos() >= targetPos {
			return false
		}

		switch node := n.(type) {
		case *ast.BinaryExpr:
			switch node.Op {
			case token.GTR, token.GEQ, token.LSS, token.LEQ, token.EQL, token.NEQ:
				if (unsafeIdentMatches(node.X, varName) && isNonNegativeIntBound(node.Y)) ||
					(unsafeIdentMatches(node.Y, varName) && isNonNegativeIntBound(node.X)) {
					guarded = true
					return false
				}
			default:
			}
		case *ast.AssignStmt:
			if len(node.Lhs) == 1 && len(node.Rhs) == 1 && unsafeIdentMatches(node.Lhs[0], varName) {
				if isMaxZeroClampExprForVar(node.Rhs[0], varName) {
					guarded = true
					return false
				}
			}
		}
		return true
	})
	return guarded
}

func referenceIsCancelDeferredOrReturned(body *ast.BlockStmt, cancelName string) bool {
	if body == nil || cancelName == "" {
		return false
	}
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		if found {
			return false
		}
		switch stmt := n.(type) {
		case *ast.DeferStmt:
			ast.Inspect(stmt.Call, func(inner ast.Node) bool {
				if call, ok := inner.(*ast.CallExpr); ok {
					if ident, ok := call.Fun.(*ast.Ident); ok && ident.Name == cancelName {
						found = true
						return false
					}
				}
				return true
			})
		case *ast.ReturnStmt:
			for _, res := range stmt.Results {
				if ident, ok := res.(*ast.Ident); ok && ident.Name == cancelName {
					found = true
					return false
				}
			}
		}
		return true
	})
	return found
}
