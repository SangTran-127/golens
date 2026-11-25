package docker

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type DetectedPort struct {
	Port    int    `json:"port"`
	Package string `json:"package"`
	File    string `json:"file"`
	Line    int    `json:"line"`
	Via     string `json:"via"`
}

var listenHints = [][]byte{[]byte("Listen"), []byte("Addr"), []byte(".Start("), []byte(".Run(")}

func detectPorts(root string) []DetectedPort {
	ports := []DetectedPort{}
	seen := map[int]bool{}
	fset := token.NewFileSet()
	files := 0
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && (name == "vendor" || name == "testdata" || name == "node_modules" || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_")) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}
		if files++; files > maxScannedGoFiles {
			return filepath.SkipAll
		}
		src, err := os.ReadFile(p)
		if err != nil || !containsAny(src, listenHints) {
			return nil
		}
		f, _ := parser.ParseFile(fset, p, src, parser.SkipObjectResolution)
		if f == nil {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		pkg := filepath.ToSlash(filepath.Dir(rel))
		for _, hit := range portsInFile(f) {
			if seen[hit.port] {
				continue
			}
			seen[hit.port] = true
			ports = append(ports, DetectedPort{Port: hit.port, Package: pkg, File: filepath.ToSlash(rel), Line: fset.Position(hit.pos).Line, Via: hit.via})
		}
		return nil
	})
	return ports
}

func containsAny(src []byte, words [][]byte) bool {
	for _, w := range words {
		if bytes.Contains(src, w) {
			return true
		}
	}
	return false
}

type portHit struct {
	port int
	pos  token.Pos
	via  string
}

func portsInFile(f *ast.File) []portHit {
	var hits []portHit
	var visit func(n ast.Node, scope map[string][]ast.Expr)
	visit = func(n ast.Node, scope map[string][]ast.Expr) {
		ast.Inspect(n, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncLit:
				visit(n.Body, merge(scope, assignments(n.Body)))
				return false
			case *ast.CallExpr:
				if addr, via := listenerAddr(n); addr != nil {
					if port, ok := portOf(eval(addr, scope, 0)); ok {
						hits = append(hits, portHit{port, addr.Pos(), via})
					}
				}
			case *ast.CompositeLit:
				sel, ok := n.Type.(*ast.SelectorExpr)
				if !ok || sel.Sel.Name != "Server" {
					return true
				}
				for _, e := range n.Elts {
					kv, ok := e.(*ast.KeyValueExpr)
					if !ok {
						continue
					}
					if k, ok := kv.Key.(*ast.Ident); ok && k.Name == "Addr" {
						if port, ok := portOf(eval(kv.Value, scope, 0)); ok {
							hits = append(hits, portHit{port, kv.Value.Pos(), exprName(sel) + "{Addr}"})
						}
					}
				}
			}
			return true
		})
	}
	fileScope := assignments(f)
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok {
			if fd.Body != nil {
				visit(fd.Body, merge(fileScope, assignments(fd.Body)))
			}
			continue
		}
		visit(d, fileScope)
	}
	return hits
}

func listenerAddr(call *ast.CallExpr) (ast.Expr, string) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return nil, ""
	}
	pkg := ""
	if id, ok := sel.X.(*ast.Ident); ok {
		pkg = id.Name
	}
	via := exprName(sel)
	switch name := sel.Sel.Name; {
	case (name == "ListenAndServe" || name == "ListenAndServeTLS") && len(call.Args) > 0:
		return call.Args[0], via
	case name == "Listen" && (pkg == "net" || pkg == "tls") && len(call.Args) > 1:
		return call.Args[1], via
	case (name == "Start" || name == "Run" || name == "Listen") && len(call.Args) == 1:
		return call.Args[0], via
	}
	return nil, ""
}

func exprName(e ast.Expr) string {
	switch e := e.(type) {
	case *ast.Ident:
		return e.Name
	case *ast.SelectorExpr:
		if x := exprName(e.X); x != "" {
			return x + "." + e.Sel.Name
		}
		return e.Sel.Name
	case *ast.CallExpr:
		return exprName(e.Fun) + "()"
	}
	return ""
}

func assignments(n ast.Node) map[string][]ast.Expr {
	m := map[string][]ast.Expr{}
	add := func(lhs []*ast.Ident, rhs []ast.Expr) {
		if len(lhs) != len(rhs) {
			return
		}
		for i, id := range lhs {
			m[id.Name] = append(m[id.Name], rhs[i])
		}
	}
	ast.Inspect(n, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.FuncDecl, *ast.FuncLit:
			return false
		case *ast.ValueSpec:
			add(n.Names, n.Values)
		case *ast.AssignStmt:
			var ids []*ast.Ident
			for _, l := range n.Lhs {
				id, ok := l.(*ast.Ident)
				if !ok {
					return true
				}
				ids = append(ids, id)
			}
			add(ids, n.Rhs)
		}
		return true
	})
	return m
}

func merge(outer, inner map[string][]ast.Expr) map[string][]ast.Expr {
	m := make(map[string][]ast.Expr, len(outer)+len(inner))
	for k, v := range outer {
		m[k] = v
	}
	for k, v := range inner {
		m[k] = append(append([]ast.Expr{}, v...), m[k]...)
	}
	return m
}

const maxEvalDepth = 6

func eval(e ast.Expr, scope map[string][]ast.Expr, depth int) string {
	if e == nil || depth > maxEvalDepth {
		return ""
	}
	switch e := e.(type) {
	case *ast.BasicLit:
		if e.Kind == token.STRING {
			s, _ := strconv.Unquote(e.Value)
			return s
		}
		if e.Kind == token.INT {
			return e.Value
		}
	case *ast.ParenExpr:
		return eval(e.X, scope, depth+1)
	case *ast.StarExpr:
		return eval(e.X, scope, depth+1)
	case *ast.Ident:
		for _, v := range scope[e.Name] {
			if s := eval(v, scope, depth+1); s != "" {
				if _, ok := portOf(s); ok {
					return s
				}
			}
		}
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			x, y := eval(e.X, scope, depth+1), eval(e.Y, scope, depth+1)
			if x != "" && y != "" {
				return x + y
			}
		}
	case *ast.CallExpr:
		return evalCall(e, scope, depth)
	}
	return ""
}

func evalCall(call *ast.CallExpr, scope map[string][]ast.Expr, depth int) string {
	name := exprName(call.Fun)
	switch name {
	case "os.Getenv", "os.LookupEnv":
		return ""
	case "fmt.Sprintf":
		if len(call.Args) == 2 {
			format := eval(call.Args[0], scope, depth+1)
			if arg := eval(call.Args[1], scope, depth+1); arg != "" && strings.Count(format, "%") == 1 {
				for _, verb := range []string{"%s", "%d", "%v"} {
					if strings.Contains(format, verb) {
						return strings.Replace(format, verb, arg, 1)
					}
				}
			}
		}
		return ""
	case "strconv.Itoa":
		if len(call.Args) == 1 {
			return eval(call.Args[0], scope, depth+1)
		}
		return ""
	}
	for _, a := range call.Args {
		if lit, ok := a.(*ast.BasicLit); ok {
			if s := eval(lit, scope, depth+1); s != "" {
				if _, ok := portOf(s); ok {
					return s
				}
			}
		}
	}
	return ""
}

func portOf(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	p := s
	if strings.Contains(s, ":") {
		_, port, err := net.SplitHostPort(s)
		if err != nil {
			return 0, false
		}
		p = port
	}
	n, err := strconv.Atoi(p)
	if err != nil || n <= 0 || n > 65535 {
		return 0, false
	}
	return n, true
}
