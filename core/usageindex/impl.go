package usageindex

import (
	"bytes"
	"cmp"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"net/url"
	"os"
	"reflect"
	"slices"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

type Loc struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Col    int    `json:"col"`
	EndCol int    `json:"endCol"`
}

type Lens struct {
	Count int
	Impls []Loc
}

type localKey struct {
	file string
	pos  Pos
}

var (
	errorType = types.Universe.Lookup("error").Type()
	errorMset = types.NewMethodSet(errorType)
)

func ensurePointer(t types.Type) types.Type {
	if _, ok := types.Unalias(t).(*types.Named); ok && !types.IsInterface(t) {
		return types.NewPointer(t)
	}
	return t
}

func utf16Len(b []byte) int {
	n := 0
	for len(b) > 0 {
		r, size := utf8.DecodeRune(b)
		n += utf16.RuneLen(r)
		b = b[size:]
	}
	return n
}

func identLoc(p token.Position, src []byte, name string) Loc {
	col := p.Column
	if src != nil && p.Column >= 1 {
		start := p.Offset - (p.Column - 1)
		if start >= 0 && start <= p.Offset && p.Offset <= len(src) {
			col = utf16Len(src[start:p.Offset]) + 1
		}
	}
	if col < 1 {
		col = 1
	}
	return Loc{File: p.Filename, Line: p.Line, Col: col, EndCol: col + utf16Len([]byte(name))}
}

func (l *loader) loc(pos token.Pos, name string) Loc {
	p := l.fset.PositionFor(pos, false)
	if pf := l.wsFiles[p.Filename]; pf != nil && pf.file != nil && pf.file.FileStart <= pos && pos <= pf.file.FileEnd {
		return identLoc(p, pf.src, name)
	}
	loc := identLoc(p, nil, name)
	if c, ok := l.cols[pos]; ok {
		loc.EndCol += c - loc.Col
		loc.Col = c
	}
	return loc
}

func utf16Cols(fset *token.FileSet, f *ast.File, src []byte) map[token.Pos]int {
	if bytes.IndexFunc(src, func(r rune) bool { return r >= utf8.RuneSelf }) < 0 {
		return nil
	}
	cols := map[token.Pos]int{}
	add := func(id *ast.Ident) {
		p := fset.PositionFor(id.Pos(), false)
		if loc := identLoc(p, src, id.Name); loc.Col != p.Column {
			cols[id.Pos()] = loc.Col
		}
	}
	ast.Inspect(f, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.TypeSpec:
			add(n.Name)
		case *ast.FuncDecl:
			add(n.Name)
		case *ast.InterfaceType:
			for _, m := range n.Methods.List {
				for _, id := range m.Names {
					add(id)
				}
			}
		}
		return true
	})
	return cols
}

func builtinErrorLoc(path string) Loc {
	if path == "" {
		return Loc{}
	}
	src, err := os.ReadFile(path)
	if err != nil {
		return Loc{}
	}
	fset := token.NewFileSet()
	f, _ := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
	if f == nil {
		return Loc{}
	}
	for _, d := range f.Decls {
		if gd, ok := d.(*ast.GenDecl); ok {
			for _, s := range gd.Specs {
				if ts, ok := s.(*ast.TypeSpec); ok && ts.Name.Name == "error" {
					return identLoc(fset.PositionFor(ts.Name.Pos(), false), src, "error")
				}
			}
		}
	}
	return Loc{}
}

func lensIdents(f *ast.File) []*ast.Ident {
	var out []*ast.Ident
	add := func(id *ast.Ident) {
		if id != nil && id.Name != "_" {
			out = append(out, id)
		}
	}
	for _, d := range f.Decls {
		switch d := d.(type) {
		case *ast.FuncDecl:
			add(d.Name)
		case *ast.GenDecl:
			if d.Tok == token.TYPE {
				for _, s := range d.Specs {
					add(s.(*ast.TypeSpec).Name)
				}
			}
		}
	}
	return out
}

func queryOf(obj types.Object) (*types.TypeName, *types.Func) {
	switch obj := obj.(type) {
	case *types.TypeName:
		return obj, nil
	case *types.Func:
		if recv := obj.Signature().Recv(); recv != nil {
			if tn := namedOf(recv.Type()); tn != nil {
				return tn, obj
			}
		}
	}
	return nil, nil
}

func (l *loader) localImpls(n *node, info *types.Info) map[localKey][]Loc {
	type candidate struct {
		name *ast.Ident
		t    types.Type
		mset *types.MethodSet
	}
	var cands []candidate
	for _, name := range n.names {
		if pf := l.wsFiles[name]; pf.file != nil {
			ast.Inspect(pf.file, func(nd ast.Node) bool {
				if ts, ok := nd.(*ast.TypeSpec); ok {
					if tn, ok := info.Defs[ts.Name].(*types.TypeName); ok && !tn.IsAlias() {
						t := ensurePointer(tn.Type())
						if ms := types.NewMethodSet(t); ms.Len() > 0 {
							cands = append(cands, candidate{ts.Name, t, ms})
						}
					}
				}
				return true
			})
		}
	}
	type match struct {
		cands []int
		error bool
	}
	matches := map[*types.TypeName]match{}
	out := map[localKey][]Loc{}
	for _, name := range n.names {
		pf := l.wsFiles[name]
		if pf.file == nil {
			continue
		}
		for _, id := range lensIdents(pf.file) {
			qtn, method := queryOf(info.Defs[id])
			if qtn == nil || l.summarize(qtn.Type()) == nil {
				continue
			}
			m, ok := matches[qtn]
			if !ok {
				qt := ensurePointer(qtn.Type())
				qmset := types.NewMethodSet(qt)
				related := func(t types.Type, mset *types.MethodSet) bool {
					if types.IsInterface(qt) {
						return implementsType(t, qt, qmset)
					}
					return implementsType(qt, t, mset)
				}
				for i, c := range cands {
					if c.name.Pos() != qtn.Pos() && related(c.t, c.mset) {
						m.cands = append(m.cands, i)
					}
				}
				m.error = related(errorType, errorMset)
				matches[qtn] = m
			}
			var locs []Loc
			for _, i := range m.cands {
				c := cands[i]
				if method == nil {
					locs = append(locs, l.loc(c.name.Pos(), c.name.Name))
					continue
				}
				for sel := range c.mset.Methods() {
					fn := sel.Obj()
					if fn.Pos() != method.Pos() && fn.Id() == method.Id() {
						locs = append(locs, l.loc(fn.Pos(), fn.Name()))
						break
					}
				}
			}
			if m.error && l.st.errorLoc.Line > 0 {
				locs = append(locs, l.st.errorLoc)
			}
			if len(locs) > 0 {
				out[localKey{name, l.pos(pf.src, id)}] = locs
			}
		}
	}
	return out
}

func implementsType(x, y types.Type, ymset *types.MethodSet) bool {
	if !types.IsInterface(y) {
		return false
	}
	for sel := range ymset.Methods() {
		ym := sel.Obj().(*types.Func)
		if ym.Signature().TypeParams().Len() > 0 {
			continue
		}
		xobj, _, _ := types.LookupFieldOrMethod(x, false, ym.Pkg(), ym.Name())
		xm, ok := xobj.(*types.Func)
		if !ok || xm.Signature().TypeParams().Len() > 0 || !unifyTypes(xm.Signature(), ym.Signature()) {
			return false
		}
	}
	return true
}

func unifyTypes(x, y types.Type) bool {
	bindings := map[*types.TypeParam]*types.Type{}
	bindingFor := func(tp *types.TypeParam) *types.Type {
		if tp == nil {
			return nil
		}
		b := bindings[tp]
		if b == nil {
			b = new(types.Type)
			bindings[tp] = b
		}
		return b
	}
	bind := func(b *types.Type, t types.Type) bool {
		for _, tp := range freeTypeParams(t) {
			if b == bindings[tp] {
				return false
			}
		}
		*b = t
		return true
	}
	depth := 0
	var uni func(x, y types.Type) bool
	uni = func(x, y types.Type) bool {
		depth++
		defer func() { depth-- }()
		if depth > 100 {
			return false
		}
		x = types.Unalias(x)
		y = types.Unalias(y)
		tpx, _ := x.(*types.TypeParam)
		tpy, _ := y.(*types.TypeParam)
		if tpx != nil || tpy != nil {
			if tpx == tpy {
				return true
			}
			bx := bindingFor(tpx)
			by := bindingFor(tpy)
			if bx != nil && by != nil && *bx == nil && *by == nil {
				bindings[tpx] = by
				return true
			}
			if bx != nil && *bx != nil {
				x = *bx
			}
			if by != nil && *by != nil {
				y = *by
			}
			if bx != nil && *bx == nil {
				return bind(bx, y)
			}
			if by != nil && *by == nil {
				return bind(by, x)
			}
			return uni(x, y)
		}
		if reflect.TypeOf(x) != reflect.TypeOf(y) {
			return false
		}
		switch x := x.(type) {
		case *types.Array:
			y := y.(*types.Array)
			return x.Len() == y.Len() && uni(x.Elem(), y.Elem())
		case *types.Basic:
			return x.Kind() == y.(*types.Basic).Kind()
		case *types.Chan:
			y := y.(*types.Chan)
			return x.Dir() == y.Dir() && uni(x.Elem(), y.Elem())
		case *types.Interface:
			return x.NumMethods() == y.(*types.Interface).NumMethods()
		case *types.Map:
			y := y.(*types.Map)
			return uni(x.Key(), y.Key()) && uni(x.Elem(), y.Elem())
		case *types.Named:
			y := y.(*types.Named)
			if x.Origin() != y.Origin() {
				return false
			}
			xtargs, ytargs := x.TypeArgs(), y.TypeArgs()
			if xtargs.Len() != ytargs.Len() {
				return false
			}
			for i := range xtargs.Len() {
				if !uni(xtargs.At(i), ytargs.At(i)) {
					return false
				}
			}
			return true
		case *types.Pointer:
			return uni(x.Elem(), y.(*types.Pointer).Elem())
		case *types.Signature:
			y := y.(*types.Signature)
			return x.Variadic() == y.Variadic() && uni(x.Params(), y.Params()) && uni(x.Results(), y.Results())
		case *types.Slice:
			return uni(x.Elem(), y.(*types.Slice).Elem())
		case *types.Struct:
			y := y.(*types.Struct)
			if x.NumFields() != y.NumFields() {
				return false
			}
			for i := range x.NumFields() {
				xf, yf := x.Field(i), y.Field(i)
				if xf.Embedded() != yf.Embedded() || xf.Name() != yf.Name() || x.Tag(i) != y.Tag(i) ||
					!xf.Exported() && xf.Pkg() != yf.Pkg() || !uni(xf.Type(), yf.Type()) {
					return false
				}
			}
			return true
		case *types.Tuple:
			y := y.(*types.Tuple)
			if x.Len() != y.Len() {
				return false
			}
			for i := range x.Len() {
				if !uni(x.At(i).Type(), y.At(i).Type()) {
					return false
				}
			}
			return true
		}
		return false
	}
	return uni(x, y)
}

func freeTypeParams(t types.Type) []*types.TypeParam {
	var out []*types.TypeParam
	var walk func(types.Type)
	walk = func(t types.Type) {
		switch t := types.Unalias(t).(type) {
		case *types.TypeParam:
			if !slices.Contains(out, t) {
				out = append(out, t)
			}
		case *types.Array:
			walk(t.Elem())
		case *types.Chan:
			walk(t.Elem())
		case *types.Map:
			walk(t.Key())
			walk(t.Elem())
		case *types.Named:
			if t.Origin() == t {
				for tp := range t.TypeParams().TypeParams() {
					walk(tp)
				}
			} else {
				for ta := range t.TypeArgs().Types() {
					walk(ta)
				}
			}
		case *types.Pointer:
			walk(t.Elem())
		case *types.Signature:
			walk(t.Params())
			walk(t.Results())
		case *types.Slice:
			walk(t.Elem())
		case *types.Struct:
			for f := range t.Fields() {
				walk(f.Type())
			}
		case *types.Tuple:
			for v := range t.Variables() {
				walk(v.Type())
			}
		}
	}
	walk(t)
	return out
}

func (ix *Index) impls(fe *fileEntry, d *decl) []Loc {
	q := d.sum
	if q == nil {
		return nil
	}
	var out []Loc
	for _, p := range fe.pkgs {
		if pe := ix.pkgs[p]; !pe.itv {
			out = append(out, pe.local[localKey{fe.name, d.pos}]...)
		}
	}
	search := func(pe *pkgEntry) {
		if pe.itv || pe.path == fe.pkgPath {
			return
		}
		for _, c := range pe.types {
			if q.iface && !implementsSum(c, q) || !q.iface && !implementsSum(q, c) {
				continue
			}
			if d.method == "" {
				out = append(out, c.pos)
			} else if m, ok := c.method(d.method); ok {
				if loc, ok := ix.methodLoc(m); ok {
					out = append(out, loc)
				}
			}
		}
	}
	for _, pe := range ix.pkgs {
		search(pe)
	}
	for _, pe := range ix.deps {
		search(pe)
	}
	slices.SortFunc(out, compareLoc)
	return slices.Compact(out)
}

func (ix *Index) methodLoc(m methodInfo) (Loc, bool) {
	if m.loc.Line > 0 {
		return m.loc, true
	}
	path, rest, ok := strings.Cut(m.key, " ")
	if !ok {
		return Loc{}, false
	}
	typ, name, _ := strings.Cut(rest, ".")
	pe := ix.byPkgPath[path]
	if pe == nil || pe.types[path+" "+typ] == nil {
		return Loc{}, false
	}
	if !token.IsExported(name) {
		name = path + "." + name
	}
	decl, _ := pe.types[path+" "+typ].method(name)
	return decl.loc, decl.loc.Line > 0
}

func compareLoc(a, b Loc) int {
	if a.File != b.File {
		return strings.Compare(fileURI(a.File), fileURI(b.File))
	}
	return cmp.Or(a.Line-b.Line, a.Col-b.Col, a.EndCol-b.EndCol)
}

func fileURI(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}
