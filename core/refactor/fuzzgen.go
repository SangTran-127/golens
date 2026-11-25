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
)

const (
	fuzzGoTestFileSuffix = "_test.go"
	fuzzTypeByteSlice    = "[]byte"
	fuzzTypeUint8Slice   = "[]uint8"
)

type FuzzSeedRow struct {
	Label  string   `json:"label"`
	Values []string `json:"values"`
}

type FuzzParamItem struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	Supported bool   `json:"supported"`
}

type FuzzTestPlan struct {
	PackageName        string          `json:"packageName"`
	TargetFunc         string          `json:"targetFunc"`
	ReceiverType       string          `json:"receiverType,omitempty"`
	AvailableFunctions []string        `json:"availableFunctions"`
	FuzzFuncName       string          `json:"fuzzFuncName"`
	Params             []FuzzParamItem `json:"params"`
	Seeds              []FuzzSeedRow   `json:"seeds"`
	IncludeEdgeSeeds   bool            `json:"includeEdgeSeeds"`
	CheckDeterminism   bool            `json:"checkDeterminism"`
	PreviewCode        string          `json:"previewCode"`
	NewContent         string          `json:"newContent"`
	TargetFile         string          `json:"targetFile"`
	Error              string          `json:"error,omitempty"`
}

type fuzzParamSpec struct {
	rawName    string
	safeName   string
	typeExpr   string
	supported  bool
	isVariadic bool
}

type fuzzResultSpec struct {
	typeExpr string
	isError  bool
}

type parsedFuzzFuncInfo struct {
	displayName    string
	shortName      string
	recvType       string
	recvBaseName   string
	recvInitType   string
	recvIsStruct   bool
	recvTypeArgs   []string
	funcCallArgs   []string
	typeSubst      map[string]string
	isPtrRecv      bool
	pkgName        string
	filePath       string
	fset           *token.FileSet
	file           *ast.File
	src            []byte
	funcDecl       *ast.FuncDecl
	params         []fuzzParamSpec
	results        []fuzzResultSpec
	supportedCount int
	allSupported   bool
	startLine      int
	endLine        int
	isTarget       bool
}

type fuzzStructSpan struct {
	name      string
	filePath  string
	startLine int
	endLine   int
	isTarget  bool
}

type fuzzTypeParamRecord struct {
	fset *token.FileSet
	src  []byte
	tp   *ast.FieldList
}

var fuzzStdlibImports = map[string]string{
	"testing": "testing",
	"bytes":   "bytes",
	"reflect": "reflect",
	"time":    "time",
	"fmt":     "fmt",
	"io":      "io",
	"context": "context",
	"strings": "strings",
	"errors":  "errors",
}

func InspectFuzzTest(
	dir, filePath, content string,
	line, col int,
	funcName string,
	includeEdgeSeeds, checkDeterminism bool,
) (FuzzTestPlan, error) {
	_ = col
	plan := FuzzTestPlan{
		AvailableFunctions: []string{},
		Params:             []FuzzParamItem{},
		Seeds:              []FuzzSeedRow{},
		IncludeEdgeSeeds:   includeEdgeSeeds,
		CheckDeterminism:   checkDeterminism,
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

	targetSrc := []byte(content)

	var allFuncs []*parsedFuzzFuncInfo
	var structSpans []fuzzStructSpan
	var defaultPkgName string
	structNames := map[string]bool{}
	definedTypes := map[string]ast.Expr{}
	structTypeParams := map[string]*fuzzTypeParamRecord{}
	localInterfaces := map[string]bool{}

	collectFromAST := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
		if !isTarget && !buildTagsCompatible(targetSrc, src) {
			return
		}
		pkg := f.Name.Name
		if defaultPkgName == "" || (strings.HasSuffix(defaultPkgName, "_test") && !strings.HasSuffix(pkg, "_test")) {
			defaultPkgName = pkg
		} else if pkg != defaultPkgName && strings.TrimSuffix(pkg, "_test") != strings.TrimSuffix(defaultPkgName, "_test") && !isTarget {
			return
		}

		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if d.Tok != token.TYPE {
					continue
				}
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || ts.Name == nil || ts.Name.Name == "" {
						continue
					}
					definedTypes[ts.Name.Name] = ts.Type
					if _, isIface := ts.Type.(*ast.InterfaceType); isIface {
						localInterfaces[ts.Name.Name] = true
					}
					if _, isStruct := ts.Type.(*ast.StructType); !isStruct {
						continue
					}
					structNames[ts.Name.Name] = true
					if ts.TypeParams != nil && len(ts.TypeParams.List) > 0 {
						structTypeParams[ts.Name.Name] = &fuzzTypeParamRecord{
							fset: fset,
							src:  src,
							tp:   ts.TypeParams,
						}
					}
					startLn := fset.Position(ts.Pos()).Line
					endLn := fset.Position(ts.End()).Line
					if len(d.Specs) == 1 {
						startLn = fset.Position(d.Pos()).Line
						if d.Doc != nil {
							startLn = fset.Position(d.Doc.Pos()).Line
						}
						endLn = fset.Position(d.End()).Line
					}
					structSpans = append(structSpans, fuzzStructSpan{
						name:      ts.Name.Name,
						filePath:  fp,
						startLine: startLn,
						endLine:   endLn,
						isTarget:  isTarget,
					})
				}
			case *ast.FuncDecl:
				if d.Name == nil || d.Name.Name == "" || d.Type == nil {
					continue
				}
				fnName := d.Name.Name
				if d.Recv == nil {
					if fnName == "init" || fnName == "main" ||
						strings.HasPrefix(fnName, "Test") ||
						strings.HasPrefix(fnName, "Benchmark") ||
						strings.HasPrefix(fnName, "Fuzz") ||
						strings.HasPrefix(fnName, "Example") {
						continue
					}
				}

				recvType := ""
				recvBase := ""
				isPtr := false
				var recvTypeArgs []string
				displayName := fnName
				if d.Recv != nil && len(d.Recv.List) > 0 {
					recvExpr := d.Recv.List[0].Type
					recvBase = extractReceiverTypeName(recvExpr)
					if recvBase == "" {
						continue
					}
					baseExpr := recvExpr
					if star, ok := recvExpr.(*ast.StarExpr); ok {
						isPtr = true
						baseExpr = star.X
						recvType = "*" + recvBase
						displayName = fmt.Sprintf("(*%s).%s", recvBase, fnName)
					} else {
						recvType = recvBase
						displayName = fmt.Sprintf("%s.%s", recvBase, fnName)
					}
					switch rt := baseExpr.(type) {
					case *ast.IndexExpr:
						recvTypeArgs = append(recvTypeArgs, strings.TrimSpace(astExprString(fset, src, rt.Index)))
					case *ast.IndexListExpr:
						for _, idx := range rt.Indices {
							recvTypeArgs = append(recvTypeArgs, strings.TrimSpace(astExprString(fset, src, idx)))
						}
					}
				}

				startLn := fset.Position(d.Pos()).Line
				if d.Doc != nil {
					startLn = fset.Position(d.Doc.Pos()).Line
				}
				endLn := fset.Position(d.End()).Line

				info := &parsedFuzzFuncInfo{
					displayName:  displayName,
					shortName:    fnName,
					recvType:     recvType,
					recvBaseName: recvBase,
					recvTypeArgs: recvTypeArgs,
					isPtrRecv:    isPtr,
					pkgName:      pkg,
					filePath:     fp,
					fset:         fset,
					file:         f,
					src:          src,
					funcDecl:     d,
					startLine:    startLn,
					endLine:      endLn,
					isTarget:     isTarget,
				}
				allFuncs = append(allFuncs, info)
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
			if strings.HasSuffix(gf, fuzzGoTestFileSuffix) && (cleanFile == "" || !sameFilePath(gf, cleanFile)) {
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

	if len(allFuncs) == 0 {
		err := fmt.Errorf("no fuzzable functions found in file or package")
		plan.Error = err.Error()
		return plan, err
	}

	for _, fn := range allFuncs {
		finalizeFuzzFuncInfo(fn, structTypeParams, definedTypes, localInterfaces)
	}

	hasParamFuncs := false
	for _, fn := range allFuncs {
		if len(fn.params) > 0 {
			hasParamFuncs = true
			break
		}
	}

	var candidates []*parsedFuzzFuncInfo
	if hasParamFuncs {
		var tierAllSupported []*parsedFuzzFuncInfo
		var tierSomeSupported []*parsedFuzzFuncInfo
		var tierUnsupported []*parsedFuzzFuncInfo
		for _, fn := range allFuncs {
			if len(fn.params) == 0 {
				continue
			}
			if fn.allSupported {
				tierAllSupported = append(tierAllSupported, fn)
			} else if fn.supportedCount > 0 {
				tierSomeSupported = append(tierSomeSupported, fn)
			} else {
				tierUnsupported = append(tierUnsupported, fn)
			}
		}
		candidates = append(candidates, tierAllSupported...)
		candidates = append(candidates, tierSomeSupported...)
		candidates = append(candidates, tierUnsupported...)
	} else {
		candidates = append(candidates, allFuncs...)
	}

	seenDisplay := map[string]bool{}
	var availableNames []string
	for _, fn := range candidates {
		if !seenDisplay[fn.displayName] {
			seenDisplay[fn.displayName] = true
			availableNames = append(availableNames, fn.displayName)
		}
	}
	plan.AvailableFunctions = availableNames

	var selected *parsedFuzzFuncInfo
	reqFunc := strings.TrimSpace(funcName)
	if reqFunc != "" {
		selected = matchFuzzFuncByName(candidates, reqFunc)
		if selected == nil {
			selected = matchFuzzFuncByName(allFuncs, reqFunc)
			if selected != nil && !seenDisplay[selected.displayName] {
				plan.AvailableFunctions = append(plan.AvailableFunctions, selected.displayName)
			}
		}
		if selected == nil {
			err := fmt.Errorf("function %q not found in package", reqFunc)
			plan.Error = err.Error()
			return plan, err
		}
	}

	if selected == nil && line > 0 {
		for _, cand := range candidates {
			if cand.isTarget && line >= cand.startLine && line <= cand.endLine {
				selected = cand
				break
			}
		}
	}

	if selected == nil && line > 0 {
		for _, st := range structSpans {
			if st.isTarget && line >= st.startLine && line <= st.endLine {
				for _, cand := range candidates {
					if cand.recvBaseName == st.name && cand.supportedCount > 0 {
						selected = cand
						break
					}
				}
				if selected != nil {
					break
				}
			}
		}
	}

	if selected == nil && line > 1 {
		bestDist := int(^uint(0) >> 1)
		for _, cand := range candidates {
			if !cand.isTarget || cand.supportedCount == 0 {
				continue
			}
			dist := minLineDist(line, cand.startLine, cand.endLine)
			if dist < bestDist {
				bestDist = dist
				selected = cand
			}
		}
	}

	if selected == nil {
		for _, cand := range candidates {
			if cand.isTarget && cand.allSupported {
				selected = cand
				break
			}
		}
	}

	if selected == nil {
		for _, cand := range candidates {
			if cand.isTarget && cand.supportedCount > 0 {
				selected = cand
				break
			}
		}
	}

	if selected == nil {
		for _, cand := range candidates {
			if cand.supportedCount > 0 {
				selected = cand
				break
			}
		}
	}

	if selected == nil {
		for _, cand := range candidates {
			if cand.isTarget {
				selected = cand
				break
			}
		}
	}

	if selected == nil {
		selected = candidates[0]
	}

	pkgName := strings.TrimSuffix(selected.pkgName, "_test")
	if pkgName == "" {
		pkgName = strings.TrimSuffix(defaultPkgName, "_test")
	}
	if pkgName == "" {
		pkgName = "main"
	}

	fuzzFuncName := buildFuzzFuncName(selected)
	paramItems := make([]FuzzParamItem, 0, len(selected.params))
	for _, p := range selected.params {
		paramItems = append(paramItems, FuzzParamItem{
			Name:      p.rawName,
			Type:      p.typeExpr,
			Supported: p.supported,
		})
	}

	seeds := buildFuzzSeedRows(selected.params, includeEdgeSeeds)
	previewCode, extraImports := buildFuzzPreviewCode(selected, fuzzFuncName, seeds, checkDeterminism, definedTypes)
	targetFile := resolveFuzzTargetTestFile(selected.filePath, cleanFile, cleanDir)
	if targetFile != "" && (cleanFile == "" || !sameFilePath(targetFile, cleanFile)) {
		if existingData, readErr := readSourceFile(targetFile); readErr == nil && len(existingData) > 0 {
			if ef, pErr := parser.ParseFile(token.NewFileSet(), targetFile, existingData, parser.PackageClauseOnly); pErr == nil && ef != nil && ef.Name != nil {
				if strings.HasSuffix(ef.Name.Name, "_test") && !strings.HasSuffix(pkgName, "_test") {
					targetFile = strings.TrimSuffix(targetFile, fuzzGoTestFileSuffix) + "_fuzz" + fuzzGoTestFileSuffix
				}
			}
		}
	}
	newContent := buildFuzzTestFileContent(targetFile, cleanFile, content, selected.src, pkgName, fuzzFuncName, previewCode, extraImports)

	plan.PackageName = pkgName
	plan.TargetFunc = selected.displayName
	plan.ReceiverType = selected.recvType
	plan.FuzzFuncName = fuzzFuncName
	plan.Params = paramItems
	plan.Seeds = seeds
	plan.PreviewCode = previewCode
	plan.NewContent = newContent
	plan.TargetFile = targetFile
	return plan, nil
}

func isSupportedFuzzType(typeStr string) bool {
	switch strings.TrimSpace(typeStr) {
	case "string", fuzzTypeByteSlice, fuzzTypeUint8Slice,
		"int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64",
		"float32", "float64",
		"bool", "rune", "byte":
		return true
	default:
		return false
	}
}

func finalizeFuzzFuncInfo(
	fn *parsedFuzzFuncInfo,
	structTypeParams map[string]*fuzzTypeParamRecord,
	definedTypes map[string]ast.Expr,
	localInterfaces map[string]bool,
) {
	if fn == nil || fn.funcDecl == nil || fn.funcDecl.Type == nil {
		return
	}
	typeSubst := map[string]string{}
	if fn.recvBaseName != "" {
		if dt, exists := definedTypes[fn.recvBaseName]; exists {
			_, fn.recvIsStruct = dt.(*ast.StructType)
		} else {
			fn.recvIsStruct = true
		}
		fn.recvInitType = fn.recvBaseName
		if len(fn.recvTypeArgs) > 0 {
			var witnessArgs []string
			if rec, ok := structTypeParams[fn.recvBaseName]; ok && rec != nil {
				witnessArgs, _ = buildGenericWitnessArgs(rec.fset, rec.src, rec.tp, localInterfaces)
			}
			recvWitness := make([]string, len(fn.recvTypeArgs))
			for i, rawArg := range fn.recvTypeArgs {
				w := "int"
				if i < len(witnessArgs) && witnessArgs[i] != "" {
					w = witnessArgs[i]
				}
				recvWitness[i] = w
				if rawArg != "" {
					typeSubst[rawArg] = w
				}
			}
			fn.recvInitType = fmt.Sprintf("%s[%s]", fn.recvBaseName, strings.Join(recvWitness, ", "))
		}
	}
	if fn.funcDecl.Type.TypeParams != nil && len(fn.funcDecl.Type.TypeParams.List) > 0 {
		funcArgs, funcSubst := buildGenericWitnessArgs(fn.fset, fn.src, fn.funcDecl.Type.TypeParams, localInterfaces)
		fn.funcCallArgs = funcArgs
		for k, v := range funcSubst {
			typeSubst[k] = v
		}
	}
	fn.typeSubst = typeSubst

	extraReserved := map[string]bool{}
	addReservedPredeclaredTypes(extraReserved)
	addReservedFileImports(extraReserved, fn.file)
	for tpName := range typeSubst {
		extraReserved[tpName] = true
	}

	fn.params = parseFuzzFuncParams(fn.fset, fn.src, fn.funcDecl.Type.Params, typeSubst, extraReserved)
	fn.results = parseFuzzFuncResults(fn.fset, fn.src, fn.funcDecl.Type.Results, typeSubst)
	supCount := 0
	for _, p := range fn.params {
		if p.supported {
			supCount++
		}
	}
	fn.supportedCount = supCount
	fn.allSupported = len(fn.params) > 0 && supCount == len(fn.params)
}

func parseFuzzFuncParams(
	fset *token.FileSet,
	src []byte,
	fl *ast.FieldList,
	typeSubst map[string]string,
	extraReserved map[string]bool,
) []fuzzParamSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var params []fuzzParamSpec
	usedNames := map[string]bool{
		"f":       true,
		"t":       true,
		"target":  true,
		"got1":    true,
		"got2":    true,
		"err1":    true,
		"err2":    true,
		"testing": true,
		"bytes":   true,
		"reflect": true,
	}
	for k, v := range extraReserved {
		if v {
			usedNames[k] = true
		}
	}
	argIdx := 0

	nextSafeName := func(raw string) string {
		cand := sanitizeParamIdent(raw)
		if cand == "" || cand == "_" || isGoKeyword(cand) || usedNames[cand] {
			if cand != "" && cand != "_" && !isGoKeyword(cand) {
				cand = cand + "Param"
			} else {
				cand = fmt.Sprintf("arg%d", argIdx)
			}
		}
		base := cand
		for suffix := 2; usedNames[cand]; suffix++ {
			cand = fmt.Sprintf("%s%d", base, suffix)
		}
		usedNames[cand] = true
		argIdx++
		return cand
	}

	for _, field := range fl.List {
		if field == nil || field.Type == nil {
			continue
		}
		isVariadic := false
		typeExpr := strings.TrimSpace(astExprString(fset, src, field.Type))
		if len(typeSubst) > 0 {
			typeExpr = substituteTypeExprString(typeExpr, typeSubst)
		}
		if ellipsis, ok := field.Type.(*ast.Ellipsis); ok {
			isVariadic = true
			eltStr := strings.TrimSpace(astExprString(fset, src, ellipsis.Elt))
			if len(typeSubst) > 0 {
				eltStr = substituteTypeExprString(eltStr, typeSubst)
			}
			typeExpr = "..." + eltStr
		}
		supported := !isVariadic && isSupportedFuzzType(typeExpr)

		if len(field.Names) == 0 {
			safe := nextSafeName(fmt.Sprintf("arg%d", argIdx))
			params = append(params, fuzzParamSpec{
				rawName:    safe,
				safeName:   safe,
				typeExpr:   typeExpr,
				supported:  supported,
				isVariadic: isVariadic,
			})
			continue
		}

		for _, ident := range field.Names {
			raw := ""
			if ident != nil {
				raw = ident.Name
			}
			safe := nextSafeName(raw)
			displayParam := raw
			if displayParam == "" || displayParam == "_" {
				displayParam = safe
			}
			params = append(params, fuzzParamSpec{
				rawName:    displayParam,
				safeName:   safe,
				typeExpr:   typeExpr,
				supported:  supported,
				isVariadic: isVariadic,
			})
		}
	}
	return params
}

func parseFuzzFuncResults(fset *token.FileSet, src []byte, fl *ast.FieldList, typeSubst map[string]string) []fuzzResultSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var results []fuzzResultSpec
	for _, field := range fl.List {
		if field == nil || field.Type == nil {
			continue
		}
		typeExpr := strings.TrimSpace(astExprString(fset, src, field.Type))
		if len(typeSubst) > 0 {
			typeExpr = substituteTypeExprString(typeExpr, typeSubst)
		}
		isErr := typeExpr == "error"
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		for i := 0; i < count; i++ {
			results = append(results, fuzzResultSpec{
				typeExpr: typeExpr,
				isError:  isErr,
			})
		}
	}
	return results
}

func matchFuzzFuncByName(list []*parsedFuzzFuncInfo, query string) *parsedFuzzFuncInfo {
	for _, fn := range list {
		if fn.displayName == query || fn.shortName == query {
			return fn
		}
		if fn.recvBaseName != "" {
			if fmt.Sprintf("(*%s).%s", fn.recvBaseName, fn.shortName) == query ||
				fmt.Sprintf("%s.%s", fn.recvBaseName, fn.shortName) == query {
				return fn
			}
		}
	}
	for _, fn := range list {
		if strings.EqualFold(fn.displayName, query) || strings.EqualFold(fn.shortName, query) {
			return fn
		}
		if fn.recvBaseName != "" {
			if strings.EqualFold(fmt.Sprintf("(*%s).%s", fn.recvBaseName, fn.shortName), query) ||
				strings.EqualFold(fmt.Sprintf("%s.%s", fn.recvBaseName, fn.shortName), query) {
				return fn
			}
		}
	}
	return nil
}

func buildFuzzFuncName(fn *parsedFuzzFuncInfo) string {
	if fn == nil {
		return "FuzzTarget"
	}
	if fn.recvBaseName != "" {
		return fmt.Sprintf("Fuzz%s_%s", exportIdent(fn.recvBaseName), fn.shortName)
	}
	return "Fuzz" + exportIdent(fn.shortName)
}

func buildFuzzSeedRows(params []fuzzParamSpec, includeEdgeSeeds bool) []FuzzSeedRow {
	var supportedParams []fuzzParamSpec
	for _, p := range params {
		if p.supported {
			supportedParams = append(supportedParams, p)
		}
	}
	if len(supportedParams) == 0 {
		supportedParams = []fuzzParamSpec{
			{rawName: "input", safeName: "input", typeExpr: "string", supported: true},
		}
	}

	rowSpecs := []struct {
		label string
		kind  string
	}{
		{label: "Default", kind: "default"},
		{label: "Typical", kind: "typical"},
	}
	if includeEdgeSeeds {
		rowSpecs = append(rowSpecs,
			struct {
				label string
				kind  string
			}{label: "Empty / Zero", kind: "empty"},
			struct {
				label string
				kind  string
			}{label: "Boundary / Negative", kind: "boundary"},
			struct {
				label string
				kind  string
			}{label: "Unicode / Special", kind: "special"},
		)
	}

	rows := make([]FuzzSeedRow, 0, len(rowSpecs))
	for _, spec := range rowSpecs {
		vals := make([]string, 0, len(supportedParams))
		for _, p := range supportedParams {
			vals = append(vals, fuzzSeedLiteralForType(p.typeExpr, spec.kind))
		}
		rows = append(rows, FuzzSeedRow{
			Label:  spec.label,
			Values: vals,
		})
	}
	return rows
}

func fuzzSeedLiteralForType(typeStr string, kind string) string {
	switch strings.TrimSpace(typeStr) {
	case "string":
		switch kind {
		case "default":
			return `""`
		case "typical":
			return `"alpha"`
		case "empty":
			return `" "`
		case "boundary":
			return `"a"`
		case "special":
			return `"utf8_λ_00"`
		}
	case fuzzTypeByteSlice, fuzzTypeUint8Slice:
		switch kind {
		case "default":
			return `[]byte("")`
		case "typical":
			return `[]byte("seed")`
		case "empty":
			return `[]byte{}`
		case "boundary":
			return `[]byte{0x00, 0xff}`
		case "special":
			return `[]byte("utf8_λ_00")`
		}
	case "int":
		switch kind {
		case "default":
			return "0"
		case "typical":
			return "42"
		case "empty":
			return "0"
		case "boundary":
			return "-1"
		case "special":
			return "1024"
		}
	case "int8", "int16", "int32", "int64":
		t := strings.TrimSpace(typeStr)
		switch kind {
		case "default":
			return fmt.Sprintf("%s(0)", t)
		case "typical":
			return fmt.Sprintf("%s(42)", t)
		case "empty":
			return fmt.Sprintf("%s(0)", t)
		case "boundary":
			return fmt.Sprintf("%s(-1)", t)
		case "special":
			if t == "int8" {
				return "int8(127)"
			}
			return fmt.Sprintf("%s(1024)", t)
		}
	case "uint":
		switch kind {
		case "default":
			return "uint(0)"
		case "typical":
			return "uint(42)"
		case "empty":
			return "uint(0)"
		case "boundary":
			return "uint(1)"
		case "special":
			return "uint(1024)"
		}
	case "uint8", "uint16", "uint32", "uint64":
		t := strings.TrimSpace(typeStr)
		switch kind {
		case "default":
			return fmt.Sprintf("%s(0)", t)
		case "typical":
			return fmt.Sprintf("%s(42)", t)
		case "empty":
			return fmt.Sprintf("%s(0)", t)
		case "boundary":
			return fmt.Sprintf("%s(1)", t)
		case "special":
			if t == "uint8" {
				return "uint8(255)"
			}
			return fmt.Sprintf("%s(1024)", t)
		}
	case "float32":
		switch kind {
		case "default":
			return "float32(0)"
		case "typical":
			return "float32(3.14)"
		case "empty":
			return "float32(0)"
		case "boundary":
			return "float32(-1.5)"
		case "special":
			return "float32(1024.5)"
		}
	case "float64":
		switch kind {
		case "default":
			return "0.0"
		case "typical":
			return "3.14"
		case "empty":
			return "0.0"
		case "boundary":
			return "-1.5"
		case "special":
			return "1024.5"
		}
	case "bool":
		switch kind {
		case "default":
			return "false"
		case "typical":
			return "true"
		case "empty":
			return "false"
		case "boundary":
			return "true"
		case "special":
			return "false"
		}
	case "byte":
		switch kind {
		case "default":
			return "byte(0)"
		case "typical":
			return "byte('a')"
		case "empty":
			return "byte(0)"
		case "boundary":
			return "byte(255)"
		case "special":
			return "byte('Z')"
		}
	case "rune":
		switch kind {
		case "default":
			return "rune(0)"
		case "typical":
			return "rune('a')"
		case "empty":
			return "rune(' ')"
		case "boundary":
			return "rune(-1)"
		case "special":
			return "rune('λ')"
		}
	}
	return `""`
}

func buildFuzzPreviewCode(
	fn *parsedFuzzFuncInfo,
	fuzzFuncName string,
	seeds []FuzzSeedRow,
	checkDeterminism bool,
	definedTypes map[string]ast.Expr,
) (string, []requiredImportSpec) {
	var buf bytes.Buffer

	importAliases := collectFileImportAliases(fn.file)
	testingPkg := "testing"
	for alias, p := range importAliases {
		if p == "testing" {
			testingPkg = alias
			break
		}
	}

	usedLocals := map[string]bool{}
	for _, p := range fn.params {
		if p.safeName != "" {
			usedLocals[p.safeName] = true
		}
	}
	for alias := range importAliases {
		usedLocals[alias] = true
	}
	if fn.shortName != "" && fn.recvBaseName == "" {
		usedLocals[fn.shortName] = true
	}
	if fn.recvBaseName != "" {
		usedLocals[fn.recvBaseName] = true
	}

	allocLocal := func(preferred string) string {
		if !usedLocals[preferred] {
			usedLocals[preferred] = true
			return preferred
		}
		for i := 1; ; i++ {
			cand := fmt.Sprintf("%s%d", preferred, i)
			if !usedLocals[cand] {
				usedLocals[cand] = true
				return cand
			}
		}
	}

	fVar := allocLocal("f")
	tVar := allocLocal("t")
	targetVar := "target"
	if fn.recvBaseName != "" {
		targetVar = allocLocal("target")
	}
	got1Var := allocLocal("got1")
	got2Var := allocLocal("got2")
	err1Var := allocLocal("err1")
	err2Var := allocLocal("err2")

	_, _ = fmt.Fprintf(&buf, "func %s(%s *%s.F) {\n", fuzzFuncName, fVar, testingPkg)
	for _, row := range seeds {
		_, _ = fmt.Fprintf(&buf, "\t%s.Add(%s)\n", fVar, strings.Join(row.Values, ", "))
	}

	var fuzzSigParams []string
	var callArgs []string
	var setupZeroVars []string

	for i, p := range fn.params {
		if p.supported {
			fuzzSigParams = append(fuzzSigParams, fmt.Sprintf("%s %s", p.safeName, p.typeExpr))
			callArgs = append(callArgs, p.safeName)
		} else if p.isVariadic {
			continue
		} else {
			zeroVar := allocLocal(fmt.Sprintf("zeroArg%d", i))
			setupZeroVars = append(setupZeroVars, fmt.Sprintf("\t\tvar %s %s\n", zeroVar, p.typeExpr))
			callArgs = append(callArgs, zeroVar)
		}
	}

	if len(fuzzSigParams) == 0 {
		fuzzSigParams = append(fuzzSigParams, "_ string")
	}

	_, _ = fmt.Fprintf(&buf, "\t%s.Fuzz(func(%s *%s.T, %s) {\n", fVar, tVar, testingPkg, strings.Join(fuzzSigParams, ", "))
	for _, line := range setupZeroVars {
		buf.WriteString(line)
	}

	callTarget := fn.shortName
	if fn.recvBaseName != "" {
		recvInit := fn.recvInitType
		if recvInit == "" {
			recvInit = fn.recvBaseName
		}
		if fn.recvIsStruct {
			if fn.isPtrRecv {
				_, _ = fmt.Fprintf(&buf, "\t\t%s := &%s{}\n", targetVar, recvInit)
			} else {
				_, _ = fmt.Fprintf(&buf, "\t\t%s := %s{}\n", targetVar, recvInit)
			}
		} else {
			_, _ = fmt.Fprintf(&buf, "\t\tvar %s %s\n", targetVar, recvInit)
		}
		callTarget = targetVar + "." + fn.shortName
	} else if len(fn.funcCallArgs) > 0 {
		callTarget = fmt.Sprintf("%s[%s]", fn.shortName, strings.Join(fn.funcCallArgs, ", "))
	}

	callExpr := fmt.Sprintf("%s(%s)", callTarget, strings.Join(callArgs, ", "))

	firstNonErrIdx := -1
	for i, r := range fn.results {
		if !r.isError {
			firstNonErrIdx = i
			break
		}
	}

	if !checkDeterminism || firstNonErrIdx == -1 {
		if len(fn.results) == 0 {
			_, _ = fmt.Fprintf(&buf, "\t\t%s\n", callExpr)
		} else {
			blanks := make([]string, len(fn.results))
			for i := range blanks {
				blanks[i] = "_"
			}
			_, _ = fmt.Fprintf(&buf, "\t\t%s = %s\n", strings.Join(blanks, ", "), callExpr)
		}
	} else {
		primaryType := strings.TrimSpace(fn.results[firstNonErrIdx].typeExpr)
		if len(fn.results) == 1 {
			_, _ = fmt.Fprintf(&buf, "\t\t%s := %s\n", got1Var, callExpr)
			_, _ = fmt.Fprintf(&buf, "\t\t%s := %s\n", got2Var, callExpr)
		} else if len(fn.results) == 2 && firstNonErrIdx == 0 && fn.results[1].isError {
			_, _ = fmt.Fprintf(&buf, "\t\t%s, %s := %s\n", got1Var, err1Var, callExpr)
			_, _ = fmt.Fprintf(&buf, "\t\t%s, %s := %s\n", got2Var, err2Var, callExpr)
			_, _ = fmt.Fprintf(&buf, "\t\tif (%s == nil) != (%s == nil) {\n", err1Var, err2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t\t%s.Fatalf(\"non-deterministic error: %%v != %%v\", %s, %s)\n", tVar, err1Var, err2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t}\n")
		} else {
			lhs1 := make([]string, len(fn.results))
			lhs2 := make([]string, len(fn.results))
			for i := range fn.results {
				if i == firstNonErrIdx {
					lhs1[i] = got1Var
					lhs2[i] = got2Var
				} else {
					lhs1[i] = "_"
					lhs2[i] = "_"
				}
			}
			_, _ = fmt.Fprintf(&buf, "\t\t%s := %s\n", strings.Join(lhs1, ", "), callExpr)
			_, _ = fmt.Fprintf(&buf, "\t\t%s := %s\n", strings.Join(lhs2, ", "), callExpr)
		}

		switch classifyFuzzResultComparison(primaryType, definedTypes) {
		case "bytes":
			_, _ = fmt.Fprintf(&buf, "\t\tif !bytes.Equal(%s, %s) {\n", got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t\t%s.Fatalf(\"non-deterministic output: %%v != %%v\", %s, %s)\n", tVar, got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t}\n")
		case "func":
			_, _ = fmt.Fprintf(&buf, "\t\tif (%s == nil) != (%s == nil) {\n", got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t\t%s.Fatalf(\"non-deterministic function nilness\")\n", tVar)
			_, _ = fmt.Fprintf(&buf, "\t\t}\n")
		case "reflect":
			_, _ = fmt.Fprintf(&buf, "\t\tif !reflect.DeepEqual(%s, %s) {\n", got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t\t%s.Fatalf(\"non-deterministic output: %%v != %%v\", %s, %s)\n", tVar, got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t}\n")
		default:
			_, _ = fmt.Fprintf(&buf, "\t\tif %s != %s {\n", got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t\t%s.Fatalf(\"non-deterministic output: %%v != %%v\", %s, %s)\n", tVar, got1Var, got2Var)
			_, _ = fmt.Fprintf(&buf, "\t\t}\n")
		}
	}

	_, _ = fmt.Fprintf(&buf, "\t})\n")
	_, _ = fmt.Fprintf(&buf, "}")

	raw := buf.String()
	previewCode := raw
	if formatted, err := format.Source([]byte(raw)); err == nil {
		previewCode = strings.TrimSpace(string(formatted))
	}

	specs := collectUsedImportSpecsFromAST([]*ast.File{fn.file}, previewCode, fuzzStdlibImports)
	sort.Slice(specs, func(i, j int) bool {
		if specs[i].Path != specs[j].Path {
			return specs[i].Path < specs[j].Path
		}
		return specs[i].Alias < specs[j].Alias
	})
	return previewCode, specs
}

func classifyFuzzResultComparison(typeStr string, definedTypes map[string]ast.Expr) string {
	trimmed := strings.TrimSpace(typeStr)
	if trimmed == fuzzTypeByteSlice || trimmed == fuzzTypeUint8Slice {
		return "bytes"
	}
	parsed, err := parser.ParseExpr(trimmed)
	if err != nil || parsed == nil {
		if strings.HasPrefix(trimmed, "func(") {
			return "func"
		}
		if isNonComparableGoType(trimmed) {
			return "reflect"
		}
		return "eq"
	}
	if _, isFunc := unwrapFuzzUnderlyingType(parsed, definedTypes, map[string]bool{}).(*ast.FuncType); isFunc {
		return "func"
	}
	if isFuzzTypeExprComparable(parsed, definedTypes, map[string]bool{}) {
		return "eq"
	}
	return "reflect"
}

func unwrapFuzzUnderlyingType(expr ast.Expr, definedTypes map[string]ast.Expr, seen map[string]bool) ast.Expr {
	for expr != nil {
		switch e := expr.(type) {
		case *ast.ParenExpr:
			expr = e.X
		case *ast.Ident:
			if seen[e.Name] || definedTypes == nil {
				return expr
			}
			next, ok := definedTypes[e.Name]
			if !ok || next == nil {
				return expr
			}
			seen[e.Name] = true
			expr = next
		default:
			return expr
		}
	}
	return expr
}

func isFuzzTypeExprComparable(expr ast.Expr, definedTypes map[string]ast.Expr, seen map[string]bool) bool {
	if expr == nil {
		return false
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isFuzzTypeExprComparable(e.X, definedTypes, seen)
	case *ast.StarExpr, *ast.ChanType:
		return true
	case *ast.ArrayType:
		if e.Len == nil {
			return false
		}
		return isFuzzTypeExprComparable(e.Elt, definedTypes, seen)
	case *ast.MapType, *ast.FuncType, *ast.InterfaceType:
		return false
	case *ast.StructType:
		if e.Fields == nil {
			return true
		}
		for _, f := range e.Fields.List {
			if f == nil || !isFuzzTypeExprComparable(f.Type, definedTypes, seen) {
				return false
			}
		}
		return true
	case *ast.IndexExpr, *ast.IndexListExpr:
		return false
	case *ast.SelectorExpr:
		return false
	case *ast.Ident:
		switch e.Name {
		case "any":
			return false
		case "bool", "byte", "complex64", "complex128",
			"float32", "float64",
			"int", "int8", "int16", "int32", "int64",
			"rune", "string",
			"uint", "uint8", "uint16", "uint32", "uint64", "uintptr":
			return true
		}
		if seen[e.Name] || definedTypes == nil {
			return false
		}
		next, ok := definedTypes[e.Name]
		if !ok || next == nil {
			return false
		}
		seen[e.Name] = true
		defer delete(seen, e.Name)
		return isFuzzTypeExprComparable(next, definedTypes, seen)
	default:
		return false
	}
}

func isNonComparableGoType(typeStr string) bool {
	trimmed := strings.TrimSpace(typeStr)
	return strings.HasPrefix(trimmed, "[]") ||
		strings.HasPrefix(trimmed, "map[") ||
		strings.HasPrefix(trimmed, "func(") ||
		trimmed == "any" ||
		strings.HasPrefix(trimmed, "interface{")
}

func resolveFuzzTargetTestFile(selectedFile, cleanFile, cleanDir string) string {
	baseFile := selectedFile
	if baseFile == "" {
		baseFile = cleanFile
	}
	if baseFile != "" {
		if strings.HasSuffix(baseFile, fuzzGoTestFileSuffix) {
			return baseFile
		}
		if strings.HasSuffix(baseFile, ".go") {
			return strings.TrimSuffix(baseFile, ".go") + fuzzGoTestFileSuffix
		}
		return baseFile + fuzzGoTestFileSuffix
	}
	if cleanDir != "" {
		return filepath.Join(cleanDir, "fuzz_test.go")
	}
	return "fuzz_test.go"
}

func buildFuzzTestFileContent(
	targetFile, cleanFile, currentContent string,
	selectedSrc []byte,
	pkgName, fuzzFuncName, previewCode string,
	requiredSpecs []requiredImportSpec,
) string {
	hasTesting := false
	for _, s := range requiredSpecs {
		if s.Path == "testing" {
			hasTesting = true
			break
		}
	}
	if !hasTesting {
		requiredSpecs = append([]requiredImportSpec{{Path: "testing"}}, requiredSpecs...)
	}

	var existingBytes []byte
	if cleanFile != "" && sameFilePath(targetFile, cleanFile) && strings.TrimSpace(currentContent) != "" {
		existingBytes = []byte(currentContent)
	} else if targetFile != "" {
		if data, err := readSourceFile(targetFile); err == nil && len(data) > 0 {
			existingBytes = data
		}
	}

	if len(existingBytes) > 0 {
		srcStr := string(existingBytes)
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, targetFile, existingBytes, parser.ParseComments)
		if err == nil && file != nil {
			var existingFunc *ast.FuncDecl
			for _, decl := range file.Decls {
				fd, ok := decl.(*ast.FuncDecl)
				if ok && fd.Recv == nil && fd.Name != nil && fd.Name.Name == fuzzFuncName {
					existingFunc = fd
					break
				}
			}

			var updated string
			if existingFunc != nil {
				startPos := existingFunc.Pos()
				if existingFunc.Doc != nil {
					startPos = existingFunc.Doc.Pos()
				}
				startOff := fset.Position(startPos).Offset
				endOff := fset.Position(existingFunc.End()).Offset
				if startOff >= 0 && endOff >= startOff && endOff <= len(srcStr) {
					updated = srcStr[:startOff] + previewCode + srcStr[endOff:]
				}
			}
			if updated == "" {
				updated = strings.TrimRight(srcStr, "\n\t ") + "\n\n" + previewCode + "\n"
			}

			withImports := ensureRequiredImportSpecs(updated, requiredSpecs)
			if formatted, fmtErr := format.Source([]byte(withImports)); fmtErr == nil {
				return string(formatted)
			}
			return withImports
		}
	}

	var buf bytes.Buffer
	_, directives := extractFileBuildConstraint(selectedSrc)
	if len(directives) == 0 {
		directives = extractFileBuildDirectives(cleanFile, currentContent)
	}
	for _, dir := range directives {
		buf.WriteString(dir)
		buf.WriteString("\n")
	}
	if buf.Len() > 0 {
		buf.WriteString("\n")
	}
	_, _ = fmt.Fprintf(&buf, "package %s\n\n", pkgName)
	_, _ = fmt.Fprintf(&buf, "import (\n")
	for _, imp := range requiredSpecs {
		if imp.Alias != "" && imp.Alias != defaultImportIdentifier(imp.Path) {
			_, _ = fmt.Fprintf(&buf, "\t%s %q\n", imp.Alias, imp.Path)
		} else {
			_, _ = fmt.Fprintf(&buf, "\t%q\n", imp.Path)
		}
	}
	_, _ = fmt.Fprintf(&buf, ")\n\n")
	buf.WriteString(previewCode)
	buf.WriteString("\n")

	raw := buf.String()
	if formatted, err := format.Source([]byte(raw)); err == nil {
		return string(formatted)
	}
	return raw
}
