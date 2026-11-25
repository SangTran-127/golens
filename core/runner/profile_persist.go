package runner

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

const keptProfileAge = 6 * time.Hour

func persistProfiles(runID int64, groups map[string][]string) map[string][]string {
	dir := filepath.Join(os.TempDir(), "golens-profiles")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil
	}
	pruneProfiles(dir, time.Now().Add(-keptProfileAge))
	saved := make(map[string][]string)
	for kind, paths := range groups {
		for index, source := range paths {
			target := filepath.Join(dir, fmt.Sprintf("run%d-%s-%d.pprof", runID, kind, index))
			if copyProfile(source, target) == nil {
				saved[kind] = append(saved[kind], target)
			}
		}
	}
	return saved
}

func copyProfile(source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil || info.Size() == 0 {
		return fmt.Errorf("empty profile")
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func pruneProfiles(dir string, olderThan time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if err == nil && !entry.IsDir() && info.ModTime().Before(olderThan) {
			_ = os.Remove(filepath.Join(dir, entry.Name()))
		}
	}
}
