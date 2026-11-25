package safety

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"

	"golens/core/bridge"
	"golens/core/vmexec"
)

const (
	safetyGoTestFileSuffix   = "_test.go"
	msgSpawnsExternalProcess = "Spawns or executes an external operating system process."
	prefixPanicColon         = "panic:"
	maxSafetyFindings        = 200
	maxSafetyWalkFiles       = 250
	maxSafetyFileBytes       = 1 << 20
	maxExternalToolGoFiles   = 40
)

var (
	safetyCancelMu sync.Mutex
	safetyCancelFn context.CancelFunc
	safetyRunMu    sync.Mutex
)

func runBoundedTool(parentCtx context.Context, dir string, timeout time.Duration, bin string, args ...string) ([]byte, error) {
	if parentCtx == nil {
		parentCtx = context.Background()
	}
	if err := parentCtx.Err(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(parentCtx, timeout)
	defer cancel()

	guestDir := vmexec.HostToGuestPath(dir, dir)
	cmd := vmexec.CommandContext(ctx, bin, args...)
	cmd.Dir = guestDir
	cmd.Env = vmexec.DefaultVMEnv("arm64", map[string]string{
		"GOFLAGS":    "-p=2",
		"GOMEMLIMIT": "512MiB",
		"GOGC":       "50",
	})
	out, err := cmd.CombinedOutput()
	if err != nil && bridge.CanFallbackToHost(err) {
		hostBin := resolveHostSafetyTool(bin)
		hostCmd := exec.CommandContext(ctx, hostBin, args...)
		hostCmd.Dir = dir
		hostCmd.Env = append(os.Environ(), "GOFLAGS=-p=2", "GOMEMLIMIT=512MiB", "GOGC=50")
		return hostCmd.CombinedOutput()
	}
	return out, err
}

func resolveHostSafetyTool(bin string) string {
	if filepath.IsAbs(bin) {
		return bin
	}
	if p, err := exec.LookPath(bin); err == nil && p != "" {
		return p
	}
	var dirs []string
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		dirs = append(dirs, filepath.Join(home, "go", "bin"))
	}
	dirs = append(dirs, "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin")
	for _, d := range dirs {
		candidate := filepath.Join(d, bin)
		if isExecutable(candidate) {
			return candidate
		}
	}
	return bin
}

func canRunExternalGoTool(workspaceDir string, maxGoFiles int) bool {
	if workspaceDir == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(workspaceDir, "go.mod")); err != nil {
		return false
	}
	count := 0
	exceeded := false
	_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name(), path == workspaceDir) {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(d.Name(), ".go") {
			count++
			if count > maxGoFiles {
				exceeded = true
				return filepath.SkipAll
			}
		}
		return nil
	})
	return count > 0 && !exceeded
}

type Finding struct {
	ID        string   `json:"id"`
	Kind      string   `json:"kind"`
	Severity  int      `json:"severity"`
	Title     string   `json:"title"`
	Detail    string   `json:"detail"`
	File      string   `json:"file"`
	RelFile   string   `json:"relFile"`
	Line      int      `json:"line"`
	Col       int      `json:"col"`
	Symbol    string   `json:"symbol,omitempty"`
	CallChain []string `json:"callChain,omitempty"`
}

type Report struct {
	Findings []Finding `json:"findings"`
	Summary  string    `json:"summary"`
}

func RunSafetyAudit(workspaceDir string, consoleOutput string) (string, error) {
	return RunAudit(workspaceDir, consoleOutput)
}

func RunAudit(workspaceDir string, consoleOutput string) (string, error) {
	auditCtx, cancel := context.WithCancel(context.Background())
	safetyCancelMu.Lock()
	if safetyCancelFn != nil {
		safetyCancelFn()
	}
	safetyCancelFn = cancel
	safetyCancelMu.Unlock()
	defer cancel()

	safetyRunMu.Lock()
	defer safetyRunMu.Unlock()

	absRoot := normalizeWorkspace(workspaceDir)

	var all []Finding
	if absRoot != "" && auditCtx.Err() == nil {
		all = append(all, analyzeASTHazards(absRoot)...)
		all = append(all, analyzeDeadcode(absRoot)...)
		if auditCtx.Err() == nil {
			all = append(all, analyzeVulns(absRoot)...)
		}
		all = append(all, auditWorkspaceGoMod(absRoot)...)
		all = append(all, scanPackageCapabilities(absRoot, nil, nil)...)
		if auditCtx.Err() == nil {
			for _, lf := range runGolangCILint(auditCtx, absRoot) {
				if !hasExistingFinding(all, lf) {
					all = append(all, lf)
				}
			}
		}
	}
	if strings.TrimSpace(consoleOutput) != "" {
		all = append(all, ParseRaceAndPanic(absRoot, consoleOutput)...)
	}

	merged := deduplicateAndSort(all)
	if len(merged) > maxSafetyFindings {
		merged = merged[:maxSafetyFindings]
	}

	report := Report{
		Findings: merged,
		Summary:  formatSummary(merged),
	}
	raw, err := json.Marshal(report)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func normalizeWorkspace(workspaceDir string) string {
	trimmed := strings.TrimSpace(workspaceDir)
	if trimmed == "" {
		return ""
	}
	if abs, err := filepath.Abs(trimmed); err == nil {
		return filepath.Clean(abs)
	}
	return filepath.Clean(trimmed)
}

func relPath(workspaceDir, file string) string {
	if workspaceDir == "" || file == "" {
		return file
	}
	if rel, err := filepath.Rel(workspaceDir, file); err == nil && !strings.HasPrefix(rel, "..") {
		return filepath.ToSlash(rel)
	}
	return filepath.ToSlash(file)
}

func shouldSkipDir(name string, isRoot bool) bool {
	if isRoot {
		return false
	}
	switch name {
	case ".git", ".build", "build", "vendor", "node_modules", "testdata", "third_party":
		return true
	}
	return strings.HasPrefix(name, ".")
}

func utf16Column(src []byte, pos token.Position) int {
	if pos.Column <= 1 || len(src) == 0 || pos.Offset <= 0 || pos.Offset > len(src) {
		if pos.Column >= 1 {
			return pos.Column
		}
		return 1
	}
	lineStart := pos.Offset - (pos.Column - 1)
	if lineStart < 0 || lineStart > pos.Offset {
		return pos.Column
	}
	prefix := string(src[lineStart:pos.Offset])
	return len(utf16.Encode([]rune(prefix))) + 1
}

func analyzeASTHazards(workspaceDir string) []Finding {
	var findings []Finding
	filesVisited := 0

	_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name(), path == workspaceDir) {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, safetyGoTestFileSuffix) {
			return nil
		}
		if info, statErr := d.Info(); statErr == nil && info.Size() > maxSafetyFileBytes {
			return nil
		}
		filesVisited++
		if filesVisited > maxSafetyWalkFiles {
			return filepath.SkipAll
		}
		src, readErr := os.ReadFile(path)
		if readErr != nil || len(src) > maxSafetyFileBytes {
			return nil
		}
		fset := token.NewFileSet()
		fileAST, parseErr := parser.ParseFile(fset, path, src, 0)
		if parseErr != nil || fileAST == nil {
			return nil
		}

		absFile, absErr := filepath.Abs(path)
		if absErr != nil {
			absFile = path
		}
		rel := relPath(workspaceDir, absFile)

		for _, decl := range fileAST.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			enclosingName := fn.Name.Name
			findings = append(findings, inspectFuncBodyHazards(fset, src, absFile, rel, enclosingName, fn.Body)...)
		}

		for _, decl := range fileAST.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok {
				continue
			}
			findings = append(findings, inspectNodeHazards(fset, src, absFile, rel, "", gen, false)...)
		}

		return nil
	})

	return findings
}

func inspectFuncBodyHazards(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	body *ast.BlockStmt,
) []Finding {
	return inspectNodeHazards(fset, src, absFile, rel, enclosingFunc, body, false)
}

func inspectNodeHazards(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	root ast.Node,
	inLoop bool,
) []Finding {
	var findings []Finding

	var walk func(n ast.Node, insideLoop bool)
	walk = func(n ast.Node, insideLoop bool) {
		if n == nil {
			return
		}
		switch stmt := n.(type) {
		case *ast.ForStmt:
			if stmt.Init != nil {
				walk(stmt.Init, insideLoop)
			}
			if stmt.Cond != nil {
				walk(stmt.Cond, insideLoop)
			}
			if stmt.Post != nil {
				walk(stmt.Post, insideLoop)
			}
			if stmt.Body != nil {
				walk(stmt.Body, true)
			}
			return
		case *ast.RangeStmt:
			if stmt.Key != nil {
				walk(stmt.Key, insideLoop)
			}
			if stmt.Value != nil {
				walk(stmt.Value, insideLoop)
			}
			if stmt.X != nil {
				walk(stmt.X, insideLoop)
			}
			if stmt.Body != nil {
				walk(stmt.Body, true)
			}
			return
		case *ast.FuncLit:
			if stmt.Body != nil {
				walk(stmt.Body, false)
			}
			return
		case *ast.GoStmt:
			findings = append(findings, checkGoStmtHazards(fset, src, absFile, rel, enclosingFunc, stmt, insideLoop)...)
			if stmt.Call != nil {
				walk(stmt.Call, false)
			}
			return
		case *ast.DeferStmt:
			if insideLoop && stmt.Call != nil {
				if sel, ok := stmt.Call.Fun.(*ast.SelectorExpr); ok {
					if sel.Sel.Name == "Unlock" || sel.Sel.Name == "RUnlock" {
						pos := fset.Position(stmt.Pos())
						col := utf16Column(src, pos)
						findings = append(findings, Finding{
							ID:       fmt.Sprintf("GO-CONC-LOCK-COPY:%s:%d", rel, pos.Line),
							Kind:     "hazard",
							Severity: 2,
							Title:    "Deferred Unlock inside loop (GO-CONC-LOCK-COPY)",
							Detail:   "Deferring Unlock() inside a loop holds the lock until the enclosing function returns, risking deadlock or contention.",
							File:     absFile,
							RelFile:  rel,
							Line:     pos.Line,
							Col:      col,
							Symbol:   enclosingFunc,
						})
					}
				}
			}
		case *ast.CompositeLit:
			if f, ok := checkTLSInsecureComposite(fset, src, absFile, rel, enclosingFunc, stmt); ok {
				findings = append(findings, f)
			}
		case *ast.CallExpr:
			if f, ok := checkHTTPCallHazard(fset, src, absFile, rel, enclosingFunc, stmt); ok {
				findings = append(findings, f)
			}
			if f, ok := checkExecShellHazard(fset, src, absFile, rel, enclosingFunc, stmt); ok {
				findings = append(findings, f)
			}
		}

		ast.Inspect(n, func(child ast.Node) bool {
			if child == nil || child == n {
				return true
			}
			walk(child, insideLoop)
			return false
		})
	}

	walk(root, inLoop)
	return findings
}

func checkGoStmtHazards(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	goStmt *ast.GoStmt,
	insideLoop bool,
) []Finding {
	var findings []Finding
	if goStmt == nil || goStmt.Call == nil {
		return nil
	}
	lit, ok := goStmt.Call.Fun.(*ast.FuncLit)
	if !ok || lit.Body == nil {
		return nil
	}

	ast.Inspect(lit.Body, func(n ast.Node) bool {
		if nested, isLit := n.(*ast.FuncLit); isLit && nested != lit {
			return false
		}
		call, isCall := n.(*ast.CallExpr)
		if !isCall {
			return true
		}
		sel, isSel := call.Fun.(*ast.SelectorExpr)
		if !isSel || sel.Sel.Name != "Add" || len(call.Args) != 1 {
			return true
		}
		if isLikelyWaitGroupReceiver(sel.X) {
			pos := fset.Position(call.Pos())
			col := utf16Column(src, pos)
			findings = append(findings, Finding{
				ID:       fmt.Sprintf("GO-CONC-WAITGROUP:%s:%d", rel, pos.Line),
				Kind:     "hazard",
				Severity: 1,
				Title:    "WaitGroup.Add called inside goroutine (GO-CONC-WAITGROUP)",
				Detail:   "Calling wg.Add() inside a 'go func()' body races with wg.Wait(); call wg.Add() before launching the goroutine.",
				File:     absFile,
				RelFile:  rel,
				Line:     pos.Line,
				Col:      col,
				Symbol:   enclosingFunc,
			})
		}
		return true
	})

	if insideLoop && len(goStmt.Call.Args) == 0 && (lit.Type.Params == nil || len(lit.Type.Params.List) == 0) {
		pos := fset.Position(goStmt.Pos())
		col := utf16Column(src, pos)
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("GO-CONC-LOOP-CAPTURE:%s:%d", rel, pos.Line),
			Kind:     "hazard",
			Severity: 2,
			Title:    "Unbounded goroutine in loop without explicit arguments (GO-CONC-LOOP-CAPTURE)",
			Detail:   "Launching 'go func()' inside a loop without passing loop state or bounding concurrency can capture shared state or leak goroutines.",
			File:     absFile,
			RelFile:  rel,
			Line:     pos.Line,
			Col:      col,
			Symbol:   enclosingFunc,
		})
	}

	return findings
}

func isLikelyWaitGroupReceiver(expr ast.Expr) bool {
	switch x := expr.(type) {
	case *ast.Ident:
		lower := strings.ToLower(x.Name)
		return lower == "wg" || strings.Contains(lower, "wg") || strings.Contains(lower, "wait")
	case *ast.SelectorExpr:
		lower := strings.ToLower(x.Sel.Name)
		return lower == "wg" || strings.Contains(lower, "wg") || strings.Contains(lower, "wait")
	}
	return false
}

func checkTLSInsecureComposite(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	comp *ast.CompositeLit,
) (Finding, bool) {
	for _, elt := range comp.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		keyIdent, ok := kv.Key.(*ast.Ident)
		if !ok || keyIdent.Name != "InsecureSkipVerify" {
			continue
		}
		valIdent, ok := kv.Value.(*ast.Ident)
		if !ok || valIdent.Name != "true" {
			continue
		}
		pos := fset.Position(kv.Pos())
		col := utf16Column(src, pos)
		return Finding{
			ID:       fmt.Sprintf("GO-SEC-TLS-INSECURE:%s:%d", rel, pos.Line),
			Kind:     "hazard",
			Severity: 1,
			Title:    "TLS InsecureSkipVerify enabled (GO-SEC-TLS-INSECURE)",
			Detail:   "Setting InsecureSkipVerify: true disables TLS certificate validation and exposes connections to man-in-the-middle attacks.",
			File:     absFile,
			RelFile:  rel,
			Line:     pos.Line,
			Col:      col,
			Symbol:   enclosingFunc,
		}, true
	}
	return Finding{}, false
}

func checkHTTPCallHazard(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	call *ast.CallExpr,
) (Finding, bool) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return Finding{}, false
	}

	method := sel.Sel.Name
	isDefaultHTTP := false
	switch x := sel.X.(type) {
	case *ast.Ident:
		if x.Name == "http" && (method == "Get" || method == "Post" || method == "Head" || method == "PostForm") {
			isDefaultHTTP = true
		}
	case *ast.SelectorExpr:
		if pkgIdent, ok := x.X.(*ast.Ident); ok && pkgIdent.Name == "http" && x.Sel.Name == "DefaultClient" {
			if method == "Do" || method == "Get" || method == "Post" || method == "Head" || method == "PostForm" {
				isDefaultHTTP = true
			}
		}
	}
	if !isDefaultHTTP {
		return Finding{}, false
	}

	pos := fset.Position(call.Pos())
	col := utf16Column(src, pos)
	return Finding{
		ID:       fmt.Sprintf("GO-SEC-HTTP-DEFAULT:%s:%d", rel, pos.Line),
		Kind:     "hazard",
		Severity: 2,
		Title:    "HTTP request using DefaultClient without timeout (GO-SEC-HTTP-DEFAULT)",
		Detail:   fmt.Sprintf("http.%s uses http.DefaultClient which has no timeout and can hang indefinitely; use an *http.Client with an explicit Timeout.", method),
		File:     absFile,
		RelFile:  rel,
		Line:     pos.Line,
		Col:      col,
		Symbol:   enclosingFunc,
	}, true
}

func checkExecShellHazard(
	fset *token.FileSet,
	src []byte,
	absFile string,
	rel string,
	enclosingFunc string,
	call *ast.CallExpr,
) (Finding, bool) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return Finding{}, false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "exec" {
		return Finding{}, false
	}

	var args []ast.Expr
	switch sel.Sel.Name {
	case "Command":
		args = call.Args
	case "CommandContext":
		if len(call.Args) > 1 {
			args = call.Args[1:]
		}
	default:
		return Finding{}, false
	}
	if len(args) < 2 {
		return Finding{}, false
	}

	shellName := stringLitValue(args[0])
	flagName := stringLitValue(args[1])
	baseShell := filepath.Base(shellName)
	if (baseShell == "sh" || baseShell == "bash" || baseShell == "zsh") && flagName == "-c" {
		pos := fset.Position(call.Pos())
		col := utf16Column(src, pos)
		return Finding{
			ID:       fmt.Sprintf("GO-SEC-EXEC-SHELL:%s:%d", rel, pos.Line),
			Kind:     "hazard",
			Severity: 1,
			Title:    "Shell command execution via exec.Command (GO-SEC-EXEC-SHELL)",
			Detail:   fmt.Sprintf("exec.%s(%q, \"-c\", ...) invokes a shell and risks command injection; invoke the target binary directly.", sel.Sel.Name, shellName),
			File:     absFile,
			RelFile:  rel,
			Line:     pos.Line,
			Col:      col,
			Symbol:   enclosingFunc,
		}, true
	}

	return Finding{}, false
}

func stringLitValue(expr ast.Expr) string {
	lit, ok := expr.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return ""
	}
	unquoted, err := strconv.Unquote(lit.Value)
	if err != nil {
		return strings.Trim(lit.Value, "\"`")
	}
	return unquoted
}

type deadcodePackageJSON struct {
	Name  string             `json:"Name"`
	Path  string             `json:"Path"`
	Funcs []deadcodeFuncJSON `json:"Funcs"`
}

type deadcodeFuncJSON struct {
	Name     string          `json:"Name"`
	Position deadcodePosJSON `json:"Position"`
}

type deadcodePosJSON struct {
	File string `json:"File"`
	Line int    `json:"Line"`
	Col  int    `json:"Col"`
}

func analyzeDeadcode(workspaceDir string) []Finding {
	var findings []Finding

	if canRunExternalGoTool(workspaceDir, maxExternalToolGoFiles) {
		if bin, err := exec.LookPath("deadcode"); err == nil && bin != "" {
			out, runErr := runBoundedTool(context.Background(), workspaceDir, 4*time.Second, bin, "-json", "./...")
			if runErr == nil && len(out) > 0 {
				findings = append(findings, parseDeadcodeJSON(workspaceDir, out)...)
			}
		}
	}

	findings = append(findings, analyzeASTDeadcode(workspaceDir)...)
	return findings
}

func parseDeadcodeJSON(workspaceDir string, data []byte) []Finding {
	var findings []Finding
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return nil
	}

	var pkgs []deadcodePackageJSON
	if trimmed[0] == '[' {
		_ = json.Unmarshal(trimmed, &pkgs)
	} else {
		dec := json.NewDecoder(bytes.NewReader(trimmed))
		for {
			var pkg deadcodePackageJSON
			if err := dec.Decode(&pkg); err != nil {
				if err == io.EOF {
					break
				}
				break
			}
			pkgs = append(pkgs, pkg)
		}
	}

	for _, pkg := range pkgs {
		for _, fn := range pkg.Funcs {
			if fn.Position.File == "" {
				continue
			}
			absFile := fn.Position.File
			if !filepath.IsAbs(absFile) {
				absFile = filepath.Join(workspaceDir, absFile)
			}
			absFile = filepath.Clean(absFile)
			rel := relPath(workspaceDir, absFile)
			line := fn.Position.Line
			if line <= 0 {
				line = 1
			}
			col := fn.Position.Col
			if col <= 0 {
				col = 1
			}
			pkgLabel := pkg.Name
			if pkgLabel == "" {
				pkgLabel = pkg.Path
			}
			findings = append(findings, Finding{
				ID:       fmt.Sprintf("DEADCODE:%s:%d:%s", rel, line, fn.Name),
				Kind:     "deadcode",
				Severity: 2,
				Title:    "Unreachable function '" + fn.Name + "'",
				Detail:   "Function '" + fn.Name + "' is never called or referenced in package '" + pkgLabel + "'.",
				File:     absFile,
				RelFile:  rel,
				Line:     line,
				Col:      col,
				Symbol:   fn.Name,
			})
		}
	}
	return findings
}

type parsedPkgFile struct {
	absPath string
	relPath string
	isTest  bool
	src     []byte
	astFile *ast.File
}

type candidateDeadFunc struct {
	name     string
	pkgName  string
	absFile  string
	relFile  string
	line     int
	col      int
	declName *ast.Ident
	body     *ast.BlockStmt
}

func analyzeASTDeadcode(workspaceDir string) []Finding {
	dirPaths := make(map[string][]string)
	filesVisited := 0

	_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name(), path == workspaceDir) {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".go") {
			return nil
		}
		if info, statErr := d.Info(); statErr == nil && info.Size() > maxSafetyFileBytes {
			return nil
		}
		filesVisited++
		if filesVisited > maxSafetyWalkFiles {
			return filepath.SkipAll
		}
		absFile, absErr := filepath.Abs(path)
		if absErr != nil {
			absFile = path
		}
		dir := filepath.Dir(absFile)
		dirPaths[dir] = append(dirPaths[dir], absFile)
		return nil
	})

	dirs := make([]string, 0, len(dirPaths))
	for dir := range dirPaths {
		dirs = append(dirs, dir)
	}
	sort.Strings(dirs)

	var findings []Finding
	for _, dir := range dirs {
		fset := token.NewFileSet()
		var files []parsedPkgFile
		for _, absFile := range dirPaths[dir] {
			src, readErr := os.ReadFile(absFile)
			if readErr != nil || len(src) > maxSafetyFileBytes {
				continue
			}
			f, parseErr := parser.ParseFile(fset, absFile, src, parser.ParseComments)
			if parseErr != nil || f == nil {
				continue
			}
			files = append(files, parsedPkgFile{
				absPath: absFile,
				relPath: relPath(workspaceDir, absFile),
				isTest:  strings.HasSuffix(filepath.Base(absFile), safetyGoTestFileSuffix),
				src:     src,
				astFile: f,
			})
		}
		if len(files) == 0 {
			continue
		}
		var candidates []candidateDeadFunc
		declIdents := make(map[*ast.Ident]bool)

		for _, pf := range files {
			if pf.isTest {
				continue
			}
			pkgName := pf.astFile.Name.Name
			for _, decl := range pf.astFile.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Name == nil {
					continue
				}
				name := fn.Name.Name
				declIdents[fn.Name] = true
				if name == "init" || name == "main" || name == "_" || ast.IsExported(name) {
					continue
				}
				if hasDirectiveComment(pf.astFile, fn) {
					continue
				}
				pos := fset.Position(fn.Name.Pos())
				col := utf16Column(pf.src, pos)
				candidates = append(candidates, candidateDeadFunc{
					name:     name,
					pkgName:  pkgName,
					absFile:  pf.absPath,
					relFile:  pf.relPath,
					line:     pos.Line,
					col:      col,
					declName: fn.Name,
					body:     fn.Body,
				})
			}
		}

		if len(candidates) == 0 {
			continue
		}

		referenced := make(map[string]bool)
		for _, pf := range files {
			ast.Inspect(pf.astFile, func(n ast.Node) bool {
				ident, ok := n.(*ast.Ident)
				if !ok {
					return true
				}
				if declIdents[ident] {
					return true
				}
				referenced[ident.Name] = true
				return true
			})
		}

		for _, c := range candidates {
			if !referenced[c.name] {
				findings = append(findings, Finding{
					ID:       fmt.Sprintf("DEADCODE:%s:%d:%s", c.relFile, c.line, c.name),
					Kind:     "deadcode",
					Severity: 2,
					Title:    "Unreachable function '" + c.name + "'",
					Detail:   "Function '" + c.name + "' is never called or referenced in package '" + c.pkgName + "'.",
					File:     c.absFile,
					RelFile:  c.relFile,
					Line:     c.line,
					Col:      c.col,
					Symbol:   c.name,
				})
			}
		}
	}

	return findings
}

func hasDirectiveComment(f *ast.File, fn *ast.FuncDecl) bool {
	if fn.Doc != nil {
		for _, c := range fn.Doc.List {
			if strings.HasPrefix(c.Text, "//go:linkname") || strings.HasPrefix(c.Text, "//export ") || strings.HasPrefix(c.Text, "//export\t") {
				return true
			}
		}
	}
	for _, cg := range f.Comments {
		if cg.End() <= fn.Pos() && fn.Pos()-cg.End() < 256 {
			for _, c := range cg.List {
				if strings.HasPrefix(c.Text, "//go:linkname") || strings.HasPrefix(c.Text, "//export ") || strings.HasPrefix(c.Text, "//export\t") {
					return true
				}
			}
		}
	}
	return false
}

type govulnMessage struct {
	OSV     *govulnOSV     `json:"osv,omitempty"`
	Finding *govulnFinding `json:"finding,omitempty"`
}

type govulnOSV struct {
	ID      string   `json:"id"`
	Summary string   `json:"summary"`
	Details string   `json:"details"`
	Aliases []string `json:"aliases"`
}

type govulnFinding struct {
	OSV          string        `json:"osv"`
	FixedVersion string        `json:"fixed_version"`
	Trace        []govulnFrame `json:"trace"`
}

type govulnFrame struct {
	Module   string     `json:"module"`
	Package  string     `json:"package"`
	Function string     `json:"function"`
	Receiver string     `json:"receiver"`
	Position *govulnPos `json:"position,omitempty"`
}

type govulnPos struct {
	Filename string `json:"filename"`
	Line     int    `json:"line"`
	Column   int    `json:"column"`
}

func analyzeVulns(workspaceDir string) []Finding {
	if !canRunExternalGoTool(workspaceDir, maxExternalToolGoFiles) {
		return nil
	}
	bin, err := exec.LookPath("govulncheck")
	if err != nil || bin == "" {
		return nil
	}
	out, _ := runBoundedTool(context.Background(), workspaceDir, 6*time.Second, bin, "-json", "./...")
	if len(out) == 0 {
		return nil
	}
	return parseGovulncheckJSON(workspaceDir, out)
}

func parseGovulncheckJSON(workspaceDir string, data []byte) []Finding {
	osvMap := make(map[string]govulnOSV)
	var rawFindings []govulnFinding

	dec := json.NewDecoder(bytes.NewReader(data))
	for {
		var msg govulnMessage
		if err := dec.Decode(&msg); err != nil {
			if err == io.EOF {
				break
			}
			break
		}
		if msg.OSV != nil && msg.OSV.ID != "" {
			osvMap[msg.OSV.ID] = *msg.OSV
		}
		if msg.Finding != nil && msg.Finding.OSV != "" && len(msg.Finding.Trace) > 0 {
			rawFindings = append(rawFindings, *msg.Finding)
		}
	}

	var findings []Finding
	for _, gf := range rawFindings {
		hasSymbol := false
		for _, fr := range gf.Trace {
			if fr.Function != "" {
				hasSymbol = true
				break
			}
		}
		if !hasSymbol {
			continue
		}

		var chosenFrame *govulnFrame
		for i := len(gf.Trace) - 1; i >= 0; i-- {
			fr := &gf.Trace[i]
			if fr.Position != nil && fr.Position.Filename != "" {
				chosenFrame = fr
				cand := fr.Position.Filename
				if !filepath.IsAbs(cand) && workspaceDir != "" {
					cand = filepath.Join(workspaceDir, cand)
				}
				if workspaceDir == "" || strings.HasPrefix(filepath.Clean(cand), workspaceDir) {
					break
				}
			}
		}
		if chosenFrame == nil || chosenFrame.Position == nil {
			continue
		}

		absFile := chosenFrame.Position.Filename
		if !filepath.IsAbs(absFile) && workspaceDir != "" {
			absFile = filepath.Join(workspaceDir, absFile)
		}
		absFile = filepath.Clean(absFile)
		rel := relPath(workspaceDir, absFile)
		line := chosenFrame.Position.Line
		if line <= 0 {
			line = 1
		}
		col := chosenFrame.Position.Column
		if col <= 0 {
			col = 1
		}

		var chain []string
		for i := len(gf.Trace) - 1; i >= 0; i-- {
			fr := gf.Trace[i]
			if fr.Function == "" {
				continue
			}
			sym := fr.Function
			if fr.Receiver != "" {
				sym = fr.Receiver + "." + sym
			}
			if fr.Package != "" {
				sym = filepath.Base(fr.Package) + "." + sym
			}
			chain = append(chain, sym)
		}

		osv := osvMap[gf.OSV]
		title := fmt.Sprintf("Reachable vulnerability %s", gf.OSV)
		if osv.Summary != "" {
			title = fmt.Sprintf("%s: %s", gf.OSV, osv.Summary)
		}
		detail := osv.Details
		if detail == "" {
			detail = osv.Summary
		}
		if gf.FixedVersion != "" {
			if detail != "" {
				detail += fmt.Sprintf(" (Fixed in %s)", gf.FixedVersion)
			} else {
				detail = fmt.Sprintf("Fixed in %s", gf.FixedVersion)
			}
		}

		findings = append(findings, Finding{
			ID:        fmt.Sprintf("VULN:%s:%s:%d", gf.OSV, rel, line),
			Kind:      "vuln",
			Severity:  1,
			Title:     title,
			Detail:    detail,
			File:      absFile,
			RelFile:   rel,
			Line:      line,
			Col:       col,
			Symbol:    chosenFrame.Function,
			CallChain: chain,
		})
	}
	return findings
}

var stackFileLineRe = regexp.MustCompile(`^\s*(.+?\.go):(\d+)(?:\s+\+0x[0-9a-fA-F]+)?\s*$`)

type parsedStackFrame struct {
	symbol  string
	file    string
	absFile string
	relFile string
	line    int
}

func ParseRaceAndPanic(workspaceDir string, consoleOutput string) []Finding {
	absRoot := normalizeWorkspace(workspaceDir)
	lines := strings.Split(strings.ReplaceAll(consoleOutput, "\r\n", "\n"), "\n")

	var findings []Finding
	for i := 0; i < len(lines); i++ {
		trimmed := strings.TrimSpace(lines[i])

		if trimmed == "WARNING: DATA RACE" {
			blockEnd := i + 1
			for blockEnd < len(lines) {
				if strings.HasPrefix(strings.TrimSpace(lines[blockEnd]), "==================") {
					break
				}
				blockEnd++
			}
			if f, ok := parseRaceBlock(absRoot, lines[i+1:blockEnd]); ok {
				findings = append(findings, f)
			}
			i = blockEnd
			continue
		}

		if strings.HasPrefix(trimmed, prefixPanicColon) {
			msg := strings.TrimSpace(strings.TrimPrefix(trimmed, prefixPanicColon))
			blockEnd := i + 1
			for blockEnd < len(lines) {
				nextTrim := strings.TrimSpace(lines[blockEnd])
				if strings.HasPrefix(nextTrim, prefixPanicColon) || nextTrim == "WARNING: DATA RACE" || strings.HasPrefix(nextTrim, "FAIL\t") {
					break
				}
				blockEnd++
			}
			if f, ok := parsePanicBlock(absRoot, msg, lines[i+1:blockEnd]); ok {
				findings = append(findings, f)
			}
			i = blockEnd - 1
		}
	}

	return findings
}

func parseRaceBlock(workspaceDir string, blockLines []string) (Finding, bool) {
	var ops []string
	var frames []parsedStackFrame
	var pendingSymbol string

	for _, rawLine := range blockLines {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "Write at ") ||
			strings.HasPrefix(trimmed, "Read at ") ||
			strings.HasPrefix(trimmed, "Previous write at ") ||
			strings.HasPrefix(trimmed, "Previous read at ") {
			ops = append(ops, strings.TrimSuffix(trimmed, ":"))
			pendingSymbol = ""
			continue
		}
		if strings.HasPrefix(trimmed, "Goroutine ") {
			pendingSymbol = ""
			continue
		}

		if m := stackFileLineRe.FindStringSubmatch(rawLine); m != nil {
			lineNum, err := strconv.Atoi(m[2])
			if err != nil || lineNum <= 0 {
				continue
			}
			absFile, rel := resolveTracePath(workspaceDir, strings.TrimSpace(m[1]))
			frames = append(frames, parsedStackFrame{
				symbol:  cleanSymbol(pendingSymbol),
				file:    strings.TrimSpace(m[1]),
				absFile: absFile,
				relFile: rel,
				line:    lineNum,
			})
			pendingSymbol = ""
			continue
		}

		if !strings.HasSuffix(trimmed, ".go") && (strings.Contains(trimmed, "(") || strings.Contains(trimmed, ".")) {
			pendingSymbol = trimmed
		}
	}

	chosen, ok := chooseWorkspaceFrame(workspaceDir, frames)
	if !ok {
		return Finding{}, false
	}

	var chain []string
	for _, fr := range frames {
		if isRuntimeInternalFrame(fr) {
			continue
		}
		label := fmt.Sprintf("%s:%d", fr.relFile, fr.line)
		if fr.symbol != "" {
			label = fmt.Sprintf("%s (%s:%d)", fr.symbol, fr.relFile, fr.line)
		}
		chain = append(chain, label)
		if len(chain) >= 6 {
			break
		}
	}

	detail := "Concurrent unsynchronized memory access detected by Go race detector."
	if len(ops) > 0 {
		detail = strings.Join(ops, " vs. ")
	}

	return Finding{
		ID:        fmt.Sprintf("RACE:%s:%d", chosen.relFile, chosen.line),
		Kind:      "race",
		Severity:  1,
		Title:     "Data race detected",
		Detail:    detail,
		File:      chosen.absFile,
		RelFile:   chosen.relFile,
		Line:      chosen.line,
		Col:       1,
		Symbol:    chosen.symbol,
		CallChain: chain,
	}, true
}

func parsePanicBlock(workspaceDir string, msg string, blockLines []string) (Finding, bool) {
	var frames []parsedStackFrame
	var pendingSymbol string

	for _, rawLine := range blockLines {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "goroutine ") {
			pendingSymbol = ""
			continue
		}
		if m := stackFileLineRe.FindStringSubmatch(rawLine); m != nil {
			lineNum, err := strconv.Atoi(m[2])
			if err != nil || lineNum <= 0 {
				continue
			}
			absFile, rel := resolveTracePath(workspaceDir, strings.TrimSpace(m[1]))
			frames = append(frames, parsedStackFrame{
				symbol:  cleanSymbol(pendingSymbol),
				file:    strings.TrimSpace(m[1]),
				absFile: absFile,
				relFile: rel,
				line:    lineNum,
			})
			pendingSymbol = ""
			continue
		}
		if strings.Contains(trimmed, "(") {
			pendingSymbol = trimmed
		}
	}

	chosen, ok := chooseWorkspaceFrame(workspaceDir, frames)
	if !ok {
		return Finding{}, false
	}

	var chain []string
	for _, fr := range frames {
		if isRuntimeInternalFrame(fr) {
			continue
		}
		label := fmt.Sprintf("%s:%d", fr.relFile, fr.line)
		if fr.symbol != "" {
			label = fmt.Sprintf("%s (%s:%d)", fr.symbol, fr.relFile, fr.line)
		}
		chain = append(chain, label)
		if len(chain) >= 6 {
			break
		}
	}

	detail := fmt.Sprintf("Panic at %s:%d", chosen.relFile, chosen.line)
	if chosen.symbol != "" {
		detail = fmt.Sprintf("Panic in %s at %s:%d", chosen.symbol, chosen.relFile, chosen.line)
	}

	return Finding{
		ID:        fmt.Sprintf("PANIC:%s:%d:%s", chosen.relFile, chosen.line, msg),
		Kind:      "race",
		Severity:  1,
		Title:     "Runtime panic: " + msg,
		Detail:    detail,
		File:      chosen.absFile,
		RelFile:   chosen.relFile,
		Line:      chosen.line,
		Col:       1,
		Symbol:    chosen.symbol,
		CallChain: chain,
	}, true
}

func resolveTracePath(workspaceDir, rawPath string) (string, string) {
	cleaned := filepath.Clean(rawPath)
	if !filepath.IsAbs(cleaned) && workspaceDir != "" {
		abs := filepath.Clean(filepath.Join(workspaceDir, cleaned))
		return abs, relPath(workspaceDir, abs)
	}
	return cleaned, relPath(workspaceDir, cleaned)
}

func chooseWorkspaceFrame(workspaceDir string, frames []parsedStackFrame) (parsedStackFrame, bool) {
	if len(frames) == 0 {
		return parsedStackFrame{}, false
	}
	if workspaceDir != "" {
		prefix := workspaceDir + string(filepath.Separator)
		for _, fr := range frames {
			if fr.absFile == workspaceDir || strings.HasPrefix(fr.absFile, prefix) {
				return fr, true
			}
		}
	}
	for _, fr := range frames {
		if !isRuntimeInternalFrame(fr) {
			return fr, true
		}
	}
	return frames[0], true
}

func isRuntimeInternalFrame(fr parsedStackFrame) bool {
	slashed := filepath.ToSlash(fr.absFile)
	if strings.Contains(slashed, "/src/runtime/") || strings.Contains(slashed, "/src/testing/") {
		return true
	}
	return strings.HasPrefix(fr.symbol, "runtime.") || strings.HasPrefix(fr.symbol, "testing.")
}

func cleanSymbol(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if idx := strings.LastIndex(trimmed, "("); idx > 0 {
		return trimmed[:idx]
	}
	return trimmed
}

func deduplicateAndSort(findings []Finding) []Finding {
	seen := make(map[string]bool, len(findings))
	out := make([]Finding, 0, len(findings))

	for _, f := range findings {
		key := fmt.Sprintf("%s|%s|%d|%s", f.Kind, f.File, f.Line, f.Title)
		if f.Kind == "deadcode" && f.Symbol != "" {
			key = fmt.Sprintf("deadcode|%s|%s", f.File, f.Symbol)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, f)
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Severity != out[j].Severity {
			return out[i].Severity < out[j].Severity
		}
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		if out[i].RelFile != out[j].RelFile {
			return out[i].RelFile < out[j].RelFile
		}
		if out[i].Line != out[j].Line {
			return out[i].Line < out[j].Line
		}
		return out[i].Title < out[j].Title
	})

	return out
}

const (
	CapabilityNetwork    = "CAPABILITY_NETWORK"
	CapabilityExec       = "CAPABILITY_EXEC"
	CapabilityFilesystem = "CAPABILITY_FILESYSTEM"
	CapabilityUnsafe     = "CAPABILITY_UNSAFE"
	CapabilityReflect    = "CAPABILITY_REFLECT"
)

func scanPackageCapabilities(workspaceDir string, files []parsedPkgFile, fset *token.FileSet) []Finding {
	if fset == nil {
		fset = token.NewFileSet()
	}
	if len(files) == 0 && workspaceDir != "" {
		filesVisited := 0
		_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				if shouldSkipDir(d.Name(), path == workspaceDir) {
					return filepath.SkipDir
				}
				return nil
			}
			name := d.Name()
			if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, safetyGoTestFileSuffix) {
				return nil
			}
			if info, statErr := d.Info(); statErr == nil && info.Size() > maxSafetyFileBytes {
				return nil
			}
			filesVisited++
			if filesVisited > maxSafetyWalkFiles {
				return filepath.SkipAll
			}
			src, readErr := os.ReadFile(path)
			if readErr != nil || len(src) > maxSafetyFileBytes {
				return nil
			}
			f, parseErr := parser.ParseFile(fset, path, src, 0)
			if parseErr != nil || f == nil {
				return nil
			}
			absFile, absErr := filepath.Abs(path)
			if absErr != nil {
				absFile = path
			}
			files = append(files, parsedPkgFile{
				absPath: absFile,
				relPath: relPath(workspaceDir, absFile),
				isTest:  false,
				src:     src,
				astFile: f,
			})
			return nil
		})
	}

	var findings []Finding
	seen := make(map[string]bool)

	type capFindingSpec struct {
		capType string
		title   string
		detail  string
		absFile string
		rel     string
		line    int
		col     int
		symbol  string
	}

	addCapFinding := func(spec capFindingSpec) {
		line := spec.line
		col := spec.col
		if line <= 0 {
			line = 1
		}
		if col <= 0 {
			col = 1
		}
		dedupKey := fmt.Sprintf("%s|%d|%s", spec.absFile, line, spec.capType)
		if seen[dedupKey] {
			return
		}
		seen[dedupKey] = true
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("%s:%s:%d", spec.capType, spec.rel, line),
			Kind:     "capability",
			Severity: 3,
			Title:    spec.title,
			Detail:   spec.detail,
			File:     spec.absFile,
			RelFile:  spec.rel,
			Line:     line,
			Col:      col,
			Symbol:   spec.symbol,
		})
	}

	for _, pf := range files {
		if pf.isTest || strings.HasSuffix(pf.absPath, safetyGoTestFileSuffix) || pf.astFile == nil {
			continue
		}
		pkgName := pf.astFile.Name.Name
		rel := pf.relPath
		if rel == "" {
			rel = relPath(workspaceDir, pf.absPath)
		}

		for _, imp := range pf.astFile.Imports {
			if imp == nil || imp.Path == nil {
				continue
			}
			impPath, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				impPath = strings.Trim(imp.Path.Value, "\"`")
			}
			switch impPath {
			case "unsafe":
				pos := fset.Position(imp.Pos())
				col := utf16Column(pf.src, pos)
				addCapFinding(capFindingSpec{
					capType: CapabilityUnsafe,
					title:   fmt.Sprintf("Unsafe import in %s", pkgName),
					detail:  "Imports package unsafe, which can bypass Go memory and type safety guarantees.",
					absFile: pf.absPath,
					rel:     rel,
					line:    pos.Line,
					col:     col,
					symbol:  pkgName,
				})
			case "C":
				pos := fset.Position(imp.Pos())
				col := utf16Column(pf.src, pos)
				addCapFinding(capFindingSpec{
					capType: CapabilityUnsafe,
					title:   fmt.Sprintf("cgo (\"C\") import in %s", pkgName),
					detail:  "Enables cgo foreign function interface to invoke native C code outside the Go runtime.",
					absFile: pf.absPath,
					rel:     rel,
					line:    pos.Line,
					col:     col,
					symbol:  pkgName,
				})
			}
		}

		inspectScope := func(node ast.Node, scopeSymbol string) {
			targetLabel := scopeSymbol
			if targetLabel == "" {
				targetLabel = pkgName
			}
			ast.Inspect(node, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				pkgIdent, ok := sel.X.(*ast.Ident)
				if !ok {
					return true
				}
				pkg := pkgIdent.Name
				fn := sel.Sel.Name
				pos := fset.Position(call.Pos())
				col := utf16Column(pf.src, pos)

				switch pkg {
				case "net":
					if strings.HasPrefix(fn, "Dial") || strings.HasPrefix(fn, "Listen") {
						addCapFinding(capFindingSpec{
							capType: CapabilityNetwork,
							title:   fmt.Sprintf("Network %s.%s call in %s", pkg, fn, targetLabel),
							detail:  "Opens network socket or performs outbound/inbound network I/O.",
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "http":
					if fn == "Get" || fn == "Post" || strings.HasPrefix(fn, "NewRequest") || strings.HasPrefix(fn, "ListenAndServe") {
						addCapFinding(capFindingSpec{
							capType: CapabilityNetwork,
							title:   fmt.Sprintf("Network %s.%s call in %s", pkg, fn, targetLabel),
							detail:  "Opens network socket or performs outbound/inbound network I/O.",
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "exec":
					if strings.HasPrefix(fn, "Command") {
						addCapFinding(capFindingSpec{
							capType: CapabilityExec,
							title:   fmt.Sprintf("External process %s.%s call in %s", pkg, fn, targetLabel),
							detail:  msgSpawnsExternalProcess,
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "syscall":
					if fn == "Exec" || fn == "ForkExec" {
						addCapFinding(capFindingSpec{
							capType: CapabilityExec,
							title:   fmt.Sprintf("External process %s.%s call in %s", pkg, fn, targetLabel),
							detail:  msgSpawnsExternalProcess,
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "os":
					if fn == "StartProcess" {
						addCapFinding(capFindingSpec{
							capType: CapabilityExec,
							title:   fmt.Sprintf("External process %s.%s call in %s", pkg, fn, targetLabel),
							detail:  msgSpawnsExternalProcess,
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					} else if fn == "WriteFile" || fn == "Remove" || fn == "RemoveAll" || fn == "Create" || fn == "OpenFile" {
						addCapFinding(capFindingSpec{
							capType: CapabilityFilesystem,
							title:   fmt.Sprintf("Filesystem %s.%s call in %s", pkg, fn, targetLabel),
							detail:  "Creates, modifies, or deletes files on the local filesystem.",
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "unsafe":
					if fn == "Pointer" || fn == "Slice" {
						addCapFinding(capFindingSpec{
							capType: CapabilityUnsafe,
							title:   fmt.Sprintf("Unsafe %s.%s call in %s", pkg, fn, targetLabel),
							detail:  "Performs low-level unsafe pointer or slice memory manipulation.",
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				case "reflect":
					if fn == "ValueOf" || fn == "New" {
						addCapFinding(capFindingSpec{
							capType: CapabilityReflect,
							title:   fmt.Sprintf("Reflection %s.%s call in %s", pkg, fn, targetLabel),
							detail:  "Uses runtime reflection to inspect or construct dynamic values.",
							absFile: pf.absPath,
							rel:     rel,
							line:    pos.Line,
							col:     col,
							symbol:  scopeSymbol,
						})
					}
				}
				return true
			})
		}

		for _, decl := range pf.astFile.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				if d.Body != nil {
					inspectScope(d.Body, d.Name.Name)
				}
			case *ast.GenDecl:
				if d.Tok != token.IMPORT {
					inspectScope(d, "")
				}
			}
		}
	}

	return findings
}

type golangciLintOutput struct {
	Issues []golangciLintIssue `json:"Issues"`
}

type golangciLintIssue struct {
	FromLinter string          `json:"FromLinter"`
	Text       string          `json:"Text"`
	Severity   string          `json:"Severity"`
	Pos        golangciLintPos `json:"Pos"`
}

type golangciLintPos struct {
	Filename string `json:"Filename"`
	Line     int    `json:"Line"`
	Column   int    `json:"Column"`
}

func runGolangCILint(ctx context.Context, workspaceDir string) []Finding {
	if !canRunExternalGoTool(workspaceDir, maxExternalToolGoFiles) {
		return nil
	}
	bin, err := exec.LookPath("golangci-lint")
	if err != nil || bin == "" {
		return nil
	}
	out, _ := runBoundedTool(ctx, workspaceDir, 5*time.Second, bin, "run", "--concurrency=2", "--out-format=json", "./...")
	if len(out) == 0 {
		return nil
	}
	return parseGolangCILintJSON(workspaceDir, out)
}

func decodeGolangCILintOutput(data []byte) (golangciLintOutput, bool) {
	var parsed golangciLintOutput
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return parsed, false
	}
	if idx := bytes.IndexByte(trimmed, '{'); idx > 0 {
		trimmed = trimmed[idx:]
	}
	if json.Unmarshal(trimmed, &parsed) == nil {
		return parsed, true
	}
	for _, line := range bytes.Split(trimmed, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 || line[0] != '{' || !bytes.Contains(line, []byte(`"Issues"`)) {
			continue
		}
		parsed = golangciLintOutput{}
		if json.Unmarshal(line, &parsed) == nil {
			return parsed, true
		}
	}
	return golangciLintOutput{}, false
}

func parseGolangCILintJSON(workspaceDir string, data []byte) []Finding {
	parsed, ok := decodeGolangCILintOutput(data)
	if !ok {
		return nil
	}

	var findings []Finding
	for _, issue := range parsed.Issues {
		if issue.Pos.Filename == "" {
			continue
		}
		absFile := issue.Pos.Filename
		if !filepath.IsAbs(absFile) && workspaceDir != "" {
			absFile = filepath.Join(workspaceDir, absFile)
		}
		absFile = filepath.Clean(absFile)
		rel := relPath(workspaceDir, absFile)
		line := issue.Pos.Line
		if line <= 0 {
			line = 1
		}
		col := issue.Pos.Column
		if col <= 0 {
			col = 1
		}
		linterName := strings.TrimSpace(issue.FromLinter)
		if linterName == "" {
			linterName = "lint"
		}
		detail := strings.TrimSpace(issue.Text)
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("GOLANGCI:%s:%s:%d", linterName, rel, line),
			Kind:     "hazard",
			Severity: 2,
			Title:    "[golangci-lint] " + linterName,
			Detail:   detail,
			File:     absFile,
			RelFile:  rel,
			Line:     line,
			Col:      col,
		})
	}
	return findings
}

func hasExistingFinding(existing []Finding, candidate Finding) bool {
	for _, f := range existing {
		if f.File == candidate.File && f.Line == candidate.Line {
			if f.Title == candidate.Title || (candidate.Detail != "" && f.Detail == candidate.Detail) {
				return true
			}
		}
	}
	return false
}

func formatSummary(findings []Finding) string {
	if len(findings) == 0 {
		return "No safety findings across static hazard analysis, dead code detection, vulnerability scan, capability audit, and runtime traces."
	}

	var vulns, races, hazards, dead, capabilities int
	for _, f := range findings {
		switch f.Kind {
		case "vuln":
			vulns++
		case "race":
			races++
		case "hazard":
			hazards++
		case "deadcode":
			dead++
		case "capability":
			capabilities++
		}
	}

	var parts []string
	if vulns > 0 {
		parts = append(parts, fmt.Sprintf("%d vuln", vulns))
	}
	if races > 0 {
		parts = append(parts, fmt.Sprintf("%d race/panic", races))
	}
	if hazards > 0 {
		if hazards == 1 {
			parts = append(parts, "1 hazard")
		} else {
			parts = append(parts, fmt.Sprintf("%d hazards", hazards))
		}
	}
	if dead > 0 {
		parts = append(parts, fmt.Sprintf("%d deadcode", dead))
	}
	if capabilities > 0 {
		if capabilities == 1 {
			parts = append(parts, "1 capability")
		} else {
			parts = append(parts, fmt.Sprintf("%d capabilities", capabilities))
		}
	}
	return fmt.Sprintf("%d findings (%s)", len(findings), strings.Join(parts, ", "))
}
