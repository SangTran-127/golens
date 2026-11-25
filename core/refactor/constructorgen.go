package refactor

import (
	"bytes"
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
	"unicode/utf8"
)

type ConstructorFieldItem struct {
	FieldName      string `json:"fieldName"`
	ParamName      string `json:"paramName"`
	FieldType      string `json:"fieldType"`
	OptionFuncName string `json:"optionFuncName"`
	IsMap          bool   `json:"isMap,omitempty"`
}

type ConstructorPlan struct {
	PackageName      string                 `json:"packageName"`
	TargetStruct     string                 `json:"targetStruct"`
	AvailableStructs []string               `json:"availableStructs"`
	ConstructorName  string                 `json:"constructorName"`
	IncludeOptions   bool                   `json:"includeOptions"`
	ReturnPointer    bool                   `json:"returnPointer"`
	Fields           []ConstructorFieldItem `json:"fields"`
	PreviewCode      string                 `json:"previewCode"`
	NewContent       string                 `json:"newContent"`
	TargetFile       string                 `json:"targetFile"`
	Error            string                 `json:"error,omitempty"`
}

type parsedConstructorStructInfo struct {
	name           string
	pkgName        string
	filePath       string
	fset           *token.FileSet
	file           *ast.File
	src            []byte
	structType     *ast.StructType
	typeParamsDecl string
	typeParamsUse  string
	typeParamNames []string
	startLine      int
	endLine        int
	declEndOff     int
	isTarget       bool
}

func InspectStructConstructor(
	dir, filePath, content string,
	line, _ int,
	structName string,
	includeOptions, returnPointer bool,
) (ConstructorPlan, error) {
	plan := ConstructorPlan{
		AvailableStructs: []string{},
		IncludeOptions:   includeOptions,
		ReturnPointer:    returnPointer,
		Fields:           []ConstructorFieldItem{},
	}

	cleanFile := ""
	if strings.TrimSpace(filePath) != "" {
		cleanFile = filepath.Clean(filePath)
	}
	cleanDir := ""
	if strings.TrimSpace(dir) != "" {
		cleanDir = filepath.Clean(dir)
	}
	if cleanDir == "" && cleanFile != "" {
		fdir := filepath.Dir(cleanFile)
		if fdir != "." {
			cleanDir = fdir
		} else if _, statErr := os.Stat(cleanFile); statErr == nil {
			cleanDir = fdir
		}
	}

	if content == "" && cleanFile != "" {
		if data, err := readSourceFile(cleanFile); err == nil {
			content = string(data)
		}
	}

	var allStructs []*parsedConstructorStructInfo
	structByName := map[string]*parsedConstructorStructInfo{}
	var availableNames []string
	var defaultPkgName string
	var targetRecvStructName string
	var targetFileSrc []byte
	if strings.TrimSpace(content) != "" {
		targetFileSrc = []byte(content)
	}

	collectFromAST := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
		pkg := f.Name.Name
		if isTarget {
			defaultPkgName = pkg
			if len(targetFileSrc) == 0 {
				targetFileSrc = src
			}
		} else if defaultPkgName == "" {
			defaultPkgName = pkg
		} else if pkg != defaultPkgName && strings.TrimSuffix(pkg, "_test") != strings.TrimSuffix(defaultPkgName, "_test") {
			return
		}
		if !isTarget && !buildTagsCompatible(targetFileSrc, src) {
			return
		}
		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if d.Tok != token.TYPE {
					continue
				}
				declEnd := fset.Position(d.End()).Offset
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || ts.Name == nil || ts.Name.Name == "" {
						continue
					}
					st, ok := ts.Type.(*ast.StructType)
					if !ok {
						continue
					}
					tpDecl, tpUse, tpNames, _ := extractTypeParamInfo(fset, src, ts.TypeParams)
					startLn := fset.Position(ts.Pos()).Line
					endLn := fset.Position(ts.End()).Line
					if len(d.Specs) == 1 {
						startLn = fset.Position(d.Pos()).Line
						if d.Doc != nil {
							startLn = fset.Position(d.Doc.Pos()).Line
						}
						endLn = fset.Position(d.End()).Line
					}
					info := &parsedConstructorStructInfo{
						name:           ts.Name.Name,
						pkgName:        pkg,
						filePath:       fp,
						fset:           fset,
						file:           f,
						src:            src,
						structType:     st,
						typeParamsDecl: tpDecl,
						typeParamsUse:  tpUse,
						typeParamNames: tpNames,
						startLine:      startLn,
						endLine:        endLn,
						declEndOff:     declEnd,
						isTarget:       isTarget,
					}
					allStructs = append(allStructs, info)
					if _, exists := structByName[info.name]; !exists {
						structByName[info.name] = info
						availableNames = append(availableNames, info.name)
					} else if isTarget && !structByName[info.name].isTarget {
						structByName[info.name] = info
					}
				}
			case *ast.FuncDecl:
				if isTarget && line > 0 && d.Recv != nil && len(d.Recv.List) > 0 {
					fnStart := fset.Position(d.Pos()).Line
					fnEnd := fset.Position(d.End()).Line
					if line >= fnStart && line <= fnEnd {
						recvName := extractReceiverTypeName(d.Recv.List[0].Type)
						if recvName != "" {
							targetRecvStructName = recvName
						}
					}
				}
			}
		}
	}

	if strings.TrimSpace(content) != "" {
		srcBytes := []byte(content)
		fset := token.NewFileSet()
		parseName := cleanFile
		if parseName == "" {
			parseName = "input.go"
		}
		f, err := parser.ParseFile(fset, parseName, srcBytes, parser.ParseComments)
		if err != nil && f == nil {
			plan.Error = fmt.Sprintf("failed to parse Go source: %v", err)
			return plan, err
		}
		collectFromAST(fset, f, srcBytes, cleanFile, true)
	}

	var searchDirs []string
	if cleanFile != "" {
		fileDir := filepath.Dir(cleanFile)
		if info, err := os.Stat(fileDir); err == nil && info.IsDir() {
			searchDirs = append(searchDirs, fileDir)
		}
	}
	if cleanDir != "" {
		if info, err := os.Stat(cleanDir); err == nil && info.IsDir() {
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
	if cleanFile != "" && strings.TrimSpace(content) != "" {
		if abs, err := filepath.Abs(cleanFile); err == nil {
			seenFiles[abs] = true
		}
		seenFiles[cleanFile] = true
	}

	for _, sdir := range searchDirs {
		goFiles := collectPackageGoFiles(sdir, cleanFile)
		for _, gf := range goFiles {
			if cleanFile != "" && strings.TrimSpace(content) != "" && sameFilePath(gf, cleanFile) {
				continue
			}
			if seenFiles[gf] {
				continue
			}
			seenFiles[gf] = true
			otherSrc, err := readSourceFile(gf)
			if err != nil || len(otherSrc) == 0 {
				continue
			}
			otherFset := token.NewFileSet()
			otherFile, err := parser.ParseFile(otherFset, gf, otherSrc, parser.ParseComments)
			if err != nil || otherFile == nil {
				continue
			}
			isTarget := cleanFile != "" && sameFilePath(gf, cleanFile)
			collectFromAST(otherFset, otherFile, otherSrc, gf, isTarget)
		}
	}

	if availableNames != nil {
		plan.AvailableStructs = availableNames
	}

	if len(allStructs) == 0 {
		err := fmt.Errorf("no struct types found in file or package")
		plan.Error = err.Error()
		return plan, err
	}

	var selected *parsedConstructorStructInfo
	reqStruct := strings.TrimSpace(structName)
	if reqStruct != "" {
		if match, ok := structByName[reqStruct]; ok {
			selected = match
		} else {
			for _, cand := range allStructs {
				if strings.EqualFold(cand.name, reqStruct) {
					selected = cand
					break
				}
			}
			if selected == nil {
				err := fmt.Errorf("struct %q not found in package", reqStruct)
				plan.Error = err.Error()
				return plan, err
			}
		}
	}

	if selected == nil && line > 0 {
		for _, cand := range allStructs {
			if cand.isTarget && line >= cand.startLine && line <= cand.endLine {
				selected = cand
				break
			}
		}
	}

	if selected == nil && targetRecvStructName != "" {
		if match, ok := structByName[targetRecvStructName]; ok {
			selected = match
		}
	}

	if selected == nil {
		for _, cand := range allStructs {
			if cand.isTarget {
				selected = cand
				break
			}
		}
	}

	if selected == nil {
		selected = allStructs[0]
	}

	pkgName := selected.pkgName
	if pkgName == "" {
		pkgName = defaultPkgName
	}

	constructorName := "New" + selected.name
	fields := extractConstructorFields(selected)
	existingDefaults := extractExistingConstructorDefaults(selected, constructorName)
	previewCode := buildStructConstructorSnippet(selected, constructorName, fields, includeOptions, returnPointer, existingDefaults)
	newContent := buildUpdatedFileWithConstructor(selected, constructorName, includeOptions, fields, previewCode)

	targetFile := selected.filePath
	if targetFile == "" {
		targetFile = cleanFile
	}

	plan.PackageName = pkgName
	plan.TargetStruct = selected.name
	plan.ConstructorName = constructorName
	plan.Fields = fields
	plan.PreviewCode = previewCode
	plan.NewContent = newContent
	plan.TargetFile = targetFile
	return plan, nil
}

func embeddedConstructorFieldName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.SelectorExpr:
		if t.Sel != nil {
			return t.Sel.Name
		}
	case *ast.StarExpr:
		return embeddedConstructorFieldName(t.X)
	case *ast.IndexExpr:
		return embeddedConstructorFieldName(t.X)
	case *ast.IndexListExpr:
		return embeddedConstructorFieldName(t.X)
	case *ast.ParenExpr:
		return embeddedConstructorFieldName(t.X)
	}
	return ""
}

func extractConstructorFields(selected *parsedConstructorStructInfo) []ConstructorFieldItem {
	if selected == nil || selected.structType == nil || selected.structType.Fields == nil {
		return []ConstructorFieldItem{}
	}

	usedParams := map[string]bool{
		selected.name: true,
		"opts":        true,
		"opt":         true,
		"cfg":         true,
		"make":        true,
		"new":         true,
	}
	addReservedPredeclaredTypes(usedParams)
	addReservedFileImports(usedParams, selected.file)
	for _, tp := range selected.typeParamNames {
		usedParams[tp] = true
	}

	usedOptions := map[string]bool{}
	var fields []ConstructorFieldItem

	for _, field := range selected.structType.Fields.List {
		if field == nil || field.Type == nil {
			continue
		}
		rawType := strings.TrimSpace(astExprString(selected.fset, selected.src, field.Type))
		if rawType == "" || isSyncLockFieldType(rawType) {
			continue
		}
		_, isASTMap := field.Type.(*ast.MapType)
		isMap := isASTMap || strings.HasPrefix(rawType, "map[")

		if len(field.Names) == 0 {
			fName := embeddedConstructorFieldName(field.Type)
			if fName == "" || fName == "_" {
				continue
			}
			pName := constructorParamName(fName, usedParams)
			optName := constructorOptionFuncName(fName, usedOptions)
			fields = append(fields, ConstructorFieldItem{
				FieldName:      fName,
				ParamName:      pName,
				FieldType:      rawType,
				OptionFuncName: optName,
				IsMap:          isMap,
			})
			continue
		}

		for _, ident := range field.Names {
			if ident == nil || ident.Name == "" || ident.Name == "_" {
				continue
			}
			fName := ident.Name
			pName := constructorParamName(fName, usedParams)
			optName := constructorOptionFuncName(fName, usedOptions)
			fields = append(fields, ConstructorFieldItem{
				FieldName:      fName,
				ParamName:      pName,
				FieldType:      rawType,
				OptionFuncName: optName,
				IsMap:          isMap,
			})
		}
	}

	if fields == nil {
		return []ConstructorFieldItem{}
	}
	return fields
}

func isSyncLockFieldType(rawType string) bool {
	switch rawType {
	case "sync.Mutex", "sync.RWMutex", "sync.WaitGroup", "sync.Once",
		"sync.Cond", "sync.Map", "sync.Pool",
		"Mutex", "RWMutex", "WaitGroup", "Once", "Cond", "Pool":
		return true
	default:
		if strings.HasPrefix(rawType, "atomic.") || strings.HasPrefix(rawType, "sync/atomic.") {
			return true
		}
		return false
	}
}

func constructorParamName(fieldName string, used map[string]bool) string {
	if fieldName == "" {
		return "v"
	}
	allUpper := true
	for _, r := range fieldName {
		if unicode.IsLetter(r) && !unicode.IsUpper(r) {
			allUpper = false
			break
		}
	}
	var param string
	if allUpper {
		param = strings.ToLower(fieldName)
	} else {
		runes := []rune(fieldName)
		upperPrefix := 0
		for upperPrefix < len(runes) && unicode.IsUpper(runes[upperPrefix]) {
			upperPrefix++
		}
		if upperPrefix > 1 {
			param = strings.ToLower(string(runes[:upperPrefix-1])) + string(runes[upperPrefix-1:])
		} else {
			param = string(unicode.ToLower(runes[0])) + string(runes[1:])
		}
	}
	if token.Lookup(param).IsKeyword() {
		param += "Val"
	}
	base := param
	for idx := 2; used[param]; idx++ {
		param = fmt.Sprintf("%s%d", base, idx)
	}
	used[param] = true
	return param
}

func constructorOptionFuncName(fieldName string, used map[string]bool) string {
	suffix := exportedConstructorFieldSuffix(fieldName)
	name := "With" + suffix
	base := name
	for idx := 2; used[name]; idx++ {
		name = fmt.Sprintf("%s%d", base, idx)
	}
	used[name] = true
	return name
}

func exportedConstructorFieldSuffix(fieldName string) string {
	switch strings.ToLower(fieldName) {
	case "id":
		return "ID"
	case "url":
		return "URL"
	case "uri":
		return "URI"
	}
	if strings.Contains(fieldName, "_") {
		parts := strings.Split(fieldName, "_")
		var b strings.Builder
		for _, p := range parts {
			if p == "" {
				continue
			}
			r, size := utf8.DecodeRuneInString(p)
			b.WriteRune(unicode.ToUpper(r))
			b.WriteString(p[size:])
		}
		if b.Len() > 0 {
			return b.String()
		}
	}
	r, size := utf8.DecodeRuneInString(fieldName)
	if r == utf8.RuneError {
		return fieldName
	}
	return string(unicode.ToUpper(r)) + fieldName[size:]
}

func extractExistingConstructorDefaults(selected *parsedConstructorStructInfo, constructorName string) map[string]string {
	defaults := map[string]string{}
	if selected == nil || selected.file == nil || selected.fset == nil {
		return defaults
	}

	var existingFunc *ast.FuncDecl
	for _, decl := range selected.file.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if ok && fd.Recv == nil && fd.Name != nil && fd.Name.Name == constructorName {
			existingFunc = fd
			break
		}
	}
	if existingFunc == nil || existingFunc.Body == nil {
		return defaults
	}

	paramNames := map[string]bool{}
	if existingFunc.Type != nil && existingFunc.Type.Params != nil {
		for _, field := range existingFunc.Type.Params.List {
			for _, ident := range field.Names {
				if ident != nil && ident.Name != "" {
					paramNames[ident.Name] = true
				}
			}
		}
	}

	ast.Inspect(existingFunc.Body, func(n ast.Node) bool {
		comp, ok := n.(*ast.CompositeLit)
		if !ok {
			return true
		}
		if comp.Type != nil {
			typeName := embeddedConstructorFieldName(comp.Type)
			if typeName == "" {
				typeName = strings.TrimPrefix(strings.TrimSpace(astExprString(selected.fset, selected.src, comp.Type)), "*")
			}
			if typeName != selected.name {
				return true
			}
		}
		for _, elt := range comp.Elts {
			kv, ok := elt.(*ast.KeyValueExpr)
			if !ok {
				continue
			}
			keyIdent, ok := kv.Key.(*ast.Ident)
			if !ok || keyIdent.Name == "" {
				continue
			}
			if valIdent, isIdent := kv.Value.(*ast.Ident); isIdent && paramNames[valIdent.Name] {
				continue
			}
			valStr := strings.TrimSpace(astExprString(selected.fset, selected.src, kv.Value))
			if valStr != "" {
				defaults[keyIdent.Name] = valStr
			}
		}
		return true
	})

	return defaults
}

func pickSafeConstructorLocal(base string, blocked map[string]bool) string {
	cand := base
	for suffix := 2; blocked[cand]; suffix++ {
		cand = fmt.Sprintf("%s%d", base, suffix)
	}
	blocked[cand] = true
	return cand
}

func buildStructConstructorSnippet(
	selected *parsedConstructorStructInfo,
	constructorName string,
	fields []ConstructorFieldItem,
	includeOptions, returnPointer bool,
	existingDefaults map[string]string,
) string {
	structName := selected.name
	tpDecl := selected.typeParamsDecl
	tpUse := selected.typeParamsUse
	instStruct := structName + tpUse

	returnType := instStruct
	if returnPointer {
		returnType = "*" + instStruct
	}

	if !includeOptions {
		var params []string
		var inits []string
		for _, f := range fields {
			if f.ParamName != "" {
				params = append(params, fmt.Sprintf("%s %s", f.ParamName, f.FieldType))
				inits = append(inits, fmt.Sprintf("\t\t%s: %s,", f.FieldName, f.ParamName))
			} else if f.IsMap {
				inits = append(inits, fmt.Sprintf("\t\t%s: make(%s),", f.FieldName, f.FieldType))
			}
		}

		prefix := ""
		if returnPointer {
			prefix = "&"
		}

		var raw string
		if len(inits) == 0 {
			raw = fmt.Sprintf("func %s%s(%s) %s {\n\treturn %s%s{}\n}",
				constructorName,
				tpDecl,
				strings.Join(params, ", "),
				returnType,
				prefix,
				instStruct,
			)
		} else {
			raw = fmt.Sprintf("func %s%s(%s) %s {\n\treturn %s%s{\n%s\n\t}\n}",
				constructorName,
				tpDecl,
				strings.Join(params, ", "),
				returnType,
				prefix,
				instStruct,
				strings.Join(inits, "\n"),
			)
		}

		if formatted, err := format.Source([]byte(raw)); err == nil {
			return strings.TrimSpace(string(formatted))
		}
		return raw
	}

	optionBaseName := structName + "Option"
	optionInstName := optionBaseName + tpUse
	blockedTypeNames := map[string]bool{structName: true}
	for _, tp := range selected.typeParamNames {
		blockedTypeNames[tp] = true
	}

	var buf bytes.Buffer
	_, _ = fmt.Fprintf(&buf, "type %s%s func(*%s)\n\n", optionBaseName, tpDecl, instStruct)

	for _, f := range fields {
		closureBlocked := map[string]bool{
			f.ParamName: true,
			structName:  true,
		}
		for tp := range blockedTypeNames {
			closureBlocked[tp] = true
		}
		recvVar := "cfg"
		if closureBlocked[recvVar] {
			recvVar = "s"
			if closureBlocked[recvVar] {
				recvVar = pickSafeConstructorLocal("cfg", closureBlocked)
			}
		}
		_, _ = fmt.Fprintf(&buf, "func %s%s(%s %s) %s {\n", f.OptionFuncName, tpDecl, f.ParamName, f.FieldType, optionInstName)
		_, _ = fmt.Fprintf(&buf, "\treturn func(%s *%s) {\n", recvVar, instStruct)
		_, _ = fmt.Fprintf(&buf, "\t\t%s.%s = %s\n", recvVar, f.FieldName, f.ParamName)
		_, _ = fmt.Fprintf(&buf, "\t}\n")
		_, _ = fmt.Fprintf(&buf, "}\n\n")
	}

	var defaultInits []string
	for _, f := range fields {
		if existingDefaults != nil {
			if defVal, ok := existingDefaults[f.FieldName]; ok && defVal != "" {
				defaultInits = append(defaultInits, fmt.Sprintf("\t\t%s: %s,", f.FieldName, defVal))
				continue
			}
		}
		if f.IsMap {
			defaultInits = append(defaultInits, fmt.Sprintf("\t\t%s: make(%s),", f.FieldName, f.FieldType))
		}
	}

	ctorBlocked := map[string]bool{}
	for k := range blockedTypeNames {
		ctorBlocked[k] = true
	}
	optsVar := pickSafeConstructorLocal("opts", ctorBlocked)
	cfgVar := pickSafeConstructorLocal("cfg", ctorBlocked)
	optVar := pickSafeConstructorLocal("opt", ctorBlocked)

	_, _ = fmt.Fprintf(&buf, "func %s%s(%s ...%s) %s {\n", constructorName, tpDecl, optsVar, optionInstName, returnType)
	if len(defaultInits) == 0 {
		_, _ = fmt.Fprintf(&buf, "\t%s := &%s{}\n", cfgVar, instStruct)
	} else {
		_, _ = fmt.Fprintf(&buf, "\t%s := &%s{\n%s\n\t}\n", cfgVar, instStruct, strings.Join(defaultInits, "\n"))
	}
	_, _ = fmt.Fprintf(&buf, "\tfor _, %s := range %s {\n", optVar, optsVar)
	_, _ = fmt.Fprintf(&buf, "\t\tif %s != nil {\n", optVar)
	_, _ = fmt.Fprintf(&buf, "\t\t\t%s(%s)\n", optVar, cfgVar)
	_, _ = fmt.Fprintf(&buf, "\t\t}\n")
	_, _ = fmt.Fprintf(&buf, "\t}\n")
	if returnPointer {
		_, _ = fmt.Fprintf(&buf, "\treturn %s\n", cfgVar)
	} else {
		_, _ = fmt.Fprintf(&buf, "\treturn *%s\n", cfgVar)
	}
	_, _ = fmt.Fprintf(&buf, "}")

	raw := buf.String()
	if formatted, err := format.Source([]byte(raw)); err == nil {
		return strings.TrimSpace(string(formatted))
	}
	return raw
}

func buildUpdatedFileWithConstructor(
	selected *parsedConstructorStructInfo,
	constructorName string,
	includeOptions bool,
	fields []ConstructorFieldItem,
	previewCode string,
) string {
	if selected == nil || len(selected.src) == 0 {
		return previewCode
	}

	srcStr := string(selected.src)
	fset := selected.fset
	file := selected.file
	optionTypeName := selected.name + "Option"
	withFuncNames := map[string]bool{}
	for _, f := range fields {
		if f.OptionFuncName != "" {
			withFuncNames[f.OptionFuncName] = true
		}
	}

	type byteSpan struct {
		start int
		end   int
	}
	var removeSpans []byteSpan
	var primarySpan *byteSpan

	if file != nil && fset != nil {
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if includeOptions && d.Tok == token.TYPE && len(d.Specs) == 1 {
					if ts, ok := d.Specs[0].(*ast.TypeSpec); ok && ts.Name != nil && ts.Name.Name == optionTypeName {
						startPos := d.Pos()
						if d.Doc != nil {
							startPos = d.Doc.Pos()
						}
						startOff := fset.Position(startPos).Offset
						endOff := fset.Position(d.End()).Offset
						if startOff >= 0 && endOff >= startOff && endOff <= len(srcStr) {
							removeSpans = append(removeSpans, byteSpan{start: startOff, end: endOff})
						}
					}
				}
			case *ast.FuncDecl:
				if d.Recv != nil || d.Name == nil {
					continue
				}
				isCtor := d.Name.Name == constructorName
				isWithOpt := includeOptions && withFuncNames[d.Name.Name]
				if !isCtor && !isWithOpt {
					continue
				}
				startPos := d.Pos()
				if d.Doc != nil {
					startPos = d.Doc.Pos()
				}
				startOff := fset.Position(startPos).Offset
				endOff := fset.Position(d.End()).Offset
				if startOff >= 0 && endOff >= startOff && endOff <= len(srcStr) {
					sp := byteSpan{start: startOff, end: endOff}
					if isCtor && primarySpan == nil {
						primarySpan = &sp
					} else {
						removeSpans = append(removeSpans, sp)
					}
				}
			}
		}
	}

	if primarySpan != nil {
		allSpans := append([]byteSpan{*primarySpan}, removeSpans...)
		sort.Slice(allSpans, func(i, j int) bool {
			return allSpans[i].start > allSpans[j].start
		})
		updated := srcStr
		for _, sp := range allSpans {
			if sp.start == primarySpan.start && sp.end == primarySpan.end {
				updated = updated[:sp.start] + previewCode + updated[sp.end:]
			} else {
				updated = updated[:sp.start] + updated[sp.end:]
			}
		}
		if formatted, err := format.Source([]byte(updated)); err == nil {
			return string(formatted)
		}
		return updated
	}

	insertOff := selected.declEndOff
	if insertOff < 0 || insertOff > len(srcStr) {
		insertOff = len(srcStr)
	}
	for insertOff < len(srcStr) && srcStr[insertOff] != '\n' {
		insertOff++
	}
	if len(removeSpans) > 0 {
		sort.Slice(removeSpans, func(i, j int) bool {
			return removeSpans[i].start > removeSpans[j].start
		})
		for _, sp := range removeSpans {
			srcStr = srcStr[:sp.start] + srcStr[sp.end:]
			if sp.end <= insertOff {
				insertOff -= sp.end - sp.start
			} else if sp.start < insertOff {
				insertOff = sp.start
			}
		}
	}
	updated := srcStr[:insertOff] + "\n\n" + previewCode + srcStr[insertOff:]

	if formatted, err := format.Source([]byte(updated)); err == nil {
		return string(formatted)
	}
	return updated
}
