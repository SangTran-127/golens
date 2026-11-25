package search

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRunStopsReadingFilesOnceCapIsExceeded(t *testing.T) {
	root := t.TempDir()
	hits := strings.Repeat("hit\n", MaxMatchesInFile)
	hitFiles := MaxMatches/MaxMatchesInFile + 5
	for i := range hitFiles {
		write(t, root, filepath.Join("a", fmt.Sprintf("h%03d.txt", i)), hits)
	}
	const fillers = 6000
	for i := range fillers {
		write(t, root, filepath.Join("z", fmt.Sprintf("f%05d.txt", i)), "nothing here\n")
	}

	var opened atomic.Int64
	prev := openFile
	openFile = func(name string) (*os.File, error) {
		opened.Add(1)
		return os.Open(name)
	}
	defer func() { openFile = prev }()

	files, done := collect(t, root, "hit")
	total := 0
	for _, f := range files {
		total += len(f.Matches)
	}
	if total != MaxMatches || done.Total != MaxMatches || !done.Truncated || !done.Done {
		t.Fatalf("total %d done %+v", total, done)
	}
	if n := opened.Load(); n >= int64(hitFiles+fillers)/2 {
		t.Fatalf("opened %d of %d files after the cap was reached", n, hitFiles+fillers)
	}
}

func TestRunExactCapIsNotTruncated(t *testing.T) {
	root := t.TempDir()
	hits := strings.Repeat("hit\n", MaxMatchesInFile)
	for i := range MaxMatches / MaxMatchesInFile {
		write(t, root, fmt.Sprintf("h%03d.txt", i), hits)
	}
	write(t, root, "zz.txt", "nothing\n")
	_, done := collect(t, root, "hit")
	if done.Total != MaxMatches || done.Truncated {
		t.Fatalf("done %+v", done)
	}
}

func TestCachedGitFilesReusesListWithinTTL(t *testing.T) {
	root := t.TempDir()
	gitFilesCacheMu.Lock()
	gitFilesCache[root] = gitFilesEntry{files: []string{"cached.go"}, at: time.Now()}
	gitFilesCacheMu.Unlock()
	defer func() {
		gitFilesCacheMu.Lock()
		delete(gitFilesCache, root)
		gitFilesCacheMu.Unlock()
	}()
	files, ok := cachedGitFiles(t.Context(), root)
	if !ok || len(files) != 1 || files[0] != "cached.go" {
		t.Fatalf("files %v ok %v", files, ok)
	}
	gitFilesCacheMu.Lock()
	gitFilesCache[root] = gitFilesEntry{files: []string{"cached.go"}, at: time.Now().Add(-2 * gitFilesCacheTTL)}
	gitFilesCacheMu.Unlock()
	if files, ok := cachedGitFiles(t.Context(), root); ok && len(files) == 1 && files[0] == "cached.go" {
		t.Fatalf("expired entry reused: %v", files)
	}
}
