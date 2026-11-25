package testutil

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type CaretTarget struct {
	Found       bool     `json:"found"`
	Test        string   `json:"test,omitempty"`
	Subtests    []string `json:"subtests,omitempty"`
	SubtestPath string   `json:"subtestPath,omitempty"`
	Line        int      `json:"line,omitempty"`
	EndLine     int      `json:"endLine,omitempty"`
	Pattern     string   `json:"pattern,omitempty"`
}

type caretSpan struct {
	testName string
	subtests []string
	line     int
	endLine  int
	pattern  string
}

type subtestCollector struct {
	fset     *token.FileSet
	testName string
	rows     []TableRow
	spans    []caretSpan
}

func collectFunctionSubtests(fset *token.FileSet, testName string, fn *ast.FuncDecl, prefix []string) ([]TableRow, []caretSpan) {
	if fn == nil || fn.Body == nil {
		return nil, nil
	}
	c := &subtestCollector{
		fset:     fset,
		testName: testName,
	}
	c.walkBlock(fn.Body, map[string]*table{}, map[string]ast.Expr{}, prefix, true, nil, 0)
	return c.rows, c.spans
}

func TableRows(fset *token.FileSet, fn *ast.FuncDecl) []TableRow {
	if fn == nil || fn.Body == nil {
		return nil
	}
	rows, _ := collectFunctionSubtests(fset, fn.Name.Name, fn, nil)
	return rows
}

func (c *subtestCollector) walkBlock(
	block *ast.BlockStmt,
	outerTables map[string]*table,
	outerEnv map[string]ast.Expr,
	prefix []string,
	emitRows bool,
	loopAlts [][]string,
	depth int,
) {
	if block == nil || depth > 12 {
		return
	}
	tables := cloneTables(outerTables)
	env := cloneEnv(outerEnv)
	for _, stmt := range block.List {
		c.walkStmt(stmt, tables, env, prefix, emitRows, loopAlts, depth)
	}
}

func (c *subtestCollector) walkStmt(
	stmt ast.Stmt,
	tables map[string]*table,
	env map[string]ast.Expr,
	prefix []string,
	emitRows bool,
	loopAlts [][]string,
	depth int,
) {
	if stmt == nil || depth > 12 {
		return
	}
	switch s := stmt.(type) {
	case *ast.BlockStmt:
		c.walkBlock(s, tables, env, prefix, emitRows, loopAlts, depth+1)
	case *ast.AssignStmt:
		for i, rhs := range s.Rhs {
			c.walkExpr(rhs, tables, env, prefix, emitRows, loopAlts, depth)
			if i < len(s.Lhs) {
				if id, ok := s.Lhs[i].(*ast.Ident); ok && id.Name != "_" {
					if t := tableOf(rhs); t != nil {
						tables[id.Name] = t
					} else {
						env[id.Name] = rhs
					}
				}
			}
		}
	case *ast.DeclStmt:
		if gd, ok := s.Decl.(*ast.GenDecl); ok {
			for _, spec := range gd.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, v := range vs.Values {
					c.walkExpr(v, tables, env, prefix, emitRows, loopAlts, depth)
					if i < len(vs.Names) && vs.Names[i].Name != "_" {
						if t := tableOf(v); t != nil {
							tables[vs.Names[i].Name] = t
						} else {
							env[vs.Names[i].Name] = v
						}
					}
				}
			}
		}
	case *ast.ExprStmt:
		c.walkExpr(s.X, tables, env, prefix, emitRows, loopAlts, depth)
	case *ast.GoStmt:
		if s.Call != nil {
			c.walkExpr(s.Call, tables, env, prefix, emitRows, loopAlts, depth)
		}
	case *ast.DeferStmt:
		if s.Call != nil {
			c.walkExpr(s.Call, tables, env, prefix, emitRows, loopAlts, depth)
		}
	case *ast.IfStmt:
		subTables := cloneTables(tables)
		subEnv := cloneEnv(env)
		if s.Init != nil {
			c.walkStmt(s.Init, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		if s.Cond != nil {
			c.walkExpr(s.Cond, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		c.walkBlock(s.Body, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		if s.Else != nil {
			c.walkStmt(s.Else, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
	case *ast.ForStmt:
		subTables := cloneTables(tables)
		subEnv := cloneEnv(env)
		if s.Init != nil {
			c.walkStmt(s.Init, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		if s.Cond != nil {
			c.walkExpr(s.Cond, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		c.walkBlock(s.Body, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		if s.Post != nil {
			c.walkStmt(s.Post, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
	case *ast.SwitchStmt:
		subTables := cloneTables(tables)
		subEnv := cloneEnv(env)
		if s.Init != nil {
			c.walkStmt(s.Init, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		c.walkBlock(s.Body, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
	case *ast.TypeSwitchStmt:
		subTables := cloneTables(tables)
		subEnv := cloneEnv(env)
		if s.Init != nil {
			c.walkStmt(s.Init, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
		}
		c.walkBlock(s.Body, subTables, subEnv, prefix, emitRows, loopAlts, depth+1)
	case *ast.SelectStmt:
		c.walkBlock(s.Body, tables, env, prefix, emitRows, loopAlts, depth+1)
	case *ast.CaseClause:
		for _, bodyStmt := range s.Body {
			c.walkStmt(bodyStmt, tables, env, prefix, emitRows, loopAlts, depth+1)
		}
	case *ast.CommClause:
		for _, bodyStmt := range s.Body {
			c.walkStmt(bodyStmt, tables, env, prefix, emitRows, loopAlts, depth+1)
		}
	case *ast.LabeledStmt:
		c.walkStmt(s.Stmt, tables, env, prefix, emitRows, loopAlts, depth)
	case *ast.RangeStmt:
		var t *table
		if id, ok := s.X.(*ast.Ident); ok {
			t = tables[id.Name]
		} else {
			t = tableOf(s.X)
		}
		if t == nil {
			c.walkBlock(s.Body, tables, env, prefix, emitRows, loopAlts, depth+1)
			return
		}
		runCalls := directRunCalls(s.Body)
		if len(runCalls) == 0 {
			c.walkBlock(s.Body, tables, env, prefix, emitRows, loopAlts, depth+1)
			return
		}
		keyVar, valVar := identName(s.Key), identName(s.Value)
		limit := min(len(t.elems), maxRowsPerTest)
		callNames := make([][]string, len(runCalls))
		callBodies := make([]*ast.BlockStmt, len(runCalls))
		for _, el := range t.elems[:limit] {
			rowBindings := rowEnv(el, t, keyVar, valVar)
			if !t.keyed && valVar != "" && rowBindings[valVar] == nil {
				rowBindings[valVar] = el
			}
			rEnv := mergeEnv(env, rowBindings)
			elStart := c.fset.Position(el.Pos()).Line
			elEnd := c.fset.Position(el.End()).Line
			for rcIdx, rc := range runCalls {
				name, ok := evalString(rc.Args[0], rEnv)
				if !ok {
					continue
				}
				callNames[rcIdx] = append(callNames[rcIdx], name)
				segs := append(append([]string(nil), prefix...), name)
				fullName := strings.Join(segs, "/")
				if emitRows && len(c.rows) < maxRowsPerTest {
					c.rows = append(c.rows, TableRow{
						Name:    fullName,
						ID:      rowID(fullName),
						Line:    elStart,
						EndLine: elEnd,
					})
				}
				if len(loopAlts) == 0 {
					c.spans = append(c.spans, caretSpan{
						testName: c.testName,
						subtests: segs,
						line:     elStart,
						endLine:  elEnd,
						pattern:  RunPattern(c.testName, segs...),
					})
				}
				if fl, ok := rc.Args[1].(*ast.FuncLit); ok && fl.Body != nil {
					if callBodies[rcIdx] == nil {
						callBodies[rcIdx] = fl.Body
					}
					if emitRows && depth < 12 {
						c.walkBlockWithSpans(fl.Body, tables, rEnv, segs, true, false, nil, depth+1)
					}
				}
			}
		}
		if depth < 12 {
			for rcIdx, body := range callBodies {
				namesForCall := callNames[rcIdx]
				if body == nil || len(namesForCall) == 0 {
					continue
				}
				if len(namesForCall) == 1 && len(loopAlts) == 0 {
					segs := append(append([]string(nil), prefix...), namesForCall[0])
					c.walkBlockWithSpans(body, tables, env, segs, false, true, nil, depth+1)
				} else {
					nextAlts := append(append([][]string(nil), loopAlts...), namesForCall)
					c.walkBlockWithSpans(body, tables, env, prefix, false, true, nextAlts, depth+1)
				}
			}
		}
	}
}

func (c *subtestCollector) walkBlockWithSpans(
	block *ast.BlockStmt,
	outerTables map[string]*table,
	outerEnv map[string]ast.Expr,
	prefix []string,
	emitRows bool,
	emitSpans bool,
	loopAlts [][]string,
	depth int,
) {
	if block == nil || depth > 12 {
		return
	}
	if emitRows && emitSpans {
		c.walkBlock(block, outerTables, outerEnv, prefix, true, loopAlts, depth)
		return
	}
	tmp := &subtestCollector{
		fset:     c.fset,
		testName: c.testName,
	}
	tmp.walkBlock(block, outerTables, outerEnv, prefix, emitRows, loopAlts, depth)
	if emitRows {
		for _, r := range tmp.rows {
			if len(c.rows) >= maxRowsPerTest {
				break
			}
			c.rows = append(c.rows, r)
		}
	}
	if emitSpans {
		c.spans = append(c.spans, tmp.spans...)
	}
}

func (c *subtestCollector) walkExpr(
	expr ast.Expr,
	tables map[string]*table,
	env map[string]ast.Expr,
	prefix []string,
	emitRows bool,
	loopAlts [][]string,
	depth int,
) {
	if expr == nil || depth > 12 {
		return
	}
	ast.Inspect(expr, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if fl, ok := n.(*ast.FuncLit); ok && n != expr {
			if fl.Body != nil {
				c.walkBlock(fl.Body, tables, env, prefix, emitRows, loopAlts, depth+1)
			}
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if isSubtestRunCall(call) {
			if name, ok := evalString(call.Args[0], env); ok {
				callStart := c.fset.Position(call.Pos()).Line
				callEnd := c.fset.Position(call.End()).Line
				if len(loopAlts) == 0 {
					segs := append(append([]string(nil), prefix...), name)
					fullName := strings.Join(segs, "/")
					if emitRows && len(c.rows) < maxRowsPerTest {
						c.rows = append(c.rows, TableRow{
							Name:    fullName,
							ID:      rowID(fullName),
							Line:    callStart,
							EndLine: callEnd,
						})
					}
					c.spans = append(c.spans, caretSpan{
						testName: c.testName,
						subtests: segs,
						line:     callStart,
						endLine:  callEnd,
						pattern:  RunPattern(c.testName, segs...),
					})
					if fl, ok := call.Args[1].(*ast.FuncLit); ok && fl.Body != nil {
						c.walkBlock(fl.Body, tables, env, segs, emitRows, loopAlts, depth+1)
					}
				} else {
					segs := append(append([]string(nil), prefix...), name)
					nextAlts := append(append([][]string(nil), loopAlts...), []string{name})
					pat := buildLoopAltPattern(c.testName, prefix, nextAlts)
					c.spans = append(c.spans, caretSpan{
						testName: c.testName,
						subtests: segs,
						line:     callStart,
						endLine:  callEnd,
						pattern:  pat,
					})
					if fl, ok := call.Args[1].(*ast.FuncLit); ok && fl.Body != nil {
						c.walkBlock(fl.Body, tables, env, segs, emitRows, nextAlts, depth+1)
					}
				}
				return false
			}
		}
		return true
	})
}

func isSubtestRunCall(call *ast.CallExpr) bool {
	if call == nil || len(call.Args) != 2 {
		return false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "Run" {
		return false
	}
	if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "suite" {
		return false
	}
	return true
}

func directRunCalls(block *ast.BlockStmt) []*ast.CallExpr {
	if block == nil {
		return nil
	}
	var calls []*ast.CallExpr
	ast.Inspect(block, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if _, ok := n.(*ast.FuncLit); ok {
			return false
		}
		if _, ok := n.(*ast.RangeStmt); ok {
			return false
		}
		if call, ok := n.(*ast.CallExpr); ok && isSubtestRunCall(call) {
			calls = append(calls, call)
			return false
		}
		return true
	})
	return calls
}

func buildLoopAltPattern(testName string, prefix []string, alts [][]string) string {
	parts := []string{"^" + regexpQuote(testName) + "$"}
	for _, seg := range prefix {
		for _, s := range strings.Split(seg, "/") {
			parts = append(parts, "^"+regexpQuote(SubtestName(s))+"$")
		}
	}
	for _, group := range alts {
		if len(group) == 1 {
			for _, s := range strings.Split(group[0], "/") {
				parts = append(parts, "^"+regexpQuote(SubtestName(s))+"$")
			}
			continue
		}
		quoted := make([]string, 0, len(group))
		seen := make(map[string]bool, len(group))
		for _, item := range group {
			q := regexpQuote(SubtestName(item))
			if !seen[q] {
				seen[q] = true
				quoted = append(quoted, q)
			}
		}
		parts = append(parts, "^(?:"+strings.Join(quoted, "|")+")$")
	}
	return strings.Join(parts, "/")
}

func ResolveCaretTarget(src []byte, line int) CaretTarget {
	return ResolveCaretTargetInFile("", src, line, nil)
}

func appendUniqueRunner(suiteRunners map[string][]string, suiteType, runner string) {
	for _, existing := range suiteRunners[suiteType] {
		if existing == runner {
			return
		}
	}
	suiteRunners[suiteType] = append(suiteRunners[suiteType], runner)
}

func applyRunnersPattern(runners []string, pat string) string {
	if len(runners) <= 1 || pat == "" {
		return pat
	}
	firstSeg := "^" + regexpQuote(runners[0]) + "$"
	if !strings.HasPrefix(pat, firstSeg) {
		return pat
	}
	quoted := make([]string, 0, len(runners))
	seen := make(map[string]bool, len(runners))
	for _, r := range runners {
		q := regexpQuote(r)
		if !seen[q] {
			seen[q] = true
			quoted = append(quoted, q)
		}
	}
	return "^(?:" + strings.Join(quoted, "|") + ")$" + pat[len(firstSeg):]
}

func ResolveCaretTargetInFile(filePath string, src []byte, line int, readFile func(string) ([]byte, error)) CaretTarget {
	if line <= 0 || len(src) == 0 {
		return CaretTarget{}
	}
	parseName := filePath
	if parseName == "" {
		parseName = "test_test.go"
	}
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, parseName, src, parser.SkipObjectResolution)
	if node == nil || (err != nil && len(node.Decls) == 0) {
		return CaretTarget{}
	}

	suiteRunners := map[string][]string{}
	var spans []caretSpan

	for _, decl := range node.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		if isTestFunc(fn) || isBenchmarkFunc(fn) || isFuzzFunc(fn) {
			fnStart := fset.Position(fn.Pos()).Line
			fnEnd := fset.Position(fn.End()).Line
			spans = append(spans, caretSpan{
				testName: fn.Name.Name,
				line:     fnStart,
				endLine:  fnEnd,
				pattern:  RunPattern(fn.Name.Name),
			})
			_, fnSpans := collectFunctionSubtests(fset, fn.Name.Name, fn, nil)
			spans = append(spans, fnSpans...)
			for _, st := range suiteTypesRun(fn) {
				appendUniqueRunner(suiteRunners, st, fn.Name.Name)
			}
		}
	}

	missingSuiteTypes := map[string]bool{}
	for _, decl := range node.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		if recvType, ok := suiteMethod(fn); ok && len(suiteRunners[recvType]) == 0 {
			missingSuiteTypes[recvType] = true
		}
	}

	if len(missingSuiteTypes) > 0 && filePath != "" {
		dirName := filepath.Dir(filePath)
		cleanTarget := filepath.Clean(filePath)
		baseName := filepath.Base(cleanTarget)
		reader := readFile
		if reader == nil {
			reader = os.ReadFile
		}
		if entries, err := os.ReadDir(dirName); err == nil {
			for _, entry := range entries {
				name := entry.Name()
				if entry.IsDir() || strings.HasPrefix(name, ".") || name == "testdata" || !strings.HasSuffix(name, "_test.go") {
					continue
				}
				sibPath := filepath.Join(dirName, name)
				if filepath.Clean(sibPath) == cleanTarget || name == baseName {
					continue
				}
				sibSrc, err := reader(sibPath)
				if err != nil || len(sibSrc) == 0 {
					continue
				}
				sibFset := token.NewFileSet()
				sibNode, err := parser.ParseFile(sibFset, sibPath, sibSrc, parser.SkipObjectResolution)
				if sibNode == nil || (err != nil && len(sibNode.Decls) == 0) {
					continue
				}
				for _, decl := range sibNode.Decls {
					fn, ok := decl.(*ast.FuncDecl)
					if !ok || fn.Body == nil || !isTestFunc(fn) {
						continue
					}
					for _, st := range suiteTypesRun(fn) {
						if missingSuiteTypes[st] {
							appendUniqueRunner(suiteRunners, st, fn.Name.Name)
						}
					}
				}
			}
		}
	}

	for _, decl := range node.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		recvType, ok := suiteMethod(fn)
		if !ok {
			continue
		}
		runners := suiteRunners[recvType]
		if len(runners) == 0 {
			continue
		}
		firstRunner := runners[0]
		fnStart := fset.Position(fn.Pos()).Line
		fnEnd := fset.Position(fn.End()).Line
		prefix := []string{fn.Name.Name}
		spans = append(spans, caretSpan{
			testName: firstRunner,
			subtests: prefix,
			line:     fnStart,
			endLine:  fnEnd,
			pattern:  applyRunnersPattern(runners, RunPattern(firstRunner, prefix...)),
		})
		_, methodSpans := collectFunctionSubtests(fset, firstRunner, fn, prefix)
		for i := range methodSpans {
			methodSpans[i].pattern = applyRunnersPattern(runners, methodSpans[i].pattern)
			spans = append(spans, methodSpans[i])
		}
	}

	var best *caretSpan
	for i := range spans {
		sp := &spans[i]
		if sp.line <= 0 || sp.endLine < sp.line {
			continue
		}
		if line < sp.line || line > sp.endLine {
			continue
		}
		if best == nil {
			best = sp
			continue
		}
		spLen := sp.endLine - sp.line
		bestLen := best.endLine - best.line
		if spLen < bestLen || (spLen == bestLen && (len(sp.subtests) > len(best.subtests) || (len(sp.subtests) == len(best.subtests) && sp.line > best.line))) {
			best = sp
		}
	}

	if best == nil {
		return CaretTarget{}
	}

	subtests := append([]string(nil), best.subtests...)
	return CaretTarget{
		Found:       true,
		Test:        best.testName,
		Subtests:    subtests,
		SubtestPath: strings.Join(subtests, "/"),
		Line:        best.line,
		EndLine:     best.endLine,
		Pattern:     best.pattern,
	}
}

func FailedSubtestPattern(failedTests []string) string {
	if len(failedTests) == 0 {
		return ""
	}

	cleaned := make([]string, 0, len(failedTests))
	seen := make(map[string]bool, len(failedTests))
	for _, raw := range failedTests {
		if raw == "" {
			continue
		}
		if !seen[raw] {
			seen[raw] = true
			cleaned = append(cleaned, raw)
		}
	}
	if len(cleaned) == 0 {
		return ""
	}

	pruned := make([]string, 0, len(cleaned))
	for _, candidate := range cleaned {
		hasFailedDescendant := false
		prefix := candidate + "/"
		for _, other := range cleaned {
			if other != candidate && strings.HasPrefix(other, prefix) {
				hasFailedDescendant = true
				break
			}
		}
		if !hasFailedDescendant {
			pruned = append(pruned, candidate)
		}
	}
	if len(pruned) == 0 {
		pruned = cleaned
	}

	allTopLevel := true
	for _, p := range pruned {
		if strings.Contains(p, "/") {
			allTopLevel = false
			break
		}
	}
	if allTopLevel {
		return FailedPattern(pruned)
	}

	groups := make(map[string][]string)
	var groupKeys []string
	for _, fullPath := range pruned {
		segs := strings.Split(fullPath, "/")
		parentKey := ""
		leaf := segs[0]
		if len(segs) > 1 {
			parentKey = strings.Join(segs[:len(segs)-1], "/")
			leaf = segs[len(segs)-1]
		}
		if _, exists := groups[parentKey]; !exists {
			groupKeys = append(groupKeys, parentKey)
		}
		groups[parentKey] = append(groups[parentKey], leaf)
	}
	sort.Strings(groupKeys)

	branches := make([]string, 0, len(groupKeys))
	for _, parentKey := range groupKeys {
		leaves := groups[parentKey]
		sort.Strings(leaves)

		var parts []string
		if parentKey != "" {
			for _, seg := range strings.Split(parentKey, "/") {
				parts = append(parts, "^"+regexpQuote(SubtestName(seg))+"$")
			}
		}
		if len(leaves) == 1 {
			parts = append(parts, "^"+regexpQuote(SubtestName(leaves[0]))+"$")
		} else {
			quotedLeaves := make([]string, 0, len(leaves))
			leafSeen := make(map[string]bool, len(leaves))
			for _, leaf := range leaves {
				q := regexpQuote(SubtestName(leaf))
				if !leafSeen[q] {
					leafSeen[q] = true
					quotedLeaves = append(quotedLeaves, q)
				}
			}
			parts = append(parts, "^(?:"+strings.Join(quotedLeaves, "|")+")$")
		}
		branches = append(branches, strings.Join(parts, "/"))
	}

	return strings.Join(branches, "|")
}

func cloneTables(src map[string]*table) map[string]*table {
	out := make(map[string]*table, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func cloneEnv(src map[string]ast.Expr) map[string]ast.Expr {
	out := make(map[string]ast.Expr, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func mergeEnv(outer, inner map[string]ast.Expr) map[string]ast.Expr {
	out := cloneEnv(outer)
	for k, v := range inner {
		out[k] = v
	}
	return out
}

func isBenchmarkIdentifier(s string) bool {
	if !strings.HasPrefix(s, "Benchmark") {
		return false
	}
	rest := s[len("Benchmark"):]
	return rest == "" || rest[0] < 'a' || rest[0] > 'z'
}

func IsBenchmarkTarget(testName, pattern string) bool {
	if isBenchmarkIdentifier(testName) {
		return true
	}
	return isBenchmarkIdentifier(strings.TrimPrefix(pattern, "^"))
}

func DebugTestArgs(testName, testRow, testPattern string) (string, []string) {
	pattern := testPattern
	if pattern == "" {
		var rows []string
		if testRow != "" {
			rows = []string{testRow}
		}
		pattern = RunPattern(testName, rows...)
	}
	if IsBenchmarkTarget(testName, pattern) {
		return pattern, []string{"-test.run", "^$", "-test.bench", pattern, "-test.benchmem", "-test.v"}
	}
	return pattern, []string{"-test.run", pattern, "-test.v"}
}
