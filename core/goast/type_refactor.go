package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

const (
	errPrefixTypeRefactorInvalidReq = "invalid request: "
)

type ExtractTypeRequest struct {
	WorkspacePath string `json:"workspacePath"`
	Path          string `json:"path"`
	Src           string `json:"src"`
	StartOffset   int    `json:"startOffset"`
	EndOffset     int    `json:"endOffset"`
	NewTypeName   string `json:"newTypeName"`
}

type ExtractTypeReply struct {
	DefaultTypeName    string                `json:"defaultTypeName"`
	ExtractedTypeExpr  string                `json:"extractedTypeExpr"`
	PreviewDeclaration string                `json:"previewDeclaration"`
	PreviewReplacement string                `json:"previewReplacement"`
	Edits              []TextEdit            `json:"edits,omitempty"`
	EditsByPath        map[string][]TextEdit `json:"editsByPath,omitempty"`
	PropagatedStructs  []string              `json:"propagatedStructs,omitempty"`
	Error              string                `json:"error,omitempty"`
}

func InspectExtractTypeJSON(reqJSON string) string {
	var req ExtractTypeRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractTypeReply{Error: errPrefixTypeRefactorInvalidReq + err.Error()})
		return string(b)
	}
	reply := InspectExtractType(req)
	b, _ := json.Marshal(reply)
	return string(b)
}

func ApplyExtractTypeJSON(reqJSON string) string {
	var req ExtractTypeRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractTypeReply{Error: errPrefixTypeRefactorInvalidReq + err.Error()})
		return string(b)
	}
	reply := ApplyExtractType(req)
	b, _ := json.Marshal(reply)
	return string(b)
}

func PropagateInterfaceMethodsJSON(reqJSON string) string {
	var req ExtractTypeRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractTypeReply{Error: errPrefixTypeRefactorInvalidReq + err.Error()})
		return string(b)
	}
	reply := PropagateInterfaceMethods(req)
	b, _ := json.Marshal(reply)
	return string(b)
}

func InspectExtractType(req ExtractTypeRequest) ExtractTypeReply {
	return runExtractType(req)
}

func ApplyExtractType(req ExtractTypeRequest) ExtractTypeReply {
	return runExtractType(req)
}

func runExtractType(req ExtractTypeRequest) ExtractTypeReply {
	src, fset, file, tf, errMsg := loadRefactorFile(req.Path, req.Src)
	if errMsg != "" {
		return ExtractTypeReply{Error: errMsg}
	}

	startOff := req.StartOffset
	if startOff < 0 {
		startOff = 0
	}
	if startOff > len(src) {
		startOff = len(src)
	}
	endOff := req.EndOffset
	if endOff < startOff {
		endOff = startOff
	}
	if endOff > len(src) {
		endOff = len(src)
	}

	trimStart, trimEnd := startOff, endOff
	for trimStart < trimEnd && (src[trimStart] == ' ' || src[trimStart] == '\t' || src[trimStart] == '\n' || src[trimStart] == '\r') {
		trimStart++
	}
	for trimEnd > trimStart && (src[trimEnd-1] == ' ' || src[trimEnd-1] == '\t' || src[trimEnd-1] == '\n' || src[trimEnd-1] == '\r') {
		trimEnd--
	}

	startPos := tf.Pos(trimStart)
	endPos := tf.Pos(trimEnd)
	cursorLine := fset.Position(tf.Pos(startOff)).Line

	targetExpr, contextName, previewNode := findExtractableTypeTarget(fset, file, startPos, endPos, cursorLine)
	if targetExpr == nil {
		return ExtractTypeReply{Error: "no extractable type expression found at selection"}
	}

	enclosingDecl := findEnclosingTopDecl(fset, file, targetExpr.Pos())
	if enclosingDecl == nil {
		return ExtractTypeReply{Error: "failed to locate enclosing top-level declaration"}
	}

	existingNames := collectTopLevelDeclNames(file)
	defaultName := suggestExtractedTypeName(contextName, existingNames)
	typeName := strings.TrimSpace(req.NewTypeName)
	if typeName == "" {
		typeName = defaultName
	}

	rawTypeExpr := exprString(fset, src, targetExpr)
	if rawTypeExpr == "" {
		return ExtractTypeReply{Error: "empty type expression"}
	}

	rawDecl := fmt.Sprintf("type %s %s", typeName, rawTypeExpr)
	formattedDecl, err := format.Source([]byte(rawDecl))
	if err != nil {
		formattedDecl = []byte(rawDecl)
	}
	previewDecl := strings.TrimSpace(string(formattedDecl))

	extractedExpr := strings.TrimSpace(strings.TrimPrefix(previewDecl, "type "+typeName))
	if extractedExpr == "" {
		extractedExpr = rawTypeExpr
	}

	previewReplacement := buildTypePreviewReplacement(fset, src, targetExpr, previewNode, typeName)

	insertPos := topDeclStartPos(enclosingDecl)
	insertOff := fset.Position(insertPos).Offset
	insertText := previewDecl + "\n\n"
	if insertOff > 0 && insertOff <= len(src) && src[insertOff-1] != '\n' {
		insertText = "\n" + previewDecl + "\n\n"
	}

	edits := []TextEdit{
		{
			Range:   lspRange(fset, src, insertPos, insertPos),
			NewText: insertText,
		},
		{
			Range:   lspRange(fset, src, targetExpr.Pos(), targetExpr.End()),
			NewText: typeName,
		},
	}

	editsByPath := map[string][]TextEdit{
		req.Path: edits,
	}

	return ExtractTypeReply{
		DefaultTypeName:    defaultName,
		ExtractedTypeExpr:  extractedExpr,
		PreviewDeclaration: previewDecl,
		PreviewReplacement: previewReplacement,
		Edits:              edits,
		EditsByPath:        editsByPath,
	}
}

func findExtractableTypeTarget(
	fset *token.FileSet,
	file *ast.File,
	startPos token.Pos,
	endPos token.Pos,
	cursorLine int,
) (ast.Expr, string, ast.Node) {
	excluded := map[ast.Expr]bool{}
	ast.Inspect(file, func(n ast.Node) bool {
		switch d := n.(type) {
		case *ast.TypeSpec:
			if d.Type != nil {
				excluded[d.Type] = true
			}
		case *ast.FuncDecl:
			if d.Type != nil {
				excluded[d.Type] = true
			}
		case *ast.InterfaceType:
			if d.Methods != nil {
				for _, m := range d.Methods.List {
					if len(m.Names) > 0 && m.Type != nil {
						excluded[m.Type] = true
					}
				}
			}
		}
		return true
	})

	var isExtractable func(e ast.Expr) bool
	isExtractable = func(e ast.Expr) bool {
		if e == nil || excluded[e] {
			return false
		}
		switch t := e.(type) {
		case *ast.StructType, *ast.MapType, *ast.ArrayType, *ast.FuncType, *ast.ChanType, *ast.InterfaceType:
			return true
		case *ast.StarExpr:
			return isExtractable(t.X)
		default:
			return false
		}
	}

	var targetExpr ast.Expr

	if startPos < endPos {
		var exactMatch ast.Expr
		var smallestContaining ast.Expr
		var largestContained ast.Expr

		ast.Inspect(file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.Field:
				if x.Pos() == startPos && x.End() == endPos && isExtractable(x.Type) {
					exactMatch = x.Type
					return false
				}
			case *ast.CompositeLit:
				if x.Pos() == startPos && x.End() == endPos && isExtractable(x.Type) {
					exactMatch = x.Type
					return false
				}
			}
			e, ok := n.(ast.Expr)
			if !ok || !isExtractable(e) {
				return true
			}
			if e.Pos() == startPos && e.End() == endPos {
				exactMatch = e
				return true
			}
			if e.Pos() <= startPos && e.End() >= endPos {
				if smallestContaining == nil || (e.End()-e.Pos()) <= (smallestContaining.End()-smallestContaining.Pos()) {
					smallestContaining = e
				}
			} else if e.Pos() >= startPos && e.End() <= endPos {
				if largestContained == nil || (e.End()-e.Pos()) > (largestContained.End()-largestContained.Pos()) {
					largestContained = e
				}
			}
			return true
		})

		if exactMatch != nil {
			targetExpr = exactMatch
		} else if smallestContaining != nil {
			targetExpr = smallestContaining
		} else if largestContained != nil {
			targetExpr = largestContained
		}
	}

	if targetExpr == nil {
		var smallestAtPos ast.Expr
		ast.Inspect(file, func(n ast.Node) bool {
			e, ok := n.(ast.Expr)
			if !ok || !isExtractable(e) {
				return true
			}
			if startPos >= e.Pos() && startPos <= e.End() {
				if smallestAtPos == nil || (e.End()-e.Pos()) <= (smallestAtPos.End()-smallestAtPos.Pos()) {
					smallestAtPos = e
				}
			}
			return true
		})
		targetExpr = smallestAtPos
	}

	if targetExpr == nil {
		var enclosingField *ast.Field
		var enclosingCompLit *ast.CompositeLit
		var enclosingValueSpec *ast.ValueSpec
		var enclosingAssign *ast.AssignStmt

		ast.Inspect(file, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if startPos < n.Pos() || startPos > n.End() {
				return false
			}
			switch x := n.(type) {
			case *ast.Field:
				if isExtractable(x.Type) {
					enclosingField = x
				}
			case *ast.CompositeLit:
				if isExtractable(x.Type) {
					enclosingCompLit = x
				}
			case *ast.ValueSpec:
				enclosingValueSpec = x
			case *ast.AssignStmt:
				enclosingAssign = x
			}
			return true
		})

		if enclosingField != nil {
			targetExpr = enclosingField.Type
		} else if enclosingCompLit != nil {
			targetExpr = enclosingCompLit.Type
		} else if enclosingValueSpec != nil {
			if isExtractable(enclosingValueSpec.Type) {
				targetExpr = enclosingValueSpec.Type
			} else {
				for _, val := range enclosingValueSpec.Values {
					if cl, ok := val.(*ast.CompositeLit); ok && isExtractable(cl.Type) {
						targetExpr = cl.Type
						break
					}
				}
			}
		} else if enclosingAssign != nil {
			for _, rhs := range enclosingAssign.Rhs {
				if cl, ok := rhs.(*ast.CompositeLit); ok && isExtractable(cl.Type) {
					targetExpr = cl.Type
					break
				}
			}
		}
	}

	if targetExpr == nil {
		ast.Inspect(file, func(n ast.Node) bool {
			if n == nil || targetExpr != nil {
				return false
			}
			sLine := fset.Position(n.Pos()).Line
			eLine := fset.Position(n.End()).Line
			if cursorLine < sLine || cursorLine > eLine {
				return true
			}
			switch x := n.(type) {
			case *ast.Field:
				if sLine == cursorLine && isExtractable(x.Type) {
					targetExpr = x.Type
					return false
				}
			case *ast.CompositeLit:
				if sLine == cursorLine && isExtractable(x.Type) {
					targetExpr = x.Type
					return false
				}
			case *ast.ValueSpec:
				if sLine == cursorLine && isExtractable(x.Type) {
					targetExpr = x.Type
					return false
				}
			}
			if e, ok := n.(ast.Expr); ok && sLine == cursorLine && isExtractable(e) {
				targetExpr = e
				return false
			}
			return true
		})
	}

	if targetExpr == nil {
		return nil, "", nil
	}

	contextName := ""
	var previewNode ast.Node

	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if targetExpr.Pos() < n.Pos() || targetExpr.End() > n.End() {
			return false
		}
		switch x := n.(type) {
		case *ast.Field:
			if len(x.Names) > 0 && x.Names[0] != nil && x.Names[0].Name != "" && x.Names[0].Name != "_" {
				contextName = x.Names[0].Name
			}
			previewNode = x
		case *ast.ValueSpec:
			if len(x.Names) > 0 && x.Names[0] != nil && x.Names[0].Name != "" && x.Names[0].Name != "_" {
				contextName = x.Names[0].Name
			}
			previewNode = x
		case *ast.AssignStmt:
			if len(x.Lhs) > 0 {
				if id, ok := x.Lhs[0].(*ast.Ident); ok && id.Name != "" && id.Name != "_" {
					contextName = id.Name
				}
			}
			previewNode = x
		case *ast.CompositeLit:
			if x.Type == targetExpr {
				previewNode = x
			}
		}
		return true
	})

	return targetExpr, contextName, previewNode
}

func findEnclosingTopDecl(fset *token.FileSet, file *ast.File, pos token.Pos) ast.Decl {
	targetLine := fset.Position(pos).Line
	for _, decl := range file.Decls {
		sPos := topDeclStartPos(decl)
		ePos := decl.End()
		if pos >= sPos && pos <= ePos {
			return decl
		}
		sLine := fset.Position(sPos).Line
		eLine := fset.Position(ePos).Line
		if targetLine >= sLine && targetLine <= eLine {
			return decl
		}
	}
	if len(file.Decls) > 0 {
		return file.Decls[len(file.Decls)-1]
	}
	return nil
}

func topDeclStartPos(decl ast.Decl) token.Pos {
	switch d := decl.(type) {
	case *ast.GenDecl:
		return declStartPos(d.Doc, d.Pos())
	case *ast.FuncDecl:
		return declStartPos(d.Doc, d.Pos())
	default:
		return decl.Pos()
	}
}

func suggestExtractedTypeName(contextName string, existing map[string]bool) string {
	base := "ExtractedType"
	pascal := toPascalCaseIdent(contextName)
	if pascal != "" {
		if strings.HasSuffix(pascal, "Type") {
			base = pascal
		} else {
			base = pascal + "Type"
		}
	}
	if !existing[base] {
		return base
	}
	for i := 2; i < 100; i++ {
		cand := fmt.Sprintf("%s%d", base, i)
		if !existing[cand] {
			return cand
		}
	}
	return base
}

func toPascalCaseIdent(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	var sb strings.Builder
	capNext := true
	for _, r := range trimmed {
		if r == '_' || r == '-' || r == ' ' {
			capNext = true
			continue
		}
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			continue
		}
		if sb.Len() == 0 && unicode.IsDigit(r) {
			sb.WriteRune('T')
		}
		if capNext {
			sb.WriteRune(unicode.ToUpper(r))
			capNext = false
		} else {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

func buildTypePreviewReplacement(
	fset *token.FileSet,
	src []byte,
	targetExpr ast.Expr,
	previewNode ast.Node,
	typeName string,
) string {
	tStart := fset.Position(targetExpr.Pos()).Offset
	tEnd := fset.Position(targetExpr.End()).Offset
	if tStart < 0 || tEnd < tStart || tEnd > len(src) {
		return typeName
	}
	if previewNode != nil {
		nStart := fset.Position(previewNode.Pos()).Offset
		nEnd := fset.Position(previewNode.End()).Offset
		if nStart >= 0 && nStart <= tStart && tEnd <= nEnd && nEnd <= len(src) {
			replaced := string(src[nStart:tStart]) + typeName + string(src[tEnd:nEnd])
			return strings.TrimSpace(replaced)
		}
	}
	return typeName
}

type ifaceMethodDetail struct {
	name      string
	sig       string
	returnStm string
}

type pkgStructRecord struct {
	name        string
	filePath    string
	fset        *token.FileSet
	src         []byte
	recvIdent   string
	recvPointer bool
	hasMethods  bool
}

func PropagateInterfaceMethods(req ExtractTypeRequest) ExtractTypeReply {
	src, fset, file, tf, errMsg := loadRefactorFile(req.Path, req.Src)
	if errMsg != "" {
		return ExtractTypeReply{Error: errMsg}
	}

	offset := req.StartOffset
	if offset < 0 {
		offset = 0
	}
	if offset > len(src) {
		offset = len(src)
	}
	pos := tf.Pos(offset)
	cursorLine := fset.Position(pos).Line

	targetIfaceSpec, targetIface := locateTargetInterface(fset, file, pos, cursorLine)
	if targetIfaceSpec == nil || targetIface == nil {
		return ExtractTypeReply{Error: "cursor is not inside an interface declaration"}
	}

	ifaceMethods := extractDetailedInterfaceMethods(fset, src, targetIface)
	if len(ifaceMethods) == 0 {
		return ExtractTypeReply{Error: fmt.Sprintf("interface %s has no methods to propagate", targetIfaceSpec.Name.Name)}
	}

	dir := filepath.Dir(req.Path)
	if (dir == "" || dir == ".") && strings.TrimSpace(req.WorkspacePath) != "" {
		dir = req.WorkspacePath
	}

	type parsedPkgFile struct {
		path string
		fset *token.FileSet
		src  []byte
		file *ast.File
	}

	var pkgFiles []parsedPkgFile
	seenPaths := map[string]bool{}
	cleanReqPath := filepath.Clean(req.Path)
	if req.Path != "" {
		seenPaths[cleanReqPath] = true
	}
	pkgFiles = append(pkgFiles, parsedPkgFile{
		path: req.Path,
		fset: fset,
		src:  src,
		file: file,
	})

	if dir != "" {
		if entries, err := os.ReadDir(dir); err == nil {
			var names []string
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				name := entry.Name()
				if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
					continue
				}
				names = append(names, name)
			}
			sort.Strings(names)
			for _, name := range names {
				fullPath := filepath.Clean(filepath.Join(dir, name))
				if seenPaths[fullPath] {
					continue
				}
				seenPaths[fullPath] = true
				pSrc, err := os.ReadFile(fullPath)
				if err != nil {
					continue
				}
				pFset := token.NewFileSet()
				pFile, _ := parser.ParseFile(pFset, fullPath, pSrc, parser.ParseComments)
				if pFile == nil || pFile.Name == nil || file.Name == nil || pFile.Name.Name != file.Name.Name {
					continue
				}
				pkgFiles = append(pkgFiles, parsedPkgFile{
					path: fullPath,
					fset: pFset,
					src:  pSrc,
					file: pFile,
				})
			}
		}
	}

	var structList []*pkgStructRecord
	structByName := map[string]*pkgStructRecord{}
	methodsByType := map[string]map[string]bool{}

	for _, pf := range pkgFiles {
		for _, decl := range pf.file.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, spec := range gd.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil || ts.Name.Name == "" {
					continue
				}
				if _, ok := ts.Type.(*ast.StructType); !ok {
					continue
				}
				sName := ts.Name.Name
				if _, exists := structByName[sName]; !exists {
					rec := &pkgStructRecord{
						name:        sName,
						filePath:    pf.path,
						fset:        pf.fset,
						src:         pf.src,
						recvIdent:   receiverIdentForType(sName),
						recvPointer: true,
					}
					structByName[sName] = rec
					structList = append(structList, rec)
				}
			}
		}
	}

	for _, pf := range pkgFiles {
		for _, decl := range pf.file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name == nil || fn.Recv == nil || len(fn.Recv.List) == 0 {
				continue
			}
			rf := fn.Recv.List[0]
			recvType := baseTypeName(rf.Type)
			if recvType == "" {
				continue
			}
			if methodsByType[recvType] == nil {
				methodsByType[recvType] = map[string]bool{}
			}
			methodsByType[recvType][fn.Name.Name] = true

			if rec, ok := structByName[recvType]; ok && !rec.hasMethods {
				rec.hasMethods = true
				_, isPtr := rf.Type.(*ast.StarExpr)
				rec.recvPointer = isPtr
				if len(rf.Names) > 0 && rf.Names[0] != nil && rf.Names[0].Name != "" && rf.Names[0].Name != "_" {
					rec.recvIdent = rf.Names[0].Name
				}
			}
		}
	}

	editsByPath := map[string][]TextEdit{}
	stubsByPath := map[string][]string{}
	fileMetaByPath := map[string]*pkgStructRecord{}
	var propagated []string

	for _, rec := range structList {
		existing := methodsByType[rec.name]
		matchedCount := 0
		var missing []ifaceMethodDetail
		for _, m := range ifaceMethods {
			if existing != nil && existing[m.name] {
				matchedCount++
			} else {
				missing = append(missing, m)
			}
		}
		if len(missing) == 0 {
			continue
		}
		if len(ifaceMethods) > 1 && matchedCount == 0 {
			continue
		}

		propagated = append(propagated, rec.name)
		fileMetaByPath[rec.filePath] = rec

		recvTypeExpr := rec.name
		if rec.recvPointer {
			recvTypeExpr = "*" + rec.name
		}
		for _, m := range missing {
			var body string
			if m.returnStm != "" {
				body = "\t" + m.returnStm + "\n"
			}
			stub := fmt.Sprintf("func (%s %s) %s {\n%s}", rec.recvIdent, recvTypeExpr, m.sig, body)
			formatted, err := format.Source([]byte(stub))
			if err == nil {
				stub = strings.TrimSpace(string(formatted))
			}
			stubsByPath[rec.filePath] = append(stubsByPath[rec.filePath], stub)
		}
	}

	for path, stubs := range stubsByPath {
		if len(stubs) == 0 {
			continue
		}
		meta := fileMetaByPath[path]
		combined := strings.Join(stubs, "\n\n")
		insertText := formatEOFInsertion(meta.src, combined)
		tfFile := meta.fset.File(token.Pos(1))
		var endPos token.Pos
		if tfFile != nil {
			endPos = tfFile.Pos(len(meta.src))
		}
		editsByPath[path] = []TextEdit{
			{
				Range:   lspRange(meta.fset, meta.src, endPos, endPos),
				NewText: insertText,
			},
		}
	}

	var previewBlocks []string
	seenPreviewFiles := map[string]bool{}
	for _, s := range propagated {
		if rec := structByName[s]; rec != nil && !seenPreviewFiles[rec.filePath] {
			seenPreviewFiles[rec.filePath] = true
			if stubs := stubsByPath[rec.filePath]; len(stubs) > 0 {
				previewBlocks = append(previewBlocks, strings.Join(stubs, "\n\n"))
			}
		}
	}

	reply := ExtractTypeReply{
		DefaultTypeName:    targetIfaceSpec.Name.Name,
		PreviewDeclaration: strings.Join(previewBlocks, "\n\n"),
		EditsByPath:        editsByPath,
		PropagatedStructs:  propagated,
	}
	if req.Path != "" {
		if e, ok := editsByPath[req.Path]; ok {
			reply.Edits = e
		}
	}
	return reply
}

func locateTargetInterface(
	fset *token.FileSet,
	file *ast.File,
	pos token.Pos,
	cursorLine int,
) (*ast.TypeSpec, *ast.InterfaceType) {
	var allSpecs []*ast.TypeSpec
	var allIfaces []*ast.InterfaceType

	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		dStart := declStartPos(gd.Doc, gd.Pos())
		dEnd := gd.End()
		for _, spec := range gd.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok || ts.Name == nil {
				continue
			}
			iface, ok := ts.Type.(*ast.InterfaceType)
			if !ok {
				continue
			}
			allSpecs = append(allSpecs, ts)
			allIfaces = append(allIfaces, iface)

			if (pos >= ts.Pos() && pos <= ts.End()) || (pos >= dStart && pos <= dEnd && len(gd.Specs) == 1) {
				return ts, iface
			}
			sLine := fset.Position(ts.Pos()).Line
			eLine := fset.Position(ts.End()).Line
			if cursorLine >= sLine && cursorLine <= eLine {
				return ts, iface
			}
		}
	}

	if len(allSpecs) == 1 {
		return allSpecs[0], allIfaces[0]
	}
	return nil, nil
}

func extractDetailedInterfaceMethods(
	fset *token.FileSet,
	src []byte,
	iface *ast.InterfaceType,
) []ifaceMethodDetail {
	if iface == nil || iface.Methods == nil {
		return nil
	}
	var out []ifaceMethodDetail
	for _, field := range iface.Methods.List {
		if len(field.Names) == 0 {
			continue
		}
		fnType, ok := field.Type.(*ast.FuncType)
		if !ok || fnType.Params == nil {
			continue
		}
		startOff := fset.Position(fnType.Params.Pos()).Offset
		endOff := fset.Position(fnType.End()).Offset
		if startOff < 0 || endOff < startOff || endOff > len(src) {
			continue
		}
		sigRest := strings.TrimSpace(string(src[startOff:endOff]))
		retStmt := buildZeroValueReturnStmt(fset, src, fnType.Results)
		for _, id := range field.Names {
			if id == nil || id.Name == "" {
				continue
			}
			out = append(out, ifaceMethodDetail{
				name:      id.Name,
				sig:       id.Name + sigRest,
				returnStm: retStmt,
			})
		}
	}
	return out
}

func buildZeroValueReturnStmt(fset *token.FileSet, src []byte, results *ast.FieldList) string {
	if results == nil || len(results.List) == 0 {
		return ""
	}
	hasNamed := false
	for _, f := range results.List {
		if len(f.Names) > 0 {
			hasNamed = true
			break
		}
	}
	if hasNamed {
		return "return"
	}
	types := extractResultTypes(fset, src, results)
	if len(types) == 0 {
		return ""
	}
	vals := make([]string, len(types))
	for i, t := range types {
		vals[i] = zeroValueExprForType(t)
	}
	return "return " + strings.Join(vals, ", ")
}

func zeroValueExprForType(typ string) string {
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
	case "error", "any", "interface{}":
		return "nil"
	}
	if strings.HasPrefix(t, "[]") ||
		strings.HasPrefix(t, "*") ||
		strings.HasPrefix(t, "map[") ||
		strings.HasPrefix(t, "chan ") ||
		strings.HasPrefix(t, "<-chan ") ||
		strings.HasPrefix(t, "chan<- ") ||
		strings.HasPrefix(t, "func(") ||
		strings.HasPrefix(t, "interface{") {
		return "nil"
	}
	return fmt.Sprintf("*new(%s)", t)
}

func formatEOFInsertion(src []byte, block string) string {
	trimmed := strings.TrimSpace(block)
	s := string(src)
	if strings.HasSuffix(s, "\n\n") {
		return trimmed + "\n"
	}
	if strings.HasSuffix(s, "\n") {
		return "\n" + trimmed + "\n"
	}
	return "\n\n" + trimmed + "\n"
}
