package toolchain

import (
	"bufio"
	"bytes"
	"context"
	"debug/buildinfo"
	"encoding/json"
	"go/version"
	"golens/core/bridge"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Health struct {
	GoPath          string `json:"goPath"`
	GoVersion       string `json:"goVersion"`
	Toolchain       string `json:"toolchain"`
	ToolchainSource string `json:"toolchainSource"`
	Effective       string `json:"effective"`
	Required        string `json:"required"`
	Directive       string `json:"directive"`
	RequiredBy      string `json:"requiredBy"`
	GoplsPath       string `json:"goplsPath"`
	GoplsGo         string `json:"goplsGo"`
	GoplsVersion    string `json:"goplsVersion"`
	GoTooOld        bool   `json:"goTooOld"`
	GoplsOutdated   bool   `json:"goplsOutdated"`
	BuildWith       string `json:"buildWith"`
}

const goEnvTimeout = 2 * time.Second

func releaseName(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if !strings.HasPrefix(v, "go") {
		v = "go" + v
	}
	if !version.IsValid(v) {
		return ""
	}
	if version.Lang(v) == v && version.Compare(v, "go1.21") >= 0 {
		v += ".0"
	}
	return v
}

func maxVersion(a, b string) string {
	if a == "" || version.Compare(b, a) > 0 {
		return b
	}
	return a
}

func directives(text string) (goLine string) {
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		if f := strings.Fields(sc.Text()); len(f) >= 2 && f[0] == "go" {
			goLine = f[1]
		}
	}
	return goLine
}

func stripGoWorkComment(line string) string {
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
			return line[:i]
		}
	}
	return line
}

func firstGoWorkToken(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if s[0] == '"' || s[0] == '`' {
		q := s[0]
		for i := 1; i < len(s); i++ {
			if s[i] == '\\' && q == '"' && i+1 < len(s) {
				i++
				continue
			}
			if s[i] == q {
				val := s[1:i]
				if q == '"' {
					val = strings.ReplaceAll(val, `\"`, `"`)
					val = strings.ReplaceAll(val, `\\`, `\`)
				}
				return val
			}
		}
		return s[1:]
	}
	return strings.Fields(s)[0]
}

func workUseDirs(workDir, text string) []string {
	var dirs []string
	inBlock := false
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(stripGoWorkComment(sc.Text()))
		if line == "" {
			continue
		}
		if inBlock {
			if idx := strings.IndexByte(line, ')'); idx >= 0 {
				if before := strings.TrimSpace(line[:idx]); before != "" {
					if tok := firstGoWorkToken(before); tok != "" {
						dirs = append(dirs, resolveWorkUse(workDir, tok))
					}
				}
				inBlock = false
				continue
			}
			if tok := firstGoWorkToken(line); tok != "" {
				dirs = append(dirs, resolveWorkUse(workDir, tok))
			}
			continue
		}
		if line == "use" {
			continue
		}
		if strings.HasPrefix(line, "use") && (line[3] == ' ' || line[3] == '\t' || line[3] == '(') {
			rest := strings.TrimSpace(line[3:])
			if strings.HasPrefix(rest, "(") {
				rest = strings.TrimSpace(rest[1:])
				if idx := strings.IndexByte(rest, ')'); idx >= 0 {
					if tok := firstGoWorkToken(rest[:idx]); tok != "" {
						dirs = append(dirs, resolveWorkUse(workDir, tok))
					}
					continue
				}
				inBlock = true
				if tok := firstGoWorkToken(rest); tok != "" {
					dirs = append(dirs, resolveWorkUse(workDir, tok))
				}
				continue
			}
			if tok := firstGoWorkToken(rest); tok != "" {
				dirs = append(dirs, resolveWorkUse(workDir, tok))
			}
		}
	}
	return dirs
}

func resolveWorkUse(workDir, rel string) string {
	p := filepath.FromSlash(rel)
	if !filepath.IsAbs(p) {
		p = filepath.Join(workDir, p)
	}
	return filepath.Clean(p)
}

func withinDirPath(path, base string) bool {
	if base == string(filepath.Separator) {
		return strings.HasPrefix(path, base)
	}
	return path == base || strings.HasPrefix(path, base+string(filepath.Separator))
}

func workCovers(workDir, text, root string) bool {
	cleanRoot := filepath.Clean(root)
	evalRoot := cleanRoot
	if r, err := filepath.EvalSymlinks(cleanRoot); err == nil {
		evalRoot = r
	}
	for _, d := range workUseDirs(workDir, text) {
		if withinDirPath(cleanRoot, d) {
			return true
		}
		if r, err := filepath.EvalSymlinks(d); err == nil && withinDirPath(evalRoot, r) {
			return true
		}
	}
	return false
}

func Required(root string) (required, directive, file string) {
	cleanRoot := filepath.Clean(root)
	for dir := cleanRoot; ; dir = filepath.Dir(dir) {
		path := filepath.Join(dir, "go.work")
		if b, err := os.ReadFile(path); err == nil {
			text := string(b)
			if workCovers(dir, text, cleanRoot) {
				if goLine := directives(text); releaseName(goLine) != "" {
					return releaseName(goLine), "go " + goLine, path
				}
			}
		}
		if dir == filepath.Dir(dir) {
			break
		}
	}
	for dir := cleanRoot; ; dir = filepath.Dir(dir) {
		path := filepath.Join(dir, "go.mod")
		if b, err := os.ReadFile(path); err == nil {
			if goLine := directives(string(b)); releaseName(goLine) != "" {
				return releaseName(goLine), "go " + goLine, path
			}
			return "", "", path
		}
		if dir == filepath.Dir(dir) {
			break
		}
	}
	return "", "", ""
}

func Effective(installed, setting, required string) (string, bool) {
	name, mode, _ := strings.Cut(setting, "+")
	switch {
	case setting == "" || setting == "auto":
		return maxVersion(installed, required), true
	case setting == "local":
		return installed, true
	case setting == "path" || mode == "path":
		return "", false
	case mode == "auto":
		return maxVersion(maxVersion(installed, releaseName(name)), required), true
	default:
		if r := releaseName(name); r != "" {
			return r, true
		}
		return "", false
	}
}

func goplsGoVersion(path string) (goVersion, modVersion string) {
	info, err := buildinfo.ReadFile(path)
	if err != nil {
		return "", ""
	}
	goVersion = strings.Fields(info.GoVersion + " ")[0]
	if !version.IsValid(goVersion) {
		goVersion = ""
	}
	return goVersion, info.Main.Version
}

func envFileValue(path, key string) (string, bool) {
	if !filepath.IsAbs(path) {
		return "", false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	for line := range strings.SplitSeq(string(b), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok && k == key {
			return strings.TrimSpace(v), true
		}
	}
	return "", false
}

func localGo(goPath string) (goVersion, goEnv, goRoot string) {
	ctx, cancel := context.WithTimeout(context.Background(), goEnvTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, goPath, "env", "GOVERSION", "GOENV", "GOROOT")
	cmd.Dir = os.TempDir()
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local")
	out, err := cmd.Output()
	if err != nil {
		return "", "", ""
	}
	raw := strings.ReplaceAll(string(out), "\r\n", "\n")
	raw = strings.TrimSuffix(raw, "\n")
	lines := strings.Split(raw, "\n")
	if len(lines) != 3 {
		return "", "", ""
	}
	if fs := strings.Fields(lines[0]); len(fs) > 0 && version.IsValid(fs[0]) {
		goVersion = fs[0]
	}
	return goVersion, strings.TrimSpace(lines[1]), strings.TrimSpace(lines[2])
}

func toolchainSetting(goEnv, goRoot string) (setting, source string) {
	if v, ok := os.LookupEnv("GOTOOLCHAIN"); ok && v != "" {
		return v, "env"
	}
	if goEnv == "off" {
		goEnv = ""
	}
	if v, ok := envFileValue(goEnv, "GOTOOLCHAIN"); ok && v != "" {
		return v, "goenv"
	}
	if v, ok := envFileValue(filepath.Join(goRoot, "go.env"), "GOTOOLCHAIN"); ok && v != "" {
		return v, "goroot"
	}
	return "auto", "default"
}

func Check(root string) Health {
	var h Health
	h.Required, h.Directive, h.RequiredBy = Required(root)
	if !bridge.IsSandboxed() || bridge.IsHostMode() {
		if p, err := exec.LookPath("gopls"); err == nil {
			h.GoplsPath = p
			h.GoplsGo, h.GoplsVersion = goplsGoVersion(p)
		}
		if p, err := exec.LookPath("go"); err == nil {
			h.GoPath = p
			var goEnv, goRoot string
			h.GoVersion, goEnv, goRoot = localGo(p)
			h.Toolchain, h.ToolchainSource = toolchainSetting(goEnv, goRoot)
		}
	} else {
		if p, err := exec.LookPath("gopls"); err == nil {
			h.GoplsPath = p
			h.GoplsGo, h.GoplsVersion = goplsGoVersion(p)
		}
		if p, err := exec.LookPath("go"); err == nil {
			h.GoPath = p
			if info, err := buildinfo.ReadFile(p); err == nil {
				h.GoVersion = strings.Fields(info.GoVersion + " ")[0]
				if !version.IsValid(h.GoVersion) {
					h.GoVersion = ""
				}
			}
			h.Toolchain, h.ToolchainSource = toolchainSetting("", "")
		}
	}
	evaluate(&h)
	return h
}

func evaluate(h *Health) {
	if h.Required == "" {
		return
	}
	if h.GoVersion != "" {
		if eff, ok := Effective(h.GoVersion, h.Toolchain, h.Required); ok {
			h.Effective = eff
			h.GoTooOld = version.Compare(eff, h.Required) < 0
		}
	}
	h.GoplsOutdated = h.GoplsGo != "" && version.Compare(version.Lang(h.GoplsGo), version.Lang(h.Required)) < 0
	h.BuildWith = maxVersion(h.GoVersion, h.Required)
}

func AllowAutomatic() string {
	if bridge.IsSandboxed() && !bridge.IsHostMode() {
		return "Changing host toolchain settings is disabled under App Sandbox."
	}
	goPath, err := exec.LookPath("go")
	if err != nil {
		return "The go command isn’t on this Mac’s PATH."
	}
	if _, goEnv, _ := localGo(goPath); goEnv == "off" {
		return "GOENV is off, so Go has no settings file to change. Set GOTOOLCHAIN=auto where GOENV is set instead."
	}
	ctx, cancel := context.WithTimeout(context.Background(), goEnvTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, goPath, "env", "-w", "GOTOOLCHAIN=auto")
	cmd.Dir = os.TempDir()
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return msg
		}
		return err.Error()
	}
	return ""
}

func CheckJSON(root string) string {
	b, _ := json.Marshal(Check(root))
	return string(b)
}
