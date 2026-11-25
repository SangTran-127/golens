package analysis

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"strings"
)

type CookieCORSSafetyRequest struct {
	FilePath string `json:"filePath"`
	Content  string `json:"content"`
}

type CookieCORSSafetyIssue struct {
	ID             string `json:"id"`
	Category       string `json:"category"`
	Severity       string `json:"severity"`
	Line           int    `json:"line"`
	Column         int    `json:"column"`
	EndLine        int    `json:"endLine"`
	EndColumn      int    `json:"endColumn"`
	Title          string `json:"title"`
	Message        string `json:"message"`
	WhyItMatters   string `json:"whyItMatters"`
	OriginalCode   string `json:"originalCode"`
	SuggestedFix   string `json:"suggestedFix"`
	QuickFixTitle  string `json:"quickFixTitle"`
	CanAutoFix     bool   `json:"canAutoFix"`
	TargetIdent    string `json:"targetIdent"`
	EnclosingFunc  string `json:"enclosingFunc"`
	LineText       string `json:"lineText"`
	ReplacementRaw string `json:"-"`
}

type CookieCORSSafetySummary struct {
	TotalIssues                  int `json:"totalIssues"`
	HighCount                    int `json:"highCount"`
	MediumCount                  int `json:"mediumCount"`
	LowCount                     int `json:"lowCount"`
	AutoFixableCount             int `json:"autoFixableCount"`
	CookieMissingFlagsCount      int `json:"cookieMissingFlagsCount"`
	CORSWildcardCredentialsCount int `json:"corsWildcardCredentialsCount"`
	MissingNoSniffHeaderCount    int `json:"missingNoSniffHeaderCount"`
}

type CookieCORSSafetyResult struct {
	FilePath string                  `json:"filePath"`
	Issues   []CookieCORSSafetyIssue `json:"issues"`
	Summary  CookieCORSSafetySummary `json:"summary"`
	Error    string                  `json:"error,omitempty"`
}

type CookieCORSSafetyFixRequest struct {
	FilePath string   `json:"filePath"`
	Content  string   `json:"content"`
	IssueIDs []string `json:"issueIds"`
}

type CookieCORSSafetyFixResponse struct {
	FilePath        string                  `json:"filePath"`
	ModifiedContent string                  `json:"modifiedContent"`
	AppliedCount    int                     `json:"appliedCount"`
	RemainingIssues []CookieCORSSafetyIssue `json:"remainingIssues"`
	Summary         CookieCORSSafetySummary `json:"summary"`
	Error           string                  `json:"error,omitempty"`
}

func InspectCookieCORSSafetyJSON(requestJSON string) (string, error) {
	var req CookieCORSSafetyRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return "", fmt.Errorf("invalid request JSON: %w", err)
	}
	res, err := InspectCookieCORSSafety(req)
	if err != nil {
		res.Error = err.Error()
	}
	out, marshalErr := json.Marshal(res)
	if marshalErr != nil {
		return "", marshalErr
	}
	return string(out), nil
}

func ApplyCookieCORSSafetyFixesJSON(requestJSON string) (string, error) {
	var req CookieCORSSafetyFixRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return "", fmt.Errorf("invalid request JSON: %w", err)
	}
	res := ApplyCookieCORSSafetyFixes(req)
	out, err := json.Marshal(res)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func InspectCookieCORSSafety(req CookieCORSSafetyRequest) (CookieCORSSafetyResult, error) {
	res := CookieCORSSafetyResult{
		FilePath: req.FilePath,
		Issues:   []CookieCORSSafetyIssue{},
	}
	if strings.TrimSpace(req.Content) == "" {
		return res, nil
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, req.FilePath, req.Content, parser.ParseComments)
	if err != nil {
		res.Error = fmt.Sprintf("parse error: %v", err)
		return res, nil
	}

	lines := strings.Split(req.Content, "\n")

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		inspectCookieCORSInFunc(fset, fn, lines, &res.Issues)
	}

	res.Summary = summarizeCookieCORSIssues(res.Issues)
	return res, nil
}

func inspectCookieCORSInFunc(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	lines []string,
	issues *[]CookieCORSSafetyIssue,
) {
	enclosingName := fn.Name.Name
	hasAllowCredentials := blockSetsAllowCredentials(fset, fn.Body)
	hasNoSniffHeader := blockSetsNoSniffHeader(fset, fn.Body)
	reportedNoSniff := false

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if n == nil {
			return false
		}

		if comp, ok := n.(*ast.CompositeLit); ok && isHTTPCookieCompositeLit(comp) {
			hasHttpOnly, hasSecure, hasSameSite := checkCookieSecurityFields(comp)
			if !hasHttpOnly || !hasSecure || !hasSameSite {
				pos := fset.Position(comp.Pos())
				endPos := fset.Position(comp.End())
				lineText := comparableLineText(lines, pos.Line)
				origLit := renderSocketNode(fset, comp)
				missing := make([]string, 0)
				addFields := make([]string, 0)
				if !hasHttpOnly {
					missing = append(missing, "HttpOnly: true")
					addFields = append(addFields, "HttpOnly: true")
				}
				if !hasSecure {
					missing = append(missing, "Secure: true")
					addFields = append(addFields, "Secure: true")
				}
				if !hasSameSite {
					missing = append(missing, "SameSite: http.SameSiteLaxMode")
					addFields = append(addFields, "SameSite: http.SameSiteLaxMode")
				}
				fixedLit := injectFieldsIntoCompositeLit(origLit, addFields)
				newLine := lineText
				canFix := false
				if pos.Line == endPos.Line && strings.Contains(lineText, origLit) {
					newLine = strings.Replace(lineText, origLit, fixedLit, 1)
					canFix = newLine != lineText
				} else if endPos.Line >= 1 && endPos.Line <= len(lines) {
					endLineText := comparableLineText(lines, endPos.Line)
					indent := pipelineLineIndent(endLineText) + "\t"
					inserted := indent + strings.Join(addFields, ", ") + ",\n" + endLineText
					pos.Line = endPos.Line
					lineText = endLineText
					newLine = inserted
					canFix = true
				}
				*issues = append(*issues, CookieCORSSafetyIssue{
					ID:             fmt.Sprintf("cookie_missing_secure_or_httponly:%d:%d", pos.Line, pos.Column),
					Category:       "cookie_missing_secure_or_httponly",
					Severity:       "high",
					Line:           pos.Line,
					Column:         pos.Column,
					EndLine:        endPos.Line,
					EndColumn:      endPos.Column,
					Title:          fmt.Sprintf("http.Cookie missing %s", strings.Join(missing, ", ")),
					Message:        fmt.Sprintf("http.Cookie literal omits %s, leaving cookies exposed to XSS script access, cleartext interception, or cross-site request forgery.", strings.Join(missing, ", ")),
					WhyItMatters:   "Session and state cookies must set HttpOnly, Secure, and an explicit SameSite policy to prevent XSS token theft and CSRF.",
					OriginalCode:   strings.TrimSpace(lineText),
					SuggestedFix:   strings.Join(addFields, ", "),
					QuickFixTitle:  "Add HttpOnly, Secure, and SameSite=Lax flags",
					CanAutoFix:     canFix,
					TargetIdent:    "http.Cookie",
					EnclosingFunc:  enclosingName,
					LineText:       strings.TrimSpace(lineText),
					ReplacementRaw: newLine,
				})
			}
		}

		if call, ok := n.(*ast.CallExpr); ok && isHeaderSetOrAddCall(call) && len(call.Args) == 2 {
			headerName := extractStringLitValue(call.Args[0])
			if strings.EqualFold(headerName, "Access-Control-Allow-Origin") {
				valLit := extractStringLitValue(call.Args[1])
				isReflectedOrigin := isRequestOriginGetExpr(fset, call.Args[1])
				if (valLit == "*" && hasAllowCredentials) || isReflectedOrigin {
					pos := fset.Position(call.Pos())
					endPos := fset.Position(call.End())
					lineText := comparableLineText(lines, pos.Line)
					origCall := renderSocketNode(fset, call)
					recvExpr := extractHeaderReceiverPrefix(fset, call)
					fixedCall := fmt.Sprintf(`%s.Set("Access-Control-Allow-Origin", "https://trusted.example.com")`, recvExpr)
					newLine := strings.Replace(lineText, origCall, fixedCall, 1)
					*issues = append(*issues, CookieCORSSafetyIssue{
						ID:             fmt.Sprintf("cors_wildcard_with_credentials:%d:%d", pos.Line, pos.Column),
						Category:       "cors_wildcard_with_credentials",
						Severity:       "high",
						Line:           pos.Line,
						Column:         pos.Column,
						EndLine:        endPos.Line,
						EndColumn:      endPos.Column,
						Title:          "Permissive or reflected Access-Control-Allow-Origin with credentials",
						Message:        fmt.Sprintf("%s allows untrusted origins or reflects raw Origin headers while credentials may be enabled.", origCall),
						WhyItMatters:   "Reflecting arbitrary Origin headers or combining wildcard CORS with credentials lets any third-party site read authenticated user responses.",
						OriginalCode:   origCall,
						SuggestedFix:   fixedCall,
						QuickFixTitle:  "Restrict Access-Control-Allow-Origin to explicit trusted origin",
						CanAutoFix:     newLine != lineText,
						TargetIdent:    "Access-Control-Allow-Origin",
						EnclosingFunc:  enclosingName,
						LineText:       strings.TrimSpace(lineText),
						ReplacementRaw: newLine,
					})
				}
			}

			if !hasNoSniffHeader && !reportedNoSniff && strings.EqualFold(headerName, "Content-Type") {
				ctVal := strings.ToLower(extractStringLitValue(call.Args[1]))
				if strings.Contains(ctVal, "text/html") || strings.Contains(ctVal, "application/json") {
					reportedNoSniff = true
					pos := fset.Position(call.Pos())
					endPos := fset.Position(call.End())
					lineText := comparableLineText(lines, pos.Line)
					indent := pipelineLineIndent(lineText)
					recvExpr := extractHeaderReceiverPrefix(fset, call)
					origCall := renderSocketNode(fset, call)
					noSniffStmt := fmt.Sprintf(`%s.Set("X-Content-Type-Options", "nosniff")`, recvExpr)
					newLine := fmt.Sprintf("%s\n%s%s", lineText, indent, noSniffStmt)
					*issues = append(*issues, CookieCORSSafetyIssue{
						ID:             fmt.Sprintf("missing_security_nosniff_or_frame_headers:%d:%d", pos.Line, pos.Column),
						Category:       "missing_security_nosniff_or_frame_headers",
						Severity:       "low",
						Line:           pos.Line,
						Column:         pos.Column,
						EndLine:        endPos.Line,
						EndColumn:      endPos.Column,
						Title:          "Content-Type set without X-Content-Type-Options: nosniff",
						Message:        fmt.Sprintf("%s sets %q without pairing X-Content-Type-Options: nosniff.", origCall, ctVal),
						WhyItMatters:   "Without X-Content-Type-Options: nosniff, browsers may MIME-sniff responses and execute uploaded or reflected content as HTML/JavaScript.",
						OriginalCode:   origCall,
						SuggestedFix:   fmt.Sprintf("%s\n%s", origCall, noSniffStmt),
						QuickFixTitle:  `Add w.Header().Set("X-Content-Type-Options", "nosniff")`,
						CanAutoFix:     true,
						TargetIdent:    "X-Content-Type-Options",
						EnclosingFunc:  enclosingName,
						LineText:       strings.TrimSpace(lineText),
						ReplacementRaw: newLine,
					})
				}
			}
		}

		return true
	})
}

func ApplyCookieCORSSafetyFixes(req CookieCORSSafetyFixRequest) CookieCORSSafetyFixResponse {
	inspectRes, _ := InspectCookieCORSSafety(CookieCORSSafetyRequest{
		FilePath: req.FilePath,
		Content:  req.Content,
	})
	if inspectRes.Error != "" {
		return CookieCORSSafetyFixResponse{
			FilePath:        req.FilePath,
			ModifiedContent: req.Content,
			Error:           inspectRes.Error,
		}
	}

	wanted := map[string]bool{}
	for _, id := range req.IssueIDs {
		wanted[id] = true
	}
	applyAll := len(wanted) == 0

	lines := strings.Split(req.Content, "\n")
	applied := 0
	replacedLines := map[int]bool{}

	for i := len(inspectRes.Issues) - 1; i >= 0; i-- {
		iss := inspectRes.Issues[i]
		if !iss.CanAutoFix || iss.ReplacementRaw == "" {
			continue
		}
		if !applyAll && !wanted[iss.ID] {
			continue
		}
		idx := iss.Line - 1
		if idx < 0 || idx >= len(lines) || replacedLines[iss.Line] {
			continue
		}
		lines[idx] = iss.ReplacementRaw
		replacedLines[iss.Line] = true
		applied++
	}

	modified := strings.Join(lines, "\n")
	if formatted, err := format.Source([]byte(modified)); err == nil {
		modified = string(formatted)
	}
	recheck, _ := InspectCookieCORSSafety(CookieCORSSafetyRequest{
		FilePath: req.FilePath,
		Content:  modified,
	})

	return CookieCORSSafetyFixResponse{
		FilePath:        req.FilePath,
		ModifiedContent: modified,
		AppliedCount:    applied,
		RemainingIssues: recheck.Issues,
		Summary:         recheck.Summary,
	}
}

func summarizeCookieCORSIssues(issues []CookieCORSSafetyIssue) CookieCORSSafetySummary {
	var s CookieCORSSafetySummary
	s.TotalIssues = len(issues)
	for _, iss := range issues {
		switch iss.Severity {
		case "high":
			s.HighCount++
		case "medium":
			s.MediumCount++
		default:
			s.LowCount++
		}
		if iss.CanAutoFix {
			s.AutoFixableCount++
		}
		switch iss.Category {
		case "cookie_missing_secure_or_httponly":
			s.CookieMissingFlagsCount++
		case "cors_wildcard_with_credentials":
			s.CORSWildcardCredentialsCount++
		case "missing_security_nosniff_or_frame_headers":
			s.MissingNoSniffHeaderCount++
		}
	}
	return s
}

func isHTTPCookieCompositeLit(comp *ast.CompositeLit) bool {
	sel, ok := comp.Type.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Cookie" {
		return false
	}
	id, ok := sel.X.(*ast.Ident)
	return ok && id.Name == "http"
}

func checkCookieSecurityFields(comp *ast.CompositeLit) (hasHttpOnly, hasSecure, hasSameSite bool) {
	for _, elt := range comp.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		keyId, ok := kv.Key.(*ast.Ident)
		if !ok {
			continue
		}
		switch keyId.Name {
		case "HttpOnly":
			if id, ok := kv.Value.(*ast.Ident); ok && id.Name == "true" {
				hasHttpOnly = true
			}
		case "Secure":
			if id, ok := kv.Value.(*ast.Ident); ok && id.Name == "true" {
				hasSecure = true
			}
		case "SameSite":
			hasSameSite = true
		}
	}
	return
}

func injectFieldsIntoCompositeLit(origLit string, fields []string) string {
	idx := strings.LastIndex(origLit, "}")
	if idx < 0 {
		return origLit
	}
	prefix := strings.TrimRight(origLit[:idx], " \t")
	sep := ", "
	if strings.HasSuffix(prefix, "{") || strings.HasSuffix(prefix, ",") {
		sep = " "
	}
	return prefix + sep + strings.Join(fields, ", ") + "}"
}

func isHeaderSetOrAddCall(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return false
	}
	return sel.Sel.Name == "Set" || sel.Sel.Name == "Add"
}

func extractHeaderReceiverPrefix(fset *token.FileSet, call *ast.CallExpr) string {
	if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
		return renderSocketNode(fset, sel.X)
	}
	return "w.Header()"
}

func extractStringLitValue(expr ast.Expr) string {
	lit, ok := expr.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return ""
	}
	return strings.Trim(lit.Value, `"`+"`")
}

func isRequestOriginGetExpr(fset *token.FileSet, expr ast.Expr) bool {
	raw := renderSocketNode(fset, expr)
	return strings.Contains(raw, `.Header.Get("Origin")`)
}

func blockSetsAllowCredentials(_ *token.FileSet, body *ast.BlockStmt) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || !isHeaderSetOrAddCall(call) || len(call.Args) != 2 {
			return true
		}
		if strings.EqualFold(extractStringLitValue(call.Args[0]), "Access-Control-Allow-Credentials") &&
			strings.EqualFold(extractStringLitValue(call.Args[1]), "true") {
			found = true
			return false
		}
		return true
	})
	return found
}

func blockSetsNoSniffHeader(_ *token.FileSet, body *ast.BlockStmt) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || !isHeaderSetOrAddCall(call) || len(call.Args) != 2 {
			return true
		}
		if strings.EqualFold(extractStringLitValue(call.Args[0]), "X-Content-Type-Options") {
			found = true
			return false
		}
		return true
	})
	return found
}
