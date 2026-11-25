package analysis

import (
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type PreallocInspectRequest struct {
	FilePath      string `json:"filePath"`
	WorkspacePath string `json:"workspacePath"`
	Content       string `json:"content"`
	Scope         string `json:"scope"`
}

type PreallocFinding struct {
	ID              string `json:"id"`
	Category        string `json:"category"`
	Severity        string `json:"severity"`
	Title           string `json:"title"`
	Message         string `json:"message"`
	File            string `json:"file"`
	Line            int    `json:"line"`
	EnclosingFn     string `json:"enclosingFn"`
	VarName         string `json:"varName"`
	SourceLen       string `json:"sourceLen"`
	Snippet         string `json:"snippet"`
	Replacement     string `json:"replacement"`
	CanAutoFix      bool   `json:"canAutoFix"`
	startOffset     int
	endOffset       int
	spanReplacement string
}

type PreallocInspectReport struct {
	Findings      []PreallocFinding `json:"findings"`
	TotalCount    int               `json:"totalCount"`
	SlicePrealloc int               `json:"slicePrealloc"`
	MapPrealloc   int               `json:"mapPrealloc"`
	SliceClone    int               `json:"sliceClone"`
	AutoFixable   int               `json:"autoFixable"`
	Error         string            `json:"error,omitempty"`
}

type PreallocFixRequest struct {
	FilePath  string `json:"filePath"`
	Content   string `json:"content"`
	FindingID string `json:"findingId"`
}

type PreallocFixResult struct {
	AppliedCount int    `json:"appliedCount"`
	NewContent   string `json:"newContent"`
	Error        string `json:"error,omitempty"`
}

func InspectPrealloc(req PreallocInspectRequest) PreallocInspectReport {
	report := PreallocInspectReport{
		Findings: []PreallocFinding{},
	}

	workspaceDir := strings.TrimSpace(req.WorkspacePath)
	filePath := strings.TrimSpace(req.FilePath)
	scope := strings.ToLower(strings.TrimSpace(req.Scope))
	includeWorkspace := scope == "workspace"

	var absWorkspace string
	if workspaceDir != "" {
		if abs, err := filepath.Abs(workspaceDir); err == nil {
			absWorkspace = abs
		} else {
			absWorkspace = workspaceDir
		}
	}

	var absActiveFile string
	if filePath != "" {
		if abs, err := filepath.Abs(filePath); err == nil {
			absActiveFile = abs
		} else {
			absActiveFile = filePath
		}
	}

	var targets []goSourceTarget

	if includeWorkspace && absWorkspace != "" {
		targets = collectWorkspaceGoTargets(absWorkspace, absActiveFile, req.Content, false)
	} else {
		var src []byte
		targetPath := filePath
		if req.Content != "" {
			src = []byte(req.Content)
			if targetPath == "" {
				targetPath = "input.go"
			}
		} else if targetPath != "" {
			data, err := os.ReadFile(targetPath)
			if err != nil {
				report.Error = err.Error()
				return report
			}
			src = data
		} else {
			return report
		}
		targets = append(targets, loadedGoSourceTarget(targetPath, src))
	}

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) []PreallocFinding {
		return inspectASTFilePrealloc(src.fset, src.file, src.path, string(src.content))
	})
	findings := flattenGoSourceResults(perFile)

	if len(targets) == 1 && len(findings) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		return report
	}

	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Category < findings[j].Category
	})

	for _, f := range findings {
		switch f.Category {
		case "PREALLOC_SLICE":
			report.SlicePrealloc++
		case "PREALLOC_MAP":
			report.MapPrealloc++
		case "SLICE_CLONE":
			report.SliceClone++
		}
		if f.CanAutoFix {
			report.AutoFixable++
		}
	}

	report.TotalCount = len(findings)
	if findings != nil {
		report.Findings = findings
	}

	return report
}

func ApplyPreallocFixes(req PreallocFixRequest) PreallocFixResult {
	content := req.Content
	filePath := strings.TrimSpace(req.FilePath)
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return PreallocFixResult{
				Error: err.Error(),
			}
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return PreallocFixResult{
			NewContent: content,
			Error:      "empty Go source content",
		}
	}

	if filePath == "" {
		filePath = "input.go"
	}

	report := InspectPrealloc(PreallocInspectRequest{
		FilePath: filePath,
		Content:  content,
		Scope:    "file",
	})
	if report.Error != "" {
		return PreallocFixResult{
			NewContent: content,
			Error:      report.Error,
		}
	}

	targetID := strings.TrimSpace(req.FindingID)
	var selected []PreallocFinding
	seenSpan := make(map[int]bool)

	for _, f := range report.Findings {
		if !f.CanAutoFix || f.Replacement == "" {
			continue
		}
		if targetID != "" && f.ID != targetID {
			continue
		}
		spanKey := f.startOffset
		if spanKey <= 0 {
			spanKey = -f.Line
		}
		if seenSpan[spanKey] {
			continue
		}
		seenSpan[spanKey] = true
		selected = append(selected, f)
	}

	if len(selected) == 0 {
		if targetID != "" {
			return PreallocFixResult{
				AppliedCount: 0,
				NewContent:   content,
				Error:        fmt.Sprintf("finding %q not found", targetID),
			}
		}
		return PreallocFixResult{
			AppliedCount: 0,
			NewContent:   formatGoSourceOrFallback(content),
		}
	}

	sort.Slice(selected, func(i, j int) bool {
		if selected[i].startOffset != selected[j].startOffset {
			return selected[i].startOffset > selected[j].startOffset
		}
		return selected[i].Line > selected[j].Line
	})

	updated := content
	applied := 0
	usedSlicesClone := false
	lastReplacedStart := len(updated) + 1

	for _, f := range selected {
		repl := f.spanReplacement
		if repl == "" {
			repl = f.Replacement
		}
		if f.endOffset > f.startOffset && f.startOffset >= 0 && f.endOffset <= len(updated) && f.endOffset <= lastReplacedStart {
			updated = updated[:f.startOffset] + repl + updated[f.endOffset:]
			lastReplacedStart = f.startOffset
			applied++
			if f.Category == "SLICE_CLONE" {
				usedSlicesClone = true
			}
			continue
		}
		lines := strings.Split(updated, "\n")
		if f.Line < 1 || f.Line > len(lines) {
			continue
		}
		origLine := lines[f.Line-1]
		indent := leadingWhitespace(origLine)
		_, commentSuffix := splitPreallocCodeAndComment(origLine)
		lines[f.Line-1] = indent + f.Replacement + commentSuffix
		updated = strings.Join(lines, "\n")
		applied++
		if f.Category == "SLICE_CLONE" {
			usedSlicesClone = true
		}
	}

	if usedSlicesClone {
		updated = ensureGoImport(filePath, updated, "slices")
	}

	formatted, err := format.Source([]byte(updated))
	if err == nil {
		updated = string(formatted)
	}

	return PreallocFixResult{
		AppliedCount: applied,
		NewContent:   updated,
	}
}

func inspectASTFilePrealloc(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
) []PreallocFinding {
	var findings []PreallocFinding

	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	inspectFuncScope := func(fnName string, root *ast.BlockStmt) {
		if root == nil {
			return
		}

		ast.Inspect(root, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}

			block, ok := n.(*ast.BlockStmt)
			if !ok {
				return true
			}

			loops := make([]*preallocLoopSummary, len(block.List))
			loopAt := func(j int) *preallocLoopSummary {
				if loops[j] == nil {
					loops[j] = summarizePreallocLoop(fset, block.List[j])
				}
				return loops[j]
			}

			for i := 0; i < len(block.List); i++ {
				stmt := block.List[i]

				if sliceDecl, ok := matchUnallocatedSliceDecl(fset, stmt); ok {
					for j := i + 1; j < len(block.List); j++ {
						loop := loopAt(j)
						if !loop.isLoop || loop.sourceLen == "" {
							continue
						}
						sourceLen := loop.sourceLen
						if loop.appendTargets[sliceDecl.varName] {
							replacement := fmt.Sprintf("%s := make(%s, 0, %s)", sliceDecl.varName, sliceDecl.sliceType, sourceLen)
							findings = append(findings, PreallocFinding{
								ID:              fmt.Sprintf("PREALLOC_SLICE:%s:%d:%s", filePath, sliceDecl.line, sliceDecl.varName),
								Category:        "PREALLOC_SLICE",
								Severity:        "warning",
								Title:           fmt.Sprintf("Pre-allocate slice '%s' capacity before loop", sliceDecl.varName),
								Message:         fmt.Sprintf("Slice '%s' (%s) grows via append inside a loop over %s; pre-allocate capacity with make(%s, 0, %s) to avoid repeated reallocations.", sliceDecl.varName, sliceDecl.sliceType, sourceLen, sliceDecl.sliceType, sourceLen),
								File:            filePath,
								Line:            sliceDecl.line,
								EnclosingFn:     fnName,
								VarName:         sliceDecl.varName,
								SourceLen:       sourceLen,
								Snippet:         lineAt(sliceDecl.line),
								Replacement:     replacement,
								CanAutoFix:      true,
								startOffset:     sliceDecl.startOffset,
								endOffset:       sliceDecl.endOffset,
								spanReplacement: replacement,
							})
							break
						}
					}
				}

				if mapDecl, ok := matchUnallocatedMapDecl(fset, stmt); ok {
					for j := i + 1; j < len(block.List); j++ {
						loop := loopAt(j)
						if !loop.isLoop || loop.sourceLen == "" {
							continue
						}
						sourceLen := loop.sourceLen
						if loop.mapAssignTargets[mapDecl.varName] {
							replacement := fmt.Sprintf("%s := make(%s, %s)", mapDecl.varName, mapDecl.mapType, sourceLen)
							findings = append(findings, PreallocFinding{
								ID:              fmt.Sprintf("PREALLOC_MAP:%s:%d:%s", filePath, mapDecl.line, mapDecl.varName),
								Category:        "PREALLOC_MAP",
								Severity:        "warning",
								Title:           fmt.Sprintf("Pre-allocate map '%s' capacity before loop", mapDecl.varName),
								Message:         fmt.Sprintf("Map '%s' (%s) is populated inside a loop over %s without an initial size hint; initialize with make(%s, %s) to reduce hash table growth overhead.", mapDecl.varName, mapDecl.mapType, sourceLen, mapDecl.mapType, sourceLen),
								File:            filePath,
								Line:            mapDecl.line,
								EnclosingFn:     fnName,
								VarName:         mapDecl.varName,
								SourceLen:       sourceLen,
								Snippet:         lineAt(mapDecl.line),
								Replacement:     replacement,
								CanAutoFix:      true,
								startOffset:     mapDecl.startOffset,
								endOffset:       mapDecl.endOffset,
								spanReplacement: replacement,
							})
							break
						}
					}
				}
			}

			return true
		})

		seenCloneLines := make(map[int]bool)
		ast.Inspect(root, func(n ast.Node) bool {
			if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
				return false
			}
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			cloneInfo, ok := matchSliceCloneAppendCall(fset, call)
			if !ok {
				return true
			}
			line := fset.Position(call.Pos()).Line
			if seenCloneLines[line] {
				return true
			}
			seenCloneLines[line] = true

			snippet := lineAt(line)
			codeOnly, _ := splitPreallocCodeAndComment(snippet)
			codeOnly = strings.TrimSpace(codeOnly)

			callExprStr := strings.TrimSpace(exprToString(fset, call))
			cloneExprStr := fmt.Sprintf("slices.Clone(%s)", cloneInfo.srcExpr)
			replacement := cloneExprStr
			if callExprStr != "" && strings.Contains(codeOnly, callExprStr) {
				replacement = strings.Replace(codeOnly, callExprStr, cloneExprStr, 1)
			}

			varName := extractLHSIdentifierFromLine(codeOnly)
			if varName == "" {
				varName = cloneInfo.srcExpr
			}

			findings = append(findings, PreallocFinding{
				ID:              fmt.Sprintf("SLICE_CLONE:%s:%d:%s", filePath, line, varName),
				Category:        "SLICE_CLONE",
				Severity:        "info",
				Title:           fmt.Sprintf("Replace append slice clone with slices.Clone(%s)", cloneInfo.srcExpr),
				Message:         fmt.Sprintf("Cloning '%s' via %s can be simplified to Go 1.21+ slices.Clone(%s).", cloneInfo.srcExpr, callExprStr, cloneInfo.srcExpr),
				File:            filePath,
				Line:            line,
				EnclosingFn:     fnName,
				VarName:         varName,
				SourceLen:       fmt.Sprintf("len(%s)", cloneInfo.srcExpr),
				Snippet:         snippet,
				Replacement:     replacement,
				CanAutoFix:      true,
				startOffset:     fset.Position(call.Pos()).Offset,
				endOffset:       fset.Position(call.End()).Offset,
				spanReplacement: cloneExprStr,
			})
			return true
		})
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}
		inspectFuncScope(fnName, fn.Body)

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			lit, ok := n.(*ast.FuncLit)
			if ok && lit.Body != nil {
				inspectFuncScope(fnName, lit.Body)
			}
			return true
		})
	}

	return findings
}

type unallocatedSliceDeclInfo struct {
	varName     string
	sliceType   string
	line        int
	startOffset int
	endOffset   int
}

func matchUnallocatedSliceDecl(fset *token.FileSet, stmt ast.Stmt) (unallocatedSliceDeclInfo, bool) {
	switch s := stmt.(type) {
	case *ast.DeclStmt:
		genDecl, ok := s.Decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.VAR || len(genDecl.Specs) != 1 {
			return unallocatedSliceDeclInfo{}, false
		}
		vs, ok := genDecl.Specs[0].(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || vs.Names[0] == nil {
			return unallocatedSliceDeclInfo{}, false
		}
		varName := vs.Names[0].Name
		if varName == "" || varName == "_" {
			return unallocatedSliceDeclInfo{}, false
		}
		if len(vs.Values) == 0 {
			arrType, ok := vs.Type.(*ast.ArrayType)
			if !ok || arrType.Len != nil {
				return unallocatedSliceDeclInfo{}, false
			}
			typeStr := strings.TrimSpace(exprToString(fset, arrType))
			if typeStr == "" {
				return unallocatedSliceDeclInfo{}, false
			}
			return unallocatedSliceDeclInfo{
				varName:     varName,
				sliceType:   typeStr,
				line:        fset.Position(s.Pos()).Line,
				startOffset: fset.Position(s.Pos()).Offset,
				endOffset:   fset.Position(s.End()).Offset,
			}, true
		}
		if len(vs.Values) == 1 {
			if typeStr, ok := matchEmptySliceInitExpr(fset, vs.Values[0]); ok {
				return unallocatedSliceDeclInfo{
					varName:     varName,
					sliceType:   typeStr,
					line:        fset.Position(s.Pos()).Line,
					startOffset: fset.Position(s.Pos()).Offset,
					endOffset:   fset.Position(s.End()).Offset,
				}, true
			}
		}

	case *ast.AssignStmt:
		if s.Tok != token.DEFINE || len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			return unallocatedSliceDeclInfo{}, false
		}
		ident, ok := s.Lhs[0].(*ast.Ident)
		if !ok || ident.Name == "" || ident.Name == "_" {
			return unallocatedSliceDeclInfo{}, false
		}
		if typeStr, ok := matchEmptySliceInitExpr(fset, s.Rhs[0]); ok {
			return unallocatedSliceDeclInfo{
				varName:     ident.Name,
				sliceType:   typeStr,
				line:        fset.Position(s.Pos()).Line,
				startOffset: fset.Position(s.Pos()).Offset,
				endOffset:   fset.Position(s.End()).Offset,
			}, true
		}
	}

	return unallocatedSliceDeclInfo{}, false
}

func matchEmptySliceInitExpr(fset *token.FileSet, expr ast.Expr) (string, bool) {
	switch e := expr.(type) {
	case *ast.CompositeLit:
		if len(e.Elts) != 0 {
			return "", false
		}
		arrType, ok := e.Type.(*ast.ArrayType)
		if !ok || arrType.Len != nil {
			return "", false
		}
		typeStr := strings.TrimSpace(exprToString(fset, arrType))
		return typeStr, typeStr != ""

	case *ast.CallExpr:
		funIdent, ok := e.Fun.(*ast.Ident)
		if !ok || funIdent.Name != "make" || len(e.Args) != 2 {
			return "", false
		}
		arrType, ok := e.Args[0].(*ast.ArrayType)
		if !ok || arrType.Len != nil {
			return "", false
		}
		lit, ok := e.Args[1].(*ast.BasicLit)
		if !ok || lit.Kind != token.INT || lit.Value != "0" {
			return "", false
		}
		typeStr := strings.TrimSpace(exprToString(fset, arrType))
		return typeStr, typeStr != ""
	}
	return "", false
}

type unallocatedMapDeclInfo struct {
	varName     string
	mapType     string
	line        int
	startOffset int
	endOffset   int
}

func matchUnallocatedMapDecl(fset *token.FileSet, stmt ast.Stmt) (unallocatedMapDeclInfo, bool) {
	switch s := stmt.(type) {
	case *ast.DeclStmt:
		genDecl, ok := s.Decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.VAR || len(genDecl.Specs) != 1 {
			return unallocatedMapDeclInfo{}, false
		}
		vs, ok := genDecl.Specs[0].(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || vs.Names[0] == nil || len(vs.Values) != 1 {
			return unallocatedMapDeclInfo{}, false
		}
		varName := vs.Names[0].Name
		if varName == "" || varName == "_" {
			return unallocatedMapDeclInfo{}, false
		}
		if typeStr, ok := matchEmptyMapInitExpr(fset, vs.Values[0]); ok {
			return unallocatedMapDeclInfo{
				varName:     varName,
				mapType:     typeStr,
				line:        fset.Position(s.Pos()).Line,
				startOffset: fset.Position(s.Pos()).Offset,
				endOffset:   fset.Position(s.End()).Offset,
			}, true
		}

	case *ast.AssignStmt:
		if s.Tok != token.DEFINE || len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			return unallocatedMapDeclInfo{}, false
		}
		ident, ok := s.Lhs[0].(*ast.Ident)
		if !ok || ident.Name == "" || ident.Name == "_" {
			return unallocatedMapDeclInfo{}, false
		}
		if typeStr, ok := matchEmptyMapInitExpr(fset, s.Rhs[0]); ok {
			return unallocatedMapDeclInfo{
				varName:     ident.Name,
				mapType:     typeStr,
				line:        fset.Position(s.Pos()).Line,
				startOffset: fset.Position(s.Pos()).Offset,
				endOffset:   fset.Position(s.End()).Offset,
			}, true
		}
	}

	return unallocatedMapDeclInfo{}, false
}

func matchEmptyMapInitExpr(fset *token.FileSet, expr ast.Expr) (string, bool) {
	switch e := expr.(type) {
	case *ast.CompositeLit:
		if len(e.Elts) != 0 {
			return "", false
		}
		mapType, ok := e.Type.(*ast.MapType)
		if !ok {
			return "", false
		}
		typeStr := strings.TrimSpace(exprToString(fset, mapType))
		return typeStr, typeStr != ""

	case *ast.CallExpr:
		funIdent, ok := e.Fun.(*ast.Ident)
		if !ok || funIdent.Name != "make" || len(e.Args) != 1 {
			return "", false
		}
		mapType, ok := e.Args[0].(*ast.MapType)
		if !ok {
			return "", false
		}
		typeStr := strings.TrimSpace(exprToString(fset, mapType))
		return typeStr, typeStr != ""
	}
	return "", false
}

func extractPreallocLoopInfo(fset *token.FileSet, stmt ast.Stmt) (body *ast.BlockStmt, sourceLen string, ok bool) {
	switch loop := stmt.(type) {
	case *ast.RangeStmt:
		if loop.Body == nil || loop.X == nil {
			return nil, "", false
		}
		xStr := strings.TrimSpace(exprToString(fset, loop.X))
		if xStr == "" {
			return nil, "", false
		}
		if isLenCallExpr(loop.X) {
			return loop.Body, xStr, true
		}
		return loop.Body, fmt.Sprintf("len(%s)", xStr), true

	case *ast.ForStmt:
		if loop.Body == nil || loop.Cond == nil {
			return nil, "", false
		}
		condBin, isBin := loop.Cond.(*ast.BinaryExpr)
		if !isBin || condBin.Op != token.LSS {
			return nil, "", false
		}
		boundStr := strings.TrimSpace(exprToString(fset, condBin.Y))
		if boundStr == "" {
			return nil, "", false
		}
		return loop.Body, boundStr, true
	}

	return nil, "", false
}

func isLenCallExpr(expr ast.Expr) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok || len(call.Args) != 1 {
		return false
	}
	ident, ok := call.Fun.(*ast.Ident)
	return ok && ident.Name == "len"
}

type preallocLoopSummary struct {
	isLoop           bool
	sourceLen        string
	appendTargets    map[string]bool
	mapAssignTargets map[string]bool
}

func summarizePreallocLoop(fset *token.FileSet, stmt ast.Stmt) *preallocLoopSummary {
	body, sourceLen, isLoop := extractPreallocLoopInfo(fset, stmt)
	summary := &preallocLoopSummary{isLoop: isLoop, sourceLen: sourceLen}
	if !isLoop || sourceLen == "" || body == nil {
		return summary
	}
	summary.appendTargets = make(map[string]bool)
	summary.mapAssignTargets = make(map[string]bool)
	ast.Inspect(body, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		assign, ok := n.(*ast.AssignStmt)
		if !ok || assign.Tok != token.ASSIGN {
			return true
		}
		for _, lhs := range assign.Lhs {
			if idxExpr, ok := lhs.(*ast.IndexExpr); ok {
				if mapIdent, ok := idxExpr.X.(*ast.Ident); ok {
					summary.mapAssignTargets[mapIdent.Name] = true
				}
			}
		}
		if len(assign.Lhs) != 1 || len(assign.Rhs) != 1 {
			return true
		}
		lhsIdent, ok := assign.Lhs[0].(*ast.Ident)
		if !ok {
			return true
		}
		call, ok := assign.Rhs[0].(*ast.CallExpr)
		if !ok || len(call.Args) < 2 {
			return true
		}
		funIdent, ok := call.Fun.(*ast.Ident)
		if !ok || funIdent.Name != "append" {
			return true
		}
		if firstArg, ok := call.Args[0].(*ast.Ident); ok && firstArg.Name == lhsIdent.Name {
			summary.appendTargets[lhsIdent.Name] = true
		}
		return true
	})
	return summary
}

type sliceCloneMatchInfo struct {
	srcExpr string
}

func matchSliceCloneAppendCall(fset *token.FileSet, call *ast.CallExpr) (sliceCloneMatchInfo, bool) {
	if call == nil || !call.Ellipsis.IsValid() || len(call.Args) != 2 {
		return sliceCloneMatchInfo{}, false
	}
	funIdent, ok := call.Fun.(*ast.Ident)
	if !ok || funIdent.Name != "append" {
		return sliceCloneMatchInfo{}, false
	}
	if !isNilOrEmptySliceBaseArg(call.Args[0]) {
		return sliceCloneMatchInfo{}, false
	}
	srcStr := strings.TrimSpace(exprToString(fset, call.Args[1]))
	if srcStr == "" {
		return sliceCloneMatchInfo{}, false
	}
	return sliceCloneMatchInfo{
		srcExpr: srcStr,
	}, true
}

func isNilOrEmptySliceBaseArg(expr ast.Expr) bool {
	switch e := expr.(type) {
	case *ast.CompositeLit:
		if len(e.Elts) != 0 {
			return false
		}
		arrType, ok := e.Type.(*ast.ArrayType)
		return ok && arrType.Len == nil

	case *ast.CallExpr:
		if len(e.Args) != 1 {
			return false
		}
		argIdent, ok := e.Args[0].(*ast.Ident)
		if !ok || argIdent.Name != "nil" {
			return false
		}
		funExpr := e.Fun
		for {
			paren, isParen := funExpr.(*ast.ParenExpr)
			if !isParen {
				break
			}
			funExpr = paren.X
		}
		arrType, ok := funExpr.(*ast.ArrayType)
		return ok && arrType.Len == nil
	}
	return false
}

func extractLHSIdentifierFromLine(codeLine string) string {
	for _, sep := range []string{":=", "="} {
		if idx := strings.Index(codeLine, sep); idx > 0 {
			lhs := strings.TrimSpace(codeLine[:idx])
			lhs = strings.TrimPrefix(lhs, "var ")
			lhs = strings.TrimSpace(lhs)
			if fields := strings.Fields(lhs); len(fields) > 0 {
				candidate := strings.TrimSuffix(fields[0], ",")
				if candidate != "" && candidate != "_" {
					return candidate
				}
			}
		}
	}
	return ""
}

func splitPreallocCodeAndComment(line string) (string, string) {
	idx := findLineCommentOutsideTicks(line)
	if idx < 0 {
		return line, ""
	}
	return line[:idx], line[idx:]
}
