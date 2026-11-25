package vmexec

import (
	"errors"
	"path/filepath"
	"slices"
	"testing"
)

func TestWorkspaceSlugMatchesSwiftForVietnamesePaths(t *testing.T) {
	const swiftSlug = "Tài-(copy)!-859a1c7c"
	for _, p := range []string{
		"/Users/dev/Dự án/Tài (copy)!",
		"/Users/dev/Dự án/Tài (copy)!",
		"/Users/dev/Dự án/Tài (copy)!/",
	} {
		if got := WorkspaceSlug(p); got != swiftSlug {
			t.Errorf("WorkspaceSlug(%q) = %q, want %q", p, got, swiftSlug)
		}
	}
	if got := WorkspaceSlug("/Users/dev/projects/velo"); got != "velo-d8678b7e" {
		t.Errorf("ASCII slug changed: %q", got)
	}
}

func TestWorkspaceSlugCandidatesKeepLegacySpelling(t *testing.T) {
	nfc := "/Users/dev/Tài"
	c := WorkspaceSlugCandidates(nfc)
	if c[0] != WorkspaceSlug(nfc) || len(c) != 2 || !slices.Contains(c, slugOf(nfc)) {
		t.Fatalf("candidates = %q", c)
	}
	if c := WorkspaceSlugCandidates("/Users/dev/app"); len(c) != 1 {
		t.Fatalf("ASCII path should have one candidate, got %q", c)
	}
}

func stubRoots(t *testing.T, exe, home, real string, existing ...string) {
	t.Helper()
	oldExe, oldHome, oldReal, oldExists := executablePath, userHomeDir, realHomeDir, pathExists
	t.Cleanup(func() { executablePath, userHomeDir, realHomeDir, pathExists = oldExe, oldHome, oldReal, oldExists })
	executablePath = func() (string, error) {
		if exe == "" {
			return "", errors.New("no executable")
		}
		return exe, nil
	}
	userHomeDir = func() (string, error) { return home, nil }
	realHomeDir = func() string { return real }
	pathExists = func(p string) bool { return slices.Contains(existing, filepath.Clean(p)) }
}

func TestHostShareRootsMirrorSandboxVMManager(t *testing.T) {
	container := "/Users/dev/Library/Containers/dev.golens.app/Data"
	appSupport := container + "/Library/Application Support/GoLens/VMRuntime"

	stubRoots(t, "/Applications/GoLens.app/Contents/MacOS/GoLens", container, "/Users/dev",
		appSupport+"/vmlinuz", "/Users/dev/go/pkg/mod")
	r := HostShareRoots()
	if r.Goroot != appSupport+"/goroot" || r.ModCache != "/Users/dev/go/pkg/mod" {
		t.Fatalf("sandboxed roots = %+v", r)
	}

	stubRoots(t, "/Applications/GoLens.app/Contents/MacOS/GoLens", container, "/Users/dev",
		"/Applications/GoLens.app/Contents/Resources/VMRuntime/vmlinuz", appSupport+"/vmlinuz")
	r = HostShareRoots()
	if r.Goroot != "/Applications/GoLens.app/Contents/Resources/VMRuntime/goroot" {
		t.Fatalf("bundled runtime not preferred: %+v", r)
	}
	if r.ModCache != container+"/Library/Caches/com.golens.app/gomod" {
		t.Fatalf("app module cache fallback = %q", r.ModCache)
	}

	stubRoots(t, "", container, "")
	r = HostShareRoots()
	if r.Goroot != appSupport+"/goroot" {
		t.Fatalf("missing runtime fallback = %+v", r)
	}
}
