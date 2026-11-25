package goast

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/build/constraint"
	"go/format"
	"go/parser"
	"go/token"
	"runtime"
	"strings"
)

type goastImportSpec struct {
	Alias string
	Path  string
}

func isGoastSyncLockType(rawType string) bool {
	trimmed := strings.TrimSpace(rawType)
	switch trimmed {
	case "sync.Mutex", "sync.RWMutex", "sync.WaitGroup", "sync.Once", "sync.Cond", "sync.Map", "sync.Pool":
		return true
	default:
		return strings.HasPrefix(trimmed, "atomic.")
	}
}

func addGoastReservedPredeclared(used map[string]bool) {
	if used == nil {
		return
	}
	for _, ident := range []string{
		"bool", "byte", "complex64", "complex128", "error", "float32", "float64",
		"int", "int8", "int16", "int32", "int64", "rune", "string",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"any", "comparable", "true", "false", "nil", "iota",
	} {
		used[ident] = true
	}
}

var goastKnownGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "js": true,
	"linux": true, "netbsd": true, "openbsd": true, "plan9": true,
	"solaris": true, "wasip1": true, "windows": true,
}

var goastUnixGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "linux": true,
	"netbsd": true, "openbsd": true, "solaris": true,
}

var goastKnownGOARCH = map[string]bool{
	"386": true, "amd64": true, "arm": true, "arm64": true,
	"loong64": true, "mips": true, "mips64": true, "mips64le": true,
	"mipsle": true, "ppc64": true, "ppc64le": true, "riscv64": true,
	"s390x": true, "wasm": true,
}

func extractGoastBuildConstraint(src []byte) (constraint.Expr, []string) {
	if len(src) == 0 {
		return nil, nil
	}
	var directives []string
	var goBuildExpr constraint.Expr
	var plusBuildExpr constraint.Expr

	for _, line := range strings.Split(string(src), "\n") {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "//go:build ") {
			directives = append(directives, trim)
			if expr, err := constraint.Parse(trim); err == nil {
				goBuildExpr = expr
			}
		} else if strings.HasPrefix(trim, "// +build ") {
			directives = append(directives, trim)
			if expr, err := constraint.Parse(trim); err == nil {
				if plusBuildExpr == nil {
					plusBuildExpr = expr
				} else {
					plusBuildExpr = &constraint.AndExpr{X: plusBuildExpr, Y: expr}
				}
			}
		} else if trim != "" && !strings.HasPrefix(trim, "//") && !strings.HasPrefix(trim, "/*") {
			break
		}
	}
	if goBuildExpr != nil {
		return goBuildExpr, directives
	}
	return plusBuildExpr, directives
}

func collectGoastConstraintTags(expr constraint.Expr, out map[string]bool) {
	if expr == nil {
		return
	}
	switch e := expr.(type) {
	case *constraint.TagExpr:
		out[e.Tag] = true
	case *constraint.NotExpr:
		collectGoastConstraintTags(e.X, out)
	case *constraint.AndExpr:
		collectGoastConstraintTags(e.X, out)
		collectGoastConstraintTags(e.Y, out)
	case *constraint.OrExpr:
		collectGoastConstraintTags(e.X, out)
		collectGoastConstraintTags(e.Y, out)
	}
}

func goastBuildTagsCompatible(targetSrc, otherSrc []byte) bool {
	otherExpr, _ := extractGoastBuildConstraint(otherSrc)
	if otherExpr == nil {
		return true
	}
	targetExpr, _ := extractGoastBuildConstraint(targetSrc)

	otherTags := map[string]bool{}
	collectGoastConstraintTags(otherExpr, otherTags)
	targetTags := map[string]bool{}
	collectGoastConstraintTags(targetExpr, targetTags)

	if otherTags["ignore"] && !targetTags["ignore"] {
		return false
	}

	if targetExpr == nil {
		return otherExpr.Eval(func(tag string) bool {
			if tag == runtime.GOOS || tag == runtime.GOARCH {
				return true
			}
			if tag == "unix" {
				return goastUnixGOOS[runtime.GOOS]
			}
			if tag == "cgo" || strings.HasPrefix(tag, "go1.") {
				return true
			}
			return false
		})
	}

	allTags := map[string]bool{}
	for k := range otherTags {
		allTags[k] = true
	}
	for k := range targetTags {
		allTags[k] = true
	}

	var osChoices []string
	var archChoices []string
	var customTags []string
	for k := range allTags {
		switch {
		case goastKnownGOOS[k]:
			osChoices = append(osChoices, k)
		case goastKnownGOARCH[k]:
			archChoices = append(archChoices, k)
		case k != "unix" && k != "cgo" && k != "ignore" && !strings.HasPrefix(k, "go1."):
			customTags = append(customTags, k)
		}
	}
	osChoices = append(osChoices, "_other_os")
	archChoices = append(archChoices, "_other_arch")
	if len(customTags) > 6 {
		return true
	}

	combos := 1 << len(customTags)
	for _, osName := range osChoices {
		for _, archName := range archChoices {
			for mask := 0; mask < combos; mask++ {
				env := func(tag string) bool {
					if tag == osName || tag == archName {
						return true
					}
					if tag == "unix" {
						return goastUnixGOOS[osName]
					}
					if tag == "cgo" || strings.HasPrefix(tag, "go1.") {
						return true
					}
					for i, ct := range customTags {
						if tag == ct {
							return (mask & (1 << i)) != 0
						}
					}
					return false
				}
				if targetExpr.Eval(env) && otherExpr.Eval(env) {
					return true
				}
			}
		}
	}
	return false
}

func extractGoastTypeParams(fset *token.FileSet, src []byte, tp *ast.FieldList) (string, string, []string, []string) {
	if tp == nil || len(tp.List) == 0 {
		return "", "", nil, nil
	}
	var declParts []string
	var useParts []string
	var names []string
	var constraints []string
	for _, field := range tp.List {
		cStr := strings.TrimSpace(exprString(fset, src, field.Type))
		if cStr == "" {
			cStr = "any"
		}
		var group []string
		for _, n := range field.Names {
			if n != nil && n.Name != "" {
				group = append(group, n.Name)
				useParts = append(useParts, n.Name)
				names = append(names, n.Name)
				constraints = append(constraints, cStr)
			}
		}
		if len(group) > 0 {
			declParts = append(declParts, strings.Join(group, ", ")+" "+cStr)
		}
	}
	if len(declParts) == 0 || len(useParts) == 0 {
		return "", "", nil, nil
	}
	return "[" + strings.Join(declParts, ", ") + "]", "[" + strings.Join(useParts, ", ") + "]", names, constraints
}

func buildGoastWitnessType(constraintExpr string, localInterfaces map[string]bool) string {
	c := strings.TrimSpace(constraintExpr)
	if c == "" || c == "any" || c == "interface{}" || c == "comparable" || c == "constraints.Ordered" || c == "cmp.Ordered" {
		return "int"
	}
	if c == "error" {
		return "error"
	}
	if parsed, err := parser.ParseExpr(c); err == nil && parsed != nil {
		switch x := parsed.(type) {
		case *ast.BinaryExpr:
			if x.Op == token.OR {
				left := strings.TrimSpace(formatGoastTypeExpr(x.X, ""))
				if left != "" && left != c {
					return buildGoastWitnessType(left, localInterfaces)
				}
			}
		case *ast.UnaryExpr:
			if x.Op == token.TILDE {
				inner := strings.TrimSpace(formatGoastTypeExpr(x.X, ""))
				if inner != "" && inner != c {
					return buildGoastWitnessType(inner, localInterfaces)
				}
			}
		case *ast.ParenExpr:
			inner := strings.TrimSpace(formatGoastTypeExpr(x.X, ""))
			if inner != "" && inner != c {
				return buildGoastWitnessType(inner, localInterfaces)
			}
		case *ast.InterfaceType:
			if x.Methods == nil || len(x.Methods.List) == 0 {
				return "int"
			}
			for _, f := range x.Methods.List {
				if len(f.Names) == 0 {
					elemStr := strings.TrimSpace(formatGoastTypeExpr(f.Type, ""))
					if elemStr != "" && elemStr != c {
						return buildGoastWitnessType(elemStr, localInterfaces)
					}
				}
			}
			return c
		case *ast.FuncType, *ast.ChanType, *ast.StructType, *ast.ArrayType, *ast.MapType, *ast.StarExpr:
			return c
		}
	}
	c = strings.TrimPrefix(c, "~")
	switch c {
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"float32", "float64", "string", "bool", "byte", "rune", "[]byte":
		return c
	case "fmt.Stringer":
		return "time.Duration"
	case "io.Reader":
		return "*bytes.Reader"
	case "io.Writer":
		return "*bytes.Buffer"
	}
	if strings.HasPrefix(c, "*") || strings.HasPrefix(c, "[]") || strings.HasPrefix(c, "map[") ||
		strings.HasPrefix(c, "func(") || strings.HasPrefix(c, "chan ") ||
		strings.HasPrefix(c, "<-chan ") || strings.HasPrefix(c, "chan<- ") ||
		strings.HasPrefix(c, "struct{") {
		return c
	}
	if localInterfaces != nil && localInterfaces[c] {
		return c
	}
	return "int"
}

func rewriteGoastTypeExpr(expr ast.Expr, rewriteIdent func(string) ast.Expr, rewriteSelector func(pkg, sel string) ast.Expr) ast.Expr {
	if expr == nil {
		return nil
	}
	switch e := expr.(type) {
	case *ast.Ident:
		if rewriteIdent != nil {
			if rep := rewriteIdent(e.Name); rep != nil {
				return rep
			}
		}
		return e
	case *ast.SelectorExpr:
		if id, ok := e.X.(*ast.Ident); ok && rewriteSelector != nil {
			if rep := rewriteSelector(id.Name, e.Sel.Name); rep != nil {
				return rep
			}
		}
		return e
	case *ast.StarExpr:
		e.X = rewriteGoastTypeExpr(e.X, rewriteIdent, rewriteSelector)
		return e
	case *ast.ParenExpr:
		e.X = rewriteGoastTypeExpr(e.X, rewriteIdent, rewriteSelector)
		return e
	case *ast.ArrayType:
		e.Elt = rewriteGoastTypeExpr(e.Elt, rewriteIdent, rewriteSelector)
		return e
	case *ast.MapType:
		e.Key = rewriteGoastTypeExpr(e.Key, rewriteIdent, rewriteSelector)
		e.Value = rewriteGoastTypeExpr(e.Value, rewriteIdent, rewriteSelector)
		return e
	case *ast.ChanType:
		e.Value = rewriteGoastTypeExpr(e.Value, rewriteIdent, rewriteSelector)
		return e
	case *ast.Ellipsis:
		e.Elt = rewriteGoastTypeExpr(e.Elt, rewriteIdent, rewriteSelector)
		return e
	case *ast.IndexExpr:
		e.X = rewriteGoastTypeExpr(e.X, rewriteIdent, rewriteSelector)
		e.Index = rewriteGoastTypeExpr(e.Index, rewriteIdent, rewriteSelector)
		return e
	case *ast.IndexListExpr:
		e.X = rewriteGoastTypeExpr(e.X, rewriteIdent, rewriteSelector)
		for i, idx := range e.Indices {
			e.Indices[i] = rewriteGoastTypeExpr(idx, rewriteIdent, rewriteSelector)
		}
		return e
	case *ast.FuncType:
		if e.Params != nil {
			for _, f := range e.Params.List {
				f.Type = rewriteGoastTypeExpr(f.Type, rewriteIdent, rewriteSelector)
			}
		}
		if e.Results != nil {
			for _, f := range e.Results.List {
				f.Type = rewriteGoastTypeExpr(f.Type, rewriteIdent, rewriteSelector)
			}
		}
		return e
	case *ast.StructType:
		if e.Fields != nil {
			for _, f := range e.Fields.List {
				f.Type = rewriteGoastTypeExpr(f.Type, rewriteIdent, rewriteSelector)
			}
		}
		return e
	default:
		return expr
	}
}

func formatGoastTypeExpr(expr ast.Expr, fallback string) string {
	var buf bytes.Buffer
	if err := format.Node(&buf, token.NewFileSet(), expr); err != nil {
		return fallback
	}
	return strings.TrimSpace(buf.String())
}

func substituteGoastTypeExpr(exprStr string, subst map[string]string) string {
	if len(subst) == 0 || strings.TrimSpace(exprStr) == "" {
		return exprStr
	}
	parsed, err := parser.ParseExpr(exprStr)
	if err != nil || parsed == nil {
		return exprStr
	}
	rewritten := rewriteGoastTypeExpr(parsed, func(name string) ast.Expr {
		rep, ok := subst[name]
		if !ok || rep == "" {
			return nil
		}
		if repExpr, pErr := parser.ParseExpr(rep); pErr == nil && repExpr != nil {
			return repExpr
		}
		return ast.NewIdent(rep)
	}, nil)
	return formatGoastTypeExpr(rewritten, exprStr)
}

func rewriteGoastFuncSig(mSig string, rewriteIdent func(string) ast.Expr, rewriteSelector func(pkg, sel string) ast.Expr) string {
	parenIdx := strings.IndexByte(mSig, '(')
	if parenIdx <= 0 {
		return mSig
	}
	mName := strings.TrimSpace(mSig[:parenIdx])
	parsed, err := parser.ParseExpr("func" + mSig[parenIdx:])
	if err != nil {
		return mSig
	}
	fnType, ok := parsed.(*ast.FuncType)
	if !ok {
		return mSig
	}
	rewriteGoastTypeExpr(fnType, rewriteIdent, rewriteSelector)
	formatted := formatGoastTypeExpr(fnType, "func"+mSig[parenIdx:])
	return mName + strings.TrimPrefix(formatted, "func")
}

func substituteGoastMethodSig(mSig string, subst map[string]string) string {
	if len(subst) == 0 {
		return mSig
	}
	return rewriteGoastFuncSig(mSig, func(name string) ast.Expr {
		rep, ok := subst[name]
		if !ok || rep == "" {
			return nil
		}
		if repExpr, err := parser.ParseExpr(rep); err == nil && repExpr != nil {
			return repExpr
		}
		return ast.NewIdent(rep)
	}, nil)
}

func qualifyGoastMethodSig(mSig string, pkgName string, definedTypes map[string]bool) string {
	if pkgName == "" || len(definedTypes) == 0 {
		return mSig
	}
	return rewriteGoastFuncSig(mSig, func(name string) ast.Expr {
		if definedTypes[name] && ast.IsExported(name) {
			return &ast.SelectorExpr{X: ast.NewIdent(pkgName), Sel: ast.NewIdent(name)}
		}
		return nil
	}, nil)
}

func remapGoastMethodSigAliases(mSig string, aliasRemap map[string]string) string {
	if len(aliasRemap) == 0 {
		return mSig
	}
	return rewriteGoastFuncSig(mSig, nil, func(pkg, sel string) ast.Expr {
		if rep, ok := aliasRemap[pkg]; ok && rep != "" && rep != pkg {
			return &ast.SelectorExpr{X: ast.NewIdent(rep), Sel: ast.NewIdent(sel)}
		}
		return nil
	})
}

func splitGoastEmbeddedExpr(fset *token.FileSet, src []byte, expr ast.Expr) (string, string, []string) {
	var args []string
	cur := expr
	if idx, ok := cur.(*ast.IndexExpr); ok {
		args = []string{strings.TrimSpace(exprString(fset, src, idx.Index))}
		cur = idx.X
	} else if idxList, ok := cur.(*ast.IndexListExpr); ok {
		for _, item := range idxList.Indices {
			args = append(args, strings.TrimSpace(exprString(fset, src, item)))
		}
		cur = idxList.X
	}
	switch base := cur.(type) {
	case *ast.Ident:
		return "", base.Name, args
	case *ast.SelectorExpr:
		if pkgID, ok := base.X.(*ast.Ident); ok && base.Sel != nil {
			return pkgID.Name, base.Sel.Name, args
		}
	}
	return "", strings.TrimSpace(exprString(fset, src, cur)), args
}

func extractGoastSigParamNames(sigRest string) []string {
	parsed, err := parser.ParseExpr("func" + sigRest)
	if err != nil {
		return nil
	}
	fnType, ok := parsed.(*ast.FuncType)
	if !ok {
		return nil
	}
	var names []string
	collectList := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, f := range fl.List {
			for _, id := range f.Names {
				if id != nil && id.Name != "" && id.Name != "_" {
					names = append(names, id.Name)
				}
			}
		}
	}
	collectList(fnType.Params)
	collectList(fnType.Results)
	return names
}

func pickSafeGoastReceiverIdent(typeName string, forbidden map[string]bool) string {
	preferred := receiverIdentForType(typeName)
	if !forbidden[preferred] {
		return preferred
	}
	for _, cand := range []string{"recv", "self", "v", "x"} {
		if !forbidden[cand] {
			return cand
		}
	}
	for i := 2; ; i++ {
		cand := fmt.Sprintf("%s%d", preferred, i)
		if !forbidden[cand] {
			return cand
		}
	}
}
