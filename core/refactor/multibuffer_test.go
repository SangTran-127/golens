package refactor_test

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/refactor"
)

func TestBuildMultiBufferExcerpts_ClusteringDistance(t *testing.T) {
	files := map[string]string{
		"calc.go": `package calc

func Add(a, b int) int {
	return a + b
}
func Sub(a, b int) int {
	return a - b
}

func Mul(a, b int) int {
	return a * b
}
`,
	}

	// Line 3 and Line 6 are separated by 3 lines (difference 3) -> clustered together
	locs := []refactor.MatchLocation{
		{FilePath: "calc.go", Line: 3},
		{FilePath: "calc.go", Line: 6},
	}

	excerpts := refactor.BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 1 {
		t.Fatalf("Expected 1 merged excerpt, got %d", len(excerpts))
	}
	if excerpts[0].StartLine != 3 || excerpts[0].EndLine != 6 {
		t.Errorf("Bounds mismatch: got [%d, %d]; want [3, 6]", excerpts[0].StartLine, excerpts[0].EndLine)
	}

	// Line 3 and Line 10 are separated by 7 lines -> separate clusters
	locsSeparated := []refactor.MatchLocation{
		{FilePath: "calc.go", Line: 3},
		{FilePath: "calc.go", Line: 10},
	}
	excerptsSeparated := refactor.BuildMultiBufferExcerpts(files, locsSeparated, 0)
	if len(excerptsSeparated) != 2 {
		t.Fatalf("Expected 2 separate excerpts, got %d", len(excerptsSeparated))
	}
}

func TestBuildMultiBufferExcerpts_ContextClamping(t *testing.T) {
	files := map[string]string{
		"short.go": "line 1\nline 2\nline 3",
	}

	locs := []refactor.MatchLocation{
		{FilePath: "short.go", Line: 1},
	}
	// Requesting 5 context lines on a 3-line file
	excerpts := refactor.BuildMultiBufferExcerpts(files, locs, 5)
	if len(excerpts) != 1 {
		t.Fatalf("Expected 1 excerpt, got %d", len(excerpts))
	}
	if excerpts[0].StartLine != 1 || excerpts[0].EndLine != 3 {
		t.Errorf("Clamping failed: got [%d, %d]; want [1, 3]", excerpts[0].StartLine, excerpts[0].EndLine)
	}
}

func TestApplyMultiBufferEdits_BottomUpPreservation(t *testing.T) {
	files := map[string]string{
		"server.go": `package main

func HandleAlpha() {
	println("alpha")
}

func HandleBeta() {
	println("beta")
}
`,
	}

	locs := []refactor.MatchLocation{
		{FilePath: "server.go", Line: 3},
		{FilePath: "server.go", Line: 7},
	}

	excerpts := refactor.BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 2 {
		t.Fatalf("Expected 2 excerpts, got %d", len(excerpts))
	}

	// Modify both: one expands, one shrinks
	excerpts[0].Lines = "func HandleAlphaRenamed() {\n\tprintln(\"alpha 1\")\n\tprintln(\"alpha 2\")\n}"
	excerpts[1].Lines = "func HandleBetaRenamed() {}"

	updated, undo, err := refactor.ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("ApplyMultiBufferEdits failed: %v", err)
	}

	content := updated["server.go"]
	if !strings.Contains(content, "HandleAlphaRenamed") || !strings.Contains(content, "HandleBetaRenamed") {
		t.Fatalf("Updated content corrupted: %s", content)
	}

	// Verify 1-step undo
	reverted, _, err := refactor.ApplyMultiBufferEdits(updated, undo)
	if err != nil {
		t.Fatalf("Undo failed: %v", err)
	}
	if !strings.Contains(reverted["server.go"], "HandleAlpha()") || !strings.Contains(reverted["server.go"], "HandleBeta()") {
		t.Errorf("Reverted content does not match original: %s", reverted["server.go"])
	}
}

func TestApplyGoMultiBufferEdits_DiskAtomicBatchSave(t *testing.T) {
	tmpDir := t.TempDir()
	fileA := filepath.Join(tmpDir, "a.go")
	fileB := filepath.Join(tmpDir, "b.go")

	_ = os.WriteFile(fileA, []byte("package main\n\nvar ConfigA = 1\n"), 0o644)
	_ = os.WriteFile(fileB, []byte("package main\n\nvar ConfigB = 2\n"), 0o644)

	res, err := refactor.BuildGoMultiBuffer("Config", tmpDir, []string{fileA, fileB})
	if err != nil {
		t.Fatalf("BuildGoMultiBuffer failed: %v", err)
	}
	if len(res.Files) != 2 {
		t.Fatalf("Expected 2 files in multi-buffer, got %d", len(res.Files))
	}

	var edits []refactor.MultiBufferFileEdit
	for _, f := range res.Files {
		var chunkEdits []refactor.MultiBufferEdit
		for _, c := range f.Chunks {
			newLines := strings.ReplaceAll(c.Lines, "Config", "Settings")
			chunkEdits = append(chunkEdits, refactor.MultiBufferEdit{
				FilePath:     c.FilePath,
				StartLine:    c.StartLine,
				EndLine:      c.EndLine,
				NewLines:     newLines,
				OriginalHash: c.OriginalHash,
			})
		}
		edits = append(edits, refactor.MultiBufferFileEdit{
			FilePath:       f.FilePath,
			OriginalSHA256: f.OriginalSHA256,
			Edits:          chunkEdits,
		})
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
	if err != nil || !applyRes.Success {
		t.Fatalf("ApplyGoMultiBufferEdits failed: %v (err: %s)", err, applyRes.ErrorMessage)
	}

	dataA, _ := os.ReadFile(fileA)
	dataB, _ := os.ReadFile(fileB)
	if !strings.Contains(string(dataA), "SettingsA") || !strings.Contains(string(dataB), "SettingsB") {
		t.Errorf("Files on disk do not contain expected replacements: A=%s, B=%s", string(dataA), string(dataB))
	}

	// Verify undo across disk files
	undoRes, err := refactor.ApplyGoMultiBufferEdits(applyRes.UndoSnapshot)
	if err != nil || !undoRes.Success {
		t.Fatalf("Undo on disk failed: %v", err)
	}
	restoredA, _ := os.ReadFile(fileA)
	if !strings.Contains(string(restoredA), "ConfigA") {
		t.Errorf("File A not restored after undo: %s", string(restoredA))
	}
}

func TestApplyGoMultiBufferEdits_ExternalModificationCollision(t *testing.T) {
	tmpDir := t.TempDir()
	file := filepath.Join(tmpDir, "concurrent.go")
	_ = os.WriteFile(file, []byte("package main\n\nvar Target = 100\n"), 0o644)

	res, err := refactor.BuildGoMultiBuffer("Target", tmpDir, []string{file})
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}

	// Simulate concurrent external modification to the file before user saves
	_ = os.WriteFile(file, []byte("package main\n\nvar Target = 999 // mutated externally\n"), 0o644)

	edits := []refactor.MultiBufferFileEdit{
		{
			FilePath:       file,
			OriginalSHA256: res.Files[0].OriginalSHA256, // Stale hash
			Edits: []refactor.MultiBufferEdit{
				{
					FilePath:     file,
					StartLine:    3,
					EndLine:      3,
					NewLines:     "var Target = 200",
					OriginalHash: res.Files[0].Chunks[0].OriginalHash,
				},
			},
		},
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
	if err == nil || applyRes.Success {
		t.Fatalf("Expected ApplyGoMultiBufferEdits to fail with external modification collision")
	}
	if !errors.Is(err, refactor.ErrFileModifiedExternally) {
		t.Errorf("Expected ErrFileModifiedExternally, got %v", err)
	}

	// Ensure disk content was NOT touched
	curr, _ := os.ReadFile(file)
	if !strings.Contains(string(curr), "999") {
		t.Errorf("Stale write corrupted concurrent change: %s", string(curr))
	}
}

func TestApplyGoMultiBufferEdits_OverlappingEditsRejection(t *testing.T) {
	tmpDir := t.TempDir()
	file := filepath.Join(tmpDir, "overlap.go")
	_ = os.WriteFile(file, []byte("line 1\nline 2\nline 3\nline 4\nline 5\n"), 0o644)

	edits := []refactor.MultiBufferFileEdit{
		{
			FilePath: file,
			Edits: []refactor.MultiBufferEdit{
				{FilePath: file, StartLine: 2, EndLine: 4, NewLines: "replacement A"},
				{FilePath: file, StartLine: 3, EndLine: 5, NewLines: "replacement B"},
			},
		},
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
	if err == nil || applyRes.Success {
		t.Fatalf("Expected overlapping edits to be rejected")
	}
	if !errors.Is(err, refactor.ErrOverlappingEdits) {
		t.Errorf("Expected ErrOverlappingEdits, got: %v", err)
	}
}

func TestApplyGoMultiBufferEdits_AtomicRollbackOnPartialFailure(t *testing.T) {
	tmpDir := t.TempDir()
	file1 := filepath.Join(tmpDir, "good.go")
	file2 := filepath.Join(tmpDir, "bad.go")

	_ = os.WriteFile(file1, []byte("package main\n\nvar X = 1\n"), 0o644)
	_ = os.WriteFile(file2, []byte("package main\n\nvar Y = 2\n"), 0o644)

	edits := []refactor.MultiBufferFileEdit{
		{
			FilePath: file1,
			Edits: []refactor.MultiBufferEdit{
				{FilePath: file1, StartLine: 3, EndLine: 3, NewLines: "var X = 10"},
			},
		},
		{
			FilePath: file2,
			Edits: []refactor.MultiBufferEdit{
				// Out of bounds start line will cause batch failure
				{FilePath: file2, StartLine: 99, EndLine: 100, NewLines: "var Y = 20"},
			},
		},
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
	if err == nil || applyRes.Success {
		t.Fatalf("Expected batch failure due to out of bounds line")
	}

	// Verify file1 was completely untouched due to atomic rollback
	data1, _ := os.ReadFile(file1)
	if !strings.Contains(string(data1), "var X = 1\n") {
		t.Errorf("File 1 was modified despite batch failure! Content: %s", string(data1))
	}

	// Verify no temporary .golens_tmp_ files remain in directory
	entries, _ := os.ReadDir(tmpDir)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".golens_tmp_") || strings.HasPrefix(entry.Name(), ".golens_bak_") {
			t.Errorf("Found leaked temporary file: %s", entry.Name())
		}
	}
}
