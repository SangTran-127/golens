package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
)

type TextEdit = SigTextEdit

type IntentionReq struct {
	Path   string `json:"path"`
	Src    string `json:"src"`
	Offset int    `json:"offset"`
	Action string `json:"action"`
}

type IntentionItem struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

type IntentionReply struct {
	Available   []IntentionItem       `json:"available,omitempty"`
	EditsByPath map[string][]TextEdit `json:"editsByPath,omitempty"`
	Error       string                `json:"error,omitempty"`
}

const (
	IntentionWrapErr         = "wrap_err"
	IntentionToggleString    = "toggle_string"
	IntentionToggleVarAssign = "toggle_var_assign"
)

func ApplyGoIntentionJSON(reqJSON string) string {
	var req IntentionReq
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		b, _ := json.Marshal(IntentionReply{Error: "invalid request: " + err.Error()})
		return string(b)
	}
	reply := ApplyGoIntention(req)
	b, _ := json.Marshal(reply)
	return string(b)
}

func ApplyGoIntention(req IntentionReq) IntentionReply {
	var src []byte
	if req.Src != "" {
		src = []byte(req.Src)
	} else if strings.TrimSpace(req.Path) != "" {
		data, err := os.ReadFile(req.Path)
		if err != nil {
			return IntentionReply{Error: "failed to read file: " + err.Error()}
		}
		src = data
	} else {
		return IntentionReply{Error: "missing source or file path"}
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, req.Path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			return IntentionReply{Error: "failed to parse file: " + err.Error()}
		}
		return IntentionReply{Error: "failed to parse file"}
	}

	tf := fset.File(file.Pos())
	if tf == nil {
		return IntentionReply{Error: "failed to locate token file"}
	}

	offset := req.Offset
	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)
	cursorLine := fset.Position(pos).Line

	action := strings.TrimSpace(req.Action)
	if action == "" || action == "list" {
		var available []IntentionItem
		if _, ok := computeWrapErrEdit(fset, file, src, pos, cursorLine); ok {
			available = append(available, IntentionItem{
				ID:    IntentionWrapErr,
				Title: "Handle Error with if err != nil",
			})
		}
		if _, ok := computeToggleStringEdit(fset, file, src, pos, cursorLine, false); ok {
			available = append(available, IntentionItem{
				ID:    IntentionToggleString,
				Title: "Convert Between Raw and Interpreted String",
			})
		}
		if _, ok := computeToggleVarAssignEdit(fset, file, src, pos, cursorLine); ok {
			available = append(available, IntentionItem{
				ID:    IntentionToggleVarAssign,
				Title: "Convert Between ':=' and 'var' Declaration",
			})
		}
		return IntentionReply{Available: available}
	}

	switch action {
	case IntentionWrapErr:
		edit, ok := computeWrapErrEdit(fset, file, src, pos, cursorLine)
		if !ok {
			return IntentionReply{Error: "no error-producing statement found at cursor"}
		}
		return IntentionReply{
			EditsByPath: map[string][]TextEdit{
				req.Path: {edit},
			},
		}
	case IntentionToggleString:
		edit, ok := computeToggleStringEdit(fset, file, src, pos, cursorLine, true)
		if !ok {
			return IntentionReply{Error: "no convertible string literal found at cursor"}
		}
		return IntentionReply{
			EditsByPath: map[string][]TextEdit{
				req.Path: {edit},
			},
		}
	case IntentionToggleVarAssign:
		edit, ok := computeToggleVarAssignEdit(fset, file, src, pos, cursorLine)
		if !ok {
			return IntentionReply{Error: "no convertible variable declaration found at cursor"}
		}
		return IntentionReply{
			EditsByPath: map[string][]TextEdit{
				req.Path: {edit},
			},
		}
	default:
		return IntentionReply{Error: "unknown intention action: " + action}
	}
}

func findInnermostEnclosingFunc(fset *token.FileSet, file *ast.File, pos token.Pos, cursorLine int) (*ast.FuncType, *ast.BlockStmt) {
	var bestType *ast.FuncType
	var bestBody *ast.BlockStmt

	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		var fnType *ast.FuncType
		var fnBody *ast.BlockStmt
		switch fn := n.(type) {
		case *ast.FuncDecl:
			fnType = fn.Type
			fnBody = fn.Body
		case *ast.FuncLit:
			fnType = fn.Type
			fnBody = fn.Body
		}
		if fnType != nil && fnBody != nil {
			startLine := fset.Position(fnBody.Pos()).Line
			endLine := fset.Position(fnBody.End()).Line
			if (pos >= fnBody.Pos() && pos <= fnBody.End()) || (cursorLine >= startLine && cursorLine <= endLine) {
				if bestBody == nil || (fnBody.Pos() >= bestBody.Pos() && fnBody.End() <= bestBody.End()) {
					bestType = fnType
					bestBody = fnBody
				}
			}
		}
		return true
	})

	return bestType, bestBody
}

type stmtInList struct {
	stmt     ast.Stmt
	nextStmt ast.Stmt
}

func collectStmtsInFuncBody(body *ast.BlockStmt) []stmtInList {
	var out []stmtInList
	var walkList func(list []ast.Stmt)
	var walkStmt func(s ast.Stmt)

	walkList = func(list []ast.Stmt) {
		for i, s := range list {
			var next ast.Stmt
			if i+1 < len(list) {
				next = list[i+1]
			}
			out = append(out, stmtInList{stmt: s, nextStmt: next})
			walkStmt(s)
		}
	}

	walkStmt = func(s ast.Stmt) {
		if s == nil {
			return
		}
		switch n := s.(type) {
		case *ast.BlockStmt:
			walkList(n.List)
		case *ast.IfStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
			if n.Else != nil {
				walkStmt(n.Else)
			}
		case *ast.ForStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
		case *ast.RangeStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
		case *ast.SwitchStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
		case *ast.TypeSwitchStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
		case *ast.SelectStmt:
			if n.Body != nil {
				walkList(n.Body.List)
			}
		case *ast.CaseClause:
			walkList(n.Body)
		case *ast.CommClause:
			walkList(n.Body)
		case *ast.LabeledStmt:
			if n.Stmt != nil {
				out = append(out, stmtInList{stmt: n.Stmt})
				walkStmt(n.Stmt)
			}
		}
	}

	walkList(body.List)
	return out
}

func computeWrapErrEdit(fset *token.FileSet, file *ast.File, src []byte, pos token.Pos, cursorLine int) (TextEdit, bool) {
	fnType, fnBody := findInnermostEnclosingFunc(fset, file, pos, cursorLine)
	if fnType == nil || fnBody == nil {
		return TextEdit{}, false
	}

	stmts := collectStmtsInFuncBody(fnBody)
	var target stmtInList
	matchedByPos := false

	for _, item := range stmts {
		switch s := item.stmt.(type) {
		case *ast.AssignStmt:
			if extractErrVarName(s) == "" {
				continue
			}
		case *ast.ExprStmt:
			if _, ok := s.X.(*ast.CallExpr); !ok {
				continue
			}
		default:
			continue
		}

		sStart := item.stmt.Pos()
		sEnd := item.stmt.End()
		startLine := fset.Position(sStart).Line
		endLine := fset.Position(sEnd).Line

		if pos >= sStart && pos <= sEnd {
			target = item
			matchedByPos = true
		} else if !matchedByPos && cursorLine >= startLine && cursorLine <= endLine {
			target = item
		}
	}

	if target.stmt == nil {
		return TextEdit{}, false
	}

	indent := lineIndentationAtPos(fset, src, target.stmt.Pos())

	switch s := target.stmt.(type) {
	case *ast.AssignStmt:
		errVar := extractErrVarName(s)
		if errVar == "" {
			return TextEdit{}, false
		}
		if isAlreadyCheckingErr(target.nextStmt, errVar) {
			return TextEdit{}, false
		}
		retStmt := formatZeroReturnStmt(fset, file, src, fnType.Results, errVar)
		ifBlock := fmt.Sprintf("\n%sif %s != nil {\n%s\t%s\n%s}", indent, errVar, indent, retStmt, indent)
		return TextEdit{
			Range:   lspRange(fset, src, s.End(), s.End()),
			NewText: ifBlock,
		}, true

	case *ast.ExprStmt:
		callExpr, ok := s.X.(*ast.CallExpr)
		if !ok {
			return TextEdit{}, false
		}
		callText := exprString(fset, src, callExpr)
		if callText == "" {
			return TextEdit{}, false
		}
		retStmt := formatZeroReturnStmt(fset, file, src, fnType.Results, "err")
		lhs := "err"
		if isTwoValueErrorCall(file, callExpr) {
			lhs = "_, err"
		}
		rewritten := fmt.Sprintf("if %s := %s; err != nil {\n%s\t%s\n%s}", lhs, callText, indent, retStmt, indent)
		return TextEdit{
			Range:   lspRange(fset, src, s.Pos(), s.End()),
			NewText: rewritten,
		}, true
	}

	return TextEdit{}, false
}

func isTwoValueErrorCall(file *ast.File, call *ast.CallExpr) bool {
	switch fun := call.Fun.(type) {
	case *ast.SelectorExpr:
		sel := fun.Sel.Name
		if pkgIdent, ok := fun.X.(*ast.Ident); ok {
			switch pkgIdent.Name + "." + sel {
			case "fmt.Print", "fmt.Println", "fmt.Printf",
				"fmt.Fprint", "fmt.Fprintln", "fmt.Fprintf",
				"fmt.Scan", "fmt.Scanln", "fmt.Scanf",
				"io.Copy", "io.CopyN", "io.WriteString",
				"os.Open", "os.Create", "os.ReadFile",
				"json.Marshal", "strconv.Atoi":
				return true
			}
		}
		if (sel == "Write" || sel == "Read" || sel == "WriteString") && len(call.Args) == 1 {
			return true
		}
	case *ast.Ident:
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if ok && fn.Recv == nil && fn.Name.Name == fun.Name && fn.Type.Results != nil {
				if fn.Type.Results.NumFields() == 2 {
					return true
				}
			}
		}
	}
	return false
}

func extractErrVarName(s *ast.AssignStmt) string {
	if s.Tok != token.DEFINE && s.Tok != token.ASSIGN {
		return ""
	}
	var errVar string
	for _, lhs := range s.Lhs {
		id, ok := lhs.(*ast.Ident)
		if !ok || id == nil {
			continue
		}
		if id.Name == "err" || strings.HasSuffix(id.Name, "Err") {
			errVar = id.Name
		}
	}
	return errVar
}

func isAlreadyCheckingErr(next ast.Stmt, errVar string) bool {
	ifStmt, ok := next.(*ast.IfStmt)
	if !ok || ifStmt == nil || ifStmt.Cond == nil {
		return false
	}
	bin, ok := ifStmt.Cond.(*ast.BinaryExpr)
	if !ok || bin.Op != token.NEQ {
		return false
	}
	xIdent, xOk := bin.X.(*ast.Ident)
	yIdent, yOk := bin.Y.(*ast.Ident)
	if xOk && yOk {
		if (xIdent.Name == errVar && yIdent.Name == "nil") || (xIdent.Name == "nil" && yIdent.Name == errVar) {
			return true
		}
	}
	return false
}

func formatZeroReturnStmt(fset *token.FileSet, file *ast.File, src []byte, results *ast.FieldList, errVar string) string {
	if results == nil || len(results.List) == 0 {
		return "return"
	}

	var resultTypes []ast.Expr
	for _, field := range results.List {
		if len(field.Names) == 0 {
			resultTypes = append(resultTypes, field.Type)
		} else {
			for range field.Names {
				resultTypes = append(resultTypes, field.Type)
			}
		}
	}

	if len(resultTypes) == 0 {
		return "return"
	}

	vals := make([]string, len(resultTypes))
	for i, tExpr := range resultTypes {
		if i == len(resultTypes)-1 && isErrorTypeExpr(tExpr) {
			vals[i] = errVar
		} else {
			vals[i] = zeroValueForTypeExpr(fset, file, src, tExpr, 0)
		}
	}

	return "return " + strings.Join(vals, ", ")
}

func isErrorTypeExpr(expr ast.Expr) bool {
	id, ok := expr.(*ast.Ident)
	return ok && id != nil && id.Name == "error"
}

func zeroValueForTypeExpr(fset *token.FileSet, file *ast.File, src []byte, expr ast.Expr, depth int) string {
	if expr == nil || depth > 8 {
		return "nil"
	}
	switch t := expr.(type) {
	case *ast.Ident:
		switch t.Name {
		case "int", "int8", "int16", "int32", "int64",
			"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
			"byte", "rune", "float32", "float64", "complex64", "complex128":
			return "0"
		case "string":
			return `""`
		case "bool":
			return "false"
		case "any", "error":
			return "nil"
		default:
			if ts := findTypeSpecInFile(file, t.Name); ts != nil {
				switch underlying := ts.Type.(type) {
				case *ast.InterfaceType, *ast.StarExpr, *ast.MapType, *ast.ChanType, *ast.FuncType:
					return "nil"
				case *ast.ArrayType:
					if underlying.Len == nil {
						return "nil"
					}
					return t.Name + "{}"
				case *ast.Ident:
					return zeroValueForTypeExpr(fset, file, src, underlying, depth+1)
				default:
					return t.Name + "{}"
				}
			}
			return t.Name + "{}"
		}
	case *ast.StarExpr, *ast.MapType, *ast.ChanType, *ast.FuncType, *ast.InterfaceType:
		return "nil"
	case *ast.ArrayType:
		if t.Len == nil {
			return "nil"
		}
		raw := exprString(fset, src, t)
		if raw != "" {
			return raw + "{}"
		}
		return "nil"
	default:
		raw := exprString(fset, src, t)
		if raw != "" {
			return raw + "{}"
		}
		return "nil"
	}
}

func findTypeSpecInFile(file *ast.File, name string) *ast.TypeSpec {
	if file == nil {
		return nil
	}
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		for _, spec := range gd.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if ok && ts.Name != nil && ts.Name.Name == name {
				return ts
			}
		}
	}
	return nil
}

func lineIndentationAtPos(fset *token.FileSet, src []byte, pos token.Pos) string {
	p := fset.Position(pos)
	lineStart := p.Offset - (p.Column - 1)
	if lineStart < 0 {
		lineStart = 0
	}
	i := lineStart
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i++
	}
	return string(src[lineStart:i])
}

func computeToggleStringEdit(fset *token.FileSet, file *ast.File, src []byte, pos token.Pos, cursorLine int, allowLineFallback bool) (TextEdit, bool) {
	importPaths := map[*ast.BasicLit]bool{}
	for _, imp := range file.Imports {
		if imp != nil && imp.Path != nil {
			importPaths[imp.Path] = true
		}
	}

	var exactLit *ast.BasicLit
	var lineLit *ast.BasicLit

	ast.Inspect(file, func(n ast.Node) bool {
		lit, ok := n.(*ast.BasicLit)
		if !ok || lit == nil || lit.Kind != token.STRING || importPaths[lit] {
			return true
		}
		if pos >= lit.Pos() && pos <= lit.End() {
			exactLit = lit
			return false
		}
		if allowLineFallback && lineLit == nil {
			startLine := fset.Position(lit.Pos()).Line
			endLine := fset.Position(lit.End()).Line
			if cursorLine >= startLine && cursorLine <= endLine {
				lineLit = lit
			}
		}
		return true
	})

	target := exactLit
	if target == nil && allowLineFallback {
		target = lineLit
	}
	if target == nil || len(target.Value) < 2 {
		return TextEdit{}, false
	}

	raw := target.Value
	if strings.HasPrefix(raw, `"`) {
		unquoted, err := strconv.Unquote(raw)
		if err != nil || strings.Contains(unquoted, "`") {
			return TextEdit{}, false
		}
		return TextEdit{
			Range:   lspRange(fset, src, target.Pos(), target.End()),
			NewText: "`" + unquoted + "`",
		}, true
	}

	if strings.HasPrefix(raw, "`") {
		unquoted, err := strconv.Unquote(raw)
		if err != nil {
			return TextEdit{}, false
		}
		return TextEdit{
			Range:   lspRange(fset, src, target.Pos(), target.End()),
			NewText: strconv.Quote(unquoted),
		}, true
	}

	return TextEdit{}, false
}

func computeToggleVarAssignEdit(fset *token.FileSet, file *ast.File, src []byte, pos token.Pos, cursorLine int) (TextEdit, bool) {
	_, fnBody := findInnermostEnclosingFunc(fset, file, pos, cursorLine)
	if fnBody != nil {
		stmts := collectStmtsInFuncBody(fnBody)
		var matchedStmt ast.Stmt
		matchedByPos := false

		for _, item := range stmts {
			if !isToggleableVarAssignStmt(item.stmt) {
				continue
			}
			sStart := item.stmt.Pos()
			sEnd := item.stmt.End()
			startLine := fset.Position(sStart).Line
			endLine := fset.Position(sEnd).Line

			if pos >= sStart && pos <= sEnd {
				matchedStmt = item.stmt
				matchedByPos = true
			} else if !matchedByPos && cursorLine >= startLine && cursorLine <= endLine {
				matchedStmt = item.stmt
			}
		}

		if matchedStmt != nil {
			return buildToggleVarAssignEdit(fset, src, matchedStmt)
		}
	}

	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.VAR || gd.Lparen.IsValid() || len(gd.Specs) != 1 {
			continue
		}
		startLine := fset.Position(gd.Pos()).Line
		endLine := fset.Position(gd.End()).Line
		if (pos >= gd.Pos() && pos <= gd.End()) || (cursorLine >= startLine && cursorLine <= endLine) {
			return buildToggleGenDeclEdit(fset, src, gd)
		}
	}

	return TextEdit{}, false
}

func isToggleableVarAssignStmt(s ast.Stmt) bool {
	switch n := s.(type) {
	case *ast.AssignStmt:
		if n.Tok != token.DEFINE || len(n.Lhs) != 1 || len(n.Rhs) != 1 {
			return false
		}
		id, ok := n.Lhs[0].(*ast.Ident)
		return ok && id != nil && id.Name != "_"
	case *ast.DeclStmt:
		gd, ok := n.Decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.VAR || gd.Lparen.IsValid() || len(gd.Specs) != 1 {
			return false
		}
		vs, ok := gd.Specs[0].(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || len(vs.Values) != 1 {
			return false
		}
		return vs.Names[0] != nil && vs.Names[0].Name != "_"
	default:
		return false
	}
}

func buildToggleVarAssignEdit(fset *token.FileSet, src []byte, s ast.Stmt) (TextEdit, bool) {
	switch n := s.(type) {
	case *ast.AssignStmt:
		id, ok := n.Lhs[0].(*ast.Ident)
		if !ok || id == nil {
			return TextEdit{}, false
		}
		rhsText := exprString(fset, src, n.Rhs[0])
		if rhsText == "" {
			return TextEdit{}, false
		}
		return TextEdit{
			Range:   lspRange(fset, src, n.Pos(), n.End()),
			NewText: fmt.Sprintf("var %s = %s", id.Name, rhsText),
		}, true
	case *ast.DeclStmt:
		gd, ok := n.Decl.(*ast.GenDecl)
		if !ok {
			return TextEdit{}, false
		}
		return buildToggleGenDeclEdit(fset, src, gd)
	default:
		return TextEdit{}, false
	}
}

func buildToggleGenDeclEdit(fset *token.FileSet, src []byte, gd *ast.GenDecl) (TextEdit, bool) {
	if gd == nil || gd.Tok != token.VAR || gd.Lparen.IsValid() || len(gd.Specs) != 1 {
		return TextEdit{}, false
	}
	vs, ok := gd.Specs[0].(*ast.ValueSpec)
	if !ok || len(vs.Names) != 1 || len(vs.Values) != 1 || vs.Names[0] == nil {
		return TextEdit{}, false
	}
	rhsText := exprString(fset, src, vs.Values[0])
	if rhsText == "" {
		return TextEdit{}, false
	}
	return TextEdit{
		Range:   lspRange(fset, src, gd.Pos(), gd.End()),
		NewText: fmt.Sprintf("%s := %s", vs.Names[0].Name, rhsText),
	}, true
}
