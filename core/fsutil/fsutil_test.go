package fsutil

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCreateFileOrFolderNeverTruncatesAnExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "main.go")
	if err := os.WriteFile(path, []byte("package main\n\nfunc main() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if CreateFileOrFolder(path, false) {
		t.Error("creating over an existing file reported success")
	}
	if b, _ := os.ReadFile(path); string(b) != "package main\n\nfunc main() {}\n" {
		t.Errorf("existing file changed: %q", b)
	}
}

func TestCreateFileOrFolderSmartGoPackageName(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module example.com/app\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		rel  string
		want string
	}{
		{"cmd/server/main.go", "package main\n\n"},
		{"cmd/cli/main.go", "package main\n\n"},
		{"cmd/server/handler.go", "package main\n\n"},
		{"internal/store/store.go", "package store\n\n"},
		{"root_helper.go", "package main\n\n"},
	}

	for _, tc := range cases {
		p := filepath.Join(root, tc.rel)
		if !CreateFileOrFolder(p, false) {
			t.Fatalf("CreateFileOrFolder(%q) failed", tc.rel)
		}
		got, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("ReadFile(%q): %v", tc.rel, err)
		}
		if string(got) != tc.want {
			t.Errorf("%s: got %q, want %q", tc.rel, string(got), tc.want)
		}
	}

	customDir := filepath.Join(root, "pkg", "v2-api")
	if err := os.MkdirAll(customDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(customDir, "first.go"), []byte("package custompkg\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	secondPath := filepath.Join(customDir, "second.go")
	if !CreateFileOrFolder(secondPath, false) {
		t.Fatal("failed to create second.go")
	}
	if got, _ := os.ReadFile(secondPath); string(got) != "package custompkg\n\n" {
		t.Errorf("sibling package inference: got %q, want %q", string(got), "package custompkg\n\n")
	}

	testOnlyDir := filepath.Join(root, "pkg", "onlytest")
	if err := os.MkdirAll(testOnlyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(testOnlyDir, "widget_test.go"), []byte("package widget_test\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	implPath := filepath.Join(testOnlyDir, "widget.go")
	if !CreateFileOrFolder(implPath, false) {
		t.Fatal("failed to create widget.go")
	}
	if got, _ := os.ReadFile(implPath); string(got) != "package widget\n\n" {
		t.Errorf("test sibling package inference: got %q, want %q", string(got), "package widget\n\n")
	}
}

func TestCreateFileOrFolderWithError_ExistingAndPermission(t *testing.T) {
	root := t.TempDir()

	existingFile := filepath.Join(root, "already.go")
	if err := os.WriteFile(existingFile, []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CreateFileOrFolderWithError(existingFile, false); !errors.Is(err, os.ErrExist) {
		t.Fatalf("expected ErrExist for existing file, got %v", err)
	}

	existingDir := filepath.Join(root, "existingdir")
	if err := os.Mkdir(existingDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := CreateFileOrFolderWithError(existingDir, true); !errors.Is(err, os.ErrExist) {
		t.Fatalf("expected ErrExist for existing directory, got %v", err)
	}

	nestedDir := filepath.Join(root, "parent", "child/")
	if err := CreateFileOrFolderWithError(nestedDir, true); err != nil {
		t.Fatalf("expected nested folder creation to succeed, got %v", err)
	}
	if info, err := os.Stat(filepath.Clean(nestedDir)); err != nil || !info.IsDir() {
		t.Fatalf("expected directory at %s, err=%v", nestedDir, err)
	}

	if err := CreateFileOrFolderWithError("", false); !errors.Is(err, os.ErrInvalid) {
		t.Fatalf("expected ErrInvalid for empty path, got %v", err)
	}

	if os.Geteuid() != 0 {
		roDir := filepath.Join(root, "readonly")
		if err := os.Mkdir(roDir, 0o555); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(roDir, 0o755) })

		fileErr := CreateFileOrFolderWithError(filepath.Join(roDir, "blocked.go"), false)
		if !errors.Is(fileErr, os.ErrPermission) {
			t.Fatalf("expected ErrPermission creating file in read-only folder, got %v", fileErr)
		}

		dirErr := CreateFileOrFolderWithError(filepath.Join(roDir, "blockeddir"), true)
		if !errors.Is(dirErr, os.ErrPermission) {
			t.Fatalf("expected ErrPermission creating folder in read-only folder, got %v", dirErr)
		}
	}
}

func TestSplitArgsPreservesQuotes(t *testing.T) {
	got := SplitArgs(`-owner "Daily QA" -tag 'hello world' -escaped "a\"b"`)
	want := []string{"-owner", "Daily QA", "-tag", "hello world", "-escaped", `a"b`}
	if len(got) != len(want) {
		t.Fatalf("len(got)=%d (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("arg[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

