package lsp

import (
	"context"
	"encoding/json"
	"fmt"
	"go/version"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type GoWorkModuleRef struct {
	Line       int            `json:"line"`
	Raw        string         `json:"raw,omitempty"`
	RelPath    string         `json:"relPath"`
	Dir        string         `json:"dir"`
	ModulePath string         `json:"modulePath,omitempty"`
	GoVersion  string         `json:"goVersion,omitempty"`
	Exists     bool           `json:"exists"`
	HasGoMod   bool           `json:"hasGoMod"`
	Requires   []GoModRequire `json:"-"`
}

type GoWorkReport struct {
	GoVersion             string            `json:"goVersion,omitempty"`
	GoLine                int               `json:"goLine,omitempty"`
	UseLine               int               `json:"useLine,omitempty"`
	NeedsSync             bool              `json:"needsSync"`
	SyncReason            string            `json:"syncReason,omitempty"`
	HighestChildGoVersion string            `json:"highestChildGoVersion,omitempty"`
	HighestChildModule    string            `json:"highestChildModule,omitempty"`
	UseModules            []GoWorkModuleRef `json:"useModules"`
	UnlistedModules       []GoWorkModuleRef `json:"unlistedModules,omitempty"`
}

type GoModWhyStanza struct {
	Header string   `json:"header"`
	Chain  []string `json:"chain,omitempty"`
	Note   string   `json:"note,omitempty"`
}

type GoModWhyReport struct {
	Module  string           `json:"module"`
	Needed  bool             `json:"needed"`
	Summary string           `json:"summary"`
	Stanzas []GoModWhyStanza `json:"stanzas,omitempty"`
	Raw     string           `json:"raw,omitempty"`
	Error   string           `json:"error,omitempty"`
}

type GoWorkSyncResult struct {
	OK     bool   `json:"ok"`
	Output string `json:"output,omitempty"`
	Error  string `json:"error,omitempty"`
}

func InspectGoWorkJSON(goWorkPath string, content string) string {
	if content == "" && goWorkPath != "" {
		if data, err := os.ReadFile(goWorkPath); err == nil {
			content = string(data)
		}
	}
	workDir := ""
	if goWorkPath != "" {
		workDir = filepath.Dir(goWorkPath)
	}
	report := ParseGoWorkContentWithDir(content, workDir)
	b, err := json.Marshal(report)
	if err != nil {
		return "{}"
	}
	return string(b)
}

func ParseGoWorkContentWithDir(content string, workDir string) GoModInspectReport {
	gw := &GoWorkReport{
		UseModules: []GoWorkModuleRef{},
	}
	report := GoModInspectReport{
		ModuleLine: 1,
		Requires:   []GoModRequire{},
		Lenses:     []GoModLens{},
		GoWork:     gw,
	}

	inBlock := ""
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	for i, raw := range lines {
		lineNum := i + 1
		codePart, _, _ := splitModLineComment(raw)
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
			case "use":
				rawDir := unquoteModToken(fields[0])
				if rawDir != "" {
					gw.UseModules = append(gw.UseModules, inspectWorkModuleRef(workDir, rawDir, lineNum))
				}
			case "replace":
				if rep, ok := parseReplaceDirectiveTokens(fields, lineNum, workDir); ok {
					report.Replaces = append(report.Replaces, rep)
				}
			}
			continue
		}

		if len(fields) >= 2 && fields[1] == "(" {
			inBlock = fields[0]
			if inBlock == "use" && gw.UseLine == 0 {
				gw.UseLine = lineNum
			}
			continue
		}
		if strings.HasSuffix(fields[0], "(") {
			inBlock = strings.TrimSuffix(fields[0], "(")
			if inBlock == "use" && gw.UseLine == 0 {
				gw.UseLine = lineNum
			}
			continue
		}

		switch fields[0] {
		case "go":
			if len(fields) >= 2 {
				gw.GoVersion = fields[1]
				gw.GoLine = lineNum
				report.GoVersion = fields[1]
				report.ModuleLine = lineNum
			}
		case "use":
			if gw.UseLine == 0 {
				gw.UseLine = lineNum
			}
			if len(fields) >= 2 {
				rawDir := unquoteModToken(fields[1])
				if rawDir != "" {
					gw.UseModules = append(gw.UseModules, inspectWorkModuleRef(workDir, rawDir, lineNum))
				}
			}
		case "replace":
			if len(fields) >= 4 {
				if rep, ok := parseReplaceDirectiveTokens(fields[1:], lineNum, workDir); ok {
					report.Replaces = append(report.Replaces, rep)
				}
			}
		}
	}

	topLine := gw.GoLine
	if topLine == 0 {
		topLine = 1
	}
	report.ModuleLine = topLine
	report.Lenses = append(report.Lenses, GoModLens{
		Line:         topLine,
		Title:        "Sync Workspace",
		CompactTitle: "Sync",
		Command:      "goWorkSync",
	})

	highestGo, highestNorm, highestMod := "", "", ""
	coveredDirs := make(map[string]bool)
	for _, u := range gw.UseModules {
		if u.Dir != "" {
			coveredDirs[cleanResolvedPath(u.Dir)] = true
		}
		if workDir != "" && (!u.Exists || !u.HasGoMod) {
			report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
				Line:     u.Line,
				Severity: 1,
				Code:     "gowork-missing-module",
				Message:  fmt.Sprintf("Use path %q does not contain a go.mod file.", u.Raw),
			})
			report.Lenses = append(report.Lenses, GoModLens{
				Line:         u.Line,
				Title:        "Remove Missing Module",
				CompactTitle: "Remove",
				Command:      "goWorkDropUse",
				Arg:          u.Raw,
			})
		}
		if u.HasGoMod && u.GoVersion != "" {
			childNorm := normalizeGoDirectiveVersion(u.GoVersion)
			if childNorm != "" && (highestNorm == "" || version.Compare(childNorm, highestNorm) > 0) {
				highestNorm = childNorm
				highestGo = u.GoVersion
				highestMod = u.RelPath
			}
		}
	}
	gw.HighestChildGoVersion = highestGo
	gw.HighestChildModule = highestMod

	workGoNorm := normalizeGoDirectiveVersion(gw.GoVersion)
	if highestNorm != "" && (workGoNorm == "" || version.Compare(workGoNorm, highestNorm) < 0) {
		targetLine := gw.GoLine
		if targetLine == 0 {
			targetLine = 1
		}
		msg := fmt.Sprintf("go.work omits Go %s required by %s/go.mod.", highestGo, highestMod)
		if gw.GoVersion != "" {
			msg = fmt.Sprintf("go.work declares Go %s, older than %s/go.mod (Go %s).", gw.GoVersion, highestMod, highestGo)
		}
		report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
			Line:     targetLine,
			Severity: 1,
			Code:     "gowork-go-version-mismatch",
			Message:  msg,
		})
		report.Lenses = append(report.Lenses, GoModLens{
			Line:         targetLine,
			Title:        "Update go.work to Go " + highestGo,
			CompactTitle: "Go " + highestGo,
			Command:      "goWorkUpdateGoVersion",
			Arg:          highestGo,
		})
	}

	if workDir != "" {
		unlisted := findUnlistedWorkModules(workDir, coveredDirs)
		gw.UnlistedModules = unlisted
		useLensLine := gw.UseLine
		if useLensLine == 0 {
			useLensLine = topLine
		}
		for idx, m := range unlisted {
			report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
				Line:     useLensLine,
				Severity: 2,
				Code:     "gowork-unlisted-module",
				Message:  fmt.Sprintf("Child module %s has go.mod but is not listed in go.work.", m.RelPath),
			})
			if idx < 4 {
				report.Lenses = append(report.Lenses, GoModLens{
					Line:         useLensLine,
					Title:        "Add " + m.RelPath + " to go.work",
					CompactTitle: "+ " + m.RelPath,
					Command:      "goWorkAddModule",
					Arg:          m.RelPath,
				})
			}
		}
	}

	if syncReason := detectWorkspaceDependencySkew(gw.UseModules); syncReason != "" {
		gw.NeedsSync = true
		gw.SyncReason = syncReason
		report.Diagnostics = append(report.Diagnostics, GoModDiagnostic{
			Line:     topLine,
			Severity: 2,
			Code:     "gowork-needs-sync",
			Message:  syncReason,
		})
	}

	appendReplaceLensesAndDiagnostics(&report)
	return report
}

func inspectWorkModuleRef(workDir string, rawDir string, line int) GoWorkModuleRef {
	ref := GoWorkModuleRef{
		Line:    line,
		Raw:     rawDir,
		RelPath: rawDir,
	}
	if workDir == "" {
		return ref
	}
	resolved := filepath.FromSlash(rawDir)
	if !filepath.IsAbs(resolved) {
		resolved = filepath.Join(workDir, resolved)
	}
	resolved = filepath.Clean(resolved)
	ref.Dir = resolved
	if rel, err := filepath.Rel(workDir, resolved); err == nil {
		ref.RelPath = formatGoWorkRelPath(rel)
	}
	if info, err := os.Stat(resolved); err == nil && info.IsDir() {
		ref.Exists = true
		modPath := filepath.Join(resolved, "go.mod")
		if rawMod, modErr := os.ReadFile(modPath); modErr == nil {
			ref.HasGoMod = true
			parsed := ParseGoModContent(string(rawMod), nil)
			ref.ModulePath = parsed.ModulePath
			ref.GoVersion = parsed.GoVersion
			ref.Requires = parsed.Requires
		}
	}
	return ref
}

func findUnlistedWorkModules(workDir string, coveredDirs map[string]bool) []GoWorkModuleRef {
	cleanRoot := filepath.Clean(workDir)
	var unlisted []GoWorkModuleRef
	_ = filepath.WalkDir(cleanRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			name := d.Name()
			if path != cleanRoot {
				if name == "vendor" || name == "node_modules" || strings.HasPrefix(name, ".") {
					return filepath.SkipDir
				}
				if rel, relErr := filepath.Rel(cleanRoot, path); relErr == nil {
					depth := strings.Count(filepath.ToSlash(rel), "/") + 1
					if depth > 4 {
						return filepath.SkipDir
					}
				}
			}
			return nil
		}
		if d.Name() != "go.mod" {
			return nil
		}
		dir := filepath.Clean(filepath.Dir(path))
		if coveredDirs[cleanResolvedPath(dir)] {
			return nil
		}
		rel, relErr := filepath.Rel(cleanRoot, dir)
		if relErr != nil {
			return nil
		}
		relTok := formatGoWorkRelPath(rel)
		parsed := GoModInspectReport{}
		if data, readErr := os.ReadFile(path); readErr == nil {
			parsed = ParseGoModContent(string(data), nil)
		}
		unlisted = append(unlisted, GoWorkModuleRef{
			RelPath:    relTok,
			Dir:        dir,
			ModulePath: parsed.ModulePath,
			GoVersion:  parsed.GoVersion,
			Exists:     true,
			HasGoMod:   true,
		})
		return nil
	})
	sort.Slice(unlisted, func(i, j int) bool {
		return unlisted[i].RelPath < unlisted[j].RelPath
	})
	return unlisted
}

func formatGoWorkRelPath(rel string) string {
	slash := filepath.ToSlash(filepath.Clean(rel))
	if slash == "." || strings.HasPrefix(slash, "./") || strings.HasPrefix(slash, "../") {
		return slash
	}
	return "./" + slash
}

func cleanResolvedPath(p string) string {
	cleaned := filepath.Clean(p)
	if eval, err := filepath.EvalSymlinks(cleaned); err == nil {
		return eval
	}
	return cleaned
}

func normalizeGoDirectiveVersion(raw string) string {
	v := strings.TrimSpace(raw)
	if v == "" {
		return ""
	}
	if !strings.HasPrefix(v, "go") {
		v = "go" + v
	}
	if !version.IsValid(v) {
		return ""
	}
	return v
}

func detectWorkspaceDependencySkew(modules []GoWorkModuleRef) string {
	if len(modules) < 2 {
		return ""
	}
	seenVersions := make(map[string]map[string]string)
	for _, m := range modules {
		for _, r := range m.Requires {
			if r.Module == "" || r.Version == "" || !strings.HasPrefix(r.Version, "v") {
				continue
			}
			byVer := seenVersions[r.Module]
			if byVer == nil {
				byVer = make(map[string]string)
				seenVersions[r.Module] = byVer
			}
			if _, ok := byVer[r.Version]; !ok {
				byVer[r.Version] = m.RelPath
			}
		}
	}
	var skewed []string
	for modPath, byVer := range seenVersions {
		if len(byVer) > 1 {
			skewed = append(skewed, modPath)
		}
	}
	sort.Strings(skewed)
	if len(skewed) == 0 {
		return ""
	}
	if len(skewed) == 1 {
		return fmt.Sprintf("Modules disagree on version of %s; run Sync Workspace.", skewed[0])
	}
	return fmt.Sprintf("Modules disagree on versions of %d shared dependencies (e.g. %s); run Sync Workspace.", len(skewed), skewed[0])
}

func GoModWhyJSON(goModPath string, module string) string {
	mod := strings.TrimSpace(module)
	if mod == "" || goModPath == "" {
		b, _ := json.Marshal(GoModWhyReport{
			Module: mod,
			Error:  "Module path and target module name are required.",
		})
		return string(b)
	}
	dir := goModPath
	if info, err := os.Stat(goModPath); err != nil || !info.IsDir() {
		dir = filepath.Dir(goModPath)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	out, err := runGoTool(ctx, dir, nil, "mod", "why", "-m", mod)
	raw := string(out)
	if err != nil {
		msg := strings.TrimSpace(raw)
		if msg == "" {
			msg = err.Error()
		}
		b, _ := json.Marshal(GoModWhyReport{
			Module: mod,
			Raw:    raw,
			Error:  msg,
		})
		return string(b)
	}
	report := ParseGoModWhyOutput(mod, raw)
	b, marshalErr := json.Marshal(report)
	if marshalErr != nil {
		return "{}"
	}
	return string(b)
}

func ParseGoModWhyOutput(module string, raw string) GoModWhyReport {
	report := GoModWhyReport{
		Module: module,
		Raw:    raw,
	}
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	var current *GoModWhyStanza
	flush := func() {
		if current != nil {
			report.Stanzas = append(report.Stanzas, *current)
			current = nil
		}
	}
	for _, rawLine := range lines {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "# ") {
			flush()
			current = &GoModWhyStanza{
				Header: strings.TrimSpace(strings.TrimPrefix(trimmed, "# ")),
			}
			continue
		}
		if current == nil {
			current = &GoModWhyStanza{Header: module}
		}
		if strings.HasPrefix(trimmed, "(") && strings.HasSuffix(trimmed, ")") {
			current.Note = strings.TrimSuffix(strings.TrimPrefix(trimmed, "("), ")")
			continue
		}
		current.Chain = append(current.Chain, trimmed)
		report.Needed = true
	}
	flush()

	if report.Needed && len(report.Stanzas) > 0 {
		for _, st := range report.Stanzas {
			if len(st.Chain) > 0 {
				report.Summary = strings.Join(st.Chain, " -> ")
				break
			}
		}
	} else if len(report.Stanzas) > 0 && report.Stanzas[0].Note != "" {
		report.Summary = report.Stanzas[0].Note
	} else {
		report.Summary = fmt.Sprintf("Main module does not require %s.", module)
	}
	return report
}

func GoWorkSyncJSON(goWorkPath string) string {
	if goWorkPath == "" {
		b, _ := json.Marshal(GoWorkSyncResult{
			OK:    false,
			Error: "Path to go.work is required.",
		})
		return string(b)
	}
	dir := goWorkPath
	if info, err := os.Stat(goWorkPath); err != nil || !info.IsDir() {
		dir = filepath.Dir(goWorkPath)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := runGoTool(ctx, dir, nil, "work", "sync")
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		errMsg := trimmed
		if errMsg == "" {
			errMsg = err.Error()
		}
		b, _ := json.Marshal(GoWorkSyncResult{
			OK:     false,
			Output: trimmed,
			Error:  errMsg,
		})
		return string(b)
	}
	b, _ := json.Marshal(GoWorkSyncResult{
		OK:     true,
		Output: trimmed,
	})
	return string(b)
}
