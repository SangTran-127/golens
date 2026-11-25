package goast

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

func findTargetFuncForTest(fset *token.FileSet, f *ast.File, offset int) *ast.FuncDecl {
	tf := fset.File(f.Pos())
	if tf == nil {
		return nil
	}
	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)
	caretLine := fset.Position(pos).Line

	var funcs []*ast.FuncDecl
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name != nil {
			funcs = append(funcs, fn)
		}
	}
	if len(funcs) == 0 {
		return nil
	}

	for _, fn := range funcs {
		if pos >= fn.Pos() && pos <= fn.End() {
			return fn
		}
	}

	for _, fn := range funcs {
		startLine := fset.Position(fn.Pos()).Line
		nameLine := fset.Position(fn.Name.Pos()).Line
		endLine := fset.Position(fn.End()).Line
		if caretLine >= startLine && caretLine <= endLine || caretLine == nameLine {
			return fn
		}
	}

	best := funcs[0]
	bestDist := absInt(fset.Position(best.Name.Pos()).Line - caretLine)
	for _, fn := range funcs[1:] {
		d := absInt(fset.Position(fn.Name.Pos()).Line - caretLine)
		if d < bestDist {
			best = fn
			bestDist = d
		}
	}
	return best
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func extractReceiverTypeInfo(fset *token.FileSet, src []byte, expr ast.Expr) (string, bool, []string) {
	isPtr := false
	cur := expr
	if star, ok := cur.(*ast.StarExpr); ok {
		isPtr = true
		cur = star.X
	}
	var typeArgs []string
	switch x := cur.(type) {
	case *ast.Ident:
		return x.Name, isPtr, nil
	case *ast.IndexExpr:
		typeArgs = []string{strings.TrimSpace(exprString(fset, src, x.Index))}
		if id, ok := x.X.(*ast.Ident); ok {
			return id.Name, isPtr, typeArgs
		}
	case *ast.IndexListExpr:
		for _, item := range x.Indices {
			typeArgs = append(typeArgs, strings.TrimSpace(exprString(fset, src, item)))
		}
		if id, ok := x.X.(*ast.Ident); ok {
			return id.Name, isPtr, typeArgs
		}
	}
	return "", isPtr, typeArgs
}

func collectTestPackageTypeDefs(filePath string, curFile *ast.File, curFset *token.FileSet, curSrc []byte, pkgName string) (map[string]testgenTypeDef, map[string]bool) {
	defs := map[string]testgenTypeDef{}
	ifaces := map[string]bool{}

	recordFile := func(f *ast.File, fset *token.FileSet, fSrc []byte) {
		if f == nil {
			return
		}
		for _, decl := range f.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, spec := range gd.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil {
					continue
				}
				name := ts.Name.Name
				td := testgenTypeDef{name: name}
				if ts.TypeParams != nil {
					_, _, tpNames, tpConstraints := extractGoastTypeParams(fset, fSrc, ts.TypeParams)
					for i, tpName := range tpNames {
						cExpr := "any"
						if i < len(tpConstraints) && tpConstraints[i] != "" {
							cExpr = tpConstraints[i]
						}
						td.typeParams = append(td.typeParams, testgenTypeParam{name: tpName, constraint: cExpr})
					}
				}
				if ts.Assign.IsValid() {
					td.kind = "alias"
					td.targetExpr = strings.TrimSpace(exprString(fset, fSrc, ts.Type))
					defs[name] = td
					continue
				}
				switch tx := ts.Type.(type) {
				case *ast.StructType:
					td.kind = "struct"
				case *ast.InterfaceType:
					isConstraint, firstTerm := inspectTestInterfaceType(fset, fSrc, tx)
					if isConstraint {
						td.kind = "constraint"
						td.targetExpr = firstTerm
					} else {
						td.kind = "interface"
						ifaces[name] = true
					}
				case *ast.FuncType:
					td.kind = "func"
				case *ast.ArrayType:
					if tx.Len == nil {
						td.kind = "slice"
					} else {
						td.kind = "array"
					}
				case *ast.MapType:
					td.kind = "map"
				case *ast.ChanType:
					td.kind = "chan"
				case *ast.StarExpr:
					td.kind = "ptr"
				case *ast.Ident:
					td.kind = "defined"
					td.targetExpr = tx.Name
				default:
					td.kind = "other"
				}
				defs[name] = td
			}
		}
	}

	recordFile(curFile, curFset, curSrc)

	if filePath != "" {
		dir := filepath.Dir(filePath)
		entries, err := os.ReadDir(dir)
		if err == nil {
			isCurrentTestFile := strings.HasSuffix(filepath.Base(filePath), testgenGoTestFileSuffix)
			absCur, _ := filepath.Abs(filePath)
			for _, ent := range entries {
				if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".go") {
					continue
				}
				if !isCurrentTestFile && strings.HasSuffix(ent.Name(), testgenGoTestFileSuffix) {
					continue
				}
				full := filepath.Join(dir, ent.Name())
				if absFull, aErr := filepath.Abs(full); aErr == nil && absFull == absCur {
					continue
				}
				sibSrc, rErr := os.ReadFile(full)
				if rErr != nil || !goastBuildTagsCompatible(curSrc, sibSrc) {
					continue
				}
				sibFset := token.NewFileSet()
				sibFile, pErr := parser.ParseFile(sibFset, full, sibSrc, 0)
				if pErr != nil || sibFile == nil || sibFile.Name == nil || sibFile.Name.Name != pkgName {
					continue
				}
				recordFile(sibFile, sibFset, sibSrc)
			}
		}
	}

	return defs, ifaces
}

func inspectTestInterfaceType(fset *token.FileSet, src []byte, iface *ast.InterfaceType) (bool, string) {
	if iface == nil || iface.Methods == nil || len(iface.Methods.List) == 0 {
		return false, ""
	}
	for _, f := range iface.Methods.List {
		if len(f.Names) > 0 {
			continue
		}
		switch t := f.Type.(type) {
		case *ast.UnaryExpr:
			if t.Op == token.TILDE {
				return true, strings.TrimSpace(exprString(fset, src, t.X))
			}
		case *ast.BinaryExpr:
			if t.Op == token.OR {
				return true, strings.TrimSpace(exprString(fset, src, t.X))
			}
		case *ast.Ident:
			if t.Name == "comparable" {
				return true, "int"
			}
			if isBuiltinTestType(t.Name) {
				return true, t.Name
			}
		}
	}
	return false, ""
}

func resolveTestTypeDef(typ string, defs map[string]testgenTypeDef) (testgenTypeDef, bool) {
	cur := strings.TrimSpace(typ)
	if idx := strings.IndexByte(cur, '['); idx > 0 {
		cur = strings.TrimSpace(cur[:idx])
	}
	visited := map[string]bool{}
	for depth := 0; depth < 16; depth++ {
		if cur == "" || visited[cur] {
			return testgenTypeDef{}, false
		}
		visited[cur] = true
		td, ok := defs[cur]
		if !ok {
			return testgenTypeDef{}, false
		}
		if td.kind == "alias" {
			next := strings.TrimSpace(td.targetExpr)
			if idx := strings.IndexByte(next, '['); idx > 0 {
				next = strings.TrimSpace(next[:idx])
			}
			if _, okNext := defs[next]; okNext {
				cur = next
				continue
			}
			return testgenTypeDef{name: td.name, kind: classifySyntacticTestType(td.targetExpr), targetExpr: td.targetExpr}, true
		}
		if td.kind == "defined" {
			if _, okNext := defs[td.targetExpr]; okNext {
				nextTd, found := resolveTestTypeDef(td.targetExpr, defs)
				if found {
					return testgenTypeDef{name: td.name, kind: nextTd.kind, targetExpr: td.targetExpr, typeParams: td.typeParams}, true
				}
			}
		}
		return td, true
	}
	return testgenTypeDef{}, false
}

func classifySyntacticTestType(typ string) string {
	t := strings.TrimSpace(typ)
	if parsed, err := parser.ParseExpr(t); err == nil && parsed != nil {
		for {
			p, ok := parsed.(*ast.ParenExpr)
			if !ok {
				break
			}
			parsed = p.X
		}
		switch x := parsed.(type) {
		case *ast.StructType:
			return "struct"
		case *ast.InterfaceType:
			return "interface"
		case *ast.FuncType:
			return "func"
		case *ast.ArrayType:
			if x.Len == nil {
				return "slice"
			}
			return "array"
		case *ast.MapType:
			return "map"
		case *ast.ChanType:
			return "chan"
		case *ast.StarExpr:
			return "ptr"
		}
	}
	if strings.HasPrefix(t, "[]") {
		return "slice"
	}
	if strings.HasPrefix(t, "map[") {
		return "map"
	}
	if strings.HasPrefix(t, "*") {
		return "ptr"
	}
	if strings.HasPrefix(t, "func(") {
		return "func"
	}
	if strings.HasPrefix(t, "chan ") || strings.HasPrefix(t, "<-chan ") || strings.HasPrefix(t, "chan<- ") {
		return "chan"
	}
	if t == "any" || t == "error" || strings.HasPrefix(t, "interface{") || strings.HasPrefix(t, "interface ") {
		return "interface"
	}
	if isBuiltinTestType(t) {
		return "basic"
	}
	return "other"
}

func isSimpleTestIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		if i == 0 {
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_') {
				return false
			}
		} else {
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_') {
				return false
			}
		}
	}
	return true
}

func isBuiltinTestType(s string) bool {
	switch strings.TrimSpace(s) {
	case "any", "bool", "byte", "comparable",
		"complex64", "complex128", "error",
		"float32", "float64",
		"int", "int8", "int16", "int32", "int64",
		"rune", "string",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr":
		return true
	}
	return false
}

func resolveTestWitnessType(constraintExpr string, typeDefs map[string]testgenTypeDef, localInterfaces map[string]bool, aliases map[string]string, forcedImports *[]goastImportSpec) string {
	c := strings.TrimSpace(constraintExpr)
	for depth := 0; depth < 8; depth++ {
		if td, ok := typeDefs[c]; ok && td.kind == "constraint" && td.targetExpr != "" {
			c = td.targetExpr
			continue
		}
		break
	}
	witness := buildGoastWitnessType(c, localInterfaces)
	switch witness {
	case "time.Duration":
		if p, exists := aliases["time"]; exists && p != "time" {
			safe := pickSafeTestIdent("stdtime", aliases, nil)
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: safe, Path: "time"})
			return safe + ".Duration"
		}
		*forcedImports = append(*forcedImports, goastImportSpec{Path: "time"})
	case "*bytes.Reader":
		if p, exists := aliases["bytes"]; exists && p != "bytes" {
			safe := pickSafeTestIdent("stdbytes", aliases, nil)
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: safe, Path: "bytes"})
			return "*" + safe + ".Reader"
		}
		*forcedImports = append(*forcedImports, goastImportSpec{Path: "bytes"})
	case "*bytes.Buffer":
		if p, exists := aliases["bytes"]; exists && p != "bytes" {
			safe := pickSafeTestIdent("stdbytes", aliases, nil)
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: safe, Path: "bytes"})
			return "*" + safe + ".Buffer"
		}
		*forcedImports = append(*forcedImports, goastImportSpec{Path: "bytes"})
	}
	return witness
}

func resolveStdPkgIdent(preferredAlias, pkgPath string, srcAliases, existingAliases map[string]string, usedTypeIdents map[string]bool, forcedImports *[]goastImportSpec) string {
	if existingAliases != nil {
		if bound, ok := existingAliases[preferredAlias]; ok && bound == pkgPath && (usedTypeIdents == nil || !usedTypeIdents[preferredAlias]) {
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: preferredAlias, Path: pkgPath})
			return preferredAlias
		}
	}
	conflict := false
	if srcAliases != nil {
		if bound, ok := srcAliases[preferredAlias]; ok && bound != pkgPath {
			conflict = true
		}
	}
	if existingAliases != nil {
		if bound, ok := existingAliases[preferredAlias]; ok && bound != pkgPath {
			conflict = true
		}
	}
	if usedTypeIdents != nil && usedTypeIdents[preferredAlias] {
		conflict = true
	}
	if !conflict {
		if preferredAlias == defaultGoastImportIdent(pkgPath) {
			*forcedImports = append(*forcedImports, goastImportSpec{Path: pkgPath})
		} else {
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: preferredAlias, Path: pkgPath})
		}
		return preferredAlias
	}
	for alias, p := range existingAliases {
		if p == pkgPath && (usedTypeIdents == nil || !usedTypeIdents[alias]) {
			*forcedImports = append(*forcedImports, goastImportSpec{Alias: alias, Path: pkgPath})
			return alias
		}
	}
	for alias, p := range srcAliases {
		if p == pkgPath && (usedTypeIdents == nil || !usedTypeIdents[alias]) {
			if existingBound, ok := existingAliases[alias]; !ok || existingBound == pkgPath {
				*forcedImports = append(*forcedImports, goastImportSpec{Alias: alias, Path: pkgPath})
				return alias
			}
		}
	}
	base := "std" + defaultGoastImportIdent(pkgPath)
	for i := 0; ; i++ {
		cand := base
		if i > 0 {
			cand = fmt.Sprintf("%s%d", base, i+1)
		}
		if srcAliases != nil {
			if _, ok := srcAliases[cand]; ok {
				continue
			}
		}
		if existingAliases != nil {
			if _, ok := existingAliases[cand]; ok {
				continue
			}
		}
		if usedTypeIdents != nil && usedTypeIdents[cand] {
			continue
		}
		*forcedImports = append(*forcedImports, goastImportSpec{Alias: cand, Path: pkgPath})
		return cand
	}
}

func pickSafeTestIdent(base string, mapA, mapB map[string]string) string {
	for i := 0; ; i++ {
		cand := base
		if i > 0 {
			cand = fmt.Sprintf("%s%d", base, i+1)
		}
		if mapA != nil {
			if _, ok := mapA[cand]; ok {
				continue
			}
		}
		if mapB != nil {
			if _, ok := mapB[cand]; ok {
				continue
			}
		}
		return cand
	}
}

func pickTestLocalVar(preferred string, fallbacks []string, forbidden map[string]bool) string {
	if preferred != "" && !forbidden[preferred] {
		return preferred
	}
	for _, f := range fallbacks {
		if f != "" && !forbidden[f] {
			return f
		}
	}
	base := preferred
	if base == "" {
		base = "v"
	}
	for i := 0; ; i++ {
		cand := fmt.Sprintf("%s%d", base, i)
		if !forbidden[cand] {
			return cand
		}
	}
}

func collectExprIdentsInto(exprStr string, out map[string]bool, includeSelectorPkg bool) {
	s := strings.TrimSpace(exprStr)
	if s == "" {
		return
	}
	parsed, err := parser.ParseExpr(s)
	if err != nil || parsed == nil {
		return
	}
	var walk func(ast.Node)
	walk = func(n ast.Node) {
		if n == nil {
			return
		}
		switch x := n.(type) {
		case *ast.Ident:
			if x.Name != "" {
				out[x.Name] = true
			}
		case *ast.SelectorExpr:
			if includeSelectorPkg {
				walk(x.X)
			} else if _, isPkgID := x.X.(*ast.Ident); !isPkgID {
				walk(x.X)
			}
		default:
			ast.Inspect(n, func(child ast.Node) bool {
				if child == n || child == nil {
					return true
				}
				switch c := child.(type) {
				case *ast.Ident:
					if c.Name != "" {
						out[c.Name] = true
					}
					return false
				case *ast.SelectorExpr:
					if includeSelectorPkg {
						walk(c.X)
					} else if _, isPkgID := c.X.(*ast.Ident); !isPkgID {
						walk(c.X)
					}
					return false
				}
				return true
			})
		}
	}
	walk(parsed)
}

func remapTestTypeSelectors(exprStr string, aliasRemap map[string]string) string {
	if len(aliasRemap) == 0 || strings.TrimSpace(exprStr) == "" {
		return exprStr
	}
	parsed, err := parser.ParseExpr(exprStr)
	if err != nil || parsed == nil {
		return exprStr
	}
	rewritten := rewriteGoastTypeExpr(parsed, nil, func(pkg, sel string) ast.Expr {
		if rep, ok := aliasRemap[pkg]; ok && rep != "" && rep != pkg {
			return &ast.SelectorExpr{X: ast.NewIdent(rep), Sel: ast.NewIdent(sel)}
		}
		return nil
	})
	return formatGoastTypeExpr(rewritten, exprStr)
}

func extractTestParams(fset *token.FileSet, src []byte, fl *ast.FieldList, typeSubst map[string]string, aliasRemap map[string]string, srcAliases map[string]string, usedFieldNames map[string]bool) []testParamField {
	var out []testParamField
	if fl == nil {
		return out
	}
	argIdx := 0
	used := make(map[string]bool, len(usedFieldNames)+4)
	for k, v := range usedFieldNames {
		used[k] = v
	}
	used["name"] = true
	used["skip"] = true
	used["want"] = true
	used["wantErr"] = true

	sanitizeName := func(raw string) string {
		n := strings.TrimSpace(raw)
		if n == "" || n == "_" || used[n] {
			for {
				cand := fmt.Sprintf("arg%d", argIdx)
				argIdx++
				if !used[cand] {
					used[cand] = true
					return cand
				}
			}
		}
		used[n] = true
		argIdx++
		return n
	}

	for _, field := range fl.List {
		isVariadic := false
		typStr := strings.TrimSpace(exprString(fset, src, field.Type))
		if ell, ok := field.Type.(*ast.Ellipsis); ok {
			isVariadic = true
			eltStr := strings.TrimSpace(exprString(fset, src, ell.Elt))
			typStr = "[]" + eltStr
		}
		if len(typeSubst) > 0 {
			typStr = substituteGoastTypeExpr(typStr, typeSubst)
		}
		isCtx, ctxAlias := isTestContextType(typStr, srcAliases)
		if len(aliasRemap) > 0 {
			typStr = remapTestTypeSelectors(typStr, aliasRemap)
		}

		if len(field.Names) == 0 {
			name := sanitizeName("")
			out = append(out, testParamField{
				name:         name,
				typeExpr:     typStr,
				isContext:    isCtx,
				contextAlias: ctxAlias,
				isVariadic:   isVariadic,
			})
		} else {
			for _, id := range field.Names {
				rawName := ""
				if id != nil {
					rawName = id.Name
				}
				name := sanitizeName(rawName)
				out = append(out, testParamField{
					name:         name,
					typeExpr:     typStr,
					isContext:    isCtx,
					contextAlias: ctxAlias,
					isVariadic:   isVariadic,
				})
			}
		}
	}
	return out
}

func isTestContextType(typStr string, srcAliases map[string]string) (bool, string) {
	parsed, err := parser.ParseExpr(strings.TrimSpace(typStr))
	if err != nil || parsed == nil {
		return false, ""
	}
	for {
		p, ok := parsed.(*ast.ParenExpr)
		if !ok {
			break
		}
		parsed = p.X
	}
	sel, ok := parsed.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Context" {
		return false, ""
	}
	pkgID, ok := sel.X.(*ast.Ident)
	if !ok || pkgID == nil {
		return false, ""
	}
	if srcAliases != nil {
		if bound, exists := srcAliases[pkgID.Name]; exists {
			if bound == "context" {
				return true, pkgID.Name
			}
			return false, ""
		}
	}
	if pkgID.Name == "context" {
		return true, "context"
	}
	return false, ""
}

func extractTestResults(fset *token.FileSet, src []byte, fl *ast.FieldList, typeSubst map[string]string, aliasRemap map[string]string, typeDefs map[string]testgenTypeDef) ([]testResultField, bool) {
	if fl == nil || len(fl.List) == 0 {
		return nil, false
	}
	var allTypes []string
	for _, field := range fl.List {
		typStr := strings.TrimSpace(exprString(fset, src, field.Type))
		if len(typeSubst) > 0 {
			typStr = substituteGoastTypeExpr(typStr, typeSubst)
		}
		if len(aliasRemap) > 0 {
			typStr = remapTestTypeSelectors(typStr, aliasRemap)
		}
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		for i := 0; i < count; i++ {
			allTypes = append(allTypes, typStr)
		}
	}
	hasErr := false
	if len(allTypes) > 0 && allTypes[len(allTypes)-1] == "error" {
		hasErr = true
		allTypes = allTypes[:len(allTypes)-1]
	}

	var results []testResultField
	for i, typStr := range allTypes {
		wantName := "want"
		gotName := "got"
		if i > 0 {
			wantName = fmt.Sprintf("want%d", i)
			gotName = fmt.Sprintf("got%d", i)
		}
		isFunc := isFuncResultType(typStr, typeDefs)
		deepEq := !isFunc && needsDeepEqual(typStr)
		results = append(results, testResultField{
			name:     wantName,
			gotName:  gotName,
			typeExpr: typStr,
			deepEq:   deepEq,
			isFunc:   isFunc,
		})
	}
	return results, hasErr
}

func isFuncResultType(typStr string, typeDefs map[string]testgenTypeDef) bool {
	if classifySyntacticTestType(typStr) == "func" {
		return true
	}
	if td, ok := resolveTestTypeDef(typStr, typeDefs); ok && td.kind == "func" {
		return true
	}
	return false
}

func needsDeepEqual(typ string) bool {
	t := strings.TrimSpace(typ)
	switch t {
	case "string", "bool",
		"int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "float32", "float64", "complex64", "complex128":
		return false
	default:
		return true
	}
}

func sampleLiteralForTest(typ string, edgeCase bool, isResult bool, typeDefs map[string]testgenTypeDef) string {
	t := strings.TrimSpace(typ)
	for strings.HasPrefix(t, "(") && strings.HasSuffix(t, ")") {
		inner := strings.TrimSpace(t[1 : len(t)-1])
		if inner == "" {
			break
		}
		if _, err := parser.ParseExpr(inner); err == nil {
			t = inner
		} else {
			break
		}
	}
	switch t {
	case "string":
		if edgeCase || isResult {
			return `""`
		}
		return `"sample"`
	case "bool":
		if edgeCase || isResult {
			return "false"
		}
		return "true"
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune":
		if edgeCase || isResult {
			return "0"
		}
		return "1"
	case "float32", "float64":
		if edgeCase || isResult {
			return "0.0"
		}
		return "1.0"
	case "complex64", "complex128":
		return "0"
	}

	kind := classifySyntacticTestType(t)
	switch kind {
	case "slice", "map", "ptr", "func", "chan", "interface":
		return "nil"
	case "struct", "array":
		return t + "{}"
	}

	if td, ok := resolveTestTypeDef(t, typeDefs); ok {
		switch td.kind {
		case "struct", "array":
			return t + "{}"
		case "interface", "func", "slice", "map", "chan", "ptr":
			return "nil"
		}
	}

	return "*new(" + t + ")"
}

