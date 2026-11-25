package analysis

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"sort"
	"strings"
)

type HTTPSafetyIssue struct {
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

type HTTPSafetyReport struct {
	FilePath           string            `json:"filePath"`
	PackageName        string            `json:"packageName"`
	TotalIssues        int               `json:"totalIssues"`
	AutoFixableCount   int               `json:"autoFixableCount"`
	DefaultClientCount int               `json:"defaultClientCount"`
	ServerTimeoutCount int               `json:"serverTimeoutCount"`
	UnclosedBodyCount  int               `json:"unclosedBodyCount"`
	InsecureTLSCount   int               `json:"insecureTLSCount"`
	Issues             []HTTPSafetyIssue `json:"issues"`
}

type httpSafetyIssueKey struct {
	kind   string
	line   int
	column int
}

type httpSafetySpanEdit struct {
	start            int
	end              int
	replacement      string
	needsTimePackage bool
	key              httpSafetyIssueKey
}

type httpSafetyBodyInsertion struct {
	insertAfterLine int
	assignLine      int
	respVar         string
	key             httpSafetyIssueKey
}

func InspectHTTPSafety(filePath string, srcOpt string) (*HTTPSafetyReport, error) {
	report := &HTTPSafetyReport{
		FilePath: filePath,
		Issues:   []HTTPSafetyIssue{},
	}

	src := srcOpt
	if src == "" && strings.TrimSpace(filePath) != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return report, err
		}
		src = string(data)
	}
	if strings.TrimSpace(src) == "" {
		return report, nil
	}

	parsePath := filePath
	if strings.TrimSpace(parsePath) == "" {
		parsePath = "input.go"
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		return report, err
	}
	fillHTTPSafetyReport(report, fset, astFile, src)
	return report, nil
}

func fillHTTPSafetyReport(report *HTTPSafetyReport, fset *token.FileSet, astFile *ast.File, src string) {
	if astFile.Name != nil {
		report.PackageName = astFile.Name.Name
	}

	issues, _, _ := collectHTTPSafetyAnalysis(fset, astFile, src)
	sort.SliceStable(issues, func(i, j int) bool {
		if issues[i].Line != issues[j].Line {
			return issues[i].Line < issues[j].Line
		}
		if issues[i].Column != issues[j].Column {
			return issues[i].Column < issues[j].Column
		}
		return issues[i].Kind < issues[j].Kind
	})

	for _, iss := range issues {
		switch iss.Kind {
		case "HTTP_DEFAULT_CLIENT":
			report.DefaultClientCount++
		case "HTTP_SERVER_NO_TIMEOUT":
			report.ServerTimeoutCount++
		case "HTTP_BODY_UNCLOSED":
			report.UnclosedBodyCount++
		case "TLS_INSECURE_SKIP_VERIFY":
			report.InsecureTLSCount++
		}
		if iss.CanAutoFix {
			report.AutoFixableCount++
		}
	}

	report.TotalIssues = len(issues)
	if issues != nil {
		report.Issues = issues
	}
}

func ApplyHTTPSafetyFixes(filePath string, srcOpt string) (string, int, error) {
	src, parsePath, err := loadHTTPSafetySource(filePath, srcOpt)
	if err != nil || strings.TrimSpace(src) == "" {
		return src, 0, err
	}
	return applyHTTPSafetyEdits(parsePath, src, nil)
}

func ApplyHTTPSafetyFix(filePath, srcOpt string, line, column int, kind string) (string, error) {
	src, parsePath, err := loadHTTPSafetySource(filePath, srcOpt)
	if err != nil {
		return src, err
	}
	key := httpSafetyIssueKey{kind: kind, line: line, column: column}
	updated, count, err := applyHTTPSafetyEdits(parsePath, src, &key)
	if err != nil {
		return src, err
	}
	if count == 0 {
		return src, fmt.Errorf("no automatic fix for %s at %d:%d", kind, line, column)
	}
	return updated, nil
}

func loadHTTPSafetySource(filePath, srcOpt string) (string, string, error) {
	src := srcOpt
	if src == "" && strings.TrimSpace(filePath) != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return "", "", err
		}
		src = string(data)
	}
	parsePath := filePath
	if strings.TrimSpace(parsePath) == "" {
		parsePath = "input.go"
	}
	return src, parsePath, nil
}

func applyHTTPSafetyEdits(parsePath, src string, only *httpSafetyIssueKey) (string, int, error) {
	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		return src, 0, err
	}

	_, spanEdits, _ := collectHTTPSafetyAnalysis(fset, astFile, src)
	if only != nil {
		filtered := spanEdits[:0]
		for _, edit := range spanEdits {
			if edit.key == *only {
				filtered = append(filtered, edit)
			}
		}
		spanEdits = filtered
	}

	appliedCount := 0
	needsTimePkg := false
	currentSrc := src

	if len(spanEdits) > 0 {
		sort.SliceStable(spanEdits, func(i, j int) bool {
			if spanEdits[i].start != spanEdits[j].start {
				return spanEdits[i].start > spanEdits[j].start
			}
			return spanEdits[i].end > spanEdits[j].end
		})

		lastStart := len(currentSrc) + 1
		for _, edit := range spanEdits {
			if edit.start < 0 || edit.end < edit.start || edit.end > len(currentSrc) {
				continue
			}
			if edit.end > lastStart {
				continue
			}
			currentSrc = currentSrc[:edit.start] + edit.replacement + currentSrc[edit.end:]
			lastStart = edit.start
			appliedCount++
			if edit.needsTimePackage {
				needsTimePkg = true
			}
		}
	}

	fset2 := token.NewFileSet()
	astFile2, err2 := parser.ParseFile(fset2, parsePath, currentSrc, parser.ParseComments)
	if astFile2 != nil && err2 == nil {
		_, _, bodyInsertions := collectHTTPSafetyAnalysis(fset2, astFile2, currentSrc)
		if only != nil {
			filtered := bodyInsertions[:0]
			for _, ins := range bodyInsertions {
				if ins.key == *only {
					filtered = append(filtered, ins)
				}
			}
			bodyInsertions = filtered
		}
		if len(bodyInsertions) > 0 {
			sort.SliceStable(bodyInsertions, func(i, j int) bool {
				if bodyInsertions[i].insertAfterLine != bodyInsertions[j].insertAfterLine {
					return bodyInsertions[i].insertAfterLine > bodyInsertions[j].insertAfterLine
				}
				return bodyInsertions[i].assignLine > bodyInsertions[j].assignLine
			})

			lines := strings.Split(currentSrc, "\n")
			seenInsertKey := make(map[string]bool)
			for _, ins := range bodyInsertions {
				if ins.insertAfterLine < 1 || ins.insertAfterLine > len(lines) {
					continue
				}
				key := fmt.Sprintf("%d:%s", ins.insertAfterLine, ins.respVar)
				if seenInsertKey[key] {
					continue
				}
				seenInsertKey[key] = true

				indent := "\t"
				if ins.assignLine >= 1 && ins.assignLine <= len(lines) {
					indent = leadingWhitespace(lines[ins.assignLine-1])
				}
				deferLine := fmt.Sprintf("%sdefer %s.Body.Close()", indent, ins.respVar)

				updatedLines := make([]string, 0, len(lines)+1)
				updatedLines = append(updatedLines, lines[:ins.insertAfterLine]...)
				updatedLines = append(updatedLines, deferLine)
				updatedLines = append(updatedLines, lines[ins.insertAfterLine:]...)
				lines = updatedLines
				appliedCount++
			}
			currentSrc = strings.Join(lines, "\n")
		}
	}

	if appliedCount == 0 {
		return src, 0, nil
	}

	if needsTimePkg {
		currentSrc = ensureHTTPSafetyTimeImport(parsePath, currentSrc)
	}

	if formatted, fmtErr := format.Source([]byte(currentSrc)); fmtErr == nil {
		currentSrc = string(formatted)
	} else if _, parseErr := parser.ParseFile(token.NewFileSet(), parsePath, currentSrc, parser.AllErrors); parseErr != nil {
		return src, 0, fmt.Errorf("HTTP safety fix would not parse: %w", parseErr)
	}

	return currentSrc, appliedCount, nil
}

func collectHTTPSafetyAnalysis(
	fset *token.FileSet,
	file *ast.File,
	src string,
) ([]HTTPSafetyIssue, []httpSafetySpanEdit, []httpSafetyBodyInsertion) {
	var issues []HTTPSafetyIssue
	var spanEdits []httpSafetySpanEdit
	var bodyInsertions []httpSafetyBodyInsertion

	unaryAmpByCompLit := make(map[*ast.CompositeLit]*ast.UnaryExpr)
	parentKeyByCompLit := make(map[*ast.CompositeLit]string)

	ast.Inspect(file, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.UnaryExpr:
			if node.Op == token.AND {
				if cl, ok := node.X.(*ast.CompositeLit); ok {
					unaryAmpByCompLit[cl] = node
				}
			}
		case *ast.KeyValueExpr:
			if keyIdent, ok := node.Key.(*ast.Ident); ok {
				switch val := node.Value.(type) {
				case *ast.CompositeLit:
					parentKeyByCompLit[val] = keyIdent.Name
				case *ast.UnaryExpr:
					if cl, ok := val.X.(*ast.CompositeLit); ok {
						parentKeyByCompLit[cl] = keyIdent.Name
					}
				}
			}
		}
		return true
	})

	inspectNodeTreeForHTTPAndTLS := func(root ast.Node, funcName string, skipNestedFuncs bool) {
		ast.Inspect(root, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if skipNestedFuncs && n != root {
				if _, isLit := n.(*ast.FuncLit); isLit {
					return false
				}
			}

			switch node := n.(type) {
			case *ast.CallExpr:
				if method, isDefaultClientCall := matchHTTPPackageClientCall(node); isDefaultClientCall {
					pos := fset.Position(node.Pos())
					exprStr := strings.TrimSpace(exprToString(fset, node))
					newFun := fmt.Sprintf("(&http.Client{Timeout: 10 * time.Second}).%s", method)
					repStr := strings.Replace(exprStr, "http."+method+"(", newFun+"(", 1)

					issues = append(issues, HTTPSafetyIssue{
						Kind:        "HTTP_DEFAULT_CLIENT",
						Severity:    "warning",
						Line:        pos.Line,
						Column:      pos.Column,
						FuncName:    funcName,
						Expression:  exprStr,
						Message:     fmt.Sprintf("http.%s uses http.DefaultClient with no timeout (Timeout: 0), which can block goroutines indefinitely if the remote server hangs", method),
						Suggestion:  fmt.Sprintf("Replace http.%s(...) with a client configured with an explicit Timeout", method),
						CanAutoFix:  true,
						FixTitle:    "Use an http.Client With a 10-Second Timeout",
						Replacement: repStr,
					})

					funStart := fset.Position(node.Fun.Pos()).Offset
					funEnd := fset.Position(node.Fun.End()).Offset
					if funStart >= 0 && funEnd > funStart && funEnd <= len(src) {
						spanEdits = append(spanEdits, httpSafetySpanEdit{
							start:            funStart,
							end:              funEnd,
							replacement:      newFun,
							needsTimePackage: true,
							key:              httpSafetyIssueKey{kind: "HTTP_DEFAULT_CLIENT", line: pos.Line, column: pos.Column},
						})
					}
				} else if method, isListenCall := matchHTTPPackageListenCall(node); isListenCall {
					pos := fset.Position(node.Pos())
					exprStr := strings.TrimSpace(exprToString(fset, node))
					replacement, canFix := buildHTTPListenAndServeReplacement(fset, node, method)

					issues = append(issues, HTTPSafetyIssue{
						Kind:        "HTTP_SERVER_NO_TIMEOUT",
						Severity:    "warning",
						Line:        pos.Line,
						Column:      pos.Column,
						FuncName:    funcName,
						Expression:  exprStr,
						Message:     fmt.Sprintf("http.%s starts an HTTP server without ReadHeaderTimeout or ReadTimeout, exposing it to Slowloris denial-of-service attacks", method),
						Suggestion:  "Configure an explicit &http.Server with ReadHeaderTimeout: 5 * time.Second",
						CanAutoFix:  canFix,
						FixTitle:    "Use an http.Server With a 5-Second ReadHeaderTimeout",
						Replacement: replacement,
					})

					if canFix {
						callStart := fset.Position(node.Pos()).Offset
						callEnd := fset.Position(node.End()).Offset
						if callStart >= 0 && callEnd > callStart && callEnd <= len(src) {
							spanEdits = append(spanEdits, httpSafetySpanEdit{
								start:            callStart,
								end:              callEnd,
								replacement:      replacement,
								needsTimePackage: true,
								key:              httpSafetyIssueKey{kind: "HTTP_SERVER_NO_TIMEOUT", line: pos.Line, column: pos.Column},
							})
						}
					}
				}

			case *ast.CompositeLit:
				if isSelectorType(node.Type, "http", "Client") {
					if !compositeLitHasNonZeroField(node, "Timeout") {
						displayNode := ast.Expr(node)
						if amp, ok := unaryAmpByCompLit[node]; ok {
							displayNode = amp
						}
						pos := fset.Position(displayNode.Pos())
						exprStr := strings.TrimSpace(exprToString(fset, displayNode))
						edit, preview := buildCompositeLitFieldAddition(fset, node, displayNode, src, "Timeout: 10 * time.Second")

						issues = append(issues, HTTPSafetyIssue{
							Kind:        "HTTP_DEFAULT_CLIENT",
							Severity:    "warning",
							Line:        pos.Line,
							Column:      pos.Column,
							FuncName:    funcName,
							Expression:  exprStr,
							Message:     "http.Client literal has no Timeout configured (defaults to 0), allowing hung remote servers to block goroutines forever",
							Suggestion:  "Set Timeout: 10 * time.Second on http.Client",
							CanAutoFix:  true,
							FixTitle:    "Add a 10-Second Timeout to http.Client",
							Replacement: preview,
						})

						if edit.end >= edit.start && edit.replacement != "" {
							edit.key = httpSafetyIssueKey{kind: "HTTP_DEFAULT_CLIENT", line: pos.Line, column: pos.Column}
							spanEdits = append(spanEdits, edit)
						}
					}
				} else if isSelectorType(node.Type, "http", "Server") {
					if !compositeLitHasNonZeroField(node, "ReadHeaderTimeout") && !compositeLitHasNonZeroField(node, "ReadTimeout") {
						displayNode := ast.Expr(node)
						if amp, ok := unaryAmpByCompLit[node]; ok {
							displayNode = amp
						}
						pos := fset.Position(displayNode.Pos())
						exprStr := strings.TrimSpace(exprToString(fset, displayNode))
						edit, preview := buildCompositeLitFieldAddition(fset, node, displayNode, src, "ReadHeaderTimeout: 5 * time.Second")

						issues = append(issues, HTTPSafetyIssue{
							Kind:        "HTTP_SERVER_NO_TIMEOUT",
							Severity:    "warning",
							Line:        pos.Line,
							Column:      pos.Column,
							FuncName:    funcName,
							Expression:  exprStr,
							Message:     "http.Server is missing ReadHeaderTimeout and ReadTimeout, leaving it vulnerable to Slowloris denial-of-service attacks",
							Suggestion:  "Add ReadHeaderTimeout: 5 * time.Second to http.Server",
							CanAutoFix:  true,
							FixTitle:    "Add a 5-Second ReadHeaderTimeout to http.Server",
							Replacement: preview,
						})

						if edit.end >= edit.start && edit.replacement != "" {
							edit.key = httpSafetyIssueKey{kind: "HTTP_SERVER_NO_TIMEOUT", line: pos.Line, column: pos.Column}
							spanEdits = append(spanEdits, edit)
						}
					}
				}

				if isTLSConfigCompositeLit(node, parentKeyByCompLit[node]) {
					if kv, ok := findInsecureSkipVerifyTrue(node); ok {
						pos := fset.Position(kv.Pos())
						exprStr := strings.TrimSpace(exprToString(fset, kv))
						issues = append(issues, HTTPSafetyIssue{
							Kind:        "TLS_INSECURE_SKIP_VERIFY",
							Severity:    "error",
							Line:        pos.Line,
							Column:      pos.Column,
							FuncName:    funcName,
							Expression:  exprStr,
							Message:     "TLS configuration sets InsecureSkipVerify: true, disabling certificate verification and exposing connections to MITM attacks",
							Suggestion:  "Remove InsecureSkipVerify: true and verify server certificates against trusted RootCAs",
							CanAutoFix:  false,
							FixTitle:    "",
							Replacement: "",
						})
					}
				}
			}

			return true
		})
	}

	inspectFuncBodyForUnclosedBodies := func(funcName string, body *ast.BlockStmt) {
		if body == nil {
			return
		}
		closedVars := collectHTTPClosedBodyVars(fset, body)
		returnedVars := collectReturnedVars(fset, body)

		var walkBlock func(block *ast.BlockStmt)
		walkBlock = func(block *ast.BlockStmt) {
			if block == nil {
				return
			}
			for idx, stmt := range block.List {
				if respVar, callDesc, ok := matchHTTPResponseAssignStmt(fset, stmt); ok {
					if !closedVars[respVar] && !returnedVars[respVar] && !returnedVars[respVar+".Body"] {
						pos := fset.Position(stmt.Pos())
						exprStr := strings.TrimSpace(formatASTNode(fset, stmt))

						insertAfterLine := fset.Position(stmt.End()).Line
						if idx+1 < len(block.List) {
							if nextIf, isIf := block.List[idx+1].(*ast.IfStmt); isIf && isErrNotNilCheck(fset, nextIf.Cond) {
								ifEnd := fset.Position(nextIf.End()).Line
								if ifEnd >= insertAfterLine {
									insertAfterLine = ifEnd
								}
							}
						}

						fixTitle := fmt.Sprintf("Add defer %s.Body.Close()", respVar)

						fnLabel := funcName
						if fnLabel == "" {
							fnLabel = "the enclosing function"
						}

						issues = append(issues, HTTPSafetyIssue{
							Kind:        "HTTP_BODY_UNCLOSED",
							Severity:    "error",
							Line:        pos.Line,
							Column:      pos.Column,
							FuncName:    funcName,
							Expression:  exprStr,
							Message:     fmt.Sprintf("HTTP response body '%s.Body' from %s is never closed in %s, leaking TCP connections and file descriptors", respVar, callDesc, fnLabel),
							Suggestion:  fmt.Sprintf("Add 'defer %s.Body.Close()' after checking the error from %s", respVar, callDesc),
							CanAutoFix:  true,
							FixTitle:    fixTitle,
							Replacement: fmt.Sprintf("defer %s.Body.Close()", respVar),
						})

						bodyInsertions = append(bodyInsertions, httpSafetyBodyInsertion{
							insertAfterLine: insertAfterLine,
							assignLine:      pos.Line,
							respVar:         respVar,
							key:             httpSafetyIssueKey{kind: "HTTP_BODY_UNCLOSED", line: pos.Line, column: pos.Column},
						})
					}
				}

				ast.Inspect(stmt, func(n ast.Node) bool {
					if n == nil || n == stmt {
						return true
					}
					if _, isLit := n.(*ast.FuncLit); isLit {
						return false
					}
					if subBlock, isBlock := n.(*ast.BlockStmt); isBlock {
						walkBlock(subBlock)
						return false
					}
					return true
				})
			}
		}

		walkBlock(body)
	}

	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			fnName := ""
			if d.Name != nil {
				fnName = d.Name.Name
			}
			if d.Body != nil {
				inspectNodeTreeForHTTPAndTLS(d.Body, fnName, true)
				inspectFuncBodyForUnclosedBodies(fnName, d.Body)

				ast.Inspect(d.Body, func(n ast.Node) bool {
					lit, ok := n.(*ast.FuncLit)
					if ok && lit.Body != nil {
						inspectNodeTreeForHTTPAndTLS(lit.Body, fnName, true)
						inspectFuncBodyForUnclosedBodies(fnName, lit.Body)
					}
					return true
				})
			}
		case *ast.GenDecl:
			inspectNodeTreeForHTTPAndTLS(d, "", false)
		}
	}

	return issues, spanEdits, bodyInsertions
}

func matchHTTPPackageClientCall(call *ast.CallExpr) (string, bool) {
	if call == nil {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "http" {
		return "", false
	}
	switch sel.Sel.Name {
	case "Get", "Post", "PostForm", "Head":
		return sel.Sel.Name, true
	default:
		return "", false
	}
}

func matchHTTPPackageListenCall(call *ast.CallExpr) (string, bool) {
	if call == nil {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "http" {
		return "", false
	}
	switch sel.Sel.Name {
	case "ListenAndServe", "ListenAndServeTLS":
		return sel.Sel.Name, true
	default:
		return "", false
	}
}

func buildHTTPListenAndServeReplacement(fset *token.FileSet, call *ast.CallExpr, method string) (string, bool) {
	switch method {
	case "ListenAndServe":
		if len(call.Args) != 2 {
			return "", false
		}
		addrStr := strings.TrimSpace(exprToString(fset, call.Args[0]))
		handlerStr := strings.TrimSpace(exprToString(fset, call.Args[1]))
		if addrStr == "" || handlerStr == "" {
			return "", false
		}
		return fmt.Sprintf("(&http.Server{Addr: %s, Handler: %s, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe()", addrStr, handlerStr), true

	case "ListenAndServeTLS":
		if len(call.Args) != 4 {
			return "", false
		}
		addrStr := strings.TrimSpace(exprToString(fset, call.Args[0]))
		certStr := strings.TrimSpace(exprToString(fset, call.Args[1]))
		keyStr := strings.TrimSpace(exprToString(fset, call.Args[2]))
		handlerStr := strings.TrimSpace(exprToString(fset, call.Args[3]))
		if addrStr == "" || certStr == "" || keyStr == "" || handlerStr == "" {
			return "", false
		}
		return fmt.Sprintf("(&http.Server{Addr: %s, Handler: %s, ReadHeaderTimeout: 5 * time.Second}).ListenAndServeTLS(%s, %s)", addrStr, handlerStr, certStr, keyStr), true
	}
	return "", false
}

func isSelectorType(expr ast.Expr, pkgName, typeName string) bool {
	if expr == nil {
		return false
	}
	if star, isStar := expr.(*ast.StarExpr); isStar {
		expr = star.X
	}
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != typeName {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	return ok && pkgIdent.Name == pkgName
}

func compositeLitHasNonZeroField(cl *ast.CompositeLit, fieldName string) bool {
	if cl == nil {
		return false
	}
	for _, elt := range cl.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		keyIdent, ok := kv.Key.(*ast.Ident)
		if !ok || keyIdent.Name != fieldName {
			continue
		}
		if lit, isBasic := kv.Value.(*ast.BasicLit); isBasic && lit.Kind == token.INT && lit.Value == "0" {
			return false
		}
		return true
	}
	return false
}

func buildCompositeLitFieldAddition(
	fset *token.FileSet,
	cl *ast.CompositeLit,
	displayNode ast.Expr,
	src string,
	fieldAddition string,
) (httpSafetySpanEdit, string) {
	lbracePos := fset.Position(cl.Lbrace)
	rbracePos := fset.Position(cl.Rbrace)
	lbraceOffset := lbracePos.Offset
	rbraceOffset := rbracePos.Offset

	fieldKey := strings.TrimSpace(strings.SplitN(fieldAddition, ":", 2)[0])
	fieldVal := ""
	if parts := strings.SplitN(fieldAddition, ":", 2); len(parts) == 2 {
		fieldVal = strings.TrimSpace(parts[1])
	}

	for _, elt := range cl.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		if keyIdent, ok := kv.Key.(*ast.Ident); ok && keyIdent.Name == fieldKey && fieldVal != "" {
			vStart := fset.Position(kv.Value.Pos()).Offset
			vEnd := fset.Position(kv.Value.End()).Offset
			if vStart >= 0 && vEnd > vStart && vEnd <= len(src) {
				edit := httpSafetySpanEdit{
					start:            vStart,
					end:              vEnd,
					replacement:      fieldVal,
					needsTimePackage: true,
				}
				return edit, previewCompositeLitWithField(fset, displayNode, fieldAddition)
			}
		}
	}

	if len(cl.Elts) == 0 {
		edit := httpSafetySpanEdit{
			start:            lbraceOffset,
			end:              rbraceOffset + 1,
			replacement:      "{" + fieldAddition + "}",
			needsTimePackage: true,
		}
		return edit, previewCompositeLitWithField(fset, displayNode, fieldAddition)
	}

	if lbracePos.Line == rbracePos.Line {
		lastEltEnd := fset.Position(cl.Elts[len(cl.Elts)-1].End()).Offset
		if lastEltEnd >= lbraceOffset && rbraceOffset >= lastEltEnd && rbraceOffset <= len(src) {
			edit := httpSafetySpanEdit{
				start:            lastEltEnd,
				end:              rbraceOffset,
				replacement:      ", " + fieldAddition,
				needsTimePackage: true,
			}
			return edit, previewCompositeLitWithField(fset, displayNode, fieldAddition)
		}
	}

	edit := httpSafetySpanEdit{
		start:            lbraceOffset,
		end:              lbraceOffset + 1,
		replacement:      "{\n\t" + fieldAddition + ",",
		needsTimePackage: true,
	}
	return edit, previewCompositeLitWithField(fset, displayNode, fieldAddition)
}

func previewCompositeLitWithField(fset *token.FileSet, displayNode ast.Expr, fieldAddition string) string {
	raw := strings.TrimSpace(exprToString(fset, displayNode))
	if strings.HasSuffix(raw, "{}") {
		return raw[:len(raw)-1] + fieldAddition + "}"
	}
	if strings.HasSuffix(raw, "}") {
		inner := strings.TrimSpace(raw[:len(raw)-1])
		if strings.HasSuffix(inner, ",") {
			return inner + " " + fieldAddition + "}"
		}
		return inner + ", " + fieldAddition + "}"
	}
	return raw
}

func isTLSConfigCompositeLit(cl *ast.CompositeLit, parentKey string) bool {
	if cl == nil {
		return false
	}
	if isSelectorType(cl.Type, "tls", "Config") {
		return true
	}
	if cl.Type == nil && parentKey == "TLSClientConfig" {
		return true
	}
	for _, elt := range cl.Elts {
		if kv, ok := elt.(*ast.KeyValueExpr); ok {
			if ident, ok := kv.Key.(*ast.Ident); ok && ident.Name == "InsecureSkipVerify" {
				return true
			}
		}
	}
	return false
}

func findInsecureSkipVerifyTrue(cl *ast.CompositeLit) (*ast.KeyValueExpr, bool) {
	if cl == nil {
		return nil, false
	}
	for _, elt := range cl.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		keyIdent, ok := kv.Key.(*ast.Ident)
		if !ok || keyIdent.Name != "InsecureSkipVerify" {
			continue
		}
		valIdent, ok := kv.Value.(*ast.Ident)
		if ok && valIdent.Name == "true" {
			return kv, true
		}
	}
	return nil, false
}

func matchHTTPResponseAssignStmt(fset *token.FileSet, stmt ast.Stmt) (respVar string, callDesc string, ok bool) {
	switch s := stmt.(type) {
	case *ast.AssignStmt:
		if len(s.Rhs) != 1 || len(s.Lhs) < 1 {
			return "", "", false
		}
		lhsIdent, isIdent := s.Lhs[0].(*ast.Ident)
		if !isIdent || lhsIdent.Name == "" || lhsIdent.Name == "_" {
			return "", "", false
		}
		call, isCall := s.Rhs[0].(*ast.CallExpr)
		if !isCall {
			return "", "", false
		}
		desc, matched := classifyHTTPResponseProducingCall(fset, call, lhsIdent.Name, len(s.Lhs))
		if !matched {
			return "", "", false
		}
		return lhsIdent.Name, desc, true

	case *ast.DeclStmt:
		genDecl, isGen := s.Decl.(*ast.GenDecl)
		if !isGen || genDecl.Tok != token.VAR || len(genDecl.Specs) != 1 {
			return "", "", false
		}
		vs, isVS := genDecl.Specs[0].(*ast.ValueSpec)
		if !isVS || len(vs.Values) != 1 || len(vs.Names) < 1 || vs.Names[0] == nil {
			return "", "", false
		}
		varName := vs.Names[0].Name
		if varName == "" || varName == "_" {
			return "", "", false
		}
		call, isCall := vs.Values[0].(*ast.CallExpr)
		if !isCall {
			return "", "", false
		}
		desc, matched := classifyHTTPResponseProducingCall(fset, call, varName, len(vs.Names))
		if !matched {
			return "", "", false
		}
		return varName, desc, true
	}
	return "", "", false
}

func classifyHTTPResponseProducingCall(
	fset *token.FileSet,
	call *ast.CallExpr,
	lhsVarName string,
	lhsCount int,
) (string, bool) {
	if call == nil {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", false
	}
	method := sel.Sel.Name
	recvStr := strings.TrimSpace(exprToString(fset, sel.X))
	if recvStr == "" {
		return "", false
	}

	if recvStr == "http" {
		switch method {
		case "Get", "Post", "PostForm", "Head":
			return "http." + method, true
		default:
			return "", false
		}
	}

	switch method {
	case "Do", "RoundTrip":
		return recvStr + "." + method, true
	case "Post", "PostForm", "Head":
		if lhsCount >= 2 || isHTTPClientReceiverExpr(sel.X, recvStr) {
			return recvStr + "." + method, true
		}
	case "Get":
		if isHTTPClientReceiverExpr(sel.X, recvStr) {
			return recvStr + ".Get", true
		}
		lowerVar := strings.ToLower(lhsVarName)
		if lhsCount == 2 && (strings.Contains(lowerVar, "resp") || lowerVar == "res" || lowerVar == "r") {
			return recvStr + ".Get", true
		}
	}

	return "", false
}

func isHTTPClientReceiverExpr(expr ast.Expr, recvStr string) bool {
	if expr == nil {
		return false
	}
	unwrapped := expr
	for {
		if p, isParen := unwrapped.(*ast.ParenExpr); isParen {
			unwrapped = p.X
			continue
		}
		if u, isUnary := unwrapped.(*ast.UnaryExpr); isUnary && u.Op == token.AND {
			unwrapped = u.X
			continue
		}
		break
	}
	if cl, isCL := unwrapped.(*ast.CompositeLit); isCL && isSelectorType(cl.Type, "http", "Client") {
		return true
	}

	lowerRecv := strings.ToLower(recvStr)
	return strings.Contains(lowerRecv, "client") ||
		strings.Contains(lowerRecv, "http") ||
		lowerRecv == "c" ||
		lowerRecv == "cli"
}

func collectHTTPClosedBodyVars(fset *token.FileSet, body *ast.BlockStmt) map[string]bool {
	closed := make(map[string]bool)
	if body == nil {
		return closed
	}
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil || sel.Sel.Name != "Close" {
			return true
		}
		if bodySel, ok := sel.X.(*ast.SelectorExpr); ok && bodySel.Sel != nil && bodySel.Sel.Name == "Body" {
			if recvIdent, ok := bodySel.X.(*ast.Ident); ok && recvIdent.Name != "" {
				closed[recvIdent.Name] = true
			}
			recvExpr := strings.TrimSpace(exprToString(fset, bodySel.X))
			if recvExpr != "" {
				closed[recvExpr] = true
			}
		}
		return true
	})
	return closed
}

func ensureHTTPSafetyTimeImport(filePath string, src string) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil || file == nil {
		return src
	}

	for _, imp := range file.Imports {
		if imp.Path != nil && strings.Trim(imp.Path.Value, "\"`") == "time" {
			return src
		}
	}

	lines := strings.Split(src, "\n")

	for _, decl := range file.Decls {
		genDecl, ok := decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.IMPORT {
			continue
		}
		if genDecl.Lparen.IsValid() {
			lparenLine := fset.Position(genDecl.Lparen).Line
			if lparenLine >= 1 && lparenLine <= len(lines) {
				updated := make([]string, 0, len(lines)+1)
				updated = append(updated, lines[:lparenLine]...)
				updated = append(updated, "\t\"time\"")
				updated = append(updated, lines[lparenLine:]...)
				return strings.Join(updated, "\n")
			}
		} else {
			impLine := fset.Position(genDecl.Pos()).Line
			if impLine >= 1 && impLine <= len(lines) {
				updated := make([]string, 0, len(lines)+1)
				updated = append(updated, lines[:impLine]...)
				updated = append(updated, "import \"time\"")
				updated = append(updated, lines[impLine:]...)
				return strings.Join(updated, "\n")
			}
		}
	}

	if file.Name != nil {
		pkgLine := fset.Position(file.Name.End()).Line
		if pkgLine >= 1 && pkgLine <= len(lines) {
			updated := make([]string, 0, len(lines)+2)
			updated = append(updated, lines[:pkgLine]...)
			updated = append(updated, "", "import \"time\"")
			updated = append(updated, lines[pkgLine:]...)
			return strings.Join(updated, "\n")
		}
	}

	return src
}

func formatASTNode(fset *token.FileSet, node ast.Node) string {
	if node == nil {
		return ""
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, node); err != nil {
		return ""
	}
	return strings.Join(strings.Fields(buf.String()), " ")
}
