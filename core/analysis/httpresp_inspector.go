package analysis

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"strings"
)

func loadHTTPRespSource(filePath, content string) (string, error) {
	if content != "" {
		return content, nil
	}
	if filePath == "" {
		return "", fmt.Errorf("missing file path or content")
	}
	raw, err := os.ReadFile(filePath)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func extractLeadingIndent(line string) string {
	idx := 0
	for idx < len(line) && (line[idx] == ' ' || line[idx] == '\t') {
		idx++
	}
	return line[:idx]
}

type HTTPRespSafetyIssue struct {
	ID          string `json:"id"`
	Category    string `json:"category"`
	Severity    string `json:"severity"`
	HandlerName string `json:"handlerName"`
	Line        int    `json:"line"`
	EndLine     int    `json:"endLine"`
	Message     string `json:"message"`
	FixTitle    string `json:"fixTitle"`
	CanAutoFix  bool   `json:"canAutoFix"`
	Original    string `json:"original"`
	Replacement string `json:"replacement"`
	editStart   int
	editEnd     int
}

type HTTPRespSafetyReport struct {
	FilePath                 string                `json:"filePath"`
	TotalIssues              int                   `json:"totalIssues"`
	WriteHeaderCount         int                   `json:"writeHeaderCount"`
	MissingContentTypeCount  int                   `json:"missingContentTypeCount"`
	UnvalidatedRedirectCount int                   `json:"unvalidatedRedirectCount"`
	Issues                   []HTTPRespSafetyIssue `json:"issues"`
}

type HTTPRespSafetyFixResult struct {
	FilePath     string               `json:"filePath"`
	AppliedCount int                  `json:"appliedCount"`
	NewContent   string               `json:"newContent"`
	Report       HTTPRespSafetyReport `json:"report"`
}

func InspectHTTPRespSafety(filePath, content string) (*HTTPRespSafetyReport, error) {
	src, err := loadHTTPRespSource(filePath, content)
	if err != nil {
		return nil, err
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("parse Go file: %w", err)
	}
	return inspectHTTPRespSafetyAST(fset, file, filePath, src), nil
}

func inspectHTTPRespSafetyAST(fset *token.FileSet, file *ast.File, filePath, src string) *HTTPRespSafetyReport {
	lines := strings.Split(src, "\n")
	report := &HTTPRespSafetyReport{
		FilePath: filePath,
		Issues:   []HTTPRespSafetyIssue{},
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		writerName, reqName := detectHTTPHandlerParams(fset, fn)
		if writerName == "" {
			writerName = "w"
		}
		if reqName == "" {
			reqName = "r"
		}
		inspectFuncForHTTPRespIssues(fset, fn, writerName, reqName, lines, report)
	}

	return report
}

func detectHTTPHandlerParams(fset *token.FileSet, fn *ast.FuncDecl) (writerName string, reqName string) {
	if fn.Type == nil || fn.Type.Params == nil {
		return "", ""
	}
	for _, field := range fn.Type.Params.List {
		typeStr := exprToString(fset, field.Type)
		if strings.HasSuffix(typeStr, "ResponseWriter") && len(field.Names) > 0 {
			writerName = field.Names[0].Name
		}
		if strings.HasSuffix(typeStr, "Request") && len(field.Names) > 0 {
			reqName = field.Names[0].Name
		}
	}
	return writerName, reqName
}

func inspectFuncForHTTPRespIssues(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	writerName string,
	reqName string,
	lines []string,
	report *HTTPRespSafetyReport,
) {
	handlerName := fn.Name.Name
	firstBodyWriteLine := 0
	firstBodyWriteIdx := -1
	firstCommitLine := 0
	firstCommitIdx := -1
	hasContentTypeSet := false
	stmts := fn.Body.List

	for idx, stmt := range stmts {
		lineNum := fset.Position(stmt.Pos()).Line
		if lineNum < 1 || lineNum > len(lines) {
			continue
		}
		lineText := lines[lineNum-1]
		trimmed := strings.TrimSpace(lineText)
		indent := extractLeadingIndent(lineText)

		if strings.Contains(trimmed, writerName+".Header().Set(") && strings.Contains(strings.ToLower(trimmed), "content-type") {
			hasContentTypeSet = true
		}

		isWriteHeader := strings.HasPrefix(trimmed, writerName+".WriteHeader(")
		isHeaderSet := strings.HasPrefix(trimmed, writerName+".Header().Set(")
		if (isWriteHeader || isHeaderSet) && firstBodyWriteLine > 0 && firstBodyWriteLine < lineNum {
			targetIdx, targetLine, callName := firstBodyWriteIdx, firstBodyWriteLine, "WriteHeader"
			if isHeaderSet {
				targetIdx, targetLine, callName = firstCommitIdx, firstCommitLine, "Header().Set"
			}
			canFix := stmtOwnsLine(fset, stmts, idx) && !stmtUsesNamesDeclaredIn(stmt, stmts[targetIdx:idx])
			origBlock := strings.Join(lines[targetLine-1:lineNum], "\n")
			reordered := append([]string{lines[lineNum-1]}, lines[targetLine-1:lineNum-1]...)
			replBlock := strings.Join(reordered, "\n")
			issueID := fmt.Sprintf("httpresp_order_%d", lineNum)
			fixTitle := ""
			if canFix {
				fixTitle = fmt.Sprintf("Move %s Before the Body Write", callName)
			}
			report.Issues = append(report.Issues, HTTPRespSafetyIssue{
				ID:          issueID,
				Category:    "writeheader_after_write",
				Severity:    "error",
				HandlerName: handlerName,
				Line:        firstBodyWriteLine,
				EndLine:     lineNum,
				Message:     fmt.Sprintf("'%s' called on line %d after response body was already written on line %d; headers/status changes after Write() are ignored", trimmed, lineNum, firstBodyWriteLine),
				FixTitle:    fixTitle,
				CanAutoFix:  canFix,
				Original:    origBlock,
				Replacement: replBlock,
				editStart:   targetLine,
				editEnd:     lineNum,
			})
			report.WriteHeaderCount++
			report.TotalIssues++
		}

		isJSONEncode := strings.Contains(trimmed, "json.NewEncoder("+writerName+").Encode(")
		if isJSONEncode && !hasContentTypeSet {
			insertLine, insertIndent := lineNum, indent
			if firstCommitLine > 0 {
				insertLine = firstCommitLine
				insertIndent = extractLeadingIndent(lines[insertLine-1])
			}
			issueID := fmt.Sprintf("httpresp_ctype_%d", lineNum)
			repl := fmt.Sprintf("%s%s.Header().Set(\"Content-Type\", \"application/json; charset=utf-8\")\n%s", insertIndent, writerName, lines[insertLine-1])
			report.Issues = append(report.Issues, HTTPRespSafetyIssue{
				ID:          issueID,
				Category:    "missing_content_type_before_write",
				Severity:    "warning",
				HandlerName: handlerName,
				Line:        lineNum,
				EndLine:     lineNum,
				Message:     fmt.Sprintf("JSON encoded to '%s' without setting Content-Type header beforehand (Go defaults to text/plain sniffing)", writerName),
				FixTitle:    "Set the JSON Content-Type Header",
				CanAutoFix:  true,
				Original:    lines[insertLine-1],
				Replacement: repl,
				editStart:   insertLine,
				editEnd:     insertLine,
			})
			report.MissingContentTypeCount++
			report.TotalIssues++
		}

		if isBodyWriteStmt(trimmed, writerName) && firstBodyWriteLine == 0 {
			firstBodyWriteLine = lineNum
			firstBodyWriteIdx = idx
		}
		if (isWriteHeader || isBodyWriteStmt(trimmed, writerName)) && firstCommitLine == 0 {
			firstCommitLine = lineNum
			firstCommitIdx = idx
		}

		if strings.Contains(trimmed, "http.Redirect(") &&
			(strings.Contains(trimmed, reqName+".URL.Query().Get(") || strings.Contains(trimmed, reqName+".FormValue(")) {
			issueID := fmt.Sprintf("httpresp_redirect_%d", lineNum)
			report.Issues = append(report.Issues, HTTPRespSafetyIssue{
				ID:          issueID,
				Category:    "unvalidated_http_redirect",
				Severity:    "error",
				HandlerName: handlerName,
				Line:        lineNum,
				EndLine:     lineNum,
				Message:     "http.Redirect target comes directly from unvalidated query/form parameter (Open Redirect risk)",
				Original:    lineText,
			})
			report.UnvalidatedRedirectCount++
			report.TotalIssues++
		}
	}
}

func stmtOwnsLine(fset *token.FileSet, stmts []ast.Stmt, idx int) bool {
	line := fset.Position(stmts[idx].Pos()).Line
	if fset.Position(stmts[idx].End()).Line != line {
		return false
	}
	if idx > 0 && fset.Position(stmts[idx-1].End()).Line == line {
		return false
	}
	if idx+1 < len(stmts) && fset.Position(stmts[idx+1].Pos()).Line == line {
		return false
	}
	return true
}

func stmtUsesNamesDeclaredIn(stmt ast.Stmt, earlier []ast.Stmt) bool {
	declared := make(map[string]bool)
	for _, s := range earlier {
		switch d := s.(type) {
		case *ast.AssignStmt:
			if d.Tok == token.DEFINE {
				for _, lhs := range d.Lhs {
					if ident, ok := lhs.(*ast.Ident); ok {
						declared[ident.Name] = true
					}
				}
			}
		case *ast.DeclStmt:
			if gd, ok := d.Decl.(*ast.GenDecl); ok {
				for _, spec := range gd.Specs {
					switch sp := spec.(type) {
					case *ast.ValueSpec:
						for _, name := range sp.Names {
							declared[name.Name] = true
						}
					case *ast.TypeSpec:
						declared[sp.Name.Name] = true
					}
				}
			}
		}
	}
	if len(declared) == 0 {
		return false
	}
	used := false
	ast.Inspect(stmt, func(n ast.Node) bool {
		if ident, ok := n.(*ast.Ident); ok && declared[ident.Name] {
			used = true
		}
		return !used
	})
	return used
}

func isBodyWriteStmt(trimmed, writerName string) bool {
	if strings.Contains(trimmed, writerName+".Write(") {
		return true
	}
	if strings.Contains(trimmed, "json.NewEncoder("+writerName+").Encode(") {
		return true
	}
	if strings.Contains(trimmed, "fmt.Fprint("+writerName+",") ||
		strings.Contains(trimmed, "fmt.Fprintf("+writerName+",") ||
		strings.Contains(trimmed, "fmt.Fprintln("+writerName+",") {
		return true
	}
	return false
}

func ApplyHTTPRespSafetyFix(filePath, content, issueID string, applyAll bool) (*HTTPRespSafetyFixResult, error) {
	src, err := loadHTTPRespSource(filePath, content)
	if err != nil {
		return nil, err
	}

	report, err := InspectHTTPRespSafety(filePath, src)
	if err != nil {
		return nil, err
	}

	current := src
	applied := 0
	for attempt := 0; attempt <= len(report.Issues); attempt++ {
		var target *HTTPRespSafetyIssue
		for i := range report.Issues {
			iss := &report.Issues[i]
			if iss.CanAutoFix && (applyAll || iss.ID == issueID) {
				target = iss
				break
			}
		}
		if target == nil {
			break
		}
		lines := strings.Split(current, "\n")
		startIdx := target.editStart - 1
		endIdx := target.editEnd - 1
		if startIdx < 0 || endIdx >= len(lines) || startIdx > endIdx {
			break
		}
		replLines := strings.Split(target.Replacement, "\n")
		updated := make([]string, 0, len(lines)-((endIdx-startIdx)+1)+len(replLines))
		updated = append(updated, lines[:startIdx]...)
		updated = append(updated, replLines...)
		updated = append(updated, lines[endIdx+1:]...)
		next := strings.Join(updated, "\n")
		nextReport, inspectErr := InspectHTTPRespSafety(filePath, next)
		if inspectErr != nil {
			break
		}
		current = next
		report = nextReport
		applied++
		if !applyAll {
			break
		}
	}

	newContent := current
	if formatted, fmtErr := format.Source([]byte(newContent)); fmtErr == nil {
		newContent = string(formatted)
	}
	newReport, err := InspectHTTPRespSafety(filePath, newContent)
	if err != nil {
		newReport = &HTTPRespSafetyReport{FilePath: filePath, Issues: []HTTPRespSafetyIssue{}}
	}

	return &HTTPRespSafetyFixResult{
		FilePath:     filePath,
		AppliedCount: applied,
		NewContent:   newContent,
		Report:       *newReport,
	}, nil
}

func InspectHTTPRespSafetyJSON(payloadJSON string) string {
	var req struct {
		FilePath string `json:"filePath"`
		Content  string `json:"content"`
	}
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(map[string]any{"error": err.Error()})
		return string(out)
	}
	report, err := InspectHTTPRespSafety(req.FilePath, req.Content)
	if err != nil {
		out, _ := json.Marshal(map[string]any{"error": err.Error()})
		return string(out)
	}
	out, _ := json.Marshal(report)
	return string(out)
}

func ApplyHTTPRespSafetyFixJSON(payloadJSON string) string {
	var req struct {
		FilePath string `json:"filePath"`
		Content  string `json:"content"`
		IssueID  string `json:"issueId"`
		ApplyAll bool   `json:"applyAll"`
	}
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(map[string]any{"error": err.Error()})
		return string(out)
	}
	res, err := ApplyHTTPRespSafetyFix(req.FilePath, req.Content, req.IssueID, req.ApplyAll)
	if err != nil {
		out, _ := json.Marshal(map[string]any{"error": err.Error()})
		return string(out)
	}
	out, _ := json.Marshal(res)
	return string(out)
}
