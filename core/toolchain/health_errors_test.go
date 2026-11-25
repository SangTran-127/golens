package toolchain

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

func TestMain(m *testing.M) {
	if os.Getenv("GOLENS_TOOLCHAIN_STUB") == "1" {
		switch filepath.Base(os.Args[0]) {
		case "go-fail":
			os.Exit(1)
		case "go-partial":
			fmt.Print("go1.24.0\n/tmp/env\n")
			os.Exit(0)
		case "go-empty-goroot":
			fmt.Print("go1.24.0\n/tmp/env\n\n")
			os.Exit(0)
		case "go-empty-goenv":
			fmt.Print("go1.24.0\n\n/tmp/root\n")
			os.Exit(0)
		case "go-badver":
			fmt.Print("devel +abc\n/tmp/env\n/tmp/root\n")
			os.Exit(0)
		case "go-slow":
			time.Sleep(2500 * time.Millisecond)
			os.Exit(0)
		case "go":
			switch os.Getenv("GOLENS_TOOLCHAIN_STUB_MODE") {
			case "off":
				if len(os.Args) > 2 && os.Args[1] == "env" && os.Args[2] == "GOVERSION" {
					fmt.Print("go1.24.0\noff\n/tmp/root\n")
				}
				os.Exit(0)
			case "err":
				if len(os.Args) > 2 && os.Args[2] == "-w" {
					fmt.Fprintln(os.Stderr, "go: cannot write env")
					os.Exit(1)
				}
				fmt.Print("go1.24.0\n/tmp/env\n/tmp/root\n")
				os.Exit(0)
			case "empty":
				if len(os.Args) > 2 && os.Args[2] == "-w" {
					os.Exit(2)
				}
				fmt.Print("go1.24.0\n/tmp/env\n/tmp/root\n")
				os.Exit(0)
			}
		}
	}
	os.Exit(m.Run())
}

func symlinkSelfExecutable(t *testing.T, dir, name string) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, name)
	if err := os.Symlink(self, dst); err != nil {
		t.Fatal(err)
	}
	return dst
}

func writeExecutable(t *testing.T, dir, name, script string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func copySelfExecutable(t *testing.T, dir, name string) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	in, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	dst := filepath.Join(dir, name)
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		t.Fatal(err)
	}
	if err := out.Close(); err != nil {
		t.Fatal(err)
	}
	return dst
}

func TestRequiredMissingAndInvalidDirectives(t *testing.T) {
	root := t.TempDir()
	modPath := filepath.Join(root, "go.mod")
	write(t, modPath, "module example.com/nogo\n")
	req, dir, file := Required(root)
	if req != "" || dir != "" || file != modPath {
		t.Fatalf("missing go line: got %q %q %q", req, dir, file)
	}

	write(t, modPath, "module example.com/bad\n\ngo notaversion\n")
	req, dir, file = Required(root)
	if req != "" || dir != "" || file != modPath {
		t.Fatalf("invalid go line: got %q %q %q", req, dir, file)
	}

	if os.Geteuid() != 0 {
		lockedRoot := t.TempDir()
		lockedMod := filepath.Join(lockedRoot, "go.mod")
		write(t, lockedMod, "module example.com/locked\n\ngo 1.24\n")
		if err := os.Chmod(lockedMod, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(lockedMod, 0o644) })
		if r, d, f := Required(lockedRoot); r != "" || d != "" || f != "" {
			t.Fatalf("unreadable go.mod should fall back: got %q %q %q", r, d, f)
		}
	}
}

func TestEffectiveAndEnvFileErrorBranches(t *testing.T) {
	if got, ok := Effective("go1.24.0", "banana", "go1.25.0"); got != "" || ok {
		t.Fatalf("invalid GOTOOLCHAIN = %q, %v; want \"\", false", got, ok)
	}
	if got, ok := Effective("go1.24.0", "go1.invalid+auto", "go1.25.0"); got != "go1.25.0" || !ok {
		t.Fatalf("invalid+auto = %q, %v; want go1.25.0, true", got, ok)
	}
	if got, ok := Effective("", "auto", "go1.25.0"); got != "go1.25.0" || !ok {
		t.Fatalf("empty installed auto = %q, %v", got, ok)
	}

	envPath := filepath.Join(t.TempDir(), "go.env")
	write(t, envPath, "GOPROXY=https://proxy.golang.org\n")
	if v, ok := envFileValue(envPath, "GOTOOLCHAIN"); ok || v != "" {
		t.Fatalf("missing key returned %q, %v", v, ok)
	}

	script := writeExecutable(t, t.TempDir(), "gopls", "#!/bin/sh\necho fake\n")
	if goVer, modVer := goplsGoVersion(script); goVer != "" || modVer != "" {
		t.Fatalf("non-binary gopls = %q %q", goVer, modVer)
	}
}

func TestLocalGoFailuresAndTimeout(t *testing.T) {
	t.Setenv("GOLENS_TOOLCHAIN_STUB", "1")
	dir := t.TempDir()

	failBin := symlinkSelfExecutable(t, dir, "go-fail")
	if gv, ge, gr := localGo(failBin); gv != "" || ge != "" || gr != "" {
		t.Fatalf("failing go = %q %q %q", gv, ge, gr)
	}

	partialBin := symlinkSelfExecutable(t, dir, "go-partial")
	if gv, ge, gr := localGo(partialBin); gv != "" || ge != "" || gr != "" {
		t.Fatalf("partial output = %q %q %q", gv, ge, gr)
	}

	badVerBin := symlinkSelfExecutable(t, dir, "go-badver")
	if gv, ge, gr := localGo(badVerBin); gv != "" || ge != "/tmp/env" || gr != "/tmp/root" {
		t.Fatalf("invalid version = %q %q %q", gv, ge, gr)
	}

	slowBin := symlinkSelfExecutable(t, dir, "go-slow")
	if gv, ge, gr := localGo(slowBin); gv != "" || ge != "" || gr != "" {
		t.Fatalf("timed out go = %q %q %q", gv, ge, gr)
	}
}

func TestCheckMissingToolsAndSandboxMode(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "go.mod"), "module example.com/app\n\ngo 1.25\n")

	emptyBin := t.TempDir()
	t.Setenv("PATH", emptyBin)
	t.Setenv("GOTOOLCHAIN", "")

	h := Check(root)
	if h.GoPath != "" || h.GoplsPath != "" || h.GoTooOld || h.GoplsOutdated {
		t.Fatalf("missing tools check = %+v", h)
	}

	prevMode := bridge.ExecutionMode()
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })
	bridge.SetExecutionMode("vm")
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "com.golens.test")

	binDir := t.TempDir()
	t.Setenv("PATH", binDir)
	copySelfExecutable(t, binDir, "go")
	copySelfExecutable(t, binDir, "gopls")

	h = Check(root)
	if h.GoPath == "" || h.GoVersion == "" || h.GoplsPath == "" || h.GoplsGo == "" {
		t.Fatalf("sandbox Check with binaries = %+v", h)
	}

	raw := CheckJSON(root)
	var decoded Health
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		t.Fatalf("CheckJSON invalid: %v (%s)", err, raw)
	}
	if decoded.Required != "go1.25.0" || decoded.GoPath != h.GoPath {
		t.Fatalf("decoded CheckJSON = %+v", decoded)
	}

	scriptDir := t.TempDir()
	t.Setenv("PATH", scriptDir)
	writeExecutable(t, scriptDir, "go", "#!/bin/sh\nexit 0\n")
	writeExecutable(t, scriptDir, "gopls", "#!/bin/sh\nexit 0\n")
	h = Check(root)
	if h.GoVersion != "" || h.GoplsGo != "" || h.Toolchain != "auto" {
		t.Fatalf("sandbox Check with non-Go scripts = %+v", h)
	}
}

func TestAllowAutomaticErrorPaths(t *testing.T) {
	prevMode := bridge.ExecutionMode()
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })

	bridge.SetExecutionMode("vm")
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "com.golens.test")
	if msg := AllowAutomatic(); !strings.Contains(msg, "App Sandbox") {
		t.Fatalf("sandbox AllowAutomatic = %q", msg)
	}

	t.Setenv("APP_SANDBOX_CONTAINER_ID", "")
	t.Setenv("HOME", t.TempDir())
	bridge.SetExecutionMode("host")

	t.Setenv("PATH", t.TempDir())
	if msg := AllowAutomatic(); !strings.Contains(msg, "PATH") {
		t.Fatalf("missing go AllowAutomatic = %q", msg)
	}

	binDir := t.TempDir()
	t.Setenv("PATH", binDir)
	t.Setenv("GOLENS_TOOLCHAIN_STUB", "1")
	symlinkSelfExecutable(t, binDir, "go")

	t.Setenv("GOLENS_TOOLCHAIN_STUB_MODE", "off")
	if msg := AllowAutomatic(); !strings.Contains(msg, "GOENV is off") {
		t.Fatalf("GOENV=off AllowAutomatic = %q", msg)
	}

	t.Setenv("GOLENS_TOOLCHAIN_STUB_MODE", "err")
	if msg := AllowAutomatic(); msg != "go: cannot write env" {
		t.Fatalf("stderr AllowAutomatic = %q", msg)
	}

	t.Setenv("GOLENS_TOOLCHAIN_STUB_MODE", "empty")
	if msg := AllowAutomatic(); !strings.Contains(msg, "exit status 2") {
		t.Fatalf("empty stderr AllowAutomatic = %q", msg)
	}
}

func TestToolchainEmptyGoEnvAndGoWorkPriority(t *testing.T) {
	t.Setenv("GOLENS_TOOLCHAIN_STUB", "1")
	dir := t.TempDir()

	emptyGoroot := symlinkSelfExecutable(t, dir, "go-empty-goroot")
	if gv, ge, gr := localGo(emptyGoroot); gv != "go1.24.0" || ge != "/tmp/env" || gr != "" {
		t.Fatalf("empty GOROOT localGo = %q %q %q", gv, ge, gr)
	}

	emptyGoenv := symlinkSelfExecutable(t, dir, "go-empty-goenv")
	if gv, ge, gr := localGo(emptyGoenv); gv != "go1.24.0" || ge != "" || gr != "/tmp/root" {
		t.Fatalf("empty GOENV localGo = %q %q %q", gv, ge, gr)
	}

	wsParent := t.TempDir()
	appDir := filepath.Join(wsParent, "app")
	otherDir := filepath.Join(wsParent, "other")
	write(t, filepath.Join(appDir, "go.mod"), "module example.com/app\n\ngo 1.24\n")
	write(t, filepath.Join(otherDir, "go.mod"), "module example.com/other\n\ngo 1.21\n")
	write(t, filepath.Join(wsParent, "go.work"), "go 1.21\n\nuse ./other\n")

	req, directive, file := Required(appDir)
	if req != "go1.24.0" || directive != "go 1.24" || file != filepath.Join(appDir, "go.mod") {
		t.Fatalf("unrelated parent go.work hid app go.mod: %q %q %q", req, directive, file)
	}

	write(t, filepath.Join(wsParent, "go.work"), "use (\n\t./app\n\t./other\n)\n")
	req, directive, file = Required(appDir)
	if req != "go1.24.0" || directive != "go 1.24" || file != filepath.Join(appDir, "go.mod") {
		t.Fatalf("parent go.work without go directive hid app go.mod: %q %q %q", req, directive, file)
	}

	write(t, filepath.Join(wsParent, "go.work"), "go 1.26.1\n\nuse ./app\n")
	req, directive, file = Required(appDir)
	if req != "go1.26.1" || directive != "go 1.26.1" || file != filepath.Join(wsParent, "go.work") {
		t.Fatalf("covering parent go.work did not take precedence: %q %q %q", req, directive, file)
	}
}
