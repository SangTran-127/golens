package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

type GoModLens struct {
	Line         int    `json:"line"`
	Title        string `json:"title"`
	CompactTitle string `json:"compactTitle,omitempty"`
	Command      string `json:"command"`
	Arg          string `json:"arg,omitempty"`
}

type GoModRequire struct {
	Line     int    `json:"line"`
	Module   string `json:"module"`
	Version  string `json:"version"`
	Indirect bool   `json:"indirect"`
	Latest   string `json:"latest,omitempty"`
}

type GoModReplace struct {
	Line           int    `json:"line"`
	OldModule      string `json:"oldModule"`
	OldVersion     string `json:"oldVersion,omitempty"`
	Target         string `json:"target"`
	TargetVersion  string `json:"targetVersion,omitempty"`
	IsLocal        bool   `json:"isLocal"`
	ResolvedTarget string `json:"resolvedTarget,omitempty"`
	TargetExists   bool   `json:"targetExists"`
	TargetHasGoMod bool   `json:"targetHasGoMod"`
}

type GoModDiagnostic struct {
	Line     int    `json:"line"`
	Severity int    `json:"severity"`
	Code     string `json:"code"`
	Message  string `json:"message"`
}

type GoModInspectReport struct {
	ModulePath  string            `json:"modulePath"`
	ModuleLine  int               `json:"moduleLine"`
	GoVersion   string            `json:"goVersion,omitempty"`
	Requires    []GoModRequire    `json:"requires"`
	Replaces    []GoModReplace    `json:"replaces,omitempty"`
	Diagnostics []GoModDiagnostic `json:"diagnostics,omitempty"`
	GoWork      *GoWorkReport     `json:"goWork,omitempty"`
	Lenses      []GoModLens       `json:"lenses"`
	UpdateError string            `json:"updateError,omitempty"`
}

func ParseGoModContent(content string, updates map[string]string) GoModInspectReport {
	return ParseGoModContentWithDir(content, updates, "")
}

func ParseGoModContentWithDir(content string, updates map[string]string, baseDir string) GoModInspectReport {
	report := GoModInspectReport{
		Requires: []GoModRequire{},
		Lenses:   []GoModLens{},
	}
	inBlock := ""
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	for i, raw := range lines {
		lineNum := i + 1
		codePart, commentPart, hasComment := splitModLineComment(raw)
		isIndirect := false
		if hasComment {
			commentFields := strings.Fields(commentPart)
			if len(commentFields) > 0 && commentFields[0] == "indirect" {
				isIndirect = true
			}
		}
		fields := tokenizeModFields(codePart)
		if len(fields) == 0 {
			continue
		}
		if inBlock != "" {
			if fields[0] == ")" || strings.HasPrefix(fields[0], ")") {
				inBlock = ""
				continue
			}
			switch inBlock {
			case "require":
				if len(fields) >= 2 {
					report.Requires = append(report.Requires, GoModRequire{
						Line:     lineNum,
						Module:   unquoteModToken(fields[0]),
						Version:  fields[1],
						Indirect: isIndirect,
					})
				}
			case "replace":
				if rep, ok := parseReplaceDirectiveTokens(fields, lineNum, baseDir); ok {
					report.Replaces = append(report.Replaces, rep)
				}
			}
			continue
		}
		if len(fields) >= 2 && fields[1] == "(" {
			inBlock = fields[0]
			continue
		}
		if strings.HasSuffix(fields[0], "(") {
			inBlock = strings.TrimSuffix(fields[0], "(")
			continue
		}
		switch fields[0] {
		case "module":
			if len(fields) >= 2 {
				report.ModulePath = unquoteModToken(fields[1])
				report.ModuleLine = lineNum
			}
		case "go":
			if len(fields) >= 2 {
				report.GoVersion = fields[1]
			}
		case "require":
			if len(fields) >= 3 {
				report.Requires = append(report.Requires, GoModRequire{
					Line:     lineNum,
					Module:   unquoteModToken(fields[1]),
					Version:  fields[2],
					Indirect: isIndirect,
				})
			}
		case "replace":
			if len(fields) >= 4 {
				if rep, ok := parseReplaceDirectiveTokens(fields[1:], lineNum, baseDir); ok {
					report.Replaces = append(report.Replaces, rep)
				}
			}
		}
	}

	moduleLine := report.ModuleLine
	if moduleLine == 0 {
		moduleLine = 1
	}
	report.Lenses = append(report.Lenses,
		GoModLens{Line: moduleLine, Title: "Run go mod tidy", CompactTitle: "Tidy", Command: "goModTidy"},
		GoModLens{Line: moduleLine, Title: "Check Module Updates", CompactTitle: "Updates", Command: "goModCheckUpdates"},
		GoModLens{Line: moduleLine, Title: "Download Modules", CompactTitle: "Download", Command: "goModDownload"},
		GoModLens{Line: moduleLine, Title: "Add Module…", CompactTitle: "Add…", Command: "goModAdd"},
	)

	for i := range report.Requires {
		req := &report.Requires[i]
		if updates != nil {
			if latest := updates[req.Module]; latest != "" && latest != req.Version {
				req.Latest = latest
				report.Lenses = append(report.Lenses, GoModLens{
					Line:         req.Line,
					Title:        "Upgrade to " + latest,
					CompactTitle: "Upgrade " + latest,
					Command:      "goModGet",
					Arg:          req.Module + "@" + latest,
				})
			}
		}
		report.Lenses = append(report.Lenses, GoModLens{
			Line:         req.Line,
			Title:        "Why Used",
			CompactTitle: "Why",
			Command:      "goModWhy",
			Arg:          req.Module,
		})
		report.Lenses = append(report.Lenses, GoModLens{
			Line:         req.Line,
			Title:        "Open Documentation",
			CompactTitle: "Docs",
			Command:      "goModOpenDocs",
			Arg:          req.Module,
		})
	}

	appendReplaceLensesAndDiagnostics(&report)
	return report
}

func appendReplaceLensesAndDiagnostics(report *GoModInspectReport) {
	for _, rep := range report.Replaces {
		if !rep.IsLocal {
			continue
		}
		report.Lenses = append(report.Lenses, GoModLens{
			Line:         rep.Line,
			Title:        "Drop Replace",
			CompactTitle: "Drop",
			Command:      "goModDropReplace",
			Arg:          strconv.Itoa(rep.Line),
		})
		targetArg := rep.ResolvedTarget
		if targetArg == "" {
			targetArg = rep.Target
		}
		if rep.ResolvedTarget == "" || rep.TargetExists {
			report.Lenses = append(report.Lenses, GoModLens{
				Line:         rep.Line,
				Title:        "Open Replaced Module",
				CompactTitle: "Open Target",
				Command:      "goModOpenReplace",
				Arg:          targetArg,
			})
		}
		if rep.ResolvedTarget != "" && !rep.TargetExists {
			report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
				Line:     rep.Line,
				Severity: 1,
				Code:     "local-replace-missing",
				Message:  fmt.Sprintf("Local replace target %q does not exist on disk.", rep.Target),
			})
		} else if rep.ResolvedTarget != "" && !rep.TargetHasGoMod {
			report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
				Line:     rep.Line,
				Severity: 2,
				Code:     "local-replace-no-gomod",
				Message:  fmt.Sprintf("Local replace target %q does not contain a go.mod file.", rep.Target),
			})
		} else {
			report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
				Line:     rep.Line,
				Severity: 2,
				Code:     "local-replace",
				Message:  fmt.Sprintf("Local replace %s => %s bypasses go.sum and breaks CI if committed.", rep.OldModule, rep.Target),
			})
		}
	}
}

func parseReplaceDirectiveTokens(tokens []string, lineNum int, baseDir string) (GoModReplace, bool) {
	arrowIdx := -1
	for i, tok := range tokens {
		if tok == "=>" {
			arrowIdx = i
			break
		}
	}
	if arrowIdx <= 0 || arrowIdx+1 >= len(tokens) {
		return GoModReplace{}, false
	}
	oldMod := unquoteModToken(tokens[0])
	oldVer := ""
	if arrowIdx >= 2 {
		oldVer = tokens[1]
	}
	rightTokens := tokens[arrowIdx+1:]
	target := unquoteModToken(rightTokens[0])
	targetVer := ""
	if len(rightTokens) >= 2 {
		targetVer = rightTokens[1]
	}
	isLocal := len(rightTokens) == 1 ||
		strings.HasPrefix(target, "./") ||
		strings.HasPrefix(target, "../") ||
		strings.HasPrefix(target, "/") ||
		target == "." ||
		target == ".." ||
		filepath.IsAbs(target) ||
		!strings.Contains(target, ".")

	rep := GoModReplace{
		Line:          lineNum,
		OldModule:     oldMod,
		OldVersion:    oldVer,
		Target:        target,
		TargetVersion: targetVer,
		IsLocal:       isLocal,
	}
	if isLocal && baseDir != "" {
		resolved := filepath.FromSlash(target)
		if !filepath.IsAbs(resolved) {
			resolved = filepath.Join(baseDir, resolved)
		}
		resolved = filepath.Clean(resolved)
		rep.ResolvedTarget = resolved
		if info, err := os.Stat(resolved); err == nil && info.IsDir() {
			rep.TargetExists = true
			if _, modErr := os.Stat(filepath.Join(resolved, "go.mod")); modErr == nil {
				rep.TargetHasGoMod = true
			}
		}
	}
	return rep, true
}

func splitModLineComment(line string) (string, string, bool) {
	var quote byte
	for i := 0; i < len(line); i++ {
		c := line[i]
		if quote != 0 {
			if c == '\\' && quote == '"' && i+1 < len(line) {
				i++
				continue
			}
			if c == quote {
				quote = 0
			}
			continue
		}
		if c == '"' || c == '`' {
			quote = c
			continue
		}
		if c == '/' && i+1 < len(line) && line[i+1] == '/' {
			return line[:i], line[i+2:], true
		}
	}
	return line, "", false
}

func tokenizeModFields(s string) []string {
	var fields []string
	i := 0
	n := len(s)
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {
			i++
		}
		if i >= n {
			break
		}
		if s[i] == '"' || s[i] == '`' {
			q := s[i]
			start := i
			i++
			for i < n {
				if s[i] == '\\' && q == '"' && i+1 < n {
					i += 2
					continue
				}
				if s[i] == q {
					i++
					break
				}
				i++
			}
			fields = append(fields, s[start:i])
			continue
		}
		start := i
		for i < n && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' {
			i++
		}
		fields = append(fields, s[start:i])
	}
	return fields
}

func unquoteModToken(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		if unquoted, err := strconv.Unquote(s); err == nil {
			return unquoted
		}
		return s[1 : len(s)-1]
	}
	if len(s) >= 2 && s[0] == '`' && s[len(s)-1] == '`' {
		return s[1 : len(s)-1]
	}
	return s
}

func resolveWorkspaceGuestDir(dir string) string {
	cleanDir := filepath.Clean(dir)
	root := filepath.Clean(GetActiveDir())
	if root != "" && root != "." {
		if rel, err := filepath.Rel(root, cleanDir); err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return vmexec.HostToGuestPath(root, cleanDir)
		}
		if evalRoot, rErr := filepath.EvalSymlinks(root); rErr == nil {
			if evalDir, dErr := filepath.EvalSymlinks(cleanDir); dErr == nil {
				if rel2, err2 := filepath.Rel(evalRoot, evalDir); err2 == nil && rel2 != ".." && !strings.HasPrefix(rel2, ".."+string(filepath.Separator)) {
					return vmexec.HostToGuestPath(evalRoot, evalDir)
				}
			}
		}
	}
	return vmexec.HostToGuestPath(cleanDir, cleanDir)
}

func runGoToolWithStreams(ctx context.Context, dir string, extraEnv map[string]string, args ...string) ([]byte, string, error) {
	guestDir := resolveWorkspaceGuestDir(dir)
	cmd := vmexec.CommandContext(ctx, "go", args...)
	cmd.Dir = guestDir
	cmd.Env = vmexec.DefaultVMEnv("arm64", extraEnv)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil && bridge.CanFallbackToHost(err) {
		stdout.Reset()
		stderr.Reset()
		hostCmd := exec.CommandContext(ctx, "go", args...)
		hostCmd.Dir = dir
		env := os.Environ()
		for k, v := range extraEnv {
			env = append(env, k+"="+v)
		}
		hostCmd.Env = env
		hostCmd.Stdout = &stdout
		hostCmd.Stderr = &stderr
		err = hostCmd.Run()
	}
	return stdout.Bytes(), strings.TrimSpace(stderr.String()), err
}

func runGoTool(ctx context.Context, dir string, extraEnv map[string]string, args ...string) ([]byte, error) {
	out, errText, err := runGoToolWithStreams(ctx, dir, extraEnv, args...)
	if errText != "" {
		if len(out) == 0 {
			return []byte(errText), err
		}
		return append(append(out, '\n'), []byte(errText)...), err
	}
	return out, err
}

func InspectGoModJSON(goModPath string, content string, checkUpdates bool) string {
	if content == "" && goModPath != "" {
		if data, err := os.ReadFile(goModPath); err == nil {
			content = string(data)
		}
	}
	if filepath.Base(goModPath) == "go.work" {
		return InspectGoWorkJSON(goModPath, content)
	}
	var updates map[string]string
	var updateErrMsg string
	if checkUpdates && goModPath != "" {
		updates = map[string]string{}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		out, errText, err := runGoToolWithStreams(ctx, filepath.Dir(goModPath), map[string]string{"GOFLAGS": "-mod=readonly"}, "list", "-m", "-u", "-json", "all")
		if err != nil {
			updateErrMsg = errText
			if updateErrMsg == "" {
				updateErrMsg = strings.TrimSpace(string(out))
			}
			if updateErrMsg == "" {
				updateErrMsg = err.Error()
			}
		}
		if len(out) > 0 {
			dec := json.NewDecoder(bytes.NewReader(out))
			for {
				var m struct {
					Path    string
					Version string
					Update  *struct {
						Version string
					}
				}
				if err := dec.Decode(&m); err != nil {
					break
				}
				if m.Path != "" && m.Update != nil && m.Update.Version != "" {
					updates[m.Path] = m.Update.Version
				}
			}
		}
	}
	baseDir := ""
	if goModPath != "" {
		baseDir = filepath.Dir(goModPath)
	}
	report := ParseGoModContentWithDir(content, updates, baseDir)
	report.UpdateError = updateErrMsg
	b, err := json.Marshal(report)
	if err != nil {
		return "{}"
	}
	return string(b)
}
