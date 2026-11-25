package analysis

import (
	"go/ast"
	"go/token"
)

func referenceLoopBodyContainsSliceAppend(body *ast.BlockStmt, varName string) bool {
	if body == nil || varName == "" {
		return false
	}
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		assign, ok := n.(*ast.AssignStmt)
		if !ok || assign.Tok != token.ASSIGN || len(assign.Lhs) != 1 || len(assign.Rhs) != 1 {
			return true
		}
		lhsIdent, ok := assign.Lhs[0].(*ast.Ident)
		if !ok || lhsIdent.Name != varName {
			return true
		}
		call, ok := assign.Rhs[0].(*ast.CallExpr)
		if !ok || len(call.Args) < 2 {
			return true
		}
		funIdent, ok := call.Fun.(*ast.Ident)
		if !ok || funIdent.Name != "append" {
			return true
		}
		firstArg, ok := call.Args[0].(*ast.Ident)
		if ok && firstArg.Name == varName {
			found = true
			return false
		}
		return true
	})
	return found
}

func referenceLoopBodyContainsMapAssign(body *ast.BlockStmt, varName string) bool {
	if body == nil || varName == "" {
		return false
	}
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		assign, ok := n.(*ast.AssignStmt)
		if !ok || assign.Tok != token.ASSIGN {
			return true
		}
		for _, lhs := range assign.Lhs {
			idxExpr, ok := lhs.(*ast.IndexExpr)
			if !ok {
				continue
			}
			if mapIdent, ok := idxExpr.X.(*ast.Ident); ok && mapIdent.Name == varName {
				found = true
				return false
			}
		}
		return true
	})
	return found
}
