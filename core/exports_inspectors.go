package main

import "C"

import (
	"encoding/json"

	"golens/core/analysis"
	"golens/core/safety"
)

// Ownership: arguments are copied; returns a C.malloc'd JSON SafetyAuditReport freed with FreeGoCString.
//
//export RunGoSafetyAudit
func RunGoSafetyAudit(cWorkspaceDir *C.char, cConsoleOutput *C.char) *C.char {
	res, err := safety.RunAudit(C.GoString(cWorkspaceDir), C.GoString(cConsoleOutput))
	if err != nil {
		return C.CString(`{"findings":[],"summary":"Safety audit failed."}`)
	}
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON LiveLintResult freed with FreeGoCString.
//
//export RunGolangCILintPackage
func RunGolangCILintPackage(cWorkspaceRoot *C.char, cPackageDir *C.char) *C.char {
	return C.CString(safety.RunPackageLint(C.GoString(cWorkspaceRoot), C.GoString(cPackageDir)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON PackageAnalyzeResult freed with FreeGoCString.
//
//export RunGoSafetyAnalyzers
func RunGoSafetyAnalyzers(cWorkspaceRoot *C.char, cPackageDir *C.char, cDisabledCategories *C.char) *C.char {
	var workspaceRoot, packageDir, disabled string
	if cWorkspaceRoot != nil {
		workspaceRoot = C.GoString(cWorkspaceRoot)
	}
	if cPackageDir != nil {
		packageDir = C.GoString(cPackageDir)
	}
	if cDisabledCategories != nil {
		disabled = C.GoString(cDisabledCategories)
	}
	return C.CString(analysis.RunPackageAnalyzersJSON(workspaceRoot, packageDir, disabled))
}

// Ownership: workspaceDir is copied; returns a C.malloc'd JSON PackageDependencyReport freed with FreeGoCString.
//
//export InspectGoPackageDeps
func InspectGoPackageDeps(workspaceDir *C.char) *C.char {
	var dir string
	if workspaceDir != nil {
		dir = C.GoString(workspaceDir)
	}
	res, err := analysis.InspectPackageDependencies(dir)
	if err != nil && res == "" {
		return C.CString(`{"modulePath":"","packageCount":0,"stdlibImportCount":0,"externalImportCount":0,"cycles":[],"packages":[]}`)
	}
	return C.CString(res)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON ComplexityReport freed with FreeGoCString.
//
//export InspectGoFunctionComplexity
func InspectGoFunctionComplexity(cDir, cFile, cContent *C.char, includeWorkspace C.int) *C.char {
	var dir, file, content string
	if cDir != nil {
		dir = C.GoString(cDir)
	}
	if cFile != nil {
		file = C.GoString(cFile)
	}
	if cContent != nil {
		content = C.GoString(cContent)
	}
	report, err := analysis.InspectFunctionComplexity(dir, file, content, includeWorkspace != 0)
	if err != nil && report.Error == "" {
		report.Error = err.Error()
	}
	out, mErr := json.Marshal(report)
	if mErr != nil {
		return C.CString(`{"totalFunctions":0,"highCount":0,"moderateCount":0,"goodCount":0,"maxCognitive":0,"averageCyclomatic":0,"functions":[],"summary":"Failed to encode complexity report."}`)
	}
	return C.CString(string(out))
}
