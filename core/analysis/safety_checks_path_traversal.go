package analysis

import (
	"go/ast"
	"go/token"
	"strings"
)

func matchFileIOSink(call *ast.CallExpr, imports pathSafetyImports) (string, ast.Expr, bool) {
	if call == nil {
		return "", nil, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", nil, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return "", nil, false
	}
	pkg := pkgIdent.Name
	method := sel.Sel.Name
	if imports.hasOS && pkg == imports.osAlias {
		switch method {
		case "Open", "OpenFile", "ReadFile", "WriteFile", "Create", "Remove", "RemoveAll", "MkdirAll":
			if len(call.Args) >= 1 {
				return "os." + method, call.Args[0], true
			}
		}
	}
	if imports.hasIOUtil && pkg == imports.ioutilAlias {
		switch method {
		case "ReadFile", "WriteFile":
			if len(call.Args) >= 1 {
				return "ioutil." + method, call.Args[0], true
			}
		}
	}
	if imports.hasHTTP && pkg == imports.httpAlias && method == "ServeFile" {
		if len(call.Args) >= 3 {
			return "http.ServeFile", call.Args[2], true
		}
	}
	return "", nil, false
}

func isPathExprUnsafe(
	expr ast.Expr,
	tainted map[string]*pathTaintEntry,
	dynamicInputs map[string]bool,
	safeVars map[string]bool,
	guardedVars map[string]bool,
	imports pathSafetyImports,
) (string, bool) {
	expr = unwrapSafetyParens(expr)
	if expr == nil {
		return "", false
	}
	if id, ok := expr.(*ast.Ident); ok {
		if guardedVars[id.Name] {
			return "", false
		}
		if entry, exists := tainted[id.Name]; exists && !entry.guarded {
			return entry.sourceLabel, true
		}
		return "", false
	}
	if arg, ok := matchCleanOrAbsCall(expr, imports); ok {
		return isPathExprUnsafe(arg, tainted, dynamicInputs, safeVars, guardedVars, imports)
	}
	return isJoinedOrConcatDynamicPath(expr, tainted, dynamicInputs, safeVars, guardedVars, imports)
}

func isJoinedOrConcatDynamicPath(
	expr ast.Expr,
	tainted map[string]*pathTaintEntry,
	dynamicInputs map[string]bool,
	safeVars map[string]bool,
	guardedVars map[string]bool,
	imports pathSafetyImports,
) (string, bool) {
	expr = unwrapSafetyParens(expr)
	if expr == nil {
		return "", false
	}
	if call, ok := expr.(*ast.CallExpr); ok {
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok && (pkgIdent.Name == imports.filepathAlias || pkgIdent.Name == imports.pathAlias) && sel.Sel.Name == "Join" {
				if len(call.Args) >= 2 {
					if reason, unsafe := isPathExprUnsafe(call.Args[0], tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
						return reason, true
					}
					for _, seg := range call.Args[1:] {
						if isSegmentGuarded(seg, guardedVars) {
							continue
						}
						if isGuaranteedSafePathValue(seg, safeVars, imports) {
							continue
						}
						if reason, unsafe := isPathExprUnsafe(seg, tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
							return reason, true
						}
						if isDynamicPathSource(seg, dynamicInputs, safeVars, imports) {
							return pkgIdent.Name + ".Join", true
						}
					}
				}
				return "", false
			}
		}
	}

	if bin, ok := expr.(*ast.BinaryExpr); ok && bin.Op == token.ADD {
		parts := flattenStringAdds(bin)
		if len(parts) < 2 {
			return "", false
		}
		hasPathJoinCue := false
		hasDynamicSegment := false
		for i, part := range parts {
			if litStr, isLit := safetyStringLiteralValue(part); isLit {
				if strings.Contains(litStr, "/") || strings.Contains(litStr, `\`) {
					hasPathJoinCue = true
				}
				if i == len(parts)-1 && strings.HasPrefix(litStr, ".") && !strings.ContainsAny(litStr, `/\`) {
					return "", false
				}
				continue
			}
			if isPathSeparatorExpr(part, imports) {
				hasPathJoinCue = true
				continue
			}
			if i > 0 && !isGuaranteedSafePathValue(part, safeVars, imports) && !isSegmentGuarded(part, guardedVars) {
				if isDynamicPathSource(part, dynamicInputs, safeVars, imports) {
					hasDynamicSegment = true
				}
				if _, unsafe := isPathExprUnsafe(part, tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
					hasDynamicSegment = true
					hasPathJoinCue = true
				}
			}
		}
		if hasPathJoinCue && hasDynamicSegment {
			return "string concatenation", true
		}
	}
	return "", false
}

func isSegmentGuarded(expr ast.Expr, guardedVars map[string]bool) bool {
	if id, ok := unwrapSafetyParens(expr).(*ast.Ident); ok {
		return guardedVars[id.Name]
	}
	return false
}

func flattenStringAdds(expr ast.Expr) []ast.Expr {
	expr = unwrapSafetyParens(expr)
	if bin, ok := expr.(*ast.BinaryExpr); ok && bin.Op == token.ADD {
		left := flattenStringAdds(bin.X)
		right := flattenStringAdds(bin.Y)
		return append(left, right...)
	}
	return []ast.Expr{expr}
}

func safetyStringLiteralValue(expr ast.Expr) (string, bool) {
	lit, ok := unwrapSafetyParens(expr).(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	v := lit.Value
	if len(v) >= 2 {
		if (v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '`' && v[len(v)-1] == '`') {
			return v[1 : len(v)-1], true
		}
	}
	return v, true
}

func isPathSeparatorExpr(expr ast.Expr, imports pathSafetyImports) bool {
	expr = unwrapSafetyParens(expr)
	if call, ok := expr.(*ast.CallExpr); ok && len(call.Args) == 1 {
		if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "string" {
			return isPathSeparatorExpr(call.Args[0], imports)
		}
	}
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return false
	}
	return (pkgIdent.Name == imports.osAlias || pkgIdent.Name == imports.filepathAlias) && sel.Sel.Name == "PathSeparator"
}

func isGuaranteedSafePathValue(expr ast.Expr, safeVars map[string]bool, imports pathSafetyImports) bool {
	expr = unwrapSafetyParens(expr)
	if expr == nil {
		return true
	}
	switch e := expr.(type) {
	case *ast.BasicLit:
		return true
	case *ast.Ident:
		return safeVars[e.Name] || e.Name == "true" || e.Name == "false" || e.Name == "nil"
	case *ast.CallExpr:
		if id, ok := e.Fun.(*ast.Ident); ok && safeVars[id.Name] {
			return true
		}
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok {
				if pkgIdent.Name == imports.strconvAlias && (sel.Sel.Name == "Itoa" || sel.Sel.Name == "FormatInt" || sel.Sel.Name == "FormatUint") {
					return true
				}
				if pkgIdent.Name == imports.fmtAlias && sel.Sel.Name == "Sprintf" && len(e.Args) >= 1 {
					if fmtStr, ok := safetyStringLiteralValue(e.Args[0]); ok && formatStringSafePath(fmtStr, e.Args[1:], safeVars, imports) {
						return true
					}
				}
				if (pkgIdent.Name == "uuid" || pkgIdent.Name == "hex") && strings.Contains(sel.Sel.Name, "String") {
					return true
				}
				if pkgIdent.Name == imports.filepathAlias && sel.Sel.Name == "Ext" {
					return true
				}
			}
			if sel.Sel.Name == "String" && isSafeIDReceiver(sel.X) {
				return true
			}
		}
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			return isGuaranteedSafePathValue(e.X, safeVars, imports) && isGuaranteedSafePathValue(e.Y, safeVars, imports)
		}
	}
	return false
}

func isSafeIDReceiver(expr ast.Expr) bool {
	switch e := unwrapSafetyParens(expr).(type) {
	case *ast.Ident:
		lower := strings.ToLower(e.Name)
		return lower == "id" || strings.HasSuffix(lower, "id") || strings.Contains(lower, "uuid")
	case *ast.SelectorExpr:
		if e.Sel != nil {
			lower := strings.ToLower(e.Sel.Name)
			return lower == "id" || strings.HasSuffix(lower, "id") || strings.Contains(lower, "uuid")
		}
	}
	return false
}

func formatStringSafePath(s string, args []ast.Expr, safeVars map[string]bool, imports pathSafetyImports) bool {
	if formatStringOnlyNumeric(s) {
		return true
	}
	argIdx := 0
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			continue
		}
		if i+1 < len(s) && s[i+1] == '%' {
			i++
			continue
		}
		prefixStart := i
		i++
		for i < len(s) && (s[i] == '-' || s[i] == '+' || s[i] == '#' || s[i] == '0' || (s[i] >= '0' && s[i] <= '9') || s[i] == '.') {
			i++
		}
		if i >= len(s) {
			return false
		}
		verb := s[i]
		var arg ast.Expr
		if argIdx < len(args) {
			arg = args[argIdx]
		}
		argIdx++
		switch verb {
		case 'd', 'b', 'o', 'O', 'x', 'X', 'U':
			continue
		case 's':
			if prefixStart > 0 && s[prefixStart-1] != '.' && s[prefixStart-1] != '/' && s[prefixStart-1] != '\\' && arg != nil {
				if isFilepathBaseCall(arg, imports) || isGuaranteedSafePathValue(arg, safeVars, imports) {
					continue
				}
			}
			return false
		default:
			return false
		}
	}
	return argIdx > 0
}

func isFilepathBaseCall(expr ast.Expr, imports pathSafetyImports) bool {
	call, ok := unwrapSafetyParens(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Base" {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	return ok && (pkgIdent.Name == imports.filepathAlias || pkgIdent.Name == imports.pathAlias)
}

func containsHTTPInputExpr(expr ast.Expr, httpTainted map[string]bool) bool {
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		switch node := n.(type) {
		case *ast.CallExpr:
			if isHTTPInputCall(node) {
				found = true
				return false
			}
		case *ast.Ident:
			if httpTainted[node.Name] {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

func matchIsAbsCond(cond ast.Expr, imports pathSafetyImports) (string, bool) {
	c := unwrapSafetyParens(cond)
	if c == nil {
		return "", false
	}
	if bin, ok := c.(*ast.BinaryExpr); ok && bin.Op == token.LAND {
		if name, neg := matchIsAbsCond(bin.X, imports); name != "" && neg {
			return name, true
		}
		if name, neg := matchIsAbsCond(bin.Y, imports); name != "" && neg {
			return name, true
		}
		return "", false
	}
	u, isNeg := c.(*ast.UnaryExpr)
	target := c
	negated := false
	if isNeg && u.Op == token.NOT {
		target = u.X
		negated = true
	}
	call, ok := unwrapSafetyParens(target).(*ast.CallExpr)
	if !ok || len(call.Args) != 1 {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "IsAbs" {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || (pkgIdent.Name != imports.filepathAlias && pkgIdent.Name != imports.pathAlias) {
		return "", false
	}
	if id, ok := unwrapSafetyParens(call.Args[0]).(*ast.Ident); ok && id.Name != "_" {
		return id.Name, negated
	}
	return "", false
}

func formatStringOnlyNumeric(s string) bool {
	hasVerb := false
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			continue
		}
		if i+1 < len(s) && s[i+1] == '%' {
			i++
			continue
		}
		i++
		for i < len(s) && (s[i] == '-' || s[i] == '+' || s[i] == '#' || s[i] == '0' || (s[i] >= '0' && s[i] <= '9') || s[i] == '.') {
			i++
		}
		if i >= len(s) {
			return false
		}
		switch s[i] {
		case 'd', 'b', 'o', 'O', 'x', 'X', 'U':
			hasVerb = true
		default:
			return false
		}
	}
	return hasVerb
}

func isDynamicPathSource(
	expr ast.Expr,
	dynamicInputs map[string]bool,
	safeVars map[string]bool,
	imports pathSafetyImports,
) bool {
	expr = unwrapSafetyParens(expr)
	if expr == nil || isGuaranteedSafePathValue(expr, safeVars, imports) {
		return false
	}
	switch e := expr.(type) {
	case *ast.Ident:
		return dynamicInputs[e.Name]
	case *ast.SelectorExpr:
		if e.Sel == nil {
			return false
		}
		if e.Sel.Name == "Output" || e.Sel.Name == "Stdout" || e.Sel.Name == "Stderr" {
			return false
		}
		if e.Sel.Name == "Path" || e.Sel.Name == "RawPath" {
			return true
		}
		if pkgIdent, ok := e.X.(*ast.Ident); ok && safeVars[pkgIdent.Name] {
			return false
		}
		return true
	case *ast.IndexExpr:
		return isDynamicPathSource(e.X, dynamicInputs, safeVars, imports)
	case *ast.CallExpr:
		if isHTTPInputCall(e) {
			return true
		}
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok {
				if pkgIdent.Name == imports.filepathAlias && (sel.Sel.Name == "Base" || sel.Sel.Name == "Clean" || sel.Sel.Name == "Dir") {
					if len(e.Args) >= 1 {
						return isDynamicPathSource(e.Args[0], dynamicInputs, safeVars, imports)
					}
				}
				if pkgIdent.Name == imports.stringsAlias && len(e.Args) >= 1 {
					return isDynamicPathSource(e.Args[0], dynamicInputs, safeVars, imports)
				}
			}
			if sel.Sel.Name == "TempDir" {
				return false
			}
		}
		for _, arg := range e.Args {
			if isDynamicPathSource(arg, dynamicInputs, safeVars, imports) {
				return true
			}
		}
	}
	return false
}

func isHTTPInputCall(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	switch sel.Sel.Name {
	case "PathValue", "FormValue", "PostFormValue", "Param", "Query", "DefaultQuery", "URLParam", "Header", "GetHeader":
		return true
	case "Get":
		if innerSel, ok := sel.X.(*ast.CallExpr); ok {
			if innerFun, ok := innerSel.Fun.(*ast.SelectorExpr); ok && innerFun.Sel != nil && innerFun.Sel.Name == "Query" {
				return true
			}
		}
		if s, ok := sel.X.(*ast.SelectorExpr); ok && s.Sel != nil && (s.Sel.Name == "Header" || s.Sel.Name == "Form" || s.Sel.Name == "Vars") {
			return true
		}
	case "Vars":
		return true
	}
	return false
}

func matchCleanOrAbsCall(expr ast.Expr, imports pathSafetyImports) (ast.Expr, bool) {
	call, ok := unwrapSafetyParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) != 1 {
		return nil, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return nil, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return nil, false
	}
	if pkgIdent.Name == imports.filepathAlias && (sel.Sel.Name == "Clean" || sel.Sel.Name == "Abs" || sel.Sel.Name == "EvalSymlinks") {
		return call.Args[0], true
	}
	if pkgIdent.Name == imports.pathAlias && sel.Sel.Name == "Clean" {
		return call.Args[0], true
	}
	return nil, false
}

func matchFilepathRelCall(expr ast.Expr, imports pathSafetyImports) (string, bool) {
	call, ok := unwrapSafetyParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) != 2 {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Rel" {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != imports.filepathAlias {
		return "", false
	}
	if id, ok := unwrapSafetyParens(call.Args[1]).(*ast.Ident); ok {
		return id.Name, true
	}
	if inner, ok := matchCleanOrAbsCall(call.Args[1], imports); ok {
		if id, ok := unwrapSafetyParens(inner).(*ast.Ident); ok {
			return id.Name, true
		}
	}
	return "", false
}

func extractContainmentGuardedVars(cond ast.Expr, relGuards map[string]string, imports pathSafetyImports) map[string]bool {
	out := make(map[string]bool)
	if cond == nil {
		return out
	}
	ast.Inspect(cond, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok {
				if pkgIdent.Name == imports.stringsAlias && (sel.Sel.Name == "HasPrefix" || sel.Sel.Name == "CutPrefix") && len(call.Args) == 2 {
					collectPathArgIdents(call.Args[0], relGuards, imports, out)
				}
				if pkgIdent.Name == imports.filepathAlias && sel.Sel.Name == "IsLocal" && len(call.Args) == 1 {
					collectPathArgIdents(call.Args[0], relGuards, imports, out)
				}
			}
			if isPathContainmentHelperName(sel.Sel.Name) {
				for _, a := range call.Args {
					collectPathArgIdents(a, relGuards, imports, out)
				}
			}
		} else if fnIdent, ok := call.Fun.(*ast.Ident); ok && isPathContainmentHelperName(fnIdent.Name) {
			for _, a := range call.Args {
				collectPathArgIdents(a, relGuards, imports, out)
			}
		}
		return true
	})
	return out
}

func extractContainmentPositiveVars(cond ast.Expr, relGuards map[string]string, imports pathSafetyImports) map[string]bool {
	if cond == nil {
		return nil
	}
	if u, ok := unwrapSafetyParens(cond).(*ast.UnaryExpr); ok && u.Op == token.NOT {
		return nil
	}
	out := make(map[string]bool)
	ast.Inspect(cond, func(n ast.Node) bool {
		if u, ok := n.(*ast.UnaryExpr); ok && u.Op == token.NOT {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if pkgIdent, ok := sel.X.(*ast.Ident); ok {
				if pkgIdent.Name == imports.stringsAlias && (sel.Sel.Name == "HasPrefix" || sel.Sel.Name == "CutPrefix") && len(call.Args) == 2 {
					if lit, isLit := safetyStringLiteralValue(call.Args[1]); !(isLit && lit == "..") {
						collectPathArgIdents(call.Args[0], relGuards, imports, out)
					}
				}
				if pkgIdent.Name == imports.filepathAlias && sel.Sel.Name == "IsLocal" && len(call.Args) == 1 {
					collectPathArgIdents(call.Args[0], relGuards, imports, out)
				}
			}
			if isPathContainmentHelperName(sel.Sel.Name) {
				for _, a := range call.Args {
					collectPathArgIdents(a, relGuards, imports, out)
				}
			}
		} else if fnIdent, ok := call.Fun.(*ast.Ident); ok && isPathContainmentHelperName(fnIdent.Name) {
			for _, a := range call.Args {
				collectPathArgIdents(a, relGuards, imports, out)
			}
		}
		return true
	})
	return out
}

func collectPathArgIdents(expr ast.Expr, relGuards map[string]string, imports pathSafetyImports, out map[string]bool) {
	expr = unwrapSafetyParens(expr)
	if inner, ok := matchCleanOrAbsCall(expr, imports); ok {
		collectPathArgIdents(inner, relGuards, imports, out)
	}
	if id, ok := expr.(*ast.Ident); ok && id.Name != "_" {
		out[id.Name] = true
		if target, ok := relGuards[id.Name]; ok && target != "" {
			out[target] = true
		}
	}
}

func isPathContainmentHelperName(name string) bool {
	lower := strings.ToLower(name)
	for _, kw := range []string{"insideroot", "withinroot", "inroot", "safepath", "validpath", "validstorage", "validfilename", "cleanpath", "containspath", "iscontained", "allowpath", "checkpath", "sanitizepath", "escapes"} {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

func ifBranchExitsOrGates(body *ast.BlockStmt, elseStmt ast.Stmt) bool {
	if elseStmt != nil {
		return true
	}
	if body == nil || len(body.List) == 0 {
		return false
	}
	last := body.List[len(body.List)-1]
	switch st := last.(type) {
	case *ast.ReturnStmt:
		return true
	case *ast.BranchStmt:
		return st.Tok == token.CONTINUE || st.Tok == token.BREAK
	case *ast.ExprStmt:
		if call, ok := st.X.(*ast.CallExpr); ok {
			if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "panic" {
				return true
			}
		}
	}
	return false
}
