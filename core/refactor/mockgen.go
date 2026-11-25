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

const (
	stdInterfaceIOReader = "io.Reader"
	stdTypeByteSlice     = "[]byte"
	stdInterfaceIOWriter = "io.Writer"
	stdInterfaceIOCloser = "io.Closer"
)

type MockGenResult struct {
	PackageName         string   `json:"packageName"`
	InterfaceName       string   `json:"interfaceName"`
	MockName            string   `json:"mockName"`
	AvailableInterfaces []string `json:"availableInterfaces"`
	MethodCount         int      `json:"methodCount"`
	GeneratedCode       string   `json:"generatedCode"`
	StandaloneFileCode  string   `json:"standaloneFileCode"`
	SuggestedFileName   string   `json:"suggestedFileName"`
	Error               string   `json:"error,omitempty"`
}

var OverlayReader func(path string) ([]byte, error)

type parsedInterfaceInfo struct {
	name           string
	pkgName        string
	filePath       string
	fset           *token.FileSet
	file           *ast.File
	src            []byte
	ifaceType      *ast.InterfaceType
	typeParamsDecl string
	typeParamsUse  string
	typeParamNames []string
	startLine      int
	endLine        int
}

var mockStdlibImports = map[string]string{
	"sync":    "sync",
	"context": "context",
	"io":      "io",
	"fmt":     "fmt",
	"http":    "net/http",
	"json":    "encoding/json",
	"sql":     "database/sql",
	"time":    "time",
	"bytes":   "bytes",
	"strings": "strings",
	"errors":  "errors",
}

type parsedStructInfo struct {
	name      string
	filePath  string
	startLine int
	endLine   int
	methods   map[string]bool
}

type mockParamSpec struct {
	name       string
	fieldName  string
	typeExpr   string
	sliceType  string
	isVariadic bool
}

type mockResultSpec struct {
	typeExpr string
	zeroExpr string
}

type mockMethodSpec struct {
	name    string
	params  []mockParamSpec
	results []mockResultSpec
}

type importSpecInfo struct {
	alias string
	path  string
	raw   string
}

func readSourceFile(path string) ([]byte, error) {
	if OverlayReader != nil {
		if data, err := OverlayReader(path); err == nil && len(data) > 0 {
			return data, nil
		}
	}
	return os.ReadFile(path)
}

func GenerateInterfaceMock(dir string, filePath string, line int, _ int, interfaceName string, mockName string) (*MockGenResult, error) {
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
	if cleanDir == "" {
		return nil, fmt.Errorf("missing package directory")
	}

	searchDir := cleanDir
	if cleanFile != "" {
		fileDir := filepath.Dir(cleanFile)
		if info, err := os.Stat(fileDir); err == nil && info.IsDir() {
			searchDir = fileDir
		}
	}

	goFiles := collectPackageGoFiles(searchDir, cleanFile)
	if len(goFiles) == 0 && cleanDir != searchDir {
		goFiles = collectPackageGoFiles(cleanDir, cleanFile)
	}

	var targetSrc []byte
	if cleanFile != "" {
		if data, err := readSourceFile(cleanFile); err == nil {
			targetSrc = data
		}
	}

	var interfaces []*parsedInterfaceInfo
	interfaceByName := map[string]*parsedInterfaceInfo{}
	var availableNames []string
	var structs []*parsedStructInfo
	structByName := map[string]*parsedStructInfo{}
	receiverMethods := map[string]map[string]bool{}
	var defaultPkgName string
	var filePkgName string

	for _, gf := range goFiles {
		isTargetFile := cleanFile != "" && sameFilePath(gf, cleanFile)
		if !isTargetFile && strings.HasSuffix(gf, "_test.go") {
			continue
		}
		src, err := readSourceFile(gf)
		if err != nil {
			continue
		}
		if !isTargetFile && !buildTagsCompatible(targetSrc, src) {
			continue
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, gf, src, parser.ParseComments)
		if f == nil || f.Name == nil {
			continue
		}
		pkg := f.Name.Name
		if defaultPkgName == "" || (strings.HasSuffix(defaultPkgName, "_test") && !strings.HasSuffix(pkg, "_test")) {
			defaultPkgName = pkg
		} else if pkg != defaultPkgName && strings.TrimSuffix(pkg, "_test") != strings.TrimSuffix(defaultPkgName, "_test") && !isTargetFile {
			continue
		}
		if isTargetFile {
			filePkgName = pkg
		}

		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if d.Tok != token.TYPE {
					continue
				}
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || ts.Name == nil {
						continue
					}
					startPos := fset.Position(ts.Pos()).Line
					endPos := fset.Position(ts.End()).Line
					if len(d.Specs) == 1 {
						startPos = fset.Position(d.Pos()).Line
						if d.Doc != nil {
							startPos = fset.Position(d.Doc.Pos()).Line
						}
						endPos = fset.Position(d.End()).Line
					}

					switch t := ts.Type.(type) {
					case *ast.InterfaceType:
						tpDecl, tpUse, tpNames, _ := extractTypeParamInfo(fset, src, ts.TypeParams)
						info := &parsedInterfaceInfo{
							name:           ts.Name.Name,
							pkgName:        pkg,
							filePath:       gf,
							fset:           fset,
							file:           f,
							src:            src,
							ifaceType:      t,
							typeParamsDecl: tpDecl,
							typeParamsUse:  tpUse,
							typeParamNames: tpNames,
							startLine:      startPos,
							endLine:        endPos,
						}
						interfaces = append(interfaces, info)
						if _, exists := interfaceByName[info.name]; !exists {
							interfaceByName[info.name] = info
							availableNames = append(availableNames, info.name)
						}
					case *ast.StructType:
						st := &parsedStructInfo{
							name:      ts.Name.Name,
							filePath:  gf,
							startLine: startPos,
							endLine:   endPos,
							methods:   map[string]bool{},
						}
						structs = append(structs, st)
						structByName[st.name] = st
					}
				}
			case *ast.FuncDecl:
				if d.Recv != nil && len(d.Recv.List) > 0 && d.Name != nil {
					recvName := extractReceiverTypeName(d.Recv.List[0].Type)
					if recvName != "" {
						if receiverMethods[recvName] == nil {
							receiverMethods[recvName] = map[string]bool{}
						}
						receiverMethods[recvName][d.Name.Name] = true
					}
				}
			}
		}
	}

	for name, methods := range receiverMethods {
		if st, ok := structByName[name]; ok {
			for m := range methods {
				st.methods[m] = true
			}
		}
	}

	if len(interfaces) == 0 {
		return nil, fmt.Errorf("no interfaces found in package")
	}

	var selected *parsedInterfaceInfo
	reqIface := strings.TrimSpace(interfaceName)
	if reqIface != "" {
		if match, ok := interfaceByName[reqIface]; ok {
			selected = match
		} else {
			for _, cand := range interfaces {
				if strings.EqualFold(cand.name, reqIface) {
					selected = cand
					break
				}
			}
			if selected == nil {
				return nil, fmt.Errorf("interface %q not found in package", reqIface)
			}
		}
	}

	if selected == nil && cleanFile != "" && line > 0 {
		for _, cand := range interfaces {
			if sameFilePath(cand.filePath, cleanFile) && line >= cand.startLine && line <= cand.endLine {
				selected = cand
				break
			}
		}
	}

	if selected == nil && cleanFile != "" && line > 0 {
		for _, st := range structs {
			if sameFilePath(st.filePath, cleanFile) && line >= st.startLine && line <= st.endLine {
				if matched := matchInterfaceForStruct(st, interfaces, interfaceByName); matched != nil {
					selected = matched
					break
				}
			}
		}
	}

	if selected == nil && cleanFile != "" {
		var bestInFile *parsedInterfaceInfo
		bestDist := int(^uint(0) >> 1)
		for _, cand := range interfaces {
			if sameFilePath(cand.filePath, cleanFile) {
				if bestInFile == nil {
					bestInFile = cand
				}
				if line > 0 {
					dist := absInt(line - cand.startLine)
					if dist < bestDist {
						bestDist = dist
						bestInFile = cand
					}
				}
			}
		}
		selected = bestInFile
	}

	if selected == nil {
		selected = interfaces[0]
	}

	pkgName := selected.pkgName
	if pkgName == "" {
		if filePkgName != "" {
			pkgName = filePkgName
		} else {
			pkgName = defaultPkgName
		}
	}
	if strings.HasSuffix(pkgName, "_test") && defaultPkgName != "" && !strings.HasSuffix(defaultPkgName, "_test") {
		pkgName = defaultPkgName
	}

	resolvedMockName := strings.TrimSpace(mockName)
	if resolvedMockName == "" {
		resolvedMockName = "Mock" + selected.name
	}

	knownInterfaces := map[string]bool{}
	for _, name := range availableNames {
		knownInterfaces[name] = true
	}

	methods, usedFiles := resolveInterfaceMethods(selected, interfaceByName, knownInterfaces, map[string]bool{})
	snippetCode := strings.TrimSpace(buildMockSnippet(selected, resolvedMockName, methods, usedFiles))
	standaloneCode := buildStandaloneMockFile(pkgName, selected, usedFiles, snippetCode)

	suggestedFile := fmt.Sprintf("mock_%s_test.go", strings.ToLower(selected.name))

	return &MockGenResult{
		PackageName:         pkgName,
		InterfaceName:       selected.name,
		MockName:            resolvedMockName,
		AvailableInterfaces: availableNames,
		MethodCount:         len(methods),
		GeneratedCode:       snippetCode,
		StandaloneFileCode:  standaloneCode,
		SuggestedFileName:   suggestedFile,
	}, nil
}

func collectPackageGoFiles(dir string, priorityFile string) []string {
	var files []string
	seen := map[string]bool{}

	addFile := func(p string) {
		if p == "" || !strings.HasSuffix(p, ".go") {
			return
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			abs = filepath.Clean(p)
		}
		if seen[abs] {
			return
		}
		seen[abs] = true
		files = append(files, abs)
	}

	if priorityFile != "" && sameFilePath(filepath.Dir(priorityFile), dir) {
		addFile(priorityFile)
	}

	entries, err := os.ReadDir(dir)
	if err == nil {
		var names []string
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".go") {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		for _, name := range names {
			addFile(filepath.Join(dir, name))
		}
	}

	if priorityFile != "" {
		addFile(priorityFile)
	}

	return files
}

func sameFilePath(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA == nil && errB == nil {
		if realA, err1 := filepath.EvalSymlinks(absA); err1 == nil {
			absA = realA
		}
		if realB, err2 := filepath.EvalSymlinks(absB); err2 == nil {
			absB = realB
		}
		return absA == absB
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

func extractReceiverTypeName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return extractReceiverTypeName(t.X)
	case *ast.IndexExpr:
		return extractReceiverTypeName(t.X)
	case *ast.IndexListExpr:
		return extractReceiverTypeName(t.X)
	default:
		return ""
	}
}

func matchInterfaceForStruct(st *parsedStructInfo, interfaces []*parsedInterfaceInfo, byName map[string]*parsedInterfaceInfo) *parsedInterfaceInfo {
	if len(st.methods) == 0 {
		return nil
	}
	var best *parsedInterfaceInfo
	bestOverlap := 0
	for _, iface := range interfaces {
		methods, _ := resolveInterfaceMethods(iface, byName, nil, map[string]bool{})
		overlap := 0
		for _, m := range methods {
			if st.methods[m.name] {
				overlap++
			}
		}
		if overlap > bestOverlap {
			bestOverlap = overlap
			best = iface
		}
	}
	return best
}

func resolveInterfaceMethods(
	info *parsedInterfaceInfo,
	byName map[string]*parsedInterfaceInfo,
	knownInterfaces map[string]bool,
	visited map[string]bool,
) ([]mockMethodSpec, []*ast.File) {
	if info == nil || info.ifaceType == nil || info.ifaceType.Methods == nil {
		return nil, nil
	}
	if visited[info.name] {
		return nil, nil
	}
	visited[info.name] = true

	var methods []mockMethodSpec
	var usedFiles []*ast.File
	seenFile := map[*ast.File]bool{}
	addFile := func(f *ast.File) {
		if f != nil && !seenFile[f] {
			seenFile[f] = true
			usedFiles = append(usedFiles, f)
		}
	}
	addFile(info.file)

	seenMethod := map[string]bool{}
	addMethod := func(m mockMethodSpec) {
		if m.name == "" || seenMethod[m.name] {
			return
		}
		seenMethod[m.name] = true
		methods = append(methods, m)
	}

	reservedExtra := map[string]bool{}
	addReservedPredeclaredTypes(reservedExtra)
	addReservedFileImports(reservedExtra, info.file)
	for _, tp := range info.typeParamNames {
		if tp != "" {
			reservedExtra[tp] = true
		}
	}

	for _, field := range info.ifaceType.Methods.List {
		if len(field.Names) == 0 {
			embeddedName := strings.TrimSpace(astExprString(info.fset, info.src, field.Type))
			embBase, embArgs := splitMockEmbeddedTypeArgs(info.fset, info.src, field.Type)
			if emb, ok := byName[embBase]; ok {
				embMethods, embFiles := resolveInterfaceMethods(emb, byName, knownInterfaces, visited)
				for _, ef := range embFiles {
					addFile(ef)
				}
				childSubst := map[string]string{}
				if len(embArgs) > 0 && len(emb.typeParamNames) > 0 {
					for i, tpName := range emb.typeParamNames {
						if i < len(embArgs) && embArgs[i] != "" {
							childSubst[tpName] = embArgs[i]
						}
					}
				}
				for _, em := range embMethods {
					if len(childSubst) > 0 {
						em = substituteMockMethodTypes(em, childSubst, knownInterfaces)
					}
					addMethod(em)
				}
				continue
			}
			for _, stdM := range stdlibEmbeddedMethods(embeddedName) {
				addMethod(stdM)
			}
			continue
		}

		fnType, ok := field.Type.(*ast.FuncType)
		if !ok {
			continue
		}
		params := parseMockParams(info.fset, info.src, fnType.Params, reservedExtra)
		results := parseMockResults(info.fset, info.src, fnType.Results, knownInterfaces)
		for _, ident := range field.Names {
			if ident == nil || ident.Name == "" {
				continue
			}
			addMethod(mockMethodSpec{
				name:    ident.Name,
				params:  params,
				results: results,
			})
		}
	}

	return methods, usedFiles
}

func splitMockEmbeddedTypeArgs(fset *token.FileSet, src []byte, expr ast.Expr) (string, []string) {
	switch e := expr.(type) {
	case *ast.Ident:
		return e.Name, nil
	case *ast.IndexExpr:
		base := strings.TrimSpace(astExprString(fset, src, e.X))
		arg := strings.TrimSpace(astExprString(fset, src, e.Index))
		return base, []string{arg}
	case *ast.IndexListExpr:
		base := strings.TrimSpace(astExprString(fset, src, e.X))
		args := make([]string, 0, len(e.Indices))
		for _, idx := range e.Indices {
			args = append(args, strings.TrimSpace(astExprString(fset, src, idx)))
		}
		return base, args
	default:
		return strings.TrimSpace(astExprString(fset, src, expr)), nil
	}
}

func substituteMockMethodTypes(m mockMethodSpec, subst map[string]string, knownInterfaces map[string]bool) mockMethodSpec {
	out := mockMethodSpec{
		name:    m.name,
		params:  make([]mockParamSpec, len(m.params)),
		results: make([]mockResultSpec, len(m.results)),
	}
	for i, p := range m.params {
		np := p
		if p.isVariadic {
			elt := strings.TrimPrefix(p.typeExpr, "...")
			subElt := substituteTypeExprString(elt, subst)
			np.typeExpr = "..." + subElt
			np.sliceType = "[]" + subElt
		} else {
			sub := substituteTypeExprString(p.typeExpr, subst)
			np.typeExpr = sub
			np.sliceType = sub
		}
		out.params[i] = np
	}
	for i, r := range m.results {
		sub := substituteTypeExprString(r.typeExpr, subst)
		parsedSub, _ := parser.ParseExpr(sub)
		out.results[i] = mockResultSpec{
			typeExpr: sub,
			zeroExpr: zeroValueForType(parsedSub, sub, knownInterfaces),
		}
	}
	return out
}

func stdlibEmbeddedMethods(name string) []mockMethodSpec {
	switch name {
	case stdInterfaceIOReader, "Reader":
		return []mockMethodSpec{{
			name:    "Read",
			params:  []mockParamSpec{{name: "p", fieldName: "P", typeExpr: stdTypeByteSlice, sliceType: stdTypeByteSlice}},
			results: []mockResultSpec{{typeExpr: "int", zeroExpr: "0"}, {typeExpr: "error", zeroExpr: "nil"}},
		}}
	case stdInterfaceIOWriter, "Writer":
		return []mockMethodSpec{{
			name:    "Write",
			params:  []mockParamSpec{{name: "p", fieldName: "P", typeExpr: stdTypeByteSlice, sliceType: stdTypeByteSlice}},
			results: []mockResultSpec{{typeExpr: "int", zeroExpr: "0"}, {typeExpr: "error", zeroExpr: "nil"}},
		}}
	case stdInterfaceIOCloser, "Closer":
		return []mockMethodSpec{{
			name:    "Close",
			params:  nil,
			results: []mockResultSpec{{typeExpr: "error", zeroExpr: "nil"}},
		}}
	case "io.ReadWriter", "ReadWriter":
		return append(stdlibEmbeddedMethods(stdInterfaceIOReader), stdlibEmbeddedMethods(stdInterfaceIOWriter)...)
	case "io.ReadCloser", "ReadCloser":
		return append(stdlibEmbeddedMethods(stdInterfaceIOReader), stdlibEmbeddedMethods(stdInterfaceIOCloser)...)
	case "io.WriteCloser", "WriteCloser":
		return append(stdlibEmbeddedMethods(stdInterfaceIOWriter), stdlibEmbeddedMethods(stdInterfaceIOCloser)...)
	case "fmt.Stringer", "Stringer":
		return []mockMethodSpec{{
			name:    "String",
			params:  nil,
			results: []mockResultSpec{{typeExpr: "string", zeroExpr: `""`}},
		}}
	case "error":
		return []mockMethodSpec{{
			name:    "Error",
			params:  nil,
			results: []mockResultSpec{{typeExpr: "string", zeroExpr: `""`}},
		}}
	default:
		return nil
	}
}

func parseMockParams(fset *token.FileSet, src []byte, fl *ast.FieldList, reservedExtra map[string]bool) []mockParamSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var params []mockParamSpec
	usedNames := map[string]bool{}
	for k, v := range reservedExtra {
		if v {
			usedNames[k] = true
		}
	}
	usedFieldNames := map[string]bool{}
	argIndex := 0

	nextArgName := func(base string) string {
		candidate := sanitizeParamIdent(base)
		if candidate == "" || candidate == "_" || isGoKeyword(candidate) || candidate == "m" || candidate == "fn" || usedNames[candidate] {
			if candidate != "" && candidate != "_" && !isGoKeyword(candidate) && candidate != "m" && candidate != "fn" {
				candidate = candidate + "Arg"
			} else {
				candidate = fmt.Sprintf("arg%d", argIndex)
			}
		}
		for usedNames[candidate] {
			argIndex++
			candidate = fmt.Sprintf("arg%d", argIndex)
		}
		usedNames[candidate] = true
		argIndex++
		return candidate
	}

	nextFieldName := func(paramName string) string {
		base := exportIdent(paramName)
		if base == "" {
			base = fmt.Sprintf("Arg%d", len(params))
		}
		candidate := base
		suffix := 2
		for usedFieldNames[candidate] {
			candidate = fmt.Sprintf("%s%d", base, suffix)
			suffix++
		}
		usedFieldNames[candidate] = true
		return candidate
	}

	for _, field := range fl.List {
		isVariadic := false
		typeExpr := strings.TrimSpace(astExprString(fset, src, field.Type))
		sliceType := typeExpr
		if ellipsis, ok := field.Type.(*ast.Ellipsis); ok {
			isVariadic = true
			eltStr := strings.TrimSpace(astExprString(fset, src, ellipsis.Elt))
			typeExpr = "..." + eltStr
			sliceType = "[]" + eltStr
		}

		if len(field.Names) == 0 {
			pName := nextArgName(fmt.Sprintf("arg%d", argIndex))
			fName := nextFieldName(pName)
			params = append(params, mockParamSpec{
				name:       pName,
				fieldName:  fName,
				typeExpr:   typeExpr,
				sliceType:  sliceType,
				isVariadic: isVariadic,
			})
			continue
		}

		for _, ident := range field.Names {
			rawName := ""
			if ident != nil {
				rawName = ident.Name
			}
			pName := nextArgName(rawName)
			fName := nextFieldName(pName)
			params = append(params, mockParamSpec{
				name:       pName,
				fieldName:  fName,
				typeExpr:   typeExpr,
				sliceType:  sliceType,
				isVariadic: isVariadic,
			})
		}
	}

	return params
}

func parseMockResults(fset *token.FileSet, src []byte, fl *ast.FieldList, knownInterfaces map[string]bool) []mockResultSpec {
	if fl == nil || len(fl.List) == 0 {
		return nil
	}
	var results []mockResultSpec
	for _, field := range fl.List {
		typeExpr := strings.TrimSpace(astExprString(fset, src, field.Type))
		zeroExpr := zeroValueForType(field.Type, typeExpr, knownInterfaces)
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		for i := 0; i < count; i++ {
			results = append(results, mockResultSpec{
				typeExpr: typeExpr,
				zeroExpr: zeroExpr,
			})
		}
	}
	return results
}

func zeroValueForType(expr ast.Expr, typeStr string, knownInterfaces map[string]bool) string {
	switch t := expr.(type) {
	case *ast.StarExpr, *ast.MapType, *ast.ChanType, *ast.FuncType, *ast.InterfaceType:
		return "nil"
	case *ast.ArrayType:
		if t.Len == nil {
			return "nil"
		}
	}

	trimmed := strings.TrimSpace(typeStr)
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

	switch trimmed {
	case "string":
		return `""`
	case "bool":
		return "false"
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "float32", "float64", "complex64", "complex128",
		"time.Duration":
		return "0"
	case "error", "any", "interface{}", "context.Context",
		stdInterfaceIOReader, stdInterfaceIOWriter, stdInterfaceIOCloser, "io.ReadWriter",
		"io.ReadCloser", "io.WriteCloser", "fmt.Stringer", "http.Handler", "http.ResponseWriter":
		return "nil"
	}

	if knownInterfaces != nil && knownInterfaces[trimmed] {
		return "nil"
	}

	return ""
}

func buildMockSnippet(selected *parsedInterfaceInfo, mockName string, methods []mockMethodSpec, usedFiles []*ast.File) string {
	ifaceName := selected.name
	typeParamsDecl := selected.typeParamsDecl
	typeParamsUse := selected.typeParamsUse

	reservedIdents := map[string]bool{}
	for _, f := range usedFiles {
		addReservedFileImports(reservedIdents, f)
	}
	for _, tp := range selected.typeParamNames {
		if tp != "" {
			reservedIdents[tp] = true
		}
	}
	recvVar := "m"
	if reservedIdents[recvVar] {
		recvVar = "mk"
		for idx := 2; reservedIdents[recvVar]; idx++ {
			recvVar = fmt.Sprintf("mk%d", idx)
		}
	}

	var buf bytes.Buffer

	_, _ = fmt.Fprintf(&buf, "type %s%s struct {\n", mockName, typeParamsDecl)
	_, _ = fmt.Fprintf(&buf, "\tmu sync.Mutex\n")
	for _, m := range methods {
		sig := formatFuncSignature(m.params, m.results)
		_, _ = fmt.Fprintf(&buf, "\t%sFunc func%s\n", m.name, sig)
		if len(m.params) == 0 {
			_, _ = fmt.Fprintf(&buf, "\t%sCalls int\n", m.name)
		} else {
			_, _ = fmt.Fprintf(&buf, "\t%sCalls []struct {\n", m.name)
			for _, p := range m.params {
				_, _ = fmt.Fprintf(&buf, "\t\t%s %s\n", p.fieldName, p.sliceType)
			}
			_, _ = fmt.Fprintf(&buf, "\t}\n")
		}
	}
	_, _ = fmt.Fprintf(&buf, "}\n\n")

	if typeParamsDecl != "" && typeParamsUse != "" {
		_, _ = fmt.Fprintf(&buf, "func New%s%s() *%s%s {\n", mockName, typeParamsDecl, mockName, typeParamsUse)
		_, _ = fmt.Fprintf(&buf, "\tvar _ %s%s = (*%s%s)(nil)\n", ifaceName, typeParamsUse, mockName, typeParamsUse)
		_, _ = fmt.Fprintf(&buf, "\treturn &%s%s{}\n", mockName, typeParamsUse)
		_, _ = fmt.Fprintf(&buf, "}\n")
	} else {
		_, _ = fmt.Fprintf(&buf, "var _ %s = (*%s)(nil)\n", ifaceName, mockName)
	}

	for _, m := range methods {
		methodParams := m.params
		paramUsed := map[string]bool{recvVar: true}
		for k, v := range reservedIdents {
			if v {
				paramUsed[k] = true
			}
		}
		if recvVar != "m" {
			copied := make([]mockParamSpec, len(m.params))
			for i, p := range m.params {
				copied[i] = p
				paramUsed[p.name] = true
			}
			methodParams = copied
		} else {
			for _, p := range m.params {
				paramUsed[p.name] = true
			}
		}

		sig := formatFuncSignature(methodParams, m.results)
		_, _ = fmt.Fprintf(&buf, "\nfunc (%s *%s%s) %s%s {\n", recvVar, mockName, typeParamsUse, m.name, sig)
		_, _ = fmt.Fprintf(&buf, "\t%s.mu.Lock()\n", recvVar)
		if len(methodParams) == 0 {
			_, _ = fmt.Fprintf(&buf, "\t%s.%sCalls++\n", recvVar, m.name)
		} else {
			_, _ = fmt.Fprintf(&buf, "\t%s.%sCalls = append(%s.%sCalls, struct {\n", recvVar, m.name, recvVar, m.name)
			for _, p := range methodParams {
				_, _ = fmt.Fprintf(&buf, "\t\t%s %s\n", p.fieldName, p.sliceType)
			}
			_, _ = fmt.Fprintf(&buf, "\t}{\n")
			for _, p := range methodParams {
				_, _ = fmt.Fprintf(&buf, "\t\t%s: %s,\n", p.fieldName, p.name)
			}
			_, _ = fmt.Fprintf(&buf, "\t})\n")
		}
		_, _ = fmt.Fprintf(&buf, "\t%s.mu.Unlock()\n", recvVar)

		callArgs := formatCallArgs(methodParams)
		if len(m.results) == 0 {
			_, _ = fmt.Fprintf(&buf, "\tif %s.%sFunc != nil {\n", recvVar, m.name)
			_, _ = fmt.Fprintf(&buf, "\t\t%s.%sFunc(%s)\n", recvVar, m.name, callArgs)
			_, _ = fmt.Fprintf(&buf, "\t}\n")
		} else {
			_, _ = fmt.Fprintf(&buf, "\tif %s.%sFunc != nil {\n", recvVar, m.name)
			_, _ = fmt.Fprintf(&buf, "\t\treturn %s.%sFunc(%s)\n", recvVar, m.name, callArgs)
			_, _ = fmt.Fprintf(&buf, "\t}\n")
			var retParts []string
			for i, r := range m.results {
				if r.zeroExpr != "" {
					retParts = append(retParts, r.zeroExpr)
				} else {
					zeroVar := fmt.Sprintf("zero%d", i)
					for paramUsed[zeroVar] {
						zeroVar += "Val"
					}
					paramUsed[zeroVar] = true
					_, _ = fmt.Fprintf(&buf, "\tvar %s %s\n", zeroVar, r.typeExpr)
					retParts = append(retParts, zeroVar)
				}
			}
			_, _ = fmt.Fprintf(&buf, "\treturn %s\n", strings.Join(retParts, ", "))
		}
		_, _ = fmt.Fprintf(&buf, "}\n")
	}

	return buf.String()
}

func buildStandaloneMockFile(pkgName string, selected *parsedInterfaceInfo, usedFiles []*ast.File, snippetCode string) string {
	specs := collectUsedImportSpecsFromAST(usedFiles, snippetCode, mockStdlibImports)
	hasSync := false
	for _, s := range specs {
		if s.Path == "sync" && (s.Alias == "" || s.Alias == "sync") {
			hasSync = true
			break
		}
	}
	if !hasSync {
		specs = append([]requiredImportSpec{{Path: "sync"}}, specs...)
	}
	sort.Slice(specs, func(i, j int) bool {
		if specs[i].Path == "sync" {
			return true
		}
		if specs[j].Path == "sync" {
			return false
		}
		if specs[i].Path != specs[j].Path {
			return specs[i].Path < specs[j].Path
		}
		return specs[i].Alias < specs[j].Alias
	})

	var imports []string
	for _, s := range specs {
		if s.Alias != "" && s.Alias != defaultImportIdentifier(s.Path) {
			imports = append(imports, fmt.Sprintf("%s %q", s.Alias, s.Path))
		} else {
			imports = append(imports, fmt.Sprintf("%q", s.Path))
		}
	}

	var buf bytes.Buffer
	if selected != nil {
		_, dirs := extractFileBuildConstraint(selected.src)
		for _, dir := range dirs {
			buf.WriteString(dir)
			buf.WriteString("\n")
		}
		if len(dirs) > 0 {
			buf.WriteString("\n")
		}
	}
	_, _ = fmt.Fprintf(&buf, "package %s\n\n", pkgName)
	if len(imports) == 1 {
		_, _ = fmt.Fprintf(&buf, "import %s\n\n", imports[0])
	} else {
		_, _ = fmt.Fprintf(&buf, "import (\n")
		for _, imp := range imports {
			_, _ = fmt.Fprintf(&buf, "\t%s\n", imp)
		}
		_, _ = fmt.Fprintf(&buf, ")\n\n")
	}
	buf.WriteString(snippetCode)
	buf.WriteString("\n")
	return buf.String()
}

func formatFuncSignature(params []mockParamSpec, results []mockResultSpec) string {
	var paramParts []string
	for _, p := range params {
		paramParts = append(paramParts, fmt.Sprintf("%s %s", p.name, p.typeExpr))
	}
	paramStr := "(" + strings.Join(paramParts, ", ") + ")"

	if len(results) == 0 {
		return paramStr
	}
	if len(results) == 1 {
		return paramStr + " " + results[0].typeExpr
	}
	var resParts []string
	for _, r := range results {
		resParts = append(resParts, r.typeExpr)
	}
	return paramStr + " (" + strings.Join(resParts, ", ") + ")"
}

func formatCallArgs(params []mockParamSpec) string {
	var args []string
	for _, p := range params {
		if p.isVariadic {
			args = append(args, p.name+"...")
		} else {
			args = append(args, p.name)
		}
	}
	return strings.Join(args, ", ")
}

func astExprString(fset *token.FileSet, src []byte, expr ast.Expr) string {
	if expr == nil || fset == nil {
		return ""
	}
	start := fset.Position(expr.Pos()).Offset
	end := fset.Position(expr.End()).Offset
	if start >= 0 && end >= start && end <= len(src) {
		return string(src[start:end])
	}
	var buf bytes.Buffer
	_ = format.Node(&buf, fset, expr)
	return buf.String()
}

func sanitizeParamIdent(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	var b strings.Builder
	for i, r := range s {
		if unicode.IsLetter(r) || r == '_' || (i > 0 && unicode.IsDigit(r)) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func exportIdent(s string) string {
	s = strings.TrimLeft(s, "_")
	if s == "" {
		return ""
	}
	r, size := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[size:]
}

func isGoKeyword(s string) bool {
	return token.Lookup(s).IsKeyword()
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
