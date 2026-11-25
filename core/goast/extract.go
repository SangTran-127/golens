package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strings"
)

const errPrefixInvalidRequest = "invalid request: "

type ExtractMethodReq struct {
	Path      string `json:"path"`
	Src       string `json:"src"`
	StartByte int    `json:"startByte"`
	EndByte   int    `json:"endByte"`
	FuncName  string `json:"funcName,omitempty"`
}

type ExtractParam struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type ExtractMethodReply struct {
	DefaultName      string                `json:"defaultName,omitempty"`
	Receiver         string                `json:"receiver,omitempty"`
	Params           []ExtractParam        `json:"params,omitempty"`
	Results          []ExtractParam        `json:"results,omitempty"`
	PreviewSignature string                `json:"previewSignature,omitempty"`
	PreviewCall      string                `json:"previewCall,omitempty"`
	StartByte        int                   `json:"startByte"`
	EndByte          int                   `json:"endByte"`
	EditsByPath      map[string][]TextEdit `json:"editsByPath,omitempty"`
	Error            string                `json:"error,omitempty"`
}

type ExtractVarReq struct {
	Path      string `json:"path"`
	Src       string `json:"src"`
	StartByte int    `json:"startByte"`
	EndByte   int    `json:"endByte"`
	VarName   string `json:"varName,omitempty"`
}

type ExtractVarReply struct {
	VarName     string                `json:"varName,omitempty"`
	EditsByPath map[string][]TextEdit `json:"editsByPath,omitempty"`
	Error       string                `json:"error,omitempty"`
}

type InlineVarReq struct {
	Path   string `json:"path"`
	Src    string `json:"src"`
	Offset int    `json:"offset"`
}

func InspectExtractMethodJSON(reqJSON string) string {
	var req ExtractMethodReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractMethodReply{Error: errPrefixInvalidRequest + err.Error()})
		return string(b)
	}
	b, _ := json.Marshal(InspectExtractMethod(req))
	return string(b)
}

func ApplyExtractMethodJSON(reqJSON string) string {
	var req ExtractMethodReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractMethodReply{Error: errPrefixInvalidRequest + err.Error()})
		return string(b)
	}
	b, _ := json.Marshal(ApplyExtractMethod(req))
	return string(b)
}

func ApplyExtractVariableJSON(reqJSON string) string {
	var req ExtractVarReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractVarReply{Error: errPrefixInvalidRequest + err.Error()})
		return string(b)
	}
	b, _ := json.Marshal(ApplyExtractVariable(req))
	return string(b)
}

func ApplyInlineVariableJSON(reqJSON string) string {
	var req InlineVarReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(ExtractVarReply{Error: errPrefixInvalidRequest + err.Error()})
		return string(b)
	}
	b, _ := json.Marshal(ApplyInlineVariable(req))
	return string(b)
}

func InspectExtractMethod(req ExtractMethodReq) ExtractMethodReply {
	return runExtractMethod(req, false)
}

func ApplyExtractMethod(req ExtractMethodReq) ExtractMethodReply {
	return runExtractMethod(req, true)
}

func loadRefactorFile(path, rawSrc string) ([]byte, *token.FileSet, *ast.File, *token.File, string) {
	var src []byte
	if rawSrc != "" {
		src = []byte(rawSrc)
	} else if strings.TrimSpace(path) != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, nil, nil, nil, "failed to read file: " + err.Error()
		}
		src = data
	} else {
		return nil, nil, nil, nil, "missing source or file path"
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			return nil, nil, nil, nil, "failed to parse file: " + err.Error()
		}
		return nil, nil, nil, nil, "failed to parse file"
	}
	tf := fset.File(file.Pos())
	if tf == nil {
		return nil, nil, nil, nil, "failed to locate token file"
	}
	return src, fset, file, tf, ""
}

func runExtractMethod(req ExtractMethodReq, produceEdits bool) ExtractMethodReply {
	src, fset, file, tf, errMsg := loadRefactorFile(req.Path, req.Src)
	if errMsg != "" {
		return ExtractMethodReply{Error: errMsg}
	}

	startByte := max(0, min(req.StartByte, len(src)))
	endByte := max(0, min(req.EndByte, len(src)))
	if startByte > endByte {
		startByte, endByte = endByte, startByte
	}

	trimStart, trimEnd := startByte, endByte
	for trimStart < trimEnd && (src[trimStart] == ' ' || src[trimStart] == '\t' || src[trimStart] == '\n' || src[trimStart] == '\r') {
		trimStart++
	}
	for trimEnd > trimStart && (src[trimEnd-1] == ' ' || src[trimEnd-1] == '\t' || src[trimEnd-1] == '\n' || src[trimEnd-1] == '\r') {
		trimEnd--
	}

	startPos := tf.Pos(trimStart)
	endPos := tf.Pos(trimEnd)
	cursorLine := fset.Position(tf.Pos(startByte)).Line

	enclosingFn := findEnclosingFuncDecl(fset, file, startPos, endPos, cursorLine)
	if enclosingFn == nil || enclosingFn.Body == nil {
		return ExtractMethodReply{Error: "selection is not inside a function body"}
	}

	selectedStmts := findSelectedStatements(fset, enclosingFn.Body, startPos, endPos, trimStart == trimEnd, cursorLine)
	if len(selectedStmts) == 0 {
		return ExtractMethodReply{Error: "no extractable statements found in selection"}
	}

	firstStmt := selectedStmts[0]
	lastStmt := selectedStmts[len(selectedStmts)-1]
	selStartPos := firstStmt.Pos()
	selEndPos := lastStmt.End()
	selStartByte := posOffset(tf, len(src), selStartPos)
	selEndByte := posOffset(tf, len(src), selEndPos)

	typeEnv := map[string]string{}
	declaredBefore := map[string]bool{}

	var recvIdentName, recvTypeStr, recvFullStr string
	if enclosingFn.Recv != nil && len(enclosingFn.Recv.List) > 0 {
		rf := enclosingFn.Recv.List[0]
		recvTypeStr = exprString(fset, src, rf.Type)
		if len(rf.Names) > 0 && rf.Names[0] != nil && rf.Names[0].Name != "" && rf.Names[0].Name != "_" {
			recvIdentName = rf.Names[0].Name
			recvFullStr = recvIdentName + " " + recvTypeStr
			typeEnv[recvIdentName] = recvTypeStr
		}
	}

	for _, p := range flattenFieldList(fset, src, enclosingFn.Type.Params) {
		if p.Name != "" && p.Name != "_" {
			typeEnv[p.Name] = p.Type
			declaredBefore[p.Name] = true
		}
	}
	for _, r := range flattenFieldList(fset, src, enclosingFn.Type.Results) {
		if r.Name != "" && r.Name != "_" {
			typeEnv[r.Name] = r.Type
			declaredBefore[r.Name] = true
		}
	}

	inferTypesInFunc(funcTypeInferCtx{
		fset: fset, file: file, src: src, body: enclosingFn.Body,
		selStartPos: selStartPos, selEndPos: selEndPos, env: typeEnv, declaredBefore: declaredBefore,
	})

	skip := collectSkippedIdents(enclosingFn.Body)
	topLevelNames := collectTopLevelDeclNames(file)

	recvUsed := false
	overwrittenInSel := map[string]bool{}
	declaredInSel := map[string]bool{}
	writtenInSel := make([]string, 0)
	writtenInSelSet := map[string]bool{}
	var paramNames []string
	paramSet := map[string]bool{}

	recordWrite := func(name string, isDecl bool) {
		if name == "" || name == "_" {
			return
		}
		if isDecl && !declaredBefore[name] {
			declaredInSel[name] = true
		}
		overwrittenInSel[name] = true
		if !writtenInSelSet[name] {
			writtenInSelSet[name] = true
			writtenInSel = append(writtenInSel, name)
		}
	}

	recordRead := func(id *ast.Ident) {
		if id == nil || skip[id] {
			return
		}
		name := id.Name
		if name == "" || name == "_" || isPredeclaredIdent(name) || topLevelNames[name] {
			return
		}
		if recvIdentName != "" && name == recvIdentName {
			recvUsed = true
			return
		}
		if declaredBefore[name] && !overwrittenInSel[name] && !paramSet[name] {
			paramSet[name] = true
			paramNames = append(paramNames, name)
		}
	}

	inspectReads := func(node ast.Node) {
		ast.Inspect(node, func(cn ast.Node) bool {
			if id, ok := cn.(*ast.Ident); ok {
				recordRead(id)
			}
			return true
		})
	}

	var walkSelNode func(n ast.Node)
	walkBlock := func(b *ast.BlockStmt) {
		if b != nil {
			for _, child := range b.List {
				walkSelNode(child)
			}
		}
	}

	walkSelNode = func(n ast.Node) {
		if n == nil {
			return
		}
		switch s := n.(type) {
		case *ast.AssignStmt:
			for _, rhs := range s.Rhs {
				inspectReads(rhs)
			}
			for _, lhs := range s.Lhs {
				if id, ok := lhs.(*ast.Ident); ok {
					if s.Tok != token.DEFINE && s.Tok != token.ASSIGN {
						recordRead(id)
					}
				} else {
					inspectReads(lhs)
				}
			}
			for _, lhs := range s.Lhs {
				if id, ok := lhs.(*ast.Ident); ok {
					recordWrite(id.Name, s.Tok == token.DEFINE)
				}
			}
		case *ast.IncDecStmt:
			inspectReads(s.X)
			if id, ok := s.X.(*ast.Ident); ok {
				recordWrite(id.Name, false)
			}
		case *ast.DeclStmt:
			if gd, ok := s.Decl.(*ast.GenDecl); ok && gd.Tok == token.VAR {
				for _, spec := range gd.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					for _, val := range vs.Values {
						inspectReads(val)
					}
					for _, id := range vs.Names {
						if id != nil {
							recordWrite(id.Name, true)
						}
					}
				}
			}
		case *ast.RangeStmt:
			inspectReads(s.X)
			if id, ok := s.Key.(*ast.Ident); ok {
				recordWrite(id.Name, s.Tok == token.DEFINE)
			}
			if id, ok := s.Value.(*ast.Ident); ok {
				recordWrite(id.Name, s.Tok == token.DEFINE)
			}
			walkBlock(s.Body)
		case *ast.IfStmt:
			walkSelNode(s.Init)
			if s.Cond != nil {
				inspectReads(s.Cond)
			}
			walkBlock(s.Body)
			walkSelNode(s.Else)
		case *ast.ForStmt:
			walkSelNode(s.Init)
			if s.Cond != nil {
				inspectReads(s.Cond)
			}
			walkSelNode(s.Post)
			walkBlock(s.Body)
		case *ast.BlockStmt:
			walkBlock(s)
		default:
			inspectReads(s)
		}
	}

	for _, stmt := range selectedStmts {
		walkSelNode(stmt)
	}

	params := make([]ExtractParam, 0, len(paramNames))
	for _, name := range paramNames {
		params = append(params, ExtractParam{Name: name, Type: lookupInferredType(name, typeEnv)})
	}

	usedAfterSel := map[string]bool{}
	ast.Inspect(enclosingFn.Body, func(n ast.Node) bool {
		if n == nil || n.End() <= selEndPos {
			return false
		}
		if id, ok := n.(*ast.Ident); ok && id != nil && !skip[id] && id.Pos() > selEndPos {
			usedAfterSel[id.Name] = true
		}
		return true
	})

	var results []ExtractParam
	resultSet := map[string]bool{}
	for _, name := range writtenInSel {
		if usedAfterSel[name] && !resultSet[name] {
			resultSet[name] = true
			results = append(results, ExtractParam{Name: name, Type: lookupInferredType(name, typeEnv)})
		}
	}

	if lastAssignsErr, errVarName := stmtAssignsOrChecksErr(lastStmt); lastAssignsErr && errVarName != "" && !resultSet[errVarName] {
		resultSet[errVarName] = true
		results = append(results, ExtractParam{Name: errVarName, Type: "error"})
	}

	funcName := strings.TrimSpace(req.FuncName)
	if funcName == "" {
		funcName = "extractedFunc"
	}

	receiver := ""
	if recvUsed && recvFullStr != "" {
		receiver = recvFullStr
	}

	previewSig := formatExtractedSignature(receiver, funcName, params, results)
	previewCall := formatExtractedCall(recvUsed, recvIdentName, funcName, params, results, declaredInSel)

	reply := ExtractMethodReply{
		DefaultName: funcName, Receiver: receiver, Params: params, Results: results,
		PreviewSignature: previewSig, PreviewCall: previewCall, StartByte: selStartByte, EndByte: selEndByte,
	}

	if produceEdits {
		origIndent := lineIndentationAtPos(fset, src, selStartPos)
		rawSelected := string(src[selStartByte:selEndByte])
		bodyText := formatExtractedBody(rawSelected, origIndent, results, lastStmt)
		newFuncDecl := fmt.Sprintf("\n\n%s {\n%s\n}", previewSig, bodyText)

		reply.EditsByPath = map[string][]TextEdit{
			req.Path: {
				{Range: lspRange(fset, src, selStartPos, selEndPos), NewText: previewCall},
				{Range: lspRange(fset, src, enclosingFn.End(), enclosingFn.End()), NewText: newFuncDecl},
			},
		}
	}

	return reply
}

func findEnclosingFuncDecl(fset *token.FileSet, file *ast.File, startPos, endPos token.Pos, cursorLine int) *ast.FuncDecl {
	var matched *ast.FuncDecl
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		if startPos >= fn.Body.Pos() && endPos <= fn.Body.End() {
			matched = fn
			break
		}
		startLine := fset.Position(fn.Body.Pos()).Line
		endLine := fset.Position(fn.Body.End()).Line
		if cursorLine >= startLine && cursorLine <= endLine {
			matched = fn
		}
	}
	return matched
}

func findSelectedStatements(fset *token.FileSet, body *ast.BlockStmt, startPos, endPos token.Pos, isCursor bool, cursorLine int) []ast.Stmt {
	var searchList func(list []ast.Stmt) []ast.Stmt
	var searchChildBlocks func(s ast.Stmt) []ast.Stmt

	searchBlock := func(b *ast.BlockStmt) []ast.Stmt {
		if b == nil {
			return nil
		}
		return searchList(b.List)
	}

	searchChildBlocks = func(s ast.Stmt) []ast.Stmt {
		switch n := s.(type) {
		case *ast.BlockStmt:
			return searchList(n.List)
		case *ast.IfStmt:
			if sub := searchBlock(n.Body); len(sub) > 0 {
				return sub
			}
			if n.Else != nil {
				return searchChildBlocks(n.Else)
			}
		case *ast.ForStmt:
			return searchBlock(n.Body)
		case *ast.RangeStmt:
			return searchBlock(n.Body)
		case *ast.SwitchStmt:
			return searchBlock(n.Body)
		case *ast.TypeSwitchStmt:
			return searchBlock(n.Body)
		case *ast.SelectStmt:
			return searchBlock(n.Body)
		case *ast.CaseClause:
			return searchList(n.Body)
		case *ast.CommClause:
			return searchList(n.Body)
		case *ast.LabeledStmt:
			if n.Stmt != nil {
				return searchChildBlocks(n.Stmt)
			}
		}
		return nil
	}

	searchList = func(list []ast.Stmt) []ast.Stmt {
		if len(list) == 0 {
			return nil
		}
		if isCursor {
			for i, s := range list {
				sStartLine := fset.Position(s.Pos()).Line
				sEndLine := fset.Position(s.End()).Line
				if (startPos >= s.Pos() && startPos <= s.End()) || (cursorLine >= sStartLine && cursorLine <= sEndLine) {
					if sub := searchChildBlocks(s); len(sub) > 0 {
						return sub
					}
					return list[i : i+1]
				}
			}
			return nil
		}

		first, last := -1, -1
		for i, s := range list {
			if (s.End() > startPos && s.Pos() < endPos) || (startPos == s.Pos() && endPos == s.End()) {
				if first == -1 {
					first = i
				}
				last = i
			}
		}
		if first == -1 {
			return nil
		}
		if first == last {
			s := list[first]
			if startPos > s.Pos() || endPos < s.End() {
				if sub := searchChildBlocks(s); len(sub) > 0 {
					return sub
				}
			}
		}
		return list[first : last+1]
	}

	return searchList(body.List)
}

func stmtAssignsOrChecksErr(stmt ast.Stmt) (bool, string) {
	switch s := stmt.(type) {
	case *ast.AssignStmt:
		if v := extractErrVarName(s); v != "" {
			return true, v
		}
	case *ast.IfStmt:
		if bin, ok := s.Cond.(*ast.BinaryExpr); ok && bin.Op == token.NEQ {
			for _, pair := range [2][2]ast.Expr{{bin.X, bin.Y}, {bin.Y, bin.X}} {
				id, ok1 := pair[0].(*ast.Ident)
				nilID, ok2 := pair[1].(*ast.Ident)
				if ok1 && ok2 && nilID.Name == "nil" && (id.Name == "err" || strings.HasSuffix(id.Name, "Err")) {
					return true, id.Name
				}
			}
		}
	}
	return false, ""
}

func formatExtractedSignature(receiver, funcName string, params, results []ExtractParam) string {
	var sb strings.Builder
	sb.WriteString("func ")
	if strings.TrimSpace(receiver) != "" {
		sb.WriteByte('(')
		sb.WriteString(strings.TrimSpace(receiver))
		sb.WriteString(") ")
	}
	sb.WriteString(funcName)
	sb.WriteByte('(')
	for i, p := range params {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(p.Name)
		sb.WriteByte(' ')
		sb.WriteString(p.Type)
	}
	sb.WriteByte(')')

	if len(results) == 1 {
		sb.WriteByte(' ')
		sb.WriteString(results[0].Type)
	} else if len(results) > 1 {
		sb.WriteString(" (")
		for i, r := range results {
			if i > 0 {
				sb.WriteString(", ")
			}
			sb.WriteString(r.Type)
		}
		sb.WriteByte(')')
	}
	return sb.String()
}

func formatExtractedCall(recvUsed bool, recvIdent, funcName string, params, results []ExtractParam, declaredInSel map[string]bool) string {
	args := make([]string, len(params))
	for i, p := range params {
		args[i] = p.Name
	}
	target := funcName
	if recvUsed && recvIdent != "" {
		target = recvIdent + "." + funcName
	}
	callExpr := fmt.Sprintf("%s(%s)", target, strings.Join(args, ", "))
	if len(results) == 0 {
		return callExpr
	}

	lhs := make([]string, len(results))
	hasNewVar := false
	for i, r := range results {
		lhs[i] = r.Name
		if declaredInSel[r.Name] {
			hasNewVar = true
		}
	}
	assignOp := "="
	if hasNewVar {
		assignOp = ":="
	}
	return fmt.Sprintf("%s %s %s", strings.Join(lhs, ", "), assignOp, callExpr)
}

func formatExtractedBody(rawSelected, origIndent string, results []ExtractParam, lastStmt ast.Stmt) string {
	lines := strings.Split(rawSelected, "\n")
	for i, line := range lines {
		if i == 0 {
			lines[i] = "\t" + strings.TrimLeft(line, " \t")
			continue
		}
		if strings.TrimSpace(line) == "" {
			lines[i] = ""
			continue
		}
		trimmed := line
		if origIndent != "" && strings.HasPrefix(trimmed, origIndent) {
			trimmed = strings.TrimPrefix(trimmed, origIndent)
		} else {
			trimmed = strings.TrimLeft(trimmed, "\t ")
		}
		lines[i] = "\t" + trimmed
	}

	_, endsWithReturn := lastStmt.(*ast.ReturnStmt)
	if len(results) > 0 && !endsWithReturn {
		retNames := make([]string, len(results))
		for i, r := range results {
			retNames[i] = r.Name
		}
		lines = append(lines, "\treturn "+strings.Join(retNames, ", "))
	}
	return strings.Join(lines, "\n")
}
