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
	"sort"
	"strings"
)

type SocketSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type SocketSafetyIssue struct {
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

type SocketSafetyInspectResult struct {
	Issues                                []SocketSafetyIssue `json:"issues"`
	NetDialWithoutTimeoutCount            int                 `json:"netDialWithoutTimeoutCount"`
	ConnReadWriteWithoutDeadlineCount     int                 `json:"connReadWriteWithoutDeadlineCount"`
	ListenerAcceptLoopWithoutBackoffCount int                 `json:"listenerAcceptLoopWithoutBackoffCount"`
	Error                                 string              `json:"error,omitempty"`
}

type SocketSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type SocketSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

type socketEditCandidate struct {
	issue        SocketSafetyIssue
	startOffset  int
	endOffset    int
	replacement  string
	needsTimeImp bool
}

func InspectSocketSafety(payloadJSON string) string {
	var req SocketSafetyInspectRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		return marshalSocketInspectError("invalid payload: " + err.Error())
	}

	candidates, err := collectSocketSafetyCandidates(req.Content, req.FilePath)
	if err != nil {
		return marshalSocketInspectError(err.Error())
	}

	res := SocketSafetyInspectResult{
		Issues: make([]SocketSafetyIssue, 0, len(candidates)),
	}
	for _, c := range candidates {
		res.Issues = append(res.Issues, c.issue)
		switch c.issue.Category {
		case "net_dial_without_timeout":
			res.NetDialWithoutTimeoutCount++
		case "conn_read_write_without_deadline":
			res.ConnReadWriteWithoutDeadlineCount++
		case "listener_accept_loop_without_backoff_or_close":
			res.ListenerAcceptLoopWithoutBackoffCount++
		}
	}

	out, _ := json.Marshal(res)
	return string(out)
}

func ApplySocketSafetyFixes(payloadJSON string) string {
	var req SocketSafetyFixRequest
	if err := json.Unmarshal([]byte(payloadJSON), &req); err != nil {
		return marshalSocketFixError("invalid payload: " + err.Error())
	}

	if req.All {
		current := req.Content
		totalFixed := 0
		needsTime := false
		for pass := 0; pass < 32; pass++ {
			candidates, err := collectSocketSafetyCandidates(current, req.FilePath)
			if err != nil {
				if totalFixed > 0 {
					break
				}
				return marshalSocketFixError(err.Error())
			}
			applied := false
			for _, c := range candidates {
				if !c.issue.CanAutoFix {
					continue
				}
				if c.startOffset < 0 || c.endOffset < c.startOffset || c.endOffset > len(current) {
					continue
				}
				current = current[:c.startOffset] + c.replacement + current[c.endOffset:]
				if c.needsTimeImp {
					needsTime = true
				}
				totalFixed++
				applied = true
				break
			}
			if !applied {
				break
			}
		}
		if needsTime {
			current = ensureSocketImportPath(current, "time")
		}
		formatted, fmtErr := format.Source([]byte(current))
		if fmtErr == nil {
			current = string(formatted)
		}
		out, _ := json.Marshal(SocketSafetyFixResult{
			NewContent: current,
			FixedCount: totalFixed,
		})
		return string(out)
	}

	candidates, err := collectSocketSafetyCandidates(req.Content, req.FilePath)
	if err != nil {
		return marshalSocketFixError(err.Error())
	}

	var selected []socketEditCandidate
	for _, c := range candidates {
		if !c.issue.CanAutoFix {
			continue
		}
		if c.issue.ID == req.IssueID {
			selected = append(selected, c)
			break
		}
	}

	if len(selected) == 0 {
		out, _ := json.Marshal(SocketSafetyFixResult{
			NewContent: req.Content,
			FixedCount: 0,
		})
		return string(out)
	}

	sort.Slice(selected, func(i, j int) bool {
		return selected[i].startOffset > selected[j].startOffset
	})

	updated := req.Content
	fixedCount := 0
	needsTime := false
	for _, c := range selected {
		if c.startOffset < 0 || c.endOffset < c.startOffset || c.endOffset > len(updated) {
			continue
		}
		updated = updated[:c.startOffset] + c.replacement + updated[c.endOffset:]
		if c.needsTimeImp {
			needsTime = true
		}
		fixedCount++
	}

	if needsTime {
		updated = ensureSocketImportPath(updated, "time")
	}

	formatted, fmtErr := format.Source([]byte(updated))
	if fmtErr == nil {
		updated = string(formatted)
	}

	out, _ := json.Marshal(SocketSafetyFixResult{
		NewContent: updated,
		FixedCount: fixedCount,
	})
	return string(out)
}

func collectSocketSafetyCandidates(content, filePath string) ([]socketEditCandidate, error) {
	if strings.TrimSpace(content) == "" {
		return nil, nil
	}
	filename := filePath
	if filename == "" {
		filename = "socket_inspect.go"
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, content, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("parse error: %w", err)
	}

	netAlias := "net"
	timeAlias := "time"
	hasTimeImport := false
	for _, imp := range file.Imports {
		pathVal := strings.Trim(imp.Path.Value, `"`)
		switch pathVal {
		case "net":
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				netAlias = imp.Name.Name
			}
		case "time":
			hasTimeImport = true
			if imp.Name != nil && imp.Name.Name != "_" && imp.Name.Name != "." {
				timeAlias = imp.Name.Name
			}
		}
	}

	var candidates []socketEditCandidate

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		funcName := fn.Name.Name
		connVars := collectFuncNetConnVars(fn, netAlias)
		connHasDeadline := collectConnVarsWithDeadline(fn.Body)
		flaggedConnDeadline := make(map[string]bool)

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkgIdent, ok := sel.X.(*ast.Ident)
			if !ok || pkgIdent.Name != netAlias || sel.Sel.Name != "Dial" || len(call.Args) != 2 {
				return true
			}
			pos := fset.Position(call.Pos())
			startOff := fset.Position(call.Pos()).Offset
			endOff := fset.Position(call.End()).Offset
			exprStr := renderSocketNode(fset, call)
			netwStr := renderSocketNode(fset, call.Args[0])
			addrStr := renderSocketNode(fset, call.Args[1])
			repl := fmt.Sprintf("%s.DialTimeout(%s, %s, 10*%s.Second)", netAlias, netwStr, addrStr, timeAlias)

			candidates = append(candidates, socketEditCandidate{
				issue: SocketSafetyIssue{
					ID:                 fmt.Sprintf("net_dial_without_timeout:%d:%d", pos.Line, pos.Column),
					Category:           "net_dial_without_timeout",
					Severity:           "warning",
					Line:               pos.Line,
					Column:             pos.Column,
					FuncName:           funcName,
					Expr:               exprStr,
					Message:            fmt.Sprintf("%s.Dial has no connection timeout and can block indefinitely if the remote host drops SYN packets", netAlias),
					Suggestion:         fmt.Sprintf("Replace %s.Dial with %s.DialTimeout(..., 10*%s.Second) or net.Dialer.DialContext", netAlias, netAlias, timeAlias),
					FixTitle:           "Use net.DialTimeout with 10s Timeout",
					ReplacementPreview: repl,
					CanAutoFix:         true,
				},
				startOffset:  startOff,
				endOffset:    endOff,
				replacement:  repl,
				needsTimeImp: !hasTimeImport,
			})
			return true
		})

		inspectSocketStatements(fn.Body.List, func(stmt ast.Stmt) {
			ast.Inspect(stmt, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				if sel.Sel.Name != "Read" && sel.Sel.Name != "Write" {
					return true
				}
				recvIdent, ok := sel.X.(*ast.Ident)
				if !ok {
					return true
				}
				connName := recvIdent.Name
				if !connVars[connName] || connHasDeadline[connName] || flaggedConnDeadline[connName] {
					return true
				}
				flaggedConnDeadline[connName] = true
				pos := fset.Position(stmt.Pos())
				stmtStart := pos.Offset
				indent := socketLineIndentAt(content, stmtStart)
				deadlineStmt := fmt.Sprintf("_ = %s.SetDeadline(%s.Now().Add(30 * %s.Second))", connName, timeAlias, timeAlias)
				repl := deadlineStmt + "\n" + indent

				candidates = append(candidates, socketEditCandidate{
					issue: SocketSafetyIssue{
						ID:                 fmt.Sprintf("conn_read_write_without_deadline:%d:%d", pos.Line, pos.Column),
						Category:           "conn_read_write_without_deadline",
						Severity:           "warning",
						Line:               pos.Line,
						Column:             pos.Column,
						FuncName:           funcName,
						Expr:               renderSocketNode(fset, call),
						Message:            fmt.Sprintf("Socket %s.%s is called without setting a read/write deadline, risking goroutine leaks on half-open connections", connName, sel.Sel.Name),
						Suggestion:         fmt.Sprintf("Call %s.SetDeadline(%s.Now().Add(30 * %s.Second)) before performing socket I/O", connName, timeAlias, timeAlias),
						FixTitle:           "Insert SetDeadline(30s) Before I/O",
						ReplacementPreview: deadlineStmt,
						CanAutoFix:         true,
					},
					startOffset:  stmtStart,
					endOffset:    stmtStart,
					replacement:  repl,
					needsTimeImp: !hasTimeImport,
				})
				return false
			})
		})

		ast.Inspect(fn.Body, func(n ast.Node) bool {
			forStmt, ok := n.(*ast.ForStmt)
			if !ok || forStmt.Body == nil {
				return true
			}
			checkListenerAcceptLoop(fset, content, forStmt.Body, funcName, timeAlias, hasTimeImport, &candidates)
			return true
		})
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].issue.Line != candidates[j].issue.Line {
			return candidates[i].issue.Line < candidates[j].issue.Line
		}
		return candidates[i].issue.Column < candidates[j].issue.Column
	})

	return candidates, nil
}

func checkListenerAcceptLoop(
	fset *token.FileSet,
	content string,
	body *ast.BlockStmt,
	funcName string,
	timeAlias string,
	hasTimeImport bool,
	candidates *[]socketEditCandidate,
) {
	acceptErrVars := make(map[string]bool)
	for _, stmt := range body.List {
		if assign, ok := stmt.(*ast.AssignStmt); ok && len(assign.Rhs) == 1 && len(assign.Lhs) == 2 {
			if call, ok := assign.Rhs[0].(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Accept" && len(call.Args) == 0 {
					if errIdent, ok := assign.Lhs[1].(*ast.Ident); ok && errIdent.Name != "_" {
						acceptErrVars[errIdent.Name] = true
					}
				}
			}
		}
		ifStmt, ok := stmt.(*ast.IfStmt)
		if !ok || ifStmt.Body == nil {
			continue
		}
		errVar := extractErrNotNilIdent(ifStmt.Cond)
		if errVar == "" || !acceptErrVars[errVar] {
			continue
		}
		var contStmt *ast.BranchStmt
		hasBackoffOrExit := false
		for _, inner := range ifStmt.Body.List {
			if br, ok := inner.(*ast.BranchStmt); ok {
				if br.Tok == token.CONTINUE {
					contStmt = br
				} else if br.Tok == token.BREAK {
					hasBackoffOrExit = true
				}
			}
			if _, ok := inner.(*ast.ReturnStmt); ok {
				hasBackoffOrExit = true
			}
			ast.Inspect(inner, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					switch sel.Sel.Name {
					case "Sleep", "After", "Close", "Fatal", "Fatalf":
						hasBackoffOrExit = true
					}
				}
				return true
			})
		}
		if contStmt != nil && !hasBackoffOrExit {
			pos := fset.Position(contStmt.Pos())
			contStart := pos.Offset
			indent := socketLineIndentAt(content, contStart)
			sleepStmt := fmt.Sprintf("%s.Sleep(50 * %s.Millisecond)", timeAlias, timeAlias)
			repl := sleepStmt + "\n" + indent

			*candidates = append(*candidates, socketEditCandidate{
				issue: SocketSafetyIssue{
					ID:                 fmt.Sprintf("listener_accept_loop_without_backoff_or_close:%d:%d", pos.Line, pos.Column),
					Category:           "listener_accept_loop_without_backoff_or_close",
					Severity:           "warning",
					Line:               pos.Line,
					Column:             pos.Column,
					FuncName:           funcName,
					Expr:               "continue",
					Message:            "Listener Accept() error branch continues immediately without backoff or exit, risking a 100% CPU spin on EMFILE",
					Suggestion:         fmt.Sprintf("Add a brief backoff (%s.Sleep(50 * %s.Millisecond)) before continuing the Accept loop", timeAlias, timeAlias),
					FixTitle:           "Insert 50ms Backoff Before continue",
					ReplacementPreview: sleepStmt,
					CanAutoFix:         true,
				},
				startOffset:  contStart,
				endOffset:    contStart,
				replacement:  repl,
				needsTimeImp: !hasTimeImport,
			})
		}
	}
}

func extractErrNotNilIdent(cond ast.Expr) string {
	bin, ok := cond.(*ast.BinaryExpr)
	if !ok || bin.Op != token.NEQ {
		return ""
	}
	if ident, ok := bin.X.(*ast.Ident); ok {
		if nilIdent, ok := bin.Y.(*ast.Ident); ok && nilIdent.Name == "nil" {
			return ident.Name
		}
	}
	if ident, ok := bin.Y.(*ast.Ident); ok {
		if nilIdent, ok := bin.X.(*ast.Ident); ok && nilIdent.Name == "nil" {
			return ident.Name
		}
	}
	return ""
}

func collectFuncNetConnVars(fn *ast.FuncDecl, netAlias string) map[string]bool {
	res := make(map[string]bool)
	if fn.Type != nil && fn.Type.Params != nil {
		for _, field := range fn.Type.Params.List {
			if isNetConnTypeExpr(field.Type, netAlias) {
				for _, name := range field.Names {
					res[name.Name] = true
				}
			}
		}
	}
	if fn.Body == nil {
		return res
	}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		switch s := n.(type) {
		case *ast.AssignStmt:
			if len(s.Rhs) == 1 && len(s.Lhs) >= 1 {
				if isNetConnCallExpr(s.Rhs[0], netAlias) {
					if ident, ok := s.Lhs[0].(*ast.Ident); ok && ident.Name != "_" {
						res[ident.Name] = true
					}
				}
			}
		case *ast.ValueSpec:
			if isNetConnTypeExpr(s.Type, netAlias) {
				for _, name := range s.Names {
					if name.Name != "_" {
						res[name.Name] = true
					}
				}
			}
			if len(s.Values) == 1 && len(s.Names) >= 1 && isNetConnCallExpr(s.Values[0], netAlias) {
				if s.Names[0].Name != "_" {
					res[s.Names[0].Name] = true
				}
			}
		}
		return true
	})
	return res
}

func isNetConnTypeExpr(expr ast.Expr, netAlias string) bool {
	if expr == nil {
		return false
	}
	if star, ok := expr.(*ast.StarExpr); ok {
		expr = star.X
	}
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != netAlias {
		return false
	}
	switch sel.Sel.Name {
	case "Conn", "TCPConn", "UDPConn", "IPConn", "UnixConn":
		return true
	}
	return false
}

func isNetConnCallExpr(expr ast.Expr, netAlias string) bool {
	call, ok := expr.(*ast.CallExpr)
	if !ok {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	if pkgIdent, ok := sel.X.(*ast.Ident); ok && pkgIdent.Name == netAlias {
		switch sel.Sel.Name {
		case "Dial", "DialTimeout", "DialTCP", "DialUDP", "DialIP", "DialUnix":
			return true
		}
	}
	if sel.Sel.Name == "Accept" || sel.Sel.Name == "AcceptTCP" || sel.Sel.Name == "AcceptUnix" || sel.Sel.Name == "DialContext" {
		return true
	}
	return false
}

func collectConnVarsWithDeadline(body *ast.BlockStmt) map[string]bool {
	res := make(map[string]bool)
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		switch sel.Sel.Name {
		case "SetDeadline", "SetReadDeadline", "SetWriteDeadline":
			if ident, ok := sel.X.(*ast.Ident); ok {
				res[ident.Name] = true
			}
		}
		return true
	})
	return res
}

func inspectSocketStatements(stmts []ast.Stmt, visit func(ast.Stmt)) {
	for _, stmt := range stmts {
		visit(stmt)
		switch s := stmt.(type) {
		case *ast.BlockStmt:
			inspectSocketStatements(s.List, visit)
		case *ast.IfStmt:
			if s.Body != nil {
				inspectSocketStatements(s.Body.List, visit)
			}
			if blk, ok := s.Else.(*ast.BlockStmt); ok {
				inspectSocketStatements(blk.List, visit)
			}
		case *ast.ForStmt:
			if s.Body != nil {
				inspectSocketStatements(s.Body.List, visit)
			}
		case *ast.RangeStmt:
			if s.Body != nil {
				inspectSocketStatements(s.Body.List, visit)
			}
		case *ast.SwitchStmt:
			if s.Body != nil {
				for _, cc := range s.Body.List {
					if clause, ok := cc.(*ast.CaseClause); ok {
						inspectSocketStatements(clause.Body, visit)
					}
				}
			}
		}
	}
}

func socketLineIndentAt(content string, offset int) string {
	lineStart := offset
	for lineStart > 0 && content[lineStart-1] != '\n' {
		lineStart--
	}
	var indent strings.Builder
	for i := lineStart; i < len(content); i++ {
		if content[i] == ' ' || content[i] == '\t' {
			indent.WriteByte(content[i])
		} else {
			break
		}
	}
	return indent.String()
}

func ensureSocketImportPath(src string, pkgPath string) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "socket.go", src, parser.ParseComments)
	if err != nil {
		return src
	}
	for _, imp := range file.Imports {
		if strings.Trim(imp.Path.Value, `"`) == pkgPath {
			return src
		}
	}
	lines := strings.Split(src, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "import (") {
			lines[i] = line + "\n\t\"" + pkgPath + "\""
			return strings.Join(lines, "\n")
		}
		if strings.HasPrefix(trimmed, "import ") && !strings.Contains(trimmed, "(") {
			lines[i] = line + "\nimport \"" + pkgPath + "\""
			return strings.Join(lines, "\n")
		}
	}
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "package ") {
			lines[i] = line + "\n\nimport \"" + pkgPath + "\""
			return strings.Join(lines, "\n")
		}
	}
	return src
}

func renderSocketNode(fset *token.FileSet, n ast.Node) string {
	var buf bytes.Buffer
	_ = printer.Fprint(&buf, fset, n)
	return buf.String()
}

func marshalSocketInspectError(msg string) string {
	out, _ := json.Marshal(SocketSafetyInspectResult{
		Issues: []SocketSafetyIssue{},
		Error:  msg,
	})
	return string(out)
}

func marshalSocketFixError(msg string) string {
	out, _ := json.Marshal(SocketSafetyFixResult{
		Error: msg,
	})
	return string(out)
}
