package analysis

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strings"
)

type sqlTxLeakCandidate struct {
	scopeBody *ast.BlockStmt
	block     *ast.BlockStmt
	idx       int
	decl      sqlTxDecl
	inLoop    bool
	leakLine  int
}

func collectSQLTxLeakCandidatesInFile(fset *token.FileSet, file *ast.File) []sqlTxLeakCandidate {
	if fset == nil || file == nil {
		return nil
	}
	hasSQLImport := fileImportsSQL(file)
	var out []sqlTxLeakCandidate
	var scanScope func(scopeBody, blk *ast.BlockStmt, inLoop bool)
	var scanNested func(scopeBody *ast.BlockStmt, stmt ast.Stmt, inLoop bool)

	scanNested = func(scopeBody *ast.BlockStmt, stmt ast.Stmt, inLoop bool) {
		if stmt == nil {
			return
		}
		switch s := stmt.(type) {
		case *ast.BlockStmt:
			scanScope(scopeBody, s, inLoop)
			return
		case *ast.IfStmt:
			scanScope(scopeBody, s.Body, inLoop)
			if s.Else != nil {
				scanNested(scopeBody, s.Else, inLoop)
			}
			return
		case *ast.ForStmt:
			scanScope(scopeBody, s.Body, true)
			return
		case *ast.RangeStmt:
			scanScope(scopeBody, s.Body, true)
			return
		case *ast.SwitchStmt:
			if s.Body != nil {
				for _, raw := range s.Body.List {
					if cc, ok := raw.(*ast.CaseClause); ok {
						for _, sub := range cc.Body {
							scanNested(scopeBody, sub, inLoop)
						}
					}
				}
			}
			return
		case *ast.TypeSwitchStmt:
			if s.Body != nil {
				for _, raw := range s.Body.List {
					if cc, ok := raw.(*ast.CaseClause); ok {
						for _, sub := range cc.Body {
							scanNested(scopeBody, sub, inLoop)
						}
					}
				}
			}
			return
		case *ast.SelectStmt:
			if s.Body != nil {
				for _, raw := range s.Body.List {
					if cc, ok := raw.(*ast.CommClause); ok {
						for _, sub := range cc.Body {
							scanNested(scopeBody, sub, inLoop)
						}
					}
				}
			}
			return
		case *ast.LabeledStmt:
			scanNested(scopeBody, s.Stmt, inLoop)
			return
		}
		ast.Inspect(stmt, func(n ast.Node) bool {
			if lit, ok := n.(*ast.FuncLit); ok && lit.Body != nil {
				scanScope(lit.Body, lit.Body, false)
				return false
			}
			return true
		})
	}

	scanScope = func(scopeBody, blk *ast.BlockStmt, inLoop bool) {
		if blk == nil {
			return
		}
		for i, stmt := range blk.List {
			if decl, ok := matchSQLTxBeginStmt(fset, stmt, blk, hasSQLImport); ok {
				decl.stmtIndex = i
				if leakLine, leaked := findSQLTxLeakInRemainingStmts(fset, blk.List[i+1:], decl, inLoop); leaked {
					out = append(out, sqlTxLeakCandidate{
						scopeBody: scopeBody,
						block:     blk,
						idx:       i,
						decl:      decl,
						inLoop:    inLoop,
						leakLine:  leakLine,
					})
				}
			}
			scanNested(scopeBody, stmt, inLoop)
		}
	}

	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok && fn.Body != nil {
			scanScope(fn.Body, fn.Body, false)
		}
	}
	return out
}

func inspectASTFileSQLTransactions(fset *token.FileSet, file *ast.File, src string) []safetyCheckIssue {
	var issues []safetyCheckIssue
	for _, c := range collectSQLTxLeakCandidatesInFile(fset, file) {
		canFix := !c.inLoop && !hasNonBlockElseAfterAssign(fset, c.block, c.idx, c.decl.errVar, c.decl.txVar, c.decl.txVar)
		issues = append(issues, safetyCheckIssue{
			Line:        c.decl.beginLine,
			Col:         c.decl.beginCol,
			TargetName:  c.decl.txVar,
			InLoop:      c.inLoop,
			CanQuickFix: canFix,
			FixTitle:    "Add defer " + c.decl.txVar + ".Rollback()",
			Message: fmt.Sprintf(
				"SQL transaction %q may leak on early return at line %d without defer %s.Rollback() or %s.Rollback()",
				c.decl.txVar,
				c.leakLine,
				c.decl.txVar,
				c.decl.txVar,
			),
		})
	}
	sortSafetyCheckIssues(issues)
	return issues
}

func fileImportsSQL(file *ast.File) bool {
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.ToLower(strings.Trim(imp.Path.Value, `"`+"`"))
		if p == "database/sql" || strings.Contains(p, "pgx") || strings.Contains(p, "gorm") || strings.Contains(p, "sqlx") || strings.Contains(p, "sqlite") || strings.Contains(p, "entgo.io") {
			return true
		}
	}
	return false
}

type sqlTxDecl struct {
	assignStmt *ast.AssignStmt
	txVar      string
	errVar     string
	beginLine  int
	beginCol   int
	assignLine int
	stmtIndex  int
}

func matchSQLTxBeginStmt(fset *token.FileSet, stmt ast.Stmt, fnBody *ast.BlockStmt, hasSQLImport bool) (sqlTxDecl, bool) {
	assign, ok := stmt.(*ast.AssignStmt)
	if !ok || len(assign.Rhs) != 1 || len(assign.Lhs) == 0 {
		return sqlTxDecl{}, false
	}
	call, ok := unwrapSafetyParens(assign.Rhs[0]).(*ast.CallExpr)
	if !ok {
		return sqlTxDecl{}, false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return sqlTxDecl{}, false
	}
	method := sel.Sel.Name
	if method != "Begin" && method != "BeginTx" {
		return sqlTxDecl{}, false
	}
	txIdent, ok := assign.Lhs[0].(*ast.Ident)
	if !ok || txIdent.Name == "" || txIdent.Name == "_" {
		return sqlTxDecl{}, false
	}
	errVar := ""
	if len(assign.Lhs) >= 2 {
		if id, ok := assign.Lhs[1].(*ast.Ident); ok && id.Name != "" && id.Name != "_" {
			errVar = id.Name
		}
	}

	if method == "Begin" && !hasSQLImport && !isLikelySQLReceiver(sel.X) && !blockCallsTxMethod(fnBody, txIdent.Name, "Commit") && !blockCallsTxMethod(fnBody, txIdent.Name, "Rollback") {
		return sqlTxDecl{}, false
	}
	if blockReturnsIdent(fnBody, txIdent.Name) {
		return sqlTxDecl{}, false
	}
	if !blockCallsTxMethod(fnBody, txIdent.Name, "Commit") && !blockCallsTxMethod(fnBody, txIdent.Name, "Rollback") && !hasSQLImport {
		return sqlTxDecl{}, false
	}

	pos := fset.Position(call.Pos())
	return sqlTxDecl{
		assignStmt: assign,
		txVar:      txIdent.Name,
		errVar:     errVar,
		beginLine:  pos.Line,
		beginCol:   pos.Column,
		assignLine: fset.Position(assign.Pos()).Line,
	}, true
}

func isLikelySQLReceiver(expr ast.Expr) bool {
	switch e := unwrapSafetyParens(expr).(type) {
	case *ast.Ident:
		return isSQLName(e.Name)
	case *ast.SelectorExpr:
		return e.Sel != nil && isSQLName(e.Sel.Name)
	case *ast.CallExpr:
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok && sel.Sel != nil {
			return isSQLName(sel.Sel.Name)
		}
	}
	return false
}

func isSQLName(name string) bool {
	lower := strings.ToLower(name)
	for _, kw := range []string{"db", "sql", "conn", "pool", "store", "repo", "gorm"} {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

func blockCallsTxMethod(root ast.Node, txVar, method string) bool {
	found := false
	ast.Inspect(root, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if callReceivesMethod(call, txVar, method) {
			found = true
			return false
		}
		return true
	})
	return found
}

func blockReturnsIdent(root ast.Node, txVar string) bool {
	found := false
	ast.Inspect(root, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		ret, ok := n.(*ast.ReturnStmt)
		if !ok {
			return true
		}
		if returnStmtReturnsIdent(ret, txVar) {
			found = true
			return false
		}
		return true
	})
	return found
}

func returnStmtReturnsIdent(ret *ast.ReturnStmt, txVar string) bool {
	for _, res := range ret.Results {
		if id, ok := unwrapSafetyParens(res).(*ast.Ident); ok && id.Name == txVar {
			return true
		}
	}
	return false
}

func callReceivesMethod(call *ast.CallExpr, recvName, method string) bool {
	if call == nil {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil || sel.Sel.Name != method {
		return false
	}
	id, ok := unwrapSafetyParens(sel.X).(*ast.Ident)
	return ok && id.Name == recvName
}

func deferGuardsTxRollback(stmt *ast.DeferStmt, txVar string) bool {
	if stmt == nil || stmt.Call == nil {
		return false
	}
	if callReceivesMethod(stmt.Call, txVar, "Rollback") {
		return true
	}
	if lit, ok := unwrapSafetyParens(stmt.Call.Fun).(*ast.FuncLit); ok && lit.Body != nil {
		return blockCallsTxMethod(lit.Body, txVar, "Rollback")
	}
	for _, arg := range stmt.Call.Args {
		if id, ok := unwrapSafetyParens(arg).(*ast.Ident); ok && id.Name == txVar {
			return true
		}
	}
	return false
}

func isBeginErrGuardIfStmt(stmt ast.Stmt, decl sqlTxDecl) bool {
	ifStmt, ok := stmt.(*ast.IfStmt)
	if !ok || ifStmt.Init != nil || ifStmt.Else != nil {
		return false
	}
	if !ifBodyOnlyExits(ifStmt.Body) {
		return false
	}
	bin, ok := unwrapSafetyParens(ifStmt.Cond).(*ast.BinaryExpr)
	if !ok || bin.Op != token.NEQ {
		return false
	}
	rhs, ok := unwrapSafetyParens(bin.Y).(*ast.Ident)
	if !ok || rhs.Name != "nil" {
		return false
	}
	if decl.errVar != "" {
		if lhs, ok := unwrapSafetyParens(bin.X).(*ast.Ident); ok && lhs.Name == decl.errVar {
			return true
		}
	}
	if sel, ok := unwrapSafetyParens(bin.X).(*ast.SelectorExpr); ok && sel.Sel != nil && sel.Sel.Name == "Error" {
		if id, ok := unwrapSafetyParens(sel.X).(*ast.Ident); ok && id.Name == decl.txVar {
			return true
		}
	}
	return false
}

func ifBodyOnlyExits(body *ast.BlockStmt) bool {
	if body == nil {
		return false
	}
	for _, st := range body.List {
		if _, ok := st.(*ast.ReturnStmt); ok {
			return true
		}
	}
	return false
}

type sqlTxFlowState struct {
	hasDeferRollback bool
	committed        bool
	rolledBack       bool
	errVarLive       bool
}

func (s sqlTxFlowState) safe() bool {
	return s.hasDeferRollback || s.committed || s.rolledBack
}

func findSQLTxLeakInRemainingStmts(fset *token.FileSet, stmts []ast.Stmt, decl sqlTxDecl, inLoop bool) (int, bool) {
	state := sqlTxFlowState{errVarLive: decl.errVar != ""}
	idx := 0
	if len(stmts) > 0 && isBeginErrGuardIfStmt(stmts[0], decl) {
		idx = 1
	}
	line, _ := walkSQLTxStmts(fset, stmts[idx:], decl, &state, inLoop)
	return line, line != 0
}

func walkSQLTxStmts(fset *token.FileSet, stmts []ast.Stmt, decl sqlTxDecl, state *sqlTxFlowState, inTxLoop bool) (int, bool) {
	for _, stmt := range stmts {
		if state.hasDeferRollback {
			return 0, true
		}
		if def, ok := stmt.(*ast.DeferStmt); ok {
			if deferGuardsTxRollback(def, decl.txVar) {
				state.hasDeferRollback = true
				return 0, true
			}
			continue
		}
		if assign, ok := stmt.(*ast.AssignStmt); ok && decl.errVar != "" && stmtAssignsIdent(assign, decl.errVar) {
			state.errVarLive = false
		}
		if stmtCallsMethodOutsideFuncLit(stmt, decl.txVar, "Rollback") {
			state.rolledBack = true
		}
		if stmtCallsMethodOutsideFuncLit(stmt, decl.txVar, "Commit") {
			state.committed = true
		}

		switch s := stmt.(type) {
		case *ast.ReturnStmt:
			if !state.safe() && !returnStmtReturnsIdent(s, decl.txVar) {
				return fset.Position(s.Pos()).Line, false
			}
			return 0, false
		case *ast.BranchStmt:
			if inTxLoop && (s.Tok == token.CONTINUE || s.Tok == token.BREAK) && !state.safe() {
				return fset.Position(s.Pos()).Line, false
			}
			return 0, false
		case *ast.BlockStmt:
			sub := *state
			if line, fell := walkSQLTxStmts(fset, s.List, decl, &sub, inTxLoop); line != 0 {
				return line, false
			} else if !fell {
				return 0, false
			} else {
				*state = sub
			}
		case *ast.IfStmt:
			bodyState, elseState := *state, *state
			if s.Init != nil {
				if assign, ok := s.Init.(*ast.AssignStmt); ok && decl.errVar != "" && stmtAssignsIdent(assign, decl.errVar) {
					bodyState.errVarLive, elseState.errVarLive, state.errVarLive = false, false, false
				}
				if stmtCallsMethodOutsideFuncLit(s.Init, decl.txVar, "Commit") {
					bodyState.committed, elseState.committed, state.committed = true, true, true
				}
				if stmtCallsMethodOutsideFuncLit(s.Init, decl.txVar, "Rollback") {
					bodyState.rolledBack, elseState.rolledBack, state.rolledBack = true, true, true
				}
			} else {
				if (state.errVarLive && isErrNotNilGuardCond(fset, s.Cond, decl.errVar)) || isSQLTxErrorSelCheck(fset, s.Cond, decl.txVar) || isResourceNilGuardExpr(fset, s.Cond, decl.txVar, decl.txVar) {
					bodyState.rolledBack = true
				}
				if (state.errVarLive && isResourceSuccessCond(fset, s.Cond, decl.errVar, decl.txVar, decl.txVar)) || isResourceSuccessCond(fset, s.Cond, "-", decl.txVar, decl.txVar) {
					elseState.rolledBack = true
				}
			}
			fell1, fell2 := true, true
			if s.Body != nil {
				var line int
				if line, fell1 = walkSQLTxStmts(fset, s.Body.List, decl, &bodyState, inTxLoop); line != 0 {
					return line, false
				}
			}
			if s.Else != nil {
				var line int
				if elseBlock, ok := s.Else.(*ast.BlockStmt); ok {
					line, fell2 = walkSQLTxStmts(fset, elseBlock.List, decl, &elseState, inTxLoop)
				} else {
					line, fell2 = walkSQLTxStmts(fset, []ast.Stmt{s.Else}, decl, &elseState, inTxLoop)
				}
				if line != 0 {
					return line, false
				}
			}
			if !fell1 && !fell2 {
				return 0, false
			}
			if fell1 && !fell2 {
				*state = bodyState
			} else if !fell1 && fell2 {
				*state = elseState
			} else {
				state.hasDeferRollback = bodyState.hasDeferRollback && elseState.hasDeferRollback
				state.committed = bodyState.committed && elseState.committed
				state.rolledBack = bodyState.safe() && elseState.safe()
				state.errVarLive = bodyState.errVarLive && elseState.errVarLive
			}
		case *ast.ForStmt:
			if s.Body != nil {
				sub := *state
				if line, _ := walkSQLTxStmts(fset, s.Body.List, decl, &sub, false); line != 0 {
					return line, false
				}
			}
		case *ast.RangeStmt:
			if s.Body != nil {
				sub := *state
				if line, _ := walkSQLTxStmts(fset, s.Body.List, decl, &sub, false); line != 0 {
					return line, false
				}
			}
		case *ast.SwitchStmt:
			if s.Body != nil {
				sub := *state
				if line, _ := walkSQLTxStmts(fset, s.Body.List, decl, &sub, false); line != 0 {
					return line, false
				}
			}
		case *ast.TypeSwitchStmt:
			if s.Body != nil {
				sub := *state
				if line, _ := walkSQLTxStmts(fset, s.Body.List, decl, &sub, false); line != 0 {
					return line, false
				}
			}
		case *ast.SelectStmt:
			if s.Body != nil {
				sub := *state
				if line, _ := walkSQLTxStmts(fset, s.Body.List, decl, &sub, inTxLoop); line != 0 {
					return line, false
				}
			}
		case *ast.CaseClause:
			sub := *state
			if line, _ := walkSQLTxStmts(fset, s.Body, decl, &sub, inTxLoop); line != 0 {
				return line, false
			}
		case *ast.CommClause:
			sub := *state
			if line, _ := walkSQLTxStmts(fset, s.Body, decl, &sub, inTxLoop); line != 0 {
				return line, false
			}
		}
	}
	return 0, true
}

func stmtCallsMethodOutsideFuncLit(node ast.Node, recvName, method string) bool {
	if node == nil {
		return false
	}
	switch n := node.(type) {
	case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt, *ast.TypeSwitchStmt, *ast.SelectStmt:
		if ifS, ok := n.(*ast.IfStmt); ok && ifS.Init != nil {
			return stmtCallsMethodOutsideFuncLit(ifS.Init, recvName, method) || stmtCallsMethodOutsideFuncLit(ifS.Cond, recvName, method)
		}
		return false
	}
	found := false
	ast.Inspect(node, func(n ast.Node) bool {
		if found || n == nil {
			return false
		}
		if _, isLit := n.(*ast.FuncLit); isLit {
			return false
		}
		if _, isIf := n.(*ast.IfStmt); isIf && n != node {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if callReceivesMethod(call, recvName, method) {
			found = true
			return false
		}
		return true
	})
	return found
}

func FixSQLTransactionIssue(filePath, content string, line int) (string, string, error) {
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return "", "", err
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return content, "", fmt.Errorf("empty Go source content")
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil || astFile == nil {
		return content, "", err
	}

	candidates := collectSQLTxLeakCandidatesInFile(fset, astFile)
	var chosen *sqlTxLeakCandidate
	for i := range candidates {
		if candidates[i].decl.beginLine == line || candidates[i].decl.assignLine == line {
			chosen = &candidates[i]
			break
		}
	}
	if chosen == nil {
		return content, "", fmt.Errorf("no unclosed SQL transaction at line %d", line)
	}

	title := fmt.Sprintf("Add defer %s.Rollback()", chosen.decl.txVar)
	if chosen.inLoop {
		return content, title, fmt.Errorf("cannot safely add defer %s.Rollback() inside a loop", chosen.decl.txVar)
	}

	ctx, ok := findResourceAssignContext(chosen.scopeBody, chosen.decl.assignStmt)
	if !ok {
		return content, title, fmt.Errorf("could not locate transaction assignment context")
	}

	updated, err := insertDeferredGuardAndCleanup(
		fset,
		content,
		chosen.scopeBody,
		ctx,
		chosen.decl.assignStmt.End(),
		chosen.decl.assignLine,
		chosen.decl.txVar,
		chosen.decl.txVar,
		chosen.decl.errVar,
		chosen.decl.txVar+".Rollback()",
		false,
		"Rollback",
		"",
	)
	return updated, title, err
}
