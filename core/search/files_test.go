package search

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
)

func TestFilesListsSearchableFilesRelativeToRoot(t *testing.T) {
	root := t.TempDir()
	for _, f := range []string{"a.go", "sub/b.go", ".hidden/c.go", "vendor/x/d.go", "logo.png", "sub/.DS_Store"} {
		p := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("package x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := Files(root)
	slices.Sort(got)
	if want := []string{"a.go", "sub/b.go"}; !slices.Equal(got, want) {
		t.Fatalf("Files = %v, want %v", got, want)
	}
	// In a git repository the list comes from git ls-files, which reports untracked dot files too.
	if err := exec.Command("git", "-C", root, "init", "-q").Run(); err != nil {
		t.Skip("git unavailable")
	}
	got = Files(root)
	slices.Sort(got)
	// Tracked-or-untracked dot folders (.github) stay searchable there; Finder metadata does not.
	if want := []string{".hidden/c.go", "a.go", "sub/b.go"}; !slices.Equal(got, want) {
		t.Fatalf("Files = %v, want %v", got, want)
	}
}
