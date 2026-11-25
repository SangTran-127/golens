package refactor_test

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/refactor"
)

func sha256String(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// TestAdversarial_MultiBuffer_ClusteringDistance tests clustering matches at
// line distance = 1, 2, 3 (clustered into 1 excerpt) vs 4, 5 (separated into 2 excerpts),
// and verifies context padding is clamped to [1, totalLines].
func TestAdversarial_MultiBuffer_ClusteringDistance(t *testing.T) {
	// Construct a 50-line file
	var lines []string
	for i := 1; i <= 50; i++ {
		lines = append(lines, fmt.Sprintf("// line %d: code statement here", i))
	}
	content := strings.Join(lines, "\n")
	fileMap := map[string]string{
		"service.go": content,
	}

	testCases := []struct {
		name             string
		lineA            int
		lineB            int
		expectedClusters int
		expectedStart    int
		expectedEnd      int
	}{
		{"Distance_1_Merged", 20, 21, 1, 20, 21},
		{"Distance_2_Merged", 20, 22, 1, 20, 22},
		{"Distance_3_Merged", 20, 23, 1, 20, 23},
		{"Distance_4_Separated", 20, 24, 2, 0, 0},
		{"Distance_5_Separated", 20, 25, 2, 0, 0},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			locs := []refactor.MatchLocation{
				{FilePath: "service.go", Line: tc.lineA},
				{FilePath: "service.go", Line: tc.lineB},
			}

			excerpts := refactor.BuildMultiBufferExcerpts(fileMap, locs, 0)
			if len(excerpts) != tc.expectedClusters {
				t.Fatalf("Expected %d clusters for distance %d (lines %d, %d), got %d",
					tc.expectedClusters, tc.lineB-tc.lineA, tc.lineA, tc.lineB, len(excerpts))
			}

			if tc.expectedClusters == 1 {
				if excerpts[0].StartLine != tc.expectedStart || excerpts[0].EndLine != tc.expectedEnd {
					t.Errorf("Cluster bounds mismatch: got [%d, %d]; want [%d, %d]",
						excerpts[0].StartLine, excerpts[0].EndLine, tc.expectedStart, tc.expectedEnd)
				}
				if len(excerpts[0].MatchLines) != 2 {
					t.Errorf("Expected 2 match lines in merged cluster, got %d", len(excerpts[0].MatchLines))
				}
			} else {
				if excerpts[0].StartLine != tc.lineA || excerpts[0].EndLine != tc.lineA {
					t.Errorf("First cluster mismatch: got [%d, %d]; want [%d, %d]",
						excerpts[0].StartLine, excerpts[0].EndLine, tc.lineA, tc.lineA)
				}
				if excerpts[1].StartLine != tc.lineB || excerpts[1].EndLine != tc.lineB {
					t.Errorf("Second cluster mismatch: got [%d, %d]; want [%d, %d]",
						excerpts[1].StartLine, excerpts[1].EndLine, tc.lineB, tc.lineB)
				}
			}
		})
	}

	// Context padding clamping tests
	t.Run("ContextPaddingClampedToTop", func(t *testing.T) {
		locs := []refactor.MatchLocation{{FilePath: "service.go", Line: 2}}
		excerpts := refactor.BuildMultiBufferExcerpts(fileMap, locs, 10)
		if len(excerpts) != 1 {
			t.Fatalf("Expected 1 excerpt, got %d", len(excerpts))
		}
		if excerpts[0].StartLine != 1 {
			t.Errorf("StartLine should clamp to 1, got %d", excerpts[0].StartLine)
		}
		if excerpts[0].EndLine != 12 {
			t.Errorf("EndLine should be 2+10=12, got %d", excerpts[0].EndLine)
		}
	})

	t.Run("ContextPaddingClampedToBottom", func(t *testing.T) {
		locs := []refactor.MatchLocation{{FilePath: "service.go", Line: 48}}
		excerpts := refactor.BuildMultiBufferExcerpts(fileMap, locs, 10)
		if len(excerpts) != 1 {
			t.Fatalf("Expected 1 excerpt, got %d", len(excerpts))
		}
		if excerpts[0].StartLine != 38 {
			t.Errorf("StartLine should be 48-10=38, got %d", excerpts[0].StartLine)
		}
		if excerpts[0].EndLine != 50 {
			t.Errorf("EndLine should clamp to 50, got %d", excerpts[0].EndLine)
		}
	})

	t.Run("ContextPaddingClampedBothEndsOnSmallFile", func(t *testing.T) {
		smallFile := map[string]string{
			"tiny.go": "line 1\nline 2\nline 3\nline 4",
		}
		locs := []refactor.MatchLocation{{FilePath: "tiny.go", Line: 2}}
		excerpts := refactor.BuildMultiBufferExcerpts(smallFile, locs, 50)
		if len(excerpts) != 1 {
			t.Fatalf("Expected 1 excerpt, got %d", len(excerpts))
		}
		if excerpts[0].StartLine != 1 || excerpts[0].EndLine != 4 {
			t.Errorf("Expected clamped bounds [1, 4], got [%d, %d]",
				excerpts[0].StartLine, excerpts[0].EndLine)
		}
	})
}

// TestAdversarial_MultiBuffer_TwoLevelSHA256Safety tests that external file modification
// on disk before ApplyMultiBufferEdits returns ErrFileModifiedExternally and aborts
// writes without modifying any file.
func TestAdversarial_MultiBuffer_TwoLevelSHA256Safety(t *testing.T) {
	tmpDir := t.TempDir()

	file1 := filepath.Join(tmpDir, "file1.go")
	file2 := filepath.Join(tmpDir, "file2.go")

	content1 := "package main\n\nvar ValueOne = 100\n"
	content2 := "package main\n\nvar ValueTwo = 200\n"

	if err := os.WriteFile(file1, []byte(content1), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	if err := os.WriteFile(file2, []byte(content2), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	res, err := refactor.BuildGoMultiBuffer("Value", tmpDir, []string{file1, file2})
	if err != nil {
		t.Fatalf("BuildGoMultiBuffer failed: %v", err)
	}

	// External modification: Alter file1 on disk BEFORE applying edits
	mutatedContent1 := "package main\n\nvar ValueOne = 99999 // mutated externally\n"
	if err := os.WriteFile(file1, []byte(mutatedContent1), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	// Prepare multi-buffer edits based on the original query
	var fileEdits []refactor.MultiBufferFileEdit
	for _, f := range res.Files {
		var chunkEdits []refactor.MultiBufferEdit
		for _, c := range f.Chunks {
			chunkEdits = append(chunkEdits, refactor.MultiBufferEdit{
				FilePath:     c.FilePath,
				StartLine:    c.StartLine,
				EndLine:      c.EndLine,
				NewLines:     strings.ReplaceAll(c.Lines, "Value", "RenamedValue"),
				OriginalHash: c.OriginalHash,
			})
		}
		fileEdits = append(fileEdits, refactor.MultiBufferFileEdit{
			FilePath:       f.FilePath,
			OriginalSHA256: f.OriginalSHA256, // Stale SHA256 for file1
			Edits:          chunkEdits,
		})
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(fileEdits)
	if err == nil {
		t.Fatalf("Expected ApplyGoMultiBufferEdits to fail with external modification collision")
	}
	if !errors.Is(err, refactor.ErrFileModifiedExternally) {
		t.Errorf("Expected ErrFileModifiedExternally, got %v", err)
	}
	if applyRes.Success {
		t.Errorf("Expected applyRes.Success == false")
	}
	if applyRes.ConflictFile != file1 {
		t.Errorf("Expected ConflictFile to be %s, got %s", file1, applyRes.ConflictFile)
	}

	// Integrity verification: Ensure disk content was NOT overwritten or corrupted
	disk1, _ := os.ReadFile(file1)
	if string(disk1) != mutatedContent1 {
		t.Fatalf("File1 was overwritten! Got: %s, want: %s", string(disk1), mutatedContent1)
	}
	disk2, _ := os.ReadFile(file2)
	if string(disk2) != content2 {
		t.Fatalf("File2 was modified during aborted batch save! Got: %s, want: %s", string(disk2), content2)
	}

	// Level 2 Check: Excerpt SHA256 mismatch when whole-file SHA is empty
	t.Run("ExcerptLevelHashMismatch", func(t *testing.T) {
		editsWithStaleExcerpt := []refactor.MultiBufferFileEdit{
			{
				FilePath: file2,
				// OriginalSHA256 intentionally omitted to test Level 2 excerpt hash
				Edits: []refactor.MultiBufferEdit{
					{
						FilePath:     file2,
						StartLine:    3,
						EndLine:      3,
						NewLines:     "var ValueTwo = 500",
						OriginalHash: "deadbeef00000000000000000000000000000000000000000000000000000000",
					},
				},
			},
		}

		res2, err2 := refactor.ApplyGoMultiBufferEdits(editsWithStaleExcerpt)
		if err2 == nil || res2.Success {
			t.Fatalf("Expected excerpt hash mismatch failure")
		}
		if !strings.Contains(err2.Error(), "hash mismatch") {
			t.Errorf("Expected hash mismatch error, got: %v", err2)
		}

		disk2After, _ := os.ReadFile(file2)
		if string(disk2After) != content2 {
			t.Errorf("File2 was modified despite excerpt hash mismatch! Got: %s", string(disk2After))
		}
	})
}

// TestAdversarial_MultiBuffer_BottomUpFiveNonContiguousEdits tests 5 non-contiguous edits
// in a single file with varying line expansion and reduction, verifying all line offsets
// remain completely stable and unaffected by other edits.
func TestAdversarial_MultiBuffer_BottomUpFiveNonContiguousEdits(t *testing.T) {
	// Create a structured Go source file with multi-line functions separated by blank lines
	var originalLines []string
	originalLines = append(originalLines, "package main", "", "import \"fmt\"", "")
	for i := 5; i <= 25; i++ {
		originalLines = append(originalLines,
			fmt.Sprintf("func Function%02d() {", i),
			fmt.Sprintf("\tfmt.Println(%d)", i),
			"}",
			"",
		)
	}
	originalContent := strings.Join(originalLines, "\n")

	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "server.go")
	if err := os.WriteFile(filePath, []byte(originalContent), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	srcLines := strings.Split(originalContent, "\n")

	// 5 Non-contiguous edits:
	// Edit 1: Function 6 (lines 9-11, 3 lines) -> expand to 6 lines (+3 lines)
	// Edit 2: Function 9 (lines 21-23, 3 lines) -> shrink to 1 line (-2 lines)
	// Edit 3: Function 13 (lines 37-39, 3 lines) -> replace with 3 lines (0 delta)
	// Edit 4: Function 17 (lines 53-55, 3 lines) -> expand to 7 lines (+4 lines)
	// Edit 5: Function 22 (lines 73-75, 3 lines) -> shrink to 1 line (-2 lines)

	edit1Replacement := strings.Join([]string{
		"func Function06Expanded() {",
		"\tfmt.Println(601)",
		"\tfmt.Println(602)",
		"\tfmt.Println(603)",
		"\tfmt.Println(604)",
		"}",
	}, "\n")

	edit2Replacement := "func Function09Collapsed() {}"

	edit3Replacement := strings.Join([]string{
		"func Function13Swapped() {",
		"\tfmt.Println(1300)",
		"}",
	}, "\n")

	edit4Replacement := strings.Join([]string{
		"func Function17Expanded() {",
		"\tfmt.Println(1701)",
		"\tfmt.Println(1702)",
		"\tfmt.Println(1703)",
		"\tfmt.Println(1704)",
		"\tfmt.Println(1705)",
		"}",
	}, "\n")

	edit5Replacement := "func Function22Collapsed() {}"

	edits := []refactor.MultiBufferEdit{
		{
			FilePath:     filePath,
			StartLine:    9,
			EndLine:      11,
			NewLines:     edit1Replacement,
			OriginalHash: sha256String([]byte(strings.Join(srcLines[8:11], "\n"))),
		},
		{
			FilePath:     filePath,
			StartLine:    21,
			EndLine:      23,
			NewLines:     edit2Replacement,
			OriginalHash: sha256String([]byte(strings.Join(srcLines[20:23], "\n"))),
		},
		{
			FilePath:     filePath,
			StartLine:    37,
			EndLine:      39,
			NewLines:     edit3Replacement,
			OriginalHash: sha256String([]byte(strings.Join(srcLines[36:39], "\n"))),
		},
		{
			FilePath:     filePath,
			StartLine:    53,
			EndLine:      55,
			NewLines:     edit4Replacement,
			OriginalHash: sha256String([]byte(strings.Join(srcLines[52:55], "\n"))),
		},
		{
			FilePath:     filePath,
			StartLine:    73,
			EndLine:      75,
			NewLines:     edit5Replacement,
			OriginalHash: sha256String([]byte(strings.Join(srcLines[72:75], "\n"))),
		},
	}

	fileEdits := []refactor.MultiBufferFileEdit{
		{
			FilePath:       filePath,
			OriginalSHA256: sha256String([]byte(originalContent)),
			Edits:          edits,
		},
	}

	applyRes, err := refactor.ApplyGoMultiBufferEdits(fileEdits)
	if err != nil || !applyRes.Success {
		t.Fatalf("ApplyGoMultiBufferEdits failed: %v (%s)", err, applyRes.ErrorMessage)
	}

	modifiedBytes, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	modifiedContent := string(modifiedBytes)

	// Verify all 5 edits were applied accurately without interference
	if !strings.Contains(modifiedContent, "Function06Expanded") {
		t.Errorf("Edit 1 (expansion) missing in modified content")
	}
	if !strings.Contains(modifiedContent, "Function09Collapsed") {
		t.Errorf("Edit 2 (reduction) missing in modified content")
	}
	if !strings.Contains(modifiedContent, "Function13Swapped") {
		t.Errorf("Edit 3 (neutral delta) missing in modified content")
	}
	if !strings.Contains(modifiedContent, "Function17Expanded") {
		t.Errorf("Edit 4 (expansion) missing in modified content")
	}
	if !strings.Contains(modifiedContent, "Function22Collapsed") {
		t.Errorf("Edit 5 (reduction) missing in modified content")
	}

	// Verify unedited regions remain intact
	if !strings.Contains(modifiedContent, "func Function05() {") {
		t.Errorf("Pre-edit boundary corrupted (Function05)")
	}
	if !strings.Contains(modifiedContent, "func Function08() {") {
		t.Errorf("Inter-edit boundary corrupted (Function08)")
	}
	if !strings.Contains(modifiedContent, "func Function12() {") {
		t.Errorf("Inter-edit boundary corrupted (Function12)")
	}
	if !strings.Contains(modifiedContent, "func Function16() {") {
		t.Errorf("Inter-edit boundary corrupted (Function16)")
	}
	if !strings.Contains(modifiedContent, "func Function21() {") {
		t.Errorf("Inter-edit boundary corrupted (Function21)")
	}
	if !strings.Contains(modifiedContent, "func Function25() {") {
		t.Errorf("Post-edit boundary corrupted (Function25)")
	}

	// Verify 1-step undo from the snapshot restores byte-for-byte
	undoRes, err := refactor.ApplyGoMultiBufferEdits(applyRes.UndoSnapshot)
	if err != nil || !undoRes.Success {
		t.Fatalf("Undo failed: %v (%s)", err, undoRes.ErrorMessage)
	}

	restoredBytes, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatalf("ReadFile after undo failed: %v", err)
	}

	if sha256String(restoredBytes) != sha256String([]byte(originalContent)) {
		t.Errorf("Restored file hash mismatch after undo!\nOriginal SHA: %s\nRestored SHA: %s",
			sha256String([]byte(originalContent)), sha256String(restoredBytes))
	}
}

// TestAdversarial_MultiBuffer_AtomicRollbackFiveFiles tests saving edits across 5 files
// where file 4 fails validation or disk write; verifies zero files remain modified.
func TestAdversarial_MultiBuffer_AtomicRollbackFiveFiles(t *testing.T) {
	tmpDir := t.TempDir()

	files := make([]string, 5)
	origContents := make([]string, 5)
	origHashes := make([]string, 5)

	for i := 0; i < 5; i++ {
		files[i] = filepath.Join(tmpDir, fmt.Sprintf("file_%d.go", i+1))
		origContents[i] = fmt.Sprintf("package main\n\nvar TargetVar%d = %d\n", i+1, (i+1)*10)
		if err := os.WriteFile(files[i], []byte(origContents[i]), 0644); err != nil {
			t.Fatalf("WriteFile failed: %v", err)
		}
		origHashes[i] = sha256String([]byte(origContents[i]))
	}

	// Sub-case 1: File 4 fails validation (out of bounds line)
	t.Run("ValidationFailureOnFourthFile", func(t *testing.T) {
		var edits []refactor.MultiBufferFileEdit
		for i := 0; i < 5; i++ {
			startLine := 3
			endLine := 3
			if i == 3 { // File 4
				startLine = 999 // Out of bounds
				endLine = 1000
			}
			edits = append(edits, refactor.MultiBufferFileEdit{
				FilePath:       files[i],
				OriginalSHA256: origHashes[i],
				Edits: []refactor.MultiBufferEdit{
					{
						FilePath:  files[i],
						StartLine: startLine,
						EndLine:   endLine,
						NewLines:  fmt.Sprintf("var TargetVar%d = %d", i+1, (i+1)*999),
					},
				},
			})
		}

		applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
		if err == nil || applyRes.Success {
			t.Fatalf("Expected batch failure due to out of bounds line on file 4")
		}

		// Verify zero files remain modified
		for i := 0; i < 5; i++ {
			data, err := os.ReadFile(files[i])
			if err != nil {
				t.Fatalf("Failed to read file %d: %v", i+1, err)
			}
			if sha256String(data) != origHashes[i] {
				t.Errorf("File %d was modified despite batch failure! Got: %s", i+1, string(data))
			}
		}

		// Verify no leaked temporary or backup files
		entries, _ := os.ReadDir(tmpDir)
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), ".golens_tmp_") || strings.HasPrefix(e.Name(), ".golens_bak_") {
				t.Errorf("Found leaked temp file: %s", e.Name())
			}
		}
	})

	// Sub-case 2: File 4 disk write failure (permission denied on directory)
	t.Run("DiskWriteFailureOnFourthFile", func(t *testing.T) {
		roDir := filepath.Join(tmpDir, "readonly_sub")
		if err := os.Mkdir(roDir, 0755); err != nil {
			t.Fatalf("Mkdir failed: %v", err)
		}
		roFile := filepath.Join(roDir, "file_4_ro.go")
		roContent := "package main\n\nvar TargetVar4 = 40\n"
		if err := os.WriteFile(roFile, []byte(roContent), 0644); err != nil {
			t.Fatalf("WriteFile failed: %v", err)
		}
		roHash := sha256String([]byte(roContent))

		// Substitute file 4 with the file inside the read-only directory
		targetFiles := []string{files[0], files[1], files[2], roFile, files[4]}
		targetHashes := []string{origHashes[0], origHashes[1], origHashes[2], roHash, origHashes[4]}

		// Make directory read-only so creating .golens_tmp_ fails
		if err := os.Chmod(roDir, 0555); err != nil {
			t.Fatalf("Chmod failed: %v", err)
		}
		defer func() {
			_ = os.Chmod(roDir, 0755) // Clean up permission for temp dir removal
		}()

		var edits []refactor.MultiBufferFileEdit
		for i := 0; i < 5; i++ {
			edits = append(edits, refactor.MultiBufferFileEdit{
				FilePath:       targetFiles[i],
				OriginalSHA256: targetHashes[i],
				Edits: []refactor.MultiBufferEdit{
					{
						FilePath:  targetFiles[i],
						StartLine: 3,
						EndLine:   3,
						NewLines:  fmt.Sprintf("var TargetVar%d = %d", i+1, (i+1)*999),
					},
				},
			})
		}

		applyRes, err := refactor.ApplyGoMultiBufferEdits(edits)
		if err == nil || applyRes.Success {
			t.Fatalf("Expected ApplyGoMultiBufferEdits to fail due to disk permission error on file 4")
		}

		// Verify zero files remain modified
		for i := 0; i < 5; i++ {
			data, err := os.ReadFile(targetFiles[i])
			if err != nil {
				t.Fatalf("Failed to read file %d: %v", i+1, err)
			}
			if sha256String(data) != targetHashes[i] {
				t.Errorf("Atomic rollback failed! File %d was modified on disk: %s", i+1, string(data))
			}
		}

		// Verify no leaked temporary or backup files in root tmpDir or roDir
		entries, _ := os.ReadDir(tmpDir)
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), ".golens_tmp_") || strings.HasPrefix(e.Name(), ".golens_bak_") {
				t.Errorf("Found leaked temp file in tmpDir: %s", e.Name())
			}
		}
	})
}

// TestAdversarial_MultiBuffer_OneStepUndoByteForByteFidelity tests applying edits,
// taking undo snapshot, applying undo snapshot, and verifying
// sha256(restoredFile) == sha256(originalFile) across multi-file refactorings.
func TestAdversarial_MultiBuffer_OneStepUndoByteForByteFidelity(t *testing.T) {
	tmpDir := t.TempDir()

	fileA := filepath.Join(tmpDir, "models.go")
	fileB := filepath.Join(tmpDir, "router.go")
	fileC := filepath.Join(tmpDir, "helpers.txt") // Non-Go file to test raw byte fidelity

	contentA := `package main

type UserModel struct {
	ID        int64
	Username  string
	Email     string
	IsActive  bool
	CreatedAt int64
}

func (u *UserModel) GetID() int64 {
	return u.ID
}
`
	contentB := `package main

import "fmt"

func RouteUser(u *UserModel) {
	fmt.Printf("User: %s\n", u.Username)
	fmt.Printf("Email: %s\n", u.Email)
}
`
	contentC := `# Helper Configuration File
host=localhost
port=8080
debug=true
max_connections=100
timeout=30s
`

	_ = os.WriteFile(fileA, []byte(contentA), 0644)
	_ = os.WriteFile(fileB, []byte(contentB), 0644)
	_ = os.WriteFile(fileC, []byte(contentC), 0644)

	hashA := sha256String([]byte(contentA))
	hashB := sha256String([]byte(contentB))
	hashC := sha256String([]byte(contentC))

	fileEdits := []refactor.MultiBufferFileEdit{
		{
			FilePath:       fileA,
			OriginalSHA256: hashA,
			Edits: []refactor.MultiBufferEdit{
				{
					FilePath:  fileA,
					StartLine: 4,
					EndLine:   7,
					NewLines: strings.Join([]string{
						"\tID           int64",
						"\tDisplayName  string",
						"\tPrimaryEmail string",
						"\tStatus       string",
						"\tUpdatedAt    int64",
						"\tIsVerified   bool",
					}, "\n"),
				},
				{
					FilePath:  fileA,
					StartLine: 11,
					EndLine:   13,
					NewLines: strings.Join([]string{
						"func (u *UserModel) Identifier() int64 {",
						"\treturn u.ID",
						"}",
					}, "\n"),
				},
			},
		},
		{
			FilePath:       fileB,
			OriginalSHA256: hashB,
			Edits: []refactor.MultiBufferEdit{
				{
					FilePath:  fileB,
					StartLine: 6,
					EndLine:   7,
					NewLines: strings.Join([]string{
						"\tfmt.Printf(\"User: %s\\n\", u.DisplayName)",
						"\tfmt.Printf(\"Email: %s\\n\", u.PrimaryEmail)",
					}, "\n"),
				},
			},
		},
		{
			FilePath:       fileC,
			OriginalSHA256: hashC,
			Edits: []refactor.MultiBufferEdit{
				{
					FilePath:  fileC,
					StartLine: 2,
					EndLine:   4,
					NewLines:  "host=127.0.0.1\nport=9090\ndebug=false\nenvironment=production",
				},
			},
		},
	}

	// 1. Apply edits to disk
	applyRes, err := refactor.ApplyGoMultiBufferEdits(fileEdits)
	if err != nil || !applyRes.Success {
		t.Fatalf("ApplyGoMultiBufferEdits failed: %v (%s)", err, applyRes.ErrorMessage)
	}

	if len(applyRes.FilesModified) != 3 {
		t.Errorf("Expected 3 files modified, got %d", len(applyRes.FilesModified))
	}
	if len(applyRes.UndoSnapshot) != 3 {
		t.Errorf("Expected 3 undo file snapshots, got %d", len(applyRes.UndoSnapshot))
	}

	// Verify files actually changed on disk
	afterA, _ := os.ReadFile(fileA)
	if sha256String(afterA) == hashA {
		t.Errorf("File A was not modified")
	}
	afterB, _ := os.ReadFile(fileB)
	if sha256String(afterB) == hashB {
		t.Errorf("File B was not modified")
	}
	afterC, _ := os.ReadFile(fileC)
	if sha256String(afterC) == hashC {
		t.Errorf("File C was not modified")
	}

	// 2. Apply 1-step undo snapshot to disk
	undoRes, err := refactor.ApplyGoMultiBufferEdits(applyRes.UndoSnapshot)
	if err != nil || !undoRes.Success {
		t.Fatalf("Applying undo snapshot failed: %v (%s)", err, undoRes.ErrorMessage)
	}

	// 3. Verify byte-for-byte SHA256 fidelity against original content
	restoredA, _ := os.ReadFile(fileA)
	restoredB, _ := os.ReadFile(fileB)
	restoredC, _ := os.ReadFile(fileC)

	if sha256String(restoredA) != hashA {
		t.Errorf("File A byte-for-byte fidelity failure after undo!\nWant SHA: %s\nGot SHA:  %s\nContent:\n%s",
			hashA, sha256String(restoredA), string(restoredA))
	}
	if sha256String(restoredB) != hashB {
		t.Errorf("File B byte-for-byte fidelity failure after undo!\nWant SHA: %s\nGot SHA:  %s\nContent:\n%s",
			hashB, sha256String(restoredB), string(restoredB))
	}
	if sha256String(restoredC) != hashC {
		t.Errorf("File C byte-for-byte fidelity failure after undo!\nWant SHA: %s\nGot SHA:  %s\nContent:\n%s",
			hashC, sha256String(restoredC), string(restoredC))
	}
}
