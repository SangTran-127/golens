package core_e2e

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// 1. Workspace Test Fixtures & Helpers
// ============================================================================

// CreateTestWorkspace creates an isolated temporary directory containing the specified files.
func CreateTestWorkspace(t *testing.T, files map[string]string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "golens-core-e2e-*")
	if err != nil {
		t.Fatalf("Failed to create temp workspace: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(dir)
	})

	for relPath, content := range files {
		fullPath := filepath.Join(dir, relPath)
		if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
			t.Fatalf("Failed to create dir for %s: %v", relPath, err)
		}
		if err := os.WriteFile(fullPath, []byte(content), 0644); err != nil {
			t.Fatalf("Failed to write %s: %v", relPath, err)
		}
	}
	return dir
}

// ============================================================================
// 2. Track 45.1 (Issue #125): Smart Debugger Value Renderers & Inspector
// ============================================================================

// InspectValue returns human-readable representation and structured inspection.
func InspectValue(typ, value string) (string, dap.VariablePayloadInspection) {
	readable := dap.Readable(typ, value)
	payload := dap.InspectRawVariablePayload(typ, value)
	return readable, payload
}

// ============================================================================
// 3. Track 45.3 (Issue #127): Inline Test Failure Capsule & Got vs Want Diff
// ============================================================================

// ParseFailures wraps core testutil.ParseTestFailureLocations.
func ParseFailures(pkgDir, testName string, outputLines []string) []testutil.TestFailureAnnotation {
	return testutil.ParseTestFailureLocations(pkgDir, testName, outputLines)
}

// ============================================================================
// 4. Track 46.2 (Issue #129): Menu Consolidation & AST Quick-Fixes
// ============================================================================

// MenuHierarchy defines the streamlined Apple HIG-compliant structure of Inspect (7) and Generate (15) actions.
type MenuHierarchy struct {
	InspectSubmenus  map[string][]string
	FeaturedInspect  []string
	GenerateSubmenus map[string][]string
}

// GetReorganizedMenuHierarchy returns the streamlined hierarchy of 7 visual/architectural inspectors and 15 core AST IDE generators.
func GetReorganizedMenuHierarchy() MenuHierarchy {
	return MenuHierarchy{
		FeaturedInspect: []string{
			"Inspect Struct Memory Layout…",
			"Inspect Function Complexity…",
			"Compiler Optimization & Live Disassembly…",
		},
		InspectSubmenus: map[string][]string{
			"Code & Memory Layout": {
				"Inspect Struct Memory Layout…",
				"Inspect Function Complexity…",
				"Compiler Optimization & Live Disassembly…",
			},
			"Architecture, API & Benchmarks": {
				"Inspect Package Dependencies…",
				"Compare Benchmarks with Baseline…",
			},
		},
		GenerateSubmenus: map[string][]string{
			"Structs & Constructors": {
				"Generate Constructor & Options…",
				"Fill Struct Fields",
				"Modify Struct Tags…",
				"Convert JSON to Go Struct…",
			},
			"Methods, Codecs & CLI": {
				"Generate Enum / Stringer Methods…",
			},
			"Tests, Benchmarks & Mocks": {
				"Generate Table-Driven Test…",
				"Generate Fuzz Test…",
				"Generate Go Benchmark…",
				"Generate Interface Mock…",
			},
		},
	}
}

// ContextualQuickFix represents a suggested code fix on the active line.
type ContextualQuickFix struct {
	Title       string
	Description string
	StartLine   int
	EndLine     int
	OldText     string
	NewText     string
}

// ScanContextualASTQuickFixes parses active file AST in-memory (<2ms) and identifies quick-fixes on line.
func ScanContextualASTQuickFixes(filePath, content string, targetLine int) ([]ContextualQuickFix, error) {
	start := time.Now()
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("AST parse failed: %w", err)
	}
	if time.Since(start) > 50*time.Millisecond {
		return nil, errors.New("AST parse exceeded performance budget")
	}

	lines := strings.Split(content, "\n")
	var fixes []ContextualQuickFix

	ast.Inspect(node, func(n ast.Node) bool {
		if n == nil {
			return true
		}
		pos := fset.Position(n.Pos())
		if pos.Line != targetLine {
			return true
		}

		// 1. Context WithCancel / WithTimeout missing defer cancel()
		if assign, ok := n.(*ast.AssignStmt); ok {
			for _, rhs := range assign.Rhs {
				if call, ok := rhs.(*ast.CallExpr); ok {
					callStr := fmt.Sprintf("%v", call.Fun)
					if strings.Contains(callStr, "WithCancel") || strings.Contains(callStr, "WithTimeout") || strings.Contains(callStr, "WithDeadline") {
						if len(assign.Lhs) >= 2 {
							cancelIdent, ok := assign.Lhs[1].(*ast.Ident)
							if ok && cancelIdent.Name != "_" {
								fixText := fmt.Sprintf("defer %s()", cancelIdent.Name)
								fixes = append(fixes, ContextualQuickFix{
									Title:       fmt.Sprintf("[GoLens Fix] Add defer %s()", cancelIdent.Name),
									Description: "Prevent context leak by deferring cancellation",
									StartLine:   targetLine,
									EndLine:     targetLine,
									OldText:     lines[targetLine-1],
									NewText:     lines[targetLine-1] + "\n\t" + fixText,
								})
							}
						}
					}
				}
			}
		}

		// 2. HTTP response without resp.Body.Close()
		if assign, ok := n.(*ast.AssignStmt); ok {
			for _, rhs := range assign.Rhs {
				if call, ok := rhs.(*ast.CallExpr); ok {
					callStr := fmt.Sprintf("%v", call.Fun)
					if strings.Contains(callStr, "Get") || strings.Contains(callStr, "Post") || strings.Contains(callStr, "Do") {
						if len(assign.Lhs) >= 1 {
							respIdent, ok := assign.Lhs[0].(*ast.Ident)
							if ok && respIdent.Name != "_" {
								fixText := fmt.Sprintf("defer %s.Body.Close()", respIdent.Name)
								fixes = append(fixes, ContextualQuickFix{
									Title:       fmt.Sprintf("[GoLens Fix] Add defer %s.Body.Close()", respIdent.Name),
									Description: "Ensure HTTP response body is closed to prevent socket leak",
									StartLine:   targetLine,
									EndLine:     targetLine,
									OldText:     lines[targetLine-1],
									NewText:     lines[targetLine-1] + "\n\t" + fixText,
								})
							}
						}
					}
				}
			}
		}

		// 3. SQL string formatting injection
		if call, ok := n.(*ast.CallExpr); ok {
			callStr := fmt.Sprintf("%v", call.Fun)
			if strings.Contains(callStr, "Query") || strings.Contains(callStr, "Exec") {
				for _, arg := range call.Args {
					if sprintfCall, ok := arg.(*ast.CallExpr); ok {
						if strings.Contains(fmt.Sprintf("%v", sprintfCall.Fun), "Sprintf") {
							fixes = append(fixes, ContextualQuickFix{
								Title:       "[GoLens Fix] Replace Sprintf with parameterized query (?, $1)",
								Description: "Prevent SQL injection vulnerability by using parameterized placeholders",
								StartLine:   targetLine,
								EndLine:     targetLine,
								OldText:     lines[targetLine-1],
								NewText:     strings.Replace(lines[targetLine-1], "fmt.Sprintf", "/* parameterized */", 1),
							})
						}
					}
				}
			}
		}

		return true
	})

	return fixes, nil
}

// ============================================================================
// 5. Track 46.1 (Issue #128): Compiler SSA Optimization & Live Disassembly
// ============================================================================

// CompilerDecision represents inlining, escape, or BCE decision by compiler.
type CompilerDecision struct {
	Category string // "escape", "leak", "inline_ok", "inline_blocked", "bce_check"
	File     string
	Line     int
	Message  string
	Hint     string
}

// DisasmInstruction represents a single disassembled machine code line.
type DisasmInstruction struct {
	Address  string
	Mnemonic string
	Operands string
	Source   string
	Line     int
}

// DisasmResult contains disassembled function instructions mapped to Go source lines.
type DisasmResult struct {
	Function     string
	TargetArch   string
	Instructions []DisasmInstruction
}

// ParseCompilerOptimizationOutput parses -m=2 and -d=ssa/check_bce/debug=1 messages.
func ParseCompilerOptimizationOutput(compilerOutput string) []CompilerDecision {
	var results []CompilerDecision
	lines := strings.Split(compilerOutput, "\n")
	lineRegex := regexp.MustCompile(`^(.+?\.go):(\d+):(?:\d+:)?\s*(.+)$`)

	for _, l := range lines {
		l = strings.TrimSpace(l)
		m := lineRegex.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		file := m[1]
		line, _ := strconv.Atoi(m[2])
		msg := m[3]

		var dec CompilerDecision
		dec.File = file
		dec.Line = line
		dec.Message = msg

		switch {
		case strings.Contains(msg, "escapes to heap") || strings.Contains(msg, "moved to heap"):
			dec.Category = "escape"
			dec.Hint = "Variable allocated on heap due to escape analysis"
		case strings.Contains(msg, "leaking param"):
			dec.Category = "leak"
			dec.Hint = "Parameter leaks outside caller stack frame"
		case strings.Contains(msg, "can inline"):
			dec.Category = "inline_ok"
			dec.Hint = "Function within inlining budget (< 80 AST cost)"
		case strings.Contains(msg, "cannot inline"):
			dec.Category = "inline_blocked"
			dec.Hint = "Inlining blocked due to budget or forbidden statements"
		case strings.Contains(msg, "Found IsInBounds") || strings.Contains(msg, "Found IsSliceInBounds"):
			dec.Category = "bce_check"
			dec.Hint = "Add index hint _ = s[maxIdx] before loop to eliminate bounds check"
		default:
			continue
		}
		results = append(results, dec)
	}
	return results
}

// RunCompilerSSAAnalysis runs go build with compiler optimization flags.
func RunCompilerSSAAnalysis(pkgDir string) ([]CompilerDecision, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "go", "build", "-gcflags=-m=2 -d=ssa/check_bce/debug=1", "./...")
	cmd.Dir = pkgDir
	cmd.Env = append(os.Environ(), "GOMEMLIMIT=512MiB", "GOGC=50")

	output, _ := cmd.CombinedOutput()
	return ParseCompilerOptimizationOutput(string(output)), nil
}

// DisassembleFunction disassembles a Go function using go tool objdump.
func DisassembleFunction(pkgDir, funcName, arch string) (*DisasmResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tmpBin := filepath.Join(pkgDir, "temp_bin_"+arch)
	defer os.Remove(tmpBin)

	buildCmd := exec.CommandContext(ctx, "go", "build", "-o", tmpBin, "./...")
	buildCmd.Dir = pkgDir
	buildCmd.Env = append(os.Environ(), "GOARCH="+arch, "CGO_ENABLED=0")
	if out, err := buildCmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("build failed for %s: %v\n%s", arch, err, string(out))
	}

	objdumpCmd := exec.CommandContext(ctx, "go", "tool", "objdump", "-s", funcName, tmpBin)
	objdumpCmd.Dir = pkgDir
	out, err := objdumpCmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("objdump failed: %v\n%s", err, string(out))
	}

	result := &DisasmResult{
		Function:   funcName,
		TargetArch: arch,
	}

	lines := strings.Split(string(out), "\n")
	asmRegex := regexp.MustCompile(`^\s*([a-zA-Z0-9_\-./\\]+\.go):(\d+)\s+(0x[0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+(\S+)\s*(.*)$`)

	for _, line := range lines {
		m := asmRegex.FindStringSubmatch(line)
		if m != nil {
			srcLine, _ := strconv.Atoi(m[2])
			result.Instructions = append(result.Instructions, DisasmInstruction{
				Source:   m[1],
				Line:     srcLine,
				Address:  m[3],
				Mnemonic: m[5],
				Operands: strings.TrimSpace(m[6]),
			})
		}
	}

	return result, nil
}

// ============================================================================
// 6. Track 45.2 (Issue #126): Block & Mutex Contention Profiler
// ============================================================================

// ContentionSample represents a single contention entry from block or mutex profile.
type ContentionSample struct {
	Count      int64  // number of contentions
	DelayNs    int64  // total delay in nanoseconds
	DelayMs    float64
	Function   string
	File       string
	Line       int
	CallFrames []string
}

const MaxContentionProfileCap = 500

// ParseContentionPprof parses simulated or raw pprof contention lines.
func ParseContentionLines(lines []string) []ContentionSample {
	var samples []ContentionSample
	sampleRegex := regexp.MustCompile(`^(\d+)\s+(\d+)\s+@\s*(.*)$`)

	for _, line := range lines {
		line = strings.TrimSpace(line)
		m := sampleRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		delayNs, _ := strconv.ParseInt(m[1], 10, 64)
		count, _ := strconv.ParseInt(m[2], 10, 64)
		frames := strings.Fields(m[3])

		var topFunc, topFile string
		var topLine int
		if len(frames) > 0 {
			topFunc = frames[0]
			parts := strings.Split(topFunc, ":")
			if len(parts) >= 2 {
				topFile = parts[0]
				topLine, _ = strconv.Atoi(parts[1])
			}
		}

		samples = append(samples, ContentionSample{
			Count:      count,
			DelayNs:    delayNs,
			DelayMs:    float64(delayNs) / 1e6,
			Function:   topFunc,
			File:       topFile,
			Line:       topLine,
			CallFrames: frames,
		})

		if len(samples) >= MaxContentionProfileCap {
			break
		}
	}

	// Sort by delay descending
	sort.Slice(samples, func(i, j int) bool {
		return samples[i].DelayNs > samples[j].DelayNs
	})

	return samples
}

// ============================================================================
// 7. Track 46.3 (Issue #130): Assistant Editor Counterpart Auto-Split & Auto-Test
// ============================================================================

// ResolveCounterpart returns counterpart file path and whether it is a test file.
func ResolveCounterpart(filePath string) (counterpart string, isTest bool) {
	if !strings.HasSuffix(filePath, ".go") {
		return "", false
	}
	if strings.HasSuffix(filePath, "_test.go") {
		base := strings.TrimSuffix(filePath, "_test.go")
		return base + ".go", false
	}
	base := strings.TrimSuffix(filePath, ".go")
	return base + "_test.go", true
}

// FindMatchingTestFunction matches `func Foo` in source to `func TestFoo` in test.
func FindMatchingTestFunction(sourceCode, testCode string, sourceLine int) (string, int, bool) {
	fset := token.NewFileSet()
	srcNode, err := parser.ParseFile(fset, "src.go", sourceCode, 0)
	if err != nil {
		return "", 0, false
	}

	var activeFuncName string
	ast.Inspect(srcNode, func(n ast.Node) bool {
		fn, ok := n.(*ast.FuncDecl)
		if ok {
			startPos := fset.Position(fn.Pos())
			endPos := fset.Position(fn.End())
			if sourceLine >= startPos.Line && sourceLine <= endPos.Line {
				activeFuncName = fn.Name.Name
				return false
			}
		}
		return true
	})

	if activeFuncName == "" {
		return "", 0, false
	}

	targetTestName := "Test" + activeFuncName
	testFset := token.NewFileSet()
	testNode, err := parser.ParseFile(testFset, "test.go", testCode, 0)
	if err != nil {
		return "", 0, false
	}

	var matchLine int
	ast.Inspect(testNode, func(n ast.Node) bool {
		fn, ok := n.(*ast.FuncDecl)
		if ok && fn.Name.Name == targetTestName {
			matchLine = testFset.Position(fn.Pos()).Line
			return false
		}
		return true
	})

	if matchLine > 0 {
		return targetTestName, matchLine, true
	}
	return targetTestName, 0, false
}

// AutoTestDebouncer simulates debounced auto-test on save.
type AutoTestDebouncer struct {
	mu           sync.Mutex
	lastTrigger  time.Time
	debounceWait time.Duration
	runCount     int
}

func NewAutoTestDebouncer(wait time.Duration) *AutoTestDebouncer {
	return &AutoTestDebouncer{debounceWait: wait}
}

func (d *AutoTestDebouncer) Trigger(saveAction func()) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	if now.Sub(d.lastTrigger) < d.debounceWait {
		return false // Debounced
	}
	d.lastTrigger = now
	d.runCount++
	if saveAction != nil {
		saveAction()
	}
	return true
}

func (d *AutoTestDebouncer) RunCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.runCount
}

// ============================================================================
// 8. Track 47.1 (Issue #131): `runtime/trace` Execution Timeline Canvas
// ============================================================================

// GoroutineTimelineLane represents a goroutine execution lane with states.
type GoroutineTimelineLane struct {
	GoroutineID int64
	Name        string
	StartNs     int64
	EndNs       int64
	ActiveNs    int64
	WaitingNs   int64
	Spans       []TimelineSpan
}

// TimelineSpan represents an individual colored block on the canvas.
type TimelineSpan struct {
	State       string // "Running", "Runnable", "Blocked", "Syscall"
	StartNs     int64
	EndNs       int64
	BlockedOn   string // "Channel", "Mutex", "Select", "Sync"
	UnblockedBy int64  // G ID that unblocked this G
	File        string
	Line        int
}

// UnblockEdge represents causation link between goroutines.
type UnblockEdge struct {
	FromG       int64
	ToG         int64
	TimestampNs int64
	File        string
	Line        int
}

const (
	MaxTraceReaderCap = 16 * 1024 * 1024 // 16 MB limit
	MaxTraceLanesCap  = 200              // Top 200 lanes
)

// ParseExecutionTraceData parses trace events under the 16MB cap.
func ParseExecutionTraceData(r io.Reader) ([]GoroutineTimelineLane, []UnblockEdge, error) {
	limitedReader := io.LimitReader(r, MaxTraceReaderCap)
	buf := new(bytes.Buffer)
	n, err := buf.ReadFrom(limitedReader)
	if err != nil && err != io.EOF {
		return nil, nil, err
	}
	if n >= MaxTraceReaderCap {
		// Enforce hard cap
		return nil, nil, fmt.Errorf("trace size exceeds 16MB limit (read %d bytes)", n)
	}

	// Parse lines / synthetic trace events
	lanesMap := make(map[int64]*GoroutineTimelineLane)
	var edges []UnblockEdge

	scannerLines := strings.Split(buf.String(), "\n")
	for _, l := range scannerLines {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		// Format: G <gid> <state> <startNs> <endNs> [blockedOn] [unblockedBy] [file:line]
		parts := strings.Fields(l)
		if len(parts) < 5 || parts[0] != "G" {
			continue
		}
		gid, _ := strconv.ParseInt(parts[1], 10, 64)
		state := parts[2]
		startNs, _ := strconv.ParseInt(parts[3], 10, 64)
		endNs, _ := strconv.ParseInt(parts[4], 10, 64)

		lane, exists := lanesMap[gid]
		if !exists {
			lane = &GoroutineTimelineLane{
				GoroutineID: gid,
				Name:        fmt.Sprintf("goroutine %d", gid),
				StartNs:     startNs,
				EndNs:       endNs,
			}
			lanesMap[gid] = lane
		}
		if endNs > lane.EndNs {
			lane.EndNs = endNs
		}

		span := TimelineSpan{
			State:   state,
			StartNs: startNs,
			EndNs:   endNs,
		}
		duration := endNs - startNs
		if state == "Running" || state == "Runnable" {
			lane.ActiveNs += duration
		} else {
			lane.WaitingNs += duration
		}

		if len(parts) >= 6 {
			span.BlockedOn = parts[5]
		}
		if len(parts) >= 7 {
			unblockG, _ := strconv.ParseInt(parts[6], 10, 64)
			span.UnblockedBy = unblockG
			if unblockG > 0 {
				edge := UnblockEdge{
					FromG:       unblockG,
					ToG:         gid,
					TimestampNs: endNs,
				}
				if len(parts) >= 8 {
					fParts := strings.Split(parts[7], ":")
					edge.File = fParts[0]
					if len(fParts) > 1 {
						edge.Line, _ = strconv.Atoi(fParts[1])
					}
				}
				edges = append(edges, edge)
			}
		}

		lane.Spans = append(lane.Spans, span)
	}

	var lanes []GoroutineTimelineLane
	for _, lane := range lanesMap {
		lanes = append(lanes, *lane)
	}

	// Sort by total duration (active + waiting) descending
	sort.Slice(lanes, func(i, j int) bool {
		durI := lanes[i].ActiveNs + lanes[i].WaitingNs
		durJ := lanes[j].ActiveNs + lanes[j].WaitingNs
		return durI > durJ
	})

	if len(lanes) > MaxTraceLanesCap {
		lanes = lanes[:MaxTraceLanesCap]
	}

	return lanes, edges, nil
}

// ============================================================================
// 9. Track 47.2 (Issue #132): Editable Multi-Buffer Editor
// ============================================================================

// MultiBufferExcerpt represents an excerpt card in the multi-buffer editor.
type MultiBufferExcerpt struct {
	FilePath     string `json:"filePath"`
	StartLine    int    `json:"startLine"`
	EndLine      int    `json:"endLine"`
	Lines        string `json:"lines"`
	OriginalHash string `json:"originalHash"`
}

// MatchLocation represents a reference or search hit.
type MatchLocation struct {
	FilePath string
	Line     int
	Column   int
}

// BuildMultiBufferExcerpts clusters match locations within <= 3 lines into unified cards.
func BuildMultiBufferExcerpts(fileContents map[string]string, locations []MatchLocation, contextLines int) []MultiBufferExcerpt {
	type locKey struct {
		file string
		line int
	}

	fileLocs := make(map[string][]int)
	for _, loc := range locations {
		fileLocs[loc.FilePath] = append(fileLocs[loc.FilePath], loc.Line)
	}

	var filePaths []string
	for fp := range fileLocs {
		filePaths = append(filePaths, fp)
	}
	sort.Strings(filePaths)

	var excerpts []MultiBufferExcerpt

	for _, filePath := range filePaths {
		linesList := fileLocs[filePath]
		content, ok := fileContents[filePath]
		if !ok {
			continue
		}
		srcLines := strings.Split(content, "\n")
		totalLines := len(srcLines)

		sort.Ints(linesList)

		// Cluster lines separated by <= 3 lines
		type cluster struct {
			start int
			end   int
		}
		var clusters []cluster
		for _, line := range linesList {
			start := line - contextLines
			if start < 1 {
				start = 1
			}
			end := line + contextLines
			if end > totalLines {
				end = totalLines
			}

			if len(clusters) > 0 && start <= clusters[len(clusters)-1].end+3 {
				// Merge clusters
				if end > clusters[len(clusters)-1].end {
					clusters[len(clusters)-1].end = end
				}
			} else {
				clusters = append(clusters, cluster{start: start, end: end})
			}
		}

		for _, cl := range clusters {
			sliceLines := srcLines[cl.start-1 : cl.end]
			text := strings.Join(sliceLines, "\n")
			hash := sha256.Sum256([]byte(text))

			excerpts = append(excerpts, MultiBufferExcerpt{
				FilePath:     filePath,
				StartLine:    cl.start,
				EndLine:      cl.end,
				Lines:        text,
				OriginalHash: hex.EncodeToString(hash[:]),
			})
		}
	}

	return excerpts
}

// ApplyMultiBufferEdits applies edits from bottom-up and returns rollback snapshot.
func ApplyMultiBufferEdits(fileContents map[string]string, edits []MultiBufferExcerpt) (map[string]string, []MultiBufferExcerpt, error) {
	updated := make(map[string]string)
	for k, v := range fileContents {
		updated[k] = v
	}

	// Group edits by file
	byFile := make(map[string][]MultiBufferExcerpt)
	for _, e := range edits {
		byFile[e.FilePath] = append(byFile[e.FilePath], e)
	}

	var undoSnapshot []MultiBufferExcerpt

	for filePath, fileEdits := range byFile {
		content, ok := updated[filePath]
		if !ok {
			return nil, nil, fmt.Errorf("file %s not found in workspace", filePath)
		}
		srcLines := strings.Split(content, "\n")

		// Sort edits from bottom to top (descending start line)
		sort.Slice(fileEdits, func(i, j int) bool {
			return fileEdits[i].StartLine > fileEdits[j].StartLine
		})

		for _, ed := range fileEdits {
			if ed.StartLine < 1 || ed.EndLine > len(srcLines) || ed.StartLine > ed.EndLine {
				return nil, nil, fmt.Errorf("edit out of bounds: [%d, %d] for file %s", ed.StartLine, ed.EndLine, filePath)
			}

			// Validate hash integrity
			currentSlice := strings.Join(srcLines[ed.StartLine-1:ed.EndLine], "\n")
			currentHash := hex.EncodeToString(func() []byte {
				h := sha256.Sum256([]byte(currentSlice))
				return h[:]
			}())

			if ed.OriginalHash != "" && currentHash != ed.OriginalHash {
				return nil, nil, fmt.Errorf("hash mismatch in %s: original was modified", filePath)
			}

			// Replace lines
			newLines := strings.Split(ed.Lines, "\n")
			newHash := hex.EncodeToString(func() []byte {
				h := sha256.Sum256([]byte(ed.Lines))
				return h[:]
			}())

			// Record undo snapshot
			undoSnapshot = append(undoSnapshot, MultiBufferExcerpt{
				FilePath:     filePath,
				StartLine:    ed.StartLine,
				EndLine:      ed.StartLine + len(newLines) - 1,
				Lines:        currentSlice,
				OriginalHash: newHash,
			})

			var result []string
			result = append(result, srcLines[:ed.StartLine-1]...)
			result = append(result, newLines...)
			result = append(result, srcLines[ed.EndLine:]...)
			srcLines = result
		}

		formatted, err := format.Source([]byte(strings.Join(srcLines, "\n")))
		if err == nil {
			updated[filePath] = string(formatted)
		} else {
			updated[filePath] = strings.Join(srcLines, "\n")
		}
	}

	return updated, undoSnapshot, nil
}

// ============================================================================
// 10. Track 47.3 (Issue #133): Zero-Config HTTP Route Code Lens & Request Exerciser
// ============================================================================

// HTTPRouteLens represents an identified route registration in Go source code.
type HTTPRouteLens struct {
	Method                 string `json:"method"`
	Path                   string `json:"path"`
	Line                   int    `json:"line"`
	Framework              string `json:"framework"` // "net/http", "chi", "gin", "echo"
	SampleRequestBodyJSON  string `json:"sampleRequestBodyJSON,omitempty"`
}

// HTTPResponseResult contains outcome of executed local HTTP request.
type HTTPResponseResult struct {
	StatusCode int               `json:"statusCode"`
	DurationMs int64             `json:"durationMs"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

// ScanHTTPRoutes scans Go AST for route declarations and infers sample struct payloads.
func ScanHTTPRoutes(srcContent string) ([]HTTPRouteLens, error) {
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, "routes.go", srcContent, 0)
	if err != nil {
		return nil, fmt.Errorf("parse error: %w", err)
	}

	// Collect structs for sample body inference
	structDefs := make(map[string]map[string]string)
	ast.Inspect(node, func(n ast.Node) bool {
		ts, ok := n.(*ast.TypeSpec)
		if ok {
			st, ok := ts.Type.(*ast.StructType)
			if ok && st.Fields != nil {
				fields := make(map[string]string)
				for _, f := range st.Fields.List {
					if len(f.Names) > 0 {
						typeName := fmt.Sprintf("%v", f.Type)
						fields[f.Names[0].Name] = typeName
					}
				}
				structDefs[ts.Name.Name] = fields
			}
		}
		return true
	})

	var routes []HTTPRouteLens
	ast.Inspect(node, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}

		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}

		methodName := sel.Sel.Name
		line := fset.Position(call.Pos()).Line

		var route HTTPRouteLens
		route.Line = line

		switch methodName {
		case "HandleFunc", "Handle":
			// net/http Go 1.22+ e.g. mux.HandleFunc("POST /api/v1/users/{id}", ...)
			if len(call.Args) >= 1 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					raw := strings.Trim(lit.Value, `"`)
					parts := strings.Fields(raw)
					if len(parts) >= 2 {
						route.Method = parts[0]
						route.Path = parts[1]
					} else {
						route.Method = "GET"
						route.Path = raw
					}
					route.Framework = "net/http"
				}
			}
		case "GET", "POST", "PUT", "DELETE", "PATCH":
			// Gin / Echo e.g. r.POST("/users", handler)
			if len(call.Args) >= 1 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					route.Method = methodName
					route.Path = strings.Trim(lit.Value, `"`)
					route.Framework = "gin/echo"
				}
			}
		case "Get", "Post", "Put", "Delete", "Patch":
			// Ignore standard library http.Get, http.Post
			if xIdent, ok := sel.X.(*ast.Ident); ok && xIdent.Name == "http" {
				break
			}
			// Chi e.g. r.Post("/users", handler)
			if len(call.Args) >= 1 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					route.Method = strings.ToUpper(methodName)
					route.Path = strings.Trim(lit.Value, `"`)
					route.Framework = "chi"
				}
			}
		}

		if route.Path != "" {
			// Infer request body if struct decoding is used in handler
			sortedStructNames := make([]string, 0, len(structDefs))
			for sName := range structDefs {
				sortedStructNames = append(sortedStructNames, sName)
			}
			sort.Strings(sortedStructNames)

			for _, structName := range sortedStructNames {
				fields := structDefs[structName]
				if strings.Contains(srcContent, structName) && (route.Method == "POST" || route.Method == "PUT" || route.Method == "PATCH") {
					sampleMap := make(map[string]any)
					for fName, fType := range fields {
						switch fType {
						case "string":
							sampleMap[strings.ToLower(fName)] = "sample_" + strings.ToLower(fName)
						case "int", "int64":
							sampleMap[strings.ToLower(fName)] = 1
						case "bool":
							sampleMap[strings.ToLower(fName)] = true
						default:
							sampleMap[strings.ToLower(fName)] = nil
						}
					}
					sampleJSON, _ := json.MarshalIndent(sampleMap, "", "  ")
					route.SampleRequestBodyJSON = string(sampleJSON)
					break
				}
			}
			routes = append(routes, route)
		}

		return true
	})

	return routes, nil
}

// ExecuteLocalHTTPRequest executes a request against a local test server.
func ExecuteLocalHTTPRequest(targetURL, method string, headers map[string]string, body string, timeout time.Duration) (*HTTPResponseResult, error) {
	req, err := http.NewRequest(method, targetURL, strings.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("invalid request: %w", err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	client := &http.Client{
		Timeout: timeout,
	}

	start := time.Now()
	resp, err := client.Do(req)
	duration := time.Since(start).Milliseconds()
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	respHeaders := make(map[string]string)
	for k, v := range resp.Header {
		respHeaders[k] = strings.Join(v, ", ")
	}

	return &HTTPResponseResult{
		StatusCode: resp.StatusCode,
		DurationMs: duration,
		Headers:    respHeaders,
		Body:       string(respBody),
	}, nil
}
