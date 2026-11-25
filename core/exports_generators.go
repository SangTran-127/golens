package main

import "C"

import (
	"encoding/json"

	"golens/core/refactor"
)

// Ownership: arguments are copied; returns a C.malloc'd JSON MockGenResult freed with FreeGoCString.
//
//export GenerateGoInterfaceMock
func GenerateGoInterfaceMock(dir *C.char, file *C.char, line C.int, col C.int, ifaceName *C.char, mockName *C.char) *C.char {
	var goDir, goFile, goIface, goMock string
	if dir != nil {
		goDir = C.GoString(dir)
	}
	if file != nil {
		goFile = C.GoString(file)
	}
	if ifaceName != nil {
		goIface = C.GoString(ifaceName)
	}
	if mockName != nil {
		goMock = C.GoString(mockName)
	}
	res, err := refactor.GenerateInterfaceMock(goDir, goFile, int(line), int(col), goIface, goMock)
	if err != nil {
		b, _ := json.Marshal(refactor.MockGenResult{
			AvailableInterfaces: []string{},
			Error:               err.Error(),
		})
		return C.CString(string(b))
	}
	if res.AvailableInterfaces == nil {
		res.AvailableInterfaces = []string{}
	}
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString(`{"availableInterfaces":[],"error":"failed to marshal mock result"}`)
	}
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON FillStructResult freed with FreeGoCString.
//
//export FillGoStructFields
func FillGoStructFields(dir *C.char, filePath *C.char, content *C.char, line C.int, col C.int) *C.char {
	var goDir, goFile, goContent string
	if dir != nil {
		goDir = C.GoString(dir)
	}
	if filePath != nil {
		goFile = C.GoString(filePath)
	}
	if content != nil {
		goContent = C.GoString(content)
	}
	res, err := refactor.FillStructFields(goDir, goFile, goContent, int(line), int(col))
	if err != nil && res == "" {
		b, _ := json.Marshal(refactor.FillStructResult{
			UpdatedSource: goContent,
			AddedFields:   []string{},
			Error:         err.Error(),
		})
		return C.CString(string(b))
	}
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON EnumMethodsPlan freed with FreeGoCString.
//
//export InspectGoEnumMethods
func InspectGoEnumMethods(cDir, cFile, cContent *C.char, line, col C.int, cTypeName *C.char, trimPrefix, includeParse, includeIsValid, includeValues C.int) *C.char {
	var goDir, goFile, goContent, goTypeName string
	if cDir != nil {
		goDir = C.GoString(cDir)
	}
	if cFile != nil {
		goFile = C.GoString(cFile)
	}
	if cContent != nil {
		goContent = C.GoString(cContent)
	}
	if cTypeName != nil {
		goTypeName = C.GoString(cTypeName)
	}
	plan, err := refactor.InspectEnumMethods(
		goDir,
		goFile,
		goContent,
		int(line),
		int(col),
		goTypeName,
		trimPrefix != 0,
		includeParse != 0,
		includeIsValid != 0,
		includeValues != 0,
	)
	if plan.AvailableEnums == nil {
		plan.AvailableEnums = []string{}
	}
	if plan.Constants == nil {
		plan.Constants = []refactor.EnumConstItem{}
	}
	if err != nil && plan.Error == "" {
		plan.Error = err.Error()
	}
	b, marshalErr := json.Marshal(plan)
	if marshalErr != nil {
		return C.CString(`{"availableEnums":[],"constants":[],"error":"failed to marshal enum methods plan"}`)
	}
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON ConstructorPlan freed with FreeGoCString.
//
//export InspectGoStructConstructor
func InspectGoStructConstructor(cDir, cFile, cContent *C.char, line, col C.int, cStructName *C.char, includeOptions, returnPointer C.int) *C.char {
	var goDir, goFile, goContent, goStruct string
	if cDir != nil {
		goDir = C.GoString(cDir)
	}
	if cFile != nil {
		goFile = C.GoString(cFile)
	}
	if cContent != nil {
		goContent = C.GoString(cContent)
	}
	if cStructName != nil {
		goStruct = C.GoString(cStructName)
	}
	plan, err := refactor.InspectStructConstructor(
		goDir,
		goFile,
		goContent,
		int(line),
		int(col),
		goStruct,
		includeOptions != 0,
		returnPointer != 0,
	)
	if plan.AvailableStructs == nil {
		plan.AvailableStructs = []string{}
	}
	if plan.Fields == nil {
		plan.Fields = []refactor.ConstructorFieldItem{}
	}
	if err != nil && plan.Error == "" {
		plan.Error = err.Error()
	}
	b, marshalErr := json.Marshal(plan)
	if marshalErr != nil {
		return C.CString(`{"availableStructs":[],"fields":[],"error":"failed to marshal constructor plan"}`)
	}
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON FuzzTestPlan freed with FreeGoCString.
//
//export InspectGoFuzzTest
func InspectGoFuzzTest(cDir, cFile, cContent *C.char, line, col C.int, cFuncName *C.char, includeEdgeSeeds, checkDeterminism C.int) *C.char {
	var goDir, goFile, goContent, goFunc string
	if cDir != nil {
		goDir = C.GoString(cDir)
	}
	if cFile != nil {
		goFile = C.GoString(cFile)
	}
	if cContent != nil {
		goContent = C.GoString(cContent)
	}
	if cFuncName != nil {
		goFunc = C.GoString(cFuncName)
	}
	plan, err := refactor.InspectFuzzTest(
		goDir,
		goFile,
		goContent,
		int(line),
		int(col),
		goFunc,
		includeEdgeSeeds != 0,
		checkDeterminism != 0,
	)
	if plan.AvailableFunctions == nil {
		plan.AvailableFunctions = []string{}
	}
	if plan.Params == nil {
		plan.Params = []refactor.FuzzParamItem{}
	}
	if plan.Seeds == nil {
		plan.Seeds = []refactor.FuzzSeedRow{}
	}
	if err != nil && plan.Error == "" {
		plan.Error = err.Error()
	}
	b, marshalErr := json.Marshal(plan)
	if marshalErr != nil {
		return C.CString(`{"availableFunctions":[],"params":[],"seeds":[],"error":"failed to marshal fuzz test plan"}`)
	}
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON BenchmarkGenPlan freed with FreeGoCString.
//
//export InspectGoBenchmarkGen
func InspectGoBenchmarkGen(
	cDir, cFile, cContent *C.char,
	line, col C.int,
	cFuncName *C.char,
	reportAllocs, runParallel, tableSubBench C.int,
) *C.char {
	dir := C.GoString(cDir)
	filePath := C.GoString(cFile)
	content := C.GoString(cContent)
	funcName := C.GoString(cFuncName)
	plan, err := refactor.InspectBenchmarkGen(
		dir,
		filePath,
		content,
		int(line),
		int(col),
		funcName,
		reportAllocs != 0,
		runParallel != 0,
		tableSubBench != 0,
	)
	if plan.AvailableFuncs == nil {
		plan.AvailableFuncs = []string{}
	}
	if plan.Params == nil {
		plan.Params = []refactor.BenchmarkParamInfo{}
	}
	if err != nil && plan.Error == "" {
		plan.Error = err.Error()
	}
	b, marshalErr := json.Marshal(plan)
	if marshalErr != nil {
		return C.CString(`{"availableFuncs":[],"params":[],"error":"failed to marshal benchmark plan"}`)
	}
	return C.CString(string(b))
}
