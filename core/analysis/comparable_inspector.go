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

const (
	catMapKeyNonComparable = "map-key-non-comparable-or-pointer"
	catFloatNaNEquality    = "float-nan-equality-comparison"
	catTimeEqualMismatch   = "time-equal-operator-mismatch"
)

type ComparableSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type ComparableSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type ComparableSafetyFixResponse struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type ComparableSafetyIssue struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Title              string `json:"title"`
	Message            string `json:"message"`
	Why                string `json:"why"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	PreviewBefore      string `json:"previewBefore"`
	PreviewAfter       string `json:"previewAfter"`
	ReplacementPreview string `json:"replacementPreview"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	EndLine            int    `json:"endLine"`
	EndColumn          int    `json:"endColumn"`
	AutoFixable        bool   `json:"autoFixable"`
	CanAutoFix         bool   `json:"canAutoFix"`
	TargetExpr         string `json:"targetExpr"`
	Expr               string `json:"expr"`
	FuncName           string `json:"funcName"`
}

type ComparableSafetyReport struct {
	FilePath                          string                  `json:"filePath"`
	TotalCount                        int                     `json:"totalCount"`
	CriticalCount                     int                     `json:"criticalCount"`
	WarningCount                      int                     `json:"warningCount"`
	InfoCount                         int                     `json:"infoCount"`
	FixableCount                      int                     `json:"fixableCount"`
	MapKeyNonComparableOrPointerCount int                     `json:"mapKeyNonComparableOrPointerCount"`
	FloatNaNEqualityComparisonCount   int                     `json:"floatNaNEqualityComparisonCount"`
	TimeEqualOperatorMismatchCount    int                     `json:"timeEqualOperatorMismatchCount"`
	Issues                            []ComparableSafetyIssue `json:"issues"`
	Error                             string                  `json:"error,omitempty"`
}

type ApplyComparableSafetyFixResult struct {
	ModifiedSource string                 `json:"modifiedSource"`
	AppliedCount   int                    `json:"appliedCount"`
	Report         ComparableSafetyReport `json:"report"`
}

func InspectComparableSafetyJSON(payloadJSON string) string {
	var req ComparableSafetyInspectRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(ComparableSafetyReport{
			Issues: []ComparableSafetyIssue{},
			Error:  "invalid payload: " + err.Error(),
		})
		return string(out)
	}
	report, err := InspectComparableSafety(req.Content, req.FilePath)
	if err != nil {
		out, _ := json.Marshal(ComparableSafetyReport{
			FilePath: req.FilePath,
			Issues:   []ComparableSafetyIssue{},
			Error:    err.Error(),
		})
		return string(out)
	}
	out, _ := json.Marshal(report)
	return string(out)
}

func ApplyComparableSafetyFixesJSON(payloadJSON string) string {
	var req ComparableSafetyFixRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(ComparableSafetyFixResponse{
			Error: "invalid payload: " + err.Error(),
		})
		return string(out)
	}
	var ids []string
	if !req.All && req.IssueID != "" {
		ids = []string{req.IssueID}
	}
	res, err := ApplyComparableSafetyFixes(req.Content, req.FilePath, ids)
	if err != nil {
		out, _ := json.Marshal(ComparableSafetyFixResponse{
			NewContent: req.Content,
			Error:      err.Error(),
		})
		return string(out)
	}
	out, _ := json.Marshal(ComparableSafetyFixResponse{
		NewContent: res.ModifiedSource,
		FixedCount: res.AppliedCount,
	})
	return string(out)
}

func InspectComparableSafety(src string, filePath string) (*ComparableSafetyReport, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	lines := strings.Split(src, "\n")
	issues := collectComparableSafetyIssues(fset, file, lines)

	report := &ComparableSafetyReport{
		FilePath: filePath,
		Issues:   issues,
	}
	for _, issue := range issues {
		report.TotalCount++
		switch issue.Severity {
		case "critical":
			report.CriticalCount++
		case "warning":
			report.WarningCount++
		default:
			report.InfoCount++
		}
		switch issue.Category {
		case catMapKeyNonComparable:
			report.MapKeyNonComparableOrPointerCount++
		case catFloatNaNEquality:
			report.FloatNaNEqualityComparisonCount++
		case catTimeEqualMismatch:
			report.TimeEqualOperatorMismatchCount++
		}
		if issue.AutoFixable {
			report.FixableCount++
		}
	}
	return report, nil
}

func ApplyComparableSafetyFixes(src string, filePath string, selectedIDs []string) (*ApplyComparableSafetyFixResult, error) {
	report, err := InspectComparableSafety(src, filePath)
	if err != nil {
		return nil, err
	}

	selected := make(map[string]bool, len(selectedIDs))
	for _, id := range selectedIDs {
		selected[id] = true
	}
	applyAll := len(selectedIDs) == 0

	lines := strings.Split(src, "\n")
	var toApply []ComparableSafetyIssue
	for _, issue := range report.Issues {
		if !issue.AutoFixable {
			continue
		}
		if applyAll || selected[issue.ID] {
			toApply = append(toApply, issue)
		}
	}

	sort.Slice(toApply, func(i, j int) bool {
		if toApply[i].Line != toApply[j].Line {
			return toApply[i].Line > toApply[j].Line
		}
		return toApply[i].Column > toApply[j].Column
	})

	applied := 0
	seenLines := make(map[int]bool)
	needMathImport := false
	for _, issue := range toApply {
		if seenLines[issue.Line] {
			continue
		}
		if applySingleComparableFix(&lines, issue) {
			seenLines[issue.Line] = true
			applied++
			if issue.Category == catFloatNaNEquality {
				needMathImport = true
			}
		}
	}

	modified := strings.Join(lines, "\n")
	if needMathImport && applied > 0 {
		modified = ensureSocketImportPath(modified, "math")
	}
	if formatted, fmtErr := format.Source([]byte(modified)); fmtErr == nil {
		modified = string(formatted)
	}

	updatedReport, err := InspectComparableSafety(modified, filePath)
	if err != nil {
		updatedReport = &ComparableSafetyReport{
			FilePath: filePath,
			Issues:   []ComparableSafetyIssue{},
		}
	}

	return &ApplyComparableSafetyFixResult{
		ModifiedSource: modified,
		AppliedCount:   applied,
		Report:         *updatedReport,
	}, nil
}

func collectComparableSafetyIssues(fset *token.FileSet, file *ast.File, lines []string) []ComparableSafetyIssue {
	var issues []ComparableSafetyIssue

	nonComparableStructs := collectNonComparableStructNames(file)

	for _, decl := range file.Decls {
		if gen, ok := decl.(*ast.GenDecl); ok && gen.Tok == token.TYPE {
			for _, spec := range gen.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok {
					continue
				}
				ast.Inspect(ts.Type, func(n ast.Node) bool {
					mt, ok := n.(*ast.MapType)
					if !ok {
						return true
					}
					if isProblematicMapKey(mt.Key, nonComparableStructs) {
						pos := fset.Position(mt.Pos())
						end := fset.Position(mt.End())
						before := comparableLineText(lines, pos.Line)
						keySrc := strings.TrimSpace(renderSocketNode(fset, mt.Key))
						after := strings.TrimSpace(rewriteMapKeyPreview(before, keySrc, nonComparableStructs))
						why := "Using pointer keys (`*T`) compares memory addresses instead of values, causing lookups with equal values to miss; structs containing slices, maps, or functions cannot be safely compared as map keys."
						issues = append(issues, ComparableSafetyIssue{
							ID:                 fmt.Sprintf("comparable:map-key:%d:%d", pos.Line, pos.Column),
							Category:           catMapKeyNonComparable,
							Severity:           "critical",
							Title:              "Map key uses pointer or non-comparable struct",
							Message:            fmt.Sprintf("`map[%s]...` uses a pointer or non-comparable struct key, risking identity mismatch or runtime panic", keySrc),
							Why:                why,
							Suggestion:         why,
							FixTitle:           "Normalize map key to value or string key",
							PreviewBefore:      strings.TrimSpace(before),
							PreviewAfter:       after,
							ReplacementPreview: after,
							Line:               pos.Line,
							Column:             pos.Column,
							EndLine:            end.Line,
							EndColumn:          end.Column,
							AutoFixable:        true,
							CanAutoFix:         true,
							TargetExpr:         keySrc,
							Expr:               keySrc,
							FuncName:           ts.Name.Name,
						})
					}
					return true
				})
			}
		}
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := fn.Name.Name
		timeVars := collectTimeTypedVars(fn)

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			if n == nil {
				return false
			}

			if mt, ok := n.(*ast.MapType); ok {
				if isProblematicMapKey(mt.Key, nonComparableStructs) {
					pos := fset.Position(mt.Pos())
					end := fset.Position(mt.End())
					before := comparableLineText(lines, pos.Line)
					keySrc := strings.TrimSpace(renderSocketNode(fset, mt.Key))
					after := strings.TrimSpace(rewriteMapKeyPreview(before, keySrc, nonComparableStructs))
					why := "Pointer keys compare pointer identity rather than logical value, causing unexpected cache misses and memory retention when callers allocate fresh structs."
					issues = append(issues, ComparableSafetyIssue{
						ID:                 fmt.Sprintf("comparable:map-key:%d:%d", pos.Line, pos.Column),
						Category:           catMapKeyNonComparable,
						Severity:           "critical",
						Title:              "Map key uses pointer or non-comparable struct",
						Message:            fmt.Sprintf("`map[%s]...` uses a pointer or non-comparable struct key in `%s`", keySrc, funcName),
						Why:                why,
						Suggestion:         why,
						FixTitle:           "Normalize map key to value or string key",
						PreviewBefore:      strings.TrimSpace(before),
						PreviewAfter:       after,
						ReplacementPreview: after,
						Line:               pos.Line,
						Column:             pos.Column,
						EndLine:            end.Line,
						EndColumn:          end.Column,
						AutoFixable:        true,
						CanAutoFix:         true,
						TargetExpr:         keySrc,
						Expr:               keySrc,
						FuncName:           funcName,
					})
				}
			}

			bin, ok := n.(*ast.BinaryExpr)
			if !ok || (bin.Op != token.EQL && bin.Op != token.NEQ) {
				return true
			}

			if nanTarget, isNaN := detectNaNComparison(fset, bin); isNaN {
				pos := fset.Position(bin.Pos())
				end := fset.Position(bin.End())
				before := comparableLineText(lines, pos.Line)
				binSrc := strings.TrimSpace(renderSocketNode(fset, bin))
				replacement := fmt.Sprintf("math.IsNaN(%s)", nanTarget)
				if bin.Op == token.NEQ && !isSelfInequality(fset, bin) {
					replacement = fmt.Sprintf("!math.IsNaN(%s)", nanTarget)
				}
				after := strings.TrimSpace(strings.Replace(before, binSrc, replacement, 1))
				why := "Per IEEE 754, `NaN == NaN` is always false, so `x == math.NaN()` never matches; `math.IsNaN(x)` makes the intent explicit and reliable."
				issues = append(issues, ComparableSafetyIssue{
					ID:                 fmt.Sprintf("comparable:float-nan:%d:%d", pos.Line, pos.Column),
					Category:           catFloatNaNEquality,
					Severity:           "critical",
					Title:              "Direct equality comparison with NaN",
					Message:            fmt.Sprintf("`%s` compares floating-point NaN with `%s` instead of `math.IsNaN`", binSrc, bin.Op.String()),
					Why:                why,
					Suggestion:         why,
					FixTitle:           "Replace with math.IsNaN(...)",
					PreviewBefore:      strings.TrimSpace(before),
					PreviewAfter:       after,
					ReplacementPreview: after,
					Line:               pos.Line,
					Column:             pos.Column,
					EndLine:            end.Line,
					EndColumn:          end.Column,
					AutoFixable:        true,
					CanAutoFix:         true,
					TargetExpr:         binSrc,
					Expr:               binSrc,
					FuncName:           funcName,
				})
				return true
			}

			if isTimeExpr(bin.X, timeVars) || isTimeExpr(bin.Y, timeVars) {
				if !isZeroValueNil(bin.X) && !isZeroValueNil(bin.Y) {
					pos := fset.Position(bin.Pos())
					end := fset.Position(bin.End())
					before := comparableLineText(lines, pos.Line)
					binSrc := strings.TrimSpace(renderSocketNode(fset, bin))
					leftSrc := strings.TrimSpace(renderSocketNode(fset, bin.X))
					rightSrc := strings.TrimSpace(renderSocketNode(fset, bin.Y))
					equalExpr := fmt.Sprintf("%s.Equal(%s)", leftSrc, rightSrc)
					if bin.Op == token.NEQ {
						equalExpr = "!" + equalExpr
					}
					after := strings.TrimSpace(strings.Replace(before, binSrc, equalExpr, 1))
					why := "`time.Time` contains both monotonic clock readings and `*time.Location` pointers; `==` can return false for two identical instants in UTC vs local time or with/without monotonic clock metadata."
					issues = append(issues, ComparableSafetyIssue{
						ID:                 fmt.Sprintf("comparable:time-equal:%d:%d", pos.Line, pos.Column),
						Category:           catTimeEqualMismatch,
						Severity:           "warning",
						Title:              "Comparing time.Time values with == or !=",
						Message:            fmt.Sprintf("`%s` compares `time.Time` struct fields directly instead of calling `.Equal(...)`", binSrc),
						Why:                why,
						Suggestion:         why,
						FixTitle:           "Replace with .Equal(...)",
						PreviewBefore:      strings.TrimSpace(before),
						PreviewAfter:       after,
						ReplacementPreview: after,
						Line:               pos.Line,
						Column:             pos.Column,
						EndLine:            end.Line,
						EndColumn:          end.Column,
						AutoFixable:        true,
						CanAutoFix:         true,
						TargetExpr:         binSrc,
						Expr:               binSrc,
						FuncName:           funcName,
					})
				}
			}

			return true
		})
	}

	return issues
}

func collectNonComparableStructNames(file *ast.File) map[string]bool {
	result := make(map[string]bool)
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.TYPE {
			continue
		}
		for _, spec := range gen.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok {
				continue
			}
			st, ok := ts.Type.(*ast.StructType)
			if !ok || st.Fields == nil {
				continue
			}
			for _, field := range st.Fields.List {
				if isNonComparableFieldType(field.Type) {
					result[ts.Name.Name] = true
					break
				}
			}
		}
	}
	return result
}

func isNonComparableFieldType(expr ast.Expr) bool {
	switch t := expr.(type) {
	case *ast.ArrayType:
		return t.Len == nil
	case *ast.MapType, *ast.FuncType:
		return true
	}
	return false
}

func isProblematicMapKey(key ast.Expr, nonComparableStructs map[string]bool) bool {
	switch t := key.(type) {
	case *ast.StarExpr:
		return true
	case *ast.ArrayType:
		return t.Len == nil
	case *ast.MapType, *ast.FuncType:
		return true
	case *ast.Ident:
		return nonComparableStructs[t.Name]
	}
	return false
}

func rewriteMapKeyPreview(line string, keySrc string, nonComparableStructs map[string]bool) string {
	target := "map[" + keySrc + "]"
	if strings.HasPrefix(keySrc, "*") {
		valKey := strings.TrimPrefix(keySrc, "*")
		if nonComparableStructs != nil && nonComparableStructs[valKey] {
			return strings.Replace(line, target, "map[string]", 1)
		}
		return strings.Replace(line, target, "map["+valKey+"]", 1)
	}
	return strings.Replace(line, target, "map[string]", 1)
}

func detectNaNComparison(fset *token.FileSet, bin *ast.BinaryExpr) (string, bool) {
	if isMathNaNCall(bin.X) {
		return strings.TrimSpace(renderSocketNode(fset, bin.Y)), true
	}
	if isMathNaNCall(bin.Y) {
		return strings.TrimSpace(renderSocketNode(fset, bin.X)), true
	}
	return "", false
}

func isSelfInequality(fset *token.FileSet, bin *ast.BinaryExpr) bool {
	if bin.Op != token.NEQ {
		return false
	}
	left := strings.TrimSpace(renderSocketNode(fset, bin.X))
	right := strings.TrimSpace(renderSocketNode(fset, bin.Y))
	return left != "" && left == right
}

func isMathNaNCall(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	return isPkgFuncCall(call, "math", "NaN")
}

func collectTimeTypedVars(fn *ast.FuncDecl) map[string]bool {
	vars := make(map[string]bool)
	if fn.Type != nil && fn.Type.Params != nil {
		for _, field := range fn.Type.Params.List {
			if isComparableTimeTypeExpr(field.Type) {
				for _, name := range field.Names {
					vars[name.Name] = true
				}
			}
		}
	}
	if fn.Body == nil {
		return vars
	}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		switch stmt := n.(type) {
		case *ast.ValueSpec:
			if isComparableTimeTypeExpr(stmt.Type) {
				for _, name := range stmt.Names {
					vars[name.Name] = true
				}
			}
			for i, val := range stmt.Values {
				if isTimeReturningExpr(val) && i < len(stmt.Names) {
					vars[stmt.Names[i].Name] = true
				}
			}
		case *ast.AssignStmt:
			for i, rhs := range stmt.Rhs {
				if isTimeReturningExpr(rhs) && i < len(stmt.Lhs) {
					if id, ok := stmt.Lhs[i].(*ast.Ident); ok {
						vars[id.Name] = true
					}
				}
			}
		}
		return true
	})
	return vars
}

func isComparableTimeTypeExpr(expr ast.Expr) bool {
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "time" && sel.Sel.Name == "Time"
}

func isTimeReturningExpr(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	if pkg, isIdent := sel.X.(*ast.Ident); isIdent && pkg.Name == "time" {
		switch sel.Sel.Name {
		case "Now", "Date", "Unix", "UnixMilli", "UnixMicro", "Parse", "ParseInLocation":
			return true
		}
	}
	switch sel.Sel.Name {
	case "UTC", "Local", "Add", "AddDate", "Truncate", "Round", "In":
		return true
	}
	return false
}

func isTimeExpr(expr ast.Expr, timeVars map[string]bool) bool {
	switch e := expr.(type) {
	case *ast.Ident:
		if timeVars[e.Name] {
			return true
		}
		lower := strings.ToLower(e.Name)
		return strings.HasSuffix(lower, "time") || strings.HasSuffix(lower, "at") || lower == "deadline" || lower == "expires"
	case *ast.CallExpr:
		return isTimeReturningExpr(e)
	case *ast.SelectorExpr:
		lower := strings.ToLower(e.Sel.Name)
		return strings.HasSuffix(lower, "time") || strings.HasSuffix(lower, "at") || lower == "deadline"
	}
	return false
}

func isZeroValueNil(expr ast.Expr) bool {
	id, ok := expr.(*ast.Ident)
	return ok && id.Name == "nil"
}

func applySingleComparableFix(lines *[]string, issue ComparableSafetyIssue) bool {
	idx := issue.Line - 1
	if idx < 0 || idx >= len(*lines) {
		return false
	}
	line := (*lines)[idx]
	switch issue.Category {
	case catMapKeyNonComparable:
		if issue.PreviewBefore != "" && issue.PreviewAfter != "" {
			updated := strings.Replace(line, issue.PreviewBefore, issue.PreviewAfter, 1)
			if updated != line {
				(*lines)[idx] = updated
				return true
			}
		}
		updated := rewriteMapKeyPreview(line, issue.TargetExpr, nil)
		if updated == line {
			return false
		}
		(*lines)[idx] = updated
		return true
	case catFloatNaNEquality, catTimeEqualMismatch:
		if issue.PreviewBefore == "" || issue.PreviewAfter == "" {
			return false
		}
		updated := strings.Replace(line, issue.PreviewBefore, issue.PreviewAfter, 1)
		if updated == line {
			return false
		}
		(*lines)[idx] = updated
		return true
	}
	return false
}

func comparableLineText(lines []string, line int) string {
	if line < 1 || line > len(lines) {
		return ""
	}
	return lines[line-1]
}
