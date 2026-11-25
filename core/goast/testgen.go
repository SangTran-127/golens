package goast

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	closingTripleIndentBraceLine = "\t\t\t}\n"
	testgenGoTestFileSuffix      = "_test.go"
)

var testgenStdlibPkgs = func() map[string]string {
	m := make(map[string]string, len(goastStdlibPkgs)+6)
	for k, v := range goastStdlibPkgs {
		m[k] = v
	}
	m["testing"] = "testing"
	m["reflect"] = "reflect"
	m["context"] = "context"
	m["bytes"] = "bytes"
	m["time"] = "time"
	return m
}()

type GenerateTestReq struct {
	Path            string `json:"path"`
	Src             string `json:"src"`
	Offset          int    `json:"offset"`
	TestFuncName    string `json:"testFuncName,omitempty"`
	IncludeParallel bool   `json:"includeParallel"`
	Apply           bool   `json:"apply"`
}

type GenerateTestReply struct {
	TargetFuncName string `json:"targetFuncName,omitempty"`
	ReceiverType   string `json:"receiverType,omitempty"`
	TestFuncName   string `json:"testFuncName,omitempty"`
	TestFilePath   string `json:"testFilePath,omitempty"`
	PreviewCode    string `json:"previewCode,omitempty"`
	Applied        bool   `json:"applied,omitempty"`
	Error          string `json:"error,omitempty"`
}

type testParamField struct {
	name         string
	typeExpr     string
	isContext    bool
	contextAlias string
	isVariadic   bool
}

type testResultField struct {
	name     string
	gotName  string
	typeExpr string
	deepEq   bool
	isFunc   bool
}

type testgenTypeParam struct {
	name       string
	constraint string
}

type testgenTypeDef struct {
	name       string
	kind       string
	targetExpr string
	typeParams []testgenTypeParam
}

type tableDrivenTestSpec struct {
	testFuncName     string
	targetFuncName   string
	recvType         string
	baseRecvName     string
	recvInstName     string
	recvVarName      string
	recvValVarName   string
	recvIsStruct     bool
	isPtrRecv        bool
	funcTypeArgs     []string
	params           []testParamField
	results          []testResultField
	hasErr           bool
	includeParallel  bool
	testingPkgIdent  string
	reflectPkgIdent  string
	testParamName    string
	subTestParamName string
	loopVarName      string
	testsVarName     string
	errVarName       string
	typeDefs         map[string]testgenTypeDef
}

type testgenByteEdit struct {
	start int
	end   int
	text  string
}

func GenerateTableDrivenTestJSON(reqJSON string) string {
	var req GenerateTestReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(GenerateTestReply{Error: "invalid request: " + err.Error()})
		return string(b)
	}
	reply := GenerateTableDrivenTest(req)
	b, _ := json.Marshal(reply)
	return string(b)
}

func GenerateTableDrivenTest(req GenerateTestReq) GenerateTestReply {
	src := []byte(req.Src)
	if len(src) == 0 && req.Path != "" {
		data, err := os.ReadFile(req.Path)
		if err != nil {
			return GenerateTestReply{Error: "failed to read source file: " + err.Error()}
		}
		src = data
	}
	if len(src) == 0 {
		return GenerateTestReply{Error: "empty source buffer"}
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, req.Path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			return GenerateTestReply{Error: "failed to parse Go file: " + err.Error()}
		}
		return GenerateTestReply{Error: "failed to parse Go file"}
	}

	targetFn := findTargetFuncForTest(fset, file, req.Offset)
	if targetFn == nil || targetFn.Name == nil {
		return GenerateTestReply{Error: "no function or method found in file"}
	}

	pkgName := "main"
	if file.Name != nil && file.Name.Name != "" {
		pkgName = file.Name.Name
	}

	typeDefs, localInterfaces := collectTestPackageTypeDefs(req.Path, file, fset, src, pkgName)

	testFilePath := computeTargetTestFilePath(req.Path, pkgName)
	var existingTestFile *ast.File
	var existingTestSrc []byte
	if testFilePath != "" {
		if data, rErr := os.ReadFile(testFilePath); rErr == nil && len(bytes.TrimSpace(data)) > 0 {
			existingTestSrc = data
			if parsedExist, pErr := parser.ParseFile(token.NewFileSet(), testFilePath, data, parser.ParseComments); pErr == nil && parsedExist != nil {
				existingTestFile = parsedExist
			}
		}
	}

	srcAliases := collectGoastFileImportAliases(file)
	existingAliases := collectGoastFileImportAliases(existingTestFile)
	combinedAliases := make(map[string]string, len(srcAliases)+len(existingAliases))
	for k, v := range srcAliases {
		combinedAliases[k] = v
	}
	aliasRemap := map[string]string{}
	forcedImports := []goastImportSpec{}
	for alias, srcPath := range srcAliases {
		if existPath, conflict := existingAliases[alias]; conflict && existPath != srcPath {
			reused := ""
			for ea, ep := range existingAliases {
				if ep == srcPath {
					reused = ea
					break
				}
			}
			if reused != "" {
				aliasRemap[alias] = reused
			} else {
				newAlias := pickSafeTestIdent(defaultGoastImportIdent(srcPath)+"Src", combinedAliases, existingAliases)
				aliasRemap[alias] = newAlias
				combinedAliases[newAlias] = srcPath
				forcedImports = append(forcedImports, goastImportSpec{Alias: newAlias, Path: srcPath})
			}
		}
	}
	for k, v := range existingAliases {
		if _, ok := combinedAliases[k]; !ok {
			combinedAliases[k] = v
		}
	}

	targetFuncName := targetFn.Name.Name
	recvType := ""
	baseRecvName := ""
	recvInstName := ""
	recvCandidate := ""
	isPtrRecv := false
	recvIsStruct := true
	var recvTypeArgExprs []string

	if targetFn.Recv != nil && len(targetFn.Recv.List) > 0 {
		rf := targetFn.Recv.List[0]
		recvType = strings.TrimSpace(exprString(fset, src, rf.Type))
		baseRecvName, isPtrRecv, recvTypeArgExprs = extractReceiverTypeInfo(fset, src, rf.Type)
		if len(rf.Names) > 0 && rf.Names[0] != nil && rf.Names[0].Name != "" && rf.Names[0].Name != "_" {
			recvCandidate = rf.Names[0].Name
		}
	}

	typeSubst := map[string]string{}
	var recvTypeArgs []string
	if baseRecvName != "" {
		td, ok := resolveTestTypeDef(baseRecvName, typeDefs)
		if ok {
			recvIsStruct = td.kind == "struct"
		}
		if len(recvTypeArgExprs) > 0 {
			for i, argExpr := range recvTypeArgExprs {
				constraintExpr := "any"
				if ok && i < len(td.typeParams) && td.typeParams[i].constraint != "" {
					constraintExpr = td.typeParams[i].constraint
				}
				if isSimpleTestIdent(argExpr) {
					if _, isTypeDef := typeDefs[argExpr]; !isTypeDef && !isBuiltinTestType(argExpr) {
						witness := resolveTestWitnessType(constraintExpr, typeDefs, localInterfaces, combinedAliases, &forcedImports)
						typeSubst[argExpr] = witness
						recvTypeArgs = append(recvTypeArgs, witness)
						continue
					}
				}
				recvTypeArgs = append(recvTypeArgs, argExpr)
			}
			for pass := 0; pass < 2; pass++ {
				for k, v := range typeSubst {
					typeSubst[k] = substituteGoastTypeExpr(v, typeSubst)
				}
				for i, arg := range recvTypeArgs {
					recvTypeArgs[i] = substituteGoastTypeExpr(arg, typeSubst)
				}
			}
			recvInstName = baseRecvName + "[" + strings.Join(recvTypeArgs, ", ") + "]"
		} else {
			recvInstName = baseRecvName
		}
	} else if recvType != "" {
		recvIsStruct = false
	}

	var funcTypeArgs []string
	if targetFn.Type.TypeParams != nil && len(targetFn.Type.TypeParams.List) > 0 {
		_, _, tpNames, tpConstraints := extractGoastTypeParams(fset, src, targetFn.Type.TypeParams)
		for i, tpName := range tpNames {
			cExpr := "any"
			if i < len(tpConstraints) && tpConstraints[i] != "" {
				cExpr = tpConstraints[i]
			}
			witness := resolveTestWitnessType(cExpr, typeDefs, localInterfaces, combinedAliases, &forcedImports)
			typeSubst[tpName] = witness
			funcTypeArgs = append(funcTypeArgs, witness)
		}
		for pass := 0; pass < 2; pass++ {
			for k, v := range typeSubst {
				typeSubst[k] = substituteGoastTypeExpr(v, typeSubst)
			}
			for i, arg := range funcTypeArgs {
				funcTypeArgs[i] = substituteGoastTypeExpr(arg, typeSubst)
			}
		}
	}

	if len(aliasRemap) > 0 {
		recvType = remapTestTypeSelectors(recvType, aliasRemap)
		recvInstName = remapTestTypeSelectors(recvInstName, aliasRemap)
		for i, a := range funcTypeArgs {
			funcTypeArgs[i] = remapTestTypeSelectors(a, aliasRemap)
		}
	}

	takenTestNames := declaredTestPackageFuncs(testFilePath, existingTestFile)
	testFuncName := strings.TrimSpace(req.TestFuncName)
	if testFuncName == "" {
		stem := targetFuncName
		if baseRecvName != "" {
			stem = baseRecvName + "_" + targetFuncName
		}
		base := "Test" + stem
		if r, _ := utf8.DecodeRuneInString(stem); unicode.IsLower(r) {
			base = "Test_" + stem
		}
		testFuncName = base
		for n := 2; takenTestNames[testFuncName]; n++ {
			testFuncName = fmt.Sprintf("%s%d", base, n)
		}
	} else if takenTestNames[testFuncName] {
		return GenerateTestReply{Error: fmt.Sprintf("%s already exists in the test package. Choose another name.", testFuncName)}
	}

	rawResults, hasErr := extractTestResults(fset, src, targetFn.Type.Results, typeSubst, aliasRemap, typeDefs)
	usedFieldNames := map[string]bool{
		"name":    true,
		"skip":    true,
		"want":    true,
		"wantErr": true,
	}
	for _, r := range rawResults {
		usedFieldNames[r.name] = true
	}
	params := extractTestParams(fset, src, targetFn.Type.Params, typeSubst, aliasRemap, srcAliases, usedFieldNames)

	usedTypeIdents := map[string]bool{
		targetFuncName: true,
	}
	usedNonPkgIdents := map[string]bool{
		targetFuncName: true,
	}
	if baseRecvName != "" {
		usedTypeIdents[baseRecvName] = true
		usedNonPkgIdents[baseRecvName] = true
	}
	collectExprIdentsInto(recvType, usedTypeIdents, true)
	collectExprIdentsInto(recvInstName, usedTypeIdents, true)
	collectExprIdentsInto(recvType, usedNonPkgIdents, false)
	collectExprIdentsInto(recvInstName, usedNonPkgIdents, false)
	for _, fa := range funcTypeArgs {
		collectExprIdentsInto(fa, usedTypeIdents, true)
		collectExprIdentsInto(fa, usedNonPkgIdents, false)
	}
	for _, p := range params {
		collectExprIdentsInto(p.typeExpr, usedTypeIdents, true)
		collectExprIdentsInto(p.typeExpr, usedNonPkgIdents, false)
	}
	for _, r := range rawResults {
		collectExprIdentsInto(r.typeExpr, usedTypeIdents, true)
		collectExprIdentsInto(r.typeExpr, usedNonPkgIdents, false)
	}

	needReflect := false
	for _, r := range rawResults {
		if r.deepEq {
			needReflect = true
			break
		}
	}

	testingPkgIdent := resolveStdPkgIdent("testing", "testing", srcAliases, existingAliases, usedNonPkgIdents, &forcedImports)
	reflectPkgIdent := ""
	if needReflect {
		reflectPkgIdent = resolveStdPkgIdent("reflect", "reflect", srcAliases, existingAliases, usedNonPkgIdents, &forcedImports)
	}
	for i := range params {
		if params[i].isContext {
			desiredAlias := params[i].contextAlias
			if desiredAlias == "" {
				desiredAlias = "context"
			}
			if remapped, ok := aliasRemap[desiredAlias]; ok && remapped != "" {
				desiredAlias = remapped
			}
			params[i].contextAlias = resolveStdPkgIdent(desiredAlias, "context", srcAliases, existingAliases, usedNonPkgIdents, &forcedImports)
		}
	}

	forbiddenLocals := map[string]bool{
		testingPkgIdent: true,
	}
	addGoastReservedPredeclared(forbiddenLocals)
	for k := range testgenStdlibPkgs {
		forbiddenLocals[k] = true
	}
	for k := range combinedAliases {
		forbiddenLocals[k] = true
	}
	for k := range usedTypeIdents {
		forbiddenLocals[k] = true
	}
	if reflectPkgIdent != "" {
		forbiddenLocals[reflectPkgIdent] = true
	}
	for _, p := range params {
		if p.isContext && p.contextAlias != "" {
			forbiddenLocals[p.contextAlias] = true
		}
	}

	testParamName := pickTestLocalVar("t", []string{"testT", "tb", "tst"}, forbiddenLocals)
	forbiddenLocals[testParamName] = true
	subTestParamName := testParamName

	loopVarName := pickTestLocalVar("tt", []string{"tc", "row", "caseItem"}, forbiddenLocals)
	forbiddenLocals[loopVarName] = true

	testsVarName := pickTestLocalVar("tests", []string{"cases", "testCases", "rows"}, forbiddenLocals)
	forbiddenLocals[testsVarName] = true

	errVarName := ""
	if hasErr {
		errVarName = pickTestLocalVar("err", []string{"callErr", "gotErr"}, forbiddenLocals)
		forbiddenLocals[errVarName] = true
	}

	usePrefixedGot := false
	for i := range rawResults {
		if forbiddenLocals[rawResults[i].gotName] {
			usePrefixedGot = true
			break
		}
	}
	for i := range rawResults {
		base := "got"
		if usePrefixedGot {
			base = "gotVal"
		}
		if i > 0 {
			base = fmt.Sprintf("%s%d", base, i)
		}
		cand := pickTestLocalVar(base, []string{base + "Out", "res"}, forbiddenLocals)
		rawResults[i].gotName = cand
		forbiddenLocals[cand] = true
	}

	recvVarName := ""
	recvValVarName := ""
	if baseRecvName != "" || recvType != "" {
		var recvCands []string
		if recvCandidate != "" {
			recvCands = append(recvCands, recvCandidate)
		}
		recvCands = append(recvCands, "r", "recv", "self", "target", "inst")
		recvVarName = pickTestLocalVar(recvCands[0], recvCands[1:], forbiddenLocals)
		forbiddenLocals[recvVarName] = true
		if !recvIsStruct && isPtrRecv {
			recvValVarName = pickTestLocalVar(recvVarName+"Val", []string{"recvVal", "val"}, forbiddenLocals)
			forbiddenLocals[recvValVarName] = true
		}
	}

	previewCode := buildTableDrivenTestCode(tableDrivenTestSpec{
		testFuncName:     testFuncName,
		targetFuncName:   targetFuncName,
		recvType:         recvType,
		baseRecvName:     baseRecvName,
		recvInstName:     recvInstName,
		recvVarName:      recvVarName,
		recvValVarName:   recvValVarName,
		recvIsStruct:     recvIsStruct,
		isPtrRecv:        isPtrRecv,
		funcTypeArgs:     funcTypeArgs,
		params:           params,
		results:          rawResults,
		hasErr:           hasErr,
		includeParallel:  req.IncludeParallel,
		testingPkgIdent:  testingPkgIdent,
		reflectPkgIdent:  reflectPkgIdent,
		testParamName:    testParamName,
		subTestParamName: subTestParamName,
		loopVarName:      loopVarName,
		testsVarName:     testsVarName,
		errVarName:       errVarName,
		typeDefs:         typeDefs,
	})

	reply := GenerateTestReply{
		TargetFuncName: targetFuncName,
		ReceiverType:   recvType,
		TestFuncName:   testFuncName,
		TestFilePath:   testFilePath,
		PreviewCode:    previewCode,
	}

	if req.Apply {
		if testFilePath == "" {
			reply.Error = "cannot apply test without a destination file path"
			return reply
		}
		if err := writeOrAppendTestFile(testFilePath, pkgName, src, file, existingTestSrc, existingTestFile, previewCode, forcedImports, testFuncName, needReflect); err != nil {
			reply.Error = err.Error()
			return reply
		}
		reply.Applied = true
	}

	return reply
}

