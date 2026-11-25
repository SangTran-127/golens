package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"golens/core/lsp"
)

func listDirs(t *testing.T, out []byte) []string {
	t.Helper()
	var dirs []string
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var p struct{ Dir string }
		if err := dec.Decode(&p); errors.Is(err, io.EOF) {
			return dirs
		} else if err != nil {
			t.Fatal(err)
		}
		dirs = append(dirs, p.Dir)
	}
}

func TestMapGuestListOutput(t *testing.T) {
	host := t.TempDir()
	ws, mod, goroot := filepath.Join(host, "My Project"), filepath.Join(host, "mod"), filepath.Join(host, "goroot")
	for _, d := range []string{ws, mod, goroot} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	paths := lsp.NewURITranslatorWithRoots(lsp.TranslatorRoots{
		HostWorkspace:  ws,
		GuestWorkspace: "/workspaces/My-Project-1234abcd",
		HostModCache:   mod,
		HostGoroot:     goroot,
	})
	fixture := `{
	"Dir": "/workspaces/My-Project-1234abcd/internal/store",
	"ImportPath": "example.com/app/internal/store",
	"GoFiles": ["store.go"]
}
{
	"Dir": "/cache/gomod/github.com/x/y@v1.2.3",
	"ImportPath": "github.com/x/y"
}
{
	"Dir": "/usr/local/go/src/fmt",
	"ImportPath": "fmt"
}
{
	"Dir": "/workspaces/My-Project-1234abcd",
	"ImportPath": "example.com/app",
	"Error": {"Err": "/workspaces/My-Project-1234abcd/main.go:3:1: expected declaration"}
}
`
	out, err := mapGuestListOutput(paths, []byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		filepath.Join(ws, "internal/store"),
		filepath.Join(mod, "github.com/x/y@v1.2.3"),
		filepath.Join(goroot, "src/fmt"),
		ws,
	}
	if got := listDirs(t, out); !slices.Equal(got, want) {
		t.Fatalf("dirs = %q, want %q", got, want)
	}
	if !strings.Contains(string(out), ws+"/main.go:3:1") {
		t.Fatalf("error text keeps the guest path:\n%s", out)
	}

	if _, err := mapGuestListOutput(paths, []byte(`{"Dir": "/root/go/pkg/mod/a@v1"}`)); err == nil || !strings.Contains(err.Error(), "no host counterpart") {
		t.Fatalf("unmapped guest dir: err = %v", err)
	}
	noModCache := lsp.NewURITranslatorWithRoots(lsp.TranslatorRoots{HostWorkspace: ws, GuestWorkspace: "/workspaces/w", HostGoroot: goroot})
	if _, err := mapGuestListOutput(noModCache, []byte(`{"Dir": "/cache/gomod/a@v1"}`)); err == nil || !strings.Contains(err.Error(), "no host counterpart") {
		t.Fatalf("module cache without a host root: err = %v", err)
	}
	unreadable := lsp.NewURITranslatorWithRoots(lsp.TranslatorRoots{HostWorkspace: ws, GuestWorkspace: "/workspaces/w", HostModCache: mod, HostGoroot: filepath.Join(host, "missing")})
	if _, err := mapGuestListOutput(unreadable, []byte(`{"Dir": "/usr/local/go/src/fmt"}`)); err == nil || !strings.Contains(err.Error(), "cannot read") {
		t.Fatalf("unreadable GOROOT share: err = %v", err)
	}
}

func TestWriteListOverlay(t *testing.T) {
	dir := t.TempDir()
	same, changed, created := filepath.Join(dir, "same.go"), filepath.Join(dir, "changed.go"), filepath.Join(dir, "new.go")
	for _, p := range []string{same, changed} {
		if err := os.WriteFile(p, []byte("package m\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	buffers := map[string][]byte{
		same:                         []byte("package m\n"),
		changed:                      []byte("package m\n\nfunc F() {}\n"),
		created:                      []byte("package m\n\nfunc G() {}\n"),
		filepath.Join(dir, "go.mod"): []byte("module m\n"),
	}
	content := func(p string) ([]byte, bool) { b, ok := buffers[p]; return b, ok }
	var paths []string
	for p := range buffers {
		paths = append(paths, p)
	}
	tmp := t.TempDir()
	file, err := writeListOverlay(tmp, paths, content)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var overlay struct{ Replace map[string]string }
	if err := json.Unmarshal(raw, &overlay); err != nil {
		t.Fatal(err)
	}
	if len(overlay.Replace) != 2 || overlay.Replace[same] != "" {
		t.Fatalf("overlay = %v, want changed.go and new.go only", overlay.Replace)
	}
	for _, p := range []string{changed, created} {
		if got, _ := os.ReadFile(overlay.Replace[p]); !bytes.Equal(got, buffers[p]) {
			t.Fatalf("overlay content of %s = %q", p, got)
		}
	}
	if file, err := writeListOverlay(t.TempDir(), []string{same}, content); err != nil || file != "" {
		t.Fatalf("all buffers equal disk: file = %q, err = %v", file, err)
	}
}

func TestRunHostGoListSeesUnsavedImports(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "m.go")
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/m\n\ngo 1.26\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("package m\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	lsp.OpenDocument(path, []byte("package m\n\nimport _ \"strings\"\n"))
	t.Cleanup(func() { lsp.CloseDocument(path) })
	out, err := runHostGo(context.Background(), dir, "list", "-json=ImportPath,Imports", "./...")
	if err != nil {
		t.Fatal(err)
	}
	var p struct{ Imports []string }
	if err := json.Unmarshal(out, &p); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(p.Imports, "strings") {
		t.Fatalf("go list imports = %v, want the unsaved import strings", p.Imports)
	}
}
