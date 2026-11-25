package analysis

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
)

type ContextualQuickFix struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Kind          string `json:"kind"`
	InspectorID   string `json:"inspectorId"`
	Line          int    `json:"line"`
	UpdatedSource string `json:"updatedSource"`
	Summary       string `json:"summary"`
}

func ContextualASTQuickFixes(workspaceDir, filePath, content string, line int) ([]ContextualQuickFix, error) {
	if strings.TrimSpace(content) == "" {
		return nil, nil
	}

	lines := strings.Split(content, "\n")
	if line < 1 || line > len(lines) {
		return nil, nil
	}

	var fixes []ContextualQuickFix

	parsePath := filePath
	if strings.TrimSpace(parsePath) == "" {
		parsePath = "input.go"
	}
	fset := token.NewFileSet()
	file, parseErr := parser.ParseFile(fset, parsePath, content, parser.ParseComments)

	if strings.Contains(content, "context") || strings.Contains(content, "defer") || strings.Contains(content, "go ") || strings.Contains(content, "sync") {
		if file != nil {
			concReport := inspectConcurrencyAST(fset, file, filePath, content)
			for _, f := range concReport.Findings {
				if (f.Line == line || f.Line == line-1 || f.Line == line+1) && f.CanAutoFix {
					if fixRes, fixErr := applyConcurrencyQuickFixAST(fset, file, filePath, content, f.Line, f.Kind); fixErr == nil {
						if fixRes.UpdatedSource != "" && fixRes.UpdatedSource != content && fixRes.Title != "" {
							fixes = append(fixes, ContextualQuickFix{
								ID:            fmt.Sprintf("concurrency.%s.%d", f.Kind, f.Line),
								Title:         fixRes.Title,
								Kind:          "quickfix.golens",
								InspectorID:   "concurrency",
								Line:          f.Line,
								UpdatedSource: fixRes.UpdatedSource,
								Summary:       f.Summary,
							})
						}
					}
				}
			}
		}
	}

	if strings.Contains(content, "http") {
		if file != nil {
			httpReport := &HTTPSafetyReport{FilePath: filePath, Issues: []HTTPSafetyIssue{}}
			fillHTTPSafetyReport(httpReport, fset, file, content)
			for _, issue := range httpReport.Issues {
				if (issue.Line == line || issue.Line == line-1 || issue.Line == line+1) && issue.CanAutoFix && issue.FixTitle != "" {
					if fixedSrc, fixErr := ApplyHTTPSafetyFix(filePath, content, issue.Line, issue.Column, issue.Kind); fixErr == nil && fixedSrc != "" && fixedSrc != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("http.%s.%d.%d", issue.Kind, issue.Line, issue.Column),
							Title:         issue.FixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "http",
							Line:          issue.Line,
							UpdatedSource: fixedSrc,
							Summary:       issue.Message,
						})
					}
				}
			}
		}
	}

	if strings.Contains(content, "http") || strings.Contains(content, "ResponseWriter") || strings.Contains(content, "WriteHeader") || strings.Contains(content, "Header") {
		if file != nil && parseErr == nil {
			httpRespReport := inspectHTTPRespSafetyAST(fset, file, filePath, content)
			for _, issue := range httpRespReport.Issues {
				if (issue.Line == line || (line >= issue.Line && line <= issue.EndLine)) && issue.CanAutoFix && issue.FixTitle != "" {
					if fixRes, fixErr := ApplyHTTPRespSafetyFix(filePath, content, issue.ID, false); fixErr == nil && fixRes != nil && fixRes.AppliedCount > 0 {
						if fixRes.NewContent != "" && fixRes.NewContent != content {
							fixes = append(fixes, ContextualQuickFix{
								ID:            fmt.Sprintf("httpresp.%s", issue.ID),
								Title:         issue.FixTitle,
								Kind:          "quickfix.golens",
								InspectorID:   "httpresp",
								Line:          issue.Line,
								UpdatedSource: fixRes.NewContent,
								Summary:       issue.Message,
							})
						}
					}
				}
			}
		}
	}

	if strings.Contains(content, "testing") || strings.Contains(content, "t.") {
		if file != nil {
			testReport := TestingSafetyInspectResult{Issues: []TestingSafetyIssue{}}
			fillTestingSafetyResult(&testReport, fset, file, content)
			for _, issue := range testReport.Issues {
				if issue.Line == line && issue.CanAutoFix && issue.FixTitle != "" {
					if fixRes, fixErr := ApplyGoTestingSafetyFixes(content, filePath, issue.ID, false); fixErr == nil {
						if fixRes.NewContent != "" && fixRes.NewContent != content {
							fixes = append(fixes, ContextualQuickFix{
								ID:            fmt.Sprintf("testing.%s", issue.ID),
								Title:         issue.FixTitle,
								Kind:          "quickfix.golens",
								InspectorID:   "testing",
								Line:          issue.Line,
								UpdatedSource: fixRes.NewContent,
								Summary:       issue.Message,
							})
						}
					}
				}
			}
		}
	}

	if strings.Contains(content, "Dial") || strings.Contains(content, "Listen") || strings.Contains(content, "Transport") {
		if file != nil && parseErr == nil {
			netdialRes := NetDialSafetyResult{FilePath: filePath, Issues: []NetDialSafetyIssue{}}
			fillNetDialSafetyResult(&netdialRes, fset, file, content)
			for _, issue := range netdialRes.Issues {
				if issue.Line == line && issue.CanAutoFix && issue.QuickFixTitle != "" {
					fixRes := ApplyNetDialSafetyFixes(NetDialSafetyFixRequest{
						FilePath: filePath,
						Content:  content,
						IssueIDs: []string{issue.ID},
					})
					if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.ModifiedContent != "" && fixRes.ModifiedContent != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("netdial.%s", issue.ID),
							Title:         issue.QuickFixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "netdial",
							Line:          issue.Line,
							UpdatedSource: fixRes.ModifiedContent,
							Summary:       issue.Message,
						})
					}
				}
			}
		}
	}

	if strings.Contains(content, "fmt.Errorf") || strings.Contains(content, "err") || strings.Contains(content, "Err") {
		if file != nil {
			errPath := strings.TrimSpace(filePath)
			if errPath == "" {
				errPath = "input.go"
			}
			errFindings := inspectASTFileErrorWrapping(fset, file, errPath, content)
			sortErrorWrappingFindings(errFindings)
			for _, f := range errFindings {
				if f.Line == line && f.CanQuickFix && f.FixTitle != "" {
					fixedSrc, fixErr := FixErrorWrappingIssue(filePath, content, f.Line, f.Kind, f.TargetName)
					if fixErr == nil && fixedSrc != "" && fixedSrc != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("errwrap.%s.%d", f.Kind, f.Line),
							Title:         f.FixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "errwrap",
							Line:          f.Line,
							UpdatedSource: fixedSrc,
							Summary:       f.Message,
						})
					}
				}
			}
		}
	}

	if file != nil && strings.Contains(content, "struct") && isSensitiveIdentifier(lines[line-1]) {
		sensFindings := inspectASTFileSensitiveData(fset, file, parsePath, parsePath, nil)
		for _, f := range sensFindings {
			if f.Line == line && f.Kind == "sensitive_tag" {
				target := f.FieldName
				if f.StructName != "" && f.FieldName != "" {
					target = f.StructName + "." + f.FieldName
				}
				if fixedSrc, fixErr := FixSensitiveDataIssue(filePath, content, f.Line, f.Kind, target); fixErr == nil && fixedSrc != "" && fixedSrc != content {
					fixes = append(fixes, ContextualQuickFix{
						ID:            fmt.Sprintf("sensitive.%s.%d", f.Kind, f.Line),
						Title:         f.QuickFixTitle,
						Kind:          "quickfix.golens",
						InspectorID:   "security",
						Line:          f.Line,
						UpdatedSource: fixedSrc,
						Summary:       f.Detail,
					})
				}
			}
		}
	}

	if file != nil && strings.Contains(lines[line-1], "interface{}") && hasQuickFixableModernAny(fset, file, parsePath, content, line) {
		if fixedSrc, fixErr := FixGoModernizationIssue(filePath, content, line, "MODERN_ANY", ""); fixErr == nil && fixedSrc != "" && fixedSrc != content {
			fixes = append(fixes, ContextualQuickFix{
				ID:            fmt.Sprintf("modernize.MODERN_ANY.%d", line),
				Title:         "Replace interface{} With any",
				Kind:          "quickfix.golens",
				InspectorID:   "modernization",
				Line:          line,
				UpdatedSource: fixedSrc,
				Summary:       "Replace empty interface{} with any",
			})
		}
	}

	if file != nil && parseErr == nil && hasResourceSafetyPrefilter(content) {
		for _, rf := range inspectASTFileResourceAndInjection(fset, file, parsePath, content) {
			if rf.Kind == "RESOURCE_UNCLOSED" && rf.Line == line && rf.CanQuickFix && rf.TargetName != "" {
				if fixedSrc, fixErr := FixResourceRiskIssue(filePath, content, rf.Line, rf.Kind, rf.TargetName); fixErr == nil && fixedSrc != "" && fixedSrc != content {
					appendContextualFixIfUnique(&fixes, ContextualQuickFix{
						ID:            fmt.Sprintf("resource.%s.%d.%s", rf.Kind, rf.Line, rf.TargetName),
						Title:         fmt.Sprintf("Add defer %s.Close()", rf.TargetName),
						Kind:          "quickfix.golens",
						InspectorID:   "resource",
						Line:          rf.Line,
						UpdatedSource: fixedSrc,
						Summary:       rf.Message,
					})
				}
			}
		}
	}

	if file != nil && parseErr == nil && (strings.Contains(content, ".Begin(") || strings.Contains(content, ".BeginTx(")) {
		for _, txIssue := range inspectASTFileSQLTransactions(fset, file, content) {
			if txIssue.Line == line && txIssue.CanQuickFix {
				if fixedSrc, title, fixErr := FixSQLTransactionIssue(filePath, content, txIssue.Line); fixErr == nil && fixedSrc != "" && fixedSrc != content && title != "" {
					appendContextualFixIfUnique(&fixes, ContextualQuickFix{
						ID:            fmt.Sprintf("sqltx.SQL_TX_UNCLOSED.%d.%s", txIssue.Line, txIssue.TargetName),
						Title:         title,
						Kind:          "quickfix.golens",
						InspectorID:   "sqltx",
						Line:          txIssue.Line,
						UpdatedSource: fixedSrc,
						Summary:       txIssue.Message,
					})
				}
			}
		}
	}

	if file != nil && parseErr == nil && (strings.Contains(content, "NewTicker") || strings.Contains(content, "NewTimer")) {
		for _, tf := range inspectASTFileTimeSafety(fset, file, parsePath, content) {
			if tf.Category == "TICKER_UNSTOPPED" && tf.Line == line && tf.CanAutoFix && tf.Replacement != "" {
				fixRes := ApplyTimeSafetyFixes(TimeSafetyFixRequest{
					FilePath:  parsePath,
					Content:   content,
					FindingID: tf.ID,
				})
				if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.NewContent != "" && fixRes.NewContent != content {
					appendContextualFixIfUnique(&fixes, ContextualQuickFix{
						ID:            fmt.Sprintf("time.%s", tf.ID),
						Title:         "Add " + tf.Replacement,
						Kind:          "quickfix.golens",
						InspectorID:   "time",
						Line:          tf.Line,
						UpdatedSource: fixRes.NewContent,
						Summary:       tf.Message,
					})
				}
			}
		}
	}

	if file != nil && parseErr == nil && (strings.Contains(content, ".Lock()") || strings.Contains(content, ".RLock()")) {
		syncStructs := make(map[string]string)
		collectSyncLockStructs(fset, file, syncStructs)
		for _, sf := range inspectASTFileSyncSafety(fset, file, parsePath, content, syncStructs) {
			if sf.Category == "SYNC_LOCK_NO_UNLOCK" && sf.Line == line && sf.CanAutoFix && sf.Replacement != "" {
				fixRes := ApplySyncSafetyFixes(SyncSafetyFixRequest{
					FilePath:  parsePath,
					Content:   content,
					FindingID: sf.ID,
				})
				if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.NewContent != "" && fixRes.NewContent != content {
					appendContextualFixIfUnique(&fixes, ContextualQuickFix{
						ID:            fmt.Sprintf("sync.%s", sf.ID),
						Title:         "Add " + sf.Replacement,
						Kind:          "quickfix.golens",
						InspectorID:   "sync",
						Line:          sf.Line,
						UpdatedSource: fixRes.NewContent,
						Summary:       sf.Message,
					})
				}
			}
		}
	}

	return fixes, nil
}

func hasResourceSafetyPrefilter(content string) bool {
	return strings.Contains(content, "Open") ||
		strings.Contains(content, "Create") ||
		strings.Contains(content, "Query") ||
		strings.Contains(content, "Dial") ||
		strings.Contains(content, "Listen") ||
		strings.Contains(content, "NewReader") ||
		strings.Contains(content, "NewWriter") ||
		strings.Contains(content, "http.") ||
		strings.Contains(content, ".Get(") ||
		strings.Contains(content, ".Post(") ||
		strings.Contains(content, ".PostForm(") ||
		strings.Contains(content, ".Head(") ||
		strings.Contains(content, ".Do(") ||
		strings.Contains(content, "Prepare") ||
		strings.Contains(content, ".Conn(")
}

func appendContextualFixIfUnique(fixes *[]ContextualQuickFix, item ContextualQuickFix) {
	for _, existing := range *fixes {
		if existing.Line == item.Line && existing.Title == item.Title {
			return
		}
	}
	*fixes = append(*fixes, item)
}

func hasQuickFixableModernAny(fset *token.FileSet, file *ast.File, path, content string, line int) bool {
	for _, f := range inspectASTFileModernization(fset, file, path, content) {
		if f.Kind == "MODERN_ANY" && f.Line == line && f.CanQuickFix {
			return true
		}
	}
	return false
}
