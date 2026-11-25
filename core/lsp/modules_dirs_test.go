package lsp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/vmexec"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestModuleListDirsUsesNestedModuleInsideWorkspaceGuestRoot(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "backend", "go.mod"), "module example.com/backend\n")
	writeFile(t, filepath.Join(root, "frontend", "package.json"), "{}\n")

	hostDir, guestDir := moduleListDirs(root)
	if hostDir != filepath.Join(root, "backend") {
		t.Fatalf("hostDir = %q, want backend module", hostDir)
	}
	want := "/workspaces/" + vmexec.WorkspaceSlug(root) + "/backend"
	if guestDir != want {
		t.Fatalf("guestDir = %q, want %q", guestDir, want)
	}
}

func TestModuleListDirsKeepsRootModule(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "go.mod"), "module example.com/root\n")
	writeFile(t, filepath.Join(root, "tools", "go.mod"), "module example.com/tools\n")

	hostDir, guestDir := moduleListDirs(root)
	if hostDir != filepath.Clean(root) {
		t.Fatalf("hostDir = %q, want root", hostDir)
	}
	if guestDir != "/workspaces/"+vmexec.WorkspaceSlug(root) {
		t.Fatalf("guestDir = %q", guestDir)
	}
}

func TestResolveModuleDirsDoesNotHideCommonGoPackageDirNames(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"build", "output", "target", "dist"} {
		writeFile(t, filepath.Join(root, name, "go.mod"), "module example.com/"+name+"\n")
	}
	writeFile(t, filepath.Join(root, "node_modules", "go.mod"), "module example.com/nm\n")

	dirs := resolveModuleDirs(root)
	joined := strings.Join(dirs, ",")
	for _, name := range []string{"build", "output", "target", "dist"} {
		if !strings.Contains(joined, filepath.Join(root, name)) {
			t.Fatalf("module dir %q missing from %v", name, dirs)
		}
	}
	if strings.Contains(joined, "node_modules") {
		t.Fatalf("node_modules must stay excluded: %v", dirs)
	}
}

func TestGoplsCompletesUnimportedPackagesLocallyAndInTheVM(t *testing.T) {
	for _, remote := range []bool{false, true} {
		if on, _ := goplsSettingsFor(remote)["completeUnimported"].(bool); !on {
			t.Fatalf("completeUnimported must be on (remote=%v)", remote)
		}
	}
}

func TestGoplsDirectoryFiltersKeepGoPackageDirNames(t *testing.T) {
	filters, _ := goplsSettingsFor(true)["directoryFilters"].([]string)
	for _, f := range filters {
		for _, name := range []string{"build", "output", "out", "target", "dist", "vendor", "coverage"} {
			if f == "-**/"+name {
				t.Fatalf("directoryFilters must not exclude %q, which is a common Go package name", name)
			}
		}
	}
	if len(filters) == 0 || filters[0] != "-**/node_modules" {
		t.Fatalf("node_modules filter missing: %v", filters)
	}
}
