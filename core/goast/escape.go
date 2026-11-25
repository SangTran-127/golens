package goast

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

var (
	escapeCancelMu sync.Mutex
	escapeCancelFn context.CancelFunc
	escapeRunMu    sync.Mutex
)

const (
	goModFileName        = "go.mod"
	prefixCanInline      = "can inline "
	prefixInliningCallTo = "inlining call to "
)

type EscapeItem struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	Kind     string `json:"kind"`
	Category string `json:"category"`
	Subject  string `json:"subject"`
	Message  string `json:"message"`
	Summary  string `json:"summary"`
	Hint     string `json:"hint,omitempty"`
}

type EscapeAnalysisResult struct {
	Items []EscapeItem `json:"items"`
	Error string       `json:"error,omitempty"`
}

func AnalyzeEscape(workspacePath, filePath string) (string, error) {
	res := EscapeAnalysisResult{
		Items: []EscapeItem{},
	}

	targetFile := strings.TrimSpace(filePath)
	workDir := strings.TrimSpace(workspacePath)

	pkgDir := workDir
	if targetFile != "" {
		if info, err := os.Stat(targetFile); err == nil && info.IsDir() {
			pkgDir = targetFile
			targetFile = ""
		} else {
			pkgDir = filepath.Dir(targetFile)
		}
	}
	if workDir == "" {
		workDir = pkgDir
	}
	if workDir == "" {
		res.Error = "missing workspace and file path"
		b, err := json.Marshal(res)
		return string(b), err
	}

	modRoot := findGoModRoot(pkgDir, workDir)
	if modRoot != "" {
		workDir = modRoot
	} else {
		modRoot = workDir
	}

	relPkg := "."
	if pkgDir != "" && pkgDir != workDir {
		if rel, err := filepath.Rel(workDir, pkgDir); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			relPkg = "./" + filepath.ToSlash(rel)
		} else {
			workDir = pkgDir
			relPkg = "."
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	escapeCancelMu.Lock()
	if escapeCancelFn != nil {
		escapeCancelFn()
	}
	escapeCancelFn = cancel
	escapeCancelMu.Unlock()
	defer cancel()

	escapeRunMu.Lock()
	defer escapeRunMu.Unlock()
	if ctx.Err() != nil {
		res.Error = "superseded by newer escape analysis request"
		b, err := json.Marshal(res)
		return string(b), err
	}

	var rawOutput string
	var cmdErr error

	guestWorkDir := vmexec.HostToGuestPath(modRoot, workDir)
	vmCmd := vmexec.CommandContext(ctx, "go", "build", "-p", "2", "-gcflags=-m=2 -d=ssa/check_bce/debug=1", "-o", "/dev/null", relPkg)
	vmCmd.Dir = guestWorkDir
	vmCmd.Env = vmexec.DefaultVMEnv("arm64", map[string]string{"GOMEMLIMIT": "512MiB", "GOGC": "50"})

	vmOut, vmErr := vmCmd.CombinedOutput()
	if vmErr != nil && bridge.CanFallbackToHost(vmErr) {
		hostCmd := exec.CommandContext(ctx, "go", "build", "-p", "2", "-gcflags=-m=2 -d=ssa/check_bce/debug=1", "-o", os.DevNull, relPkg)
		hostCmd.Dir = workDir
		hostCmd.Env = append(os.Environ(), "GOMEMLIMIT=512MiB", "GOGC=50")
		vmOut, vmErr = hostCmd.CombinedOutput()
	}
	rawOutput = string(vmOut)
	cmdErr = vmErr

	items := ParseEscapeOutput(rawOutput, workDir, targetFile)
	if items != nil {
		res.Items = items
	}

	if cmdErr != nil && len(res.Items) == 0 {
		res.Error = strings.TrimSpace(rawOutput)
		if res.Error == "" {
			res.Error = cmdErr.Error()
		}
	}

	b, err := json.Marshal(res)
	return string(b), err
}

func findGoModRoot(pkgDir, fallbackWorkDir string) string {
	if fallbackWorkDir != "" {
		if _, err := os.Stat(filepath.Join(fallbackWorkDir, goModFileName)); err == nil {
			if pkgDir == "" {
				return fallbackWorkDir
			}
			if rel, relErr := filepath.Rel(fallbackWorkDir, pkgDir); relErr == nil && !strings.HasPrefix(rel, "..") {
				if !hasNestedGoMod(fallbackWorkDir, pkgDir) {
					return fallbackWorkDir
				}
			}
		}
	}
	cur := pkgDir
	for cur != "" {
		if _, err := os.Stat(filepath.Join(cur, goModFileName)); err == nil {
			return cur
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	return fallbackWorkDir
}

func hasNestedGoMod(rootDir, pkgDir string) bool {
	cur := pkgDir
	for cur != "" && cur != rootDir {
		if _, err := os.Stat(filepath.Join(cur, goModFileName)); err == nil {
			return true
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	return false
}

func ParseEscapeOutput(output, workDir, targetFile string) []EscapeItem {
	cleanTarget := ""
	evalTarget := ""
	if strings.TrimSpace(targetFile) != "" {
		cleanTarget = filepath.Clean(targetFile)
		if resolved, err := filepath.EvalSymlinks(cleanTarget); err == nil {
			evalTarget = resolved
		}
	}

	items := make([]EscapeItem, 0)
	type dedupKey struct {
		file    string
		line    int
		summary string
	}
	seen := make(map[dedupKey]bool)

	for _, rawLine := range strings.Split(output, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		goIdx := strings.Index(line, ".go:")
		if goIdx < 0 {
			continue
		}

		rawFile := line[:goIdx+3]
		rest := line[goIdx+4:]

		lineNum, colNum, msg, ok := parseLocationAndMessage(rest)
		if !ok || msg == "" {
			continue
		}

		kind, category, subject, summary, hint := classifyEscapeMessage(msg)
		if kind == "" {
			continue
		}

		resolvedFile := rawFile
		if strings.HasPrefix(resolvedFile, "/workspaces/") {
			resolvedFile = vmexec.GuestToHostPath(workDir, resolvedFile)
		} else if !filepath.IsAbs(resolvedFile) && workDir != "" {
			resolvedFile = filepath.Join(workDir, resolvedFile)
		}
		resolvedFile = filepath.Clean(resolvedFile)

		if cleanTarget != "" {
			if !sameFilePath(resolvedFile, cleanTarget, evalTarget) {
				continue
			}
			resolvedFile = cleanTarget
		}

		key := dedupKey{
			file:    resolvedFile,
			line:    lineNum,
			summary: summary,
		}
		if seen[key] {
			continue
		}
		seen[key] = true

		items = append(items, EscapeItem{
			File:     resolvedFile,
			Line:     lineNum,
			Col:      colNum,
			Kind:     kind,
			Category: category,
			Subject:  subject,
			Message:  msg,
			Summary:  summary,
			Hint:     hint,
		})
	}

	sort.SliceStable(items, func(i, j int) bool {
		if items[i].File != items[j].File {
			return items[i].File < items[j].File
		}
		if items[i].Line != items[j].Line {
			return items[i].Line < items[j].Line
		}
		return items[i].Col < items[j].Col
	})

	return items
}

func sameFilePath(candidate, cleanTarget, evalTarget string) bool {
	if candidate == cleanTarget {
		return true
	}
	if evalTarget != "" {
		if evalCand, err := filepath.EvalSymlinks(candidate); err == nil && evalCand == evalTarget {
			return true
		}
	}
	return false
}

func parseLocationAndMessage(rest string) (int, int, string, bool) {
	parts := strings.SplitN(rest, ":", 3)
	if len(parts) < 2 {
		return 0, 0, "", false
	}
	lineNum, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil || lineNum <= 0 {
		return 0, 0, "", false
	}
	if len(parts) >= 3 {
		if colNum, colErr := strconv.Atoi(strings.TrimSpace(parts[1])); colErr == nil && colNum > 0 {
			return lineNum, colNum, strings.TrimSpace(parts[2]), true
		}
	}
	msg := strings.TrimSpace(strings.Join(parts[1:], ":"))
	return lineNum, 1, msg, true
}

func classifyEscapeMessage(msg string) (kind, category, subject, summary, hint string) {
	if strings.Contains(msg, "Found IsInBounds") || strings.Contains(msg, "Found IsSliceInBounds") || strings.Contains(msg, "Found check") {
		return "bce_check", "bce_check", "", "BCE: bounds check", "Add index hint _ = s[maxIdx] before loop to eliminate bounds check"
	}

	if strings.Contains(msg, "cannot inline") {
		reason := msg
		if idx := strings.Index(msg, "cannot inline "); idx >= 0 {
			reason = strings.TrimSpace(msg[idx+len("cannot inline "):])
		}
		return "inline_blocked", "inline_blocked", "", "cannot inline: " + reason, "Inlining blocked due to budget or forbidden statements"
	}

	if idx := strings.Index(msg, "moved to heap:"); idx >= 0 {
		subject = strings.TrimSpace(msg[idx+len("moved to heap:"):])
		if subject != "" {
			return "heap", "escape", subject, "↗ heap: " + subject, "Variable allocated on heap due to escape analysis"
		}
		return "heap", "escape", "", "↗ escapes to heap", "Variable allocated on heap due to escape analysis"
	}

	if idx := strings.Index(msg, "escapes to heap"); idx >= 0 {
		subject = strings.TrimSpace(msg[:idx])
		if subject != "" {
			return "heap", "escape", subject, "↗ heap: " + subject, "Variable allocated on heap due to escape analysis"
		}
		return "heap", "escape", "", "↗ escapes to heap", "Variable allocated on heap due to escape analysis"
	}

	if idx := strings.Index(msg, "leaking param:"); idx >= 0 {
		subject = strings.TrimSpace(msg[idx+len("leaking param:"):])
		if toIdx := strings.Index(subject, " to result "); toIdx > 0 {
			subject = strings.TrimSpace(subject[:toIdx])
		}
		if subject != "" {
			return "leak", "leak", subject, "↗ leaks param: " + subject, "Parameter leaks outside caller stack frame"
		}
		return "leak", "leak", "", "↗ leaks param", "Parameter leaks outside caller stack frame"
	}

	if strings.Contains(msg, prefixCanInline) || strings.Contains(msg, prefixInliningCallTo) {
		if idx := strings.Index(msg, prefixCanInline); idx >= 0 {
			subject = strings.TrimSpace(msg[idx+len(prefixCanInline):])
		} else if idx := strings.Index(msg, prefixInliningCallTo); idx >= 0 {
			subject = strings.TrimSpace(msg[idx+len(prefixInliningCallTo):])
		}
		return "inline", "inline_ok", subject, msg, "Function within inlining budget (< 80 AST cost)"
	}

	if idx := strings.Index(msg, "does not escape"); idx >= 0 {
		subject = strings.TrimSpace(msg[:idx])
		return "stack", "stack", subject, "stack: " + msg, ""
	}

	return "", "", "", "", ""
}
