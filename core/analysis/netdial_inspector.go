package analysis

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
)

type NetDialSafetyRequest struct {
	FilePath string `json:"filePath"`
	Content  string `json:"content"`
}

type NetDialSafetyIssue struct {
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
	editLine       int
}

type NetDialSafetySummary struct {
	TotalIssues              int `json:"totalIssues"`
	HighCount                int `json:"highCount"`
	MediumCount              int `json:"mediumCount"`
	LowCount                 int `json:"lowCount"`
	AutoFixableCount         int `json:"autoFixableCount"`
	DialWithoutTimeoutCount  int `json:"dialWithoutTimeoutCount"`
	PerRequestTransportCount int `json:"perRequestTransportCount"`
	WildcardListenBindCount  int `json:"wildcardListenBindCount"`
}

type NetDialSafetyResult struct {
	FilePath string               `json:"filePath"`
	Issues   []NetDialSafetyIssue `json:"issues"`
	Summary  NetDialSafetySummary `json:"summary"`
	Error    string               `json:"error,omitempty"`
}

type NetDialSafetyFixRequest struct {
	FilePath string   `json:"filePath"`
	Content  string   `json:"content"`
	IssueIDs []string `json:"issueIds"`
}

type NetDialSafetyFixResponse struct {
	FilePath        string               `json:"filePath"`
	ModifiedContent string               `json:"modifiedContent"`
	AppliedCount    int                  `json:"appliedCount"`
	RemainingIssues []NetDialSafetyIssue `json:"remainingIssues"`
	Summary         NetDialSafetySummary `json:"summary"`
	Error           string               `json:"error,omitempty"`
}

func InspectNetDialSafetyJSON(requestJSON string) (string, error) {
	var req NetDialSafetyRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return "", fmt.Errorf("invalid request JSON: %w", err)
	}
	res, err := InspectNetDialSafety(req)
	if err != nil {
		res.Error = err.Error()
	}
	out, marshalErr := json.Marshal(res)
	if marshalErr != nil {
		return "", marshalErr
	}
	return string(out), nil
}

func ApplyNetDialSafetyFixesJSON(requestJSON string) (string, error) {
	var req NetDialSafetyFixRequest
	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return "", fmt.Errorf("invalid request JSON: %w", err)
	}
	res := ApplyNetDialSafetyFixes(req)
	out, err := json.Marshal(res)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func InspectNetDialSafety(req NetDialSafetyRequest) (NetDialSafetyResult, error) {
	res := NetDialSafetyResult{
		FilePath: req.FilePath,
		Issues:   []NetDialSafetyIssue{},
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

	fillNetDialSafetyResult(&res, fset, file, req.Content)
	return res, nil
}

func fillNetDialSafetyResult(res *NetDialSafetyResult, fset *token.FileSet, file *ast.File, content string) {
	lines := strings.Split(content, "\n")

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		inspectNetDialInFunc(fset, fn, lines, &res.Issues)
	}

	res.Summary = summarizeNetDialIssues(res.Issues)
}

func inspectNetDialInFunc(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	lines []string,
	issues *[]NetDialSafetyIssue,
) {
	enclosingName := fn.Name.Name

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if n == nil {
			return false
		}

		if call, ok := n.(*ast.CallExpr); ok && isPkgFuncCall(call, "net", "Dial") && len(call.Args) == 2 {
			pos := fset.Position(call.Pos())
			endPos := fset.Position(call.End())
			lineText := comparableLineText(lines, pos.Line)
			origCall := renderSocketNode(fset, call)
			netArg := renderSocketNode(fset, call.Args[0])
			addrArg := renderSocketNode(fset, call.Args[1])
			fixedCall := fmt.Sprintf("net.DialTimeout(%s, %s, 10*time.Second)", netArg, addrArg)
			newLine := strings.Replace(lineText, origCall, fixedCall, 1)
			*issues = append(*issues, NetDialSafetyIssue{
				ID:             fmt.Sprintf("net_dial_without_timeout_or_context:%d:%d", pos.Line, pos.Column),
				Category:       "net_dial_without_timeout_or_context",
				Severity:       "high",
				Line:           pos.Line,
				Column:         pos.Column,
				EndLine:        endPos.Line,
				EndColumn:      endPos.Column,
				Title:          "net.Dial called without timeout or context",
				Message:        fmt.Sprintf("%s dials without a connection deadline or context.Context, risking indefinite goroutine hangs.", origCall),
				WhyItMatters:   "Unbounded TCP/Unix dials can block for minutes on blackholed routes or unresponsive peers.",
				OriginalCode:   origCall,
				SuggestedFix:   fixedCall,
				QuickFixTitle:  "Use net.DialTimeout With a 10-Second Timeout",
				CanAutoFix:     newLine != lineText,
				TargetIdent:    "net.Dial",
				EnclosingFunc:  enclosingName,
				LineText:       strings.TrimSpace(lineText),
				ReplacementRaw: newLine,
			})
		}

		if comp, ok := n.(*ast.CompositeLit); ok && isHTTPTransportCompositeLit(comp) {
			if valueIdent := disableKeepAlivesTrueValue(comp); valueIdent != nil {
				pos := fset.Position(comp.Pos())
				endPos := fset.Position(comp.End())
				valuePos := fset.Position(valueIdent.Pos())
				lineText := comparableLineText(lines, valuePos.Line)
				origLit := renderSocketNode(fset, comp)
				fixedLit := strings.Replace(origLit, "DisableKeepAlives: true", "DisableKeepAlives: false", 1)
				newLine := lineText
				if col := valuePos.Column - 1; col >= 0 && col+len("true") <= len(lineText) && lineText[col:col+len("true")] == "true" {
					newLine = lineText[:col] + "false" + lineText[col+len("true"):]
				}
				*issues = append(*issues, NetDialSafetyIssue{
					ID:             fmt.Sprintf("http_transport_disable_keepalives_per_request:%d:%d", pos.Line, pos.Column),
					Category:       "http_transport_disable_keepalives_per_request",
					Severity:       "medium",
					Line:           pos.Line,
					Column:         pos.Column,
					EndLine:        endPos.Line,
					EndColumn:      endPos.Column,
					Title:          "http.Transport disables keep-alives or connection pooling",
					Message:        fmt.Sprintf("%s sets DisableKeepAlives: true, forcing a fresh TCP/TLS handshake on every outbound request.", origLit),
					WhyItMatters:   "Disabling HTTP keep-alives under load exhausts ephemeral ports (TIME_WAIT) and degrades latency.",
					OriginalCode:   origLit,
					SuggestedFix:   fixedLit,
					QuickFixTitle:  "Enable Keep-Alives",
					CanAutoFix:     newLine != lineText,
					TargetIdent:    "http.Transport",
					EnclosingFunc:  enclosingName,
					LineText:       strings.TrimSpace(lineText),
					ReplacementRaw: newLine,
					editLine:       valuePos.Line,
				})
			}
		}

		if call, ok := n.(*ast.CallExpr); ok {
			addrIdx := -1
			if isPkgFuncCall(call, "net", "Listen") && len(call.Args) == 2 {
				addrIdx = 1
			} else if isPkgFuncCall(call, "http", "ListenAndServe") && len(call.Args) >= 1 {
				addrIdx = 0
			}
			if addrIdx >= 0 {
				addrVal := extractStringLitValue(call.Args[addrIdx])
				if strings.HasPrefix(addrVal, ":") && len(addrVal) > 1 {
					pos := fset.Position(call.Pos())
					endPos := fset.Position(call.End())
					lineText := comparableLineText(lines, pos.Line)
					origCall := renderSocketNode(fset, call)
					origArg := renderSocketNode(fset, call.Args[addrIdx])
					fixedArg := fmt.Sprintf(`"127.0.0.1%s"`, addrVal)
					fixedCall := strings.Replace(origCall, origArg, fixedArg, 1)
					newLine := strings.Replace(lineText, origCall, fixedCall, 1)
					*issues = append(*issues, NetDialSafetyIssue{
						ID:             fmt.Sprintf("net_listen_wildcard_without_bind_host:%d:%d", pos.Line, pos.Column),
						Category:       "net_listen_wildcard_without_bind_host",
						Severity:       "low",
						Line:           pos.Line,
						Column:         pos.Column,
						EndLine:        endPos.Line,
						EndColumn:      endPos.Column,
						Title:          fmt.Sprintf("Wildcard bind address %q exposes listener on all network interfaces", addrVal),
						Message:        fmt.Sprintf("%s binds %q (0.0.0.0/::) instead of an explicit loopback or interface address.", origCall, addrVal),
						WhyItMatters:   "Binding ':port' without a host exposes local/internal endpoints to untrusted LAN peers and triggers macOS firewall prompts.",
						OriginalCode:   origCall,
						SuggestedFix:   fixedCall,
						QuickFixTitle:  fmt.Sprintf("Bind to 127.0.0.1%s", addrVal),
						CanAutoFix:     newLine != lineText,
						TargetIdent:    addrVal,
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

func ApplyNetDialSafetyFixes(req NetDialSafetyFixRequest) NetDialSafetyFixResponse {
	inspectRes, _ := InspectNetDialSafety(NetDialSafetyRequest{
		FilePath: req.FilePath,
		Content:  req.Content,
	})
	if inspectRes.Error != "" {
		return NetDialSafetyFixResponse{
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
	needTimeImport := false
	replacedLines := map[int]bool{}

	for i := len(inspectRes.Issues) - 1; i >= 0; i-- {
		iss := inspectRes.Issues[i]
		if !iss.CanAutoFix || iss.ReplacementRaw == "" {
			continue
		}
		if !applyAll && !wanted[iss.ID] {
			continue
		}
		editLine := iss.Line
		if iss.editLine > 0 {
			editLine = iss.editLine
		}
		idx := editLine - 1
		if idx < 0 || idx >= len(lines) || replacedLines[editLine] {
			continue
		}
		lines[idx] = iss.ReplacementRaw
		replacedLines[editLine] = true
		applied++
		if iss.Category == "net_dial_without_timeout_or_context" {
			needTimeImport = true
		}
	}

	modified := strings.Join(lines, "\n")
	if needTimeImport && applied > 0 {
		modified = ensureSocketImportPath(modified, "time")
	}

	recheck, _ := InspectNetDialSafety(NetDialSafetyRequest{
		FilePath: req.FilePath,
		Content:  modified,
	})

	return NetDialSafetyFixResponse{
		FilePath:        req.FilePath,
		ModifiedContent: modified,
		AppliedCount:    applied,
		RemainingIssues: recheck.Issues,
		Summary:         recheck.Summary,
	}
}

func summarizeNetDialIssues(issues []NetDialSafetyIssue) NetDialSafetySummary {
	var s NetDialSafetySummary
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
		case "net_dial_without_timeout_or_context":
			s.DialWithoutTimeoutCount++
		case "http_transport_disable_keepalives_per_request":
			s.PerRequestTransportCount++
		case "net_listen_wildcard_without_bind_host":
			s.WildcardListenBindCount++
		}
	}
	return s
}

func isHTTPTransportCompositeLit(comp *ast.CompositeLit) bool {
	sel, ok := comp.Type.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Transport" {
		return false
	}
	id, ok := sel.X.(*ast.Ident)
	return ok && id.Name == "http"
}

func disableKeepAlivesTrueValue(comp *ast.CompositeLit) *ast.Ident {
	for _, elt := range comp.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		if k, ok := kv.Key.(*ast.Ident); ok && k.Name == "DisableKeepAlives" {
			if v, ok := kv.Value.(*ast.Ident); ok && v.Name == "true" {
				return v
			}
		}
	}
	return nil
}
