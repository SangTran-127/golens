package analysis

import (
	"fmt"
	"go/ast"
	"go/token"
	"sort"
	"strings"
)

type safetyCheckIssue struct {
	Line        int
	Col         int
	Message     string
	TargetName  string
	InLoop      bool
	CanQuickFix bool
	FixTitle    string
}

type pathTaintEntry struct {
	sourceLabel string
	guarded     bool
}

func inspectASTFilePathTraversal(fset *token.FileSet, file *ast.File, src string) []safetyCheckIssue {
	if fset == nil || file == nil {
		return nil
	}
	imports := collectPathSafetyImports(file)
	if !imports.hasOS && !imports.hasIOUtil && !imports.hasHTTP {
		return nil
	}

	constNames := collectFileConstNames(file)
	safeHelpers := collectFileSafePathHelpers(file, constNames, imports)
	for h := range safeHelpers {
		constNames[h] = true
	}
	constHelperParams := collectConstantOnlyHelperParams(file)
	var issues []safetyCheckIssue

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}
		params := collectFuncParamNames(fn.Type)
		if constParams := constHelperParams[fnName]; len(constParams) > 0 && fn.Recv == nil {
			for p := range constParams {
				delete(params, p)
			}
		}
		issues = append(issues, scanFuncBodyPathTraversal(fset, fn.Body, fnName, params, constNames, imports)...)
	}

	sortSafetyCheckIssues(issues)
	return issues
}

type pathSafetyImports struct {
	hasOS         bool
	hasIOUtil     bool
	hasHTTP       bool
	osAlias       string
	ioutilAlias   string
	httpAlias     string
	filepathAlias string
	pathAlias     string
	stringsAlias  string
	strconvAlias  string
	fmtAlias      string
}

func collectPathSafetyImports(file *ast.File) pathSafetyImports {
	info := pathSafetyImports{
		osAlias:       "os",
		ioutilAlias:   "ioutil",
		httpAlias:     "http",
		filepathAlias: "filepath",
		pathAlias:     "path",
		stringsAlias:  "strings",
		strconvAlias:  "strconv",
		fmtAlias:      "fmt",
	}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.Trim(imp.Path.Value, `"`+"`")
		alias := ""
		if imp.Name != nil {
			alias = imp.Name.Name
		}
		if alias == "_" || alias == "." {
			continue
		}
		switch p {
		case "os":
			info.hasOS = true
			if alias != "" {
				info.osAlias = alias
			}
		case "io/ioutil":
			info.hasIOUtil = true
			if alias != "" {
				info.ioutilAlias = alias
			}
		case "net/http":
			info.hasHTTP = true
			if alias != "" {
				info.httpAlias = alias
			}
		case "path/filepath":
			if alias != "" {
				info.filepathAlias = alias
			}
		case "path":
			if alias != "" {
				info.pathAlias = alias
			}
		case "strings":
			if alias != "" {
				info.stringsAlias = alias
			}
		case "strconv":
			if alias != "" {
				info.strconvAlias = alias
			}
		case "fmt":
			if alias != "" {
				info.fmtAlias = alias
			}
		}
	}
	return info
}

func collectFileConstNames(file *ast.File) map[string]bool {
	out := make(map[string]bool)
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		for _, spec := range gd.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			for _, id := range vs.Names {
				if id != nil && id.Name != "" && id.Name != "_" {
					out[id.Name] = true
				}
			}
		}
	}
	return out
}

func collectFileSafePathHelpers(file *ast.File, constNames map[string]bool, imports pathSafetyImports) map[string]bool {
	out := make(map[string]bool)
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv != nil || fn.Name == nil || fn.Body == nil {
			continue
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 1 {
			continue
		}
		hasRet := false
		allSafe := true
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			if !allSafe || n == nil {
				return false
			}
			ret, ok := n.(*ast.ReturnStmt)
			if !ok {
				return true
			}
			hasRet = true
			if len(ret.Results) != 1 || !isSafeHashOrEncodingReturnExpr(ret.Results[0], constNames, imports) {
				allSafe = false
				return false
			}
			return true
		})
		if hasRet && allSafe {
			out[fn.Name.Name] = true
		}
	}
	return out
}

func isSafeHashOrEncodingReturnExpr(expr ast.Expr, constNames map[string]bool, imports pathSafetyImports) bool {
	if isGuaranteedSafePathValue(expr, constNames, imports) {
		return true
	}
	call, ok := unwrapSafetyParens(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	if pkgIdent, ok := sel.X.(*ast.Ident); ok {
		if pkgIdent.Name == "hex" && sel.Sel.Name == "EncodeToString" {
			return true
		}
		if strings.HasPrefix(pkgIdent.Name, "base") && strings.Contains(sel.Sel.Name, "EncodeToString") {
			return true
		}
	}
	return false
}

func collectConstantOnlyHelperParams(file *ast.File) map[string]map[string]bool {
	funcs := make(map[string][]string)
	bodies := make(map[string]*ast.BlockStmt)
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv != nil || fn.Name == nil || fn.Type.Params == nil {
			continue
		}
		if ast.IsExported(fn.Name.Name) {
			continue
		}
		var paramNames []string
		for _, field := range fn.Type.Params.List {
			if field == nil {
				continue
			}
			if len(field.Names) == 0 {
				paramNames = append(paramNames, "")
				continue
			}
			for _, id := range field.Names {
				if id != nil {
					paramNames = append(paramNames, id.Name)
				}
			}
		}
		funcs[fn.Name.Name] = paramNames
		bodies[fn.Name.Name] = fn.Body
	}

	result := make(map[string]map[string]bool)
	for pass := 0; pass < 4; pass++ {
		seenCall := make(map[string]bool)
		nonConstIdx := make(map[string]map[int]bool)

		for callerName, body := range bodies {
			if body == nil {
				continue
			}
			callerConst := result[callerName]
			ast.Inspect(body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				id, ok := unwrapSafetyParens(call.Fun).(*ast.Ident)
				if !ok {
					return true
				}
				paramNames, exists := funcs[id.Name]
				if !exists {
					return true
				}
				seenCall[id.Name] = true
				if nonConstIdx[id.Name] == nil {
					nonConstIdx[id.Name] = make(map[int]bool)
				}
				for i := range paramNames {
					if i >= len(call.Args) {
						nonConstIdx[id.Name][i] = true
						continue
					}
					if isLiteralConstantExpr(call.Args[i]) {
						continue
					}
					if argID, ok := unwrapSafetyParens(call.Args[i]).(*ast.Ident); ok && callerConst[argID.Name] {
						continue
					}
					nonConstIdx[id.Name][i] = true
				}
				return true
			})
		}

		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			if fn.Recv == nil && fn.Name != nil {
				if _, tracked := bodies[fn.Name.Name]; tracked {
					continue
				}
			}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				id, ok := unwrapSafetyParens(call.Fun).(*ast.Ident)
				if !ok {
					return true
				}
				paramNames, exists := funcs[id.Name]
				if !exists {
					return true
				}
				seenCall[id.Name] = true
				if nonConstIdx[id.Name] == nil {
					nonConstIdx[id.Name] = make(map[int]bool)
				}
				for i := range paramNames {
					if i >= len(call.Args) || !isLiteralConstantExpr(call.Args[i]) {
						nonConstIdx[id.Name][i] = true
					}
				}
				return true
			})
		}

		next := make(map[string]map[string]bool)
		for fnName, paramNames := range funcs {
			if !seenCall[fnName] {
				continue
			}
			constSet := make(map[string]bool)
			for i, p := range paramNames {
				if p != "" && !nonConstIdx[fnName][i] {
					constSet[p] = true
				}
			}
			if len(constSet) > 0 {
				next[fnName] = constSet
			}
		}
		result = next
	}
	return result
}

func isLiteralConstantExpr(expr ast.Expr) bool {
	expr = unwrapSafetyParens(expr)
	if lit, ok := expr.(*ast.BasicLit); ok {
		return lit.Kind == token.STRING || lit.Kind == token.INT || lit.Kind == token.FLOAT
	}
	if bin, ok := expr.(*ast.BinaryExpr); ok && bin.Op == token.ADD {
		return isLiteralConstantExpr(bin.X) && isLiteralConstantExpr(bin.Y)
	}
	return false
}

func collectFuncParamNames(ft *ast.FuncType) map[string]bool {
	out := make(map[string]bool)
	if ft == nil || ft.Params == nil {
		return out
	}
	for _, field := range ft.Params.List {
		if field == nil {
			continue
		}
		for _, id := range field.Names {
			if id != nil && id.Name != "" && id.Name != "_" {
				out[id.Name] = true
			}
		}
	}
	return out
}

func scanFuncBodyPathTraversal(
	fset *token.FileSet,
	body *ast.BlockStmt,
	fnName string,
	params map[string]bool,
	constNames map[string]bool,
	imports pathSafetyImports,
) []safetyCheckIssue {
	var issues []safetyCheckIssue
	tainted := make(map[string]*pathTaintEntry)
	dynamicInputs := make(map[string]bool)
	for p := range params {
		dynamicInputs[p] = true
	}
	safeVars := make(map[string]bool)
	for c := range constNames {
		safeVars[c] = true
	}
	guardedVars := make(map[string]bool)
	httpTainted := make(map[string]bool)
	relGuards := make(map[string]string)

	var markVarsGuarded func(vars map[string]bool)
	markVarsGuarded = func(vars map[string]bool) {
		for name := range vars {
			guardedVars[name] = true
			if entry, ok := tainted[name]; ok {
				entry.guarded = true
			}
		}
	}

	var markHTTPInput func(lhs string, rhs ast.Expr)
	markHTTPInput = func(lhs string, rhs ast.Expr) {
		if containsHTTPInputExpr(rhs, httpTainted) {
			httpTainted[lhs] = true
		} else {
			delete(httpTainted, lhs)
		}
	}

	var inspectNode func(node ast.Node)
	var checkFileIOSinks func(expr ast.Expr)

	checkFileIOSinks = func(expr ast.Expr) {
		if expr == nil {
			return
		}
		ast.Inspect(expr, func(n ast.Node) bool {
			if lit, ok := n.(*ast.FuncLit); ok {
				inspectNode(lit)
				return false
			}
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sinkName, pathArg, isSink := matchFileIOSink(call, imports)
			if !isSink || pathArg == nil {
				return true
			}
			if reason, unsafe := isPathExprUnsafe(pathArg, tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
				pos := fset.Position(call.Pos())
				issues = append(issues, safetyCheckIssue{
					Line: pos.Line,
					Col:  pos.Column,
					Message: fmt.Sprintf(
						"Potential path traversal into %s from unguarded %s; validate with filepath.Rel or check strings.HasPrefix on filepath.Clean result",
						sinkName,
						reason,
					),
				})
			}
			return true
		})
	}

	inspectExprCalls := func(expr ast.Expr) {
		checkFileIOSinks(expr)
	}

	inspectNode = func(node ast.Node) {
		if node == nil {
			return
		}
		switch n := node.(type) {
		case *ast.BlockStmt:
			for _, st := range n.List {
				inspectNode(st)
			}
		case *ast.FuncLit:
			litParams := collectFuncParamNames(n.Type)
			mergedParams := make(map[string]bool, len(params)+len(litParams))
			for k, v := range params {
				mergedParams[k] = v
			}
			for k, v := range litParams {
				mergedParams[k] = v
			}
			issues = append(issues, scanFuncBodyPathTraversal(fset, n.Body, fnName, mergedParams, constNames, imports)...)
		case *ast.DeclStmt:
			gd, ok := n.Decl.(*ast.GenDecl)
			if !ok {
				return
			}
			if gd.Tok == token.CONST {
				for _, spec := range gd.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, id := range vs.Names {
							if id != nil && id.Name != "_" {
								safeVars[id.Name] = true
							}
						}
					}
				}
				return
			}
			for _, spec := range gd.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, val := range vs.Values {
					inspectExprCalls(val)
					if i >= len(vs.Names) || vs.Names[i] == nil || vs.Names[i].Name == "_" {
						continue
					}
					markHTTPInput(vs.Names[i].Name, val)
					processPathAssignment(vs.Names[i].Name, val, tainted, dynamicInputs, safeVars, guardedVars, relGuards, imports)
				}
			}
		case *ast.AssignStmt:
			if n.Tok != token.ASSIGN && n.Tok != token.DEFINE {
				for _, rhs := range n.Rhs {
					inspectExprCalls(rhs)
				}
				return
			}
			for _, rhs := range n.Rhs {
				inspectExprCalls(rhs)
			}
			if len(n.Rhs) == 1 && len(n.Lhs) >= 1 {
				rhs := n.Rhs[0]
				if relTarget, ok := matchFilepathRelCall(rhs, imports); ok {
					if id, ok := n.Lhs[0].(*ast.Ident); ok && id.Name != "_" {
						relGuards[id.Name] = relTarget
					}
					return
				}
				if len(n.Lhs) == 1 {
					if id, ok := n.Lhs[0].(*ast.Ident); ok && id.Name != "_" {
						markHTTPInput(id.Name, rhs)
						processPathAssignment(id.Name, rhs, tainted, dynamicInputs, safeVars, guardedVars, relGuards, imports)
					}
					return
				}
				if lhs0, ok := n.Lhs[0].(*ast.Ident); ok && lhs0.Name != "_" {
					markHTTPInput(lhs0.Name, rhs)
					processPathAssignment(lhs0.Name, rhs, tainted, dynamicInputs, safeVars, guardedVars, relGuards, imports)
				}
				return
			}
			for i, rhs := range n.Rhs {
				if i < len(n.Lhs) {
					if id, ok := n.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
						markHTTPInput(id.Name, rhs)
						processPathAssignment(id.Name, rhs, tainted, dynamicInputs, safeVars, guardedVars, relGuards, imports)
					}
				}
			}
		case *ast.IfStmt:
			if n.Init != nil {
				inspectNode(n.Init)
			}
			if absVar, isNegAbs := matchIsAbsCond(n.Cond, imports); absVar != "" && !httpTainted[absVar] {
				savedGuarded := cloneBoolMap(guardedVars)
				guardedVars[absVar] = true
				if isNegAbs {
					inspectNode(n.Body)
					guardedVars = savedGuarded
					if n.Else != nil {
						inspectNode(n.Else)
					}
				} else {
					inspectNode(n.Body)
					if n.Else != nil {
						inspectNode(n.Else)
					}
					guardedVars = savedGuarded
				}
				return
			}
			if condGuards := extractContainmentGuardedVars(n.Cond, relGuards, imports); len(condGuards) > 0 && ifBranchExitsOrGates(n.Body, n.Else) {
				markVarsGuarded(condGuards)
			}
			if condGuards := extractContainmentPositiveVars(n.Cond, relGuards, imports); len(condGuards) > 0 {
				savedGuarded := cloneBoolMap(guardedVars)
				markVarsGuarded(condGuards)
				inspectNode(n.Body)
				guardedVars = savedGuarded
				if n.Else != nil {
					inspectNode(n.Else)
				}
				return
			}
			inspectNode(n.Body)
			if n.Else != nil {
				inspectNode(n.Else)
			}
		case *ast.ExprStmt:
			inspectExprCalls(n.X)
		case *ast.ReturnStmt:
			for _, res := range n.Results {
				inspectExprCalls(res)
			}
		case *ast.DeferStmt:
			if n.Call != nil {
				inspectExprCalls(n.Call)
			}
		case *ast.GoStmt:
			if n.Call != nil {
				inspectExprCalls(n.Call)
			}
		case *ast.ForStmt:
			if n.Init != nil {
				inspectNode(n.Init)
			}
			inspectNode(n.Body)
		case *ast.RangeStmt:
			inspectNode(n.Body)
		case *ast.SwitchStmt:
			if n.Init != nil {
				inspectNode(n.Init)
			}
			inspectNode(n.Body)
		case *ast.TypeSwitchStmt:
			if n.Init != nil {
				inspectNode(n.Init)
			}
			inspectNode(n.Body)
		case *ast.CaseClause:
			for _, st := range n.Body {
				inspectNode(st)
			}
		case *ast.SelectStmt:
			inspectNode(n.Body)
		case *ast.CommClause:
			for _, st := range n.Body {
				inspectNode(st)
			}
		}
	}

	inspectNode(body)
	return issues
}

func cloneBoolMap(m map[string]bool) map[string]bool {
	out := make(map[string]bool, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func processPathAssignment(
	lhs string,
	rhs ast.Expr,
	tainted map[string]*pathTaintEntry,
	dynamicInputs map[string]bool,
	safeVars map[string]bool,
	guardedVars map[string]bool,
	relGuards map[string]string,
	imports pathSafetyImports,
) {
	if isGuaranteedSafePathValue(rhs, safeVars, imports) {
		delete(tainted, lhs)
		delete(dynamicInputs, lhs)
		safeVars[lhs] = true
		return
	}
	if wrappedArg, ok := matchCleanOrAbsCall(rhs, imports); ok {
		if id, ok := unwrapSafetyParens(wrappedArg).(*ast.Ident); ok {
			if entry, exists := tainted[id.Name]; exists && !entry.guarded && !guardedVars[id.Name] {
				tainted[lhs] = &pathTaintEntry{sourceLabel: entry.sourceLabel, guarded: guardedVars[lhs]}
				relGuards[lhs] = id.Name
				return
			}
		}
		if reason, unsafe := isPathExprUnsafe(wrappedArg, tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
			tainted[lhs] = &pathTaintEntry{sourceLabel: reason, guarded: guardedVars[lhs]}
			return
		}
	}
	if reason, unsafe := isJoinedOrConcatDynamicPath(rhs, tainted, dynamicInputs, safeVars, guardedVars, imports); unsafe {
		tainted[lhs] = &pathTaintEntry{sourceLabel: reason, guarded: guardedVars[lhs]}
		delete(safeVars, lhs)
		return
	}
	if isDynamicPathSource(rhs, dynamicInputs, safeVars, imports) {
		dynamicInputs[lhs] = true
		delete(safeVars, lhs)
		delete(tainted, lhs)
		return
	}
	delete(tainted, lhs)
	delete(dynamicInputs, lhs)
}

func unwrapSafetyParens(expr ast.Expr) ast.Expr {
	for expr != nil {
		if p, ok := expr.(*ast.ParenExpr); ok {
			expr = p.X
			continue
		}
		return expr
	}
	return nil
}

func sortSafetyCheckIssues(issues []safetyCheckIssue) {
	sort.SliceStable(issues, func(i, j int) bool {
		if issues[i].Line != issues[j].Line {
			return issues[i].Line < issues[j].Line
		}
		if issues[i].Col != issues[j].Col {
			return issues[i].Col < issues[j].Col
		}
		return issues[i].Message < issues[j].Message
	})
}
