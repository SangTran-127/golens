package refactor

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/build/constraint"
	"go/format"
	"go/parser"
	"go/token"
	"path"
	"runtime"
	"strings"
)

type requiredImportSpec struct {
	Alias string
	Path  string
}

func defaultImportIdentifier(impPath string) string {
	trimmed := strings.Trim(strings.TrimSpace(impPath), `"`)
	if trimmed == "" {
		return ""
	}
	base := path.Base(trimmed)
	if len(base) >= 2 && base[0] == 'v' {
		allDigits := true
		for i := 1; i < len(base); i++ {
			if base[i] < '0' || base[i] > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			parent := path.Base(path.Dir(trimmed))
			if parent != "." && parent != "/" && parent != "" {
				return parent
			}
		}
	}
	return base
}

func ensureRequiredImports(src string, required []string) string {
	if len(required) == 0 {
		return src
	}
	specs := make([]requiredImportSpec, 0, len(required))
	for _, req := range required {
		if strings.TrimSpace(req) == "" {
			continue
		}
		specs = append(specs, requiredImportSpec{Path: req})
	}
	return ensureRequiredImportSpecs(src, specs)
}

func ensureRequiredImportSpecs(src string, required []requiredImportSpec) string {
	if len(required) == 0 {
		return src
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "updated.go", []byte(src), parser.ParseComments)
	if err != nil || file == nil {
		return src
	}

	type impBinding struct {
		path string
		name string
	}
	existingDefaultPath := map[string]bool{}
	var existingBindings []impBinding
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.Trim(imp.Path.Value, `"`)
		name := ""
		if imp.Name != nil {
			name = imp.Name.Name
		}
		existingBindings = append(existingBindings, impBinding{path: p, name: name})
		if name == "" || name == defaultImportIdentifier(p) {
			existingDefaultPath[p] = true
		}
	}

	seenMissing := map[string]bool{}
	var missing []requiredImportSpec
	for _, req := range required {
		p := strings.Trim(strings.TrimSpace(req.Path), `"`)
		if p == "" {
			continue
		}
		alias := strings.TrimSpace(req.Alias)
		key := alias + "|" + p
		if seenMissing[key] {
			continue
		}
		satisfied := false
		if alias == "" {
			satisfied = existingDefaultPath[p]
		} else {
			for _, b := range existingBindings {
				if b.path == p && (b.name == alias || (b.name == "" && alias == defaultImportIdentifier(p))) {
					satisfied = true
					break
				}
			}
		}
		if !satisfied {
			seenMissing[key] = true
			missing = append(missing, requiredImportSpec{Alias: alias, Path: p})
		}
	}
	if len(missing) == 0 {
		return src
	}

	formatSpec := func(m requiredImportSpec) string {
		if m.Alias != "" && m.Alias != defaultImportIdentifier(m.Path) {
			return fmt.Sprintf("%s %q", m.Alias, m.Path)
		}
		return fmt.Sprintf("%q", m.Path)
	}

	var firstImportDecl *ast.GenDecl
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if ok && gd.Tok == token.IMPORT {
			firstImportDecl = gd
			break
		}
	}

	if firstImportDecl != nil {
		if firstImportDecl.Lparen.IsValid() && firstImportDecl.Rparen.IsValid() {
			rparenOff := fset.Position(firstImportDecl.Rparen).Offset
			if rparenOff >= 0 && rparenOff <= len(src) {
				var addBuf strings.Builder
				if rparenOff > 0 && src[rparenOff-1] != '\n' {
					addBuf.WriteByte('\n')
				}
				for _, m := range missing {
					addBuf.WriteString("\t" + formatSpec(m) + "\n")
				}
				return src[:rparenOff] + addBuf.String() + src[rparenOff:]
			}
		}
		startOff := fset.Position(firstImportDecl.Pos()).Offset
		endOff := fset.Position(firstImportDecl.End()).Offset
		if startOff >= 0 && endOff >= startOff && endOff <= len(src) {
			var specs []string
			for _, spec := range firstImportDecl.Specs {
				is, ok := spec.(*ast.ImportSpec)
				if !ok || is.Path == nil {
					continue
				}
				if is.Name != nil && is.Name.Name != "" {
					specs = append(specs, fmt.Sprintf("\t%s %s", is.Name.Name, is.Path.Value))
				} else {
					specs = append(specs, fmt.Sprintf("\t%s", is.Path.Value))
				}
			}
			for _, m := range missing {
				specs = append(specs, "\t"+formatSpec(m))
			}
			replacement := "import (\n" + strings.Join(specs, "\n") + "\n)"
			return src[:startOff] + replacement + src[endOff:]
		}
	}

	if file.Name != nil {
		pkgEndOff := fset.Position(file.Name.End()).Offset
		if pkgEndOff >= 0 && pkgEndOff <= len(src) {
			for pkgEndOff < len(src) && src[pkgEndOff] != '\n' {
				pkgEndOff++
			}
			var importBlock strings.Builder
			if len(missing) == 1 {
				importBlock.WriteString("\n\nimport " + formatSpec(missing[0]))
			} else {
				importBlock.WriteString("\n\nimport (\n")
				for _, m := range missing {
					importBlock.WriteString("\t" + formatSpec(m) + "\n")
				}
				importBlock.WriteString(")")
			}
			return src[:pkgEndOff] + importBlock.String() + src[pkgEndOff:]
		}
	}

	return src
}

var knownBuildGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "js": true,
	"linux": true, "netbsd": true, "openbsd": true, "plan9": true,
	"solaris": true, "wasip1": true, "windows": true,
}

var knownUnixGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "linux": true,
	"netbsd": true, "openbsd": true, "solaris": true,
}

var knownBuildGOARCH = map[string]bool{
	"386": true, "amd64": true, "arm": true, "arm64": true,
	"loong64": true, "mips": true, "mips64": true, "mips64le": true,
	"mipsle": true, "ppc64": true, "ppc64le": true, "riscv64": true,
	"s390x": true, "wasm": true,
}

func extractFileBuildConstraint(src []byte) (constraint.Expr, []string) {
	if len(src) == 0 {
		return nil, nil
	}
	var directives []string
	var goBuildExpr constraint.Expr
	var plusBuildExpr constraint.Expr

	lines := strings.Split(string(src), "\n")
	for _, l := range lines {
		trim := strings.TrimSpace(l)
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

func collectConstraintTags(expr constraint.Expr, out map[string]bool) {
	if expr == nil {
		return
	}
	switch e := expr.(type) {
	case *constraint.TagExpr:
		out[e.Tag] = true
	case *constraint.NotExpr:
		collectConstraintTags(e.X, out)
	case *constraint.AndExpr:
		collectConstraintTags(e.X, out)
		collectConstraintTags(e.Y, out)
	case *constraint.OrExpr:
		collectConstraintTags(e.X, out)
		collectConstraintTags(e.Y, out)
	}
}

func buildTagsCompatible(targetSrc, otherSrc []byte) bool {
	otherExpr, _ := extractFileBuildConstraint(otherSrc)
	if otherExpr == nil {
		return true
	}
	targetExpr, _ := extractFileBuildConstraint(targetSrc)

	otherTags := map[string]bool{}
	collectConstraintTags(otherExpr, otherTags)
	targetTags := map[string]bool{}
	collectConstraintTags(targetExpr, targetTags)

	if otherTags["ignore"] && !targetTags["ignore"] {
		return false
	}

	if targetExpr == nil {
		return otherExpr.Eval(func(tag string) bool {
			if tag == runtime.GOOS || tag == runtime.GOARCH {
				return true
			}
			if tag == "unix" {
				return knownUnixGOOS[runtime.GOOS]
			}
			if tag == "cgo" {
				return true
			}
			if strings.HasPrefix(tag, "go1.") {
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
	for k := range allTags {
		if knownBuildGOOS[k] {
			osChoices = append(osChoices, k)
		}
	}
	osChoices = append(osChoices, "_other_os")

	var archChoices []string
	for k := range allTags {
		if knownBuildGOARCH[k] {
			archChoices = append(archChoices, k)
		}
	}
	archChoices = append(archChoices, "_other_arch")

	var customTags []string
	for k := range allTags {
		if knownBuildGOOS[k] || knownBuildGOARCH[k] || k == "unix" {
			continue
		}
		customTags = append(customTags, k)
	}
	if len(customTags) > 10 {
		customTags = customTags[:10]
	}

	limit := 1 << len(customTags)
	for _, osTag := range osChoices {
		for _, archTag := range archChoices {
			for mask := 0; mask < limit; mask++ {
				env := map[string]bool{}
				for idx, ct := range customTags {
					env[ct] = (mask & (1 << idx)) != 0
				}
				eval := func(tag string) bool {
					if knownBuildGOOS[tag] {
						return tag == osTag
					}
					if knownBuildGOARCH[tag] {
						return tag == archTag
					}
					if tag == "unix" {
						return knownUnixGOOS[osTag]
					}
					if knownBuildGOOS[tag] {
						return false
					}
					return env[tag]
				}
				if targetExpr.Eval(eval) && otherExpr.Eval(eval) {
					return true
				}
			}
		}
	}
	return false
}

func extractTypeParamInfo(fset *token.FileSet, src []byte, tp *ast.FieldList) (string, string, []string, map[string]string) {
	if tp == nil || len(tp.List) == 0 {
		return "", "", nil, nil
	}
	var declParts []string
	var useParts []string
	var allNames []string
	constraints := map[string]string{}
	for _, field := range tp.List {
		cStr := strings.TrimSpace(exprTextFromAST(fset, src, field.Type))
		if cStr == "" {
			cStr = "any"
		}
		var names []string
		for _, n := range field.Names {
			if n != nil && n.Name != "" {
				names = append(names, n.Name)
				useParts = append(useParts, n.Name)
				allNames = append(allNames, n.Name)
				constraints[n.Name] = cStr
			}
		}
		if len(names) > 0 {
			declParts = append(declParts, strings.Join(names, ", ")+" "+cStr)
		}
	}
	if len(declParts) == 0 || len(useParts) == 0 {
		return "", "", nil, nil
	}
	return "[" + strings.Join(declParts, ", ") + "]", "[" + strings.Join(useParts, ", ") + "]", allNames, constraints
}

func buildGenericWitnessArgs(fset *token.FileSet, src []byte, tp *ast.FieldList, localInterfaces map[string]bool) ([]string, map[string]string) {
	if tp == nil || len(tp.List) == 0 {
		return nil, nil
	}
	var args []string
	subst := map[string]string{}
	for _, field := range tp.List {
		cStr := strings.TrimSpace(exprTextFromAST(fset, src, field.Type))
		witness := witnessTypeForConstraint(cStr, localInterfaces)
		for _, n := range field.Names {
			if n != nil && n.Name != "" {
				args = append(args, witness)
				subst[n.Name] = witness
			}
		}
	}
	return args, subst
}

func witnessTypeForConstraint(constraintExpr string, localInterfaces map[string]bool) string {
	c := strings.TrimSpace(constraintExpr)
	if c == "" || c == "any" || c == "interface{}" || c == "comparable" || c == "constraints.Ordered" || c == "cmp.Ordered" {
		return "int"
	}
	if c == "error" {
		return "error"
	}
	if strings.Contains(c, "|") {
		parts := strings.Split(c, "|")
		for _, part := range parts {
			term := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(part), "~"))
			if term != "" {
				return witnessTypeForConstraint(term, localInterfaces)
			}
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
	if strings.HasPrefix(c, "*") || strings.HasPrefix(c, "[]") || strings.HasPrefix(c, "map[") {
		return c
	}
	if localInterfaces != nil && localInterfaces[c] {
		return c
	}
	return "int"
}

func substituteTypeExprString(exprStr string, subst map[string]string) string {
	if len(subst) == 0 || strings.TrimSpace(exprStr) == "" {
		return exprStr
	}
	parsed, err := parser.ParseExpr(exprStr)
	if err != nil || parsed == nil {
		return exprStr
	}
	var rewrite func(node ast.Node)
	rewrite = func(node ast.Node) {
		switch n := node.(type) {
		case *ast.StarExpr:
			if id, ok := n.X.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.X = &ast.Ident{Name: rep}
					return
				}
			}
			rewrite(n.X)
		case *ast.ArrayType:
			if id, ok := n.Elt.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Elt = &ast.Ident{Name: rep}
				}
			} else {
				rewrite(n.Elt)
			}
		case *ast.MapType:
			if id, ok := n.Key.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Key = &ast.Ident{Name: rep}
				}
			} else {
				rewrite(n.Key)
			}
			if id, ok := n.Value.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Value = &ast.Ident{Name: rep}
				}
			} else {
				rewrite(n.Value)
			}
		case *ast.ChanType:
			if id, ok := n.Value.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Value = &ast.Ident{Name: rep}
					return
				}
			}
			rewrite(n.Value)
		case *ast.IndexExpr:
			if id, ok := n.Index.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Index = &ast.Ident{Name: rep}
				}
			} else {
				rewrite(n.Index)
			}
		case *ast.IndexListExpr:
			for i, idx := range n.Indices {
				if id, ok := idx.(*ast.Ident); ok {
					if rep, exists := subst[id.Name]; exists {
						n.Indices[i] = &ast.Ident{Name: rep}
						continue
					}
				}
				rewrite(idx)
			}
		case *ast.Ellipsis:
			if id, ok := n.Elt.(*ast.Ident); ok {
				if rep, exists := subst[id.Name]; exists {
					n.Elt = &ast.Ident{Name: rep}
					return
				}
			}
			rewrite(n.Elt)
		case *ast.FuncType:
			if n.Params != nil {
				for _, f := range n.Params.List {
					if id, ok := f.Type.(*ast.Ident); ok {
						if rep, exists := subst[id.Name]; exists {
							f.Type = &ast.Ident{Name: rep}
							continue
						}
					}
					rewrite(f.Type)
				}
			}
			if n.Results != nil {
				for _, f := range n.Results.List {
					if id, ok := f.Type.(*ast.Ident); ok {
						if rep, exists := subst[id.Name]; exists {
							f.Type = &ast.Ident{Name: rep}
							continue
						}
					}
					rewrite(f.Type)
				}
			}
		}
	}
	if id, ok := parsed.(*ast.Ident); ok {
		if rep, exists := subst[id.Name]; exists {
			return rep
		}
	}
	rewrite(parsed)
	var buf bytes.Buffer
	if err := format.Node(&buf, token.NewFileSet(), parsed); err != nil {
		return exprStr
	}
	return strings.TrimSpace(buf.String())
}

func exprTextFromAST(fset *token.FileSet, src []byte, expr ast.Expr) string {
	if expr == nil || fset == nil {
		return ""
	}
	start := fset.Position(expr.Pos()).Offset
	end := fset.Position(expr.End()).Offset
	if start >= 0 && end >= start && end <= len(src) {
		return string(src[start:end])
	}
	var buf bytes.Buffer
	_ = format.Node(&buf, fset, expr)
	return buf.String()
}

func collectFileImportAliases(file *ast.File) map[string]string {
	aliases := map[string]string{}
	if file == nil {
		return aliases
	}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		impPath := strings.Trim(imp.Path.Value, `"`)
		if impPath == "" {
			continue
		}
		alias := ""
		if imp.Name != nil && imp.Name.Name != "" {
			if imp.Name.Name == "_" || imp.Name.Name == "." {
				continue
			}
			alias = imp.Name.Name
		} else {
			alias = defaultImportIdentifier(impPath)
		}
		if alias != "" {
			aliases[alias] = impPath
		}
	}
	return aliases
}

func addReservedFileImports(used map[string]bool, file *ast.File) {
	if used == nil || file == nil {
		return
	}
	for alias := range collectFileImportAliases(file) {
		used[alias] = true
	}
}

func addReservedPredeclaredTypes(used map[string]bool) {
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

func collectUsedImportSpecsFromAST(files []*ast.File, code string, stdlib map[string]string) []requiredImportSpec {
	combined := map[string]string{}
	for _, f := range files {
		for alias, p := range collectFileImportAliases(f) {
			if _, exists := combined[alias]; !exists {
				combined[alias] = p
			}
		}
	}

	expr, err := parser.ParseFile(token.NewFileSet(), "snippet.go", "package p\n"+code, parser.SkipObjectResolution)
	referencedPkgIdents := map[string]bool{}
	if err == nil && expr != nil {
		ast.Inspect(expr, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if id, ok := sel.X.(*ast.Ident); ok && id.Name != "" {
				referencedPkgIdents[id.Name] = true
			}
			return true
		})
	} else {
		for alias := range combined {
			if strings.Contains(code, alias+".") {
				referencedPkgIdents[alias] = true
			}
		}
		for alias := range stdlib {
			if strings.Contains(code, alias+".") {
				referencedPkgIdents[alias] = true
			}
		}
	}

	var specs []requiredImportSpec
	seen := map[string]bool{}
	for ident := range referencedPkgIdents {
		if p, ok := combined[ident]; ok {
			key := ident + "|" + p
			if !seen[key] {
				seen[key] = true
				specs = append(specs, requiredImportSpec{Alias: ident, Path: p})
			}
			continue
		}
		if p, ok := stdlib[ident]; ok {
			key := "|" + p
			if !seen[key] {
				seen[key] = true
				specs = append(specs, requiredImportSpec{Path: p})
			}
		}
	}
	return specs
}
