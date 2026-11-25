package search

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

const vendored = "ven" + "dor"

func write(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, rel)
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func collect(t *testing.T, root, query string) ([]FileMatches, Batch) {
	t.Helper()
	var files []FileMatches
	var done Batch
	Run(context.Background(), root, query, func(b Batch) {
		files = append(files, b.Files...)
		if b.Done {
			done = b
		}
	})
	sort.Slice(files, func(i, j int) bool { return files[i].Relative < files[j].Relative })
	return files, done
}

func TestScanFileReportsLineColumnAndUTF16Offset(t *testing.T) {
	content := []byte("héllo\n𝔸 x Needle y needle\nnone\r\nlast NEEDLE")
	m := scanFile(content, lowerASCII(nil, content), []byte("needle"), 10)
	if len(m) != 3 {
		t.Fatalf("matches %+v", m)
	}
	if m[0].Line != 2 || m[0].Column != 5 || m[0].Offset != 11 || m[0].Length != 6 || m[0].Text != "𝔸 x Needle y needle" {
		t.Fatalf("first %+v", m[0])
	}
	// A second occurrence on the same line is its own match (Replace All relies on it).
	if m[1].Line != 2 || m[1].Column != 14 || m[1].Offset != 20 {
		t.Fatalf("same line %+v", m[1])
	}
	if m[2].Line != 4 || m[2].Column != 5 || m[2].Text != "last NEEDLE" {
		t.Fatalf("last %+v", m[2])
	}
	if scanFile([]byte("a\x00needle"), nil, []byte("needle"), 10) != nil {
		t.Fatal("binary file matched")
	}
}

func TestRunWalksWithoutGitAndSkipsFilteredFiles(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", "package a // Target\n")
	write(t, root, "sub/b.txt", "one\ntarget two\n")
	write(t, root, vendored+"/v.go", "target\n")
	write(t, root, ".hidden/h.go", "target\n")
	write(t, root, "img.png", "target\n")
	files, done := collect(t, root, "target")
	if len(files) != 2 || files[0].Relative != "a.go" || files[1].Relative != filepath.Join("sub", "b.txt") || files[1].Matches[0].Line != 2 {
		t.Fatalf("files %+v", files)
	}
	if !done.Done || done.Total != 2 || done.Truncated {
		t.Fatalf("done %+v", done)
	}
}

func TestRunHonoursGitignore(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	root := t.TempDir()
	if out, err := exec.Command("git", "-C", root, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	write(t, root, ".gitignore", "gen/\n*.log\n")
	write(t, root, "keep.go", "target\n")
	write(t, root, "gen/out.go", "target\n")
	write(t, root, "run.log", "target\n")
	write(t, root, vendored+"/x.go", "target\n")
	files, _ := collect(t, root, "target")
	if len(files) != 1 || files[0].Relative != "keep.go" {
		t.Fatalf("files %+v", files)
	}
}

func TestRunKeepsScanningPastExcludedGitFiles(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	root := t.TempDir()
	if out, err := exec.Command("git", "-C", root, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	// git lists files in byte order: the excluded image and vendored file come before the later sources.
	write(t, root, "assets/icon.png", "needle\n")
	write(t, root, "b/"+vendored+"/v.go", "needle\n")
	write(t, root, "c/later.go", "needle\n")
	write(t, root, "z.go", "needle\n")
	files, _ := collect(t, root, "needle")
	if len(files) != 2 || files[0].Relative != filepath.Join("c", "later.go") || files[1].Relative != "z.go" {
		t.Fatalf("files %+v", files)
	}
}

func TestRunCapsTotalMatches(t *testing.T) {
	root := t.TempDir()
	lines := strings.Repeat("hit\n", MaxMatchesInFile+5)
	for i := range MaxMatches/MaxMatchesInFile + 3 {
		write(t, root, filepath.Join("d", strings.Repeat("f", i+1)+".txt"), lines)
	}
	files, done := collect(t, root, "hit")
	total := 0
	for _, f := range files {
		if len(f.Matches) > MaxMatchesInFile {
			t.Fatalf("per-file cap exceeded: %d", len(f.Matches))
		}
		total += len(f.Matches)
	}
	if total != MaxMatches || done.Total != MaxMatches || !done.Truncated {
		t.Fatalf("total %d done %+v", total, done)
	}
}

func TestStartCancelsPreviousSearch(t *testing.T) {
	root := t.TempDir()
	for i := range 300 {
		write(t, root, filepath.Join("p", strings.Repeat("x", i%40+1), strings.Repeat("f", i/40+1)+".txt"), strings.Repeat("needle\n", 50))
	}
	finished := make(chan int64, 4)
	old := Emit
	t.Cleanup(func() { Emit = old })
	Emit = func(s string) {
		var b Batch
		if json.Unmarshal([]byte(s), &b) == nil && b.Done {
			finished <- b.ID
		}
	}
	first := Start(root, "needle")
	second := Start(root, "needle")
	select {
	case id := <-finished:
		if id != second {
			t.Fatalf("cancelled search %d finished (first %d, second %d)", id, first, second)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("no search finished")
	}
	select {
	case id := <-finished:
		t.Fatalf("extra done event %d", id)
	case <-time.After(300 * time.Millisecond):
	}
}
