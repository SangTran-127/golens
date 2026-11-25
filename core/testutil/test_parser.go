package testutil

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golens/core/bridge"
)

const (
	maxTestFiles   = 1000
	maxRowsPerTest = 500
)

type TableRow struct {
	Name    string `json:"name"`
	ID      string `json:"id"`
	Line    int    `json:"line"`
	EndLine int    `json:"endLine,omitempty"`
	File    string `json:"file,omitempty"`
}

type GoTestFunc struct {
	Name    string     `json:"name"`
	File    string     `json:"file"`
	Line    int        `json:"line"`
	EndLine int        `json:"endLine,omitempty"`
	Package string     `json:"package"`
	Rows    []TableRow `json:"rows,omitempty"`
}

type GoTestSuite struct {
	Package    string       `json:"package"`
	Dir        string       `json:"dir"`
	ImportPath string       `json:"importPath"`
	Tests      []GoTestFunc `json:"tests"`
}

func isTestFunc(fn *ast.FuncDecl) bool {
	if fn.Recv != nil || fn.Type.Params == nil || len(fn.Type.Params.List) != 1 {
		return false
	}
	name := fn.Name.Name
	if !strings.HasPrefix(name, "Test") || name == "TestMain" {
		return false
	}
	if rest := name[4:]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return false
	}
	star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	sel, ok := star.X.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "T"
}

func isBenchmarkFunc(fn *ast.FuncDecl) bool {
	if fn.Recv != nil || fn.Type.Params == nil || len(fn.Type.Params.List) != 1 {
		return false
	}
	name := fn.Name.Name
	if !strings.HasPrefix(name, "Benchmark") {
		return false
	}
	if rest := name[9:]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return false
	}
	star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	sel, ok := star.X.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "B"
}

func isFuzzFunc(fn *ast.FuncDecl) bool {
	if fn.Recv != nil || fn.Type.Params == nil || len(fn.Type.Params.List) != 1 {
		return false
	}
	name := fn.Name.Name
	if !strings.HasPrefix(name, "Fuzz") {
		return false
	}
	if rest := name[4:]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return false
	}
	star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	sel, ok := star.X.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "F"
}

func suiteMethod(fn *ast.FuncDecl) (string, bool) {
	if fn.Recv == nil || len(fn.Recv.List) != 1 || fn.Body == nil {
		return "", false
	}
	if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 {
		return "", false
	}
	if fn.Type.Params != nil && len(fn.Type.Params.List) > 0 {
		if len(fn.Type.Params.List) != 1 {
			return "", false
		}
		star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
		if !ok {
			return "", false
		}
		sel, ok := star.X.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != "T" {
			return "", false
		}
	}
	name := fn.Name.Name
	if !strings.HasPrefix(name, "Test") || name == "TestMain" || len(name) == 4 {
		return "", false
	}
	if rest := name[4:]; rest != "" && rest[0] >= 'a' && rest[0] <= 'z' {
		return "", false
	}
	recv := typeIdentName(fn.Recv.List[0].Type)
	if recv == "" {
		return "", false
	}
	return recv, true
}

func typeIdentName(e ast.Expr) string {
	switch e := e.(type) {
	case *ast.Ident:
		return e.Name
	case *ast.StarExpr:
		return typeIdentName(e.X)
	case *ast.ParenExpr:
		return typeIdentName(e.X)
	case *ast.IndexExpr:
		return typeIdentName(e.X)
	case *ast.IndexListExpr:
		return typeIdentName(e.X)
	}
	return ""
}

func suiteTypeOf(e ast.Expr, localTypes map[string]string) string {
	switch e := e.(type) {
	case *ast.ParenExpr:
		return suiteTypeOf(e.X, localTypes)
	case *ast.UnaryExpr:
		if e.Op == token.AND {
			return suiteTypeOf(e.X, localTypes)
		}
	case *ast.CompositeLit:
		return typeIdentName(e.Type)
	case *ast.CallExpr:
		if id, ok := e.Fun.(*ast.Ident); ok && id.Name == "new" && len(e.Args) == 1 {
			return typeIdentName(e.Args[0])
		}
	case *ast.Ident:
		if localTypes != nil {
			return localTypes[e.Name]
		}
	}
	return ""
}

func suiteTypesRun(fn *ast.FuncDecl) []string {
	if fn.Body == nil {
		return nil
	}
	localTypes := map[string]string{}
	var out []string
	seen := map[string]bool{}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.AssignStmt:
			for i, rhs := range n.Rhs {
				if i < len(n.Lhs) {
					if id, ok := n.Lhs[i].(*ast.Ident); ok {
						if t := suiteTypeOf(rhs, localTypes); t != "" {
							localTypes[id.Name] = t
						}
					}
				}
			}
		case *ast.ValueSpec:
			valType := typeIdentName(n.Type)
			for i, name := range n.Names {
				if i < len(n.Values) {
					if t := suiteTypeOf(n.Values[i], localTypes); t != "" {
						localTypes[name.Name] = t
						continue
					}
				}
				if valType != "" {
					localTypes[name.Name] = valType
				}
			}
		case *ast.CallExpr:
			if len(n.Args) != 2 {
				return true
			}
			sel, ok := n.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "Run" {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if !ok || pkg.Name != "suite" {
				return true
			}
			if st := suiteTypeOf(n.Args[1], localTypes); st != "" && !seen[st] {
				seen[st] = true
				out = append(out, st)
			}
		}
		return true
	})
	return out
}

type parsedTestFile struct {
	path string
	node *ast.File
}

func DiscoverTests(dir string) string {
	dirPaths := make(map[string][]string)
	var order []string
	files := 0
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if path != dir && (strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") || name == "vendor" || name == "testdata" || name == "node_modules" || name == "build" || name == "third_party") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(name, "_test.go") {
			return nil
		}
		if info, statErr := d.Info(); statErr == nil && info.Size() > (1<<20) {
			return nil
		}
		if files >= maxTestFiles {
			return filepath.SkipAll
		}
		files++
		dirName := filepath.Dir(path)
		if _, ok := dirPaths[dirName]; !ok {
			order = append(order, dirName)
		}
		dirPaths[dirName] = append(dirPaths[dirName], path)
		return nil
	})
	if err != nil {
		bridge.Debug("Error discovering tests: " + err.Error())
	}
	suites := make([]GoTestSuite, 0, len(order))
	for _, dirName := range order {
		fset := token.NewFileSet()
		var pfiles []parsedTestFile
		for _, path := range dirPaths[dirName] {
			node, parseErr := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if parseErr != nil || node == nil {
				continue
			}
			pfiles = append(pfiles, parsedTestFile{path: path, node: node})
		}
		if len(pfiles) == 0 {
			continue
		}
		methodsBySuite := make(map[string][]TableRow)
		for _, pf := range pfiles {
			for _, decl := range pf.node.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok {
					continue
				}
				if recvType, ok := suiteMethod(fn); ok {
					methodsBySuite[recvType] = append(methodsBySuite[recvType], TableRow{
						Name:    fn.Name.Name,
						ID:      rowID(fn.Name.Name),
						Line:    fset.Position(fn.Pos()).Line,
						EndLine: fset.Position(fn.End()).Line,
						File:    pf.path,
					})
					subRows, _ := collectFunctionSubtests(fset, fn.Name.Name, fn, []string{fn.Name.Name})
					for _, sr := range subRows {
						sr.File = pf.path
						methodsBySuite[recvType] = append(methodsBySuite[recvType], sr)
					}
				}
			}
		}
		var tests []GoTestFunc
		pkgName := ""
		for _, pf := range pfiles {
			if pkgName == "" {
				pkgName = strings.TrimSuffix(pf.node.Name.Name, "_test")
			}
			for _, decl := range pf.node.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Body == nil || (!isTestFunc(fn) && !isBenchmarkFunc(fn) && !isFuzzFunc(fn)) {
					continue
				}
				rows := TableRows(fset, fn)
				for _, st := range suiteTypesRun(fn) {
					for _, m := range methodsBySuite[st] {
						if len(rows) >= maxRowsPerTest {
							break
						}
						r := m
						if r.File == pf.path {
							r.File = ""
						}
						rows = append(rows, r)
					}
				}
				tests = append(tests, GoTestFunc{
					Name:    fn.Name.Name,
					File:    pf.path,
					Line:    fset.Position(fn.Pos()).Line,
					EndLine: fset.Position(fn.End()).Line,
					Package: pf.node.Name.Name,
					Rows:    rows,
				})
			}
		}
		if len(tests) == 0 {
			continue
		}
		relDir, err := filepath.Rel(dir, dirName)
		if err != nil {
			relDir = "."
		}
		suites = append(suites, GoTestSuite{
			Package:    pkgName,
			Dir:        relDir,
			ImportPath: ImportPath(dirName),
			Tests:      tests,
		})
	}
	res, _ := json.Marshal(suites)
	return string(res)
}

func fileTests(fset *token.FileSet, node *ast.File, path string) []GoTestFunc {
	methodsInFile := make(map[string][]TableRow)
	var suiteOrder []string
	for _, decl := range node.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}
		if recvType, ok := suiteMethod(fn); ok {
			if _, exists := methodsInFile[recvType]; !exists {
				suiteOrder = append(suiteOrder, recvType)
			}
			methodsInFile[recvType] = append(methodsInFile[recvType], TableRow{
				Name:    fn.Name.Name,
				ID:      rowID(fn.Name.Name),
				Line:    fset.Position(fn.Pos()).Line,
				EndLine: fset.Position(fn.End()).Line,
			})
			subRows, _ := collectFunctionSubtests(fset, fn.Name.Name, fn, []string{fn.Name.Name})
			methodsInFile[recvType] = append(methodsInFile[recvType], subRows...)
		}
	}

	claimedSuites := make(map[string]bool)
	var tests []GoTestFunc
	for _, decl := range node.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil || (!isTestFunc(fn) && !isBenchmarkFunc(fn) && !isFuzzFunc(fn)) {
			continue
		}
		rows := TableRows(fset, fn)
		for _, st := range suiteTypesRun(fn) {
			claimedSuites[st] = true
			for _, m := range methodsInFile[st] {
				if len(rows) >= maxRowsPerTest {
					break
				}
				rows = append(rows, m)
			}
		}
		tests = append(tests, GoTestFunc{
			Name:    fn.Name.Name,
			File:    path,
			Line:    fset.Position(fn.Pos()).Line,
			EndLine: fset.Position(fn.End()).Line,
			Package: node.Name.Name,
			Rows:    rows,
		})
	}

	hasUnclaimed := false
	for _, st := range suiteOrder {
		if !claimedSuites[st] {
			hasUnclaimed = true
			break
		}
	}
	if hasUnclaimed && path != "" {
		dirName := filepath.Dir(path)
		baseName := filepath.Base(path)
		if entries, err := os.ReadDir(dirName); err == nil {
			for _, entry := range entries {
				if entry.IsDir() || !strings.HasSuffix(entry.Name(), "_test.go") || entry.Name() == baseName {
					continue
				}
				sibPath := filepath.Join(dirName, entry.Name())
				sibNode, err := parser.ParseFile(fset, sibPath, nil, parser.SkipObjectResolution)
				if err != nil || sibNode == nil {
					continue
				}
				for _, decl := range sibNode.Decls {
					fn, ok := decl.(*ast.FuncDecl)
					if !ok || fn.Body == nil || !isTestFunc(fn) {
						continue
					}
					var rows []TableRow
					for _, st := range suiteTypesRun(fn) {
						if claimedSuites[st] || len(methodsInFile[st]) == 0 {
							continue
						}
						claimedSuites[st] = true
						for _, m := range methodsInFile[st] {
							if len(rows) >= maxRowsPerTest {
								break
							}
							rows = append(rows, m)
						}
					}
					if len(rows) > 0 {
						tests = append(tests, GoTestFunc{
							Name:    fn.Name.Name,
							File:    path,
							Line:    0,
							Package: node.Name.Name,
							Rows:    rows,
						})
					}
				}
			}
		}
	}
	return tests
}

type FileTestsResult struct {
	ImportPath string       `json:"importPath"`
	Tests      []GoTestFunc `json:"tests"`
}

func FileTests(path string, src []byte) FileTestsResult {
	res := FileTestsResult{ImportPath: ImportPath(filepath.Dir(path)), Tests: []GoTestFunc{}}
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
	if node == nil {
		return res
	}
	if err != nil && len(node.Decls) == 0 {
		return res
	}
	if t := fileTests(fset, node, path); t != nil {
		res.Tests = t
	}
	return res
}

func ParseFileTests(path string, src []byte) FileTestsResult {
	return FileTests(path, src)
}

func FindModuleRoot(dir string) (string, string) {
	for d := dir; ; d = filepath.Dir(d) {
		if data, err := os.ReadFile(filepath.Join(d, "go.mod")); err == nil {
			if mod := modulePath(data); mod != "" {
				return d, mod
			}
			return "", ""
		}
		parent := filepath.Dir(d)
		if parent == d {
			return "", ""
		}
	}
}

func ImportPath(dir string) string {
	rel := ""
	for d := dir; ; d = filepath.Dir(d) {
		if data, err := os.ReadFile(filepath.Join(d, "go.mod")); err == nil {
			mod := modulePath(data)
			if mod == "" {
				return ""
			}
			if rel == "" {
				return mod
			}
			return mod + "/" + filepath.ToSlash(rel)
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
		rel = filepath.Join(filepath.Base(d), rel)
	}
}

func modulePath(gomod []byte) string {
	for _, line := range strings.Split(string(gomod), "\n") {
		line = strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(line, "module"); ok && (rest == "" || rest[0] == ' ' || rest[0] == '\t') {
			rest = strings.TrimSpace(rest)
			if i := strings.Index(rest, "//"); i >= 0 {
				rest = strings.TrimSpace(rest[:i])
			}
			return strings.Trim(rest, "\"`")
		}
	}
	return ""
}

type table struct {
	elems  []ast.Expr
	keyed  bool
	fields map[string]int
}

func identName(e ast.Expr) string {
	if id, ok := e.(*ast.Ident); ok && id.Name != "_" {
		return id.Name
	}
	return ""
}

func tableOf(e ast.Expr) *table {
	lit, ok := e.(*ast.CompositeLit)
	if !ok {
		return nil
	}
	t := &table{fields: map[string]int{}}
	var elem ast.Expr
	switch typ := lit.Type.(type) {
	case *ast.ArrayType:
		elem = typ.Elt
	case *ast.MapType:
		t.keyed = true
		elem = typ.Value
	default:
		return nil
	}
	if st, ok := elem.(*ast.StructType); ok {
		i := 0
		for _, f := range st.Fields.List {
			for _, n := range f.Names {
				t.fields[n.Name] = i
				i++
			}
			if len(f.Names) == 0 {
				i++
			}
		}
	}
	t.elems = lit.Elts
	return t
}

type value struct {
	s     string
	isInt bool
	i     int64
}

func rowEnv(el ast.Expr, t *table, keyVar, valVar string) map[string]ast.Expr {
	env := map[string]ast.Expr{}
	body := el
	if kv, ok := el.(*ast.KeyValueExpr); ok && t.keyed {
		if keyVar != "" {
			env[keyVar] = kv.Key
		}
		body = kv.Value
	}
	lit, ok := body.(*ast.CompositeLit)
	if !ok || valVar == "" {
		return env
	}
	for i, e := range lit.Elts {
		if kv, ok := e.(*ast.KeyValueExpr); ok {
			if k, ok := kv.Key.(*ast.Ident); ok {
				env[valVar+"."+k.Name] = kv.Value
			}
			continue
		}
		for name, idx := range t.fields {
			if idx == i {
				env[valVar+"."+name] = e
			}
		}
	}
	return env
}

func evalValue(e ast.Expr, env map[string]ast.Expr, depth int) (value, bool) {
	if depth > 8 {
		return value{}, false
	}
	switch e := e.(type) {
	case *ast.BasicLit:
		switch e.Kind {
		case token.STRING:
			s, err := strconv.Unquote(e.Value)
			return value{s: s}, err == nil
		case token.INT:
			n, err := strconv.ParseInt(e.Value, 0, 64)
			return value{isInt: true, i: n, s: e.Value}, err == nil
		default:
		}
	case *ast.ParenExpr:
		return evalValue(e.X, env, depth+1)
	case *ast.Ident:
		if v, ok := env[e.Name]; ok {
			return evalValue(v, env, depth+1)
		}
	case *ast.SelectorExpr:
		if x, ok := e.X.(*ast.Ident); ok {
			if v, ok := env[x.Name+"."+e.Sel.Name]; ok {
				return evalValue(v, env, depth+1)
			}
		}
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			a, ok1 := evalValue(e.X, env, depth+1)
			b, ok2 := evalValue(e.Y, env, depth+1)
			if ok1 && ok2 && !a.isInt && !b.isInt {
				return value{s: a.s + b.s}, true
			}
		}
	case *ast.CallExpr:
		sel, ok := e.Fun.(*ast.SelectorExpr)
		if !ok || len(e.Args) == 0 {
			return value{}, false
		}
		if pkg, ok := sel.X.(*ast.Ident); !ok || pkg.Name != "fmt" || sel.Sel.Name != "Sprintf" {
			return value{}, false
		}
		format, ok := evalValue(e.Args[0], env, depth+1)
		if !ok || format.isInt {
			return value{}, false
		}
		args := make([]any, 0, len(e.Args)-1)
		for _, a := range e.Args[1:] {
			v, ok := evalValue(a, env, depth+1)
			if !ok {
				return value{}, false
			}
			if v.isInt {
				args = append(args, v.i)
			} else {
				args = append(args, v.s)
			}
		}
		if strings.ContainsAny(strings.ReplaceAll(format.s, "%%", ""), "%") && !onlySimpleVerbs(format.s) {
			return value{}, false
		}
		return value{s: fmt.Sprintf(format.s, args...)}, true
	}
	return value{}, false
}

func onlySimpleVerbs(f string) bool {
	for i := 0; i < len(f); i++ {
		if f[i] != '%' {
			continue
		}
		i++
		if i >= len(f) {
			return false
		}
		switch f[i] {
		case 's', 'd', 'v', 'q', '%':
		default:
			return false
		}
	}
	return true
}

func evalString(e ast.Expr, env map[string]ast.Expr) (string, bool) {
	v, ok := evalValue(e, env, 0)
	if !ok || v.isInt {
		return "", false
	}
	return v.s, true
}

func SubtestName(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r == ' ':
			b.WriteByte('_')
		case !strconv.IsPrint(r):
			b.WriteString(strconv.QuoteRune(r)[1 : len(strconv.QuoteRune(r))-1])
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func rowID(name string) string {
	segs := strings.Split(name, "/")
	for i, seg := range segs {
		segs[i] = SubtestName(seg)
	}
	return strings.Join(segs, "/")
}

func RunPattern(test string, rows ...string) string {
	var parts []string
	if strings.Contains(test, "/") {
		segs := strings.Split(test, "/")
		parts = append(parts, "^"+regexpQuote(segs[0])+"$")
		for _, seg := range segs[1:] {
			parts = append(parts, "^"+regexpQuote(SubtestName(seg))+"$")
		}
	} else {
		parts = []string{"^" + regexpQuote(test) + "$"}
	}
	for _, r := range rows {
		for _, seg := range strings.Split(r, "/") {
			parts = append(parts, "^"+regexpQuote(SubtestName(seg))+"$")
		}
	}
	return strings.Join(parts, "/")
}

func regexpQuote(s string) string {
	const special = `\.+*?()|[]{}^$`
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(special, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func FailedPattern(tests []string) string {
	if len(tests) == 0 {
		return ""
	}
	quoted := make([]string, len(tests))
	for i, t := range tests {
		quoted[i] = regexpQuote(t)
	}
	return "^(" + strings.Join(quoted, "|") + ")$"
}
