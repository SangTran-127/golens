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
	catCloseChannelFromReceiver   = "close-channel-from-receiver-or-multiple-workers"
	catPipelineSendWithoutContext = "pipeline-send-without-context-select"
	catRangeOverUnclosedChannel   = "range-over-unclosed-channel"
)

type PipelineSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type PipelineSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type PipelineSafetyFixResponse struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type PipelineSafetyIssue struct {
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
	ChanExpr           string `json:"chanExpr"`
	Expr               string `json:"expr"`
	FuncName           string `json:"funcName"`
}

type PipelineSafetyReport struct {
	FilePath                               string                `json:"filePath"`
	TotalCount                             int                   `json:"totalCount"`
	CriticalCount                          int                   `json:"criticalCount"`
	WarningCount                           int                   `json:"warningCount"`
	InfoCount                              int                   `json:"infoCount"`
	FixableCount                           int                   `json:"fixableCount"`
	CloseChannelFromReceiverOrWorkersCount int                   `json:"closeChannelFromReceiverOrWorkersCount"`
	PipelineSendWithoutContextSelectCount  int                   `json:"pipelineSendWithoutContextSelectCount"`
	RangeOverUnclosedChannelCount          int                   `json:"rangeOverUnclosedChannelCount"`
	Issues                                 []PipelineSafetyIssue `json:"issues"`
	Error                                  string                `json:"error,omitempty"`
}

type ApplyPipelineSafetyFixResult struct {
	ModifiedSource string               `json:"modifiedSource"`
	AppliedCount   int                  `json:"appliedCount"`
	Report         PipelineSafetyReport `json:"report"`
}

func InspectPipelineSafetyJSON(payloadJSON string) string {
	var req PipelineSafetyInspectRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(PipelineSafetyReport{
			Issues: []PipelineSafetyIssue{},
			Error:  "invalid payload: " + err.Error(),
		})
		return string(out)
	}
	report, err := InspectPipelineSafety(req.Content, req.FilePath)
	if err != nil {
		out, _ := json.Marshal(PipelineSafetyReport{
			FilePath: req.FilePath,
			Issues:   []PipelineSafetyIssue{},
			Error:    err.Error(),
		})
		return string(out)
	}
	out, _ := json.Marshal(report)
	return string(out)
}

func ApplyPipelineSafetyFixesJSON(payloadJSON string) string {
	var req PipelineSafetyFixRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		out, _ := json.Marshal(PipelineSafetyFixResponse{
			Error: "invalid payload: " + err.Error(),
		})
		return string(out)
	}
	var ids []string
	if !req.All && req.IssueID != "" {
		ids = []string{req.IssueID}
	}
	res, err := ApplyPipelineSafetyFixes(req.Content, req.FilePath, ids)
	if err != nil {
		out, _ := json.Marshal(PipelineSafetyFixResponse{
			NewContent: req.Content,
			Error:      err.Error(),
		})
		return string(out)
	}
	out, _ := json.Marshal(PipelineSafetyFixResponse{
		NewContent: res.ModifiedSource,
		FixedCount: res.AppliedCount,
	})
	return string(out)
}

func InspectPipelineSafety(src string, filePath string) (*PipelineSafetyReport, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	lines := strings.Split(src, "\n")
	issues := collectPipelineSafetyIssues(fset, file, lines)

	report := &PipelineSafetyReport{
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
		case catCloseChannelFromReceiver:
			report.CloseChannelFromReceiverOrWorkersCount++
		case catPipelineSendWithoutContext:
			report.PipelineSendWithoutContextSelectCount++
		case catRangeOverUnclosedChannel:
			report.RangeOverUnclosedChannelCount++
		}
		if issue.AutoFixable {
			report.FixableCount++
		}
	}
	return report, nil
}

func ApplyPipelineSafetyFixes(src string, filePath string, selectedIDs []string) (*ApplyPipelineSafetyFixResult, error) {
	report, err := InspectPipelineSafety(src, filePath)
	if err != nil {
		return nil, err
	}

	selected := make(map[string]bool, len(selectedIDs))
	for _, id := range selectedIDs {
		selected[id] = true
	}
	applyAll := len(selectedIDs) == 0

	lines := strings.Split(src, "\n")
	var toApply []PipelineSafetyIssue
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
	for _, issue := range toApply {
		if seenLines[issue.Line] {
			continue
		}
		if applySinglePipelineFix(&lines, issue) {
			seenLines[issue.Line] = true
			applied++
		}
	}

	modified := strings.Join(lines, "\n")
	if formatted, fmtErr := format.Source([]byte(modified)); fmtErr == nil {
		modified = string(formatted)
	}
	updatedReport, err := InspectPipelineSafety(modified, filePath)
	if err != nil {
		updatedReport = &PipelineSafetyReport{
			FilePath: filePath,
			Issues:   []PipelineSafetyIssue{},
		}
	}

	return &ApplyPipelineSafetyFixResult{
		ModifiedSource: modified,
		AppliedCount:   applied,
		Report:         *updatedReport,
	}, nil
}

func collectPipelineSafetyIssues(fset *token.FileSet, file *ast.File, lines []string) []PipelineSafetyIssue {
	var issues []PipelineSafetyIssue

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := fn.Name.Name
		hasCtx, ctxName := findPipelineContextParam(fn)
		recvOnlyChans := collectReceiveOnlyChanParams(fn)
		localChans, closedChans := collectLocalAndClosedChans(fn.Body)

		ctx := pipelineInspectCtx{
			fset:          fset,
			lines:         lines,
			funcName:      funcName,
			hasCtx:        hasCtx,
			ctxName:       ctxName,
			recvOnlyChans: recvOnlyChans,
			localChans:    localChans,
			closedChans:   closedChans,
			issues:        &issues,
		}
		inspectPipelineBlock(&ctx, fn.Body.List, false, false)
	}

	return issues
}

type pipelineInspectCtx struct {
	fset          *token.FileSet
	lines         []string
	funcName      string
	hasCtx        bool
	ctxName       string
	recvOnlyChans map[string]bool
	localChans    map[string]bool
	closedChans   map[string]bool
	issues        *[]PipelineSafetyIssue
}

func inspectPipelineBlock(
	ctx *pipelineInspectCtx,
	stmts []ast.Stmt,
	inLoopOrGoroutine bool,
	inSelect bool,
) {
	fset := ctx.fset
	lines := ctx.lines
	funcName := ctx.funcName
	hasCtx := ctx.hasCtx
	ctxName := ctx.ctxName
	recvOnlyChans := ctx.recvOnlyChans
	localChans := ctx.localChans
	closedChans := ctx.closedChans
	issues := ctx.issues
	for _, stmt := range stmts {
		switch s := stmt.(type) {
		case *ast.ExprStmt:
			if call, ok := s.X.(*ast.CallExpr); ok {
				checkCloseCall(fset, call, lines, funcName, recvOnlyChans, inLoopOrGoroutine, issues)
			}
		case *ast.SendStmt:
			if hasCtx && !inSelect {
				pos := fset.Position(s.Pos())
				end := fset.Position(s.End())
				chanSrc := strings.TrimSpace(renderSocketNode(fset, s.Chan))
				sendSrc := strings.TrimSpace(renderSocketNode(fset, s))
				before := comparableLineText(lines, pos.Line)
				after := fmt.Sprintf("select { case %s: case <-%s.Done(): return }", sendSrc, ctxName)
				why := "When a downstream stage exits early on error or cancellation, upstream producers sending directly with `ch <- v` leak goroutines unless wrapped in a `select` with `<-ctx.Done()`."
				*issues = append(*issues, PipelineSafetyIssue{
					ID:                 fmt.Sprintf("pipeline:send-no-ctx:%d:%d", pos.Line, pos.Column),
					Category:           catPipelineSendWithoutContext,
					Severity:           "critical",
					Title:              "Blocking channel send without ctx.Done() select",
					Message:            fmt.Sprintf("`%s` in `%s` can block indefinitely if downstream stops reading after `%s` cancellation", sendSrc, funcName, ctxName),
					Why:                why,
					Suggestion:         why,
					FixTitle:           "Wrap channel send in select with <-ctx.Done()",
					PreviewBefore:      strings.TrimSpace(before),
					PreviewAfter:       after,
					ReplacementPreview: after,
					Line:               pos.Line,
					Column:             pos.Column,
					EndLine:            end.Line,
					EndColumn:          end.Column,
					AutoFixable:        true,
					CanAutoFix:         true,
					ChanExpr:           chanSrc,
					Expr:               sendSrc,
					FuncName:           funcName,
				})
			}
		case *ast.RangeStmt:
			if id, ok := s.X.(*ast.Ident); ok {
				if localChans[id.Name] && !closedChans[id.Name] {
					pos := fset.Position(s.Pos())
					end := fset.Position(s.End())
					before := comparableLineText(lines, pos.Line)
					after := fmt.Sprintf("close(%s)\n%s", id.Name, strings.TrimSpace(before))
					why := "`for v := range ch` blocks until `ch` is closed; if producers finish without closing `ch`, the consumer goroutine deadlocks or leaks forever."
					*issues = append(*issues, PipelineSafetyIssue{
						ID:                 fmt.Sprintf("pipeline:range-unclosed:%d:%d", pos.Line, pos.Column),
						Category:           catRangeOverUnclosedChannel,
						Severity:           "critical",
						Title:              "Range loop over local channel that is never closed",
						Message:            fmt.Sprintf("`for ... range %s` iterates over a local channel that has no `close(%s)` in `%s`", id.Name, id.Name, funcName),
						Why:                why,
						Suggestion:         why,
						FixTitle:           "Close channel before ranging over buffered values",
						PreviewBefore:      strings.TrimSpace(before),
						PreviewAfter:       after,
						ReplacementPreview: after,
						Line:               pos.Line,
						Column:             pos.Column,
						EndLine:            end.Line,
						EndColumn:          end.Column,
						AutoFixable:        true,
						CanAutoFix:         true,
						ChanExpr:           id.Name,
						Expr:               id.Name,
						FuncName:           funcName,
					})
				}
			}
			if s.Body != nil {
				inspectPipelineBlock(ctx, s.Body.List, true, inSelect)
			}
		case *ast.ForStmt:
			if s.Body != nil {
				inspectPipelineBlock(ctx, s.Body.List, true, inSelect)
			}
		case *ast.GoStmt:
			if lit, ok := s.Call.Fun.(*ast.FuncLit); ok && lit.Body != nil {
				inspectPipelineBlock(ctx, lit.Body.List, inLoopOrGoroutine, inSelect)
			}
		case *ast.SelectStmt:
			if s.Body != nil {
				for _, clause := range s.Body.List {
					if comm, ok := clause.(*ast.CommClause); ok {
						inspectPipelineBlock(ctx, comm.Body, inLoopOrGoroutine, true)
					}
				}
			}
		case *ast.IfStmt:
			if s.Body != nil {
				inspectPipelineBlock(ctx, s.Body.List, inLoopOrGoroutine, inSelect)
			}
			if block, ok := s.Else.(*ast.BlockStmt); ok {
				inspectPipelineBlock(ctx, block.List, inLoopOrGoroutine, inSelect)
			}
		case *ast.BlockStmt:
			inspectPipelineBlock(ctx, s.List, inLoopOrGoroutine, inSelect)
		}
	}
}

func checkCloseCall(
	fset *token.FileSet,
	call *ast.CallExpr,
	lines []string,
	funcName string,
	recvOnlyChans map[string]bool,
	inLoopOrGoroutine bool,
	issues *[]PipelineSafetyIssue,
) {
	id, ok := call.Fun.(*ast.Ident)
	if !ok || id.Name != "close" || len(call.Args) != 1 {
		return
	}
	argSrc := strings.TrimSpace(renderSocketNode(fset, call.Args[0]))
	isRecvOnly := recvOnlyChans[argSrc]
	if !isRecvOnly && !inLoopOrGoroutine {
		return
	}

	pos := fset.Position(call.Pos())
	end := fset.Position(call.End())
	before := comparableLineText(lines, pos.Line)
	reason := fmt.Sprintf("`close(%s)` is called inside a worker loop/fan-out goroutine in `%s`, risking double-close panic", argSrc, funcName)
	if isRecvOnly {
		reason = fmt.Sprintf("`close(%s)` closes a receive-only channel parameter in `%s`", argSrc, funcName)
	}
	after := fmt.Sprintf("// Coordinator closes %s after wg.Wait()", argSrc)
	why := "Closing a channel from a receiver or inside multiple concurrent fan-out worker goroutines causes `panic: close of closed channel` or `panic: send on closed channel`; close once after `wg.Wait()` in the coordinator."
	*issues = append(*issues, PipelineSafetyIssue{
		ID:                 fmt.Sprintf("pipeline:close-worker:%d:%d", pos.Line, pos.Column),
		Category:           catCloseChannelFromReceiver,
		Severity:           "critical",
		Title:              "Closing channel from receiver or multiple fan-out workers",
		Message:            reason,
		Why:                why,
		Suggestion:         why,
		FixTitle:           "Guard worker close or move close(ch) to coordinator after wg.Wait()",
		PreviewBefore:      strings.TrimSpace(before),
		PreviewAfter:       after,
		ReplacementPreview: after,
		Line:               pos.Line,
		Column:             pos.Column,
		EndLine:            end.Line,
		EndColumn:          end.Column,
		AutoFixable:        true,
		CanAutoFix:         true,
		ChanExpr:           argSrc,
		Expr:               argSrc,
		FuncName:           funcName,
	})
}

func findPipelineContextParam(fn *ast.FuncDecl) (bool, string) {
	if fn.Type == nil || fn.Type.Params == nil {
		return false, ""
	}
	for _, field := range fn.Type.Params.List {
		sel, ok := field.Type.(*ast.SelectorExpr)
		if !ok {
			continue
		}
		pkg, ok := sel.X.(*ast.Ident)
		if ok && pkg.Name == "context" && sel.Sel.Name == "Context" {
			if len(field.Names) > 0 && field.Names[0].Name != "_" {
				return true, field.Names[0].Name
			}
			return true, "ctx"
		}
	}
	return false, ""
}

func collectReceiveOnlyChanParams(fn *ast.FuncDecl) map[string]bool {
	res := make(map[string]bool)
	if fn.Type == nil || fn.Type.Params == nil {
		return res
	}
	for _, field := range fn.Type.Params.List {
		ct, ok := field.Type.(*ast.ChanType)
		if ok && ct.Dir == ast.RECV {
			for _, name := range field.Names {
				res[name.Name] = true
			}
		}
	}
	return res
}

func collectLocalAndClosedChans(body *ast.BlockStmt) (map[string]bool, map[string]bool) {
	local := make(map[string]bool)
	closed := make(map[string]bool)
	ast.Inspect(body, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.AssignStmt:
			for i, rhs := range node.Rhs {
				if isMakeChanCall(rhs) && i < len(node.Lhs) {
					if id, ok := node.Lhs[i].(*ast.Ident); ok {
						local[id.Name] = true
					}
				}
			}
		case *ast.CallExpr:
			if id, ok := node.Fun.(*ast.Ident); ok && id.Name == "close" && len(node.Args) == 1 {
				if chID, ok := node.Args[0].(*ast.Ident); ok {
					closed[chID.Name] = true
				}
			}
		}
		return true
	})
	return local, closed
}

func isMakeChanCall(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok || len(call.Args) == 0 {
		return false
	}
	id, ok := call.Fun.(*ast.Ident)
	if !ok || id.Name != "make" {
		return false
	}
	_, isChan := call.Args[0].(*ast.ChanType)
	return isChan
}

func applySinglePipelineFix(lines *[]string, issue PipelineSafetyIssue) bool {
	idx := issue.Line - 1
	if idx < 0 || idx >= len(*lines) {
		return false
	}
	indent := pipelineLineIndent((*lines)[idx])
	switch issue.Category {
	case catCloseChannelFromReceiver:
		(*lines)[idx] = indent + fmt.Sprintf("// Coordinator closes %s after wg.Wait()", issue.ChanExpr)
		return true
	case catPipelineSendWithoutContext:
		(*lines)[idx] = indent + issue.PreviewAfter
		return true
	case catRangeOverUnclosedChannel:
		(*lines)[idx] = indent + fmt.Sprintf("close(%s)\n", issue.ChanExpr) + (*lines)[idx]
		return true
	}
	return false
}

func pipelineLineIndent(line string) string {
	idx := 0
	for idx < len(line) && (line[idx] == ' ' || line[idx] == '\t') {
		idx++
	}
	return line[:idx]
}
