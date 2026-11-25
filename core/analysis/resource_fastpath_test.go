package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"reflect"
	"testing"
)

func TestResourceFastPaths_MatchPrinterBasedChecks(t *testing.T) {
	var fixtures []string
	for _, f := range []string{"resource_inspector_test.go", "http_inspector_test.go"} {
		fixtures = append(fixtures, harvestGoFixtures(t, f)...)
	}
	fixtures = append(fixtures, `package p

import (
	"database/sql"
	"fmt"
	"net/http"
	"os"
	"os/exec"
)

func f(db *sql.DB, name string, c *http.Client, r *http.Request) error {
	file, err := os.Open(name)
	if err != nil {
		return err
	}
	resp, _ := c.Do(r)
	go func() {
		defer resp.Body.Close()
		g := func() { file.Close() }
		g()
	}()
	rows, _ := db.Query("SELECT " + name)
	defer (rows).Close()
	_ = exec.Command("sh", "-c", fmt.Sprintf("ls %s", name))
	_ = (exec).Command(name)
	tx, _ := db.Begin()
	defer tx.Rollback()
	return a.b.c.Close()
}
`)
	exprs, calls, bodies := 0, 0, 0
	for fi, src := range fixtures {
		fset := token.NewFileSet()
		file, _ := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
		if file == nil {
			continue
		}
		ast.Inspect(file, func(n ast.Node) bool {
			if e, ok := n.(ast.Expr); ok {
				exprs++
				if got, ok := identChainString(e); ok && got != exprToString(fset, e) {
					t.Fatalf("fixture %d: fast string %q differs from printer %q", fi, got, exprToString(fset, e))
				}
				if got, want := resourceExprString(fset, e), exprToString(fset, e); got != want {
					t.Fatalf("fixture %d: resource string %q differs from printer %q", fi, got, want)
				}
			}
			if call, ok := n.(*ast.CallExpr); ok {
				calls++
				d1, b1, m1 := classifyResourceCall(fset, call)
				d2, b2, m2 := referenceClassifyResourceCall(fset, call)
				if d1 != d2 || b1 != b2 || m1 != m2 {
					t.Fatalf("fixture %d: classify differs (%q,%v,%v) vs (%q,%v,%v)", fi, d1, b1, m1, d2, b2, m2)
				}
				dyn := map[string]bool{"name": true, "q": true, "query": true, "cmd": true}
				g1, ok1 := matchSQLInjectionCall(fset, call, dyn)
				g2, ok2 := referenceMatchSQLInjectionCall(fset, call, dyn)
				if g1 != g2 || ok1 != ok2 {
					t.Fatalf("fixture %d: sql injection match differs", fi)
				}
				c1, cok1 := matchCmdInjectionCall(fset, call, dyn)
				c2, cok2 := referenceMatchCmdInjectionCall(fset, call, dyn)
				if c1 != c2 || cok1 != cok2 {
					t.Fatalf("fixture %d: cmd injection match differs", fi)
				}
			}
			return true
		})
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			index := collectResourceCloseCalls(fset, fn.Body)
			check := func(body *ast.BlockStmt) {
				bodies++
				got := closedTargetsWithin(index, body)
				want := collectClosedTargets(fset, body)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("fixture %d %s: closed targets differ: %v vs %v", fi, fn.Name.Name, got, want)
				}
			}
			check(fn.Body)
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
					check(lit.Body)
				}
				return true
			})
		}
	}
	if exprs < 500 || calls < 50 || bodies < 10 {
		t.Fatalf("sample too small: %d exprs, %d calls, %d bodies", exprs, calls, bodies)
	}
}
