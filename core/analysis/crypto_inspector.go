package analysis

import (
	"encoding/json"
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
)

const (
	pkgCryptoRand = "crypto/rand"
)

type CryptoSafetyInspectRequest struct {
	Path      string `json:"path"`
	Content   string `json:"content"`
	Workspace string `json:"workspace"`
}

type CryptoSafetyIssue struct {
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

	startOffset int
	endOffset   int
}

type CryptoSafetyInspectResult struct {
	Issues             []CryptoSafetyIssue `json:"issues"`
	WeakHashCount      int                 `json:"weakHashCount"`
	MathRandCount      int                 `json:"mathRandCount"`
	TimingCompareCount int                 `json:"timingCompareCount"`
	Error              string              `json:"error,omitempty"`
}

type CryptoSafetyFixRequest struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	IssueID string `json:"issueId"`
	All     bool   `json:"all"`
}

type CryptoSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

func InspectCryptoSafety(reqJSON string) string {
	var req CryptoSafetyInspectRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalCryptoInspectResult(CryptoSafetyInspectResult{
			Issues: []CryptoSafetyIssue{},
			Error:  err.Error(),
		})
	}

	res := inspectCryptoSafetyInternal(req)
	return marshalCryptoInspectResult(res)
}

func FixCryptoSafetyIssue(reqJSON string) string {
	var req CryptoSafetyFixRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalCryptoFixResult(CryptoSafetyFixResult{
			Error: err.Error(),
		})
	}

	res := fixCryptoSafetyInternal(req)
	return marshalCryptoFixResult(res)
}

func marshalCryptoInspectResult(res CryptoSafetyInspectResult) string {
	if res.Issues == nil {
		res.Issues = []CryptoSafetyIssue{}
	}
	data, err := json.Marshal(res)
	if err != nil {
		return `{"issues":[],"weakHashCount":0,"mathRandCount":0,"timingCompareCount":0,"error":"failed to marshal result"}`
	}
	return string(data)
}

func marshalCryptoFixResult(res CryptoSafetyFixResult) string {
	data, err := json.Marshal(res)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"failed to marshal fix result"}`
	}
	return string(data)
}

func inspectCryptoSafetyInternal(req CryptoSafetyInspectRequest) CryptoSafetyInspectResult {
	result := CryptoSafetyInspectResult{
		Issues: []CryptoSafetyIssue{},
	}

	src := req.Content
	filePath := strings.TrimSpace(req.Path)
	workspace := strings.TrimSpace(req.Workspace)

	if src == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil && workspace != "" && !filepath.IsAbs(filePath) {
			data, err = os.ReadFile(filepath.Join(workspace, filePath))
		}
		if err != nil {
			result.Error = err.Error()
			return result
		}
		src = string(data)
	}

	if strings.TrimSpace(src) == "" {
		return result
	}

	parsePath := filePath
	if parsePath == "" {
		parsePath = "input.go"
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, parsePath, src, parser.ParseComments)
	if astFile == nil {
		if err != nil {
			result.Error = err.Error()
		}
		return result
	}

	issues := collectCryptoSafetyIssuesInAST(fset, astFile, src)
	for _, issue := range issues {
		switch issue.Category {
		case "weak_hash":
			result.WeakHashCount++
		case "math_rand_security":
			result.MathRandCount++
		case "non_constant_time_compare":
			result.TimingCompareCount++
		}
	}

	if issues != nil {
		result.Issues = issues
	}
	return result
}

func fixCryptoSafetyInternal(req CryptoSafetyFixRequest) CryptoSafetyFixResult {
	src := req.Content
	filePath := strings.TrimSpace(req.Path)
	if src == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return CryptoSafetyFixResult{
				Error: err.Error(),
			}
		}
		src = string(data)
	}

	if strings.TrimSpace(src) == "" {
		return CryptoSafetyFixResult{
			NewContent: src,
		}
	}

	parsePath := filePath
	if parsePath == "" {
		parsePath = "input.go"
	}

	targetID := strings.TrimSpace(req.IssueID)
	fixAll := req.All

	totalFixed := 0
	currentSrc := src

	maxPasses := 1
	if fixAll {
		maxPasses = 5
	}

	for pass := 0; pass < maxPasses; pass++ {
		fset := token.NewFileSet()
		astFile, err := parser.ParseFile(fset, parsePath, currentSrc, parser.ParseComments)
		if astFile == nil {
			if pass == 0 && err != nil {
				return CryptoSafetyFixResult{
					NewContent: src,
					Error:      err.Error(),
				}
			}
			break
		}

		issues := collectCryptoSafetyIssuesInAST(fset, astFile, currentSrc)
		var selected []CryptoSafetyIssue
		for _, issue := range issues {
			if !issue.CanAutoFix || issue.ReplacementPreview == "" {
				continue
			}
			if !fixAll && targetID != "" && issue.ID != targetID {
				continue
			}
			selected = append(selected, issue)
			if !fixAll && targetID != "" {
				break
			}
		}

		if len(selected) == 0 {
			if pass == 0 && !fixAll && targetID != "" {
				return CryptoSafetyFixResult{
					NewContent: src,
					FixedCount: 0,
					Error:      fmt.Sprintf("issue %q not found", targetID),
				}
			}
			break
		}

		sort.SliceStable(selected, func(i, j int) bool {
			if selected[i].startOffset != selected[j].startOffset {
				return selected[i].startOffset > selected[j].startOffset
			}
			return selected[i].endOffset > selected[j].endOffset
		})

		updatedSrc := currentSrc
		lastModifiedStart := len(updatedSrc) + 1
		passFixed := 0

		for _, issue := range selected {
			if issue.startOffset < 0 || issue.endOffset <= issue.startOffset || issue.endOffset > len(updatedSrc) {
				continue
			}
			if issue.endOffset > lastModifiedStart {
				continue
			}
			updatedSrc = updatedSrc[:issue.startOffset] + issue.ReplacementPreview + updatedSrc[issue.endOffset:]
			lastModifiedStart = issue.startOffset
			passFixed++
		}

		if passFixed == 0 {
			break
		}

		totalFixed += passFixed
		currentSrc = reconcileCryptoImportsAndFormat(parsePath, updatedSrc)

		if !fixAll {
			break
		}
	}

	return CryptoSafetyFixResult{
		NewContent: currentSrc,
		FixedCount: totalFixed,
	}
}

func collectCryptoSafetyIssuesInAST(
	fset *token.FileSet,
	astFile *ast.File,
	src string,
) []CryptoSafetyIssue {
	var issues []CryptoSafetyIssue

	hasMathRandImport := false
	hasCryptoRandDefaultImport := false
	hasGoTokenImport := false
	hasHMACImport := false
	tokenAlias := "token"
	hmacAlias := "hmac"
	stringsAlias := "strings"

	for _, imp := range astFile.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		pathVal := strings.Trim(imp.Path.Value, `"`+"`")
		alias := ""
		if imp.Name != nil {
			alias = imp.Name.Name
		}
		switch pathVal {
		case "math/rand", "math/rand/v2":
			if alias == "" || alias == "rand" {
				hasMathRandImport = true
			}
		case pkgCryptoRand:
			if alias == "" || alias == "rand" {
				hasCryptoRandDefaultImport = true
			}
		case "go/token":
			hasGoTokenImport = true
			if alias != "" && alias != "." && alias != "_" {
				tokenAlias = alias
			}
		case "crypto/hmac":
			hasHMACImport = true
			if alias != "" && alias != "." && alias != "_" {
				hmacAlias = alias
			}
		case "strings":
			if alias != "" && alias != "." && alias != "_" {
				stringsAlias = alias
			}
		}
	}

	inspectScope := func(funcName string, root ast.Node) {
		scopeCtx := collectCryptoScopeContext(fset, src, root, hmacAlias, hasHMACImport, hasGoTokenImport, tokenAlias, stringsAlias)
		ast.Inspect(root, func(n ast.Node) bool {
			if n == nil {
				return false
			}
			if n != root {
				if _, isFuncDecl := n.(*ast.FuncDecl); isFuncDecl {
					return false
				}
			}

			switch node := n.(type) {
			case *ast.CallExpr:
				if issue, ok := matchWeakHashCall(fset, src, node, funcName); ok {
					issues = append(issues, issue)
					return true
				}
				if issue, ok := matchMathRandCall(fset, src, node, funcName, hasMathRandImport, hasCryptoRandDefaultImport); ok {
					issues = append(issues, issue)
					return true
				}
				if issue, ok := matchNonConstantTimeCallWithProvenance(fset, src, node, funcName, scopeCtx); ok {
					issues = append(issues, issue)
					return true
				}

			case *ast.BinaryExpr:
				if issue, ok := matchNonConstantTimeBinaryExprWithProvenance(fset, src, node, funcName, scopeCtx); ok {
					issues = append(issues, issue)
					return true
				}
			}

			return true
		})
	}

	for _, decl := range astFile.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Body == nil {
				continue
			}
			fnName := ""
			if d.Name != nil {
				fnName = d.Name.Name
			}
			inspectScope(fnName, d.Body)
		case *ast.GenDecl:
			if d.Tok == token.IMPORT {
				continue
			}
			inspectScope("", d)
		}
	}

	sort.SliceStable(issues, func(i, j int) bool {
		if issues[i].Line != issues[j].Line {
			return issues[i].Line < issues[j].Line
		}
		if issues[i].Column != issues[j].Column {
			return issues[i].Column < issues[j].Column
		}
		return issues[i].Category < issues[j].Category
	})

	return issues
}

func matchWeakHashCall(
	fset *token.FileSet,
	src string,
	call *ast.CallExpr,
	funcName string,
) (CryptoSafetyIssue, bool) {
	if call == nil {
		return CryptoSafetyIssue{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return CryptoSafetyIssue{}, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return CryptoSafetyIssue{}, false
	}

	pkgName := pkgIdent.Name
	methodName := sel.Sel.Name

	var replacement string
	switch pkgName {
	case "md5", "sha1":
		switch methodName {
		case "New":
			if len(call.Args) != 0 {
				return CryptoSafetyIssue{}, false
			}
			replacement = "sha256.New()"
		case "Sum":
			if len(call.Args) != 1 {
				return CryptoSafetyIssue{}, false
			}
			argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
			if argStr == "" {
				return CryptoSafetyIssue{}, false
			}
			replacement = fmt.Sprintf("sha256.Sum256(%s)", argStr)
		default:
			return CryptoSafetyIssue{}, false
		}
	case "des":
		if (methodName == "NewCipher" || methodName == "NewTripleDESCipher") && len(call.Args) == 1 {
			argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
			if argStr == "" {
				return CryptoSafetyIssue{}, false
			}
			replacement = fmt.Sprintf("aes.NewCipher(%s)", argStr)
		} else {
			return CryptoSafetyIssue{}, false
		}
	case "rc4":
		if methodName == "NewCipher" && len(call.Args) == 1 {
			argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
			if argStr == "" {
				return CryptoSafetyIssue{}, false
			}
			replacement = fmt.Sprintf("aes.NewCipher(%s)", argStr)
		} else {
			return CryptoSafetyIssue{}, false
		}
	default:
		return CryptoSafetyIssue{}, false
	}

	pos := fset.Position(call.Pos())
	endPos := fset.Position(call.End())
	exprStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call))

	return CryptoSafetyIssue{
		ID:                 fmt.Sprintf("weak_hash:%d:%d:%s", pos.Line, pos.Column, pkgName+"."+methodName),
		Category:           "weak_hash",
		Severity:           "warning",
		Line:               pos.Line,
		Column:             pos.Column,
		FuncName:           funcName,
		Expr:               exprStr,
		Message:            fmt.Sprintf("Weak cryptographic primitive (%s) is broken against collision/brute-force attacks", exprStr),
		Suggestion:         "Replace MD5/SHA1 with sha256.New() or sha256.Sum256(...)",
		FixTitle:           "Upgrade to sha256",
		ReplacementPreview: replacement,
		CanAutoFix:         true,
		startOffset:        pos.Offset,
		endOffset:          endPos.Offset,
	}, true
}

func matchMathRandCall(
	fset *token.FileSet,
	src string,
	call *ast.CallExpr,
	funcName string,
	hasMathRandImport bool,
	hasCryptoRandDefaultImport bool,
) (CryptoSafetyIssue, bool) {
	if call == nil {
		return CryptoSafetyIssue{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return CryptoSafetyIssue{}, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "rand" {
		return CryptoSafetyIssue{}, false
	}

	methodName := sel.Sel.Name
	var replacement string

	switch methodName {
	case "Read":
		if len(call.Args) != 1 {
			return CryptoSafetyIssue{}, false
		}
		if hasCryptoRandDefaultImport && !hasMathRandImport {
			return CryptoSafetyIssue{}, false
		}
		argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
		if argStr == "" {
			return CryptoSafetyIssue{}, false
		}
		replacement = fmt.Sprintf("cryptorand.Read(%s)", argStr)

	case "Intn", "IntN":
		if len(call.Args) != 1 {
			return CryptoSafetyIssue{}, false
		}
		argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
		if argStr == "" {
			return CryptoSafetyIssue{}, false
		}
		replacement = fmt.Sprintf("func() int { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int(b[0]) %% (%s) }()", argStr)

	case "Int":
		if len(call.Args) != 0 {
			return CryptoSafetyIssue{}, false
		}
		replacement = "func() int { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int(b[0]) }()"

	case "Int63":
		if len(call.Args) != 0 {
			return CryptoSafetyIssue{}, false
		}
		replacement = "func() int64 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int64(b[0]) }()"

	case "Int63n", "Int64N":
		if len(call.Args) != 1 {
			return CryptoSafetyIssue{}, false
		}
		argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
		if argStr == "" {
			return CryptoSafetyIssue{}, false
		}
		replacement = fmt.Sprintf("func() int64 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int64(b[0]) %% (%s) }()", argStr)

	case "Int31":
		if len(call.Args) != 0 {
			return CryptoSafetyIssue{}, false
		}
		replacement = "func() int32 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int32(b[0]) }()"

	case "Int31n", "Int32N":
		if len(call.Args) != 1 {
			return CryptoSafetyIssue{}, false
		}
		argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
		if argStr == "" {
			return CryptoSafetyIssue{}, false
		}
		replacement = fmt.Sprintf("func() int32 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return int32(b[0]) %% (%s) }()", argStr)

	case "Uint64":
		if len(call.Args) != 0 {
			return CryptoSafetyIssue{}, false
		}
		replacement = "func() uint64 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return uint64(b[0]) }()"

	case "Uint32":
		if len(call.Args) != 0 {
			return CryptoSafetyIssue{}, false
		}
		replacement = "func() uint32 { var b [8]byte; _, _ = cryptorand.Read(b[:]); return uint32(b[0]) }()"

	case "Seed":
		if len(call.Args) != 1 {
			return CryptoSafetyIssue{}, false
		}
		argStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call.Args[0]))
		if argStr == "" {
			return CryptoSafetyIssue{}, false
		}
		replacement = fmt.Sprintf("func() { _ = %s; var b [8]byte; _, _ = cryptorand.Read(b[:]) }()", argStr)

	default:
		return CryptoSafetyIssue{}, false
	}

	pos := fset.Position(call.Pos())
	endPos := fset.Position(call.End())
	exprStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call))

	return CryptoSafetyIssue{
		ID:                 fmt.Sprintf("math_rand_security:%d:%d:rand.%s", pos.Line, pos.Column, methodName),
		Category:           "math_rand_security",
		Severity:           "error",
		Line:               pos.Line,
		Column:             pos.Column,
		FuncName:           funcName,
		Expr:               exprStr,
		Message:            "Non-cryptographic PRNG (math/rand) is predictable and unsafe for tokens, IDs, or secrets",
		Suggestion:         "Use crypto/rand for cryptographically secure random bytes or integers",
		FixTitle:           "Replace with crypto/rand safe helper",
		ReplacementPreview: replacement,
		CanAutoFix:         true,
		startOffset:        pos.Offset,
		endOffset:          endPos.Offset,
	}, true
}

type cryptoScopeContext struct {
	hmacInstances    map[string]bool
	digestVars       map[string]bool
	trimPrefixSource map[string]string
	composedKeys     map[string]bool
	hmacAlias        string
	hasHMACImport    bool
	hasGoTokenImport bool
	tokenAlias       string
}

func matchNonConstantTimeCallWithProvenance(
	fset *token.FileSet,
	src string,
	call *ast.CallExpr,
	funcName string,
	scopeCtx cryptoScopeContext,
) (CryptoSafetyIssue, bool) {
	if call == nil || len(call.Args) != 2 {
		return CryptoSafetyIssue{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return CryptoSafetyIssue{}, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return CryptoSafetyIssue{}, false
	}

	pkgName := pkgIdent.Name
	methodName := sel.Sel.Name

	if !((pkgName == "bytes" && methodName == "Equal") || (pkgName == "strings" && methodName == "EqualFold")) {
		return CryptoSafetyIssue{}, false
	}

	arg0 := call.Args[0]
	arg1 := call.Args[1]
	if isExcludedComparisonOperand(arg0, scopeCtx.hasGoTokenImport, scopeCtx.tokenAlias) || isExcludedComparisonOperand(arg1, scopeCtx.hasGoTokenImport, scopeCtx.tokenAlias) || scopeCtx.isComposedKey(arg0) || scopeCtx.isComposedKey(arg1) {
		return CryptoSafetyIssue{}, false
	}

	hasDigest := exprIsMACDigest(arg0, scopeCtx) || exprIsMACDigest(arg1, scopeCtx)
	hasSensitive := exprHasSecuritySensitiveIdentifier(arg0) || exprHasSecuritySensitiveIdentifier(arg1)
	if !hasDigest && !hasSensitive {
		return CryptoSafetyIssue{}, false
	}

	lhsStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, arg0))
	rhsStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, arg1))
	if lhsStr == "" || rhsStr == "" {
		return CryptoSafetyIssue{}, false
	}

	var replacement string
	if pkgName == "bytes" {
		replacement = fmt.Sprintf("subtle.ConstantTimeCompare(%s, %s) == 1", lhsStr, rhsStr)
	} else {
		replacement = fmt.Sprintf("subtle.ConstantTimeCompare([]byte(%s), []byte(%s)) == 1", lhsStr, rhsStr)
	}

	pos := fset.Position(call.Pos())
	endPos := fset.Position(call.End())
	exprStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, call))

	msg := fmt.Sprintf("Direct comparison on secret/signature (%s) leaks length and byte prefixes via timing side-channel; use hmac.Equal or subtle.ConstantTimeCompare", exprStr)
	suggestion := "Use hmac.Equal for MACs or subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1"
	if pkgName == "bytes" {
		suggestion = "Use hmac.Equal(a, b) for MAC digests or subtle.ConstantTimeCompare(a, b) == 1"
	}

	return CryptoSafetyIssue{
		ID:                 fmt.Sprintf("non_constant_time_compare:%d:%d:%s.%s", pos.Line, pos.Column, pkgName, methodName),
		Category:           "non_constant_time_compare",
		Severity:           "error",
		Line:               pos.Line,
		Column:             pos.Column,
		FuncName:           funcName,
		Expr:               exprStr,
		Message:            msg,
		Suggestion:         suggestion,
		FixTitle:           "Use subtle.ConstantTimeCompare",
		ReplacementPreview: replacement,
		CanAutoFix:         true,
		startOffset:        pos.Offset,
		endOffset:          endPos.Offset,
	}, true
}

func matchNonConstantTimeBinaryExprWithProvenance(
	fset *token.FileSet,
	src string,
	bin *ast.BinaryExpr,
	funcName string,
	scopeCtx cryptoScopeContext,
) (CryptoSafetyIssue, bool) {
	if bin == nil || (bin.Op != token.EQL && bin.Op != token.NEQ) {
		return CryptoSafetyIssue{}, false
	}

	if isExcludedComparisonOperand(bin.X, scopeCtx.hasGoTokenImport, scopeCtx.tokenAlias) || isExcludedComparisonOperand(bin.Y, scopeCtx.hasGoTokenImport, scopeCtx.tokenAlias) || scopeCtx.isComposedKey(bin.X) || scopeCtx.isComposedKey(bin.Y) {
		return CryptoSafetyIssue{}, false
	}

	hasDigest := exprIsMACDigest(bin.X, scopeCtx) || exprIsMACDigest(bin.Y, scopeCtx)
	hasSensitive := exprHasSecuritySensitiveIdentifier(bin.X) || exprHasSecuritySensitiveIdentifier(bin.Y)
	if !hasDigest && !hasSensitive {
		return CryptoSafetyIssue{}, false
	}

	lhsStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, bin.X))
	rhsStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, bin.Y))
	if lhsStr == "" || rhsStr == "" {
		return CryptoSafetyIssue{}, false
	}
	if isTrimPrefixUnchangedCheck(bin.X, bin.Y, lhsStr, rhsStr, scopeCtx) {
		return CryptoSafetyIssue{}, false
	}

	var replacement string
	if bin.Op == token.EQL {
		replacement = fmt.Sprintf("subtle.ConstantTimeCompare([]byte(%s), []byte(%s)) == 1", lhsStr, rhsStr)
	} else {
		replacement = fmt.Sprintf("subtle.ConstantTimeCompare([]byte(%s), []byte(%s)) != 1", lhsStr, rhsStr)
	}

	pos := fset.Position(bin.Pos())
	endPos := fset.Position(bin.End())
	exprStr := strings.TrimSpace(cryptoSliceNodeText(fset, src, bin))

	return CryptoSafetyIssue{
		ID:                 fmt.Sprintf("non_constant_time_compare:%d:%d:%s", pos.Line, pos.Column, bin.Op.String()),
		Category:           "non_constant_time_compare",
		Severity:           "error",
		Line:               pos.Line,
		Column:             pos.Column,
		FuncName:           funcName,
		Expr:               exprStr,
		Message:            fmt.Sprintf("Direct comparison on secret/signature (%s) leaks length and byte prefixes via timing side-channel; use hmac.Equal or subtle.ConstantTimeCompare", exprStr),
		Suggestion:         "Use hmac.Equal for MAC digests or subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1",
		FixTitle:           "Use subtle.ConstantTimeCompare",
		ReplacementPreview: replacement,
		CanAutoFix:         true,
		startOffset:        pos.Offset,
		endOffset:          endPos.Offset,
	}, true
}

func isTrimPrefixUnchangedCheck(x, y ast.Expr, lhsStr, rhsStr string, scopeCtx cryptoScopeContext) bool {
	if id, ok := unwrapCryptoParens(x).(*ast.Ident); ok {
		if srcText, exists := scopeCtx.trimPrefixSource[id.Name]; exists && srcText == rhsStr {
			return true
		}
	}
	if id, ok := unwrapCryptoParens(y).(*ast.Ident); ok {
		if srcText, exists := scopeCtx.trimPrefixSource[id.Name]; exists && srcText == lhsStr {
			return true
		}
	}
	return false
}

func collectCryptoScopeContext(
	fset *token.FileSet,
	src string,
	root ast.Node,
	hmacAlias string,
	hasHMACImport bool,
	hasGoTokenImport bool,
	tokenAlias string,
	stringsAlias string,
) cryptoScopeContext {
	hmacInstances := make(map[string]bool)
	digestVars := make(map[string]bool)
	trimPrefixSource := make(map[string]string)
	composedKeys := make(map[string]bool)
	ctx := cryptoScopeContext{
		hmacInstances:    hmacInstances,
		digestVars:       digestVars,
		trimPrefixSource: trimPrefixSource,
		composedKeys:     composedKeys,
		hmacAlias:        hmacAlias,
		hasHMACImport:    hasHMACImport,
		hasGoTokenImport: hasGoTokenImport,
		tokenAlias:       tokenAlias,
	}
	if root == nil {
		return ctx
	}

	ast.Inspect(root, func(n ast.Node) bool {
		switch stmt := n.(type) {
		case *ast.AssignStmt:
			for i, rhs := range stmt.Rhs {
				if isHMACNewExpr(rhs, hmacAlias) && i < len(stmt.Lhs) {
					if id, ok := stmt.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
						hmacInstances[id.Name] = true
					}
				}
				if isNonSecretConcatenation(rhs) && i < len(stmt.Lhs) {
					if id, ok := stmt.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
						composedKeys[id.Name] = true
					}
				}
				if rawArg, ok := matchTrimPrefixSourceExpr(rhs, stringsAlias); ok && i < len(stmt.Lhs) {
					if id, ok := stmt.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
						if txt := strings.TrimSpace(cryptoSliceNodeText(fset, src, rawArg)); txt != "" {
							trimPrefixSource[id.Name] = txt
						}
					}
				}
			}
		case *ast.ValueSpec:
			for i, rhs := range stmt.Values {
				if isHMACNewExpr(rhs, hmacAlias) && i < len(stmt.Names) {
					if stmt.Names[i] != nil && stmt.Names[i].Name != "_" {
						hmacInstances[stmt.Names[i].Name] = true
					}
				}
				if isNonSecretConcatenation(rhs) && i < len(stmt.Names) && stmt.Names[i] != nil && stmt.Names[i].Name != "_" {
					composedKeys[stmt.Names[i].Name] = true
				}
				if rawArg, ok := matchTrimPrefixSourceExpr(rhs, stringsAlias); ok && i < len(stmt.Names) {
					if stmt.Names[i] != nil && stmt.Names[i].Name != "_" {
						if txt := strings.TrimSpace(cryptoSliceNodeText(fset, src, rawArg)); txt != "" {
							trimPrefixSource[stmt.Names[i].Name] = txt
						}
					}
				}
			}
		}
		return true
	})

	for pass := 0; pass < 2; pass++ {
		ast.Inspect(root, func(n ast.Node) bool {
			switch stmt := n.(type) {
			case *ast.AssignStmt:
				for i, rhs := range stmt.Rhs {
					if isMACDigestProducer(rhs, hmacInstances, digestVars, hmacAlias, hasHMACImport) && i < len(stmt.Lhs) {
						if id, ok := stmt.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
							digestVars[id.Name] = true
						}
					}
				}
			case *ast.ValueSpec:
				for i, rhs := range stmt.Values {
					if isMACDigestProducer(rhs, hmacInstances, digestVars, hmacAlias, hasHMACImport) && i < len(stmt.Names) {
						if stmt.Names[i] != nil && stmt.Names[i].Name != "_" {
							digestVars[stmt.Names[i].Name] = true
						}
					}
				}
			}
			return true
		})
	}

	return ctx
}

func isNonSecretConcatenation(expr ast.Expr) bool {
	bin, ok := unwrapCryptoParens(expr).(*ast.BinaryExpr)
	return ok && bin.Op == token.ADD && !exprHasSecuritySensitiveIdentifier(bin)
}

func (ctx cryptoScopeContext) isComposedKey(expr ast.Expr) bool {
	id, ok := unwrapCryptoParens(expr).(*ast.Ident)
	return ok && ctx.composedKeys[id.Name] && !ctx.digestVars[id.Name]
}

func matchTrimPrefixSourceExpr(expr ast.Expr, stringsAlias string) (ast.Expr, bool) {
	call, ok := unwrapCryptoParens(expr).(*ast.CallExpr)
	if !ok || len(call.Args) != 2 {
		return nil, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || (sel.Sel.Name != "TrimPrefix" && sel.Sel.Name != "TrimSuffix") {
		return nil, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != stringsAlias {
		return nil, false
	}
	return call.Args[0], true
}

func isHMACNewExpr(expr ast.Expr, hmacAlias string) bool {
	call, ok := unwrapCryptoParens(expr).(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "New" {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	return ok && pkgIdent.Name == hmacAlias
}

func isMACDigestProducer(
	expr ast.Expr,
	hmacInstances map[string]bool,
	digestVars map[string]bool,
	hmacAlias string,
	hasHMACImport bool,
) bool {
	expr = unwrapCryptoParens(expr)
	switch e := expr.(type) {
	case *ast.Ident:
		return digestVars[e.Name]
	case *ast.CallExpr:
		if isSumCallOnMAC(e, hmacInstances, hmacAlias, hasHMACImport) {
			return true
		}
		if isEncodingOfDigestCall(e, hmacInstances, digestVars, hmacAlias, hasHMACImport) {
			return true
		}
	}
	return false
}

func isSumCallOnMAC(call *ast.CallExpr, hmacInstances map[string]bool, hmacAlias string, hasHMACImport bool) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != "Sum" {
		return false
	}
	if isHMACNewExpr(sel.X, hmacAlias) {
		return true
	}
	if id, ok := unwrapCryptoParens(sel.X).(*ast.Ident); ok {
		if hmacInstances[id.Name] {
			return true
		}
		if hasHMACImport && isHMACReceiverName(id.Name) {
			return true
		}
	}
	return false
}

func isHMACReceiverName(name string) bool {
	lower := strings.ToLower(name)
	return lower == "mac" || lower == "hmac" || strings.Contains(lower, "hmac") || strings.HasSuffix(lower, "mac")
}

func isEncodingOfDigestCall(
	call *ast.CallExpr,
	hmacInstances map[string]bool,
	digestVars map[string]bool,
	hmacAlias string,
	hasHMACImport bool,
) bool {
	if len(call.Args) == 0 {
		return false
	}
	if ft, ok := call.Fun.(*ast.Ident); ok && ft.Name == "string" {
		return isMACDigestProducer(call.Args[0], hmacInstances, digestVars, hmacAlias, hasHMACImport)
	}
	if _, ok := call.Fun.(*ast.ArrayType); ok {
		return isMACDigestProducer(call.Args[0], hmacInstances, digestVars, hmacAlias, hasHMACImport)
	}
	if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
		if sel.Sel.Name == "EncodeToString" {
			return isMACDigestProducer(call.Args[0], hmacInstances, digestVars, hmacAlias, hasHMACImport)
		}
	}
	return false
}

func exprIsMACDigest(expr ast.Expr, scopeCtx cryptoScopeContext) bool {
	if expr == nil {
		return false
	}
	e := unwrapCryptoParens(expr)
	switch node := e.(type) {
	case *ast.Ident:
		return scopeCtx.digestVars[node.Name]
	case *ast.CallExpr:
		if isSumCallOnMAC(node, scopeCtx.hmacInstances, scopeCtx.hmacAlias, scopeCtx.hasHMACImport) {
			return true
		}
		if isHMACNewExpr(node, scopeCtx.hmacAlias) {
			return true
		}
		if isEncodingOfDigestCall(node, scopeCtx.hmacInstances, scopeCtx.digestVars, scopeCtx.hmacAlias, scopeCtx.hasHMACImport) {
			return true
		}
		for _, arg := range node.Args {
			if exprIsMACDigest(arg, scopeCtx) {
				return true
			}
		}
	}
	return false
}

func unwrapCryptoParens(expr ast.Expr) ast.Expr {
	for expr != nil {
		if p, ok := expr.(*ast.ParenExpr); ok {
			expr = p.X
			continue
		}
		return expr
	}
	return nil
}

func isExcludedComparisonOperand(expr ast.Expr, hasGoTokenImport bool, tokenAlias string) bool {
	if expr == nil {
		return true
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return isExcludedComparisonOperand(e.X, hasGoTokenImport, tokenAlias)
	case *ast.Ident:
		if e.Name == "nil" || e.Name == "true" || e.Name == "false" || e.Name == "iota" {
			return true
		}
		if strings.HasPrefix(e.Name, "Default") {
			return true
		}
		return isNonCryptoIdentifier(e.Name)
	case *ast.BasicLit:
		return true
	case *ast.SelectorExpr:
		if e.Sel != nil {
			if strings.HasPrefix(e.Sel.Name, "Default") || isASTMetadataField(e.Sel.Name) || isNonCryptoIdentifier(e.Sel.Name) {
				return true
			}
			if pkgIdent, ok := e.X.(*ast.Ident); ok {
				if (hasGoTokenImport && pkgIdent.Name == tokenAlias) || (pkgIdent.Name == "token" && isAllCapsIdent(e.Sel.Name)) {
					return true
				}
			}
		}
		return isExcludedComparisonOperand(e.X, hasGoTokenImport, tokenAlias)
	case *ast.UnaryExpr:
		return isExcludedComparisonOperand(e.X, hasGoTokenImport, tokenAlias)
	case *ast.CallExpr:
		if ident, ok := e.Fun.(*ast.Ident); ok {
			if ident.Name == "len" || ident.Name == "cap" {
				return true
			}
			if ident.Name == "string" && len(e.Args) == 1 {
				if _, isLit := unwrapCryptoParens(e.Args[0]).(*ast.BasicLit); isLit {
					return true
				}
			}
			if isNonCryptoIdentifier(ident.Name) {
				return true
			}
		}
		if arr, ok := e.Fun.(*ast.ArrayType); ok && arr.Len == nil && len(e.Args) == 1 {
			if elt, ok := arr.Elt.(*ast.Ident); ok && elt.Name == "byte" {
				if _, isLit := unwrapCryptoParens(e.Args[0]).(*ast.BasicLit); isLit {
					return true
				}
			}
		}
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if isNonCryptoIdentifier(sel.Sel.Name) {
				return true
			}
			if pkgIdent, ok := sel.X.(*ast.Ident); ok {
				if pkgIdent.Name == "subtle" && sel.Sel.Name == "ConstantTimeCompare" {
					return true
				}
				if pkgIdent.Name == "hmac" && sel.Sel.Name == "Equal" {
					return true
				}
			}
		}
	}
	return false
}

func isAllCapsIdent(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r >= 'a' && r <= 'z' {
			return false
		}
	}
	return true
}

func isASTMetadataField(name string) bool {
	switch strings.ToLower(name) {
	case "tok", "kind", "op", "pos", "end", "start", "type", "mode", "tag", "name":
		return true
	default:
		return false
	}
}

func isNonCryptoIdentifier(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if lower == "" {
		return false
	}
	switch lower {
	case "hash", "currenthash", "originalhash", "originalsha256", "currentfilehash", "beforehash", "afterhash", "sourcehash", "filehash", "contenthash", "importcontenthash", "repairhash", "planhash", "cachehash", "assethash", "bodyhash", "etag", "crc", "checksum", "tok", "sigchan", "sigch", "sigs", "macaddr", "macaddress":
		return true
	}
	for _, suffix := range []string{"contenthash", "sourcehash", "filehash", "originalhash", "beforehash", "afterhash", "repairhash", "planhash", "cachehash", "sha256", "alias"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

var cryptoSubstringKeywords = []string{
	"token",
	"secret",
	"hmac",
	"signature",
	"hash",
	"digest",
	"apikey",
	"password",
	"passwd",
}

var cryptoSegmentKeywords = map[string]bool{
	"sig":  true,
	"sigs": true,
	"mac":  true,
	"macs": true,
	"otp":  true,
	"otps": true,
	"pin":  true,
	"pins": true,
}

func isCryptoSensitiveIdentifierName(name string) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || trimmed == "_" {
		return false
	}
	lower := strings.ToLower(trimmed)
	compact := strings.ReplaceAll(lower, "_", "")
	for _, kw := range cryptoSubstringKeywords {
		if strings.Contains(lower, kw) || strings.Contains(compact, kw) {
			return true
		}
	}

	words := splitCryptoIdentifierWords(trimmed)
	for _, w := range words {
		cleanWord := strings.TrimRightFunc(strings.ToLower(w), unicode.IsDigit)
		if cryptoSegmentKeywords[cleanWord] {
			return true
		}
	}

	return false
}

func splitCryptoIdentifierWords(ident string) []string {
	var words []string
	var current []rune
	runes := []rune(ident)

	flush := func() {
		if len(current) > 0 {
			words = append(words, string(current))
			current = nil
		}
	}

	for i, r := range runes {
		if r == '_' {
			flush()
			continue
		}
		if i > 0 && unicode.IsUpper(r) {
			prev := runes[i-1]
			nextIsLower := i+1 < len(runes) && unicode.IsLower(runes[i+1])
			if unicode.IsLower(prev) || unicode.IsDigit(prev) || (unicode.IsUpper(prev) && nextIsLower) {
				flush()
			}
		}
		current = append(current, r)
	}
	flush()
	return words
}

func exprHasSecuritySensitiveIdentifier(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		switch node := n.(type) {
		case *ast.CallExpr:
			if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
				if pkgIdent, ok := sel.X.(*ast.Ident); ok {
					if (pkgIdent.Name == "subtle" && sel.Sel.Name == "ConstantTimeCompare") ||
						(pkgIdent.Name == "hmac" && sel.Sel.Name == "Equal") {
						return false
					}
				}
			}
		case *ast.Ident:
			if isCryptoSensitiveIdentifierName(node.Name) {
				found = true
				return false
			}
		case *ast.SelectorExpr:
			if node.Sel != nil && isCryptoSensitiveIdentifierName(node.Sel.Name) {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

func cryptoSliceNodeText(fset *token.FileSet, src string, node ast.Node) string {
	if node == nil {
		return ""
	}
	start := fset.Position(node.Pos()).Offset
	end := fset.Position(node.End()).Offset
	if start >= 0 && end > start && end <= len(src) {
		return src[start:end]
	}
	if expr, ok := node.(ast.Expr); ok {
		return exprToString(fset, expr)
	}
	return ""
}

type cryptoImportEntry struct {
	alias string
	path  string
}

func reconcileCryptoImportsAndFormat(filePath string, src string) string {
	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if astFile == nil || err != nil {
		if formatted, fmtErr := format.Source([]byte(src)); fmtErr == nil {
			return string(formatted)
		}
		return src
	}

	usedPkgIdents := make(map[string]bool)
	for _, decl := range astFile.Decls {
		if gen, ok := decl.(*ast.GenDecl); ok && gen.Tok == token.IMPORT {
			continue
		}
		ast.Inspect(decl, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if ident, ok := sel.X.(*ast.Ident); ok && ident.Name != "" {
				usedPkgIdents[ident.Name] = true
			}
			return true
		})
	}

	var existingImports []cryptoImportEntry
	var importDecls []*ast.GenDecl

	for _, decl := range astFile.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.IMPORT {
			continue
		}
		importDecls = append(importDecls, gen)
		for _, spec := range gen.Specs {
			imp, ok := spec.(*ast.ImportSpec)
			if !ok || imp.Path == nil {
				continue
			}
			pathVal := strings.Trim(imp.Path.Value, `"`+"`")
			alias := ""
			if imp.Name != nil {
				alias = imp.Name.Name
			}
			existingImports = append(existingImports, cryptoImportEntry{
				alias: alias,
				path:  pathVal,
			})
		}
	}

	removableByDefaultName := map[string]string{
		"crypto/md5":   "md5",
		"crypto/sha1":  "sha1",
		"crypto/des":   "des",
		"crypto/rc4":   "rc4",
		"math/rand":    "rand",
		"math/rand/v2": "rand",
		"bytes":        "bytes",
		"strings":      "strings",
	}

	var keptImports []cryptoImportEntry
	seenImportKey := make(map[string]bool)

	addImportEntry := func(alias, path string) {
		key := alias + ":" + path
		if seenImportKey[key] {
			return
		}
		seenImportKey[key] = true
		keptImports = append(keptImports, cryptoImportEntry{
			alias: alias,
			path:  path,
		})
	}

	for _, imp := range existingImports {
		if defaultLocal, isRemovable := removableByDefaultName[imp.path]; isRemovable {
			localName := imp.alias
			if localName == "" {
				localName = defaultLocal
			}
			if !usedPkgIdents[localName] {
				continue
			}
		}
		addImportEntry(imp.alias, imp.path)
	}

	hasLocalPkg := func(localName, pkgPath string) bool {
		for _, imp := range keptImports {
			if imp.path == pkgPath && (imp.alias == "" || imp.alias == localName) {
				return true
			}
			if imp.alias == localName {
				return true
			}
		}
		return false
	}

	if usedPkgIdents["sha256"] && !hasLocalPkg("sha256", "crypto/sha256") {
		addImportEntry("", "crypto/sha256")
	}
	if usedPkgIdents["aes"] && !hasLocalPkg("aes", "crypto/aes") {
		addImportEntry("", "crypto/aes")
	}
	if usedPkgIdents["cryptorand"] && !hasLocalPkg("cryptorand", pkgCryptoRand) {
		addImportEntry("cryptorand", pkgCryptoRand)
	}
	if usedPkgIdents["subtle"] && !hasLocalPkg("subtle", "crypto/subtle") {
		addImportEntry("", "crypto/subtle")
	}

	sort.SliceStable(keptImports, func(i, j int) bool {
		return keptImports[i].path < keptImports[j].path
	})

	var importBlock string
	if len(keptImports) == 1 && keptImports[0].alias == "" {
		importBlock = fmt.Sprintf("import %q", keptImports[0].path)
	} else if len(keptImports) > 0 {
		var lines []string
		lines = append(lines, "import (")
		for _, imp := range keptImports {
			if imp.alias != "" {
				lines = append(lines, fmt.Sprintf("\t%s %q", imp.alias, imp.path))
			} else {
				lines = append(lines, fmt.Sprintf("\t%q", imp.path))
			}
		}
		lines = append(lines, ")")
		importBlock = strings.Join(lines, "\n")
	}

	updated := src
	if len(importDecls) > 0 {
		for i := len(importDecls) - 1; i >= 1; i-- {
			d := importDecls[i]
			start := fset.Position(d.Pos()).Offset
			end := fset.Position(d.End()).Offset
			if start >= 0 && end >= start && end <= len(updated) {
				updated = updated[:start] + updated[end:]
			}
		}
		first := importDecls[0]
		start := fset.Position(first.Pos()).Offset
		end := fset.Position(first.End()).Offset
		if start >= 0 && end >= start && end <= len(updated) {
			updated = updated[:start] + importBlock + updated[end:]
		}
	} else if importBlock != "" && astFile.Name != nil {
		pkgEnd := fset.Position(astFile.Name.End()).Offset
		if pkgEnd >= 0 && pkgEnd <= len(updated) {
			updated = updated[:pkgEnd] + "\n\n" + importBlock + updated[pkgEnd:]
		}
	}

	if formatted, fmtErr := format.Source([]byte(updated)); fmtErr == nil {
		return string(formatted)
	}
	return updated
}
