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

const (
	defaultSyncInputFile = "input.go"
)

type SyncSafetyInspectRequest struct {
	FilePath      string `json:"filePath"`
	WorkspacePath string `json:"workspacePath"`
	Content       string `json:"content"`
	Scope         string `json:"scope"`
}

type SyncSafetyFinding struct {
	ID          string `json:"id"`
	Category    string `json:"category"`
	Severity    string `json:"severity"`
	Title       string `json:"title"`
	Message     string `json:"message"`
	File        string `json:"file"`
	Line        int    `json:"line"`
	EnclosingFn string `json:"enclosingFn"`
	TargetName  string `json:"targetName"`
	Snippet     string `json:"snippet"`
	Replacement string `json:"replacement"`
	CanAutoFix  bool   `json:"canAutoFix"`
}

type SyncSafetyInspectReport struct {
	Findings          []SyncSafetyFinding `json:"findings"`
	TotalCount        int                 `json:"totalCount"`
	ValueReceiverCopy int                 `json:"valueReceiverCopy"`
	DeferUnlockLoop   int                 `json:"deferUnlockLoop"`
	MissingUnlock     int                 `json:"missingUnlock"`
	AutoFixable       int                 `json:"autoFixable"`
	Error             string              `json:"error,omitempty"`
}

type SyncSafetyFixRequest struct {
	FilePath    string            `json:"filePath"`
	Content     string            `json:"content"`
	FindingID   string            `json:"findingId"`
	OpenBuffers map[string]string `json:"openBuffers,omitempty"`
}

type SyncSafetyFixResult struct {
	AppliedCount int            `json:"appliedCount"`
	NewContent   string         `json:"newContent"`
	FileEdits    []FileEditPlan `json:"fileEdits,omitempty"`
	Error        string         `json:"error,omitempty"`
}

func InspectSyncSafety(req SyncSafetyInspectRequest) SyncSafetyInspectReport {
	report := SyncSafetyInspectReport{
		Findings: []SyncSafetyFinding{},
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
				targetPath = defaultSyncInputFile
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

	parsedTargets, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) parsedGoSource {
		return src
	})

	syncStructs := make(map[string]string)
	for _, pt := range parsedTargets {
		collectSyncLockStructs(pt.fset, pt.file, syncStructs)
	}

	if len(targets) == 1 && len(parsedTargets) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		return report
	}

	perFile := make([][]SyncSafetyFinding, len(parsedTargets))
	runIndexedParallel(len(parsedTargets), func(i int) {
		pt := parsedTargets[i]
		perFile[i] = inspectASTFileSyncSafety(pt.fset, pt.file, pt.path, string(pt.content), syncStructs)
	})
	findings := flattenGoSourceResults(perFile)

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
		case "SYNC_VALUE_RECEIVER":
			report.ValueReceiverCopy++
		case "SYNC_DEFER_UNLOCK_LOOP":
			report.DeferUnlockLoop++
		case "SYNC_LOCK_NO_UNLOCK":
			report.MissingUnlock++
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

func ApplySyncSafetyFixes(req SyncSafetyFixRequest) SyncSafetyFixResult {
	content := req.Content
	filePath := strings.TrimSpace(req.FilePath)
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return SyncSafetyFixResult{
				Error: err.Error(),
			}
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return SyncSafetyFixResult{
			NewContent: content,
			Error:      "empty Go source content",
		}
	}

	if filePath == "" {
		filePath = defaultSyncInputFile
	}

	report := InspectSyncSafety(SyncSafetyInspectRequest{
		FilePath: filePath,
		Content:  content,
		Scope:    "file",
	})
	if report.Error != "" {
		return SyncSafetyFixResult{
			NewContent: content,
			Error:      report.Error,
		}
	}

	targetID := strings.TrimSpace(req.FindingID)
	var selected []SyncSafetyFinding
	seenLineCategory := make(map[string]bool)

	for _, f := range report.Findings {
		if !f.CanAutoFix || f.Replacement == "" {
			continue
		}
		if targetID != "" && f.ID != targetID {
			continue
		}
		key := fmt.Sprintf("%d:%s", f.Line, f.Category)
		if seenLineCategory[key] {
			continue
		}
		seenLineCategory[key] = true
		selected = append(selected, f)
	}

	if len(selected) == 0 {
		if targetID != "" {
			return SyncSafetyFixResult{
				AppliedCount: 0,
				NewContent:   content,
				Error:        fmt.Sprintf("finding %q not found", targetID),
			}
		}
		return SyncSafetyFixResult{
			AppliedCount: 0,
			NewContent:   formatGoSourceOrFallback(content),
		}
	}

	sort.Slice(selected, func(i, j int) bool {
		if selected[i].Line != selected[j].Line {
			return selected[i].Line > selected[j].Line
		}
		return selected[i].Category > selected[j].Category
	})

	lines := strings.Split(content, "\n")
	applied := 0
	rewrittenStructs := make(map[string]bool)

	for _, f := range selected {
		if f.Line < 1 || f.Line > len(lines) {
			continue
		}
		origLine := lines[f.Line-1]
		indent := leadingWhitespace(origLine)

		switch f.Category {
		case "SYNC_VALUE_RECEIVER":
			_, commentSuffix := splitPreallocCodeAndComment(origLine)
			lines[f.Line-1] = indent + f.Replacement + commentSuffix
			if f.TargetName != "" {
				rewrittenStructs[f.TargetName] = true
			}
			applied++

		case "SYNC_LOCK_NO_UNLOCK":
			lines = insertSyncUnlockDeferOnLines(filePath, lines, f.Line, f.TargetName, f.Replacement)
			applied++
		}
	}

	updated := strings.Join(lines, "\n")
	var siblingEdits []FileEditPlan
	if len(rewrittenStructs) > 0 {
		var pkgErr error
		updated, siblingEdits, pkgErr = rewriteSyncValueCompositeLitsAcrossPackage(
			filePath,
			updated,
			rewrittenStructs,
			req.OpenBuffers,
		)
		if pkgErr != nil {
			return SyncSafetyFixResult{
				NewContent: content,
				Error:      pkgErr.Error(),
			}
		}
	}
	formatted, err := format.Source([]byte(updated))
	if err == nil {
		updated = string(formatted)
	}

	var fileEdits []FileEditPlan
	if filePath != defaultSyncInputFile && updated != content {
		fileEdits = append(fileEdits, FileEditPlan{
			FilePath:   filePath,
			NewContent: updated,
		})
	}
	fileEdits = append(fileEdits, siblingEdits...)

	return SyncSafetyFixResult{
		AppliedCount: applied,
		NewContent:   updated,
		FileEdits:    fileEdits,
	}
}

func insertSyncUnlockDeferOnLines(
	filePath string,
	lines []string,
	startLine int,
	targetExpr string,
	deferStmt string,
) []string {
	curSrc := strings.Join(lines, "\n")
	curFset := token.NewFileSet()
	curFile, _ := parser.ParseFile(curFset, filePath, curSrc, parser.ParseComments)
	if curFile != nil {
		var matchedCall *ast.CallExpr
		bestDist := 1 << 30
		ast.Inspect(curFile, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			info, ok := matchLockCallExpr(curFset, call)
			if !ok || (targetExpr != "" && info.targetExpr != targetExpr) {
				return true
			}
			dist := info.line - startLine
			if dist < 0 {
				dist = -dist
			}
			if dist < bestDist {
				bestDist = dist
				matchedCall = call
			}
			return true
		})

		if matchedCall != nil {
			endPos := curFset.Position(matchedCall.End())
			endLineIdx := endPos.Line - 1
			colIdx := endPos.Column - 1
			if endLineIdx >= 0 && endLineIdx < len(lines) && colIdx >= 0 && colIdx <= len(lines[endLineIdx]) {
				lineStr := lines[endLineIdx]
				rest := lineStr[colIdx:]
				codeAfter, _ := splitPreallocCodeAndComment(rest)
				codeAfter = stripInlineBlockComments(codeAfter)
				if strings.TrimSpace(codeAfter) != "" {
					lines[endLineIdx] = lineStr[:colIdx] + "; " + deferStmt + lineStr[colIdx:]
					return lines
				}
				indent := leadingWhitespace(lines[startLine-1])
				lines[endLineIdx] = lineStr + "\n" + indent + deferStmt
				return lines
			}
		}
	}

	origLine := lines[startLine-1]
	indent := leadingWhitespace(origLine)
	lines[startLine-1] = origLine + "\n" + indent + deferStmt
	return lines
}

func collectSyncPkgTypeMetadata(
	file *ast.File,
	interfaceTypes map[string]bool,
	structTypes map[string]bool,
	funcDecls map[string]*ast.FuncDecl,
) {
	if file == nil {
		return
	}
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.GenDecl:
			if d.Tok == token.TYPE {
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || ts.Name == nil {
						continue
					}
					switch ts.Type.(type) {
					case *ast.InterfaceType:
						interfaceTypes[ts.Name.Name] = true
					case *ast.StructType:
						structTypes[ts.Name.Name] = true
					}
				}
			}
		case *ast.FuncDecl:
			if d.Recv == nil && d.Name != nil {
				funcDecls[d.Name.Name] = d
			}
		}
	}
}

func sameSyncFilePath(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA == nil && errB == nil {
		return absA == absB
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

func rewriteSyncValueCompositeLitsAcrossPackage(
	filePath string,
	src string,
	rewrittenStructs map[string]bool,
	openBuffers map[string]string,
) (string, []FileEditPlan, error) {
	interfaceTypes := map[string]bool{
		"any":   true,
		"error": true,
	}
	structTypes := make(map[string]bool)
	funcDecls := make(map[string]*ast.FuncDecl)

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err == nil && file != nil {
		collectSyncPkgTypeMetadata(file, interfaceTypes, structTypes, funcDecls)
	}

	type siblingFile struct {
		path    string
		content string
	}
	var siblings []siblingFile

	if filePath != "" && filePath != defaultSyncInputFile {
		if fileInfo, fileStatErr := os.Stat(filePath); fileStatErr == nil && !fileInfo.IsDir() {
			dir := filepath.Dir(filePath)
			if info, statErr := os.Stat(dir); statErr == nil && info.IsDir() {
				entries, readErr := os.ReadDir(dir)
				if readErr != nil {
					return src, nil, fmt.Errorf("failed to read package directory %s: %w", dir, readErr)
				}
				for _, entry := range entries {
					if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".go") {
						continue
					}
					sibPath := filepath.Join(dir, entry.Name())
					if sameSyncFilePath(sibPath, filePath) {
						continue
					}
					var sibSrc string
					if bufContent, ok := lookupOpenBufferContent(openBuffers, sibPath); ok {
						sibSrc = bufContent
					} else {
						data, rErr := os.ReadFile(sibPath)
						if rErr != nil {
							return src, nil, fmt.Errorf("failed to read sibling file %s: %w", sibPath, rErr)
						}
						sibSrc = string(data)
					}
					sibFset := token.NewFileSet()
					sibAST, pErr := parser.ParseFile(sibFset, sibPath, sibSrc, parser.ParseComments)
					if pErr == nil && sibAST != nil {
						collectSyncPkgTypeMetadata(sibAST, interfaceTypes, structTypes, funcDecls)
						siblings = append(siblings, siblingFile{
							path:    sibPath,
							content: sibSrc,
						})
					}
				}
			}
		}
	}

	updated := rewriteSyncValueCompositeLitsForInterfacesWithMetadata(
		filePath,
		src,
		rewrittenStructs,
		interfaceTypes,
		structTypes,
		funcDecls,
	)

	var siblingEdits []FileEditPlan
	for _, sib := range siblings {
		sibUpdated := rewriteSyncValueCompositeLitsForInterfacesWithMetadata(
			sib.path,
			sib.content,
			rewrittenStructs,
			interfaceTypes,
			structTypes,
			funcDecls,
		)
		if sibUpdated != sib.content {
			if formatted, fmtErr := format.Source([]byte(sibUpdated)); fmtErr == nil {
				sibUpdated = string(formatted)
			}
			siblingEdits = append(siblingEdits, FileEditPlan{
				FilePath:   sib.path,
				NewContent: sibUpdated,
			})
		}
	}

	return updated, siblingEdits, nil
}

func rewriteSyncValueCompositeLitsForInterfacesWithMetadata(
	filePath string,
	src string,
	rewrittenStructs map[string]bool,
	pkgInterfaces map[string]bool,
	pkgStructs map[string]bool,
	pkgFuncs map[string]*ast.FuncDecl,
) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil || file == nil {
		return src
	}

	interfaceTypes := map[string]bool{
		"any":   true,
		"error": true,
	}
	for k, v := range pkgInterfaces {
		if v {
			interfaceTypes[k] = true
		}
	}
	structTypes := make(map[string]bool)
	for k, v := range pkgStructs {
		if v {
			structTypes[k] = true
		}
	}
	funcDecls := make(map[string]*ast.FuncDecl)
	for k, v := range pkgFuncs {
		funcDecls[k] = v
	}
	varInterfaceTypes := make(map[string]bool)

	collectSyncPkgTypeMetadata(file, interfaceTypes, structTypes, funcDecls)

	ast.Inspect(file, func(n ast.Node) bool {
		vs, ok := n.(*ast.ValueSpec)
		if !ok || vs.Type == nil {
			return true
		}
		baseName := extractBaseStructTypeName(vs.Type)
		isIface := interfaceTypes[baseName]
		if _, ok := vs.Type.(*ast.InterfaceType); ok {
			isIface = true
		}
		if _, ok := vs.Type.(*ast.SelectorExpr); ok {
			isIface = true
		}
		if isIface || (baseName != "" && !structTypes[baseName] && !rewrittenStructs[baseName]) {
			for _, ident := range vs.Names {
				if ident != nil && ident.Name != "" && ident.Name != "_" {
					varInterfaceTypes[ident.Name] = true
				}
			}
		}
		return true
	})

	addressTaken := make(map[*ast.CompositeLit]bool)
	ast.Inspect(file, func(n ast.Node) bool {
		un, ok := n.(*ast.UnaryExpr)
		if !ok || un.Op != token.AND {
			return true
		}
		if comp := unwrapCompositeLit(un.X); comp != nil {
			addressTaken[comp] = true
		}
		return true
	})

	type litReplacement struct {
		start int
		end   int
		wrap  bool
	}
	seenComp := make(map[*ast.CompositeLit]bool)
	var replacements []litReplacement

	markComp := func(comp *ast.CompositeLit, wrapParens bool) {
		if comp == nil || addressTaken[comp] || seenComp[comp] {
			return
		}
		litStruct := extractBaseStructTypeName(comp.Type)
		if !rewrittenStructs[litStruct] {
			return
		}
		startOff := fset.Position(comp.Pos()).Offset
		endOff := fset.Position(comp.End()).Offset
		if startOff < 0 || endOff < startOff || endOff > len(src) {
			return
		}
		seenComp[comp] = true
		replacements = append(replacements, litReplacement{
			start: startOff,
			end:   endOff,
			wrap:  wrapParens,
		})
	}

	inspectScope := func(fnType *ast.FuncType, root ast.Node) {
		ast.Inspect(root, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if lit, isLit := n.(*ast.FuncLit); isLit && n != root {
				if lit.Body != nil {
					ast.Inspect(lit.Body, func(inner ast.Node) bool {
						ret, ok := inner.(*ast.ReturnStmt)
						if !ok || lit.Type == nil || lit.Type.Results == nil {
							return true
						}
						for i, resExpr := range ret.Results {
							comp := unwrapCompositeLit(resExpr)
							if comp == nil {
								continue
							}
							litStruct := extractBaseStructTypeName(comp.Type)
							resType := funcFieldTypeAt(lit.Type.Results, i)
							if resType != nil && extractBaseStructTypeName(resType) != litStruct {
								markComp(comp, false)
							}
						}
						return true
					})
				}
			}

			switch node := n.(type) {
			case *ast.ValueSpec:
				if node.Type != nil {
					targetBase := extractBaseStructTypeName(node.Type)
					for _, val := range node.Values {
						comp := unwrapCompositeLit(val)
						if comp == nil {
							continue
						}
						litStruct := extractBaseStructTypeName(comp.Type)
						if targetBase != litStruct {
							markComp(comp, false)
						}
					}
				}

			case *ast.AssignStmt:
				for i, rhs := range node.Rhs {
					comp := unwrapCompositeLit(rhs)
					if comp == nil || i >= len(node.Lhs) {
						continue
					}
					if lhsIdent, ok := node.Lhs[i].(*ast.Ident); ok && varInterfaceTypes[lhsIdent.Name] {
						markComp(comp, false)
					}
				}

			case *ast.CallExpr:
				for argIdx, arg := range node.Args {
					comp := unwrapCompositeLit(arg)
					if comp == nil {
						continue
					}
					litStruct := extractBaseStructTypeName(comp.Type)
					switch fun := node.Fun.(type) {
					case *ast.Ident:
						if interfaceTypes[fun.Name] {
							markComp(comp, false)
						} else if fd, ok := funcDecls[fun.Name]; ok && fd.Type != nil && fd.Type.Params != nil {
							pType := funcFieldTypeAt(fd.Type.Params, argIdx)
							if pType != nil && extractBaseStructTypeName(pType) != litStruct {
								markComp(comp, false)
							}
						} else if !structTypes[fun.Name] && !rewrittenStructs[fun.Name] {
							markComp(comp, false)
						}
					case *ast.ParenExpr, *ast.InterfaceType, *ast.SelectorExpr:
						markComp(comp, false)
					}
				}

			case *ast.ReturnStmt:
				if fnType != nil && fnType.Results != nil {
					for i, resExpr := range node.Results {
						comp := unwrapCompositeLit(resExpr)
						if comp == nil {
							continue
						}
						litStruct := extractBaseStructTypeName(comp.Type)
						resType := funcFieldTypeAt(fnType.Results, i)
						if resType != nil && extractBaseStructTypeName(resType) != litStruct {
							markComp(comp, false)
						}
					}
				}

			case *ast.CompositeLit:
				var eltType ast.Expr
				switch t := node.Type.(type) {
				case *ast.ArrayType:
					eltType = t.Elt
				case *ast.MapType:
					eltType = t.Value
				}
				if eltType != nil {
					eltBase := extractBaseStructTypeName(eltType)
					for _, elt := range node.Elts {
						valExpr := elt
						if kv, ok := elt.(*ast.KeyValueExpr); ok {
							valExpr = kv.Value
						}
						comp := unwrapCompositeLit(valExpr)
						if comp == nil {
							continue
						}
						litStruct := extractBaseStructTypeName(comp.Type)
						if eltBase != litStruct {
							markComp(comp, false)
						}
					}
				}

			case *ast.SelectorExpr:
				if comp := unwrapCompositeLit(node.X); comp != nil {
					markComp(comp, true)
				}
			}

			return true
		})
	}

	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok {
			inspectScope(fn.Type, fn)
		} else {
			inspectScope(nil, decl)
		}
	}

	if len(replacements) == 0 {
		return src
	}

	sort.Slice(replacements, func(i, j int) bool {
		return replacements[i].start > replacements[j].start
	})

	out := src
	for _, r := range replacements {
		orig := out[r.start:r.end]
		if r.wrap {
			out = out[:r.start] + "(&" + orig + ")" + out[r.end:]
		} else {
			out = out[:r.start] + "&" + orig + out[r.end:]
		}
	}
	return out
}

func unwrapCompositeLit(expr ast.Expr) *ast.CompositeLit {
	for expr != nil {
		if p, ok := expr.(*ast.ParenExpr); ok {
			expr = p.X
			continue
		}
		if comp, ok := expr.(*ast.CompositeLit); ok {
			return comp
		}
		return nil
	}
	return nil
}

func funcFieldTypeAt(fl *ast.FieldList, targetIdx int) ast.Expr {
	if fl == nil || targetIdx < 0 {
		return nil
	}
	idx := 0
	for _, field := range fl.List {
		if field == nil || field.Type == nil {
			continue
		}
		if ell, ok := field.Type.(*ast.Ellipsis); ok {
			if targetIdx >= idx {
				return ell.Elt
			}
		}
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		if targetIdx < idx+count {
			return field.Type
		}
		idx += count
	}
	return nil
}

func collectSyncLockStructs(fset *token.FileSet, file *ast.File, syncStructs map[string]string) {
	if file == nil {
		return
	}
	for _, decl := range file.Decls {
		genDecl, ok := decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.TYPE {
			continue
		}
		for _, spec := range genDecl.Specs {
			typeSpec, ok := spec.(*ast.TypeSpec)
			if !ok || typeSpec.Name == nil {
				continue
			}
			structType, ok := typeSpec.Type.(*ast.StructType)
			if !ok || structType.Fields == nil {
				continue
			}
			for _, field := range structType.Fields.List {
				if desc, ok := matchSyncLockField(fset, field); ok {
					syncStructs[typeSpec.Name.Name] = desc
					break
				}
			}
		}
	}
}

func matchSyncLockField(fset *token.FileSet, field *ast.Field) (string, bool) {
	if field == nil || field.Type == nil {
		return "", false
	}
	if _, isPtr := field.Type.(*ast.StarExpr); isPtr {
		return "", false
	}

	typeStr := strings.TrimSpace(exprToString(fset, field.Type))
	switch typeStr {
	case "sync.Mutex", "sync.RWMutex", "sync.WaitGroup", "sync.Once", "sync.Cond", "sync.Map", "Mutex", "RWMutex", "WaitGroup", "Once":
		if len(field.Names) > 0 && field.Names[0] != nil && field.Names[0].Name != "" {
			return fmt.Sprintf("%s %s", field.Names[0].Name, typeStr), true
		}
		return typeStr, true
	}

	for _, nameIdent := range field.Names {
		if nameIdent == nil {
			continue
		}
		lower := strings.ToLower(nameIdent.Name)
		if lower == "mu" || lower == "mutex" || lower == "rwmu" || lower == "rwmutex" || lower == "wg" {
			return fmt.Sprintf("%s %s", nameIdent.Name, typeStr), true
		}
	}

	return "", false
}

func inspectASTFileSyncSafety(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	content string,
	syncStructs map[string]string,
) []SyncSafetyFinding {
	var findings []SyncSafetyFinding

	lines := strings.Split(content, "\n")
	lineAt := func(line int) string {
		if line >= 1 && line <= len(lines) {
			return strings.TrimSpace(lines[line-1])
		}
		return ""
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}
		fnName := ""
		if fn.Name != nil {
			fnName = fn.Name.Name
		}

		if finding, ok := checkSyncValueReceiver(fset, fn, filePath, lines, lineAt, syncStructs); ok {
			findings = append(findings, finding)
		}

		if fn.Body != nil {
			findings = append(findings, inspectSyncSafetyInBlock(fset, fn.Body, fnName, filePath, lineAt)...)

			ast.Inspect(fn.Body, func(n ast.Node) bool {
				lit, ok := n.(*ast.FuncLit)
				if ok && lit.Body != nil {
					findings = append(findings, inspectSyncSafetyInBlock(fset, lit.Body, fnName, filePath, lineAt)...)
				}
				return true
			})
		}
	}

	return findings
}

func checkSyncValueReceiver(
	fset *token.FileSet,
	fn *ast.FuncDecl,
	filePath string,
	lines []string,
	lineAt func(int) string,
	syncStructs map[string]string,
) (SyncSafetyFinding, bool) {
	if fn == nil || fn.Recv == nil || len(fn.Recv.List) == 0 {
		return SyncSafetyFinding{}, false
	}
	recvField := fn.Recv.List[0]
	if recvField == nil || recvField.Type == nil {
		return SyncSafetyFinding{}, false
	}
	if _, isPtr := recvField.Type.(*ast.StarExpr); isPtr {
		return SyncSafetyFinding{}, false
	}

	structName := extractBaseStructTypeName(recvField.Type)
	if structName == "" {
		return SyncSafetyFinding{}, false
	}
	typeExprStr := strings.TrimSpace(exprToString(fset, recvField.Type))
	if typeExprStr == "" {
		typeExprStr = structName
	}

	recvName := ""
	if len(recvField.Names) > 0 && recvField.Names[0] != nil {
		recvName = recvField.Names[0].Name
	}

	lockDesc, hasKnownSyncField := syncStructs[structName]
	usedLockExpr := ""
	if fn.Body != nil && recvName != "" && recvName != "_" {
		usedLockExpr = findReceiverLockUsageInBody(fset, fn.Body, recvName)
	}

	if !hasKnownSyncField && usedLockExpr == "" {
		return SyncSafetyFinding{}, false
	}

	fnName := ""
	if fn.Name != nil {
		fnName = fn.Name.Name
	}
	line := fset.Position(fn.Pos()).Line
	snippet := lineAt(line)

	replacement := buildPointerReceiverLineReplacement(fset, recvField, lines, line, recvName, typeExprStr)

	origRecv := fmt.Sprintf("(%s)", typeExprStr)
	newRecv := fmt.Sprintf("(*%s)", typeExprStr)
	if recvName != "" {
		origRecv = fmt.Sprintf("(%s %s)", recvName, typeExprStr)
		newRecv = fmt.Sprintf("(%s *%s)", recvName, typeExprStr)
	}

	detail := lockDesc
	if detail == "" {
		detail = usedLockExpr
	}

	return SyncSafetyFinding{
		ID:          fmt.Sprintf("SYNC_VALUE_RECEIVER:%s:%d:%s", filePath, line, fnName),
		Category:    "SYNC_VALUE_RECEIVER",
		Severity:    "error",
		Title:       fmt.Sprintf("Value receiver %s copies sync lock on method '%s'", origRecv, fnName),
		Message:     fmt.Sprintf("Method '%s' uses value receiver %s which copies '%s' (%s) by value on each call; change receiver to %s so callers share the same lock.", fnName, origRecv, structName, detail, newRecv),
		File:        filePath,
		Line:        line,
		EnclosingFn: fnName,
		TargetName:  structName,
		Snippet:     snippet,
		Replacement: replacement,
		CanAutoFix:  true,
	}, true
}

func extractBaseStructTypeName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.IndexExpr:
		return extractBaseStructTypeName(t.X)
	case *ast.IndexListExpr:
		return extractBaseStructTypeName(t.X)
	}
	return ""
}

func findReceiverLockUsageInBody(fset *token.FileSet, body *ast.BlockStmt, recvName string) string {
	if body == nil || recvName == "" {
		return ""
	}
	found := ""
	ast.Inspect(body, func(n ast.Node) bool {
		if found != "" || n == nil {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		methodName := sel.Sel.Name
		switch methodName {
		case "Lock", "RLock", "Unlock", "RUnlock", "TryLock", "TryRLock", "Wait", "Done", "Add", "Do":
			targetExpr := strings.TrimSpace(exprToString(fset, sel.X))
			if targetExpr == recvName || strings.HasPrefix(targetExpr, recvName+".") {
				found = targetExpr + "." + methodName + "()"
				return false
			}
		}
		return true
	})
	return found
}

func buildPointerReceiverLineReplacement(
	fset *token.FileSet,
	recvField *ast.Field,
	lines []string,
	fnLine int,
	recvName string,
	typeExprStr string,
) string {
	if fnLine >= 1 && fnLine <= len(lines) {
		origLine := lines[fnLine-1]
		codeOnly, _ := splitPreallocCodeAndComment(origLine)
		typePos := fset.Position(recvField.Type.Pos())
		if typePos.Line == fnLine && typePos.Column >= 1 && typePos.Column-1 <= len(codeOnly) {
			rewritten := codeOnly[:typePos.Column-1] + "*" + codeOnly[typePos.Column-1:]
			return strings.TrimSpace(rewritten)
		}
		if recvName != "" {
			oldRecv := fmt.Sprintf("(%s %s)", recvName, typeExprStr)
			newRecv := fmt.Sprintf("(%s *%s)", recvName, typeExprStr)
			if strings.Contains(codeOnly, oldRecv) {
				return strings.TrimSpace(strings.Replace(codeOnly, oldRecv, newRecv, 1))
			}
		} else {
			oldRecv := fmt.Sprintf("(%s)", typeExprStr)
			newRecv := fmt.Sprintf("(*%s)", typeExprStr)
			if strings.Contains(codeOnly, oldRecv) {
				return strings.TrimSpace(strings.Replace(codeOnly, oldRecv, newRecv, 1))
			}
		}
	}
	if recvName != "" {
		return fmt.Sprintf("func (%s *%s)", recvName, typeExprStr)
	}
	return fmt.Sprintf("func (*%s)", typeExprStr)
}

type syncLockCallInfo struct {
	targetExpr   string
	lockMethod   string
	unlockMethod string
	line         int
	call         *ast.CallExpr
}

func inspectSyncSafetyInBlock(
	fset *token.FileSet,
	root *ast.BlockStmt,
	fnName string,
	filePath string,
	lineAt func(int) string,
) []SyncSafetyFinding {
	if root == nil {
		return nil
	}

	var findings []SyncSafetyFinding
	seenDeferLoopLines := make(map[int]bool)

	inspectLoopBodiesOnce(root, func(n ast.Node) {
		deferStmt, ok := n.(*ast.DeferStmt)
		if !ok || deferStmt.Call == nil {
			return
		}
		targetExpr, unlockMethod, ok := matchUnlockCallExpr(fset, deferStmt.Call)
		if !ok {
			return
		}
		line := fset.Position(deferStmt.Pos()).Line
		if seenDeferLoopLines[line] {
			return
		}
		seenDeferLoopLines[line] = true

		findings = append(findings, SyncSafetyFinding{
			ID:          fmt.Sprintf("SYNC_DEFER_UNLOCK_LOOP:%s:%d:%s", filePath, line, targetExpr),
			Category:    "SYNC_DEFER_UNLOCK_LOOP",
			Severity:    "warning",
			Title:       fmt.Sprintf("defer %s.%s() inside loop holds lock until function returns", targetExpr, unlockMethod),
			Message:     fmt.Sprintf("'defer %s.%s()' is scheduled inside a loop in '%s', so the lock will not be released at the end of each iteration and may deadlock on the second iteration; call '%s.%s()' directly before the iteration ends or extract the loop body into a helper function.", targetExpr, unlockMethod, fnName, targetExpr, unlockMethod),
			File:        filePath,
			Line:        line,
			EnclosingFn: fnName,
			TargetName:  targetExpr,
			Snippet:     lineAt(line),
			Replacement: fmt.Sprintf("%s.%s()", targetExpr, unlockMethod),
			CanAutoFix:  false,
		})
	})

	unlockedTargets := make(map[string]bool)
	var lockCalls []syncLockCallInfo
	seenLockLines := make(map[int]bool)

	ast.Inspect(root, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if _, isNestedLit := n.(*ast.FuncLit); isNestedLit {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if targetExpr, _, ok := matchUnlockCallExpr(fset, call); ok {
			unlockedTargets[targetExpr] = true
			return true
		}
		if lockInfo, ok := matchLockCallExpr(fset, call); ok {
			if !seenLockLines[lockInfo.line] {
				seenLockLines[lockInfo.line] = true
				lockCalls = append(lockCalls, lockInfo)
			}
		}
		return true
	})

	for _, lc := range lockCalls {
		if unlockedTargets[lc.targetExpr] {
			continue
		}
		deferUnlock := fmt.Sprintf("defer %s.%s()", lc.targetExpr, lc.unlockMethod)
		findings = append(findings, SyncSafetyFinding{
			ID:          fmt.Sprintf("SYNC_LOCK_NO_UNLOCK:%s:%d:%s", filePath, lc.line, lc.targetExpr),
			Category:    "SYNC_LOCK_NO_UNLOCK",
			Severity:    "error",
			Title:       fmt.Sprintf("Lock '%s.%s()' acquired without matching '%s.%s()'", lc.targetExpr, lc.lockMethod, lc.targetExpr, lc.unlockMethod),
			Message:     fmt.Sprintf("'%s.%s()' is called in '%s' without a matching '%s.%s()' in this function body; insert '%s' immediately after acquiring the lock to avoid deadlocks.", lc.targetExpr, lc.lockMethod, fnName, lc.targetExpr, lc.unlockMethod, deferUnlock),
			File:        filePath,
			Line:        lc.line,
			EnclosingFn: fnName,
			TargetName:  lc.targetExpr,
			Snippet:     lineAt(lc.line),
			Replacement: deferUnlock,
			CanAutoFix:  !stmtInsideLoopOrNonBlock(root, lc.call),
		})
	}

	return findings
}

func matchLockCallExpr(fset *token.FileSet, call *ast.CallExpr) (syncLockCallInfo, bool) {
	if call == nil || len(call.Args) != 0 {
		return syncLockCallInfo{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.X == nil {
		return syncLockCallInfo{}, false
	}
	methodName := sel.Sel.Name
	var unlockMethod string
	switch methodName {
	case "Lock":
		unlockMethod = "Unlock"
	case "RLock":
		unlockMethod = "RUnlock"
	default:
		return syncLockCallInfo{}, false
	}

	targetExpr := strings.TrimSpace(exprToString(fset, sel.X))
	if targetExpr == "" {
		return syncLockCallInfo{}, false
	}

	return syncLockCallInfo{
		targetExpr:   targetExpr,
		lockMethod:   methodName,
		unlockMethod: unlockMethod,
		line:         fset.Position(call.Pos()).Line,
		call:         call,
	}, true
}

func matchUnlockCallExpr(fset *token.FileSet, call *ast.CallExpr) (targetExpr string, unlockMethod string, ok bool) {
	if call == nil || len(call.Args) != 0 {
		return "", "", false
	}
	sel, isSel := call.Fun.(*ast.SelectorExpr)
	if !isSel || sel.Sel == nil || sel.X == nil {
		return "", "", false
	}
	switch sel.Sel.Name {
	case "Unlock", "RUnlock":
		target := strings.TrimSpace(exprToString(fset, sel.X))
		if target == "" {
			return "", "", false
		}
		return target, sel.Sel.Name, true
	default:
		return "", "", false
	}
}
