package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"
)

func TestGuardIndexes_MatchPerQueryWalks(t *testing.T) {
	var fixtures []string
	for _, f := range []string{"numeric_inspector_test.go", "unsafe_inspector_test.go", "concurrency_inspector_test.go"} {
		fixtures = append(fixtures, harvestGoFixtures(t, f)...)
	}
	fixtures = append(fixtures, `package p

import "unsafe"

func f(a, b int, s struct{ n int }, p *byte) int {
	if a > 0 && (b <= 10 || s.n < 3) {
		b = max(b, 1)
	}
	n := a
	n = max(n, 0)
	if (a) != 0 {
		_ = b / a
	}
	defer func() { cancel2() }()
	_ = unsafe.Slice(p, s.n)
	for i := 0; i < a; i++ {
		if i >= 0 {
			_ = a % i
		}
	}
	return a / b
}
`)

	queries := 0
	for fi, src := range fixtures {
		fset := token.NewFileSet()
		file, _ := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
		if file == nil {
			continue
		}
		names := map[string]bool{"": true}
		ast.Inspect(file, func(n ast.Node) bool {
			if ident, ok := n.(*ast.Ident); ok {
				names[ident.Name] = true
			}
			return true
		})
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			var targets []token.Pos
			ast.Inspect(fn, func(n ast.Node) bool {
				if n != nil {
					targets = append(targets, n.Pos(), n.End())
				}
				return true
			})
			roots := []ast.Node{fn, fn.Body}
			for name := range names {
				if got, want := name != "" && collectDeferredOrReturnedNames(fn.Body)[name], referenceIsCancelDeferredOrReturned(fn.Body, name); got != want {
					t.Fatalf("fixture %d %s: cancel %q got %v want %v", fi, fn.Name.Name, name, got, want)
				}
				for _, root := range roots {
					bounds := buildBoundsGuardIndex(root)
					zero := buildZeroDivisorGuardIndex(root)
					nonNeg := buildNonNegativeBoundsGuardIndex(root)
					for _, target := range targets {
						queries++
						if got, want := name != "" && bounds.before(name, target), referenceHasBoundsGuardBeforePos(root, name, target); got != want {
							t.Fatalf("fixture %d %s: bounds guard %q at %d got %v want %v", fi, fn.Name.Name, name, target, got, want)
						}
						if got, want := name != "" && zero.before(name, target), referenceHasZeroDivisorGuardBeforePos(root, name, target); got != want {
							t.Fatalf("fixture %d %s: zero guard %q at %d got %v want %v", fi, fn.Name.Name, name, target, got, want)
						}
						if got, want := name != "" && nonNeg.before(name, target), referenceHasNonNegativeBoundsGuardBeforePos(root, name, target); got != want {
							t.Fatalf("fixture %d %s: non-negative guard %q at %d got %v want %v", fi, fn.Name.Name, name, target, got, want)
						}
					}
				}
			}
		}
	}
	if queries < 1000 {
		t.Fatalf("expected a broad query sample, got %d", queries)
	}
}
