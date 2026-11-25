package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"
)

func TestLoopSummaries_MatchPerDeclarationWalks(t *testing.T) {
	var fixtures []string
	for _, f := range []string{"prealloc_inspector_test.go"} {
		fixtures = append(fixtures, harvestGoFixtures(t, f)...)
	}
	fixtures = append(fixtures, `package p

func f(items []int, n int) {
	var a []int
	var m map[string]int
	var b []int
	for _, it := range items {
		a = append(a, it)
		m["k"] = it
		m["x"]++
		b = append(a, it)
		func() { b = append(b, it) }()
	}
	for i := 0; i < n; i++ {
		b, m = append(b, i), nil
		_ = &a
		m[string(rune(i))], b = 1, nil
	}
}
`)
	checked := 0
	for fi, src := range fixtures {
		fset := token.NewFileSet()
		file, _ := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
		if file == nil {
			continue
		}
		names := map[string]bool{}
		ast.Inspect(file, func(n ast.Node) bool {
			if ident, ok := n.(*ast.Ident); ok {
				names[ident.Name] = true
			}
			return true
		})
		ast.Inspect(file, func(n ast.Node) bool {
			stmt, ok := n.(ast.Stmt)
			if !ok {
				return true
			}
			loop := summarizePreallocLoop(fset, stmt)
			body, sourceLen, isLoop := extractPreallocLoopInfo(fset, stmt)
			for name := range names {
				checked++
				if isLoop && sourceLen != "" {
					if referenceLoopBodyContainsSliceAppend(body, name) != loop.appendTargets[name] {
						t.Fatalf("fixture %d: append target %q differs", fi, name)
					}
					if referenceLoopBodyContainsMapAssign(body, name) != loop.mapAssignTargets[name] {
						t.Fatalf("fixture %d: map assign target %q differs", fi, name)
					}
				}
			}
			return true
		})
	}
	if checked < 1000 {
		t.Fatalf("expected a broad sample, got %d", checked)
	}
}
