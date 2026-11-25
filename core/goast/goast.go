package goast

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
)

func parse(src []byte) (*token.FileSet, *ast.File) {
	fset := token.NewFileSet()
	f, _ := parser.ParseFile(fset, "", src, parser.SkipObjectResolution)
	return fset, f
}

type binding struct {
	name    string
	line    int
	scopeLo token.Pos
	scopeHi token.Pos
	assign  bool
}

type funcScope struct {
	typ  *ast.FuncType
	body *ast.BlockStmt
}

func enclosingFuncs(f *ast.File, pos token.Pos) []funcScope {
	var chain []funcScope
	ast.Inspect(f, func(n ast.Node) bool {
		if n == nil || pos < n.Pos() || pos > n.End() {
			return false
		}
		switch fn := n.(type) {
		case *ast.FuncDecl:
			if fn.Body != nil {
				chain = append([]funcScope{{fn.Type, fn.Body}}, chain...)
			}
		case *ast.FuncLit:
			chain = append([]funcScope{{fn.Type, fn.Body}}, chain...)
		}
		return true
	})
	return chain
}

func InlineValueLines(src []byte, line int, names []string) map[string]int {
	out := map[string]int{}
	fset, f := parse(src)
	if f == nil || line < 1 {
		return out
	}
	tf := fset.File(f.Pos())
	if tf == nil || line > tf.LineCount() {
		return out
	}
	stop := tf.LineStart(line)
	want := map[string]bool{}
	for _, n := range names {
		if n != "" && !strings.HasPrefix(n, "(") {
			want[n] = true
		}
	}
	for _, fn := range enclosingFuncs(f, stop) {
		for name, at := range funcBindings(fset, fn.typ, fn.body, stop, line, want) {
			out[name] = at
			delete(want, name)
		}
	}
	return out
}

func funcBindings(fset *token.FileSet, typ *ast.FuncType, body *ast.BlockStmt, stop token.Pos, line int, want map[string]bool) map[string]int {
	out := map[string]int{}
	lineOf := func(p token.Pos) int { return fset.Position(p).Line }
	var binds []binding
	add := func(id *ast.Ident, lo, hi token.Pos) {
		if id != nil && want[id.Name] {
			binds = append(binds, binding{id.Name, lineOf(id.Pos()), lo, hi, false})
		}
	}
	assign := func(id *ast.Ident) {
		if id != nil && want[id.Name] {
			binds = append(binds, binding{id.Name, lineOf(id.Pos()), 0, 0, true})
		}
	}
	addFields := func(fl *ast.FieldList, lo, hi token.Pos) {
		if fl == nil {
			return
		}
		for _, fld := range fl.List {
			for _, id := range fld.Names {
				add(id, lo, hi)
			}
		}
	}
	addFields(typ.Params, body.Lbrace, body.Rbrace)
	addFields(typ.Results, body.Lbrace, body.Rbrace)
	var walk func(n ast.Node, lo, hi token.Pos)
	walk = func(n ast.Node, lo, hi token.Pos) {
		ast.Inspect(n, func(c ast.Node) bool {
			if c == nil || c == n {
				return true
			}
			if c.Pos() >= stop {
				return false
			}
			switch s := c.(type) {
			case *ast.FuncLit:
				return false
			case *ast.BlockStmt:
				walk(s, s.Lbrace, s.Rbrace)
				return false
			case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt, *ast.TypeSwitchStmt, *ast.SelectStmt, *ast.CaseClause, *ast.CommClause:
				if s, ok := c.(*ast.RangeStmt); ok && s.Tok == token.DEFINE {
					for _, e := range []ast.Expr{s.Key, s.Value} {
						if id, ok := e.(*ast.Ident); ok {
							add(id, s.Pos(), s.End())
						}
					}
				}
				walk(c, c.Pos(), c.End())
				return false
			case *ast.AssignStmt:
				for _, e := range s.Lhs {
					id, ok := e.(*ast.Ident)
					if !ok {
						continue
					}
					if s.Tok == token.DEFINE {
						add(id, lo, hi)
					} else {
						assign(id)
					}
				}
			case *ast.ValueSpec:
				for _, id := range s.Names {
					add(id, lo, hi)
				}
			case *ast.IncDecStmt:
				if id, ok := s.X.(*ast.Ident); ok {
					assign(id)
				}
			}
			return true
		})
	}
	walk(body, body.Lbrace, body.Rbrace)
	declared := map[string]bool{}
	for _, b := range binds {
		if !b.assign && stop >= b.scopeLo && stop <= b.scopeHi {
			declared[b.name] = true
		}
	}
	funcLine := lineOf(typ.Pos())
	for _, b := range binds {
		if b.line >= line && b.line != funcLine {
			continue
		}
		if b.assign && !declared[b.name] || !b.assign && (stop < b.scopeLo || stop > b.scopeHi) {
			continue
		}
		if b.line > out[b.name] {
			out[b.name] = b.line
		}
	}
	return out
}

func DeclarationAt(src []byte, offset int) (string, bool) {
	fset, f := parse(src)
	if f == nil {
		return "", false
	}
	tf := fset.File(f.Pos())
	if tf == nil || offset < 0 || offset > tf.Size() {
		return "", false
	}
	pos := tf.Pos(offset)
	var found *ast.Ident
	check := func(id *ast.Ident) {
		if id != nil && id.Name != "_" && pos >= id.Pos() && pos <= id.End() {
			found = id
		}
	}
	fields := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, fld := range fl.List {
			for _, id := range fld.Names {
				check(id)
			}
		}
	}
	ast.Inspect(f, func(n ast.Node) bool {
		if found != nil || n == nil || pos < n.Pos() || pos > n.End() {
			return false
		}
		switch d := n.(type) {
		case *ast.FuncDecl:
			check(d.Name)
			fields(d.Recv)
		case *ast.FuncType:
			fields(d.TypeParams)
			fields(d.Params)
			fields(d.Results)
		case *ast.TypeSpec:
			check(d.Name)
			fields(d.TypeParams)
		case *ast.ValueSpec:
			for _, id := range d.Names {
				check(id)
			}
		case *ast.StructType:
			fields(d.Fields)
		case *ast.InterfaceType:
			fields(d.Methods)
		case *ast.AssignStmt:
			if d.Tok == token.DEFINE {
				for _, e := range d.Lhs {
					if id, ok := e.(*ast.Ident); ok {
						check(id)
					}
				}
			}
		case *ast.RangeStmt:
			if d.Tok == token.DEFINE {
				for _, e := range []ast.Expr{d.Key, d.Value} {
					if id, ok := e.(*ast.Ident); ok {
						check(id)
					}
				}
			}
		case *ast.LabeledStmt:
			check(d.Label)
		}
		return true
	})
	if found == nil {
		return "", false
	}
	return found.Name, true
}
