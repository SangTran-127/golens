package usageindex

import (
	"fmt"
	"go/types"
	"slices"
	"strings"
)

func keyOf(obj types.Object) string {
	switch o := obj.(type) {
	case *types.Func:
		o = o.Origin()
		if o.Pkg() == nil {
			return ""
		}
		recv := o.Signature().Recv()
		if recv == nil {
			if pkgLevel(o) {
				return o.Pkg().Path() + " " + o.Name()
			}
			return ""
		}
		if tn := namedOf(recv.Type()); tn != nil && pkgLevel(tn) {
			return tn.Pkg().Path() + " " + tn.Name() + "." + o.Name()
		}
	case *types.TypeName:
		if pkgLevel(o) {
			return o.Pkg().Path() + " " + o.Name()
		}
	}
	return ""
}

func pkgLevel(o types.Object) bool {
	return o.Pkg() != nil && o.Parent() == o.Pkg().Scope()
}

func namedOf(t types.Type) *types.TypeName {
	if ptr, ok := types.Unalias(t).(*types.Pointer); ok {
		t = ptr.Elem()
	}
	if n, ok := types.Unalias(t).(*types.Named); ok {
		return n.Origin().Obj()
	}
	return nil
}

func methodID(fn *types.Func) string {
	if !fn.Exported() && fn.Pkg() != nil {
		return fn.Pkg().Path() + "." + fn.Name()
	}
	return fn.Name()
}

type methodInfo struct {
	id     string
	fp     string
	key    string
	loc    Loc
	tricky bool
}

type typeSummary struct {
	iface   bool
	pos     Loc
	methods []methodInfo
}

func (s *typeSummary) method(id string) (methodInfo, bool) {
	i, ok := slices.BinarySearchFunc(s.methods, id, func(m methodInfo, id string) int { return strings.Compare(m.id, id) })
	if !ok {
		return methodInfo{}, false
	}
	return s.methods[i], true
}

func (l *loader) summarize(t types.Type) *typeSummary {
	if s, ok := l.sumCache[t]; ok {
		return s
	}
	mset := types.NewMethodSet(ensurePointer(t))
	s := &typeSummary{iface: types.IsInterface(t), methods: make([]methodInfo, 0, mset.Len())}
	var tn *types.TypeName
	if n, ok := t.(*types.Named); ok && pkgLevel(n.Obj()) {
		tn = n.Obj()
	}
	ws := tn == nil || l.wsPaths[tn.Pkg().Path()]
	for sel := range mset.Methods() {
		fn := sel.Obj().(*types.Func)
		if fn.Signature().TypeParams().Len() > 0 {
			continue
		}
		fp, tricky := fingerprint(fn.Signature())
		m := methodInfo{id: l.intern(methodID(fn)), fp: l.intern(fp), tricky: tricky}
		if tn != nil && fn.Pkg() == tn.Pkg() {
			m.loc = l.loc(fn.Pos(), fn.Name())
		}
		if ws || m.loc.Line == 0 {
			m.key = keyOf(fn)
		}
		s.methods = append(s.methods, m)
	}
	slices.SortFunc(s.methods, func(a, b methodInfo) int { return strings.Compare(a.id, b.id) })
	if len(s.methods) == 0 {
		s = nil
	} else if tn != nil {
		s.pos = l.loc(tn.Pos(), tn.Name())
	}
	l.sumCache[t] = s
	return s
}

func (l *loader) intern(s string) string {
	if v, ok := l.strs[s]; ok {
		return v
	}
	l.strs[s] = s
	return s
}

func canon(s *typeSummary) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%t;", s.iface)
	for _, m := range s.methods {
		b.WriteString(m.id)
		b.WriteString(m.fp)
		b.WriteByte(';')
	}
	return b.String()
}

func implementsSum(x, y *typeSummary) bool {
	if !y.iface || len(x.methods) < len(y.methods) {
		return false
	}
	for _, ym := range y.methods {
		xm, ok := x.method(ym.id)
		if !ok {
			return false
		}
		if xm.tricky || ym.tricky {
			if !fingerprintsMatch(xm.fp, ym.fp) {
				return false
			}
		} else if xm.fp != ym.fp {
			return false
		}
	}
	return true
}

func corresponds(x, y *typeSummary) bool {
	return implementsSum(x, y) || implementsSum(y, x)
}

func (ix *Index) count(fe *fileEntry, d *decl) int {
	if d.key == "" {
		return 0
	}
	c := ix.counts[d.key]
	if d.method == "" {
		return c
	}
	self := ix.pkgs[fe.owner].types[d.recv]
	if self == nil {
		return c
	}
	targets := map[string]bool{d.key: true}
	ext := map[string]bool{}
	var expansions []int
	for _, ref := range ix.byMethod[d.method] {
		o := ref.sum
		if o == self || !corresponds(self, o) {
			continue
		}
		if d.exported {
			expansions = append(expansions, ref.pkg)
		}
		m, _ := o.method(d.method)
		k := m.key
		switch {
		case k == "" || targets[k]:
		case ix.wsKey(k):
			targets[k] = true
			c += ix.counts[k]
		case d.exported:
			ext[k] = true
		}
	}
	var scope map[int]bool
	if len(ext) > 0 {
		scope = ix.reverseDeps(append(append([]int(nil), fe.pkgs...), expansions...))
	}
	seen := map[*fileEntry]bool{}
	visit := func(f *fileEntry) {
		if seen[f] {
			return
		}
		seen[f] = true
		inScope := false
		for _, p := range f.pkgs {
			inScope = inScope || scope[p]
		}
		local := f.pkgPath == fe.pkgPath
		for k, n := range f.ext {
			if inScope && ext[k] {
				c += n
			} else if em := ix.extRecv[k]; local && em.name == d.method && corresponds(self, em.recv) {
				c += n
			}
		}
	}
	for _, f := range ix.byPath[fe.pkgPath] {
		visit(f)
	}
	for p := range scope {
		for _, f := range ix.pkgs[p].files {
			visit(f)
		}
	}
	return c
}

func (ix *Index) wsKey(k string) bool {
	path, _, _ := strings.Cut(k, " ")
	_, ok := ix.byPath[path]
	return ok
}

func (ix *Index) reverseDeps(starts []int) map[int]bool {
	out := map[int]bool{}
	expanded := map[int]bool{}
	queue := starts
	for len(queue) > 0 {
		p := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		if expanded[p] {
			continue
		}
		expanded[p] = true
		for _, q := range ix.pkgs[p].importedBy {
			if !ix.pkgs[q].itv {
				out[q] = true
			}
			queue = append(queue, q)
		}
	}
	return out
}
