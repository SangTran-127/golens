package goast

import (
	"go/ast"
	"go/token"
	"unicode/utf16"
	"unicode/utf8"
)

type Decl struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
}

func Declarations(src []byte) []Decl {
	fset, f := parse(src)
	if f == nil {
		return nil
	}
	out := make([]Decl, 0)
	add := func(id *ast.Ident, kind string) {
		if id == nil || id.Name == "_" {
			return
		}
		p := fset.PositionFor(id.Pos(), false)
		col := p.Column
		if p.Column >= 1 {
			lineStart := p.Offset - (p.Column - 1)
			if lineStart >= 0 && lineStart <= p.Offset && p.Offset <= len(src) {
				col = utf16Len(src[lineStart:p.Offset]) + 1
			}
		}
		if col < 1 {
			col = 1
		}
		out = append(out, Decl{id.Name, kind, p.Line, col})
	}
	for _, d := range f.Decls {
		switch d := d.(type) {
		case *ast.FuncDecl:
			kind := "func"
			if d.Recv != nil {
				kind = "method"
			}
			add(d.Name, kind)
		case *ast.GenDecl:
			if d.Tok != token.TYPE {
				continue
			}
			for _, s := range d.Specs {
				ts := s.(*ast.TypeSpec)
				kind := "type"
				if _, ok := ts.Type.(*ast.InterfaceType); ok {
					kind = "interface"
				}
				add(ts.Name, kind)
			}
		}
	}
	return out
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
