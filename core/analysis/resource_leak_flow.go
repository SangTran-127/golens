package analysis

import (
	"go/ast"
	"go/token"
)

type resourceFlowResult struct {
	leaked   bool
	leakLine int
	inLoop   bool
	canFix   bool
}

type resourceTargetSpec struct {
	varName       string
	closeTarget   string
	errVar        string
	errVarLive    bool
	aliases       map[string]bool
	cleanupVars   map[string]bool
	wrapperVars   map[string]bool
	inLoop        bool
	isOuterAssign bool
	loopBroke     bool
}

type resourceFlowState struct {
	deferred bool
	closed   bool
	escaped  bool
}

func (s resourceFlowState) safe() bool {
	return s.deferred || s.closed || s.escaped
}

type resourceAssignContext struct {
	block      *ast.BlockStmt
	idx        int
	inLoop     bool
	inIfInit   bool
	ifInitStmt *ast.IfStmt
	outerCont  [][]ast.Stmt
}

func analyzeResourceAcquisitionFlow(fset *token.FileSet, fnBody *ast.BlockStmt, acq resourceAcquisitionMatch) resourceFlowResult {
	ctx, ok := findResourceAssignContext(fnBody, acq.assignStmt)
	if !ok {
		return resourceFlowResult{}
	}
	errVar := extractAssignErrVar(acq.assignStmt)
	outerAssign := acq.assignStmt.Tok == token.ASSIGN && len(ctx.outerCont) > 0 && !blockDeclaresVar(ctx.block, acq.varName)
	spec := resourceTargetSpec{
		varName:       acq.varName,
		closeTarget:   acq.closeTarget,
		errVar:        errVar,
		errVarLive:    errVar != "",
		aliases:       make(map[string]bool),
		cleanupVars:   make(map[string]bool),
		wrapperVars:   make(map[string]bool),
		inLoop:        ctx.inLoop,
		isOuterAssign: outerAssign,
	}
	if ctx.inIfInit {
		return analyzeIfInitResourceFlow(fset, ctx, &spec)
	}

	canFix := !ctx.inLoop && !hasNonBlockElseAfterAssign(fset, ctx.block, ctx.idx, spec.errVar, spec.varName, spec.closeTarget)
	if suppress, disallowFix := analyzeBufferTrailerWriter(fset, fnBody, acq); suppress {
		return resourceFlowResult{}
	} else if disallowFix {
		canFix = false
	}
	stmts := ctx.block.List[ctx.idx+1:]
	curIdx, handled, branchElse, earlyRes := consumeLeadingResourceGuards(fset, stmts, &spec, canFix)
	if handled {
		return earlyRes
	}

	state := resourceFlowState{}
	if branchElse != nil {
		leakLine, fell, st := walkResourceFlowStmt(fset, branchElse, &spec, state)
		if leakLine != 0 {
			return resourceFlowResult{leaked: true, leakLine: leakLine, inLoop: ctx.inLoop, canFix: canFix}
		}
		if !fell && !spec.loopBroke {
			return resourceFlowResult{}
		}
		state = st
	}

	leakLine, fell, state := walkResourceFlowStmts(fset, stmts[curIdx:], &spec, state)
	if leakLine != 0 {
		return resourceFlowResult{leaked: true, leakLine: leakLine, inLoop: ctx.inLoop, canFix: canFix}
	}

	if (fell || spec.loopBroke) && !state.safe() && spec.isOuterAssign {
		spec.inLoop = false
		for _, outer := range ctx.outerCont {
			oIdx, oHandled, oElse, oRes := consumeLeadingResourceGuards(fset, outer, &spec, canFix)
			if oHandled {
				return oRes
			}
			if oElse != nil {
				oLeak, oFell, oSt := walkResourceFlowStmt(fset, oElse, &spec, state)
				if oLeak != 0 {
					return resourceFlowResult{leaked: true, leakLine: oLeak, inLoop: ctx.inLoop, canFix: canFix}
				}
				state = oSt
				if !oFell {
					return resourceFlowResult{}
				}
			}
			oLeak, oFell, oState := walkResourceFlowStmts(fset, outer[oIdx:], &spec, state)
			if oLeak != 0 {
				return resourceFlowResult{leaked: true, leakLine: oLeak, inLoop: ctx.inLoop, canFix: canFix}
			}
			state, fell = oState, oFell
			if !fell || state.safe() {
				return resourceFlowResult{}
			}
		}
	}

	if fell && !state.safe() {
		endLine := fset.Position(ctx.block.Rbrace).Line
		if endLine < acq.line {
			endLine = acq.line
		}
		return resourceFlowResult{leaked: true, leakLine: endLine, inLoop: ctx.inLoop, canFix: canFix}
	}
	return resourceFlowResult{}
}

func consumeLeadingResourceGuards(fset *token.FileSet, stmts []ast.Stmt, spec *resourceTargetSpec, canFix bool) (int, bool, ast.Stmt, resourceFlowResult) {
	curIdx := 0
	var branchElse ast.Stmt
	for curIdx < len(stmts) {
		ifStmt, ok := stmts[curIdx].(*ast.IfStmt)
		if !ok || ifStmt.Init != nil {
			break
		}
		if (spec.errVarLive && isErrNotNilGuardCond(fset, ifStmt.Cond, spec.errVar)) || isResourceNilGuardExpr(fset, ifStmt.Cond, spec.varName, spec.closeTarget) {
			if !ifBlockTerminatesExecution(fset, ifStmt.Body) {
				break
			}
			curIdx++
			if ifStmt.Else != nil {
				branchElse = ifStmt.Else
				break
			}
			continue
		}
		if isResourceSuccessCond(fset, ifStmt.Cond, spec.errVar, spec.varName, spec.closeTarget) && ifStmt.Else == nil {
			leakLine, fell, st := walkResourceFlowStmts(fset, ifStmt.Body.List, spec, resourceFlowState{})
			if leakLine != 0 {
				return curIdx, true, nil, resourceFlowResult{leaked: true, leakLine: leakLine, inLoop: spec.inLoop, canFix: canFix && !spec.inLoop}
			}
			if (!fell && !spec.loopBroke) || st.safe() {
				return curIdx, true, nil, resourceFlowResult{}
			}
			curIdx++
			break
		}
		break
	}
	return curIdx, false, branchElse, resourceFlowResult{}
}

func analyzeIfInitResourceFlow(fset *token.FileSet, ctx resourceAssignContext, spec *resourceTargetSpec) resourceFlowResult {
	if ctx.ifInitStmt == nil {
		return resourceFlowResult{}
	}
	check := func(stmts []ast.Stmt, endLine int) resourceFlowResult {
		leakLine, fell, st := walkResourceFlowStmts(fset, stmts, spec, resourceFlowState{})
		if leakLine != 0 {
			return resourceFlowResult{leaked: true, leakLine: leakLine, inLoop: ctx.inLoop}
		}
		if fell && !st.safe() {
			return resourceFlowResult{leaked: true, leakLine: endLine, inLoop: ctx.inLoop}
		}
		return resourceFlowResult{}
	}
	if isErrNotNilGuardCond(fset, ctx.ifInitStmt.Cond, spec.errVar) {
		if !ifBlockTerminatesExecution(fset, ctx.ifInitStmt.Body) {
			if r := check(ctx.ifInitStmt.Body.List, fset.Position(ctx.ifInitStmt.Body.Rbrace).Line); r.leaked {
				return r
			}
		}
		if ctx.ifInitStmt.Else != nil {
			leakLine, fell, st := walkResourceFlowStmt(fset, ctx.ifInitStmt.Else, spec, resourceFlowState{})
			if leakLine != 0 {
				return resourceFlowResult{leaked: true, leakLine: leakLine, inLoop: ctx.inLoop}
			}
			if fell && !st.safe() {
				return resourceFlowResult{leaked: true, leakLine: fset.Position(ctx.ifInitStmt.End()).Line, inLoop: ctx.inLoop}
			}
		}
		return resourceFlowResult{}
	}
	if isResourceSuccessCond(fset, ctx.ifInitStmt.Cond, spec.errVar, spec.varName, spec.closeTarget) {
		return check(ctx.ifInitStmt.Body.List, fset.Position(ctx.ifInitStmt.Body.Rbrace).Line)
	}
	return resourceFlowResult{}
}

func walkResourceFlowStmts(fset *token.FileSet, stmts []ast.Stmt, spec *resourceTargetSpec, state resourceFlowState) (int, bool, resourceFlowState) {
	cur := state
	for _, stmt := range stmts {
		if cur.safe() {
			return 0, true, cur
		}
		leakLine, fell, next := walkResourceFlowStmt(fset, stmt, spec, cur)
		if leakLine != 0 {
			return leakLine, false, next
		}
		cur = next
		if !fell {
			return 0, false, cur
		}
	}
	return 0, true, cur
}

func walkResourceFlowStmt(fset *token.FileSet, stmt ast.Stmt, spec *resourceTargetSpec, cur resourceFlowState) (int, bool, resourceFlowState) {
	if stmt == nil {
		return 0, true, cur
	}
	if def, ok := stmt.(*ast.DeferStmt); ok {
		if deferGuardsResourceTarget(fset, def, spec) {
			cur.deferred = true
		}
		return 0, true, cur
	}
	if gs, ok := stmt.(*ast.GoStmt); ok {
		if goroutineHandlesResource(fset, gs, spec) {
			cur.escaped = true
		}
		return 0, true, cur
	}

	recordResourceCleanupOrEscape(fset, stmt, spec, &cur)

	switch s := stmt.(type) {
	case *ast.ReturnStmt:
		if !cur.safe() {
			return fset.Position(s.Pos()).Line, false, cur
		}
		return 0, false, cur
	case *ast.BranchStmt:
		if s.Tok == token.BREAK && spec.inLoop && spec.isOuterAssign {
			spec.loopBroke = true
			return 0, false, cur
		}
		if spec.inLoop && (s.Tok == token.CONTINUE || s.Tok == token.BREAK) && !cur.safe() {
			return fset.Position(s.Pos()).Line, false, cur
		}
		return 0, false, cur
	case *ast.BlockStmt:
		return walkResourceFlowStmts(fset, s.List, spec, cur)
	case *ast.IfStmt:
		if s.Init != nil {
			recordResourceCleanupOrEscape(fset, s.Init, spec, &cur)
		}
		bodyInit, elseInit := cur, cur
		if s.Init == nil {
			if isResourceNilGuardExpr(fset, s.Cond, spec.varName, spec.closeTarget) || (spec.errVarLive && isErrNotNilGuardCond(fset, s.Cond, spec.errVar)) {
				bodyInit.escaped = true
			}
			if isResourceSuccessCond(fset, s.Cond, "-", spec.varName, spec.closeTarget) || (spec.errVarLive && isResourceSuccessCond(fset, s.Cond, spec.errVar, spec.varName, spec.closeTarget)) {
				elseInit.escaped = true
			}
		}
		leak1, fall1, st1 := walkResourceFlowStmts(fset, s.Body.List, spec, bodyInit)
		if leak1 != 0 {
			return leak1, false, st1
		}
		fall2, st2 := true, elseInit
		if s.Else != nil {
			var leak2 int
			leak2, fall2, st2 = walkResourceFlowStmt(fset, s.Else, spec, elseInit)
			if leak2 != 0 {
				return leak2, false, st2
			}
		}
		if fall1 && !fall2 {
			return 0, true, st1
		}
		if !fall1 && fall2 {
			return 0, true, st2
		}
		if fall1 && fall2 {
			return 0, true, resourceFlowState{deferred: st1.deferred && st2.deferred, closed: st1.safe() && st2.safe(), escaped: st1.escaped && st2.escaped}
		}
		return 0, false, cur
	case *ast.SwitchStmt:
		if s.Init != nil {
			recordResourceCleanupOrEscape(fset, s.Init, spec, &cur)
		}
		return walkResourceClauseBlock(fset, s.Body, spec, cur, false)
	case *ast.TypeSwitchStmt:
		if s.Init != nil {
			recordResourceCleanupOrEscape(fset, s.Init, spec, &cur)
		}
		return walkResourceClauseBlock(fset, s.Body, spec, cur, false)
	case *ast.SelectStmt:
		return walkResourceClauseBlock(fset, s.Body, spec, cur, true)
	case *ast.ForStmt:
		if s.Init != nil {
			recordResourceCleanupOrEscape(fset, s.Init, spec, &cur)
		}
		if s.Cond == nil && forLoopActsAsAcceptDaemon(fset, s.Body, spec) {
			cur.escaped = true
			return 0, true, cur
		}
		return walkLoopStatementBody(fset, s.Body, spec, cur)
	case *ast.RangeStmt:
		return walkLoopStatementBody(fset, s.Body, spec, cur)
	case *ast.LabeledStmt:
		return walkResourceFlowStmt(fset, s.Stmt, spec, cur)
	}

	if stmtReassignsResourceVar(stmt, spec.varName) && !cur.safe() {
		return fset.Position(stmt.Pos()).Line, false, cur
	}
	return 0, true, cur
}

func walkLoopStatementBody(fset *token.FileSet, body *ast.BlockStmt, spec *resourceTargetSpec, cur resourceFlowState) (int, bool, resourceFlowState) {
	if body != nil {
		inner := *spec
		inner.inLoop = false
		if leakLine, _, _ := walkResourceFlowStmts(fset, body.List, &inner, cur); leakLine != 0 {
			return leakLine, false, cur
		}
	}
	return 0, true, cur
}

func walkResourceClauseBlock(fset *token.FileSet, body *ast.BlockStmt, spec *resourceTargetSpec, cur resourceFlowState, isSelect bool) (int, bool, resourceFlowState) {
	if body == nil {
		return 0, true, cur
	}
	hasDefault, anyFall, allFallSafe := isSelect, false, true
	for _, raw := range body.List {
		var stmts []ast.Stmt
		switch c := raw.(type) {
		case *ast.CaseClause:
			stmts = c.Body
			if len(c.List) == 0 {
				hasDefault = true
			}
		case *ast.CommClause:
			stmts = c.Body
		default:
			continue
		}
		leakLine, fell, out := walkResourceFlowStmts(fset, stmts, spec, cur)
		if leakLine != 0 {
			return leakLine, false, out
		}
		if fell {
			anyFall = true
			if !out.safe() {
				allFallSafe = false
			}
		}
	}
	if !hasDefault {
		anyFall = true
		if !cur.safe() {
			allFallSafe = false
		}
	}
	if anyFall && allFallSafe {
		return 0, true, resourceFlowState{closed: true}
	}
	return 0, anyFall, cur
}

func recordResourceCleanupOrEscape(fset *token.FileSet, stmt ast.Stmt, spec *resourceTargetSpec, cur *resourceFlowState) {
	if stmt == nil {
		return
	}
	if assign, ok := stmt.(*ast.AssignStmt); ok {
		if spec.errVar != "" && stmtAssignsIdent(assign, spec.errVar) {
			spec.errVarLive = false
		}
		for i, lhs := range assign.Lhs {
			var rhs ast.Expr
			if i < len(assign.Rhs) {
				rhs = assign.Rhs[i]
			} else if len(assign.Rhs) == 1 {
				rhs = assign.Rhs[0]
			}
			if rhs == nil {
				continue
			}
			if matchesResourceTargetExpr(fset, rhs, spec) {
				switch l := unwrapSafetyParens(lhs).(type) {
				case *ast.Ident:
					if l.Name != "" && l.Name != "_" && l.Name != spec.varName {
						spec.aliases[l.Name] = true
					}
				case *ast.SelectorExpr, *ast.IndexExpr, *ast.StarExpr:
					cur.escaped = true
				}
			}
			if exprEscapesTargetValue(fset, rhs, spec) {
				switch lhs.(type) {
				case *ast.SelectorExpr, *ast.IndexExpr, *ast.StarExpr:
					cur.escaped = true
				}
			}
			if call, ok := unwrapSafetyParens(rhs).(*ast.CallExpr); ok && argsContainTargetExpr(fset, call.Args, spec) && !isNonOwningWrapperCall(fset, call) {
				if id, ok := unwrapSafetyParens(lhs).(*ast.Ident); ok && id.Name != "" && id.Name != "_" {
					spec.wrapperVars[id.Name] = true
				}
			}
			if lit, ok := unwrapSafetyParens(rhs).(*ast.FuncLit); ok && lit.Body != nil && funcLitClosesResource(fset, lit.Body, spec, nil) {
				if id, ok := unwrapSafetyParens(lhs).(*ast.Ident); ok && id.Name != "" && id.Name != "_" {
					spec.cleanupVars[id.Name] = true
				}
			}
		}
	}
	if send, ok := stmt.(*ast.SendStmt); ok {
		if matchesResourceTargetExpr(fset, send.Value, spec) || exprEscapesTargetValue(fset, send.Value, spec) {
			cur.escaped = true
		}
	}
	if ret, ok := stmt.(*ast.ReturnStmt); ok {
		for _, res := range ret.Results {
			if matchesResourceTargetExpr(fset, res, spec) || exprEscapesTargetValue(fset, res, spec) || exprReferencesCleanupVar(res, spec.cleanupVars) || exprReferencesCleanupVar(res, spec.wrapperVars) {
				cur.escaped = true
			}
			if isResourceReturningTransferCall(fset, res, spec) {
				cur.escaped = true
			}
			if lit, ok := unwrapSafetyParens(res).(*ast.FuncLit); ok && lit.Body != nil && funcLitClosesResource(fset, lit.Body, spec, nil) {
				cur.escaped = true
			}
		}
	}
	inspectStmtResourceEffects(fset, stmt, spec, cur)
}
