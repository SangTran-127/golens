package analysis

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
)

type GoroutineSafetyIssue struct {
	Kind        string `json:"kind"`
	Severity    string `json:"severity"`
	Line        int    `json:"line"`
	Column      int    `json:"column"`
	FuncName    string `json:"funcName"`
	Expression  string `json:"expression"`
	Message     string `json:"message"`
	Suggestion  string `json:"suggestion"`
	CanAutoFix  bool   `json:"canAutoFix"`
	FixTitle    string `json:"fixTitle"`
	Replacement string `json:"replacement"`
}

type GoroutineSafetyReport struct {
	FilePath          string                 `json:"filePath"`
	PackageName       string                 `json:"packageName"`
	TotalIssues       int                    `json:"totalIssues"`
	AutoFixableCount  int                    `json:"autoFixableCount"`
	LoopCaptureCount  int                    `json:"loopCaptureCount"`
	UnboundedGoCount  int                    `json:"unboundedGoCount"`
	WaitGroupBugCount int                    `json:"waitGroupBugCount"`
	Issues            []GoroutineSafetyIssue `json:"issues"`
}

func InspectGoroutineSafety(filePath string, srcOpt string) (*GoroutineSafetyReport, error) {
	src := srcOpt
	trimmedPath := strings.TrimSpace(filePath)
	if src == "" && trimmedPath != "" {
		data, err := os.ReadFile(trimmedPath)
		if err != nil {
			return nil, err
		}
		src = string(data)
	}

	report := &GoroutineSafetyReport{
		FilePath: filePath,
		Issues:   []GoroutineSafetyIssue{},
	}

	if strings.TrimSpace(src) == "" {
		return report, nil
	}

	parsePath := trimmedPath
	if parsePath == "" {
		parsePath = "input.go"
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		return nil, err
	}

	if astFile.Name != nil {
		report.PackageName = astFile.Name.Name
	}

	lines := strings.Split(src, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	for _, decl := range astFile.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := ""
		if fn.Name != nil {
			funcName = fn.Name.Name
		}

		fnIssues := inspectFuncGoroutineSafety(fset, fn.Body, funcName, lineAt)
		report.Issues = append(report.Issues, fnIssues...)
	}

	sort.SliceStable(report.Issues, func(i, j int) bool {
		if report.Issues[i].Line != report.Issues[j].Line {
			return report.Issues[i].Line < report.Issues[j].Line
		}
		if report.Issues[i].Column != report.Issues[j].Column {
			return report.Issues[i].Column < report.Issues[j].Column
		}
		return report.Issues[i].Kind < report.Issues[j].Kind
	})

	for _, issue := range report.Issues {
		switch issue.Kind {
		case "LOOP_VAR_CAPTURE":
			report.LoopCaptureCount++
		case "UNBOUNDED_GOROUTINE_LOOP":
			report.UnboundedGoCount++
		case "WAITGROUP_ADD_INSIDE_GO":
			report.WaitGroupBugCount++
		}
		if issue.CanAutoFix {
			report.AutoFixableCount++
		}
	}
	report.TotalIssues = len(report.Issues)

	return report, nil
}

func ApplyGoroutineSafetyFixes(filePath string, srcOpt string) (string, int, error) {
	src := srcOpt
	trimmedPath := strings.TrimSpace(filePath)
	if src == "" && trimmedPath != "" {
		data, err := os.ReadFile(trimmedPath)
		if err != nil {
			return "", 0, err
		}
		src = string(data)
	}

	report, err := InspectGoroutineSafety(filePath, src)
	if err != nil {
		return "", 0, err
	}

	var fixable []GoroutineSafetyIssue
	seenLines := make(map[int]bool)
	for _, issue := range report.Issues {
		if !issue.CanAutoFix || issue.Kind != "LOOP_VAR_CAPTURE" {
			continue
		}
		if seenLines[issue.Line] {
			continue
		}
		seenLines[issue.Line] = true
		fixable = append(fixable, issue)
	}

	if len(fixable) == 0 {
		return src, 0, nil
	}

	sort.Slice(fixable, func(i, j int) bool {
		return fixable[i].Line > fixable[j].Line
	})

	lines := strings.Split(src, "\n")
	applied := 0

	for _, issue := range fixable {
		if issue.Line < 1 || issue.Line > len(lines) {
			continue
		}
		rebindCode := strings.TrimSpace(strings.Split(issue.Replacement, "//")[0])
		if rebindCode == "" {
			continue
		}
		origLine := lines[issue.Line-1]
		indent := leadingWhitespace(origLine)
		trimmedOrig := strings.TrimSpace(origLine)
		if !strings.HasPrefix(trimmedOrig, "go ") && strings.Contains(origLine, "go func") {
			goIdx := strings.Index(origLine, "go func")
			lines[issue.Line-1] = origLine[:goIdx] + rebindCode + "; " + origLine[goIdx:]
		} else {
			lines[issue.Line-1] = indent + rebindCode + "\n" + origLine
		}
		applied++
	}

	return strings.Join(lines, "\n"), applied, nil
}

func inspectFuncGoroutineSafety(
	fset *token.FileSet,
	fnBody *ast.BlockStmt,
	funcName string,
	lineAt func(int) string,
) []GoroutineSafetyIssue {
	var issues []GoroutineSafetyIssue

	waitGroupNames := collectWaitGroupNames(fset, fnBody)

	ast.Inspect(fnBody, func(n ast.Node) bool {
		goStmt, ok := n.(*ast.GoStmt)
		if !ok || goStmt.Call == nil {
			return true
		}
		funcLit, ok := goStmt.Call.Fun.(*ast.FuncLit)
		if !ok || funcLit.Body == nil {
			return true
		}

		for idx, stmt := range funcLit.Body.List {
			call := extractStandaloneCall(stmt)
			if call == nil {
				continue
			}
			if isWaitGroupAddCall(fset, call, idx == 0, waitGroupNames, fnBody) {
				pos := fset.Position(call.Pos())
				expr := strings.TrimSpace(exprToString(fset, call))
				if expr == "" {
					expr = "wg.Add(1)"
				}
				issues = append(issues, GoroutineSafetyIssue{
					Kind:        "WAITGROUP_ADD_INSIDE_GO",
					Severity:    "error",
					Line:        pos.Line,
					Column:      pos.Column,
					FuncName:    funcName,
					Expression:  expr,
					Message:     "Calling " + expr + " inside 'go func()' races with Wait(); move Add(1) before the 'go' statement",
					Suggestion:  "Call wg.Add(1) on the line before launching 'go func()'",
					CanAutoFix:  false,
					FixTitle:    "",
					Replacement: "",
				})
				break
			}
		}
		return true
	})

	type loopContext struct {
		vars []string
		body *ast.BlockStmt
	}

	var walkLoops func(node ast.Node, stack []loopContext)
	walkLoops = func(node ast.Node, stack []loopContext) {
		if node == nil {
			return
		}

		switch n := node.(type) {
		case *ast.FuncLit:
			return

		case *ast.RangeStmt:
			if n.Body == nil {
				return
			}
			vars := extractRangeLoopVars(n)
			nextStack := append(append([]loopContext{}, stack...), loopContext{
				vars: vars,
				body: n.Body,
			})
			for _, stmt := range n.Body.List {
				walkLoops(stmt, nextStack)
			}
			return

		case *ast.ForStmt:
			if n.Body == nil {
				return
			}
			vars := extractForLoopVars(n)
			nextStack := append(append([]loopContext{}, stack...), loopContext{
				vars: vars,
				body: n.Body,
			})
			for _, stmt := range n.Body.List {
				walkLoops(stmt, nextStack)
			}
			return

		case *ast.GoStmt:
			if len(stack) > 0 && n.Call != nil {
				var allLoopVars []string
				seenVar := make(map[string]bool)
				var loopBodies []*ast.BlockStmt
				for _, lc := range stack {
					loopBodies = append(loopBodies, lc.body)
					for _, v := range lc.vars {
						if !seenVar[v] {
							seenVar[v] = true
							allLoopVars = append(allLoopVars, v)
						}
					}
				}
				innermostBody := stack[len(stack)-1].body

				if funcLit, isLit := n.Call.Fun.(*ast.FuncLit); isLit {
					if isZeroParamClosure(funcLit) && funcLit.Body != nil && len(allLoopVars) > 0 {
						var captured []string
						for _, v := range allLoopVars {
							if isVarReboundBeforePos(loopBodies, v, n.Pos()) {
								continue
							}
							if isLoopVarReferencedInClosure(funcLit.Body, v) {
								captured = append(captured, v)
							}
						}
						if len(captured) > 0 {
							varName := strings.Join(captured, ", ")
							pos := fset.Position(n.Pos())
							expr := lineAt(pos.Line)
							if expr == "" {
								expr = "go func()"
							}
							issues = append(issues, GoroutineSafetyIssue{
								Kind:        "LOOP_VAR_CAPTURE",
								Severity:    "warning",
								Line:        pos.Line,
								Column:      pos.Column,
								FuncName:    funcName,
								Expression:  expr,
								Message:     fmt.Sprintf("Loop variable '%s' captured by 'go func()' closure without rebinding or passing as parameter", varName),
								Suggestion:  fmt.Sprintf("Rebind '%s := %s' before launching 'go func()' or pass '%s' as a parameter", varName, varName, varName),
								CanAutoFix:  true,
								FixTitle:    "Pass loop variable as parameter to go func(" + varName + ")",
								Replacement: fmt.Sprintf("%s := %s // explicit loop capture before go func()", varName, varName),
							})
						}
					}
				} else {
					if !hasLoopGoroutineSynchronization(fset, innermostBody, fnBody, n.Call, waitGroupNames) {
						pos := fset.Position(n.Pos())
						callExpr := strings.TrimSpace(exprToString(fset, n.Call))
						expr := "go " + callExpr
						if callExpr == "" {
							expr = lineAt(pos.Line)
						}
						issues = append(issues, GoroutineSafetyIssue{
							Kind:        "UNBOUNDED_GOROUTINE_LOOP",
							Severity:    "warning",
							Line:        pos.Line,
							Column:      pos.Column,
							FuncName:    funcName,
							Expression:  expr,
							Message:     "Spawning goroutine inside loop without WaitGroup or bounded concurrency synchronization",
							Suggestion:  "Coordinate loop goroutines with sync.WaitGroup, errgroup.Group, or a bounded semaphore channel",
							CanAutoFix:  false,
							FixTitle:    "",
							Replacement: "",
						})
					}
				}
			}
			return
		}

		ast.Inspect(node, func(child ast.Node) bool {
			if child == nil || child == node {
				return true
			}
			walkLoops(child, stack)
			return false
		})
	}

	walkLoops(fnBody, nil)

	return issues
}

func collectWaitGroupNames(fset *token.FileSet, fnBody *ast.BlockStmt) map[string]bool {
	names := make(map[string]bool)
	if fnBody == nil {
		return names
	}
	ast.Inspect(fnBody, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.ValueSpec:
			if node.Type != nil {
				typeStr := strings.TrimSpace(exprToString(fset, node.Type))
				if strings.HasSuffix(typeStr, "WaitGroup") {
					for _, ident := range node.Names {
						if ident != nil && ident.Name != "" {
							names[ident.Name] = true
						}
					}
				}
			}
		case *ast.CallExpr:
			if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
				if sel.Sel.Name == "Done" || sel.Sel.Name == "Wait" {
					recv := strings.TrimSpace(exprToString(fset, sel.X))
					if recv != "" {
						names[recv] = true
					}
				}
			}
		}
		return true
	})
	return names
}

func extractStandaloneCall(stmt ast.Stmt) *ast.CallExpr {
	exprStmt, ok := stmt.(*ast.ExprStmt)
	if !ok || exprStmt.X == nil {
		return nil
	}
	call, ok := exprStmt.X.(*ast.CallExpr)
	if !ok {
		return nil
	}
	return call
}

func isWaitGroupAddCall(
	fset *token.FileSet,
	call *ast.CallExpr,
	isFirstStmt bool,
	waitGroupNames map[string]bool,
	_ *ast.BlockStmt,
) bool {
	if call == nil || len(call.Args) != 1 {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Add" {
		return false
	}
	recv := strings.TrimSpace(exprToString(fset, sel.X))
	if recv == "" {
		return false
	}
	if isFirstStmt {
		return true
	}
	if waitGroupNames[recv] {
		return true
	}
	lowerRecv := strings.ToLower(recv)
	if lowerRecv == "wg" || strings.HasSuffix(lowerRecv, ".wg") || strings.Contains(lowerRecv, "waitgroup") {
		return true
	}
	return false
}

func extractRangeLoopVars(n *ast.RangeStmt) []string {
	var vars []string
	if ident, ok := n.Key.(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
		vars = append(vars, ident.Name)
	}
	if ident, ok := n.Value.(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
		vars = append(vars, ident.Name)
	}
	return vars
}

func extractForLoopVars(n *ast.ForStmt) []string {
	var vars []string
	assign, ok := n.Init.(*ast.AssignStmt)
	if !ok {
		return vars
	}
	for _, lhs := range assign.Lhs {
		if ident, ok := lhs.(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
			vars = append(vars, ident.Name)
		}
	}
	return vars
}

func isZeroParamClosure(funcLit *ast.FuncLit) bool {
	if funcLit == nil || funcLit.Type == nil || funcLit.Type.Params == nil {
		return true
	}
	return len(funcLit.Type.Params.List) == 0
}

func isVarReboundBeforePos(loopBodies []*ast.BlockStmt, varName string, goPos token.Pos) bool {
	for _, body := range loopBodies {
		if body == nil {
			continue
		}
		rebound := false
		ast.Inspect(body, func(n ast.Node) bool {
			if rebound || n == nil {
				return false
			}
			if n.Pos() >= goPos {
				return false
			}
			if _, isLit := n.(*ast.FuncLit); isLit {
				return false
			}
			switch stmt := n.(type) {
			case *ast.AssignStmt:
				if stmt.Tok == token.DEFINE {
					for _, lhs := range stmt.Lhs {
						if ident, ok := lhs.(*ast.Ident); ok && ident.Name == varName {
							rebound = true
							return false
						}
					}
				}
			case *ast.DeclStmt:
				if genDecl, ok := stmt.Decl.(*ast.GenDecl); ok && genDecl.Tok == token.VAR {
					for _, spec := range genDecl.Specs {
						if vs, ok := spec.(*ast.ValueSpec); ok {
							for _, ident := range vs.Names {
								if ident != nil && ident.Name == varName {
									rebound = true
									return false
								}
							}
						}
					}
				}
			}
			return true
		})
		if rebound {
			return true
		}
	}
	return false
}

func isLoopVarReferencedInClosure(body *ast.BlockStmt, varName string) bool {
	if body == nil || varName == "" {
		return false
	}
	referenced := false
	shadowed := false

	var walk func(n ast.Node)
	walk = func(n ast.Node) {
		if referenced || shadowed || n == nil {
			return
		}

		switch node := n.(type) {
		case *ast.AssignStmt:
			for _, rhs := range node.Rhs {
				walk(rhs)
			}
			if referenced {
				return
			}
			if node.Tok == token.DEFINE {
				for _, lhs := range node.Lhs {
					if ident, ok := lhs.(*ast.Ident); ok && ident.Name == varName {
						shadowed = true
						return
					}
				}
			}
			for _, lhs := range node.Lhs {
				if node.Tok != token.DEFINE {
					walk(lhs)
				}
			}
			return

		case *ast.SelectorExpr:
			walk(node.X)
			return

		case *ast.Ident:
			if node.Name == varName {
				referenced = true
			}
			return
		}

		ast.Inspect(n, func(child ast.Node) bool {
			if child == nil || child == n {
				return true
			}
			walk(child)
			return false
		})
	}

	walk(body)
	return referenced
}

func hasLoopGoroutineSynchronization(
	fset *token.FileSet,
	loopBody *ast.BlockStmt,
	fnBody *ast.BlockStmt,
	goCall *ast.CallExpr,
	waitGroupNames map[string]bool,
) bool {
	if loopBody == nil {
		return false
	}

	synchronized := false
	ast.Inspect(loopBody, func(n ast.Node) bool {
		if synchronized || n == nil {
			return false
		}
		switch node := n.(type) {
		case *ast.SendStmt:
			synchronized = true
			return false
		case *ast.UnaryExpr:
			if node.Op == token.ARROW {
				synchronized = true
				return false
			}
		case *ast.CallExpr:
			if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
				switch sel.Sel.Name {
				case "Add", "Done", "Wait", "Acquire", "TryAcquire":
					synchronized = true
					return false
				}
			}
		}
		return true
	})
	if synchronized {
		return true
	}

	if goCall != nil {
		for _, arg := range goCall.Args {
			argStr := strings.TrimSpace(exprToString(fset, arg))
			argStr = strings.TrimPrefix(argStr, "&")
			if waitGroupNames[argStr] || strings.EqualFold(argStr, "wg") {
				return true
			}
		}
	}

	if fnBody != nil {
		hasChanOrSyncInFn := false
		ast.Inspect(fnBody, func(n ast.Node) bool {
			if hasChanOrSyncInFn || n == nil {
				return false
			}
			switch node := n.(type) {
			case *ast.SendStmt:
				hasChanOrSyncInFn = true
				return false
			case *ast.UnaryExpr:
				if node.Op == token.ARROW {
					hasChanOrSyncInFn = true
					return false
				}
			case *ast.ChanType:
				hasChanOrSyncInFn = true
				return false
			}
			return true
		})
		if hasChanOrSyncInFn {
			return true
		}
	}

	return false
}
