package runner

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPersistProfilesCopiesNonEmptyFilesAndSkipsEmpty(t *testing.T) {
	src := t.TempDir()
	good := filepath.Join(src, "cpu.pprof")
	empty := filepath.Join(src, "mem.pprof")
	if err := os.WriteFile(good, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	saved := persistProfiles(987654, map[string][]string{"cpu": {good}, "mem": {empty}})
	t.Cleanup(func() {
		for _, paths := range saved {
			for _, p := range paths {
				_ = os.Remove(p)
			}
		}
	})
	if len(saved["cpu"]) != 1 {
		t.Fatalf("cpu not saved: %v", saved)
	}
	if len(saved["mem"]) != 0 {
		t.Fatalf("empty profile must be skipped: %v", saved)
	}
	copied, err := os.ReadFile(saved["cpu"][0])
	if err != nil || string(copied) != "data" {
		t.Fatalf("copy mismatch: %v %q", err, copied)
	}
}

func TestPruneProfilesRemovesOnlyOldFiles(t *testing.T) {
	dir := t.TempDir()
	oldFile := filepath.Join(dir, "old.pprof")
	newFile := filepath.Join(dir, "new.pprof")
	for _, p := range []string{oldFile, newFile} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-24 * time.Hour)
	if err := os.Chtimes(oldFile, past, past); err != nil {
		t.Fatal(err)
	}
	pruneProfiles(dir, time.Now().Add(-time.Hour))
	if _, err := os.Stat(oldFile); !os.IsNotExist(err) {
		t.Fatal("old file should be removed")
	}
	if _, err := os.Stat(newFile); err != nil {
		t.Fatal("new file should remain")
	}
}
