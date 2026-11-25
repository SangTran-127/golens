package analysis

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"sort"
	"strings"
)

type EnvConfigSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type EnvConfigSafetyIssue struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	FuncName           string `json:"funcName"`
	Expr               string `json:"expr"`
	Message            string `json:"message"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	ReplacementPreview string `json:"replacementPreview"`
	CanAutoFix         bool   `json:"canAutoFix"`
}

type EnvConfigSafetyInspectResult struct {
	Issues                              []EnvConfigSafetyIssue `json:"issues"`
	GetenvWithoutLookupOrFallbackCount  int                    `json:"getenvWithoutLookupOrFallbackCount"`
	UncheckedStrconvEnvParseCount       int                    `json:"uncheckedStrconvEnvParseCount"`
	HardcodedLocalhostInProdConfigCount int                    `json:"hardcodedLocalhostInProdConfigCount"`
	Error                               string                 `json:"error,omitempty"`
}

type EnvConfigSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type EnvConfigSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type envConfigEditCandidate struct {
	issue       EnvConfigSafetyIssue
	startOffset int
	endOffset   int
	replacement string
	needsOSImp  bool
}

func InspectEnvConfigSafety(payloadJSON string) string {
	var req EnvConfigSafetyInspectRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		return marshalEnvConfigInspectError("invalid payload: " + err.Error())
	}

	candidates, err := collectEnvConfigSafetyCandidates(req.Content, req.FilePath)
	if err != nil {
		return marshalEnvConfigInspectError(err.Error())
	}

	res := EnvConfigSafetyInspectResult{
		Issues: make([]EnvConfigSafetyIssue, 0, len(candidates)),
	}
	for _, c := range candidates {
		res.Issues = append(res.Issues, c.issue)
		switch c.issue.Category {
		case "getenv_without_lookupenv_or_fallback":
			res.GetenvWithoutLookupOrFallbackCount++
		case "unchecked_strconv_env_parse":
			res.UncheckedStrconvEnvParseCount++
		case "hardcoded_localhost_or_port_in_prod_config":
			res.HardcodedLocalhostInProdConfigCount++
		}
	}

	out, _ := json.Marshal(res)
	return string(out)
}

func ApplyEnvConfigSafetyFixes(payloadJSON string) string {
	var req EnvConfigSafetyFixRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		return marshalEnvConfigFixError("invalid payload: " + err.Error())
	}

	if req.All {
		current := req.Content
		totalFixed := 0
		needsOS := false
		for pass := 0; pass < 32; pass++ {
			candidates, err := collectEnvConfigSafetyCandidates(current, req.FilePath)
			if err != nil {
				if totalFixed > 0 {
					break
				}
				return marshalEnvConfigFixError(err.Error())
			}
			applied := false
			for _, c := range candidates {
				if !c.issue.CanAutoFix {
					continue
				}
				if c.startOffset < 0 || c.endOffset < c.startOffset || c.endOffset > len(current) {
					continue
				}
				current = current[:c.startOffset] + c.replacement + current[c.endOffset:]
				if c.needsOSImp {
					needsOS = true
				}
				totalFixed++
				applied = true
				break
			}
			if !applied {
				break
			}
		}
		if needsOS {
			current = ensureEnvConfigImportPath(current, "os")
		}
		formatted, fmtErr := format.Source([]byte(current))
		if fmtErr == nil {
			current = string(formatted)
		}
		out, _ := json.Marshal(EnvConfigSafetyFixResult{
			NewContent: current,
			FixedCount: totalFixed,
		})
		return string(out)
	}

	candidates, err := collectEnvConfigSafetyCandidates(req.Content, req.FilePath)
	if err != nil {
		return marshalEnvConfigFixError(err.Error())
	}

	var selected []envConfigEditCandidate
	for _, c := range candidates {
		if !c.issue.CanAutoFix {
			continue
		}
		if c.issue.ID == req.IssueID {
			selected = append(selected, c)
			break
		}
	}

	if len(selected) == 0 {
		out, _ := json.Marshal(EnvConfigSafetyFixResult{
			NewContent: req.Content,
			FixedCount: 0,
		})
		return string(out)
	}

	sort.Slice(selected, func(i, j int) bool {
		return selected[i].startOffset > selected[j].startOffset
	})

	updated := req.Content
	fixedCount := 0
	needsOS := false
	for _, c := range selected {
		if c.startOffset < 0 || c.endOffset < c.startOffset || c.endOffset > len(updated) {
			continue
		}
		updated = updated[:c.startOffset] + c.replacement + updated[c.endOffset:]
		if c.needsOSImp {
			needsOS = true
		}
		fixedCount++
	}

	if needsOS {
		updated = ensureEnvConfigImportPath(updated, "os")
	}

	formatted, fmtErr := format.Source([]byte(updated))
	if fmtErr == nil {
		updated = string(formatted)
	}

	out, _ := json.Marshal(EnvConfigSafetyFixResult{
		NewContent: updated,
		FixedCount: fixedCount,
	})
	return string(out)
}

func collectEnvConfigSafetyCandidates(content, filePath string) ([]envConfigEditCandidate, error) {
	if strings.TrimSpace(content) == "" {
		return nil, nil
	}
	filename := filePath
	if filename == "" {
		filename = "envconfig_inspect.go"
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, content, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("parse error: %w", err)
	}

	osAlias := "os"
	strconvAlias := "strconv"
	httpAlias := "http"
	netAlias := "net"
	hasOSImport := false
	for _, imp := range file.Imports {
		pathVal := strings.Trim(imp.Path.Value, `"`)
		switch pathVal {
		case "os":
			hasOSImport = true
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				osAlias = imp.Name.Name
			}
		case "strconv":
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				strconvAlias = imp.Name.Name
			}
		case "net/http":
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				httpAlias = imp.Name.Name
			}
		case "net":
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				netAlias = imp.Name.Name
			}
		}
	}

	var candidates []envConfigEditCandidate

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := fn.Name.Name
		checkedVars := collectCheckedEmptyStringVars(fn.Body)

		inspectSocketStatements(fn.Body.List, func(stmt ast.Stmt) {
			assign, ok := stmt.(*ast.AssignStmt)
			if !ok {
				return
			}

			if len(assign.Lhs) == 1 && len(assign.Rhs) == 1 {
				if ident, ok := assign.Lhs[0].(*ast.Ident); ok && ident.Name != "_" {
					if call, ok := assign.Rhs[0].(*ast.CallExpr); ok && isPkgFuncCall(call, osAlias, "Getenv") && len(call.Args) == 1 {
						varName := ident.Name
						if !checkedVars[varName] {
							pos := fset.Position(assign.Pos())
							stmtStart := pos.Offset
							stmtEnd := fset.Position(assign.End()).Offset
							indent := socketLineIndentAt(content, stmtStart)
							keyStr := renderSocketNode(fset, call.Args[0])
							assignText := strings.TrimSpace(content[stmtStart:stmtEnd])
							repl := fmt.Sprintf("%s\n%sif %s == \"\" {\n%s\t%s, _ = %s.LookupEnv(%s)\n%s}", assignText, indent, varName, indent, varName, osAlias, keyStr, indent)

							candidates = append(candidates, envConfigEditCandidate{
								issue: EnvConfigSafetyIssue{
									ID:                 fmt.Sprintf("getenv_without_lookupenv_or_fallback:%d:%d", pos.Line, pos.Column),
									Category:           "getenv_without_lookupenv_or_fallback",
									Severity:           "warning",
									Line:               pos.Line,
									Column:             pos.Column,
									FuncName:           funcName,
									Expr:               assignText,
									Message:            fmt.Sprintf("%s.Getenv(%s) is assigned to %q without checking for an empty or unset environment variable", osAlias, keyStr, varName),
									Suggestion:         fmt.Sprintf("Guard %s == \"\" or use %s.LookupEnv(%s) with an explicit fallback", varName, osAlias, keyStr),
									FixTitle:           "Add Empty-Value LookupEnv Guard",
									ReplacementPreview: repl,
									CanAutoFix:         true,
								},
								startOffset: stmtStart,
								endOffset:   stmtEnd,
								replacement: repl,
							})
						}
					}
				}
			}

			if len(assign.Lhs) == 2 && len(assign.Rhs) == 1 {
				valIdent, ok0 := assign.Lhs[0].(*ast.Ident)
				blankIdent, ok1 := assign.Lhs[1].(*ast.Ident)
				if ok0 && ok1 && valIdent.Name != "_" && blankIdent.Name == "_" {
					if call, ok := assign.Rhs[0].(*ast.CallExpr); ok && isStrconvParseCall(call, strconvAlias) {
						pos := fset.Position(assign.Pos())
						stmtStart := pos.Offset
						stmtEnd := fset.Position(assign.End()).Offset
						indent := socketLineIndentAt(content, stmtStart)
						callStr := renderSocketNode(fset, call)
						errVar := valIdent.Name + "Err"
						defaultVal := defaultLiteralForStrconv(call)
						repl := fmt.Sprintf("%s, %s %s %s\n%sif %s != nil {\n%s\t%s = %s\n%s}", valIdent.Name, errVar, assign.Tok.String(), callStr, indent, errVar, indent, valIdent.Name, defaultVal, indent)

						candidates = append(candidates, envConfigEditCandidate{
							issue: EnvConfigSafetyIssue{
								ID:                 fmt.Sprintf("unchecked_strconv_env_parse:%d:%d", pos.Line, pos.Column),
								Category:           "unchecked_strconv_env_parse",
								Severity:           "warning",
								Line:               pos.Line,
								Column:             pos.Column,
								FuncName:           funcName,
								Expr:               strings.TrimSpace(content[stmtStart:stmtEnd]),
								Message:            fmt.Sprintf("Ignored error from %s silently falls back to zero value when configuration input is malformed", callStr),
								Suggestion:         "Capture the parse error and explicitly set a safe fallback value",
								FixTitle:           "Handle strconv Parse Error Explicitly",
								ReplacementPreview: repl,
								CanAutoFix:         true,
							},
							startOffset: stmtStart,
							endOffset:   stmtEnd,
							replacement: repl,
						})
					}
				}
			}
		})

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			var addrArg ast.Expr
			if isPkgFuncCall(call, httpAlias, "ListenAndServe") && len(call.Args) >= 1 {
				addrArg = call.Args[0]
			} else if isPkgFuncCall(call, netAlias, "Listen") && len(call.Args) >= 2 {
				addrArg = call.Args[1]
			}
			if addrArg == nil {
				return true
			}
			lit, ok := addrArg.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			rawAddr := strings.Trim(lit.Value, `"`)
			if !strings.HasPrefix(rawAddr, "localhost:") && !strings.HasPrefix(rawAddr, "127.0.0.1:") {
				return true
			}
			pos := fset.Position(lit.Pos())
			startOff := fset.Position(lit.Pos()).Offset
			endOff := fset.Position(lit.End()).Offset
			repl := fmt.Sprintf("%s.Getenv(\"LISTEN_ADDR\")", osAlias)

			candidates = append(candidates, envConfigEditCandidate{
				issue: EnvConfigSafetyIssue{
					ID:                 fmt.Sprintf("hardcoded_localhost_or_port_in_prod_config:%d:%d", pos.Line, pos.Column),
					Category:           "hardcoded_localhost_or_port_in_prod_config",
					Severity:           "warning",
					Line:               pos.Line,
					Column:             pos.Column,
					FuncName:           funcName,
					Expr:               lit.Value,
					Message:            fmt.Sprintf("Hardcoded loopback bind address %s prevents external traffic inside containers and production environments", lit.Value),
					Suggestion:         fmt.Sprintf("Read bind address from %s.Getenv(\"LISTEN_ADDR\") or bind to \":port\"", osAlias),
					FixTitle:           "Read Bind Address from os.Getenv(\"LISTEN_ADDR\")",
					ReplacementPreview: repl,
					CanAutoFix:         true,
				},
				startOffset: startOff,
				endOffset:   endOff,
				replacement: repl,
				needsOSImp:  !hasOSImport,
			})
			return true
		})
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].issue.Line != candidates[j].issue.Line {
			return candidates[i].issue.Line < candidates[j].issue.Line
		}
		return candidates[i].issue.Column < candidates[j].issue.Column
	})

	return candidates, nil
}

func collectCheckedEmptyStringVars(body *ast.BlockStmt) map[string]bool {
	res := make(map[string]bool)
	ast.Inspect(body, func(n ast.Node) bool {
		switch expr := n.(type) {
		case *ast.BinaryExpr:
			if expr.Op == token.EQL || expr.Op == token.NEQ {
				if ident, ok := expr.X.(*ast.Ident); ok && isEmptyStringLit(expr.Y) {
					res[ident.Name] = true
				}
				if ident, ok := expr.Y.(*ast.Ident); ok && isEmptyStringLit(expr.X) {
					res[ident.Name] = true
				}
			}
		case *ast.CallExpr:
			if ident, ok := expr.Fun.(*ast.Ident); ok && ident.Name == "len" && len(expr.Args) == 1 {
				if argIdent, ok := expr.Args[0].(*ast.Ident); ok {
					res[argIdent.Name] = true
				}
			}
		}
		return true
	})
	return res
}

func isEmptyStringLit(expr ast.Expr) bool {
	lit, ok := expr.(*ast.BasicLit)
	return ok && lit.Kind == token.STRING && (lit.Value == `""` || lit.Value == "``")
}

func isPkgFuncCall(call *ast.CallExpr, pkgAlias, fnName string) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != fnName {
		return false
	}
	ident, ok := sel.X.(*ast.Ident)
	return ok && ident.Name == pkgAlias
}

func isStrconvParseCall(call *ast.CallExpr, strconvAlias string) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	ident, ok := sel.X.(*ast.Ident)
	if !ok || ident.Name != strconvAlias {
		return false
	}
	switch sel.Sel.Name {
	case "Atoi", "ParseInt", "ParseUint", "ParseFloat", "ParseBool":
		return true
	}
	return false
}

func defaultLiteralForStrconv(call *ast.CallExpr) string {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if ok && sel.Sel.Name == "ParseBool" {
		return "false"
	}
	return "0"
}

func ensureEnvConfigImportPath(src string, pkgPath string) string {
	return ensureSocketImportPath(src, pkgPath)
}

func marshalEnvConfigInspectError(msg string) string {
	out, _ := json.Marshal(EnvConfigSafetyInspectResult{
		Issues: []EnvConfigSafetyIssue{},
		Error:  msg,
	})
	return string(out)
}

func marshalEnvConfigFixError(msg string) string {
	out, _ := json.Marshal(EnvConfigSafetyFixResult{
		Error: msg,
	})
	return string(out)
}
