package testutil

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const maxUntestedResults = 200

type UntestedFunc struct {
	TestName  string `json:"testName"`
	FuncName  string `json:"funcName"`
	Receiver  string `json:"receiver,omitempty"`
	Signature string `json:"signature"`
	File      string `json:"file"`
	Line      int    `json:"line"`
}

func UntestedPackageFunctions(pkgDir string) []UntestedFunc {
	if pkgDir == "" {
		return []UntestedFunc{}
	}
	entries, err := os.ReadDir(pkgDir)
	if err != nil {
		return []UntestedFunc{}
	}

	var srcFiles []string
	var testFiles []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".go") {
			continue
		}
		info, statErr := entry.Info()
		if statErr == nil && info.Size() > (1<<20) {
			continue
		}
		fullPath := filepath.Join(pkgDir, name)
		if strings.HasSuffix(name, "_test.go") {
			testFiles = append(testFiles, fullPath)
		} else {
			srcFiles = append(srcFiles, fullPath)
		}
	}

	existingTests := make(map[string]bool)
	testFset := token.NewFileSet()
	for _, tf := range testFiles {
		node, parseErr := parser.ParseFile(testFset, tf, nil, parser.SkipObjectResolution)
		if node == nil || (parseErr != nil && len(node.Decls) == 0) {
			continue
		}
		for _, decl := range node.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name == nil {
				continue
			}
			if isTestFunc(fn) {
				existingTests[fn.Name.Name] = true
			} else if _, isSuiteMethod := suiteMethod(fn); isSuiteMethod {
				existingTests[fn.Name.Name] = true
			}
		}
	}

	srcFset := token.NewFileSet()
	seenTestNames := make(map[string]bool)
	var untested []UntestedFunc
	for _, sf := range srcFiles {
		node, parseErr := parser.ParseFile(srcFset, sf, nil, parser.SkipObjectResolution)
		if node == nil || (parseErr != nil && len(node.Decls) == 0) {
			continue
		}
		for _, decl := range node.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name == nil {
				continue
			}
			funcName := fn.Name.Name
			if !ast.IsExported(funcName) {
				continue
			}
			recvName := ""
			testName := "Test" + funcName
			if fn.Recv != nil && len(fn.Recv.List) > 0 {
				recvName = typeIdentName(fn.Recv.List[0].Type)
				if recvName == "" || !ast.IsExported(recvName) {
					continue
				}
				testName = "Test" + recvName + "_" + funcName
			}
			if isFunctionTested(existingTests, testName) || seenTestNames[testName] {
				continue
			}
			seenTestNames[testName] = true
			sig := formatFuncSignature(srcFset, fn)
			untested = append(untested, UntestedFunc{
				TestName:  testName,
				FuncName:  funcName,
				Receiver:  recvName,
				Signature: sig,
				File:      sf,
				Line:      srcFset.Position(fn.Pos()).Line,
			})
			if len(untested) >= maxUntestedResults {
				break
			}
		}
		if len(untested) >= maxUntestedResults {
			break
		}
	}

	sort.Slice(untested, func(i, j int) bool {
		if untested[i].File != untested[j].File {
			return untested[i].File < untested[j].File
		}
		if untested[i].Line != untested[j].Line {
			return untested[i].Line < untested[j].Line
		}
		return untested[i].TestName < untested[j].TestName
	})

	if untested == nil {
		return []UntestedFunc{}
	}
	return untested
}

func isFunctionTested(existingTests map[string]bool, testName string) bool {
	if existingTests[testName] {
		return true
	}
	prefix := testName + "_"
	for name := range existingTests {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func formatFuncSignature(fset *token.FileSet, fn *ast.FuncDecl) string {
	sigDecl := ast.FuncDecl{
		Recv: fn.Recv,
		Name: fn.Name,
		Type: fn.Type,
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, &sigDecl); err != nil {
		return "func " + fn.Name.Name + "()"
	}
	return strings.TrimSpace(buf.String())
}
