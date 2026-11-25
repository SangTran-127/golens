package refactor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApplyGoMultiBufferEdits_KeepsBackupWhenRestoreFails(t *testing.T) {
	dir := t.TempDir()
	originals := map[string]string{
		filepath.Join(dir, "a.go"): "package main\n\nvar A = 1\n",
		filepath.Join(dir, "b.go"): "package main\n\nvar B = 2\n",
	}
	var edits []MultiBufferFileEdit
	for path, content := range originals {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		edits = append(edits, MultiBufferFileEdit{
			FilePath: path,
			Edits:    []MultiBufferEdit{{FilePath: path, StartLine: 3, EndLine: 3, NewLines: "var Z = 9"}},
		})
	}

	commits := 0
	renameFile = func(from, to string) error {
		if strings.HasSuffix(from, ".bak") {
			return errors.New("restore refused")
		}
		commits++
		if commits == 2 {
			return errors.New("rename refused")
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renameFile = os.Rename })

	res, err := ApplyGoMultiBufferEdits(edits)
	if err == nil || res.Success {
		t.Fatalf("expected the batch to fail")
	}

	matches, _ := filepath.Glob(filepath.Join(dir, ".golens_bak_*"))
	if len(matches) != 1 {
		t.Fatalf("expected exactly one kept backup, found %v", matches)
	}
	bak := matches[0]
	if !strings.Contains(res.ErrorMessage, bak) {
		t.Errorf("error message does not name the kept backup %s: %s", bak, res.ErrorMessage)
	}
	data, readErr := os.ReadFile(bak)
	if readErr != nil {
		t.Fatalf("kept backup is unreadable: %v", readErr)
	}
	found := false
	for _, content := range originals {
		if string(data) == content {
			found = true
		}
	}
	if !found {
		t.Errorf("kept backup does not hold an original file: %q", data)
	}

	tmps, _ := filepath.Glob(filepath.Join(dir, ".golens_tmp_*"))
	if len(tmps) != 0 {
		t.Errorf("temp files leaked: %v", tmps)
	}
}
