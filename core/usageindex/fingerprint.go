package usageindex

import (
	"fmt"
	"go/types"
	"reflect"
	"strconv"
	"strings"
	"text/scanner"
)

func fingerprint(t types.Type) (string, bool) {
	var buf strings.Builder
	tricky := false
	var print func(t types.Type)
	print = func(t types.Type) {
		switch t := t.(type) {
		case *types.Alias:
			print(types.Unalias(t))
		case *types.Named:
			targs := t.TypeArgs()
			if targs != nil {
				buf.WriteString("(inst ")
			}
			tname := t.Obj()
			if tname.Pkg() != nil {
				fmt.Fprintf(&buf, "(qual %q %s)", tname.Pkg().Path(), tname.Name())
			} else {
				buf.WriteString(tname.Name())
			}
			if targs != nil {
				for t0 := range targs.Types() {
					buf.WriteByte(' ')
					print(t0)
				}
				buf.WriteString(")")
			}
		case *types.Array:
			fmt.Fprintf(&buf, "(array %d ", t.Len())
			print(t.Elem())
			buf.WriteByte(')')
		case *types.Slice:
			buf.WriteString("(slice ")
			print(t.Elem())
			buf.WriteByte(')')
		case *types.Pointer:
			buf.WriteString("(ptr ")
			print(t.Elem())
			buf.WriteByte(')')
		case *types.Map:
			buf.WriteString("(map ")
			print(t.Key())
			buf.WriteByte(' ')
			print(t.Elem())
			buf.WriteByte(')')
		case *types.Chan:
			fmt.Fprintf(&buf, "(chan %d ", t.Dir())
			print(t.Elem())
			buf.WriteByte(')')
		case *types.Tuple:
			buf.WriteString("(tuple")
			for v := range t.Variables() {
				buf.WriteByte(' ')
				print(v.Type())
			}
			buf.WriteByte(')')
		case *types.Basic:
			switch t.Kind() {
			case types.Byte:
				buf.WriteString("byte")
			case types.Rune:
				buf.WriteString("rune")
			case types.UnsafePointer:
				buf.WriteString(`(qual "unsafe" Pointer)`)
			default:
				buf.WriteString(t.String())
			}
		case *types.Signature:
			buf.WriteString("(func ")
			print(t.Params())
			if t.Variadic() {
				buf.WriteString(" v")
			}
			buf.WriteByte(' ')
			print(t.Results())
			buf.WriteByte(')')
		case *types.Struct:
			buf.WriteString("(struct")
			for i := range t.NumFields() {
				f := t.Field(i)
				name := f.Name()
				if !f.Exported() {
					name = fmt.Sprintf("(qual %q %s)", f.Pkg().Path(), name)
				}
				fmt.Fprintf(&buf, " %s %t %q ", name, f.Embedded(), t.Tag(i))
				print(f.Type())
			}
			buf.WriteByte(')')
		case *types.Interface:
			if t.NumMethods() == 0 {
				buf.WriteString("any")
			} else {
				tricky = true
				buf.WriteString("(interface)")
			}
		case *types.TypeParam:
			tricky = true
			fmt.Fprintf(&buf, "(%s %d)", symTypeparam, t.Index())
		default:
			buf.WriteString(strconv.Quote(types.TypeString(t, nil)))
		}
	}
	print(t)
	return buf.String(), tricky
}

func fingerprintsMatch(x, y string) bool {
	return unifySexpr(parseFingerprint(x), parseFingerprint(y))
}

type (
	sexpr  any
	symbol string
	cons   struct{ car, cdr sexpr }
)

const symTypeparam = "typeparam"

func parseFingerprint(fp string) sexpr {
	var scan scanner.Scanner
	scan.Error = func(*scanner.Scanner, string) {}
	scan.Init(strings.NewReader(fp))
	var tok rune
	next := func() { tok = scan.Scan() }
	next()
	var parse func() sexpr
	parse = func() sexpr {
		if tok == '(' {
			next()
			var head sexpr
			tailcdr := &head
			for tok != ')' && tok != scanner.EOF {
				cell := &cons{car: parse()}
				*tailcdr = cell
				tailcdr = &cell.cdr
			}
			next()
			return head
		}
		s := scan.TokenText()
		switch tok {
		case scanner.Int:
			next()
			i, _ := strconv.Atoi(s)
			return i
		case scanner.String:
			next()
			u, _ := strconv.Unquote(s)
			return u
		default:
			next()
			return symbol(s)
		}
	}
	return parse()
}

func unifySexpr(x, y sexpr) bool {
	var maxTypeParam func(x sexpr) int
	maxTypeParam = func(x sexpr) int {
		if i := typeParamIndex(x); i >= 0 {
			return i
		}
		if c, ok := x.(*cons); ok {
			return max(maxTypeParam(c.car), maxTypeParam(c.cdr))
		}
		return -1
	}
	xBindings := make([]*sexpr, maxTypeParam(x)+1)
	for i := range xBindings {
		xBindings[i] = new(sexpr)
	}
	yBindings := make([]*sexpr, maxTypeParam(y)+1)
	for i := range yBindings {
		yBindings[i] = new(sexpr)
	}
	bind := func(b *sexpr, s sexpr, bindings []*sexpr) bool {
		var occurs func(s sexpr) bool
		occurs = func(s sexpr) bool {
			if j := typeParamIndex(s); j >= 0 {
				return b == bindings[j]
			}
			if c, ok := s.(*cons); ok {
				return occurs(c.car) || occurs(c.cdr)
			}
			return false
		}
		if occurs(s) {
			return false
		}
		*b = s
		return true
	}
	var uni func(x, y sexpr) bool
	uni = func(x, y sexpr) bool {
		var bx, by *sexpr
		ix := typeParamIndex(x)
		if ix >= 0 {
			bx = xBindings[ix]
		}
		iy := typeParamIndex(y)
		if iy >= 0 {
			by = yBindings[iy]
		}
		if bx != nil || by != nil {
			if bx != nil && by != nil && *bx == nil && *by == nil {
				xBindings[ix] = yBindings[iy]
				return true
			}
			if bx != nil && *bx != nil {
				x = *bx
			}
			if by != nil && *by != nil {
				y = *by
			}
			if bx != nil && *bx == nil {
				return bind(bx, y, yBindings)
			}
			if by != nil && *by == nil {
				return bind(by, x, xBindings)
			}
			return uni(x, y)
		}
		if reflect.TypeOf(x) != reflect.TypeOf(y) {
			return false
		}
		switch x := x.(type) {
		case nil, string, int, symbol:
			return x == y
		case *cons:
			y := y.(*cons)
			if !uni(x.car, y.car) {
				return false
			}
			if x.cdr == nil {
				return y.cdr == nil
			}
			if y.cdr == nil {
				return false
			}
			return uni(x.cdr, y.cdr)
		}
		return false
	}
	return uni(x, y)
}

func typeParamIndex(x sexpr) int {
	if x, ok := x.(*cons); ok {
		if sym, ok := x.car.(symbol); ok && sym == symTypeparam {
			if c, ok := x.cdr.(*cons); ok {
				if i, ok := c.car.(int); ok {
					return i
				}
			}
		}
	}
	return -1
}
