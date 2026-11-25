package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type NumericSafetyIssue struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	FuncName           string `json:"funcName"`
	Expr               string `json:"expr"`
	Message            string `json:"message"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	ReplacementPreview string `json:"replacementPreview"`
	CanAutoFix         bool   `json:"canAutoFix"`
}

type NumericSafetyInspectResult struct {
	Issues                []NumericSafetyIssue `json:"issues"`
	NarrowConversionCount int                  `json:"narrowConversionCount"`
	FloatEqualityCount    int                  `json:"floatEqualityCount"`
	UnguardedDivCount     int                  `json:"unguardedDivCount"`
	Error                 string               `json:"error,omitempty"`
}

type NumericSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type NumericSafetyIssueItem = NumericSafetyIssue
type NumericSafetyInspectResponse = NumericSafetyInspectResult
type NumericSafetyFixResponse = NumericSafetyFixResult

type NumericSafetyInspectRequest struct {
	Content   string `json:"content"`
	FilePath  string `json:"filePath"`
	Path      string `json:"path,omitempty"`
	Workspace string `json:"workspace,omitempty"`
}

type NumericSafetyFixRequest struct {
	Content   string `json:"content"`
	FilePath  string `json:"filePath"`
	Path      string `json:"path,omitempty"`
	Workspace string `json:"workspace,omitempty"`
	IssueID   string `json:"issueId"`
	All       bool   `json:"all"`
	ApplyAll  bool   `json:"applyAll,omitempty"`
}

type numericSafetyCandidate struct {
	issue        NumericSafetyIssue
	replaceStart int
	replaceEnd   int
	replaceText  string
	needsMathPkg bool
}

type narrowIntTargetSpec struct {
	typeName string
	bitSize  int
	unsigned bool
	minBound string
	maxBound string
}

var narrowIntTargetSpecs = map[string]narrowIntTargetSpec{
	"int32": {
		typeName: "int32",
		bitSize:  32,
		unsigned: false,
		minBound: "math.MinInt32",
		maxBound: "math.MaxInt32",
	},
	"int16": {
		typeName: "int16",
		bitSize:  16,
		unsigned: false,
		minBound: "math.MinInt16",
		maxBound: "math.MaxInt16",
	},
	"int8": {
		typeName: "int8",
		bitSize:  8,
		unsigned: false,
		minBound: "math.MinInt8",
		maxBound: "math.MaxInt8",
	},
	"uint32": {
		typeName: "uint32",
		bitSize:  32,
		unsigned: true,
		minBound: "0",
		maxBound: "math.MaxUint32",
	},
	"uint16": {
		typeName: "uint16",
		bitSize:  16,
		unsigned: true,
		minBound: "0",
		maxBound: "math.MaxUint16",
	},
	"uint8": {
		typeName: "uint8",
		bitSize:  8,
		unsigned: true,
		minBound: "0",
		maxBound: "math.MaxUint8",
	},
}

type numericScopeInfo struct {
	wideIntIdents   map[string]string
	narrowIntIdents map[string]int
	float64Idents   map[string]bool
	float32Idents   map[string]bool
	nonZeroConsts   map[string]bool
	structFloatFlds map[string]string
	boundsGuards    guardIndexCache
	zeroGuards      guardIndexCache
}

func InspectGoNumericSafety(content string, filePath string) (NumericSafetyInspectResult, error) {
	return inspectGoNumericSafetyWithWorkspace(content, filePath, "")
}

func inspectGoNumericSafetyWithWorkspace(content string, filePath string, workspace string) (NumericSafetyInspectResult, error) {
	res := NumericSafetyInspectResult{
		Issues: []NumericSafetyIssue{},
	}

	src, parsePath, err := resolveNumericSafetySource(filePath, content, workspace)
	if err != nil {
		res.Error = err.Error()
		return res, err
	}
	if strings.TrimSpace(src) == "" {
		return res, nil
	}

	fset := token.NewFileSet()
	astFile, parseErr := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		if parseErr != nil {
			res.Error = parseErr.Error()
			return res, parseErr
		}
		return res, nil
	}

	candidates := collectNumericSafetyCandidates(fset, astFile, src)
	issues := make([]NumericSafetyIssue, 0, len(candidates))
	for _, cand := range candidates {
		iss := cand.issue
		issues = append(issues, iss)
		switch iss.Category {
		case "narrow_int_conversion":
			res.NarrowConversionCount++
		case "float_exact_equality":
			res.FloatEqualityCount++
		case "unguarded_division":
			res.UnguardedDivCount++
		}
	}
	res.Issues = issues
	return res, nil
}

func ApplyGoNumericSafetyFixes(content string, filePath string, issueID string, applyAll bool) (NumericSafetyFixResult, error) {
	return applyGoNumericSafetyFixesWithWorkspace(content, filePath, "", issueID, applyAll)
}

func applyGoNumericSafetyFixesWithWorkspace(
	content string,
	filePath string,
	workspace string,
	issueID string,
	applyAll bool,
) (NumericSafetyFixResult, error) {
	src, parsePath, err := resolveNumericSafetySource(filePath, content, workspace)
	if err != nil {
		return NumericSafetyFixResult{
			NewContent: content,
			Error:      err.Error(),
		}, err
	}
	if strings.TrimSpace(src) == "" {
		return NumericSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
		}, nil
	}

	currentSrc := src
	fixedCount := 0
	needsMathImport := false
	targetID := strings.TrimSpace(issueID)

	if !applyAll {
		fset := token.NewFileSet()
		astFile, parseErr := parser.ParseFile(fset, parsePath, currentSrc, parser.ParseComments)
		if astFile == nil {
			errMsg := "failed to parse Go source"
			if parseErr != nil {
				errMsg = parseErr.Error()
			}
			return NumericSafetyFixResult{
				NewContent: currentSrc,
				Error:      errMsg,
			}, parseErr
		}

		candidates := collectNumericSafetyCandidates(fset, astFile, currentSrc)
		var chosen *numericSafetyCandidate
		for i := range candidates {
			if !candidates[i].issue.CanAutoFix {
				continue
			}
			if targetID == "" || candidates[i].issue.ID == targetID {
				chosen = &candidates[i]
				break
			}
		}

		if chosen == nil {
			errMsg := ""
			if targetID != "" {
				errMsg = fmt.Sprintf("numeric safety issue %q not found", targetID)
			}
			var notFoundErr error
			if errMsg != "" {
				notFoundErr = fmt.Errorf("%s", errMsg)
			}
			return NumericSafetyFixResult{
				NewContent: currentSrc,
				FixedCount: 0,
				Error:      errMsg,
			}, notFoundErr
		}

		updatedSrc, ok := applySingleNumericSafetyCandidate(currentSrc, *chosen)
		if ok && updatedSrc != currentSrc {
			currentSrc = updatedSrc
			fixedCount = 1
			if chosen.needsMathPkg {
				needsMathImport = true
			}
		}
	} else {
		fixer := numericSafetyFixer(parsePath)
		fixer.applied = func(c numericSafetyCandidate) {
			if c.needsMathPkg {
				needsMathImport = true
			}
		}
		currentSrc, fixedCount, _ = fixer.run(currentSrc)
	}

	if fixedCount > 0 {
		if needsMathImport {
			currentSrc = ensureGoImport(parsePath, currentSrc, "math")
		}
		if formatted, fmtErr := format.Source([]byte(currentSrc)); fmtErr == nil {
			currentSrc = string(formatted)
		}
	}

	return NumericSafetyFixResult{
		NewContent: currentSrc,
		FixedCount: fixedCount,
	}, nil
}

func InspectNumericSafety(reqJSON string) string {
	var req NumericSafetyInspectRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalNumericInspectResult(NumericSafetyInspectResult{
				Issues: []NumericSafetyIssue{},
				Error:  err.Error(),
			})
		}
	}
	targetPath := strings.TrimSpace(req.FilePath)
	if targetPath == "" {
		targetPath = strings.TrimSpace(req.Path)
	}
	res, _ := inspectGoNumericSafetyWithWorkspace(req.Content, targetPath, req.Workspace)
	return marshalNumericInspectResult(res)
}

func ApplyNumericSafetyFix(reqJSON string) string {
	var req NumericSafetyFixRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalNumericFixResult(NumericSafetyFixResult{
				Error: err.Error(),
			})
		}
		if strings.TrimSpace(req.IssueID) == "" {
			var alt struct {
				IssueID string `json:"issueID"`
			}
			if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.IssueID) != "" {
				req.IssueID = alt.IssueID
			}
		}
	}
	targetPath := strings.TrimSpace(req.FilePath)
	if targetPath == "" {
		targetPath = strings.TrimSpace(req.Path)
	}
	res, _ := applyGoNumericSafetyFixesWithWorkspace(req.Content, targetPath, req.Workspace, req.IssueID, req.All || req.ApplyAll)
	return marshalNumericFixResult(res)
}

func marshalNumericInspectResult(res NumericSafetyInspectResult) string {
	if res.Issues == nil {
		res.Issues = []NumericSafetyIssue{}
	}
	data, err := json.Marshal(res)
	if err != nil {
		return `{"issues":[],"narrowConversionCount":0,"floatEqualityCount":0,"unguardedDivCount":0,"error":"failed to marshal numeric inspect result"}`
	}
	return string(data)
}

func marshalNumericFixResult(res NumericSafetyFixResult) string {
	data, err := json.Marshal(res)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"failed to marshal numeric fix result"}`
	}
	return string(data)
}

func resolveNumericSafetySource(filePath, content, workspace string) (string, string, error) {
	trimmedPath := strings.TrimSpace(filePath)
	parsePath := trimmedPath
	if parsePath == "" {
		parsePath = "input.go"
	}

	if content != "" {
		return content, parsePath, nil
	}
	if trimmedPath == "" {
		return "", parsePath, nil
	}

	if !filepath.IsAbs(trimmedPath) && strings.TrimSpace(workspace) != "" {
		candidate := filepath.Join(strings.TrimSpace(workspace), trimmedPath)
		if data, err := os.ReadFile(candidate); err == nil {
			return string(data), candidate, nil
		}
	}

	data, err := os.ReadFile(trimmedPath)
	if err != nil {
		return "", parsePath, err
	}
	return string(data), trimmedPath, nil
}

func applySingleNumericSafetyCandidate(src string, cand numericSafetyCandidate) (string, bool) {
	if cand.replaceStart < 0 || cand.replaceEnd <= cand.replaceStart || cand.replaceEnd > len(src) {
		return src, false
	}
	updated := src[:cand.replaceStart] + cand.replaceText + src[cand.replaceEnd:]
	return updated, true
}

func collectNumericSafetyCandidates(
	fset *token.FileSet,
	file *ast.File,
	src string,
) []numericSafetyCandidate {
	var candidates []numericSafetyCandidate

	baseScope := collectPackageNumericScope(file)

	inspectScope := func(rootNode ast.Node, fnType *ast.FuncType, recv *ast.FieldList, funcName string) {
		if rootNode == nil {
			return
		}

		scope := cloneNumericScope(baseScope)
		populateFuncNumericScope(&scope, recv, fnType, rootNode)

		ast.Inspect(rootNode, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if n != rootNode {
				if _, isLit := n.(*ast.FuncLit); isLit {
					return false
				}
			}

			switch node := n.(type) {
			case *ast.CallExpr:
				if cand, ok := detectNarrowIntConversion(fset, node, rootNode, funcName, scope, src); ok {
					candidates = append(candidates, cand)
				}

			case *ast.BinaryExpr:
				if cand, ok := detectFloatExactEquality(fset, node, funcName, scope, src); ok {
					candidates = append(candidates, cand)
				}
				if cand, ok := detectUnguardedDivision(fset, node, rootNode, funcName, scope, src); ok {
					candidates = append(candidates, cand)
				}
			}

			return true
		})
	}

	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			fnName := ""
			if d.Name != nil {
				fnName = d.Name.Name
			}
			if d.Body != nil {
				inspectScope(d.Body, d.Type, d.Recv, fnName)
				ast.Inspect(d.Body, func(n ast.Node) bool {
					if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
						inspectScope(lit.Body, lit.Type, nil, fnName)
					}
					return true
				})
			}
		case *ast.GenDecl:
			if d.Tok == token.IMPORT {
				continue
			}
			ast.Inspect(d, func(n ast.Node) bool {
				if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
					inspectScope(lit.Body, lit.Type, nil, "")
					return false
				}
				return true
			})
			inspectScope(d, nil, nil, "")
		}
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].issue.Line != candidates[j].issue.Line {
			return candidates[i].issue.Line < candidates[j].issue.Line
		}
		if candidates[i].issue.Column != candidates[j].issue.Column {
			return candidates[i].issue.Column < candidates[j].issue.Column
		}
		return candidates[i].issue.Category < candidates[j].issue.Category
	})

	return candidates
}

func newNumericScopeInfo() numericScopeInfo {
	return numericScopeInfo{
		wideIntIdents:   make(map[string]string),
		narrowIntIdents: make(map[string]int),
		float64Idents:   make(map[string]bool),
		float32Idents:   make(map[string]bool),
		nonZeroConsts:   make(map[string]bool),
		structFloatFlds: make(map[string]string),
		boundsGuards:    guardIndexCache{},
		zeroGuards:      guardIndexCache{},
	}
}

func cloneNumericScope(src numericScopeInfo) numericScopeInfo {
	dst := newNumericScopeInfo()
	if src.boundsGuards != nil {
		dst.boundsGuards = src.boundsGuards
	}
	if src.zeroGuards != nil {
		dst.zeroGuards = src.zeroGuards
	}
	for k, v := range src.wideIntIdents {
		dst.wideIntIdents[k] = v
	}
	for k, v := range src.narrowIntIdents {
		dst.narrowIntIdents[k] = v
	}
	for k, v := range src.float64Idents {
		dst.float64Idents[k] = v
	}
	for k, v := range src.float32Idents {
		dst.float32Idents[k] = v
	}
	for k, v := range src.nonZeroConsts {
		dst.nonZeroConsts[k] = v
	}
	for k, v := range src.structFloatFlds {
		dst.structFloatFlds[k] = v
	}
	return dst
}

func collectPackageNumericScope(file *ast.File) numericScopeInfo {
	scope := newNumericScopeInfo()
	if file == nil {
		return scope
	}

	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}

		switch gd.Tok {
		case token.TYPE:
			for _, spec := range gd.Specs {
				ts, isTS := spec.(*ast.TypeSpec)
				if !isTS || ts.Type == nil {
					continue
				}
				st, isStruct := ts.Type.(*ast.StructType)
				if !isStruct || st.Fields == nil {
					continue
				}
				for _, field := range st.Fields.List {
					typeName := extractBasicNumericTypeName(field.Type)
					if typeName == "float64" || typeName == "float32" {
						for _, ident := range field.Names {
							if ident != nil && ident.Name != "" {
								scope.structFloatFlds[ident.Name] = typeName
							}
						}
					}
				}
			}

		case token.CONST:
			for _, spec := range gd.Specs {
				vs, isVS := spec.(*ast.ValueSpec)
				if !isVS {
					continue
				}
				typeName := extractBasicNumericTypeName(vs.Type)
				for idx, ident := range vs.Names {
					if ident == nil || ident.Name == "" || ident.Name == "_" {
						continue
					}
					recordExplicitNumericType(&scope, ident.Name, typeName)
					if idx < len(vs.Values) {
						val := vs.Values[idx]
						recordInferredNumericExpr(&scope, ident.Name, val)
						if isNonZeroNumericLiteralExpr(val) {
							scope.nonZeroConsts[ident.Name] = true
						}
					}
				}
			}

		case token.VAR:
			for _, spec := range gd.Specs {
				vs, isVS := spec.(*ast.ValueSpec)
				if !isVS {
					continue
				}
				typeName := extractBasicNumericTypeName(vs.Type)
				for idx, ident := range vs.Names {
					if ident == nil || ident.Name == "" || ident.Name == "_" {
						continue
					}
					recordExplicitNumericType(&scope, ident.Name, typeName)
					if idx < len(vs.Values) {
						recordInferredNumericExpr(&scope, ident.Name, vs.Values[idx])
					}
				}
			}
		default:
		}
	}

	return scope
}

func populateFuncNumericScope(
	scope *numericScopeInfo,
	recv *ast.FieldList,
	fnType *ast.FuncType,
	rootNode ast.Node,
) {
	recordFieldList := func(fl *ast.FieldList) {
		if fl == nil {
			return
		}
		for _, field := range fl.List {
			typeName := extractBasicNumericTypeName(field.Type)
			if typeName == "" {
				continue
			}
			for _, ident := range field.Names {
				if ident != nil && ident.Name != "" && ident.Name != "_" {
					recordExplicitNumericType(scope, ident.Name, typeName)
				}
			}
		}
	}

	recordFieldList(recv)
	if fnType != nil {
		recordFieldList(fnType.Params)
		recordFieldList(fnType.Results)
	}

	for pass := 0; pass < 2; pass++ {
		ast.Inspect(rootNode, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if n != rootNode {
				if _, isLit := n.(*ast.FuncLit); isLit {
					return false
				}
			}

			switch stmt := n.(type) {
			case *ast.DeclStmt:
				gd, ok := stmt.Decl.(*ast.GenDecl)
				if !ok {
					return true
				}
				for _, spec := range gd.Specs {
					vs, isVS := spec.(*ast.ValueSpec)
					if !isVS {
						continue
					}
					typeName := extractBasicNumericTypeName(vs.Type)
					for idx, ident := range vs.Names {
						if ident == nil || ident.Name == "" || ident.Name == "_" {
							continue
						}
						if gd.Tok == token.CONST && idx < len(vs.Values) && isNonZeroNumericLiteralExpr(vs.Values[idx]) {
							scope.nonZeroConsts[ident.Name] = true
						}
						recordExplicitNumericType(scope, ident.Name, typeName)
						if idx < len(vs.Values) {
							recordInferredNumericExpr(scope, ident.Name, vs.Values[idx])
						}
					}
				}

			case *ast.AssignStmt:
				if len(stmt.Rhs) == 1 {
					rhs := stmt.Rhs[0]
					if origin, isWideCall, minBitSize := matchWideIntCallExpr(rhs); isWideCall {
						if len(stmt.Lhs) >= 1 {
							if ident, ok := stmt.Lhs[0].(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
								delete(scope.nonZeroConsts, ident.Name)
								if minBitSize > 0 && minBitSize <= 32 {
									scope.narrowIntIdents[ident.Name] = minBitSize
								} else {
									scope.wideIntIdents[ident.Name] = origin
									delete(scope.narrowIntIdents, ident.Name)
								}
							}
						}
						return true
					}
					if fKind := classifyFloatExpr(rhs, *scope); fKind != "" {
						if len(stmt.Lhs) >= 1 {
							if ident, ok := stmt.Lhs[0].(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
								recordExplicitNumericType(scope, ident.Name, fKind)
							}
						}
						return true
					}
				}

				for idx, lhs := range stmt.Lhs {
					ident, ok := lhs.(*ast.Ident)
					if !ok || ident.Name == "" || ident.Name == "_" {
						continue
					}
					delete(scope.nonZeroConsts, ident.Name)
					if idx < len(stmt.Rhs) {
						recordInferredNumericExpr(scope, ident.Name, stmt.Rhs[idx])
					}
				}

			case *ast.RangeStmt:
				if ident, ok := stmt.Key.(*ast.Ident); ok && ident.Name != "" && ident.Name != "_" {
					scope.wideIntIdents[ident.Name] = "int"
				}
			}

			return true
		})
	}
}

func extractBasicNumericTypeName(typeExpr ast.Expr) string {
	expr := unwrapNumericParens(typeExpr)
	ident, ok := expr.(*ast.Ident)
	if !ok {
		return ""
	}
	switch ident.Name {
	case "int", "int64", "uint", "uint64", "uintptr",
		"int32", "int16", "int8", "uint32", "uint16", "uint8", "byte", "rune",
		"float64", "float32":
		return ident.Name
	default:
		return ""
	}
}

func recordExplicitNumericType(scope *numericScopeInfo, name string, typeName string) {
	if scope == nil || name == "" || name == "_" || typeName == "" {
		return
	}
	switch typeName {
	case "int", "int64", "uint", "uint64", "uintptr":
		scope.wideIntIdents[name] = typeName
		delete(scope.narrowIntIdents, name)
	case "int32", "uint32", "rune":
		scope.narrowIntIdents[name] = 32
		delete(scope.wideIntIdents, name)
	case "int16", "uint16":
		scope.narrowIntIdents[name] = 16
		delete(scope.wideIntIdents, name)
	case "int8", "uint8", "byte":
		scope.narrowIntIdents[name] = 8
		delete(scope.wideIntIdents, name)
	case "float64":
		scope.float64Idents[name] = true
		delete(scope.float32Idents, name)
	case "float32":
		scope.float32Idents[name] = true
		delete(scope.float64Idents, name)
	}
}

func recordInferredNumericExpr(scope *numericScopeInfo, name string, expr ast.Expr) {
	if scope == nil || name == "" || name == "_" || expr == nil {
		return
	}
	unwrapped := unwrapNumericParens(expr)

	if origin, isWide, minBitSize := matchWideIntCallExpr(unwrapped); isWide {
		if minBitSize > 0 && minBitSize <= 32 {
			scope.narrowIntIdents[name] = minBitSize
		} else {
			scope.wideIntIdents[name] = origin
			delete(scope.narrowIntIdents, name)
		}
		return
	}

	if fKind := classifyFloatExpr(unwrapped, *scope); fKind != "" {
		recordExplicitNumericType(scope, name, fKind)
		return
	}

	if call, isCall := unwrapped.(*ast.CallExpr); isCall && len(call.Args) == 1 {
		if ident, isIdent := unwrapNumericParens(call.Fun).(*ast.Ident); isIdent {
			switch ident.Name {
			case "int", "int64", "uint", "uint64", "uintptr",
				"int32", "int16", "int8", "uint32", "uint16", "uint8", "byte", "rune",
				"float64", "float32":
				recordExplicitNumericType(scope, name, ident.Name)
				return
			}
		}
	}

	if isWideIntExpr(unwrapped, *scope) {
		if _, alreadySet := scope.wideIntIdents[name]; !alreadySet {
			scope.wideIntIdents[name] = "int"
		}
	}
}

func matchWideIntCallExpr(expr ast.Expr) (origin string, isWide bool, constrainedBitSize int) {
	call, ok := unwrapNumericParens(expr).(*ast.CallExpr)
	if !ok {
		return "", false, 0
	}

	if ident, isIdent := unwrapNumericParens(call.Fun).(*ast.Ident); isIdent {
		switch ident.Name {
		case "len", "cap", "int", "int64", "uint", "uint64", "uintptr":
			if len(call.Args) == 1 {
				return ident.Name + "(...)", true, 0
			}
		}
	}

	sel, isSel := unwrapNumericParens(call.Fun).(*ast.SelectorExpr)
	if !isSel || sel.Sel == nil {
		return "", false, 0
	}

	if pkgIdent, isIdent := sel.X.(*ast.Ident); isIdent {
		pkg := pkgIdent.Name
		fn := sel.Sel.Name
		if pkg == "strconv" {
			switch fn {
			case "Atoi":
				if len(call.Args) == 1 {
					return "strconv.Atoi", true, 0
				}
			case "ParseInt", "ParseUint":
				if len(call.Args) == 3 {
					bitSize := extractIntLiteralValue(call.Args[2])
					if bitSize == 8 || bitSize == 16 || bitSize == 32 {
						return "strconv." + fn, true, bitSize
					}
					return "strconv." + fn, true, 0
				}
			}
		}
		if pkg == "time" && (fn == "Since" || fn == "Until") {
			return "time." + fn, true, 0
		}
	}

	switch sel.Sel.Name {
	case "Size", "Unix", "UnixMilli", "UnixMicro", "UnixNano", "Nanoseconds", "Microseconds", "Milliseconds", "Len", "Cap", "Count":
		if len(call.Args) == 0 {
			return "." + sel.Sel.Name + "()", true, 0
		}
	}

	return "", false, 0
}

func detectNarrowIntConversion(
	fset *token.FileSet,
	call *ast.CallExpr,
	enclosingRoot ast.Node,
	funcName string,
	scope numericScopeInfo,
	src string,
) (numericSafetyCandidate, bool) {
	if call == nil || len(call.Args) != 1 {
		return numericSafetyCandidate{}, false
	}

	funIdent, ok := unwrapNumericParens(call.Fun).(*ast.Ident)
	if !ok {
		return numericSafetyCandidate{}, false
	}

	spec, isTarget := narrowIntTargetSpecs[funIdent.Name]
	if !isTarget {
		return numericSafetyCandidate{}, false
	}

	arg := unwrapNumericParens(call.Args[0])
	if arg == nil || isSafeNarrowConversionArg(arg, spec, scope) {
		return numericSafetyCandidate{}, false
	}

	var varName string
	var originDesc string

	switch a := arg.(type) {
	case *ast.Ident:
		if a.Name == "" || a.Name == "_" || a.Name == "iota" {
			return numericSafetyCandidate{}, false
		}
		if scope.nonZeroConsts[a.Name] {
			return numericSafetyCandidate{}, false
		}
		if narrowBits, isNarrow := scope.narrowIntIdents[a.Name]; isNarrow && narrowBits <= spec.bitSize {
			return numericSafetyCandidate{}, false
		}
		if scope.float64Idents[a.Name] || scope.float32Idents[a.Name] {
			return numericSafetyCandidate{}, false
		}
		origin, isKnownWide := scope.wideIntIdents[a.Name]
		if !isKnownWide {
			if narrowBits, isNarrow := scope.narrowIntIdents[a.Name]; isNarrow && narrowBits > spec.bitSize {
				origin = fmt.Sprintf("int%d", narrowBits)
			} else {
				return numericSafetyCandidate{}, false
			}
		}
		if enclosingRoot != nil && scope.boundsGuards.get(enclosingRoot, buildBoundsGuardIndex).before(a.Name, call.Pos()) {
			return numericSafetyCandidate{}, false
		}
		varName = a.Name
		originDesc = origin

	case *ast.CallExpr:
		origin, isWideCall, constrainedBits := matchWideIntCallExpr(a)
		if !isWideCall || (constrainedBits > 0 && constrainedBits <= spec.bitSize) {
			return numericSafetyCandidate{}, false
		}
		varName = strings.TrimSpace(numericSliceNodeText(fset, src, arg))
		originDesc = origin

	default:
		if !isWideIntExpr(arg, scope) {
			return numericSafetyCandidate{}, false
		}
		varName = strings.TrimSpace(numericSliceNodeText(fset, src, arg))
		originDesc = "wide integer expression"
	}

	argStr := strings.TrimSpace(numericSliceNodeText(fset, src, call.Args[0]))
	if argStr == "" {
		return numericSafetyCandidate{}, false
	}

	pos := fset.Position(call.Pos())
	endPos := fset.Position(call.End())
	exprStr := strings.TrimSpace(numericSliceNodeText(fset, src, call))

	replacement := fmt.Sprintf("%s(min(max(%s, %s), %s))", spec.typeName, argStr, spec.minBound, spec.maxBound)

	msg := fmt.Sprintf(
		"Narrow integer conversion %s from %s (%s) without bounds check can silently overflow or truncate",
		exprStr,
		varName,
		originDesc,
	)
	suggestion := fmt.Sprintf(
		"Clamp %s to [%s, %s] using min/max before converting to %s",
		argStr,
		spec.minBound,
		spec.maxBound,
		spec.typeName,
	)

	id := fmt.Sprintf("narrow_int_conversion:%d:%d", pos.Line, pos.Column)
	return numericSafetyCandidate{
		issue: NumericSafetyIssue{
			ID:                 id,
			Category:           "narrow_int_conversion",
			Severity:           "warning",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               exprStr,
			Message:            msg,
			Suggestion:         suggestion,
			FixTitle:           fmt.Sprintf("Clamp with min/max (%s..%s)", spec.minBound, spec.maxBound),
			ReplacementPreview: replacement,
			CanAutoFix:         pos.Offset >= 0 && endPos.Offset > pos.Offset,
		},
		replaceStart: pos.Offset,
		replaceEnd:   endPos.Offset,
		replaceText:  replacement,
		needsMathPkg: true,
	}, true
}

func isSafeNarrowConversionArg(arg ast.Expr, spec narrowIntTargetSpec, _ numericScopeInfo) bool {
	unwrapped := unwrapNumericParens(arg)
	switch node := unwrapped.(type) {
	case *ast.BasicLit:
		return true
	case *ast.UnaryExpr:
		if node.Op == token.SUB || node.Op == token.ADD {
			if _, isLit := unwrapNumericParens(node.X).(*ast.BasicLit); isLit {
				return true
			}
		}
	case *ast.CallExpr:
		if ident, isIdent := unwrapNumericParens(node.Fun).(*ast.Ident); isIdent {
			if ident.Name == "min" || ident.Name == "max" {
				return true
			}
			if innerSpec, ok := narrowIntTargetSpecs[ident.Name]; ok && innerSpec.bitSize <= spec.bitSize {
				return true
			}
		}
	}
	return false
}

func detectFloatExactEquality(
	fset *token.FileSet,
	bin *ast.BinaryExpr,
	funcName string,
	scope numericScopeInfo,
	src string,
) (numericSafetyCandidate, bool) {
	if bin == nil || (bin.Op != token.EQL && bin.Op != token.NEQ) {
		return numericSafetyCandidate{}, false
	}

	leftKind := classifyFloatExpr(bin.X, scope)
	rightKind := classifyFloatExpr(bin.Y, scope)
	if leftKind == "" && rightKind == "" {
		return numericSafetyCandidate{}, false
	}

	lhsStr := strings.TrimSpace(numericSliceNodeText(fset, src, bin.X))
	rhsStr := strings.TrimSpace(numericSliceNodeText(fset, src, bin.Y))
	if lhsStr == "" || rhsStr == "" {
		return numericSafetyCandidate{}, false
	}

	isFloat32 := leftKind == "float32" || rightKind == "float32"
	cmpOp := "<"
	if bin.Op == token.NEQ {
		cmpOp = ">="
	}

	var replacement string
	if isFloat32 {
		leftArg := wrapFloat64ConversionIfNeeded(bin.X, lhsStr)
		rightArg := wrapFloat64ConversionIfNeeded(bin.Y, rhsStr)
		replacement = fmt.Sprintf("math.Abs(%s-%s) %s 1e-9", leftArg, rightArg, cmpOp)
	} else {
		leftSub := formatFloatSubtractionLeft(bin.X, lhsStr)
		rightSub := formatFloatSubtractionRight(bin.Y, rhsStr)
		replacement = fmt.Sprintf("math.Abs(%s-%s) %s 1e-9", leftSub, rightSub, cmpOp)
	}

	pos := fset.Position(bin.Pos())
	endPos := fset.Position(bin.End())
	exprStr := strings.TrimSpace(numericSliceNodeText(fset, src, bin))

	id := fmt.Sprintf("float_exact_equality:%d:%d", pos.Line, pos.Column)
	return numericSafetyCandidate{
		issue: NumericSafetyIssue{
			ID:                 id,
			Category:           "float_exact_equality",
			Severity:           "warning",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               exprStr,
			Message:            fmt.Sprintf("Exact floating-point comparison (%s) is fragile due to IEEE-754 rounding errors", exprStr),
			Suggestion:         fmt.Sprintf("Replace exact %s comparison with an epsilon check: %s", bin.Op.String(), replacement),
			FixTitle:           "Rewrite to math.Abs epsilon comparison",
			ReplacementPreview: replacement,
			CanAutoFix:         pos.Offset >= 0 && endPos.Offset > pos.Offset,
		},
		replaceStart: pos.Offset,
		replaceEnd:   endPos.Offset,
		replaceText:  replacement,
		needsMathPkg: true,
	}, true
}

func wrapFloat64ConversionIfNeeded(expr ast.Expr, raw string) string {
	unwrapped := unwrapNumericParens(expr)
	if call, isCall := unwrapped.(*ast.CallExpr); isCall && len(call.Args) == 1 {
		if ident, isIdent := unwrapNumericParens(call.Fun).(*ast.Ident); isIdent && ident.Name == "float64" {
			return raw
		}
	}
	return fmt.Sprintf("float64(%s)", raw)
}

func formatFloatSubtractionLeft(_ ast.Expr, raw string) string {
	return raw
}

func formatFloatSubtractionRight(expr ast.Expr, raw string) string {
	switch e := expr.(type) {
	case *ast.BinaryExpr:
		if e.Op == token.ADD || e.Op == token.SUB {
			return fmt.Sprintf("(%s)", raw)
		}
	case *ast.UnaryExpr:
		if e.Op == token.SUB || e.Op == token.ADD {
			return fmt.Sprintf("(%s)", raw)
		}
	}
	return raw
}

func classifyFloatExpr(expr ast.Expr, scope numericScopeInfo) string {
	if expr == nil {
		return ""
	}
	unwrapped := unwrapNumericParens(expr)

	switch node := unwrapped.(type) {
	case *ast.BasicLit:
		if node.Kind == token.FLOAT {
			return "float64"
		}
	case *ast.UnaryExpr:
		if node.Op == token.SUB || node.Op == token.ADD {
			return classifyFloatExpr(node.X, scope)
		}
	case *ast.Ident:
		if scope.float32Idents[node.Name] {
			return "float32"
		}
		if scope.float64Idents[node.Name] {
			return "float64"
		}
	case *ast.SelectorExpr:
		if node.Sel != nil {
			if fType, ok := scope.structFloatFlds[node.Sel.Name]; ok {
				return fType
			}
			if pkgIdent, isIdent := node.X.(*ast.Ident); isIdent && pkgIdent.Name == "math" {
				switch node.Sel.Name {
				case "Pi", "E", "Phi", "Sqrt2", "SqrtE", "SqrtPi", "SqrtPhi", "Ln2", "Log2E", "Ln10", "Log10E",
					"MaxFloat64", "SmallestNonzeroFloat64":
					return "float64"
				case "MaxFloat32", "SmallestNonzeroFloat32":
					return "float32"
				}
			}
		}
	case *ast.CallExpr:
		if fKind := classifyFloatCallExpr(node); fKind != "" {
			return fKind
		}
	case *ast.BinaryExpr:
		switch node.Op {
		case token.ADD, token.SUB, token.MUL, token.QUO:
			lk := classifyFloatExpr(node.X, scope)
			if lk != "" {
				return lk
			}
			rk := classifyFloatExpr(node.Y, scope)
			if rk != "" {
				return rk
			}
		default:
		}
	}

	return ""
}

func classifyFloatCallExpr(call *ast.CallExpr) string {
	if call == nil {
		return ""
	}
	if ident, isIdent := unwrapNumericParens(call.Fun).(*ast.Ident); isIdent && len(call.Args) == 1 {
		if ident.Name == "float64" || ident.Name == "float32" {
			return ident.Name
		}
	}
	sel, isSel := unwrapNumericParens(call.Fun).(*ast.SelectorExpr)
	if !isSel || sel.Sel == nil {
		return ""
	}
	pkgIdent, isIdent := sel.X.(*ast.Ident)
	if !isIdent {
		return ""
	}
	if pkgIdent.Name == "strconv" && sel.Sel.Name == "ParseFloat" {
		if len(call.Args) == 2 && extractIntLiteralValue(call.Args[1]) == 32 {
			return "float64"
		}
		return "float64"
	}
	if pkgIdent.Name == "math" {
		switch sel.Sel.Name {
		case "Abs", "Acos", "Acosh", "Asin", "Asinh", "Atan", "Atan2", "Atanh",
			"Cbrt", "Ceil", "Copysign", "Cos", "Cosh", "Dim", "Erf", "Erfc",
			"Exp", "Exp2", "Expm1", "FMA", "Floor", "Hypot", "Log", "Log10",
			"Log1p", "Log2", "Max", "Min", "Mod", "Nextafter", "Pow", "Pow10",
			"Remainder", "Round", "RoundToEven", "Sin", "Sinh", "Sqrt", "Tan",
			"Tanh", "Trunc":
			return "float64"
		case "Float32frombits", "Nextafter32":
			return "float32"
		case "Float64frombits":
			return "float64"
		}
	}
	if (pkgIdent.Name == "rand" || pkgIdent.Name == "v2") && (sel.Sel.Name == "Float64" || sel.Sel.Name == "NormFloat64" || sel.Sel.Name == "ExpFloat64") {
		return "float64"
	}
	if (pkgIdent.Name == "rand" || pkgIdent.Name == "v2") && sel.Sel.Name == "Float32" {
		return "float32"
	}
	return ""
}

func detectUnguardedDivision(
	fset *token.FileSet,
	bin *ast.BinaryExpr,
	enclosingRoot ast.Node,
	funcName string,
	scope numericScopeInfo,
	src string,
) (numericSafetyCandidate, bool) {
	if bin == nil || (bin.Op != token.QUO && bin.Op != token.REM) {
		return numericSafetyCandidate{}, false
	}

	divisorIdent, ok := unwrapNumericParens(bin.Y).(*ast.Ident)
	if !ok || divisorIdent.Name == "" || divisorIdent.Name == "_" || divisorIdent.Name == "iota" {
		return numericSafetyCandidate{}, false
	}

	divName := divisorIdent.Name
	if scope.nonZeroConsts[divName] {
		return numericSafetyCandidate{}, false
	}

	if enclosingRoot != nil && scope.zeroGuards.get(enclosingRoot, buildZeroDivisorGuardIndex).before(divName, bin.Pos()) {
		return numericSafetyCandidate{}, false
	}

	lhsStr := strings.TrimSpace(numericSliceNodeText(fset, src, bin.X))
	if lhsStr == "" {
		return numericSafetyCandidate{}, false
	}

	opStr := bin.Op.String()
	preview := fmt.Sprintf("%s %s max(%s, 1)", lhsStr, opStr, divName)
	divReplacement := fmt.Sprintf("max(%s, 1)", divName)

	pos := fset.Position(bin.Pos())
	divStart := fset.Position(bin.Y.Pos()).Offset
	divEnd := fset.Position(bin.Y.End()).Offset
	exprStr := strings.TrimSpace(numericSliceNodeText(fset, src, bin))

	opNoun := "Division"
	if bin.Op == token.REM {
		opNoun = "Modulo"
	}

	id := fmt.Sprintf("unguarded_division:%d:%d", pos.Line, pos.Column)
	return numericSafetyCandidate{
		issue: NumericSafetyIssue{
			ID:                 id,
			Category:           "unguarded_division",
			Severity:           "error",
			Line:               pos.Line,
			Column:             pos.Column,
			FuncName:           funcName,
			Expr:               exprStr,
			Message:            fmt.Sprintf("%s by variable %q (%s) without a prior zero check can panic or produce Inf/NaN at runtime", opNoun, divName, exprStr),
			Suggestion:         fmt.Sprintf("Check %s != 0 before dividing or guard divisor with %s", divName, divReplacement),
			FixTitle:           fmt.Sprintf("Guard divisor with %s", divReplacement),
			ReplacementPreview: preview,
			CanAutoFix:         divStart >= 0 && divEnd > divStart,
		},
		replaceStart: divStart,
		replaceEnd:   divEnd,
		replaceText:  divReplacement,
		needsMathPkg: false,
	}, true
}

func isZeroOrPositiveGuardBound(expr ast.Expr) bool {
	unwrapped := unwrapNumericParens(expr)
	lit, ok := unwrapped.(*ast.BasicLit)
	if !ok {
		return false
	}
	if lit.Kind == token.INT || lit.Kind == token.FLOAT {
		return true
	}
	return false
}

func isMaxGuardCallForIdent(expr ast.Expr, varName string) bool {
	call, ok := unwrapNumericParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) < 2 {
		return false
	}
	ident, ok := unwrapNumericParens(call.Fun).(*ast.Ident)
	if !ok || ident.Name != "max" {
		return false
	}
	return exprReferencesIdent(call, varName)
}

func isWideIntExpr(expr ast.Expr, scope numericScopeInfo) bool {
	if expr == nil {
		return false
	}
	unwrapped := unwrapNumericParens(expr)
	switch node := unwrapped.(type) {
	case *ast.Ident:
		_, ok := scope.wideIntIdents[node.Name]
		return ok
	case *ast.CallExpr:
		_, isWide, bits := matchWideIntCallExpr(node)
		return isWide && bits == 0
	case *ast.BinaryExpr:
		switch node.Op {
		case token.ADD, token.SUB, token.MUL, token.QUO, token.REM, token.SHL, token.SHR, token.AND, token.OR, token.XOR:
			return isWideIntExpr(node.X, scope) || isWideIntExpr(node.Y, scope)
		default:
		}
	}
	return false
}

func isNonZeroNumericLiteralExpr(expr ast.Expr) bool {
	unwrapped := unwrapNumericParens(expr)
	if unary, isUnary := unwrapped.(*ast.UnaryExpr); isUnary && (unary.Op == token.SUB || unary.Op == token.ADD) {
		unwrapped = unwrapNumericParens(unary.X)
	}
	lit, ok := unwrapped.(*ast.BasicLit)
	if !ok {
		return false
	}
	switch lit.Kind {
	case token.INT:
		val, err := strconv.ParseInt(lit.Value, 0, 64)
		if err == nil {
			return val != 0
		}
		uval, uerr := strconv.ParseUint(lit.Value, 0, 64)
		return uerr == nil && uval != 0
	case token.FLOAT:
		fval, err := strconv.ParseFloat(lit.Value, 64)
		return err == nil && fval != 0
	default:
	}
	return false
}

func extractIntLiteralValue(expr ast.Expr) int {
	lit, ok := unwrapNumericParens(expr).(*ast.BasicLit)
	if !ok || lit.Kind != token.INT {
		return -1
	}
	val, err := strconv.Atoi(lit.Value)
	if err != nil {
		return -1
	}
	return val
}

func numericIsIdentNamed(expr ast.Expr, name string) bool {
	ident, ok := unwrapNumericParens(expr).(*ast.Ident)
	return ok && ident.Name == name
}

func exprReferencesIdent(expr ast.Expr, name string) bool {
	if expr == nil || name == "" {
		return false
	}
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if ident, ok := n.(*ast.Ident); ok && ident.Name == name {
			found = true
			return false
		}
		return true
	})
	return found
}

func unwrapNumericParens(expr ast.Expr) ast.Expr {
	curr := expr
	for {
		paren, ok := curr.(*ast.ParenExpr)
		if !ok {
			return curr
		}
		curr = paren.X
	}
}

func numericSliceNodeText(fset *token.FileSet, src string, node ast.Node) string {
	if node == nil {
		return ""
	}
	start := fset.Position(node.Pos()).Offset
	end := fset.Position(node.End()).Offset
	if start >= 0 && end > start && end <= len(src) {
		return src[start:end]
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, node); err == nil {
		return buf.String()
	}
	return ""
}

func numericSafetyFixer(parsePath string) lastCandidateFixer[numericSafetyCandidate] {
	return lastCandidateFixer[numericSafetyCandidate]{
		maxFixes: 64,
		scan: func(s string) ([]numericSafetyCandidate, bool, error) {
			fset := token.NewFileSet()
			astFile, parseErr := parser.ParseFile(fset, parsePath, s, parser.ParseComments)
			if astFile == nil || parseErr != nil {
				return nil, false, parseErr
			}
			return collectNumericSafetyCandidates(fset, astFile, s), true, nil
		},
		fixable: func(c numericSafetyCandidate) bool {
			return c.issue.CanAutoFix
		},
		span: func(_ string, c numericSafetyCandidate) (int, int, bool) {
			return c.replaceStart, c.replaceEnd, true
		},
		apply: applySingleNumericSafetyCandidate,
	}
}
