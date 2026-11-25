package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func ListWorkspaceInterfaces(workspaceDir string, currentPath string) string {
	candidates := collectWorkspaceInterfaces(workspaceDir, currentPath, nil)
	b, err := json.Marshal(candidates)
	if err != nil {
		return "[]"
	}
	return string(b)
}

type workspaceInterfaceInfo struct {
	candidate            InterfaceCandidate
	file                 *ast.File
	fset                 *token.FileSet
	src                  []byte
	ifaceType            *ast.InterfaceType
	typeParamNames       []string
	typeParamConstraints []string
	pkgDefinedTypes      map[string]bool
	explicitArgs         []string
}

func collectWorkspaceInterfaces(workspaceDir string, currentPath string, buffers map[string]string) []InterfaceCandidate {
	records := collectWorkspaceInterfaceRecords(workspaceDir, currentPath, buffers)
	out := make([]InterfaceCandidate, 0, len(records))
	for _, r := range records {
		out = append(out, r.candidate)
	}
	return out
}

func collectWorkspaceInterfaceRecords(workspaceDir string, currentPath string, buffers map[string]string) []*workspaceInterfaceInfo {
	readFile := func(p string) ([]byte, error) {
		if buffers != nil {
			if buf, ok := buffers[p]; ok {
				return []byte(buf), nil
			}
		}
		return os.ReadFile(p)
	}

	var targetSrc []byte
	if currentPath != "" {
		if data, err := readFile(currentPath); err == nil {
			targetSrc = data
		}
	}

	modRoot, modPath := resolveGoastModuleRoot(currentPath, workspaceDir)

	visitedFiles := map[string]bool{}
	var goFiles []string

	addGoFile := func(p string) {
		clean := filepath.Clean(p)
		if visitedFiles[clean] {
			return
		}
		if !strings.HasSuffix(clean, ".go") || strings.HasSuffix(clean, goTestFileSuffix) {
			return
		}
		visitedFiles[clean] = true
		goFiles = append(goFiles, clean)
	}

	if currentPath != "" {
		addGoFile(currentPath)
		dir := filepath.Dir(currentPath)
		if entries, err := os.ReadDir(dir); err == nil {
			for _, e := range entries {
				if !e.IsDir() {
					addGoFile(filepath.Join(dir, e.Name()))
				}
			}
		}
	}

	for p := range buffers {
		addGoFile(p)
	}

	if workspaceDir != "" && len(goFiles) < 200 {
		_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				name := d.Name()
				if path != workspaceDir && (strings.HasPrefix(name, ".") || name == "vendor" || name == "node_modules" || name == "build" || name == "testdata" || name == "third_party") {
					return filepath.SkipDir
				}
				return nil
			}
			if len(goFiles) >= 200 {
				return filepath.SkipAll
			}
			if info, statErr := d.Info(); statErr == nil && info.Size() > (1<<20) {
				return nil
			}
			addGoFile(path)
			return nil
		})
	}

	if len(goFiles) > 200 {
		goFiles = goFiles[:200]
	}

	type rawIfaceEntry struct {
		pkg           string
		dir           string
		importPath    string
		name          string
		fset          *token.FileSet
		file          *ast.File
		src           []byte
		ifaceType     *ast.InterfaceType
		tpNames       []string
		tpConstraints []string
	}

	var entries []*rawIfaceEntry
	byPkgAndName := map[string]map[string]*rawIfaceEntry{}
	pkgDefinedTypes := map[string]map[string]bool{}

	for _, p := range goFiles {
		src, err := readFile(p)
		if err != nil || len(src) > (1<<20) {
			continue
		}
		isCurrent := currentPath != "" && filepath.Clean(p) == filepath.Clean(currentPath)
		if !isCurrent && !goastBuildTagsCompatible(targetSrc, src) {
			continue
		}
		fset := token.NewFileSet()
		f, _ := parser.ParseFile(fset, p, src, parser.SkipObjectResolution)
		if f == nil || f.Name == nil {
			continue
		}
		pkgName := f.Name.Name
		if pkgDefinedTypes[pkgName] == nil {
			pkgDefinedTypes[pkgName] = map[string]bool{}
		}
		if byPkgAndName[pkgName] == nil {
			byPkgAndName[pkgName] = map[string]*rawIfaceEntry{}
		}
		impPath := computeGoastImportPath(filepath.Dir(p), modRoot, modPath)

		for _, decl := range f.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, spec := range gd.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil {
					continue
				}
				pkgDefinedTypes[pkgName][ts.Name.Name] = true
				iface, ok := ts.Type.(*ast.InterfaceType)
				if !ok || iface.Methods == nil {
					continue
				}
				_, _, tpNames, tpCons := extractGoastTypeParams(fset, src, ts.TypeParams)
				entry := &rawIfaceEntry{
					pkg:           pkgName,
					dir:           filepath.Dir(p),
					importPath:    impPath,
					name:          ts.Name.Name,
					fset:          fset,
					file:          f,
					src:           src,
					ifaceType:     iface,
					tpNames:       tpNames,
					tpConstraints: tpCons,
				}
				entries = append(entries, entry)
				if _, exists := byPkgAndName[pkgName][entry.name]; !exists {
					byPkgAndName[pkgName][entry.name] = entry
				}
			}
		}
	}

	var resolveEntry func(e *rawIfaceEntry, visited map[string]bool) []string
	resolveEntry = func(e *rawIfaceEntry, visited map[string]bool) []string {
		if e == nil || e.ifaceType == nil || e.ifaceType.Methods == nil {
			return nil
		}
		visitKey := e.pkg + "::" + e.name
		if visited[visitKey] {
			return nil
		}
		visited[visitKey] = true
		defer delete(visited, visitKey)

		seenMethod := map[string]bool{}
		var methods []string
		addMethod := func(sig string) {
			paren := strings.IndexByte(sig, '(')
			if paren <= 0 {
				return
			}
			mName := strings.TrimSpace(sig[:paren])
			if mName == "" || seenMethod[mName] {
				return
			}
			seenMethod[mName] = true
			methods = append(methods, sig)
		}

		for _, field := range e.ifaceType.Methods.List {
			if len(field.Names) == 0 {
				embPkg, embName, embArgs := splitGoastEmbeddedExpr(e.fset, e.src, field.Type)
				targetPkg := e.pkg
				if embPkg != "" {
					targetPkg = embPkg
				}
				var embEntry *rawIfaceEntry
				if pkgMap := byPkgAndName[targetPkg]; pkgMap != nil {
					embEntry = pkgMap[embName]
				}
				if embEntry != nil {
					embMethods := resolveEntry(embEntry, visited)
					subst := map[string]string{}
					for i, tp := range embEntry.tpNames {
						if i < len(embArgs) && embArgs[i] != "" {
							subst[tp] = embArgs[i]
						}
					}
					for _, em := range embMethods {
						if len(subst) > 0 {
							em = substituteGoastMethodSig(em, subst)
						}
						if embEntry.pkg != "" && embEntry.pkg != e.pkg {
							em = qualifyGoastMethodSig(em, embEntry.pkg, pkgDefinedTypes[embEntry.pkg])
						}
						addMethod(em)
					}
					continue
				}
				embeddedName := strings.TrimSpace(exprString(e.fset, e.src, field.Type))
				for _, std := range stdlibInterfaces {
					if std.Name == embeddedName || strings.TrimPrefix(std.Name, std.Package+".") == embeddedName {
						for _, sm := range std.Methods {
							addMethod(sm)
						}
					}
				}
				continue
			}
			fnType, ok := field.Type.(*ast.FuncType)
			if !ok || fnType.Params == nil {
				continue
			}
			startOff := e.fset.Position(fnType.Params.Pos()).Offset
			endOff := e.fset.Position(fnType.End()).Offset
			if startOff < 0 || endOff < startOff || endOff > len(e.src) {
				continue
			}
			sigRest := strings.TrimSpace(string(e.src[startOff:endOff]))
			for _, id := range field.Names {
				if id == nil || id.Name == "" {
					continue
				}
				addMethod(id.Name + sigRest)
			}
		}
		return methods
	}

	var records []*workspaceInterfaceInfo
	seen := map[string]bool{}
	for _, e := range entries {
		key := e.pkg + "::" + e.name
		if seen[key] {
			continue
		}
		methods := resolveEntry(e, map[string]bool{})
		if len(methods) == 0 {
			continue
		}
		seen[key] = true
		records = append(records, &workspaceInterfaceInfo{
			candidate: InterfaceCandidate{
				Name:       e.name,
				Package:    e.pkg,
				Methods:    methods,
				TypeParams: e.tpNames,
				ImportPath: e.importPath,
			},
			file:                 e.file,
			fset:                 e.fset,
			src:                  e.src,
			ifaceType:            e.ifaceType,
			typeParamNames:       e.tpNames,
			typeParamConstraints: e.tpConstraints,
			pkgDefinedTypes:      pkgDefinedTypes[e.pkg],
		})
	}

	for _, std := range stdlibInterfaces {
		key := std.Package + "::" + std.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		records = append(records, &workspaceInterfaceInfo{
			candidate: std,
		})
	}

	return records
}

func extractInterfaceMethods(fset *token.FileSet, src []byte, iface *ast.InterfaceType) []string {
	if iface == nil || iface.Methods == nil {
		return nil
	}
	var methods []string
	for _, field := range iface.Methods.List {
		if len(field.Names) == 0 {
			embeddedName := strings.TrimSpace(exprString(fset, src, field.Type))
			for _, std := range stdlibInterfaces {
				if std.Name == embeddedName || strings.TrimPrefix(std.Name, std.Package+".") == embeddedName {
					methods = append(methods, std.Methods...)
				}
			}
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
		for _, id := range field.Names {
			if id == nil || id.Name == "" {
				continue
			}
			methods = append(methods, id.Name+sigRest)
		}
	}
	return methods
}

type methodSigInfo struct {
	name     string
	sig      string
	exported bool
}

func collectPackageMethodsAndTypes(
	req GenerateCodeRequest,
	currentFile *ast.File,
	currentFset *token.FileSet,
	currentSrc []byte,
	typeName string,
	readSource func(string) ([]byte, error),
) ([]methodSigInfo, map[string]bool) {
	methods, existingTypes, _ := collectPackageMethodsTypesAndParams(req, currentFile, currentFset, currentSrc, typeName, readSource)
	return methods, existingTypes
}

func collectPackageMethodsTypesAndParams(
	req GenerateCodeRequest,
	currentFile *ast.File,
	currentFset *token.FileSet,
	currentSrc []byte,
	typeName string,
	readSource func(string) ([]byte, error),
) ([]methodSigInfo, map[string]bool, string) {
	dir := filepath.Dir(req.Path)
	visited := map[string]bool{}
	var otherPaths []string

	for p := range req.Buffers {
		if p == req.Path {
			continue
		}
		if filepath.Dir(p) == dir && strings.HasSuffix(p, ".go") && !strings.HasSuffix(p, goTestFileSuffix) {
			otherPaths = append(otherPaths, p)
			visited[p] = true
		}
	}

	if entries, err := os.ReadDir(dir); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			name := entry.Name()
			if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, goTestFileSuffix) {
				continue
			}
			fullPath := filepath.Join(dir, name)
			if fullPath == req.Path || visited[fullPath] {
				continue
			}
			otherPaths = append(otherPaths, fullPath)
			visited[fullPath] = true
		}
	}
	sort.Strings(otherPaths)

	existingTypes := map[string]bool{}
	methodsByType := map[string][]methodSigInfo{}
	seenMethodsByType := map[string]map[string]bool{}
	embedsByType := map[string][]string{}
	ifaceMethodsByName := map[string][]methodSigInfo{}
	var targetTypeParamsUse string

	scanAST := func(fset *token.FileSet, src []byte, f *ast.File) {
		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.GenDecl:
				if d.Tok == token.TYPE {
					for _, spec := range d.Specs {
						ts, ok := spec.(*ast.TypeSpec)
						if !ok || ts.Name == nil {
							continue
						}
						tName := ts.Name.Name
						existingTypes[tName] = true
						if tName == typeName && targetTypeParamsUse == "" && ts.TypeParams != nil {
							_, tpUse, _, _ := extractGoastTypeParams(fset, src, ts.TypeParams)
							targetTypeParamsUse = tpUse
						}
						if st, ok := ts.Type.(*ast.StructType); ok && st.Fields != nil {
							for _, field := range st.Fields.List {
								if len(field.Names) == 0 {
									embType := strings.TrimSpace(exprString(fset, src, field.Type))
									if embType != "" {
										embedsByType[tName] = append(embedsByType[tName], embType)
									}
								}
							}
						}
						if it, ok := ts.Type.(*ast.InterfaceType); ok {
							for _, mSig := range extractInterfaceMethods(fset, src, it) {
								paren := strings.IndexByte(mSig, '(')
								if paren <= 0 {
									continue
								}
								mName := strings.TrimSpace(mSig[:paren])
								ifaceMethodsByName[tName] = append(ifaceMethodsByName[tName], methodSigInfo{
									name:     mName,
									sig:      mSig,
									exported: ast.IsExported(mName),
								})
							}
						}
					}
				}
			case *ast.FuncDecl:
				if d.Name == nil || d.Recv == nil || len(d.Recv.List) == 0 {
					continue
				}
				recvName := extractReceiverTypeName(d.Recv)
				if recvName == "" {
					continue
				}
				mName := d.Name.Name
				if seenMethodsByType[recvName] == nil {
					seenMethodsByType[recvName] = map[string]bool{}
				}
				if seenMethodsByType[recvName][mName] {
					continue
				}
				seenMethodsByType[recvName][mName] = true

				startOff := fset.Position(d.Name.Pos()).Offset
				endOff := fset.Position(d.Type.End()).Offset
				if startOff >= 0 && endOff >= startOff && endOff <= len(src) {
					sig := strings.TrimSpace(string(src[startOff:endOff]))
					methodsByType[recvName] = append(methodsByType[recvName], methodSigInfo{
						name:     mName,
						sig:      sig,
						exported: ast.IsExported(mName),
					})
				}
			}
		}
	}

	scanAST(currentFset, currentSrc, currentFile)
	for _, p := range otherPaths {
		pSrc, err := readSource(p)
		if err != nil {
			continue
		}
		if !goastBuildTagsCompatible(currentSrc, pSrc) {
			continue
		}
		pFset := token.NewFileSet()
		pFile, _ := parser.ParseFile(pFset, p, pSrc, parser.SkipObjectResolution)
		if pFile == nil || pFile.Name == nil || currentFile.Name == nil || pFile.Name.Name != currentFile.Name.Name {
			continue
		}
		scanAST(pFset, pSrc, pFile)
	}

	var methods []methodSigInfo
	collectedNames := map[string]bool{}
	addCollected := func(m methodSigInfo) {
		if m.name == "" || collectedNames[m.name] {
			return
		}
		collectedNames[m.name] = true
		methods = append(methods, m)
	}
	for _, m := range methodsByType[typeName] {
		addCollected(m)
	}

	visitedEmbed := map[string]bool{typeName: true}
	var collectEmbedded func(tName string)
	collectEmbedded = func(tName string) {
		for _, rawEmb := range embedsByType[tName] {
			cleanEmb := strings.TrimSpace(strings.TrimPrefix(rawEmb, "*"))
			if idx := strings.IndexByte(cleanEmb, '['); idx > 0 {
				cleanEmb = strings.TrimSpace(cleanEmb[:idx])
			}
			if cleanEmb == "" {
				continue
			}
			for _, std := range stdlibInterfaces {
				if std.Name == cleanEmb {
					for _, sm := range std.Methods {
						paren := strings.IndexByte(sm, '(')
						if paren > 0 {
							mName := strings.TrimSpace(sm[:paren])
							addCollected(methodSigInfo{name: mName, sig: sm, exported: ast.IsExported(mName)})
						}
					}
				}
			}
			if visitedEmbed[cleanEmb] {
				continue
			}
			visitedEmbed[cleanEmb] = true
			for _, m := range methodsByType[cleanEmb] {
				addCollected(m)
			}
			for _, m := range ifaceMethodsByName[cleanEmb] {
				addCollected(m)
			}
			collectEmbedded(cleanEmb)
		}
	}
	collectEmbedded(typeName)

	return methods, existingTypes, targetTypeParamsUse
}

func generateExtractInterface(
	req GenerateCodeRequest,
	fset *token.FileSet,
	src []byte,
	file *ast.File,
	typeName string,
	insertPos token.Pos,
	readSource func(string) ([]byte, error),
) string {
	allMethods, existingTypes := collectPackageMethodsAndTypes(req, file, fset, src, typeName, readSource)

	var exportedSigs []string
	for _, m := range allMethods {
		if m.exported {
			exportedSigs = append(exportedSigs, "\t"+m.sig)
		}
	}
	if len(exportedSigs) == 0 {
		return marshalError(fmt.Sprintf("no exported methods found on %s", typeName))
	}

	ifaceName := typeName + "Interface"
	if strings.HasSuffix(typeName, "e") {
		ifaceName = typeName + "r"
	}
	if existingTypes[ifaceName] && ifaceName != typeName+"Interface" {
		ifaceName = typeName + "Interface"
	}

	raw := fmt.Sprintf("type %s interface {\n%s\n}", ifaceName, strings.Join(exportedSigs, "\n"))
	formatted, err := format.Source([]byte(raw))
	if err != nil {
		formatted = []byte(raw)
	}
	insertText := strings.TrimSpace(string(formatted)) + "\n\n"

	resp := GenerateCodeResponse{
		EditsByPath: map[string][]SigTextEdit{
			req.Path: {
				{
					Range:   lspRange(fset, src, insertPos, insertPos),
					NewText: insertText,
				},
			},
		},
	}
	b, _ := json.Marshal(resp)
	return string(b)
}

func findInterfaceCandidate(req GenerateCodeRequest) *InterfaceCandidate {
	rec := findInterfaceRecord(req)
	if rec == nil {
		return nil
	}
	return &rec.candidate
}

func splitTargetGenericArgs(target string) (string, []string) {
	t := strings.TrimSpace(target)
	openIdx := strings.IndexByte(t, '[')
	if openIdx <= 0 || !strings.HasSuffix(t, "]") {
		return t, nil
	}
	base := strings.TrimSpace(t[:openIdx])
	inner := t[openIdx+1 : len(t)-1]
	var args []string
	depth := 0
	start := 0
	for i, r := range inner {
		switch r {
		case '[', '(':
			depth++
		case ']', ')':
			if depth > 0 {
				depth--
			}
		case ',':
			if depth == 0 {
				args = append(args, strings.TrimSpace(inner[start:i]))
				start = i + 1
			}
		}
	}
	last := strings.TrimSpace(inner[start:])
	if last != "" {
		args = append(args, last)
	}
	return base, args
}

func findInterfaceRecord(req GenerateCodeRequest) *workspaceInterfaceInfo {
	baseTarget, explicitArgs := splitTargetGenericArgs(req.TargetName)
	if baseTarget == "" {
		return nil
	}

	wsDir := req.WorkspaceDir
	if wsDir == "" {
		wsDir = filepath.Dir(req.Path)
		parent := filepath.Dir(wsDir)
		if parent != wsDir && parent != "/" && parent != "." {
			if _, err := os.Stat(filepath.Join(parent, "go.mod")); err == nil {
				wsDir = parent
			}
		}
	}

	records := collectWorkspaceInterfaceRecords(wsDir, req.Path, req.Buffers)

	for _, r := range records {
		c := r.candidate
		pkgAlias := defaultGoastImportIdent(c.Package)
		if c.Name == baseTarget || c.Package+"."+c.Name == baseTarget || (pkgAlias != "" && pkgAlias+"."+c.Name == baseTarget) {
			r.explicitArgs = explicitArgs
			return r
		}
	}
	for _, r := range records {
		c := r.candidate
		short := c.Name
		if dot := strings.LastIndexByte(short, '.'); dot >= 0 {
			short = short[dot+1:]
		}
		if short == baseTarget {
			r.explicitArgs = explicitArgs
			return r
		}
	}
	return nil
}

func generateImplementInterface(
	req GenerateCodeRequest,
	fset *token.FileSet,
	src []byte,
	file *ast.File,
	typeName string,
	typeParams *ast.FieldList,
	insertAfterPos token.Pos,
	readSource func(string) ([]byte, error),
) string {
	if strings.TrimSpace(req.TargetName) == "" {
		return marshalError("missing target interface name")
	}

	rec := findInterfaceRecord(req)
	if rec == nil || len(rec.candidate.Methods) == 0 {
		return marshalError("interface not found: " + req.TargetName)
	}
	cand := rec.candidate

	existingMethods, existingTypes, lookedUpTPUse := collectPackageMethodsTypesAndParams(req, file, fset, src, typeName, readSource)
	seen := map[string]bool{}
	for _, m := range existingMethods {
		seen[m.name] = true
	}

	var structTPUse string
	var structTPNames []string
	if typeParams != nil {
		_, structTPUse, structTPNames, _ = extractGoastTypeParams(fset, src, typeParams)
	}
	if structTPUse == "" && lookedUpTPUse != "" {
		structTPUse = lookedUpTPUse
		trimmed := strings.TrimSuffix(strings.TrimPrefix(lookedUpTPUse, "["), "]")
		for _, p := range strings.Split(trimmed, ",") {
			if pn := strings.TrimSpace(p); pn != "" {
				structTPNames = append(structTPNames, pn)
			}
		}
	}

	typeSubst := map[string]string{}
	if len(rec.typeParamNames) > 0 {
		if len(rec.explicitArgs) > 0 {
			for i, tp := range rec.typeParamNames {
				if i < len(rec.explicitArgs) && rec.explicitArgs[i] != "" {
					typeSubst[tp] = rec.explicitArgs[i]
				}
			}
		} else if len(structTPNames) == len(rec.typeParamNames) {
			for i, tp := range rec.typeParamNames {
				typeSubst[tp] = structTPNames[i]
			}
		} else {
			for i, tp := range rec.typeParamNames {
				cons := ""
				if i < len(rec.typeParamConstraints) {
					cons = rec.typeParamConstraints[i]
				}
				typeSubst[tp] = buildGoastWitnessType(cons, existingTypes)
			}
		}
	}

	currentPkg := ""
	if file != nil && file.Name != nil {
		currentPkg = file.Name.Name
	}
	qualifyPkg := ""
	if cand.Package != "" && cand.Package != currentPkg && cand.Package != "builtin" && rec.file != nil {
		qualifyPkg = cand.Package
	}

	currentAliases := collectGoastFileImportAliases(file)
	pathToCurrentAlias := map[string]string{}
	for alias, p := range currentAliases {
		if _, exists := pathToCurrentAlias[p]; !exists {
			pathToCurrentAlias[p] = alias
		}
	}
	sourceAliases := collectGoastFileImportAliases(rec.file)
	aliasRemap := map[string]string{}
	for srcAlias, impPath := range sourceAliases {
		if curAlias, ok := pathToCurrentAlias[impPath]; ok && curAlias != srcAlias {
			aliasRemap[srcAlias] = curAlias
		}
	}
	for stdAlias, impPath := range goastStdlibPkgs {
		if curAlias, ok := pathToCurrentAlias[impPath]; ok && curAlias != stdAlias {
			aliasRemap[stdAlias] = curAlias
		}
	}

	baseForbidden := map[string]bool{}
	for alias := range currentAliases {
		baseForbidden[alias] = true
	}
	for _, tp := range structTPNames {
		baseForbidden[tp] = true
	}

	recvTypeExpr := typeName + structTPUse
	var stubs []string
	for _, rawSig := range cand.Methods {
		mSig := strings.TrimSpace(rawSig)
		if len(typeSubst) > 0 {
			mSig = substituteGoastMethodSig(mSig, typeSubst)
		}
		if qualifyPkg != "" && len(rec.pkgDefinedTypes) > 0 {
			mSig = qualifyGoastMethodSig(mSig, qualifyPkg, rec.pkgDefinedTypes)
		}
		if len(aliasRemap) > 0 {
			mSig = remapGoastMethodSigAliases(mSig, aliasRemap)
		}

		parenIdx := strings.IndexByte(mSig, '(')
		if parenIdx <= 0 {
			continue
		}
		mName := strings.TrimSpace(mSig[:parenIdx])
		if seen[mName] {
			continue
		}
		seen[mName] = true

		forbidden := map[string]bool{}
		for k, v := range baseForbidden {
			forbidden[k] = v
		}
		for _, pName := range extractGoastSigParamNames(mSig[parenIdx:]) {
			forbidden[pName] = true
		}
		recvName := pickSafeGoastReceiverIdent(typeName, forbidden)

		stubs = append(stubs, fmt.Sprintf(
			"func (%s *%s) %s {\n\tpanic(\"not implemented\")\n}",
			recvName, recvTypeExpr, mSig,
		))
	}

	if len(stubs) == 0 {
		resp := GenerateCodeResponse{
			EditsByPath: map[string][]SigTextEdit{},
		}
		b, _ := json.Marshal(resp)
		return string(b)
	}

	raw := strings.Join(stubs, "\n\n")
	formatted, err := format.Source([]byte(raw))
	if err != nil {
		formatted = []byte(raw)
	}
	insertText := "\n\n" + strings.TrimSpace(string(formatted))

	var sourceFiles []*ast.File
	if file != nil {
		sourceFiles = append(sourceFiles, file)
	}
	if rec.file != nil {
		sourceFiles = append(sourceFiles, rec.file)
	}
	requiredSpecs := collectGoastUsedImportSpecs(sourceFiles, string(formatted), goastStdlibPkgs)
	if qualifyPkg != "" && cand.ImportPath != "" {
		qualAlias := qualifyPkg
		if curAlias, ok := pathToCurrentAlias[cand.ImportPath]; ok {
			qualAlias = curAlias
		}
		hasQual := false
		for _, s := range requiredSpecs {
			if s.Path == cand.ImportPath {
				hasQual = true
				break
			}
		}
		if !hasQual && strings.Contains(string(formatted), qualAlias+".") {
			requiredSpecs = append(requiredSpecs, goastImportSpec{Alias: qualAlias, Path: cand.ImportPath})
		}
	}

	edits := buildGoastImportEdits(fset, file, src, requiredSpecs)
	edits = append(edits, SigTextEdit{
		Range:   lspRange(fset, src, insertAfterPos, insertAfterPos),
		NewText: insertText,
	})

	resp := GenerateCodeResponse{
		EditsByPath: map[string][]SigTextEdit{
			req.Path: edits,
		},
	}
	b, _ := json.Marshal(resp)
	return string(b)
}
