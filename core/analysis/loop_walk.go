package analysis

import "go/ast"

func inspectLoopBodiesOnce(root ast.Node, visit func(n ast.Node)) {
	if root == nil {
		return
	}
	loopBodies := make(map[*ast.BlockStmt]bool)
	var enteredBody []bool
	depth := 0
	ast.Inspect(root, func(n ast.Node) bool {
		if n == nil {
			if len(enteredBody) > 0 {
				if enteredBody[len(enteredBody)-1] {
					depth--
				}
				enteredBody = enteredBody[:len(enteredBody)-1]
			}
			return false
		}
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		switch loop := n.(type) {
		case *ast.ForStmt:
			if loop.Body != nil {
				loopBodies[loop.Body] = true
			}
		case *ast.RangeStmt:
			if loop.Body != nil {
				loopBodies[loop.Body] = true
			}
		}
		block, isBlock := n.(*ast.BlockStmt)
		entering := isBlock && loopBodies[block]
		if entering {
			depth++
		}
		enteredBody = append(enteredBody, entering)
		if depth > 0 {
			visit(n)
		}
		return true
	})
}
