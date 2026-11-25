package goast

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

func buildTableDrivenTestCode(spec tableDrivenTestSpec) string {
	testFuncName := spec.testFuncName
	targetFuncName := spec.targetFuncName
	recvType := spec.recvType
	baseRecvName := spec.baseRecvName
	recvInstName := spec.recvInstName
	if recvInstName == "" {
		recvInstName = baseRecvName
	}
	recvVarName := spec.recvVarName
	isPtrRecv := spec.isPtrRecv
	params := spec.params
	results := spec.results
	hasErr := spec.hasErr
	includeParallel := spec.includeParallel
	testingPkg := spec.testingPkgIdent
	if testingPkg == "" {
		testingPkg = "testing"
	}
	reflectPkg := spec.reflectPkgIdent
	if reflectPkg == "" {
		reflectPkg = "reflect"
	}
	tParam := spec.testParamName
	if tParam == "" {
		tParam = "t"
	}
	subT := spec.subTestParamName
	if subT == "" {
		subT = "t"
	}
	ttVar := spec.loopVarName
	if ttVar == "" {
		ttVar = "tt"
	}
	testsVar := spec.testsVarName
	if testsVar == "" {
		testsVar = "tests"
	}
	errVar := spec.errVarName
	if errVar == "" {
		errVar = "err"
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("func %s(%s *%s.T) {\n", testFuncName, tParam, testingPkg))
	if includeParallel {
		sb.WriteString(fmt.Sprintf("\t%s.Parallel()\n", tParam))
	}

	sb.WriteString(fmt.Sprintf("\t%s := []struct {\n", testsVar))
	sb.WriteString("\t\tname string\n")
	sb.WriteString("\t\tskip bool\n")
	for _, p := range params {
		if p.isContext {
			continue
		}
		sb.WriteString("\t\t")
		sb.WriteString(p.name)
		sb.WriteByte(' ')
		sb.WriteString(p.typeExpr)
		sb.WriteByte('\n')
	}
	for _, r := range results {
		sb.WriteString("\t\t")
		sb.WriteString(r.name)
		sb.WriteByte(' ')
		sb.WriteString(r.typeExpr)
		sb.WriteByte('\n')
	}
	if hasErr {
		sb.WriteString("\t\twantErr bool\n")
	}
	sb.WriteString("\t}{\n")

	writeCase := func(caseName string, edge bool) {
		sb.WriteString("\t\t{\n")
		sb.WriteString(fmt.Sprintf("\t\t\tname: %q,\n", caseName))
		sb.WriteString("\t\t\tskip: true,\n")
		for _, p := range params {
			if p.isContext {
				continue
			}
			sb.WriteString(fmt.Sprintf("\t\t\t%s: %s,\n", p.name, sampleLiteralForTest(p.typeExpr, edge, false, spec.typeDefs)))
		}
		for _, r := range results {
			sb.WriteString(fmt.Sprintf("\t\t\t%s: %s,\n", r.name, sampleLiteralForTest(r.typeExpr, edge, true, spec.typeDefs)))
		}
		if hasErr {
			wantErrVal := "false"
			if edge {
				wantErrVal = "true"
			}
			sb.WriteString(fmt.Sprintf("\t\t\twantErr: %s,\n", wantErrVal))
		}
		sb.WriteString("\t\t},\n")
	}

	writeCase("base case", false)
	writeCase("edge case", true)
	sb.WriteString("\t}\n")

	sb.WriteString(fmt.Sprintf("\tfor _, %s := range %s {\n", ttVar, testsVar))
	sb.WriteString(fmt.Sprintf("\t\t%s.Run(%s.name, func(%s *%s.T) {\n", tParam, ttVar, subT, testingPkg))
	if includeParallel {
		sb.WriteString(fmt.Sprintf("\t\t\t%s.Parallel()\n", subT))
	}
	sb.WriteString(fmt.Sprintf("\t\t\tif %s.skip {\n", ttVar))
	sb.WriteString(fmt.Sprintf("\t\t\t\t%s.Skip(\"populate expected test case values\")\n", subT))
	sb.WriteString(closingTripleIndentBraceLine)

	callTarget := targetFuncName
	if len(spec.funcTypeArgs) > 0 && baseRecvName == "" && recvType == "" {
		callTarget += "[" + strings.Join(spec.funcTypeArgs, ", ") + "]"
	}
	if baseRecvName != "" {
		if spec.recvIsStruct {
			if isPtrRecv {
				sb.WriteString(fmt.Sprintf("\t\t\t%s := &%s{}\n", recvVarName, recvInstName))
			} else {
				sb.WriteString(fmt.Sprintf("\t\t\t%s := %s{}\n", recvVarName, recvInstName))
			}
		} else {
			if isPtrRecv {
				sb.WriteString(fmt.Sprintf("\t\t\tvar %s %s\n", spec.recvValVarName, recvInstName))
				sb.WriteString(fmt.Sprintf("\t\t\t%s := &%s\n", recvVarName, spec.recvValVarName))
			} else {
				sb.WriteString(fmt.Sprintf("\t\t\tvar %s %s\n", recvVarName, recvInstName))
			}
		}
		callTarget = recvVarName + "." + targetFuncName
	} else if recvType != "" {
		sb.WriteString(fmt.Sprintf("\t\t\tvar %s %s\n", recvVarName, recvType))
		callTarget = recvVarName + "." + targetFuncName
	}

	var callArgs []string
	for _, p := range params {
		if p.isContext {
			ctxAlias := p.contextAlias
			if ctxAlias == "" {
				ctxAlias = "context"
			}
			callArgs = append(callArgs, ctxAlias+".Background()")
		} else if p.isVariadic {
			callArgs = append(callArgs, ttVar+"."+p.name+"...")
		} else {
			callArgs = append(callArgs, ttVar+"."+p.name)
		}
	}
	callExpr := fmt.Sprintf("%s(%s)", callTarget, strings.Join(callArgs, ", "))

	var lhsVars []string
	for _, r := range results {
		lhsVars = append(lhsVars, r.gotName)
	}
	if hasErr {
		lhsVars = append(lhsVars, errVar)
	}

	if len(lhsVars) > 0 {
		sb.WriteString(fmt.Sprintf("\t\t\t%s := %s\n", strings.Join(lhsVars, ", "), callExpr))
	} else {
		sb.WriteString(fmt.Sprintf("\t\t\t%s\n", callExpr))
	}

	labelForMsg := targetFuncName
	if baseRecvName != "" {
		labelForMsg = baseRecvName + "." + targetFuncName
	}

	if hasErr {
		sb.WriteString(fmt.Sprintf("\t\t\tif (%s != nil) != %s.wantErr {\n", errVar, ttVar))
		sb.WriteString(fmt.Sprintf("\t\t\t\t%s.Fatalf(\"%s() error = %%v, wantErr %%v\", %s, %s.wantErr)\n", subT, labelForMsg, errVar, ttVar))
		sb.WriteString(closingTripleIndentBraceLine)
		if len(results) > 0 {
			sb.WriteString(fmt.Sprintf("\t\t\tif %s.wantErr {\n", ttVar))
			sb.WriteString("\t\t\t\treturn\n")
			sb.WriteString(closingTripleIndentBraceLine)
		}
	}

	for _, r := range results {
		if r.isFunc {
			sb.WriteString(fmt.Sprintf("\t\t\tif (%s == nil) != (%s.%s == nil) {\n", r.gotName, ttVar, r.name))
			sb.WriteString(fmt.Sprintf("\t\t\t\t%s.Errorf(\"%s() nil = %%v, want nil = %%v\", %s == nil, %s.%s == nil)\n", subT, labelForMsg, r.gotName, ttVar, r.name))
			sb.WriteString(closingTripleIndentBraceLine)
		} else if r.deepEq {
			sb.WriteString(fmt.Sprintf("\t\t\tif !%s.DeepEqual(%s, %s.%s) {\n", reflectPkg, r.gotName, ttVar, r.name))
			sb.WriteString(fmt.Sprintf("\t\t\t\t%s.Errorf(\"%s() = %%v, want %%v\", %s, %s.%s)\n", subT, labelForMsg, r.gotName, ttVar, r.name))
			sb.WriteString(closingTripleIndentBraceLine)
		} else {
			sb.WriteString(fmt.Sprintf("\t\t\tif %s != %s.%s {\n", r.gotName, ttVar, r.name))
			sb.WriteString(fmt.Sprintf("\t\t\t\t%s.Errorf(\"%s() = %%v, want %%v\", %s, %s.%s)\n", subT, labelForMsg, r.gotName, ttVar, r.name))
			sb.WriteString(closingTripleIndentBraceLine)
		}
	}

	sb.WriteString("\t\t})\n")
	sb.WriteString("\t}\n")
	sb.WriteString("}")

	raw := sb.String()
	wrapped := "package p\n\n" + raw + "\n"
	if formatted, err := format.Source([]byte(wrapped)); err == nil {
		s := strings.TrimSpace(strings.TrimPrefix(string(formatted), "package p"))
		return s
	}
	return raw
}

func computeTestFilePath(path string) string {
	p := strings.TrimSpace(path)
	if p == "" {
		return ""
	}
	if strings.HasSuffix(p, testgenGoTestFileSuffix) {
		return p
	}
	if strings.HasSuffix(p, ".go") {
		return strings.TrimSuffix(p, ".go") + testgenGoTestFileSuffix
	}
	return p + testgenGoTestFileSuffix
}

func isTestFilePackageCompatible(path, pkgName string) bool {
	data, err := os.ReadFile(path)
	if err != nil || len(bytes.TrimSpace(data)) == 0 {
		return true
	}
	f, err := parser.ParseFile(token.NewFileSet(), path, data, parser.PackageClauseOnly)
	if err != nil || f == nil || f.Name == nil {
		return true
	}
	return f.Name.Name == pkgName
}

func computeTargetTestFilePath(path, pkgName string) string {
	base := computeTestFilePath(path)
	if base == "" {
		return ""
	}
	if isTestFilePackageCompatible(base, pkgName) {
		return base
	}
	stem := strings.TrimSuffix(base, testgenGoTestFileSuffix)
	for i := 0; ; i++ {
		suffix := "_unit" + testgenGoTestFileSuffix
		if i > 0 {
			suffix = fmt.Sprintf("_unit%d%s", i+1, testgenGoTestFileSuffix)
		}
		cand := stem + suffix
		if isTestFilePackageCompatible(cand, pkgName) {
			return cand
		}
	}
}

func collectRequiredTestImportSpecs(srcFile, existingTestFile *ast.File, previewCode string, forcedImports []goastImportSpec, needReflect bool) []goastImportSpec {
	var files []*ast.File
	if srcFile != nil {
		files = append(files, srcFile)
	}
	if existingTestFile != nil {
		files = append(files, existingTestFile)
	}
	stdlibFallback := testgenStdlibPkgs
	if !needReflect {
		stdlibFallback = make(map[string]string, len(testgenStdlibPkgs))
		for k, v := range testgenStdlibPkgs {
			if k != "reflect" {
				stdlibFallback[k] = v
			}
		}
	}
	used := collectGoastUsedImportSpecs(files, previewCode, stdlibFallback)
	byKey := map[string]goastImportSpec{}
	addSpec := func(spec goastImportSpec) {
		p := strings.Trim(strings.TrimSpace(spec.Path), `"`)
		if p == "" {
			return
		}
		alias := strings.TrimSpace(spec.Alias)
		if alias == defaultGoastImportIdent(p) {
			alias = ""
		}
		key := alias + "|" + p
		byKey[key] = goastImportSpec{Alias: alias, Path: p}
	}
	for _, s := range forcedImports {
		addSpec(s)
	}
	for _, s := range used {
		addSpec(s)
	}
	out := make([]goastImportSpec, 0, len(byKey))
	for _, s := range byKey {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Path != out[j].Path {
			return out[i].Path < out[j].Path
		}
		return out[i].Alias < out[j].Alias
	})
	return out
}

func writeOrAppendTestFile(testFilePath, pkgName string, src []byte, srcFile *ast.File, existing []byte, existingFile *ast.File, previewCode string, forcedImports []goastImportSpec, testFuncName string, needReflect bool) error {
	reqSpecs := collectRequiredTestImportSpecs(srcFile, existingFile, previewCode, forcedImports, needReflect)

	if len(bytes.TrimSpace(existing)) == 0 {
		if data, err := os.ReadFile(testFilePath); err == nil && len(bytes.TrimSpace(data)) > 0 {
			existing = data
		}
	}
	if len(bytes.TrimSpace(existing)) > 0 {
		updated := appendTestToExistingFile(existing, reqSpecs, previewCode)
		if formatted, fmtErr := format.Source(updated); fmtErr == nil {
			updated = formatted
		}
		return os.WriteFile(testFilePath, updated, 0644)
	}

	var sb strings.Builder
	_, directives := extractGoastBuildConstraint(src)
	if len(directives) > 0 {
		sb.WriteString(strings.Join(directives, "\n"))
		sb.WriteString("\n\n")
	}
	sb.WriteString("package ")
	sb.WriteString(pkgName)
	sb.WriteString("\n\n")
	if len(reqSpecs) == 1 {
		sb.WriteString("import " + formatTestImportSpec(reqSpecs[0]) + "\n\n")
	} else if len(reqSpecs) > 1 {
		sb.WriteString("import (\n")
		for _, imp := range reqSpecs {
			sb.WriteString("\t" + formatTestImportSpec(imp) + "\n")
		}
		sb.WriteString(")\n\n")
	}
	sb.WriteString(previewCode)
	sb.WriteByte('\n')

	outBytes := []byte(sb.String())
	if formatted, fmtErr := format.Source(outBytes); fmtErr == nil {
		outBytes = formatted
	}
	return os.WriteFile(testFilePath, outBytes, 0644)
}

func formatTestImportSpec(spec goastImportSpec) string {
	if spec.Alias != "" && spec.Alias != defaultGoastImportIdent(spec.Path) {
		return fmt.Sprintf("%s %q", spec.Alias, spec.Path)
	}
	return fmt.Sprintf("%q", spec.Path)
}

func buildMissingTestImportByteEdits(fset *token.FileSet, file *ast.File, src []byte, required []goastImportSpec) []testgenByteEdit {
	if file == nil || len(required) == 0 {
		return nil
	}
	type binding struct {
		name string
		path string
	}
	var existing []binding
	existingDefault := map[string]bool{}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.Trim(imp.Path.Value, `"`)
		name := ""
		if imp.Name != nil {
			name = imp.Name.Name
		}
		if name != "_" && name != "." {
			existing = append(existing, binding{name: name, path: p})
			if name == "" || name == defaultGoastImportIdent(p) {
				existingDefault[p] = true
			}
		}
	}

	seen := map[string]bool{}
	var missing []goastImportSpec
	for _, req := range required {
		p := strings.Trim(strings.TrimSpace(req.Path), `"`)
		if p == "" {
			continue
		}
		alias := strings.TrimSpace(req.Alias)
		key := alias + "|" + p
		if seen[key] {
			continue
		}
		satisfied := false
		if alias == "" {
			satisfied = existingDefault[p]
		} else {
			for _, b := range existing {
				if b.path == p && (b.name == alias || (b.name == "" && alias == defaultGoastImportIdent(p))) {
					satisfied = true
					break
				}
			}
		}
		if !satisfied {
			seen[key] = true
			missing = append(missing, goastImportSpec{Alias: alias, Path: p})
		}
	}
	if len(missing) == 0 {
		return nil
	}

	var firstImportDecl *ast.GenDecl
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if ok && gd.Tok == token.IMPORT {
			firstImportDecl = gd
			break
		}
	}

	if firstImportDecl != nil {
		if firstImportDecl.Lparen.IsValid() && firstImportDecl.Rparen.IsValid() {
			rparenOff := fset.Position(firstImportDecl.Rparen).Offset
			if rparenOff >= 0 && rparenOff <= len(src) {
				var addBuf strings.Builder
				if rparenOff > 0 && src[rparenOff-1] != '\n' {
					addBuf.WriteByte('\n')
				}
				for _, m := range missing {
					addBuf.WriteString("\t" + formatTestImportSpec(m) + "\n")
				}
				return []testgenByteEdit{{
					start: rparenOff,
					end:   rparenOff,
					text:  addBuf.String(),
				}}
			}
		}
		startOff := fset.Position(firstImportDecl.Pos()).Offset
		endOff := fset.Position(firstImportDecl.End()).Offset
		if startOff >= 0 && endOff >= startOff && endOff <= len(src) {
			var specs []string
			for _, spec := range firstImportDecl.Specs {
				is, ok := spec.(*ast.ImportSpec)
				if !ok || is.Path == nil {
					continue
				}
				if is.Name != nil && is.Name.Name != "" {
					specs = append(specs, fmt.Sprintf("\t%s %s", is.Name.Name, is.Path.Value))
				} else {
					specs = append(specs, fmt.Sprintf("\t%s", is.Path.Value))
				}
			}
			for _, m := range missing {
				specs = append(specs, "\t"+formatTestImportSpec(m))
			}
			return []testgenByteEdit{{
				start: startOff,
				end:   endOff,
				text:  "import (\n" + strings.Join(specs, "\n") + "\n)",
			}}
		}
	}

	if file.Name != nil {
		var importBlock strings.Builder
		if len(missing) == 1 {
			importBlock.WriteString("\n\nimport " + formatTestImportSpec(missing[0]))
		} else {
			importBlock.WriteString("\n\nimport (\n")
			for _, m := range missing {
				importBlock.WriteString("\t" + formatTestImportSpec(m) + "\n")
			}
			importBlock.WriteString(")")
		}
		insertOff := fset.Position(file.Name.End()).Offset
		for insertOff < len(src) && src[insertOff] != '\n' {
			insertOff++
		}
		if insertOff >= 0 && insertOff <= len(src) {
			return []testgenByteEdit{{
				start: insertOff,
				end:   insertOff,
				text:  importBlock.String(),
			}}
		}
	}
	return nil
}

func appendTestToExistingFile(existing []byte, reqSpecs []goastImportSpec, previewCode string) []byte {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", existing, parser.ParseComments)
	if err != nil || f == nil {
		var buf bytes.Buffer
		buf.Write(bytes.TrimRight(existing, " \t\r\n"))
		buf.WriteString("\n\n")
		buf.WriteString(previewCode)
		buf.WriteByte('\n')
		return buf.Bytes()
	}

	edits := buildMissingTestImportByteEdits(fset, f, existing, reqSpecs)

	insertOff := len(existing)
	for insertOff > 0 && (existing[insertOff-1] == ' ' || existing[insertOff-1] == '\t' || existing[insertOff-1] == '\r' || existing[insertOff-1] == '\n') {
		insertOff--
	}
	edits = append(edits, testgenByteEdit{
		start: insertOff,
		end:   len(existing),
		text:  "\n\n" + previewCode + "\n",
	})

	sort.Slice(edits, func(i, j int) bool {
		if edits[i].start != edits[j].start {
			return edits[i].start > edits[j].start
		}
		return edits[i].end > edits[j].end
	})

	out := string(existing)
	for _, ed := range edits {
		if ed.start < 0 || ed.end < ed.start || ed.end > len(out) {
			continue
		}
		out = out[:ed.start] + ed.text + out[ed.end:]
	}
	return []byte(out)
}

func declaredTestPackageFuncs(testFilePath string, existing *ast.File) map[string]bool {
	names := map[string]bool{}
	collect := func(f *ast.File) {
		for _, decl := range f.Decls {
			if fn, ok := decl.(*ast.FuncDecl); ok && fn.Recv == nil && fn.Name != nil {
				names[fn.Name.Name] = true
			}
		}
	}
	if existing != nil {
		collect(existing)
	}
	if testFilePath == "" {
		return names
	}
	dir := filepath.Dir(testFilePath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return names
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), testgenGoTestFileSuffix) || filepath.Join(dir, e.Name()) == testFilePath {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), filepath.Join(dir, e.Name()), nil, parser.SkipObjectResolution)
		if err != nil || (existing != nil && f.Name.Name != existing.Name.Name) {
			continue
		}
		collect(f)
	}
	return names
}
