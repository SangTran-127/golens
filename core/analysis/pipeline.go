package analysis

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

var OverlayReader func(path string) ([]byte, error)

const (
	analyzerSourceName      = "golens-safety"
	maxAnalyzerFileIssues   = 100
	maxAnalyzerMessageBytes = 2000

	CategoryConcurrency    = "concurrency"
	CategoryResourceSafety = "resourceSafety"
	CategoryErrorHandling  = "errorHandling"
	CategorySecurity       = "security"
	CategoryModernization  = "modernization"
)

var generatedFileHeaderPattern = regexp.MustCompile(`(?m)^// Code generated .* DO NOT EDIT\.\s*$`)

type AnalyzerDiagnostic struct {
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	EndLine  int    `json:"endLine"`
	EndCol   int    `json:"endCol"`
	Severity int    `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
	Code     string `json:"code"`
}

type PackageAnalyzeResult struct {
	Status string                          `json:"status"`
	Error  string                          `json:"error,omitempty"`
	Files  map[string][]AnalyzerDiagnostic `json:"files"`
}

type parsedPackageFile struct {
	path    string
	relFile string
	name    string
	isTest  bool
	src     string
	lines   []string
	fset    *token.FileSet
	file    *ast.File
}

func (pf *parsedPackageFile) lineAt(line int) string {
	if line >= 1 && line <= len(pf.lines) {
		return strings.TrimSpace(pf.lines[line-1])
	}
	return ""
}

func RunPackageAnalyzersJSON(workspaceRoot, packageDir, disabledCSV string) string {
	res := runPackageAnalyzers(workspaceRoot, packageDir, disabledCSV)
	if res.Files == nil {
		res.Files = map[string][]AnalyzerDiagnostic{}
	}
	b, err := json.Marshal(res)
	if err != nil {
		return `{"status":"error","error":"failed to marshal analyzer result","files":{}}`
	}
	return string(b)
}

func runPackageAnalyzers(workspaceRoot, packageDir, disabledCSV string) PackageAnalyzeResult {
	res := PackageAnalyzeResult{
		Status: "ok",
		Files:  map[string][]AnalyzerDiagnostic{},
	}

	packageDir = strings.TrimSpace(packageDir)
	if packageDir == "" {
		res.Status = "unavailable"
		return res
	}

	absPkgDir, err := filepath.Abs(packageDir)
	if err != nil {
		res.Status = "error"
		res.Error = err.Error()
		return res
	}
	st, err := os.Stat(absPkgDir)
	if err != nil || !st.IsDir() {
		res.Status = "error"
		if err != nil {
			res.Error = err.Error()
		} else {
			res.Error = "package path is not a directory"
		}
		return res
	}

	var absWorkspace string
	if strings.TrimSpace(workspaceRoot) != "" {
		if abs, wErr := filepath.Abs(strings.TrimSpace(workspaceRoot)); wErr == nil {
			absWorkspace = abs
		}
	}

	entries, err := os.ReadDir(absPkgDir)
	if err != nil {
		res.Status = "error"
		res.Error = err.Error()
		return res
	}

	disabled := parseDisabledCategories(disabledCSV)
	allDisabled := disabled[CategoryConcurrency] &&
		disabled[CategoryResourceSafety] &&
		disabled[CategoryErrorHandling] &&
		disabled[CategorySecurity]
	inVendor := isVendorDirectory(absPkgDir, absWorkspace)

	type rawCandidate struct {
		path string
		name string
	}
	var candidates []rawCandidate

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".go") {
			continue
		}
		absPath := filepath.Join(absPkgDir, name)
		res.Files[absPath] = []AnalyzerDiagnostic{}

		if allDisabled || inVendor {
			continue
		}
		if strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".") {
			continue
		}
		if info, infoErr := e.Info(); infoErr == nil && info.Size() > workspaceScanMaxFileBytes {
			continue
		}
		candidates = append(candidates, rawCandidate{path: absPath, name: name})
	}

	if len(candidates) == 0 {
		return res
	}

	parsed := make([]*parsedPackageFile, len(candidates))
	runIndexedParallel(len(candidates), func(i int) {
		cand := candidates[i]
		data, readErr := readPackageFileBytes(cand.path)
		if readErr != nil || len(bytes.TrimSpace(data)) == 0 {
			return
		}
		if isGeneratedGoBytes(data) {
			return
		}
		fset := token.NewFileSet()
		astFile, _ := parser.ParseFile(fset, cand.path, data, parser.ParseComments)
		if astFile == nil {
			return
		}
		srcStr := string(data)
		rawLines := strings.Split(srcStr, "\n")
		for idx := range rawLines {
			rawLines[idx] = strings.TrimSuffix(rawLines[idx], "\r")
		}
		relFile := cand.name
		if absWorkspace != "" {
			if rel, relErr := filepath.Rel(absWorkspace, cand.path); relErr == nil && rel != "" && !strings.HasPrefix(rel, "..") {
				relFile = filepath.ToSlash(rel)
			}
		}
		parsed[i] = &parsedPackageFile{
			path:    cand.path,
			relFile: relFile,
			name:    cand.name,
			isTest:  strings.HasSuffix(cand.name, "_test.go"),
			src:     srcStr,
			lines:   rawLines,
			fset:    fset,
			file:    astFile,
		}
	})

	var activeFiles []*parsedPackageFile
	for _, pf := range parsed {
		if pf != nil {
			activeFiles = append(activeFiles, pf)
		}
	}
	if len(activeFiles) == 0 {
		return res
	}

	var syncStructs map[string]string
	if !disabled[CategoryConcurrency] {
		syncStructs = make(map[string]string)
		for _, pf := range activeFiles {
			collectSyncLockStructs(pf.fset, pf.file, syncStructs)
		}
	}

	var stringerSet map[string]bool
	if !disabled[CategorySecurity] {
		stringerSet = make(map[string]bool)
		for _, pf := range activeFiles {
			for _, recv := range collectStringerReceivers(pf.file) {
				stringerSet[recv] = true
			}
		}
	}

	perFileDiags := make([][]AnalyzerDiagnostic, len(activeFiles))
	runIndexedParallel(len(activeFiles), func(i int) {
		perFileDiags[i] = analyzeSingleParsedFile(activeFiles[i], disabled, syncStructs, stringerSet)
	})

	for i, pf := range activeFiles {
		if len(perFileDiags[i]) > 0 {
			res.Files[pf.path] = perFileDiags[i]
		}
	}

	return res
}

func analyzeSingleParsedFile(
	pf *parsedPackageFile,
	disabled map[string]bool,
	syncStructs map[string]string,
	stringerSet map[string]bool,
) []AnalyzerDiagnostic {
	type dedupKey struct {
		line    int
		message string
	}
	seen := make(map[dedupKey]bool)
	diags := make([]AnalyzerDiagnostic, 0)

	addDiag := func(oneBasedLine, oneBasedCol, severity int, message, category string) {
		if len(diags) >= maxAnalyzerFileIssues {
			return
		}
		msg := strings.TrimSpace(message)
		if msg == "" {
			return
		}
		if len(msg) > maxAnalyzerMessageBytes {
			msg = msg[:maxAnalyzerMessageBytes]
		}
		line0 := max(oneBasedLine, 1) - 1
		key := dedupKey{line: line0, message: msg}
		if seen[key] {
			return
		}
		seen[key] = true

		text := ""
		if line0 < len(pf.lines) {
			text = pf.lines[line0]
		}
		startByte, endByte := analyzerTokenRange(text, oneBasedCol)

		sev := 2
		if severity == 1 {
			sev = 1
		}

		diags = append(diags, AnalyzerDiagnostic{
			Line:     line0,
			Col:      analyzerUTF16Len(text[:startByte]),
			EndLine:  line0,
			EndCol:   analyzerUTF16Len(text[:endByte]),
			Severity: sev,
			Message:  msg,
			Source:   analyzerSourceName,
			Code:     category,
		})
	}

	if !disabled[CategoryConcurrency] {
		if strings.Contains(pf.src, "context") || strings.Contains(pf.src, "go ") {
			conc := inspectConcurrencyAST(pf.fset, pf.file, pf.path, pf.src)
			for _, f := range conc.Findings {
				if pf.isTest && (f.Kind == "context_background" || f.Kind == "context_background_in_func" || f.Kind == "unbounded_goroutine") {
					continue
				}
				msg := f.Summary
				if msg == "" {
					msg = f.Suggestion
				}
				sev := 2
				if f.Severity == "error" || f.Severity == "high" {
					sev = 1
				}
				addDiag(f.Line, 0, sev, msg, CategoryConcurrency)
			}
		}

		if strings.Contains(pf.src, "NewTicker") || strings.Contains(pf.src, "time.After") {
			for _, tf := range inspectASTFileTimeSafety(pf.fset, pf.file, pf.path, pf.src) {
				if tf.Category == "TICKER_UNSTOPPED" || tf.Category == "TIME_AFTER_LOOP" {
					addDiag(tf.Line, 0, 2, tf.Message, CategoryConcurrency)
				}
			}
		}

		if strings.Contains(pf.src, "sync.") || len(syncStructs) > 0 {
			for _, sf := range inspectASTFileSyncSafety(pf.fset, pf.file, pf.path, pf.src, syncStructs) {
				sev := 2
				if sf.Severity == "error" {
					sev = 1
				}
				addDiag(sf.Line, 0, sev, sf.Message, CategoryConcurrency)
			}
		}

		if strings.Contains(pf.src, "go ") {
			for _, decl := range pf.file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Body == nil {
					continue
				}
				fnName := ""
				if fn.Name != nil {
					fnName = fn.Name.Name
				}
				for _, gi := range inspectFuncGoroutineSafety(pf.fset, fn.Body, fnName, pf.lineAt) {
					if gi.Kind == "WAITGROUP_ADD_INSIDE_GO" || gi.Kind == "LOOP_VAR_CAPTURE" {
						sev := 2
						if gi.Severity == "error" {
							sev = 1
						}
						addDiag(gi.Line, gi.Column, sev, gi.Message, CategoryConcurrency)
					}
				}
			}
		}

		if pf.isTest && strings.Contains(pf.src, "testing/synctest") {
			for _, si := range collectSynctestBubbleCaptureIssues(pf.fset, pf.file, pf.src) {
				addDiag(si.Line, si.Column, 1, si.Message, CategoryConcurrency)
			}
		}
	}

	wantResource := !disabled[CategoryResourceSafety]
	wantSecurity := !disabled[CategorySecurity]

	if (wantResource || wantSecurity) && (strings.Contains(pf.src, "http") || strings.Contains(pf.src, "tls") || strings.Contains(pf.src, "InsecureSkipVerify")) {
		var httpRep HTTPSafetyReport
		fillHTTPSafetyReport(&httpRep, pf.fset, pf.file, pf.src)
		for _, iss := range httpRep.Issues {
			sev := 2
			if iss.Severity == "error" || iss.Severity == "high" {
				sev = 1
			}
			switch iss.Kind {
			case "HTTP_BODY_UNCLOSED":
				if wantResource {
					addDiag(iss.Line, iss.Column, sev, iss.Message, CategoryResourceSafety)
				}
			case "HTTP_DEFAULT_CLIENT", "HTTP_SERVER_NO_TIMEOUT":
				if wantResource && !pf.isTest {
					addDiag(iss.Line, iss.Column, 2, iss.Message, CategoryResourceSafety)
				}
			case "TLS_INSECURE_SKIP_VERIFY":
				if wantSecurity && !pf.isTest {
					addDiag(iss.Line, iss.Column, sev, iss.Message, CategorySecurity)
				}
			}
		}
	}

	if (wantResource || wantSecurity) && (strings.Contains(pf.src, "Open") || strings.Contains(pf.src, "Create") || strings.Contains(pf.src, "Query") || strings.Contains(pf.src, "Exec") || strings.Contains(pf.src, "Command")) {
		for _, rf := range inspectASTFileResourceAndInjection(pf.fset, pf.file, pf.path, pf.src) {
			sev := 2
			if rf.Severity == "high" || rf.Severity == "error" {
				sev = 1
			}
			switch rf.Kind {
			case "RESOURCE_UNCLOSED":
				if wantResource {
					addDiag(rf.Line, rf.Col, sev, rf.Message, CategoryResourceSafety)
				}
			case "SQL_INJECTION", "CMD_INJECTION":
				if wantSecurity && !pf.isTest {
					addDiag(rf.Line, rf.Col, sev, rf.Message, CategorySecurity)
				}
			}
		}
	}

	if wantResource && !pf.isTest && (strings.Contains(pf.src, ".Begin(") || strings.Contains(pf.src, ".BeginTx(")) {
		for _, txIssue := range inspectASTFileSQLTransactions(pf.fset, pf.file, pf.src) {
			addDiag(txIssue.Line, txIssue.Col, 2, txIssue.Message, CategoryResourceSafety)
		}
	}

	if !disabled[CategoryErrorHandling] && !pf.isTest {
		if strings.Contains(pf.src, "Errorf") || strings.Contains(pf.src, "err") {
			for _, ef := range inspectASTFileErrorWrapping(pf.fset, pf.file, pf.path, pf.src) {
				addDiag(ef.Line, ef.Col, 2, ef.Message, CategoryErrorHandling)
			}
		}
	}

	if wantSecurity && !pf.isTest {
		if strings.Contains(pf.src, "struct") || strings.Contains(pf.src, "log") || strings.Contains(pf.src, "slog") || strings.Contains(pf.src, "Print") {
			for _, sf := range inspectASTFileSensitiveData(pf.fset, pf.file, pf.path, pf.relFile, stringerSet) {
				if sf.Kind == "sensitive_tag" || sf.Kind == "sensitive_log" {
					msg := sf.Detail
					if msg == "" {
						msg = sf.Title
					}
					addDiag(sf.Line, 0, 2, msg, CategorySecurity)
				}
			}
		}

		if strings.Contains(pf.src, "md5") || strings.Contains(pf.src, "sha1") || strings.Contains(pf.src, "des") || strings.Contains(pf.src, "rc4") || strings.Contains(pf.src, "math/rand") || strings.Contains(pf.src, "hmac") || strings.Contains(pf.src, "token") || strings.Contains(pf.src, "secret") || strings.Contains(pf.src, "bytes.Equal") || strings.Contains(pf.src, ".Sum(") || strings.Contains(pf.src, "Signature") || strings.Contains(pf.src, "Digest") {
			for _, ci := range collectCryptoSafetyIssuesInAST(pf.fset, pf.file, pf.src) {
				sev := 2
				if ci.Severity == "error" || ci.Severity == "high" {
					sev = 1
				}
				addDiag(ci.Line, ci.Column, sev, ci.Message, CategorySecurity)
			}
		}

		if strings.Contains(pf.src, "Join(") || strings.Contains(pf.src, "os.Open") || strings.Contains(pf.src, "os.ReadFile") || strings.Contains(pf.src, "os.WriteFile") || strings.Contains(pf.src, "os.Create") || strings.Contains(pf.src, "os.Remove") || strings.Contains(pf.src, "os.MkdirAll") || strings.Contains(pf.src, "ServeFile") {
			for _, pt := range inspectASTFilePathTraversal(pf.fset, pf.file, pf.src) {
				addDiag(pt.Line, pt.Col, 1, pt.Message, CategorySecurity)
			}
		}
	}

	sort.SliceStable(diags, func(i, j int) bool {
		if diags[i].Line != diags[j].Line {
			return diags[i].Line < diags[j].Line
		}
		if diags[i].Col != diags[j].Col {
			return diags[i].Col < diags[j].Col
		}
		return diags[i].Code < diags[j].Code
	})

	return diags
}

func parseDisabledCategories(csv string) map[string]bool {
	out := make(map[string]bool)
	for _, part := range strings.Split(csv, ",") {
		k := strings.TrimSpace(part)
		if k == "" {
			continue
		}
		out[k] = true
		switch strings.ToLower(k) {
		case "concurrency":
			out[CategoryConcurrency] = true
		case "resourcesafety", "resource_safety", "resource":
			out[CategoryResourceSafety] = true
		case "errorhandling", "error_handling", "errwrap":
			out[CategoryErrorHandling] = true
		case "security":
			out[CategorySecurity] = true
		case "modernization", "modernize":
			out[CategoryModernization] = true
		}
	}
	return out
}

func readPackageFileBytes(absPath string) ([]byte, error) {
	if OverlayReader != nil {
		if data, err := OverlayReader(absPath); err == nil && data != nil {
			return data, nil
		}
	}
	return os.ReadFile(absPath)
}

func isGeneratedGoBytes(data []byte) bool {
	head := data
	if len(head) > 4096 {
		head = head[:4096]
	}
	return generatedFileHeaderPattern.Match(head)
}

func isVendorDirectory(absDir, absWorkspace string) bool {
	rel := absDir
	if absWorkspace != "" {
		if r, err := filepath.Rel(absWorkspace, absDir); err == nil && !strings.HasPrefix(r, "..") {
			rel = r
		}
	}
	for _, seg := range strings.Split(filepath.ToSlash(rel), "/") {
		if seg == "vendor" {
			return true
		}
	}
	return false
}

func analyzerTokenRange(text string, column int) (int, int) {
	if text == "" {
		return 0, 0
	}
	if column <= 0 || column > len(text) {
		start := len(text) - len(strings.TrimLeftFunc(text, unicode.IsSpace))
		end := len(strings.TrimRightFunc(text, unicode.IsSpace))
		if end <= start {
			return 0, len(text)
		}
		return start, end
	}
	start := column - 1
	for start > 0 && !utf8.RuneStart(text[start]) {
		start--
	}
	end := start
	for end < len(text) {
		r, size := utf8.DecodeRuneInString(text[end:])
		if !isAnalyzerTokenRune(r) {
			break
		}
		end += size
	}
	if end > start {
		return start, end
	}
	begin := start
	for begin > 0 {
		r, size := utf8.DecodeLastRuneInString(text[:begin])
		if !isAnalyzerTokenRune(r) {
			break
		}
		begin -= size
	}
	if begin < start {
		return begin, start
	}
	_, size := utf8.DecodeRuneInString(text[start:])
	return start, start + size
}

func isAnalyzerTokenRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '.'
}

func analyzerUTF16Len(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}
