package fsutil

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunDirFollowsTheOpenPackage(t *testing.T) {
	root := t.TempDir()
	write := func(rel, src string) string {
		p := filepath.Join(root, rel)
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		_ = os.WriteFile(p, []byte(src), 0o644)
		return p
	}
	server := write("cmd/server/main.go", "package main\n")
	hub := write("internal/chat/hub.go", "package chat\n")
	hubTest := write("internal/chat/hub_test.go", "package chat\n")

	for _, c := range []struct {
		name, wd, active, want string
		note                   bool
	}{
		{"main package", "", server, filepath.Dir(server), false},
		{"library falls back to root", "", hub, root, true},
		{"test file stays in its package", "", hubTest, filepath.Dir(hub), false},
		{"no file", "", "", root, false},
		{"relative working directory", "cmd/server", hub, filepath.Join(root, "cmd/server"), false},
		{"absolute working directory", "/abs/x", hub, "/abs/x", false},
	} {
		dir, note := RunDir(root, c.wd, c.active)
		if dir != c.want || (note != "") != c.note {
			t.Errorf("%s: got %q note %q, want %q", c.name, dir, note, c.want)
		}
	}
}
