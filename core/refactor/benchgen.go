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
	benchGoTestFileSuffix = "_test.go"
)

type BenchmarkParamInfo struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	SampleExpr string `json:"sampleExpr"`
}

type BenchmarkGenPlan struct {
	PackageName        string               `json:"packageName"`
	TargetFunc         string               `json:"targetFunc"`
	ReceiverType       string               `json:"receiverType,omitempty"`
	BenchmarkName      string               `json:"benchmarkName"`
	AvailableFuncs     []string             `json:"availableFuncs"`
	Params             []BenchmarkParamInfo `json:"params"`
	ReportAllocs       bool                 `json:"reportAllocs"`
	RunParallel        bool                 `json:"runParallel"`
	TableSubBench      bool                 `json:"tableSubBench"`
	PreviewCode        string               `json:"previewCode"`
	NewContent         string               `json:"newContent"`
	TargetFile         string               `json:"targetFile"`
	IsExistingTestFile bool                 `json:"isExistingTestFile"`
	Error              string               `json:"error,omitempty"`
}

type benchParamSpec struct {
	rawName    string
	safeField  string
	typeExpr   string
	fieldType  string
	sampleExpr string
	isVariadic bool
}

type benchResultSpec struct {
	typeExpr string
	isError  bool
}

type parsedBenchFuncInfo struct {
	displayName  string
	shortName    string
	recvType     string
	recvBaseName string
	recvInitType string
	recvIsStruct bool
	recvTypeArgs []string
	funcCallArgs []string
	typeSubst    map[string]string
	isPtrRecv    bool
	pkgName      string
	filePath     string
	fset         *token.FileSet
	file         *ast.File
	src          []byte
	funcDecl     *ast.FuncDecl
	params       []benchParamSpec
	results      []benchResultSpec
	startLine    int
	endLine      int
	isTarget     bool
}

type benchTypeParamRecord struct {
	fset *token.FileSet
	src  []byte
	tp   *ast.FieldList
}

var benchStdlibImports = map[string]string{
	"testing":  "testing",
	"context":  "context",
	"time":     "time",
	"io":       "io",
	"bytes":    "bytes",
	"strings":  "strings",
	"http":     "net/http",
	"json":     "encoding/json",
	"sql":      "database/sql",
	"slog":     "log/slog",
	"url":      "net/url",
	"filepath": "path/filepath",
	"os":       "os",
	"sync":     "sync",
	"atomic":   "sync/atomic",
	"big":      "math/big",
	"rand":     "math/rand",
	"net":      "net",
	"cmp":      "cmp",
	"fmt":      "fmt",
}

type benchStructSpan struct {
	name      string
	filePath  string
	startLine int
	endLine   int
	isTarget  bool
}

func InspectBenchmarkGen(
	dir, filePath, content string,
	line, col int,
	funcName string,
	reportAllocs, runParallel, tableSubBench bool,
) (BenchmarkGenPlan, error) {
	_ = col
	plan := BenchmarkGenPlan{
		AvailableFuncs: []string{},
		Params:         []BenchmarkParamInfo{},
		ReportAllocs:   reportAllocs,
		RunParallel:    runParallel,
		TableSubBench:  tableSubBench,
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

	var allFuncs []*parsedBenchFuncInfo
	var structSpans []benchStructSpan
	structNames := map[string]bool{}
	interfaceNames := map[string]bool{}
	definedBasicTypes := map[string]bool{}
	structTypeParams := map[string]*benchTypeParamRecord{}
	var defaultPkgName string

	collectTypesFromAST := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
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
				tName := ts.Name.Name
				switch ts.Type.(type) {
				case *ast.StructType:
					structNames[tName] = true
					if ts.TypeParams != nil && len(ts.TypeParams.List) > 0 {
						structTypeParams[tName] = &benchTypeParamRecord{
							fset: fset,
							src:  src,
							tp:   ts.TypeParams,
						}
					}
					startLn := fset.Position(ts.Pos()).Line
					endLn := fset.Position(ts.End()).Line
					if len(gd.Specs) == 1 {
						startLn = fset.Position(gd.Pos()).Line
						if gd.Doc != nil {
							startLn = fset.Position(gd.Doc.Pos()).Line
						}
						endLn = fset.Position(gd.End()).Line
					}
					structSpans = append(structSpans, benchStructSpan{
						name:      tName,
						filePath:  fp,
						startLine: startLn,
						endLine:   endLn,
						isTarget:  isTarget,
					})
				case *ast.InterfaceType:
					interfaceNames[tName] = true
				default:
					definedBasicTypes[tName] = true
				}
			}
		}
	}

	collectFuncsFromAST := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
		pkg := f.Name.Name
		if defaultPkgName == "" || (strings.HasSuffix(defaultPkgName, "_test") && !strings.HasSuffix(pkg, "_test")) {
			defaultPkgName = pkg
		} else if pkg != defaultPkgName && strings.TrimSuffix(pkg, "_test") != strings.TrimSuffix(defaultPkgName, "_test") && !isTarget {
			return
		}

		for _, decl := range f.Decls {
			d, ok := decl.(*ast.FuncDecl)
			if !ok || d.Name == nil || d.Name.Name == "" || d.Type == nil {
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

			info := &parsedBenchFuncInfo{
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

	type parsedFileEntry struct {
		fset     *token.FileSet
		file     *ast.File
		src      []byte
		filePath string
		isTarget bool
	}
	var parsedEntries []parsedFileEntry

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
		parsedEntries = append(parsedEntries, parsedFileEntry{
			fset:     fset,
			file:     f,
			src:      srcBytes,
			filePath: cleanFile,
			isTarget: true,
		})
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
			if strings.HasSuffix(gf, benchGoTestFileSuffix) && (cleanFile == "" || !sameFilePath(gf, cleanFile)) {
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
			if !isTarget && !buildTagsCompatible(targetSrc, otherSrc) {
				continue
			}
			parsedEntries = append(parsedEntries, parsedFileEntry{
				fset:     otherFset,
				file:     otherFile,
				src:      otherSrc,
				filePath: gf,
				isTarget: isTarget,
			})
		}
	}

	for _, entry := range parsedEntries {
		collectTypesFromAST(entry.fset, entry.file, entry.src, entry.filePath, entry.isTarget)
	}
	for _, entry := range parsedEntries {
		collectFuncsFromAST(entry.fset, entry.file, entry.src, entry.filePath, entry.isTarget)
	}
	for _, fn := range allFuncs {
		finalizeBenchFuncInfo(fn, structTypeParams, structNames, interfaceNames, definedBasicTypes)
	}

	if len(allFuncs) == 0 {
		err := fmt.Errorf("no benchmarkable functions found in file or package")
		plan.Error = err.Error()
		return plan, err
	}

	var candidates []*parsedBenchFuncInfo
	for _, fn := range allFuncs {
		if fn.isTarget {
			candidates = append(candidates, fn)
		}
	}
	for _, fn := range allFuncs {
		if !fn.isTarget {
			candidates = append(candidates, fn)
		}
	}

	seenDisplay := map[string]bool{}
	var availableNames []string
	for _, fn := range candidates {
		if !seenDisplay[fn.displayName] {
			seenDisplay[fn.displayName] = true
			availableNames = append(availableNames, fn.displayName)
		}
	}
	plan.AvailableFuncs = availableNames

	var selected *parsedBenchFuncInfo
	reqFunc := strings.TrimSpace(funcName)
	if reqFunc != "" {
		selected = matchBenchFuncByName(candidates, reqFunc)
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
					if cand.recvBaseName == st.name {
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
			if !cand.isTarget {
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

	benchmarkName := buildBenchmarkFuncName(selected)
	paramItems := make([]BenchmarkParamInfo, 0, len(selected.params))
	for _, p := range selected.params {
		paramItems = append(paramItems, BenchmarkParamInfo{
			Name:       p.rawName,
			Type:       p.typeExpr,
			SampleExpr: p.sampleExpr,
		})
	}

	previewCode, extraImports := buildBenchmarkPreviewCode(benchmarkPreviewSpec{
		fn:                selected,
		benchmarkName:     benchmarkName,
		reportAllocs:      reportAllocs,
		runParallel:       runParallel,
		tableSubBench:     tableSubBench,
		structNames:       structNames,
		interfaceNames:    interfaceNames,
		definedBasicTypes: definedBasicTypes,
	})
	targetFile := resolveBenchmarkTargetTestFile(selected.filePath, cleanFile, cleanDir)
	if targetFile != "" && (cleanFile == "" || !sameFilePath(targetFile, cleanFile)) {
		if existingData, readErr := readSourceFile(targetFile); readErr == nil && len(existingData) > 0 {
			if ef, pErr := parser.ParseFile(token.NewFileSet(), targetFile, existingData, parser.PackageClauseOnly); pErr == nil && ef != nil && ef.Name != nil {
				if strings.HasSuffix(ef.Name.Name, "_test") && !strings.HasSuffix(pkgName, "_test") {
					targetFile = strings.TrimSuffix(targetFile, benchGoTestFileSuffix) + "_bench" + benchGoTestFileSuffix
				}
			}
		}
	}
	newContent, isExisting := buildBenchmarkTestFileContent(
		targetFile,
		cleanFile,
		content,
		selected.src,
		pkgName,
		benchmarkName,
		previewCode,
		extraImports,
	)

	plan.PackageName = pkgName
	plan.TargetFunc = selected.displayName
	plan.ReceiverType = selected.recvType
	plan.BenchmarkName = benchmarkName
	plan.Params = paramItems
	plan.PreviewCode = previewCode
	plan.NewContent = newContent
	plan.TargetFile = targetFile
	plan.IsExistingTestFile = isExisting
	return plan, nil
}

func finalizeBenchFuncInfo(
	fn *parsedBenchFuncInfo,
	structTypeParams map[string]*benchTypeParamRecord,
	structNames, interfaceNames, definedBasicTypes map[string]bool,
) {
	if fn == nil || fn.funcDecl == nil || fn.funcDecl.Type == nil {
		return
	}
	typeSubst := map[string]string{}
	if fn.recvBaseName != "" {
		if structNames[fn.recvBaseName] {
			fn.recvIsStruct = true
		} else if !definedBasicTypes[fn.recvBaseName] && !interfaceNames[fn.recvBaseName] {
			fn.recvIsStruct = true
		}
		fn.recvInitType = fn.recvBaseName
		if len(fn.recvTypeArgs) > 0 {
			var witnessArgs []string
			if rec, ok := structTypeParams[fn.recvBaseName]; ok && rec != nil {
				witnessArgs, _ = buildGenericWitnessArgs(rec.fset, rec.src, rec.tp, interfaceNames)
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
		funcArgs, funcSubst := buildGenericWitnessArgs(fn.fset, fn.src, fn.funcDecl.Type.TypeParams, interfaceNames)
		fn.funcCallArgs = funcArgs
		for k, v := range funcSubst {
			typeSubst[k] = v
		}
	}
	fn.typeSubst = typeSubst
	fn.params = parseBenchFuncParams(fn.fset, fn.src, fn.funcDecl.Type.Params, typeSubst, structNames, interfaceNames, definedBasicTypes)
	fn.results = parseBenchFuncResults(fn.fset, fn.src, fn.funcDecl.Type.Results, typeSubst)
}

func parseBenchFuncParams(
	fset *token.FileSet,
	src []byte,
	fl *ast.FieldList,
	typeSubst map[string]string,
	structNames, interfaceNames, definedBasicTypes map[string]bool,
) []benchParamSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var params []benchParamSpec
	usedFields := map[string]bool{
		"name": true,
	}
	argIdx := 0

	nextSafeField := func(raw string) string {
		cand := sanitizeParamIdent(raw)
		if cand == "" || cand == "_" || isGoKeyword(cand) || usedFields[cand] {
			if cand != "" && cand != "_" && !isGoKeyword(cand) {
				cand = cand + "Param"
			} else {
				cand = fmt.Sprintf("arg%d", argIdx)
			}
		}
		base := cand
		for suffix := 2; usedFields[cand]; suffix++ {
			cand = fmt.Sprintf("%s%d", base, suffix)
		}
		usedFields[cand] = true
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
		fieldType := typeExpr
		if ellipsis, ok := field.Type.(*ast.Ellipsis); ok {
			isVariadic = true
			eltStr := strings.TrimSpace(astExprString(fset, src, ellipsis.Elt))
			if len(typeSubst) > 0 {
				eltStr = substituteTypeExprString(eltStr, typeSubst)
			}
			typeExpr = "..." + eltStr
			fieldType = "[]" + eltStr
		}
		sampleExpr := sampleExprForBenchType(fieldType, 0, structNames, interfaceNames, definedBasicTypes)

		if len(field.Names) == 0 {
			safe := nextSafeField(fmt.Sprintf("arg%d", argIdx))
			params = append(params, benchParamSpec{
				rawName:    safe,
				safeField:  safe,
				typeExpr:   typeExpr,
				fieldType:  fieldType,
				sampleExpr: sampleExpr,
				isVariadic: isVariadic,
			})
			continue
		}

		for _, ident := range field.Names {
			raw := ""
			if ident != nil {
				raw = ident.Name
			}
			safe := nextSafeField(raw)
			displayParam := raw
			if displayParam == "" || displayParam == "_" {
				displayParam = safe
			}
			params = append(params, benchParamSpec{
				rawName:    displayParam,
				safeField:  safe,
				typeExpr:   typeExpr,
				fieldType:  fieldType,
				sampleExpr: sampleExpr,
				isVariadic: isVariadic,
			})
		}
	}
	return params
}

func parseBenchFuncResults(fset *token.FileSet, src []byte, fl *ast.FieldList, typeSubst map[string]string) []benchResultSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var results []benchResultSpec
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
			results = append(results, benchResultSpec{
				typeExpr: typeExpr,
				isError:  isErr,
			})
		}
	}
	return results
}

func matchBenchFuncByName(list []*parsedBenchFuncInfo, query string) *parsedBenchFuncInfo {
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

func buildBenchmarkFuncName(fn *parsedBenchFuncInfo) string {
	if fn == nil {
		return "BenchmarkTarget"
	}
	if fn.recvBaseName != "" {
		return fmt.Sprintf("Benchmark%s_%s", exportIdent(fn.recvBaseName), fn.shortName)
	}
	return "Benchmark" + exportIdent(fn.shortName)
}

func sampleExprForBenchType(
	typeStr string,
	variant int,
	structNames, interfaceNames, definedBasicTypes map[string]bool,
) string {
	t := strings.TrimSpace(typeStr)
	switch t {
	case "string":
		switch variant {
		case 1:
			return `"sample_medium"`
		case 2:
			return `"sample_large_payload"`
		default:
			return `"sample"`
		}
	case "[]byte", "[]uint8":
		switch variant {
		case 1:
			return `[]byte("sample_medium")`
		case 2:
			return `[]byte("sample_large_payload")`
		default:
			return `[]byte("sample")`
		}
	case "[]string":
		switch variant {
		case 1:
			return `[]string{"alpha", "beta", "gamma", "delta"}`
		case 2:
			return `[]string{"item1", "item2", "item3", "item4", "item5"}`
		default:
			return `[]string{"a", "b", "c"}`
		}
	case "[]int":
		switch variant {
		case 1:
			return `[]int{10, 20, 30, 40, 50}`
		case 2:
			return `[]int{100, 200, 300, 400, 500}`
		default:
			return `[]int{1, 2, 3}`
		}
	case "int":
		switch variant {
		case 1:
			return "1000"
		case 2:
			return "10000"
		default:
			return "100"
		}
	case "int8":
		switch variant {
		case 1:
			return "int8(50)"
		case 2:
			return "int8(100)"
		default:
			return "int8(10)"
		}
	case "int16", "int32", "int64", "uint16", "uint32", "uint64", "uintptr":
		switch variant {
		case 1:
			return fmt.Sprintf("%s(1000)", t)
		case 2:
			return fmt.Sprintf("%s(10000)", t)
		default:
			return fmt.Sprintf("%s(100)", t)
		}
	case "uint":
		switch variant {
		case 1:
			return "uint(1000)"
		case 2:
			return "uint(10000)"
		default:
			return "uint(100)"
		}
	case "uint8":
		switch variant {
		case 1:
			return "uint8(100)"
		case 2:
			return "uint8(200)"
		default:
			return "uint8(10)"
		}
	case "float32":
		switch variant {
		case 1:
			return "float32(42.5)"
		case 2:
			return "float32(1024.75)"
		default:
			return "float32(3.14)"
		}
	case "float64":
		switch variant {
		case 1:
			return "42.5"
		case 2:
			return "1024.75"
		default:
			return "3.14"
		}
	case "bool":
		if variant == 1 {
			return "false"
		}
		return "true"
	case "byte":
		switch variant {
		case 1:
			return "byte('m')"
		case 2:
			return "byte('z')"
		default:
			return "byte('a')"
		}
	case "rune":
		switch variant {
		case 1:
			return "rune('Z')"
		case 2:
			return "rune('λ')"
		default:
			return "rune('a')"
		}
	case "context.Context":
		return "context.Background()"
	case "time.Duration":
		switch variant {
		case 1:
			return "time.Second"
		case 2:
			return "5 * time.Second"
		default:
			return "100 * time.Millisecond"
		}
	case "time.Time":
		return "time.Unix(1700000000, 0)"
	case "map[string]string":
		switch variant {
		case 1:
			return `map[string]string{"a": "1", "b": "2"}`
		case 2:
			return `map[string]string{"x": "alpha", "y": "beta", "z": "gamma"}`
		default:
			return `map[string]string{"key": "value"}`
		}
	case "map[string]int":
		switch variant {
		case 1:
			return `map[string]int{"a": 10, "b": 20}`
		case 2:
			return `map[string]int{"x": 100, "y": 200, "z": 300}`
		default:
			return `map[string]int{"key": 100}`
		}
	}

	if strings.HasPrefix(t, "[]") || strings.HasPrefix(t, "map[") {
		return fmt.Sprintf("%s{}", t)
	}
	if strings.HasPrefix(t, "*") {
		elem := strings.TrimSpace(strings.TrimPrefix(t, "*"))
		elemBase := strings.SplitN(elem, "[", 2)[0]
		if structNames[elemBase] {
			return fmt.Sprintf("&%s{}", elem)
		}
		if elem != "" {
			return fmt.Sprintf("new(%s)", elem)
		}
		return "nil"
	}
	if t == "error" || t == "any" ||
		strings.HasPrefix(t, "interface") ||
		strings.HasPrefix(t, "func(") ||
		strings.HasPrefix(t, "chan ") ||
		strings.HasPrefix(t, "<-chan") ||
		strings.HasPrefix(t, "chan<-") ||
		interfaceNames[t] {
		return "nil"
	}
	baseT := strings.SplitN(t, "[", 2)[0]
	if structNames[baseT] {
		return fmt.Sprintf("%s{}", t)
	}
	return fmt.Sprintf("*new(%s)", t)
}

func isSimpleBenchIdent(s string) bool {
	if s == "" || isGoKeyword(s) {
		return false
	}
	for i, r := range s {
		if i == 0 {
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_') {
				return false
			}
		} else {
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_') {
				return false
			}
		}
	}
	return true
}

type benchmarkPreviewSpec struct {
	fn                *parsedBenchFuncInfo
	benchmarkName     string
	reportAllocs      bool
	runParallel       bool
	tableSubBench     bool
	structNames       map[string]bool
	interfaceNames    map[string]bool
	definedBasicTypes map[string]bool
}

func buildBenchmarkPreviewCode(spec benchmarkPreviewSpec) (string, []requiredImportSpec) {
	fn := spec.fn
	benchmarkName := spec.benchmarkName
	reportAllocs := spec.reportAllocs
	runParallel := spec.runParallel
	tableSubBench := spec.tableSubBench
	structNames := spec.structNames
	interfaceNames := spec.interfaceNames
	definedBasicTypes := spec.definedBasicTypes
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

	bVar := allocLocal("b")
	iVar := allocLocal("i")
	bmVar := allocLocal("bm")
	pbVar := allocLocal("pb")
	benchmarksVar := allocLocal("benchmarks")
	targetVar := "target"
	if fn.recvBaseName != "" {
		targetVar = allocLocal("target")
	}

	callTarget := fn.shortName
	if fn.recvBaseName != "" {
		callTarget = targetVar + "." + fn.shortName
	} else if len(fn.funcCallArgs) > 0 {
		callTarget = fmt.Sprintf("%s[%s]", fn.shortName, strings.Join(fn.funcCallArgs, ", "))
	}

	formatCallStmt := func(indent string, args []string) string {
		callExpr := fmt.Sprintf("%s(%s)", callTarget, strings.Join(args, ", "))
		if len(fn.results) == 0 {
			return fmt.Sprintf("%s%s\n", indent, callExpr)
		}
		blanks := make([]string, len(fn.results))
		for i := range blanks {
			blanks[i] = "_"
		}
		return fmt.Sprintf("%s%s = %s\n", indent, strings.Join(blanks, ", "), callExpr)
	}

	writeTargetInit := func(indent string) {
		if fn.recvBaseName == "" {
			return
		}
		recvInit := fn.recvInitType
		if recvInit == "" {
			recvInit = fn.recvBaseName
		}
		if fn.recvIsStruct {
			if fn.isPtrRecv {
				_, _ = fmt.Fprintf(&buf, "%s%s := &%s{}\n", indent, targetVar, recvInit)
			} else {
				_, _ = fmt.Fprintf(&buf, "%s%s := %s{}\n", indent, targetVar, recvInit)
			}
		} else {
			_, _ = fmt.Fprintf(&buf, "%svar %s %s\n", indent, targetVar, recvInit)
		}
	}

	writeLoopBody := func(indent string, args []string) {
		writeTargetInit(indent)
		if reportAllocs {
			_, _ = fmt.Fprintf(&buf, "%s%s.ReportAllocs()\n", indent, bVar)
			_, _ = fmt.Fprintf(&buf, "%s%s.ResetTimer()\n", indent, bVar)
		}
		if runParallel {
			_, _ = fmt.Fprintf(&buf, "%s%s.RunParallel(func(%s *%s.PB) {\n", indent, bVar, pbVar, testingPkg)
			_, _ = fmt.Fprintf(&buf, "%s\tfor %s.Next() {\n", indent, pbVar)
			buf.WriteString(formatCallStmt(indent+"\t\t", args))
			_, _ = fmt.Fprintf(&buf, "%s\t}\n", indent)
			_, _ = fmt.Fprintf(&buf, "%s})\n", indent)
		} else {
			_, _ = fmt.Fprintf(&buf, "%sfor %s := 0; %s < %s.N; %s++ {\n", indent, iVar, iVar, bVar, iVar)
			buf.WriteString(formatCallStmt(indent+"\t", args))
			_, _ = fmt.Fprintf(&buf, "%s}\n", indent)
		}
	}

	_, _ = fmt.Fprintf(&buf, "func %s(%s *%s.B) {\n", benchmarkName, bVar, testingPkg)

	if tableSubBench {
		_, _ = fmt.Fprintf(&buf, "\t%s := []struct {\n", benchmarksVar)
		_, _ = fmt.Fprintf(&buf, "\t\tname string\n")
		for _, p := range fn.params {
			_, _ = fmt.Fprintf(&buf, "\t\t%s %s\n", p.safeField, p.fieldType)
		}
		_, _ = fmt.Fprintf(&buf, "\t}{\n")

		caseLabels := []string{"small", "medium", "large"}
		if len(fn.params) == 0 {
			caseLabels = []string{"baseline", "warmup"}
		}
		for idx, label := range caseLabels {
			var fields []string
			fields = append(fields, fmt.Sprintf("name: %q", label))
			for _, p := range fn.params {
				val := p.sampleExpr
				if idx > 0 {
					val = sampleExprForBenchType(p.fieldType, idx, structNames, interfaceNames, definedBasicTypes)
				}
				fields = append(fields, fmt.Sprintf("%s: %s", p.safeField, val))
			}
			_, _ = fmt.Fprintf(&buf, "\t\t{%s},\n", strings.Join(fields, ", "))
		}
		_, _ = fmt.Fprintf(&buf, "\t}\n")
		_, _ = fmt.Fprintf(&buf, "\tfor _, %s := range %s {\n", bmVar, benchmarksVar)
		_, _ = fmt.Fprintf(&buf, "\t\t%s.Run(%s.name, func(%s *%s.B) {\n", bVar, bmVar, bVar, testingPkg)

		var bmArgs []string
		for _, p := range fn.params {
			arg := bmVar + "." + p.safeField
			if p.isVariadic {
				arg += "..."
			}
			bmArgs = append(bmArgs, arg)
		}
		writeLoopBody("\t\t\t", bmArgs)

		_, _ = fmt.Fprintf(&buf, "\t\t})\n")
		_, _ = fmt.Fprintf(&buf, "\t}\n")
	} else {
		var directArgs []string
		for _, p := range fn.params {
			arg := p.sampleExpr
			if p.isVariadic {
				arg += "..."
			}
			directArgs = append(directArgs, arg)
		}
		writeLoopBody("\t", directArgs)
	}

	_, _ = fmt.Fprintf(&buf, "}")

	raw := buf.String()
	previewCode := raw
	if formatted, err := format.Source([]byte(raw)); err == nil {
		previewCode = strings.TrimSpace(string(formatted))
	}
	extraImports := inferBenchmarkExtraImports(fn, previewCode)
	return previewCode, extraImports
}

func inferBenchmarkExtraImports(fn *parsedBenchFuncInfo, previewCode string) []requiredImportSpec {
	var files []*ast.File
	if fn != nil && fn.file != nil {
		files = []*ast.File{fn.file}
	}
	specs := collectUsedImportSpecsFromAST(files, previewCode, benchStdlibImports)
	sort.Slice(specs, func(i, j int) bool {
		if specs[i].Path != specs[j].Path {
			return specs[i].Path < specs[j].Path
		}
		return specs[i].Alias < specs[j].Alias
	})
	return specs
}

func resolveBenchmarkTargetTestFile(selectedFile, cleanFile, cleanDir string) string {
	baseFile := selectedFile
	if baseFile == "" {
		baseFile = cleanFile
	}
	if baseFile != "" {
		if strings.HasSuffix(baseFile, benchGoTestFileSuffix) {
			return baseFile
		}
		if strings.HasSuffix(baseFile, ".go") {
			return strings.TrimSuffix(baseFile, ".go") + benchGoTestFileSuffix
		}
		return baseFile + benchGoTestFileSuffix
	}
	if cleanDir != "" {
		return filepath.Join(cleanDir, "bench_test.go")
	}
	return "bench_test.go"
}

func buildBenchmarkTestFileContent(
	targetFile, cleanFile, currentContent string,
	selectedSrc []byte,
	pkgName, benchmarkName, previewCode string,
	extraImports []requiredImportSpec,
) (string, bool) {
	requiredSpecs := make([]requiredImportSpec, 0, len(extraImports)+1)
	hasTesting := false
	for _, s := range extraImports {
		if s.Path == "testing" {
			hasTesting = true
		}
		requiredSpecs = append(requiredSpecs, s)
	}
	if !hasTesting {
		requiredSpecs = append([]requiredImportSpec{{Path: "testing"}}, requiredSpecs...)
	}

	var existingBytes []byte
	isExisting := false
	if cleanFile != "" && sameFilePath(targetFile, cleanFile) && strings.TrimSpace(currentContent) != "" {
		existingBytes = []byte(currentContent)
		isExisting = true
	} else if targetFile != "" {
		if data, err := readSourceFile(targetFile); err == nil && len(data) > 0 {
			existingBytes = data
			isExisting = true
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
				if ok && fd.Recv == nil && fd.Name != nil && fd.Name.Name == benchmarkName {
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
				return string(formatted), isExisting
			}
			return withImports, isExisting
		}
	}

	var buf bytes.Buffer
	_, dirs := extractFileBuildConstraint(selectedSrc)
	if len(dirs) == 0 {
		dirs = extractFileBuildDirectives(cleanFile, currentContent)
	}
	for _, dir := range dirs {
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
		return string(formatted), isExisting
	}
	return raw, isExisting
}

func extractFileBuildDirectives(filePath, currentContent string) []string {
	var src []byte
	if strings.TrimSpace(currentContent) != "" {
		src = []byte(currentContent)
	} else if filePath != "" {
		if data, err := readSourceFile(filePath); err == nil {
			src = data
		}
	}
	if len(src) == 0 {
		return nil
	}
	var directives []string
	lines := strings.Split(string(src), "\n")
	for _, l := range lines {
		trim := strings.TrimSpace(l)
		if strings.HasPrefix(trim, "//go:build ") || strings.HasPrefix(trim, "// +build ") {
			directives = append(directives, trim)
		} else if trim != "" && !strings.HasPrefix(trim, "//") {
			break
		}
	}
	return directives
}
