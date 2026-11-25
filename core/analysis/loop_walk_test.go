package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"
)

func nestedLoopWalkOrder(root ast.Node) []ast.Node {
	seen := make(map[ast.Node]bool)
	var order []ast.Node
	ast.Inspect(root, func(n ast.Node) bool {
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		var body *ast.BlockStmt
		switch loop := n.(type) {
		case *ast.ForStmt:
			body = loop.Body
		case *ast.RangeStmt:
			body = loop.Body
		}
		if body == nil {
			return true
		}
		ast.Inspect(body, func(inner ast.Node) bool {
			if inner == nil {
				return false
			}
			if _, isNestedLit := inner.(*ast.FuncLit); isNestedLit {
				return false
			}
			if !seen[inner] {
				seen[inner] = true
				order = append(order, inner)
			}
			return true
		})
		return true
	})
	return order
}

func TestInspectLoopBodiesOnce_MatchesNestedLoopWalks(t *testing.T) {
	fixtures := append(harvestGoFixtures(t, "time_inspector_test.go"), harvestGoFixtures(t, "sync_inspector_test.go")...)
	fixtures = append(fixtures, `package p

import "time"

func f(xs [][]int, ch chan int) {
	for i := 0; i < len(xs); i++ {
		for _, row := range xs[i] {
			select {
			case <-time.After(time.Second):
			case <-ch:
			}
			go func() {
				for range xs {
					<-time.After(time.Millisecond)
				}
			}()
			_ = row
		}
		<-time.After(2 * time.Second)
	}
	for {
		break
	}
	<-time.After(time.Second)
}
`)
	visited := 0
	for fi, src := range fixtures {
		fset := token.NewFileSet()
		file, _ := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
		if file == nil {
			continue
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			want := nestedLoopWalkOrder(fn.Body)
			var got []ast.Node
			inspectLoopBodiesOnce(fn.Body, func(n ast.Node) { got = append(got, n) })
			if len(got) != len(want) {
				t.Fatalf("fixture %d %s: visited %d nodes, nested walks reached %d", fi, fn.Name.Name, len(got), len(want))
			}
			for i := range got {
				if got[i] != want[i] {
					t.Fatalf("fixture %d %s: visit order differs at %d", fi, fn.Name.Name, i)
				}
			}
			visited += len(got)
		}
	}
	if visited < 50 {
		t.Fatalf("expected a broad sample, visited %d nodes", visited)
	}
}
