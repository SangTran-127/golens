package goast

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func resolveCalledFuncDecl(path string, src []byte, fset *token.FileSet, f *ast.File, call *ast.CallExpr, name string) (string, []byte, *token.FileSet, *ast.FuncDecl) {
	funExpr := unwrapCallFunExpr(call.Fun)
	_, isIdent := funExpr.(*ast.Ident)
	selExpr, isSel := funExpr.(*ast.SelectorExpr)
	var selPkg string
	if isSel {
		if xId, ok := selExpr.X.(*ast.Ident); ok {
			selPkg = xId.Name
		}
	}

	pkgFiles := loadSiblingSigFiles(path, src, fset, f, nil)
	inferredRecvType := ""
	if isSel {
		inferredRecvType = inferSigSelectorReceiverType(f, src, fset, pkgFiles, selExpr, call.Pos())
	}

	type sigCandidate struct {
		pf    parsedSigFile
		fn    *ast.FuncDecl
		score int
	}
	scoreCtx := sigCandidateScoreCtx{
		call:             call,
		primaryPath:      path,
		callerAST:        f,
		callerSrc:        src,
		callerFset:       fset,
		pkgFiles:         pkgFiles,
		isSel:            isSel,
		inferredRecvType: inferredRecvType,
	}
	var pkgCandidates []sigCandidate
	for _, pf := range pkgFiles {
		for _, d := range pf.ast.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Name == nil || fn.Name.Name != name {
				continue
			}
			if isIdent && fn.Recv != nil {
				continue
			}
			sc := scoreSigCandidate(pf, fn, scoreCtx)
			pkgCandidates = append(pkgCandidates, sigCandidate{pf: pf, fn: fn, score: sc})
		}
	}
	if len(pkgCandidates) > 0 {
		best := pkgCandidates[0]
		for _, c := range pkgCandidates[1:] {
			if c.score > best.score {
				best = c
			}
		}
		if !(isSel && inferredRecvType != "" && best.fn.Recv != nil && extractReceiverTypeName(best.fn.Recv) != inferredRecvType && selPkg != "") {
			return best.pf.path, best.pf.src, best.pf.fset, best.fn
		}
	}

	dir := filepath.Dir(path)
	modRoot := findModuleRoot(dir)
	if modRoot != "" && modRoot != dir {
		var modCandidates []sigCandidate
		filesVisited := 0
		_ = filepath.WalkDir(modRoot, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				base := d.Name()
				if strings.HasPrefix(base, ".") || base == "vendor" || base == "node_modules" || base == "testdata" || base == "build" || base == "third_party" {
					return filepath.SkipDir
				}
				return nil
			}
			if p == path || filepath.Dir(p) == dir || !strings.HasSuffix(d.Name(), ".go") {
				return nil
			}
			if info, statErr := d.Info(); statErr == nil && info.Size() > (1<<20) {
				return nil
			}
			filesVisited++
			if filesVisited > 150 {
				return filepath.SkipAll
			}
			candSrc, err := os.ReadFile(p)
			if err != nil {
				return nil
			}
			candFset := token.NewFileSet()
			candAST, _ := parser.ParseFile(candFset, p, candSrc, parser.ParseComments)
			if candAST == nil {
				return nil
			}
			if selPkg != "" && candAST.Name != nil && candAST.Name.Name != selPkg {
				return nil
			}
			pf := parsedSigFile{path: p, src: candSrc, fset: candFset, ast: candAST}
			for _, decl := range candAST.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Name == nil || fn.Name.Name != name {
					continue
				}
				if isIdent && fn.Recv != nil {
					continue
				}
				sc := scoreSigCandidate(pf, fn, scoreCtx)
				modCandidates = append(modCandidates, sigCandidate{pf: pf, fn: fn, score: sc})
			}
			return nil
		})
		if len(modCandidates) > 0 {
			best := modCandidates[0]
			for _, c := range modCandidates[1:] {
				if c.score > best.score {
					best = c
				}
			}
			return best.pf.path, best.pf.src, best.pf.fset, best.fn
		}
	}

	return "", nil, nil, nil
}

func findModuleRoot(startDir string) string {
	cur := startDir
	for i := 0; i < 5 && cur != "" && cur != "/" && cur != "."; i++ {
		if _, err := os.Stat(filepath.Join(cur, "go.mod")); err == nil {
			return cur
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	return startDir
}

func flattenFieldList(fset *token.FileSet, src []byte, fl *ast.FieldList) []ParamSpec {
	out := make([]ParamSpec, 0)
	if fl == nil {
		return out
	}
	idx := 0
	for _, field := range fl.List {
		typStr := exprString(fset, src, field.Type)
		if len(field.Names) == 0 {
			out = append(out, ParamSpec{
				OrigIndex: idx,
				Name:      "",
				Type:      typStr,
			})
			idx++
		} else {
			for _, id := range field.Names {
				name := ""
				if id != nil {
					name = id.Name
				}
				out = append(out, ParamSpec{
					OrigIndex: idx,
					Name:      name,
					Type:      typStr,
				})
				idx++
			}
		}
	}
	return out
}

func exprString(fset *token.FileSet, src []byte, expr ast.Expr) string {
	if expr == nil {
		return ""
	}
	start := fset.Position(expr.Pos()).Offset
	end := fset.Position(expr.End()).Offset
	if start >= 0 && end >= start && end <= len(src) {
		return strings.TrimSpace(string(src[start:end]))
	}
	return ""
}

func lspPos(fset *token.FileSet, src []byte, pos token.Pos) LSPWirePos {
	p := fset.Position(pos)
	lineStart := p.Offset - (p.Column - 1)
	if lineStart < 0 {
		lineStart = 0
	}
	charCol := 0
	if p.Offset >= lineStart && p.Offset <= len(src) {
		charCol = utf16Len(src[lineStart:p.Offset])
	}
	return LSPWirePos{
		Line:      p.Line - 1,
		Character: charCol,
	}
}

func lspRange(fset *token.FileSet, src []byte, start, end token.Pos) LSPWireRange {
	return LSPWireRange{
		Start: lspPos(fset, src, start),
		End:   lspPos(fset, src, end),
	}
}

func formatSignatureHeader(spec FuncSignatureSpec, typeParamsText string) string {
	var sb strings.Builder
	sb.WriteString(strings.TrimSpace(spec.Name))
	if typeParamsText != "" {
		sb.WriteString(typeParamsText)
	}
	sb.WriteByte('(')
	for i, p := range spec.Params {
		if i > 0 {
			sb.WriteString(", ")
		}
		pName := strings.TrimSpace(p.Name)
		pType := strings.TrimSpace(p.Type)
		if pName != "" {
			sb.WriteString(pName)
			sb.WriteByte(' ')
			sb.WriteString(pType)
		} else {
			sb.WriteString(pType)
		}
	}
	sb.WriteByte(')')

	if len(spec.Results) == 1 && strings.TrimSpace(spec.Results[0].Name) == "" {
		rType := strings.TrimSpace(spec.Results[0].Type)
		if rType != "" {
			sb.WriteByte(' ')
			sb.WriteString(rType)
		}
	} else if len(spec.Results) >= 1 {
		sb.WriteString(" (")
		for i, r := range spec.Results {
			if i > 0 {
				sb.WriteString(", ")
			}
			rName := strings.TrimSpace(r.Name)
			rType := strings.TrimSpace(r.Type)
			if rName != "" {
				sb.WriteString(rName)
				sb.WriteByte(' ')
				sb.WriteString(rType)
			} else {
				sb.WriteString(rType)
			}
		}
		sb.WriteByte(')')
	}
	return sb.String()
}

func zeroValueForType(typ string) string {
	t := strings.TrimSpace(typ)
	switch t {
	case "string":
		return `""`
	case "bool":
		return "false"
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "float32", "float64", "complex64", "complex128":
		return "0"
	default:
		return "nil"
	}
}

func ApplyChangeSignature(reqJSON string) string {
	var req ChangeSignatureRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalError("invalid request: " + err.Error())
	}
	spec := req.Spec
	if spec.Path == "" || strings.TrimSpace(spec.Name) == "" {
		return marshalError("missing function path or name")
	}

	readSource := func(p string) ([]byte, error) {
		if req.Buffers != nil {
			if buf, ok := req.Buffers[p]; ok {
				return []byte(buf), nil
			}
		}
		return os.ReadFile(p)
	}

	declSrc, err := readSource(spec.Path)
	if err != nil {
		return marshalError("failed to read declaration file: " + err.Error())
	}

	fset := token.NewFileSet()
	declFile, _ := parser.ParseFile(fset, spec.Path, declSrc, parser.ParseComments)
	if declFile == nil {
		return marshalError("failed to parse declaration file")
	}
	declTF := fset.File(declFile.Pos())
	if declTF == nil {
		return marshalError("failed to locate token file")
	}

	specRecvBase := ""
	if fields := strings.Fields(strings.TrimSpace(spec.Receiver)); len(fields) > 0 {
		specRecvBase = strings.TrimPrefix(fields[len(fields)-1], "*")
		if idx := strings.IndexByte(specRecvBase, '['); idx > 0 {
			specRecvBase = specRecvBase[:idx]
		}
	}

	var targetDecl *ast.FuncDecl
	for _, d := range declFile.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Name == nil {
			continue
		}
		if fn.Name.Name == spec.OrigName && fset.Position(fn.Name.Pos()).Line == spec.NameLine {
			if specRecvBase == "" || extractReceiverTypeName(fn.Recv) == specRecvBase {
				targetDecl = fn
				break
			}
		}
	}
	if targetDecl == nil && specRecvBase != "" {
		for _, d := range declFile.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Name == nil {
				continue
			}
			if fn.Name.Name == spec.OrigName && extractReceiverTypeName(fn.Recv) == specRecvBase {
				targetDecl = fn
				break
			}
		}
	}
	if targetDecl == nil {
		for _, d := range declFile.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Name == nil {
				continue
			}
			if fn.Name.Name == spec.OrigName {
				targetDecl = fn
				break
			}
		}
	}
	if targetDecl == nil {
		return marshalError("target function declaration not found")
	}

	targetRecvBase := extractReceiverTypeName(targetDecl.Recv)
	pkgFiles := loadSiblingSigFiles(spec.Path, declSrc, fset, declFile, req.Buffers)

	origParams := flattenFieldList(fset, declSrc, targetDecl.Type.Params)
	origParamCount := len(origParams)

	typeParamsText := ""
	if targetDecl.Type.TypeParams != nil {
		tpStart := fset.Position(targetDecl.Type.TypeParams.Pos()).Offset
		tpEnd := fset.Position(targetDecl.Type.TypeParams.End()).Offset
		if tpStart >= 0 && tpEnd >= tpStart && tpEnd <= len(declSrc) {
			typeParamsText = string(declSrc[tpStart:tpEnd])
		}
	}

	nameStartOffset := fset.Position(targetDecl.Name.Pos()).Offset
	var sigEndOffset int
	if targetDecl.Body != nil {
		sigEndOffset = fset.Position(targetDecl.Body.Lbrace).Offset
		for sigEndOffset > nameStartOffset && (declSrc[sigEndOffset-1] == ' ' || declSrc[sigEndOffset-1] == '\t') {
			sigEndOffset--
		}
	} else {
		sigEndOffset = fset.Position(targetDecl.End()).Offset
	}

	editsByPath := map[string][]SigTextEdit{}
	newHeader := formatSignatureHeader(spec, typeParamsText)
	editsByPath[spec.Path] = append(editsByPath[spec.Path], SigTextEdit{
		Range:   lspRange(fset, declSrc, targetDecl.Name.Pos(), declTF.Pos(sigEndOffset)),
		NewText: newHeader,
	})

	paramRenames := map[string]string{}
	for _, p := range spec.Params {
		if p.OrigIndex >= 0 && p.OrigIndex < len(origParams) {
			oldName := origParams[p.OrigIndex].Name
			newName := strings.TrimSpace(p.Name)
			if oldName != "" && oldName != "_" && newName != "" && newName != oldName {
				paramRenames[oldName] = newName
			}
		}
	}

	refsByPath := map[string][]SigRefLocation{}
	for _, ref := range req.References {
		if ref.Path != "" {
			refsByPath[ref.Path] = append(refsByPath[ref.Path], ref)
		}
	}
	if _, ok := refsByPath[spec.Path]; !ok {
		refsByPath[spec.Path] = nil
	}
	for p := range req.Buffers {
		if _, ok := refsByPath[p]; !ok {
			refsByPath[p] = nil
		}
	}
	if pkgDir := filepath.Dir(spec.Path); pkgDir != "" {
		if entries, err := os.ReadDir(pkgDir); err == nil {
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				name := e.Name()
				if !strings.HasSuffix(name, ".go") || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") {
					continue
				}
				full := filepath.Join(pkgDir, name)
				if _, ok := refsByPath[full]; !ok {
					refsByPath[full] = nil
				}
			}
		}
	}

	type byteSpan struct {
		lo int
		hi int
	}
	var replacedCallArgSpansInDecl []byteSpan

	paths := make([]string, 0, len(refsByPath))
	for p := range refsByPath {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	for _, filePath := range paths {
		var fileSrc []byte
		var fileAST *ast.File
		var fileFset *token.FileSet
		var fileTF *token.File
		if filePath == spec.Path {
			fileSrc = declSrc
			fileAST = declFile
			fileFset = fset
			fileTF = declTF
		} else {
			src, err := readSource(filePath)
			if err != nil {
				continue
			}
			fileSrc = src
			fileFset = token.NewFileSet()
			fileAST, _ = parser.ParseFile(fileFset, filePath, fileSrc, parser.ParseComments)
			if fileAST == nil {
				continue
			}
			fileTF = fileFset.File(fileAST.Pos())
			if fileTF == nil {
				continue
			}
		}

		refs := refsByPath[filePath]
		seenLparen := map[token.Pos]bool{}

		ast.Inspect(fileAST, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok || !call.Lparen.IsValid() || !call.Rparen.IsValid() {
				return true
			}
			if seenLparen[call.Lparen] {
				return true
			}
			calleeIdent := extractCalleeIdent(call.Fun)
			if calleeIdent == nil || calleeIdent.Name != spec.OrigName {
				return true
			}
			if targetDecl != nil && calleeIdent == targetDecl.Name {
				return true
			}

			unwrappedFun := unwrapCallFunExpr(call.Fun)
			callSel, isSel := unwrappedFun.(*ast.SelectorExpr)
			callRecvBase := ""
			if targetDecl.Recv != nil {
				if !isSel {
					return true
				}
				callRecvBase = inferSigSelectorReceiverType(fileAST, fileSrc, fileFset, pkgFiles, callSel, call.Pos())
				if targetRecvBase != "" && callRecvBase != "" && callRecvBase != targetRecvBase {
					return true
				}
			}

			matched := false
			idRange := lspRange(fileFset, fileSrc, calleeIdent.Pos(), calleeIdent.End())
			for _, ref := range refs {
				if ref.Line == idRange.Start.Line {
					if (ref.Col >= idRange.Start.Character && ref.Col <= idRange.End.Character) ||
						(ref.Col-1 >= idRange.Start.Character && ref.Col-1 <= idRange.End.Character) {
						matched = true
						break
					}
				}
			}
			samePkgDir := filepath.Dir(filePath) == filepath.Dir(spec.Path) &&
				fileAST.Name != nil && declFile.Name != nil &&
				(fileAST.Name.Name == declFile.Name.Name || fileAST.Name.Name == declFile.Name.Name+"_test")
			if !matched && (filePath == spec.Path || samePkgDir || len(req.References) == 0) {
				if targetDecl.Recv == nil {
					if _, isIdent := unwrappedFun.(*ast.Ident); isIdent && (filePath == spec.Path || fileAST.Name.Name == declFile.Name.Name || len(req.References) == 0) {
						matched = true
					}
				} else if (filePath == spec.Path || samePkgDir || len(refs) == 0) && isSel {
					if callRecvBase == "" && targetRecvBase != "" {
						declPF := parsedSigFile{path: spec.Path, src: declSrc, fset: fset, ast: declFile}
						scoreCtx := sigCandidateScoreCtx{
							call:             call,
							primaryPath:      filePath,
							callerAST:        fileAST,
							callerSrc:        fileSrc,
							callerFset:       fileFset,
							pkgFiles:         pkgFiles,
							isSel:            true,
							inferredRecvType: callRecvBase,
						}
						targetScore := scoreSigCandidate(declPF, targetDecl, scoreCtx)
						betterOther := false
						for _, pf := range pkgFiles {
							for _, d := range pf.ast.Decls {
								fn, ok := d.(*ast.FuncDecl)
								if !ok || fn == targetDecl || fn.Recv == nil || fn.Name == nil || fn.Name.Name != spec.OrigName {
									continue
								}
								if extractReceiverTypeName(fn.Recv) == targetRecvBase {
									continue
								}
								if scoreSigCandidate(pf, fn, scoreCtx) > targetScore {
									betterOther = true
									break
								}
							}
							if betterOther {
								break
							}
						}
						if !betterOther {
							matched = true
						}
					} else {
						matched = true
					}
				}
			}
			if !matched {
				return true
			}
			seenLparen[call.Lparen] = true

			if spec.Name != spec.OrigName {
				editsByPath[filePath] = append(editsByPath[filePath], SigTextEdit{
					Range:   idRange,
					NewText: strings.TrimSpace(spec.Name),
				})
			}

			if len(call.Args) == origParamCount && !call.Ellipsis.IsValid() {
				inDeclBody := filePath == spec.Path && targetDecl.Body != nil &&
					call.Pos() >= targetDecl.Body.Pos() && call.End() <= targetDecl.Body.End()

				origArgs := make([]string, len(call.Args))
				for i, argExpr := range call.Args {
					origArgs[i] = renderArgExpr(fileFset, fileSrc, argExpr, inDeclBody, paramRenames)
				}

				newArgs := make([]string, 0, len(spec.Params))
				for _, p := range spec.Params {
					if p.OrigIndex >= 0 && p.OrigIndex < len(origArgs) {
						newArgs = append(newArgs, origArgs[p.OrigIndex])
					} else {
						defVal := strings.TrimSpace(p.DefaultValue)
						if defVal == "" {
							defVal = zeroValueForType(p.Type)
						}
						newArgs = append(newArgs, defVal)
					}
				}

				lparenEndOffset := fileFset.Position(call.Lparen).Offset + 1
				rparenStartOffset := fileFset.Position(call.Rparen).Offset
				if lparenEndOffset >= 0 && rparenStartOffset >= lparenEndOffset && rparenStartOffset <= len(fileSrc) {
					newArgsText := strings.Join(newArgs, ", ")
					oldArgsText := string(fileSrc[lparenEndOffset:rparenStartOffset])
					if newArgsText != oldArgsText {
						editsByPath[filePath] = append(editsByPath[filePath], SigTextEdit{
							Range:   lspRange(fileFset, fileSrc, fileTF.Pos(lparenEndOffset), call.Rparen),
							NewText: newArgsText,
						})
						if inDeclBody {
							replacedCallArgSpansInDecl = append(replacedCallArgSpansInDecl, byteSpan{
								lo: lparenEndOffset,
								hi: rparenStartOffset,
							})
						}
					}
				}
			}
			return true
		})
	}

	if targetDecl.Body != nil && len(paramRenames) > 0 {
		skipIdent := collectSkippedIdents(targetDecl.Body)
		ast.Inspect(targetDecl.Body, func(n ast.Node) bool {
			id, ok := n.(*ast.Ident)
			if !ok || id == nil || skipIdent[id] {
				return true
			}
			newName, shouldRename := paramRenames[id.Name]
			if !shouldRename {
				return true
			}
			idOffset := fset.Position(id.Pos()).Offset
			for _, sp := range replacedCallArgSpansInDecl {
				if idOffset >= sp.lo && idOffset < sp.hi {
					return true
				}
			}
			editsByPath[spec.Path] = append(editsByPath[spec.Path], SigTextEdit{
				Range:   lspRange(fset, declSrc, id.Pos(), id.End()),
				NewText: newName,
			})
			return true
		})
	}

	resp := ChangeSignatureResponse{
		EditsByPath: editsByPath,
	}
	b, err := json.Marshal(resp)
	if err != nil {
		return marshalError(err.Error())
	}
	return string(b)
}

func extractCalleeIdent(fun ast.Expr) *ast.Ident {
	switch e := fun.(type) {
	case *ast.Ident:
		return e
	case *ast.SelectorExpr:
		return e.Sel
	case *ast.IndexExpr:
		return extractCalleeIdent(e.X)
	case *ast.IndexListExpr:
		return extractCalleeIdent(e.X)
	default:
		return nil
	}
}

func collectSkippedIdents(root ast.Node) map[*ast.Ident]bool {
	skip := map[*ast.Ident]bool{}
	ast.Inspect(root, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.SelectorExpr:
			if x.Sel != nil {
				skip[x.Sel] = true
			}
		case *ast.LabeledStmt:
			if x.Label != nil {
				skip[x.Label] = true
			}
		case *ast.BranchStmt:
			if x.Label != nil {
				skip[x.Label] = true
			}
		case *ast.CompositeLit:
			switch x.Type.(type) {
			case *ast.MapType, *ast.ArrayType:
			default:
				for _, elt := range x.Elts {
					if kv, ok := elt.(*ast.KeyValueExpr); ok {
						if id, ok := kv.Key.(*ast.Ident); ok {
							skip[id] = true
						}
					}
				}
			}
		}
		return true
	})
	return skip
}

func renderArgExpr(fset *token.FileSet, src []byte, expr ast.Expr, applyRenames bool, renames map[string]string) string {
	start := fset.Position(expr.Pos()).Offset
	end := fset.Position(expr.End()).Offset
	if start < 0 || end < start || end > len(src) {
		return ""
	}
	if !applyRenames || len(renames) == 0 {
		return strings.TrimSpace(string(src[start:end]))
	}
	skip := collectSkippedIdents(expr)
	type repl struct {
		lo      int
		hi      int
		newText string
	}
	var repls []repl
	ast.Inspect(expr, func(n ast.Node) bool {
		id, ok := n.(*ast.Ident)
		if !ok || id == nil || skip[id] {
			return true
		}
		if newName, ok := renames[id.Name]; ok {
			lo := fset.Position(id.Pos()).Offset - start
			hi := fset.Position(id.End()).Offset - start
			if lo >= 0 && hi >= lo && hi <= end-start {
				repls = append(repls, repl{lo: lo, hi: hi, newText: newName})
			}
		}
		return true
	})
	raw := string(src[start:end])
	if len(repls) == 0 {
		return strings.TrimSpace(raw)
	}
	sort.Slice(repls, func(i, j int) bool { return repls[i].lo > repls[j].lo })
	for _, r := range repls {
		raw = raw[:r.lo] + r.newText + raw[r.hi:]
	}
	return strings.TrimSpace(raw)
}

func marshalError(msg string) string {
	b, _ := json.Marshal(ChangeSignatureResponse{
		EditsByPath: map[string][]SigTextEdit{},
		Error:       msg,
	})
	return string(b)
}
