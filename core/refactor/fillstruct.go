package refactor

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type FillStructResult struct {
	UpdatedSource   string   `json:"updatedSource"`
	StructName      string   `json:"structName"`
	AddedFieldCount int      `json:"addedFieldCount"`
	AddedFields     []string `json:"addedFields"`
	Error           string   `json:"error,omitempty"`
}

type structTypeDef struct {
	name       string
	pkgName    string
	filePath   string
	fset       *token.FileSet
	src        []byte
	structType *ast.StructType
	typeParams *ast.FieldList
	imports    map[string]string
	startLine  int
	endLine    int
	endOffset  int
}

type underlyingTypeDef struct {
	name       string
	pkgName    string
	fset       *token.FileSet
	src        []byte
	typeExpr   ast.Expr
	typeParams *ast.FieldList
	imports    map[string]string
}

type structFieldSpec struct {
	name     string
	typeExpr ast.Expr
	typeStr  string
	fset     *token.FileSet
	src      []byte
	imports  map[string]string
}

type fieldKeyValue struct {
	key string
	val string
}

type compositeLitCandidate struct {
	cl            *ast.CompositeLit
	structName    string
	structDef     *structTypeDef
	startPos      token.Position
	endPos        token.Position
	lbracePos     token.Position
	rbracePos     token.Position
	lastEltEndOff int
	existingPairs []fieldKeyValue
	addedPairs    []fieldKeyValue
	addedFields   []string
}

func marshalFillStructResult(res FillStructResult) string {
	if res.AddedFields == nil {
		res.AddedFields = []string{}
	}
	b, err := json.Marshal(res)
	if err != nil {
		return `{"updatedSource":"","structName":"","addedFieldCount":0,"addedFields":[],"error":"failed to marshal fill struct result"}`
	}
	return string(b)
}

func FillStructFields(dir string, filePath string, content string, line int, col int) (string, error) {
	cleanFile := ""
	if strings.TrimSpace(filePath) != "" {
		cleanFile = filepath.Clean(filePath)
	}
	cleanDir := ""
	if strings.TrimSpace(dir) != "" {
		cleanDir = filepath.Clean(dir)
	}
	if cleanDir == "" && cleanFile != "" {
		cleanDir = filepath.Dir(cleanFile)
	}

	if content == "" && cleanFile != "" {
		if data, err := readSourceFile(cleanFile); err == nil {
			content = string(data)
		}
	}
	if strings.TrimSpace(content) == "" {
		err := fmt.Errorf("empty Go source content")
		return marshalFillStructResult(FillStructResult{
			UpdatedSource: content,
			AddedFields:   []string{},
			Error:         err.Error(),
		}), err
	}

	if line <= 0 {
		line = 1
	}
	if col <= 0 {
		col = 1
	}

	srcBytes := []byte(content)
	targetFset := token.NewFileSet()
	parseFilename := cleanFile
	if parseFilename == "" {
		parseFilename = "input.go"
	}
	targetFile, err := parser.ParseFile(targetFset, parseFilename, srcBytes, parser.ParseComments)
	if err != nil || targetFile == nil {
		parseErr := fmt.Errorf("failed to parse Go source: %v", err)
		return marshalFillStructResult(FillStructResult{
			UpdatedSource: content,
			AddedFields:   []string{},
			Error:         parseErr.Error(),
		}), parseErr
	}

	targetPkgName := ""
	if targetFile.Name != nil {
		targetPkgName = targetFile.Name.Name
	}
	targetBasePkgName := strings.TrimSuffix(targetPkgName, "_test")
	targetImports := collectFileImportAliases(targetFile)

	structByName := map[string]*structTypeDef{}
	typeByName := map[string]*underlyingTypeDef{}
	var targetFileStructs []*structTypeDef

	indexASTTypes := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
		pkg := f.Name.Name
		if !isTarget {
			if targetBasePkgName != "" && pkg != targetBasePkgName && pkg != targetPkgName {
				return
			}
			if !buildTagsCompatible(srcBytes, src) {
				return
			}
		}
		fileImports := collectFileImportAliases(f)
		for _, decl := range f.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, spec := range gd.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil || ts.Name.Name == "" {
					continue
				}
				startLn := fset.Position(ts.Pos()).Line
				endLn := fset.Position(ts.End()).Line
				endOff := fset.Position(ts.End()).Offset
				if len(gd.Specs) == 1 {
					startLn = fset.Position(gd.Pos()).Line
					if gd.Doc != nil {
						startLn = fset.Position(gd.Doc.Pos()).Line
					}
					endLn = fset.Position(gd.End()).Line
					endOff = fset.Position(gd.End()).Offset
				}

				switch t := ts.Type.(type) {
				case *ast.StructType:
					def := &structTypeDef{
						name:       ts.Name.Name,
						pkgName:    pkg,
						filePath:   fp,
						fset:       fset,
						src:        src,
						structType: t,
						typeParams: ts.TypeParams,
						imports:    fileImports,
						startLine:  startLn,
						endLine:    endLn,
						endOffset:  endOff,
					}
					if isTarget {
						structByName[def.name] = def
						targetFileStructs = append(targetFileStructs, def)
					} else if _, exists := structByName[def.name]; !exists {
						structByName[def.name] = def
					}
					if pkg != "" {
						qual := pkg + "." + def.name
						if isTarget || structByName[qual] == nil {
							structByName[qual] = def
						}
					}
				default:
					ut := &underlyingTypeDef{
						name:       ts.Name.Name,
						pkgName:    pkg,
						fset:       fset,
						src:        src,
						typeExpr:   ts.Type,
						typeParams: ts.TypeParams,
						imports:    fileImports,
					}
					if isTarget || typeByName[ut.name] == nil {
						typeByName[ut.name] = ut
					}
					if pkg != "" {
						qual := pkg + "." + ut.name
						if isTarget || typeByName[qual] == nil {
							typeByName[qual] = ut
						}
					}
				}
			}
		}
	}

	indexASTTypes(targetFset, targetFile, srcBytes, cleanFile, true)

	var searchDirs []string
	if cleanFile != "" {
		fileDir := filepath.Dir(cleanFile)
		if info, statErr := os.Stat(fileDir); statErr == nil && info.IsDir() {
			searchDirs = append(searchDirs, fileDir)
		}
	}
	if cleanDir != "" {
		if info, statErr := os.Stat(cleanDir); statErr == nil && info.IsDir() {
			already := false
			for _, d := range searchDirs {
				if sameFilePath(d, cleanDir) {
					already = true
					break
				}
			}
			if !already {
				searchDirs = append(searchDirs, cleanDir)
			}
		}
	}

	seenFiles := map[string]bool{}
	if cleanFile != "" {
		if abs, absErr := filepath.Abs(cleanFile); absErr == nil {
			seenFiles[abs] = true
		}
		seenFiles[cleanFile] = true
	}

	for _, sdir := range searchDirs {
		goFiles := collectPackageGoFiles(sdir, "")
		for _, gf := range goFiles {
			if cleanFile != "" && sameFilePath(gf, cleanFile) {
				continue
			}
			if seenFiles[gf] {
				continue
			}
			seenFiles[gf] = true
			otherSrc, readErr := readSourceFile(gf)
			if readErr != nil || len(otherSrc) == 0 {
				continue
			}
			otherFset := token.NewFileSet()
			otherFile, parseErr := parser.ParseFile(otherFset, gf, otherSrc, parser.ParseComments)
			if parseErr != nil || otherFile == nil {
				continue
			}
			indexASTTypes(otherFset, otherFile, otherSrc, gf, false)
		}
	}

	var candidates []*compositeLitCandidate
	var walkAST func(node ast.Node, inherited *structTypeSpecInst, scopeTPs map[string]bool)
	walkAST = func(node ast.Node, inherited *structTypeSpecInst, scopeTPs map[string]bool) {
		if node == nil {
			return
		}
		if fn, ok := node.(*ast.FuncDecl); ok {
			nextScope := copyBoolMap(scopeTPs)
			if fn.Type != nil && fn.Type.TypeParams != nil {
				for _, f := range fn.Type.TypeParams.List {
					for _, id := range f.Names {
						if id != nil && id.Name != "" {
							nextScope[id.Name] = true
						}
					}
				}
			}
			if fn.Recv != nil && len(fn.Recv.List) > 0 {
				collectIndexTypeParamIdents(fn.Recv.List[0].Type, nextScope)
			}
			if fn.Body != nil {
				walkAST(fn.Body, nil, nextScope)
			}
			return
		}
		if cl, ok := node.(*ast.CompositeLit); ok {
			var resolved *structTypeSpecInst
			if cl.Type != nil {
				resolved = resolveStructTypeInst(cl.Type, targetFset, srcBytes, targetImports, structByName, typeByName)
			} else if inherited != nil {
				resolved = inherited
			}

			var childInherited *structTypeSpecInst
			if cl.Type != nil {
				childInherited = resolveElemStructTypeInst(cl.Type, targetFset, srcBytes, targetImports, structByName, typeByName)
			}

			if resolved != nil && resolved.def != nil && resolved.def.structType != nil {
				crossPkg := resolved.def.pkgName != "" && targetPkgName != "" && resolved.def.pkgName != targetPkgName
				if _, isSel := cl.Type.(*ast.SelectorExpr); isSel && targetPkgName == resolved.def.pkgName {
					crossPkg = false
				}
				existing, added, addedNames := computeCompositeLitFields(
					cl,
					targetFset,
					srcBytes,
					resolved,
					crossPkg,
					scopeTPs,
					targetImports,
					structByName,
					typeByName,
				)
				lastEltEnd := -1
				if len(cl.Elts) > 0 {
					lastEltEnd = targetFset.Position(cl.Elts[len(cl.Elts)-1].End()).Offset
				}
				candidates = append(candidates, &compositeLitCandidate{
					cl:            cl,
					structName:    resolved.def.name,
					structDef:     resolved.def,
					startPos:      targetFset.Position(cl.Pos()),
					endPos:        targetFset.Position(cl.End()),
					lbracePos:     targetFset.Position(cl.Lbrace),
					rbracePos:     targetFset.Position(cl.Rbrace),
					lastEltEndOff: lastEltEnd,
					existingPairs: existing,
					addedPairs:    added,
					addedFields:   addedNames,
				})
			}

			for _, elt := range cl.Elts {
				if kv, ok := elt.(*ast.KeyValueExpr); ok {
					walkAST(kv.Key, nil, scopeTPs)
					walkAST(kv.Value, childInherited, scopeTPs)
				} else {
					walkAST(elt, childInherited, scopeTPs)
				}
			}
			return
		}

		ast.Inspect(node, func(n ast.Node) bool {
			if n == nil || n == node {
				return true
			}
			switch sub := n.(type) {
			case *ast.FuncDecl:
				walkAST(sub, nil, scopeTPs)
				return false
			case *ast.CompositeLit:
				walkAST(sub, nil, scopeTPs)
				return false
			}
			return true
		})
	}
	walkAST(targetFile, nil, map[string]bool{})

	selected := selectCompositeLitCandidate(candidates, line, col)

	if selected == nil {
		for _, stDef := range targetFileStructs {
			if line >= stDef.startLine && line <= stDef.endLine {
				var bestSameStruct *compositeLitCandidate
				bestDist := int(^uint(0) >> 1)
				for _, cand := range candidates {
					if cand.structName == stDef.name {
						dist := absInt(cand.startPos.Line - line)
						if bestSameStruct == nil ||
							(len(cand.addedFields) > 0 && len(bestSameStruct.addedFields) == 0) ||
							((len(cand.addedFields) > 0) == (len(bestSameStruct.addedFields) > 0) && dist < bestDist) {
							bestSameStruct = cand
							bestDist = dist
						}
					}
				}
				if bestSameStruct != nil {
					selected = bestSameStruct
					break
				}
				return synthesizeStructLiteralAfterDecl(content, stDef, targetImports, structByName, typeByName)
			}
		}
	}

	if selected == nil && len(candidates) > 0 {
		var best *compositeLitCandidate
		bestDist := int(^uint(0) >> 1)
		for _, cand := range candidates {
			dist := absInt(cand.startPos.Line - line)
			if cand.endPos.Line < line {
				dist = line - cand.endPos.Line
			} else if cand.startPos.Line > line {
				dist = cand.startPos.Line - line
			} else {
				dist = 0
			}
			if dist <= 5 {
				if best == nil ||
					(len(cand.addedFields) > 0 && len(best.addedFields) == 0) ||
					((len(cand.addedFields) > 0) == (len(best.addedFields) > 0) && dist < bestDist) {
					best = cand
					bestDist = dist
				}
			}
		}
		selected = best
	}

	if selected == nil {
		noLitErr := fmt.Errorf("no struct composite literal found at line %d, column %d", line, col)
		return marshalFillStructResult(FillStructResult{
			UpdatedSource: content,
			AddedFields:   []string{},
			Error:         noLitErr.Error(),
		}), noLitErr
	}

	if len(selected.addedFields) == 0 {
		res := FillStructResult{
			UpdatedSource:   content,
			StructName:      selected.structName,
			AddedFieldCount: 0,
			AddedFields:     []string{},
		}
		return marshalFillStructResult(res), nil
	}

	updatedSource, spliceErr := spliceFilledCompositeLit(content, selected)
	if spliceErr != nil {
		return marshalFillStructResult(FillStructResult{
			UpdatedSource: content,
			StructName:    selected.structName,
			AddedFields:   []string{},
			Error:         spliceErr.Error(),
		}), spliceErr
	}

	res := FillStructResult{
		UpdatedSource:   updatedSource,
		StructName:      selected.structName,
		AddedFieldCount: len(selected.addedFields),
		AddedFields:     selected.addedFields,
	}
	return marshalFillStructResult(res), nil
}

type structTypeSpecInst struct {
	def   *structTypeDef
	subst map[string]string
}

func copyBoolMap(src map[string]bool) map[string]bool {
	out := make(map[string]bool, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func collectIndexTypeParamIdents(expr ast.Expr, out map[string]bool) {
	if expr == nil || out == nil {
		return
	}
	if star, ok := expr.(*ast.StarExpr); ok {
		expr = star.X
	}
	switch x := expr.(type) {
	case *ast.IndexExpr:
		if id, ok := x.Index.(*ast.Ident); ok && id.Name != "" {
			out[id.Name] = true
		}
	case *ast.IndexListExpr:
		for _, idx := range x.Indices {
			if id, ok := idx.(*ast.Ident); ok && id.Name != "" {
				out[id.Name] = true
			}
		}
	}
}

func buildTypeParamSubstFromArgs(
	tp *ast.FieldList,
	args []ast.Expr,
	fset *token.FileSet,
	src []byte,
	parentSubst map[string]string,
) map[string]string {
	if tp == nil || len(tp.List) == 0 {
		return parentSubst
	}
	var paramNames []string
	for _, f := range tp.List {
		for _, id := range f.Names {
			if id != nil && id.Name != "" {
				paramNames = append(paramNames, id.Name)
			}
		}
	}
	if len(paramNames) == 0 {
		return parentSubst
	}
	subst := map[string]string{}
	for k, v := range parentSubst {
		subst[k] = v
	}
	for i, name := range paramNames {
		if i < len(args) && args[i] != nil {
			argStr := strings.TrimSpace(astExprString(fset, src, args[i]))
			if argStr != "" {
				if len(parentSubst) > 0 {
					argStr = substituteTypeExprString(argStr, parentSubst)
				}
				subst[name] = argStr
			}
		}
	}
	return subst
}

func stripTypeArgExpr(expr ast.Expr) (ast.Expr, []ast.Expr) {
	switch t := expr.(type) {
	case *ast.IndexExpr:
		return t.X, []ast.Expr{t.Index}
	case *ast.IndexListExpr:
		return t.X, t.Indices
	default:
		return expr, nil
	}
}

func resolveStructTypeInst(
	expr ast.Expr,
	fset *token.FileSet,
	src []byte,
	fileImports map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
) *structTypeSpecInst {
	baseExpr, typeArgs := stripTypeArgExpr(expr)
	switch t := baseExpr.(type) {
	case *ast.Ident:
		if def, ok := structByName[t.Name]; ok {
			subst := buildTypeParamSubstFromArgs(def.typeParams, typeArgs, fset, src, nil)
			return &structTypeSpecInst{def: def, subst: subst}
		}
		if ut, ok := typeByName[t.Name]; ok && ut.typeExpr != nil {
			if sub := resolveStructTypeInst(ut.typeExpr, ut.fset, ut.src, ut.imports, structByName, typeByName); sub != nil {
				parentSubst := buildTypeParamSubstFromArgs(ut.typeParams, typeArgs, fset, src, nil)
				chainSubst := buildTypeParamSubstFromArgs(sub.def.typeParams, nil, sub.def.fset, sub.def.src, parentSubst)
				for k, v := range sub.subst {
					if len(parentSubst) > 0 {
						chainSubst[k] = substituteTypeExprString(v, parentSubst)
					} else {
						chainSubst[k] = v
					}
				}
				copied := *sub.def
				copied.name = t.Name
				copied.pkgName = ut.pkgName
				return &structTypeSpecInst{def: &copied, subst: chainSubst}
			}
		}
	case *ast.SelectorExpr:
		pkgIdent, _ := t.X.(*ast.Ident)
		if pkgIdent != nil && t.Sel != nil {
			qual := pkgIdent.Name + "." + t.Sel.Name
			if def, ok := structByName[qual]; ok {
				subst := buildTypeParamSubstFromArgs(def.typeParams, typeArgs, fset, src, nil)
				return &structTypeSpecInst{def: def, subst: subst}
			}
			if fileImports != nil {
				if impPath, ok := fileImports[pkgIdent.Name]; ok {
					pkgBase := defaultImportIdentifier(impPath)
					if def, ok := structByName[pkgBase+"."+t.Sel.Name]; ok {
						subst := buildTypeParamSubstFromArgs(def.typeParams, typeArgs, fset, src, nil)
						return &structTypeSpecInst{def: def, subst: subst}
					}
				}
			}
			if def, ok := structByName[t.Sel.Name]; ok {
				subst := buildTypeParamSubstFromArgs(def.typeParams, typeArgs, fset, src, nil)
				return &structTypeSpecInst{def: def, subst: subst}
			}
		}
	case *ast.StructType:
		return &structTypeSpecInst{
			def: &structTypeDef{
				name:       "struct",
				fset:       fset,
				src:        src,
				structType: t,
				imports:    fileImports,
			},
		}
	}
	return nil
}

func resolveElemStructTypeInst(
	expr ast.Expr,
	fset *token.FileSet,
	src []byte,
	fileImports map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
) *structTypeSpecInst {
	switch t := expr.(type) {
	case *ast.ArrayType:
		elt := t.Elt
		if star, ok := elt.(*ast.StarExpr); ok {
			elt = star.X
		}
		return resolveStructTypeInst(elt, fset, src, fileImports, structByName, typeByName)
	case *ast.MapType:
		val := t.Value
		if star, ok := val.(*ast.StarExpr); ok {
			val = star.X
		}
		return resolveStructTypeInst(val, fset, src, fileImports, structByName, typeByName)
	}
	return nil
}

func selectCompositeLitCandidate(candidates []*compositeLitCandidate, line int, col int) *compositeLitCandidate {
	var enclosing []*compositeLitCandidate
	for _, cand := range candidates {
		if line >= cand.startPos.Line && line <= cand.endPos.Line {
			enclosing = append(enclosing, cand)
		}
	}
	if len(enclosing) == 0 {
		return nil
	}
	if len(enclosing) == 1 {
		return enclosing[0]
	}

	containsCol := func(c *compositeLitCandidate) bool {
		if line > c.startPos.Line && line < c.endPos.Line {
			return true
		}
		if c.startPos.Line == c.endPos.Line {
			return col >= c.startPos.Column-1 && col <= c.endPos.Column+1
		}
		if line == c.startPos.Line {
			return col >= c.startPos.Column-1
		}
		if line == c.endPos.Line {
			return col <= c.endPos.Column+1
		}
		return false
	}

	colDist := func(c *compositeLitCandidate) int {
		if containsCol(c) {
			return 0
		}
		if c.startPos.Line == c.endPos.Line {
			if col < c.startPos.Column {
				return c.startPos.Column - col
			}
			if col > c.endPos.Column {
				return col - c.endPos.Column
			}
		}
		return 0
	}

	sort.SliceStable(enclosing, func(i, j int) bool {
		a, b := enclosing[i], enclosing[j]
		aHasMissing := len(a.addedFields) > 0
		bHasMissing := len(b.addedFields) > 0
		if aHasMissing != bHasMissing {
			return aHasMissing
		}
		aContains := containsCol(a)
		bContains := containsCol(b)
		if aContains != bContains {
			return aContains
		}
		aSpan := int(a.cl.End() - a.cl.Pos())
		bSpan := int(b.cl.End() - b.cl.Pos())
		if aContains && bContains && aSpan != bSpan {
			return aSpan < bSpan
		}
		aDist := colDist(a)
		bDist := colDist(b)
		if aDist != bDist {
			return aDist < bDist
		}
		return aSpan < bSpan
	})

	return enclosing[0]
}

func extractStructFields(def *structTypeDef) []structFieldSpec {
	if def == nil || def.structType == nil || def.structType.Fields == nil {
		return nil
	}
	var fields []structFieldSpec
	for _, field := range def.structType.Fields.List {
		if field == nil || field.Type == nil {
			continue
		}
		typeStr := strings.TrimSpace(astExprString(def.fset, def.src, field.Type))
		if len(field.Names) == 0 {
			embName := embeddedFieldName(field.Type)
			if embName == "" || embName == "_" {
				continue
			}
			fields = append(fields, structFieldSpec{
				name:     embName,
				typeExpr: field.Type,
				typeStr:  typeStr,
				fset:     def.fset,
				src:      def.src,
				imports:  def.imports,
			})
			continue
		}
		for _, ident := range field.Names {
			if ident == nil || ident.Name == "" || ident.Name == "_" {
				continue
			}
			fields = append(fields, structFieldSpec{
				name:     ident.Name,
				typeExpr: field.Type,
				typeStr:  typeStr,
				fset:     def.fset,
				src:      def.src,
				imports:  def.imports,
			})
		}
	}
	return fields
}

func embeddedFieldName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.SelectorExpr:
		if t.Sel != nil {
			return t.Sel.Name
		}
	case *ast.StarExpr:
		return embeddedFieldName(t.X)
	case *ast.IndexExpr:
		return embeddedFieldName(t.X)
	case *ast.IndexListExpr:
		return embeddedFieldName(t.X)
	}
	return ""
}

func computeCompositeLitFields(
	cl *ast.CompositeLit,
	targetFset *token.FileSet,
	targetSrc []byte,
	inst *structTypeSpecInst,
	crossPackage bool,
	scopeTypeParams map[string]bool,
	targetImports map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
) (existing []fieldKeyValue, added []fieldKeyValue, addedNames []string) {
	def := inst.def
	allFields := extractStructFields(def)
	present := map[string]bool{}

	for i, elt := range cl.Elts {
		if kv, ok := elt.(*ast.KeyValueExpr); ok {
			keyStr := strings.TrimSpace(astExprString(targetFset, targetSrc, kv.Key))
			valStr := strings.TrimSpace(astExprString(targetFset, targetSrc, kv.Value))
			if keyStr != "" {
				present[keyStr] = true
				existing = append(existing, fieldKeyValue{
					key: keyStr,
					val: valStr,
				})
			}
		} else {
			valStr := strings.TrimSpace(astExprString(targetFset, targetSrc, elt))
			if i < len(allFields) {
				fName := allFields[i].name
				present[fName] = true
				existing = append(existing, fieldKeyValue{
					key: fName,
					val: valStr,
				})
			}
		}
	}

	mergedImports := map[string]string{}
	for k, v := range def.imports {
		mergedImports[k] = v
	}
	for k, v := range targetImports {
		mergedImports[k] = v
	}

	for _, sf := range allFields {
		if crossPackage && !ast.IsExported(sf.name) {
			continue
		}
		if present[sf.name] {
			continue
		}
		zeroVal := zeroValueForStructFieldWithSubst(sf, inst.subst, scopeTypeParams, mergedImports, structByName, typeByName, map[string]bool{})
		added = append(added, fieldKeyValue{
			key: sf.name,
			val: zeroVal,
		})
		addedNames = append(addedNames, sf.name)
	}

	return existing, added, addedNames
}

func zeroValueForStructFieldWithSubst(
	sf structFieldSpec,
	subst map[string]string,
	unboundTypeParams map[string]bool,
	importAliases map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
	visited map[string]bool,
) string {
	expr := sf.typeExpr
	typeStr := sf.typeStr
	if len(subst) > 0 && strings.TrimSpace(typeStr) != "" {
		substituted := substituteTypeExprString(typeStr, subst)
		if substituted != "" && substituted != typeStr {
			typeStr = substituted
			if parsed, err := parser.ParseExpr(substituted); err == nil && parsed != nil {
				expr = parsed
			} else {
				expr = nil
			}
		}
	}
	return resolveZeroValue(expr, typeStr, sf.fset, sf.src, unboundTypeParams, importAliases, structByName, typeByName, visited)
}

func resolveZeroValue(
	expr ast.Expr,
	typeStr string,
	fset *token.FileSet,
	src []byte,
	unboundTypeParams map[string]bool,
	importAliases map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
	visited map[string]bool,
) string {
	trimmed := strings.TrimSpace(typeStr)
	if trimmed == "" && expr != nil {
		trimmed = strings.TrimSpace(astExprString(fset, src, expr))
	}

	switch t := expr.(type) {
	case *ast.StarExpr, *ast.MapType, *ast.ChanType, *ast.FuncType, *ast.InterfaceType:
		return "nil"
	case *ast.ArrayType:
		if t.Len == nil {
			return "nil"
		}
		return trimmed + "{}"
	case *ast.StructType:
		return trimmed + "{}"
	}

	if strings.HasPrefix(trimmed, "*") ||
		strings.HasPrefix(trimmed, "[]") ||
		strings.HasPrefix(trimmed, "map[") ||
		strings.HasPrefix(trimmed, "chan ") ||
		strings.HasPrefix(trimmed, "<-chan") ||
		strings.HasPrefix(trimmed, "chan<-") ||
		strings.HasPrefix(trimmed, "func(") ||
		strings.HasPrefix(trimmed, "interface{") {
		return "nil"
	}

	if unboundTypeParams != nil && unboundTypeParams[trimmed] {
		return fmt.Sprintf("*new(%s)", trimmed)
	}

	switch trimmed {
	case "string":
		return `""`
	case "bool":
		return "false"
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "float32", "float64", "complex64", "complex128",
		"time.Duration", "time.Month", "time.Weekday",
		"os.FileMode", "fs.FileMode",
		"syscall.Signal", "syscall.Errno",
		"sql.IsolationLevel", "slog.Level", "http.ConnState":
		return "0"
	case "error", "any", "interface{}",
		"context.Context", "context.CancelFunc", "context.CancelCauseFunc",
		"io.Reader", "io.Writer", "io.Closer",
		"io.ReadWriter", "io.ReadCloser", "io.WriteCloser", "io.ReadWriteCloser",
		"io.ReaderAt", "io.WriterAt", "io.Seeker", "io.ReadSeeker", "io.WriteSeeker", "io.ReadWriteSeeker",
		"fmt.Stringer", "http.Handler", "http.HandlerFunc", "http.ResponseWriter", "http.RoundTripper", "http.Header",
		"fs.FS", "fs.File", "fs.FileInfo", "fs.DirEntry",
		"os.FileInfo", "os.DirEntry", "os.Signal",
		"slog.Handler", "sql.Result":
		return "nil"
	}

	lookupKey := trimmed
	if idx := strings.IndexByte(trimmed, '['); idx > 0 {
		lookupKey = strings.TrimSpace(trimmed[:idx])
	}

	if structByName != nil {
		if _, ok := structByName[lookupKey]; ok {
			return trimmed + "{}"
		}
	}

	if typeByName != nil && !visited[lookupKey] {
		if ut, ok := typeByName[lookupKey]; ok && ut.typeExpr != nil {
			visited[lookupKey] = true
			utStr := strings.TrimSpace(astExprString(ut.fset, ut.src, ut.typeExpr))
			underZero := resolveZeroValue(ut.typeExpr, utStr, ut.fset, ut.src, unboundTypeParams, ut.imports, structByName, typeByName, visited)
			switch underZero {
			case `""`, "false", "0", "nil":
				return underZero
			default:
				return trimmed + "{}"
			}
		}
	}

	if z, ok := resolveImportedSelectorZeroValue(trimmed, importAliases); ok {
		return z
	}

	if strings.Contains(trimmed, ".") {
		return fmt.Sprintf("*new(%s)", trimmed)
	}

	return trimmed + "{}"
}

var stdlibShortPkgToImportPath = map[string]string{
	"atomic":    "sync/atomic",
	"base64":    "encoding/base64",
	"big":       "math/big",
	"binary":    "encoding/binary",
	"cipher":    "crypto/cipher",
	"color":     "image/color",
	"csv":       "encoding/csv",
	"driver":    "database/sql/driver",
	"exec":      "os/exec",
	"filepath":  "path/filepath",
	"fs":        "io/fs",
	"gob":       "encoding/gob",
	"gzip":      "compress/gzip",
	"hex":       "encoding/hex",
	"http":      "net/http",
	"httptest":  "net/http/httptest",
	"httptrace": "net/http/httptrace",
	"httputil":  "net/http/httputil",
	"json":      "encoding/json",
	"mail":      "net/mail",
	"multipart": "mime/multipart",
	"netip":     "net/netip",
	"pem":       "encoding/pem",
	"pprof":     "runtime/pprof",
	"rand":      "math/rand",
	"signal":    "os/signal",
	"slog":      "log/slog",
	"smtp":      "net/smtp",
	"sql":       "database/sql",
	"tabwriter": "text/tabwriter",
	"tar":       "archive/tar",
	"template":  "text/template",
	"tls":       "crypto/tls",
	"url":       "net/url",
	"user":      "os/user",
	"utf16":     "unicode/utf16",
	"utf8":      "unicode/utf8",
	"x509":      "crypto/x509",
	"xml":       "encoding/xml",
	"zip":       "archive/zip",
	"zlib":      "compress/zlib",
}

func resolveImportedSelectorZeroValue(trimmed string, importAliases map[string]string) (string, bool) {
	baseExpr := trimmed
	if idx := strings.IndexByte(trimmed, '['); idx > 0 {
		baseExpr = strings.TrimSpace(trimmed[:idx])
	}
	pkgName, typeName, ok := strings.Cut(baseExpr, ".")
	if !ok || pkgName == "" || typeName == "" || strings.Contains(typeName, ".") {
		return "", false
	}
	importPath := pkgName
	if importAliases != nil {
		if actual, exists := importAliases[pkgName]; exists {
			importPath = actual
		}
	}
	if importPath == pkgName {
		if mapped, exists := stdlibShortPkgToImportPath[pkgName]; exists {
			importPath = mapped
		}
	}
	imp := importer.Default()
	if imp == nil {
		return "", false
	}
	pkg, err := imp.Import(importPath)
	if err != nil || pkg == nil || pkg.Scope() == nil {
		return "", false
	}
	obj := pkg.Scope().Lookup(typeName)
	if obj == nil || obj.Type() == nil {
		return "", false
	}
	switch u := obj.Type().Underlying().(type) {
	case *types.Basic:
		info := u.Info()
		if info&types.IsBoolean != 0 {
			return "false", true
		}
		if info&types.IsString != 0 {
			return `""`, true
		}
		if info&(types.IsInteger|types.IsFloat|types.IsComplex) != 0 {
			return "0", true
		}
		if u.Kind() == types.UnsafePointer {
			return "nil", true
		}
	case *types.Interface, *types.Pointer, *types.Slice, *types.Map, *types.Chan, *types.Signature:
		return "nil", true
	case *types.Struct, *types.Array:
		return trimmed + "{}", true
	}
	return "", false
}

func spliceFilledCompositeLit(content string, cand *compositeLitCandidate) (string, error) {
	lbraceOff := cand.lbracePos.Offset
	rbraceOff := cand.rbracePos.Offset
	if lbraceOff < 0 || rbraceOff < lbraceOff || rbraceOff >= len(content) {
		return content, fmt.Errorf("invalid composite literal byte range")
	}

	isMultiLine := cand.lbracePos.Line < cand.rbracePos.Line
	hasPositional := false
	for _, elt := range cand.cl.Elts {
		if _, isKV := elt.(*ast.KeyValueExpr); !isKV {
			hasPositional = true
			break
		}
	}

	if isMultiLine && len(cand.existingPairs) > 0 && !hasPositional && cand.lastEltEndOff > lbraceOff && cand.lastEltEndOff <= rbraceOff {
		indent := lineIndentationAtOffset(content, lbraceOff)
		inner := content[lbraceOff+1 : rbraceOff]
		relLastElt := cand.lastEltEndOff - (lbraceOff + 1)

		hasTrailingComma := false
		for i := relLastElt; i < len(inner); i++ {
			ch := inner[i]
			if ch == ',' {
				hasTrailingComma = true
				break
			}
			if ch == '\n' {
				break
			}
		}
		if !hasTrailingComma {
			inner = inner[:relLastElt] + "," + inner[relLastElt:]
		}

		trimEnd := len(inner)
		for trimEnd > 0 && (inner[trimEnd-1] == ' ' || inner[trimEnd-1] == '\t') {
			trimEnd--
		}
		prefix := inner[:trimEnd]
		if len(prefix) > 0 && prefix[len(prefix)-1] != '\n' {
			prefix += "\n"
		}

		var addBuf strings.Builder
		for _, pair := range cand.addedPairs {
			addBuf.WriteString(indent)
			addBuf.WriteString("\t")
			addBuf.WriteString(pair.key)
			addBuf.WriteString(": ")
			addBuf.WriteString(pair.val)
			addBuf.WriteString(",\n")
		}
		replacement := "{" + prefix + addBuf.String() + indent + "}"
		return content[:lbraceOff] + replacement + content[rbraceOff+1:], nil
	}

	allPairs := make([]fieldKeyValue, 0, len(cand.existingPairs)+len(cand.addedPairs))
	allPairs = append(allPairs, cand.existingPairs...)
	allPairs = append(allPairs, cand.addedPairs...)

	var replacement string
	if isMultiLine {
		indent := lineIndentationAtOffset(content, lbraceOff)
		var sb strings.Builder
		sb.WriteString("{\n")
		for _, pair := range allPairs {
			sb.WriteString(indent)
			sb.WriteString("\t")
			sb.WriteString(pair.key)
			sb.WriteString(": ")
			sb.WriteString(pair.val)
			sb.WriteString(",\n")
		}
		sb.WriteString(indent)
		sb.WriteString("}")
		replacement = sb.String()
	} else {
		var parts []string
		for _, pair := range allPairs {
			parts = append(parts, fmt.Sprintf("%s: %s", pair.key, pair.val))
		}
		replacement = "{" + strings.Join(parts, ", ") + "}"
	}

	updated := content[:lbraceOff] + replacement + content[rbraceOff+1:]
	return updated, nil
}

func synthesizeStructLiteralAfterDecl(
	content string,
	stDef *structTypeDef,
	targetImports map[string]string,
	structByName map[string]*structTypeDef,
	typeByName map[string]*underlyingTypeDef,
) (string, error) {
	fields := extractStructFields(stDef)
	if len(fields) == 0 {
		res := FillStructResult{
			UpdatedSource:   content,
			StructName:      stDef.name,
			AddedFieldCount: 0,
			AddedFields:     []string{},
		}
		return marshalFillStructResult(res), nil
	}

	tpDecl, tpUse, tpNames, _ := extractTypeParamInfo(stDef.fset, stDef.src, stDef.typeParams)
	unboundTPs := map[string]bool{}
	for _, n := range tpNames {
		unboundTPs[n] = true
	}

	mergedImports := map[string]string{}
	for k, v := range stDef.imports {
		mergedImports[k] = v
	}
	for k, v := range targetImports {
		mergedImports[k] = v
	}

	var parts []string
	var addedNames []string
	for _, sf := range fields {
		zeroVal := zeroValueForStructFieldWithSubst(sf, nil, unboundTPs, mergedImports, structByName, typeByName, map[string]bool{})
		parts = append(parts, fmt.Sprintf("%s: %s", sf.name, zeroVal))
		addedNames = append(addedNames, sf.name)
	}

	insertOff := stDef.endOffset
	if insertOff < 0 || insertOff > len(content) {
		insertOff = len(content)
	}
	for insertOff < len(content) && content[insertOff] != '\n' {
		insertOff++
	}

	var snippet string
	if tpDecl != "" && tpUse != "" {
		snippet = fmt.Sprintf("\n\nfunc _%s() %s%s {\n\treturn %s%s{%s}\n}", tpDecl, stDef.name, tpUse, stDef.name, tpUse, strings.Join(parts, ", "))
	} else {
		snippet = fmt.Sprintf("\n\nvar _ = %s{%s}", stDef.name, strings.Join(parts, ", "))
	}
	updated := content[:insertOff] + snippet + content[insertOff:]

	res := FillStructResult{
		UpdatedSource:   updated,
		StructName:      stDef.name,
		AddedFieldCount: len(addedNames),
		AddedFields:     addedNames,
	}
	return marshalFillStructResult(res), nil
}

func lineIndentationAtOffset(content string, offset int) string {
	lineStart := offset
	for lineStart > 0 && content[lineStart-1] != '\n' {
		lineStart--
	}
	var indent strings.Builder
	for i := lineStart; i < len(content); i++ {
		ch := content[i]
		if ch == '\t' || ch == ' ' {
			indent.WriteByte(ch)
		} else {
			break
		}
	}
	return indent.String()
}
