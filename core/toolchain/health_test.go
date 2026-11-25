package toolchain

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReleaseName(t *testing.T) {
	cases := map[string]string{
		"1.25":     "go1.25.0",
		"1.25.3":   "go1.25.3",
		"go1.24.1": "go1.24.1",
		"1.20":     "go1.20",
		"1.26rc1":  "go1.26rc1",
		"":         "",
		"banana":   "",
	}
	for in, want := range cases {
		if got := releaseName(in); got != want {
			t.Errorf("releaseName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRequiredUsesTheGoLine(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "go.mod"), "module example.com/a\n\ngo 1.24\n\ntoolchain go1.99.0\n")
	sub := filepath.Join(root, "cmd", "app")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	req, dir, file := Required(sub)
	if req != "go1.24.0" || dir != "go 1.24" || file != filepath.Join(root, "go.mod") {
		t.Errorf("the toolchain line is only a suggestion: %q %q %q", req, dir, file)
	}

	write(t, filepath.Join(root, "go.work"), "go 1.26.2\n\nuse ./\n")
	req, dir, file = Required(sub)
	if req != "go1.26.2" || dir != "go 1.26.2" || file != filepath.Join(root, "go.work") {
		t.Errorf("go.work wins: %q %q %q", req, dir, file)
	}

	if req, _, _ := Required(t.TempDir()); req != "" {
		t.Errorf("no module: %q", req)
	}
}

func TestEffective(t *testing.T) {
	const installed, required = "go1.23.4", "go1.25.0"
	cases := []struct {
		setting, want string
		ok            bool
	}{
		{"", "go1.25.0", true},
		{"auto", "go1.25.0", true},
		{"local", "go1.23.4", true},
		{"go1.24.0", "go1.24.0", true},
		{"go1.26.1", "go1.26.1", true},
		{"go1.24.0+auto", "go1.25.0", true},
		{"go1.26.1+auto", "go1.26.1", true},
		{"path", "", false},
		{"go1.24.0+path", "", false},
	}
	for _, c := range cases {
		got, ok := Effective(installed, c.setting, required)
		if got != c.want || ok != c.ok {
			t.Errorf("Effective(%q) = %q,%v want %q,%v", c.setting, got, ok, c.want, c.ok)
		}
	}
}

func TestEvaluate(t *testing.T) {
	h := Health{GoVersion: "go1.23.4", Toolchain: "local", Required: "go1.25.0", GoplsGo: "go1.24.9"}
	evaluate(&h)
	if !h.GoTooOld || !h.GoplsOutdated || h.BuildWith != "go1.25.0" || h.Effective != "go1.23.4" {
		t.Errorf("too old everywhere: %+v", h)
	}

	h = Health{GoVersion: "go1.27.1", Toolchain: "auto", Required: "go1.25.0", GoplsGo: "go1.27.1"}
	evaluate(&h)
	if h.GoTooOld || h.GoplsOutdated || h.BuildWith != "go1.27.1" {
		t.Errorf("healthy: %+v", h)
	}

	h = Health{GoVersion: "go1.27.1", Toolchain: "path", Required: "go1.99.0", GoplsGo: "go1.27.1"}
	evaluate(&h)
	if h.GoTooOld || !h.GoplsOutdated {
		t.Errorf("path mode never claims Go is too old, gopls still is: %+v", h)
	}

	h = Health{GoVersion: "go1.27.3", Toolchain: "auto", Required: "go1.27.3", GoplsGo: "go1.27.1"}
	evaluate(&h)
	if h.GoplsOutdated {
		t.Errorf("go/types checks the language version, so a patch release behind is fine: %+v", h)
	}

	h = Health{GoVersion: "", Toolchain: "local", Required: "go1.26.0", GoplsGo: ""}
	evaluate(&h)
	if h.GoTooOld || h.GoplsOutdated {
		t.Errorf("an unreadable Go version claims nothing: %+v", h)
	}

	h = Health{GoVersion: "go1.27.1", Toolchain: "auto", GoplsGo: "go1.20"}
	evaluate(&h)
	if h.GoTooOld || h.GoplsOutdated {
		t.Errorf("no module, no warnings: %+v", h)
	}
}

func TestGoplsGoVersionReadsBuildInfo(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	goVer, _ := goplsGoVersion(self)
	if want := strings.Fields(runtime.Version())[0]; goVer != want {
		t.Errorf("goplsGoVersion = %q, want %q", goVer, want)
	}
	if goVer, mod := goplsGoVersion(filepath.Join(t.TempDir(), "missing")); goVer != "" || mod != "" {
		t.Errorf("missing binary: %q %q", goVer, mod)
	}
}

func TestToolchainSettingSources(t *testing.T) {
	dir := t.TempDir()
	goEnv := filepath.Join(dir, "env")
	goRoot := filepath.Join(dir, "root")
	write(t, filepath.Join(goRoot, "go.env"), "# defaults\nGOTOOLCHAIN=local\n")

	t.Setenv("GOTOOLCHAIN", "")
	if s, src := toolchainSetting(goEnv, goRoot); s != "local" || src != "goroot" {
		t.Errorf("goroot: %q %q", s, src)
	}
	write(t, goEnv, "GOTOOLCHAIN=go1.24.0+auto\n")
	if s, src := toolchainSetting(goEnv, goRoot); s != "go1.24.0+auto" || src != "goenv" {
		t.Errorf("goenv: %q %q", s, src)
	}
	t.Setenv("GOTOOLCHAIN", "local")
	if s, src := toolchainSetting(goEnv, goRoot); s != "local" || src != "env" {
		t.Errorf("env: %q %q", s, src)
	}
	t.Setenv("GOTOOLCHAIN", "")
	if s, src := toolchainSetting(filepath.Join(dir, "none"), filepath.Join(dir, "none")); s != "auto" || src != "default" {
		t.Errorf("default: %q %q", s, src)
	}
}

func TestCheckOnThisMachine(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "go.mod"), "module example.com/x\n\ngo 1.99\n")
	t.Setenv("GOTOOLCHAIN", "local")
	h := Check(root)
	if h.GoPath == "" {
		t.Skip("go is not on PATH")
	}
	if h.Required != "go1.99.0" || h.ToolchainSource != "env" || !h.GoTooOld || h.GoVersion == "" {
		t.Errorf("GOTOOLCHAIN=local with go 1.99: %+v", h)
	}
}

func TestAllowAutomaticWritesGoEnvFile(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go is not on PATH")
	}
	goEnv := filepath.Join(t.TempDir(), "env")
	write(t, goEnv, "GOTOOLCHAIN=local\n")
	t.Setenv("GOENV", goEnv)
	t.Setenv("GOTOOLCHAIN", "")
	if msg := AllowAutomatic(); msg != "" {
		t.Fatalf("AllowAutomatic: %s", msg)
	}
	if v, _ := envFileValue(goEnv, "GOTOOLCHAIN"); v != "auto" {
		t.Errorf("GOTOOLCHAIN in env file = %q, want auto", v)
	}
}

func TestToolchainLineDoesNotWarnUnderLocal(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "go.mod"), "module example.com/x\n\ngo 1.24\n\ntoolchain go1.99.0\n")
	t.Setenv("GOTOOLCHAIN", "local")
	h := Check(root)
	if h.GoPath == "" {
		t.Skip("go is not on PATH")
	}
	if h.GoTooOld || h.GoplsOutdated {
		t.Errorf("go build succeeds here, so nothing may warn: %+v", h)
	}
}

func TestEnvFileValueIgnoresOffAndRelativePaths(t *testing.T) {
	t.Setenv("GOTOOLCHAIN", "")
	if s, src := toolchainSetting("off", filepath.Join(t.TempDir(), "none")); src != "default" || s != "auto" {
		t.Errorf("GOENV=off: %q %q", s, src)
	}
	if _, ok := envFileValue("relative/env", "GOTOOLCHAIN"); ok {
		t.Error("a relative path must not be read from the process working directory")
	}
}
