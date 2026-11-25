package refactor

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"go/format"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var (
	ErrFileModifiedExternally = errors.New("file modified externally (SHA256 mismatch)")
	ErrEditOutOfBounds        = errors.New("edit out of bounds")
	ErrOverlappingEdits       = errors.New("overlapping edits within file")
	ErrEmptyEdits             = errors.New("no edits provided")
	ErrFileNotFound           = errors.New("file not found in workspace")
)

type MatchLocation struct {
	FilePath string `json:"filePath"`
	Line     int    `json:"line"`
	Column   int    `json:"column,omitempty"`
}

type MultiBufferChunk struct {
	ID           string `json:"id"`
	FilePath     string `json:"filePath"`
	StartLine    int    `json:"startLine"`
	EndLine      int    `json:"endLine"`
	Lines        string `json:"lines"`
	OriginalHash string `json:"originalHash"`
	MatchLines   []int  `json:"matchLines,omitempty"`
}

type MultiBufferExcerpt = MultiBufferChunk

type MultiBufferFile struct {
	FilePath       string             `json:"filePath"`
	RelativePath   string             `json:"relativePath"`
	OriginalSHA256 string             `json:"originalSHA256"`
	Chunks         []MultiBufferChunk `json:"chunks"`
}

type MultiBufferResult struct {
	Query      string            `json:"query,omitempty"`
	Files      []MultiBufferFile `json:"files"`
	TotalHits  int               `json:"totalHits"`
	TotalFiles int               `json:"totalFiles"`
	Error      string            `json:"error,omitempty"`
}

type MultiBufferEdit struct {
	FilePath     string `json:"filePath"`
	StartLine    int    `json:"startLine"`
	EndLine      int    `json:"endLine"`
	NewLines     string `json:"newLines"`
	OriginalHash string `json:"originalHash,omitempty"`
}

type MultiBufferFileEdit struct {
	FilePath       string            `json:"filePath"`
	OriginalSHA256 string            `json:"originalSHA256,omitempty"`
	Edits          []MultiBufferEdit `json:"edits"`
}

type ApplyResult struct {
	Success       bool                  `json:"success"`
	FilesModified []string              `json:"filesModified"`
	UndoSnapshot  []MultiBufferFileEdit `json:"undoSnapshot,omitempty"`
	ErrorMessage  string                `json:"errorMessage,omitempty"`
	ConflictFile  string                `json:"conflictFile,omitempty"`
}

func CalculateSHA256(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func BuildMultiBufferExcerpts(fileContents map[string]string, locations []MatchLocation, contextLines int) []MultiBufferExcerpt {
	if contextLines < 0 {
		contextLines = 0
	}

	fileLocs := make(map[string][]int)
	for _, loc := range locations {
		fileLocs[loc.FilePath] = append(fileLocs[loc.FilePath], loc.Line)
	}

	var filePaths []string
	for fp := range fileLocs {
		filePaths = append(filePaths, fp)
	}
	sort.Strings(filePaths)

	var excerpts []MultiBufferExcerpt

	for _, filePath := range filePaths {
		linesList := fileLocs[filePath]
		content, ok := fileContents[filePath]
		if !ok {
			continue
		}
		srcLines := strings.Split(content, "\n")
		totalLines := len(srcLines)

		sort.Ints(linesList)

		type cluster struct {
			start      int
			end        int
			matchLines []int
		}
		var clusters []cluster
		for _, line := range linesList {
			start := line - contextLines
			if start < 1 {
				start = 1
			}
			end := line + contextLines
			if end > totalLines {
				end = totalLines
			}

			if len(clusters) > 0 && start <= clusters[len(clusters)-1].end+3 {
				if end > clusters[len(clusters)-1].end {
					clusters[len(clusters)-1].end = end
				}
				clusters[len(clusters)-1].matchLines = append(clusters[len(clusters)-1].matchLines, line)
			} else {
				clusters = append(clusters, cluster{
					start:      start,
					end:        end,
					matchLines: []int{line},
				})
			}
		}

		for _, cl := range clusters {
			sliceLines := srcLines[cl.start-1 : cl.end]
			text := strings.Join(sliceLines, "\n")
			hash := CalculateSHA256([]byte(text))

			excerpts = append(excerpts, MultiBufferExcerpt{
				ID:           fmt.Sprintf("%s:%d-%d", filePath, cl.start, cl.end),
				FilePath:     filePath,
				StartLine:    cl.start,
				EndLine:      cl.end,
				Lines:        text,
				OriginalHash: hash,
				MatchLines:   cl.matchLines,
			})
		}
	}

	return excerpts
}

func BuildGoMultiBuffer(query, dir string, files []string) (*MultiBufferResult, error) {
	if dir == "" {
		dir = "."
	}
	cleanDir, err := filepath.Abs(dir)
	if err != nil {
		cleanDir = dir
	}

	targetFiles := files
	if len(targetFiles) == 0 {
		var scanned []string
		_ = filepath.Walk(cleanDir, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() {
				name := info.Name()
				if name == ".git" || name == "vendor" || name == "node_modules" || name == ".build" || name == "build" {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasSuffix(info.Name(), ".go") {
				scanned = append(scanned, path)
			}
			return nil
		})
		targetFiles = scanned
	}

	fileContents := make(map[string]string)
	fileHashes := make(map[string]string)
	var locations []MatchLocation
	queryLower := strings.ToLower(query)

	for _, file := range targetFiles {
		var contentBytes []byte
		if OverlayReader != nil {
			if data, err := OverlayReader(file); err == nil && len(data) > 0 {
				contentBytes = data
			}
		}
		if len(contentBytes) == 0 {
			data, err := os.ReadFile(file)
			if err != nil {
				continue
			}
			contentBytes = data
		}

		contentStr := string(contentBytes)
		fileContents[file] = contentStr
		fileHashes[file] = CalculateSHA256(contentBytes)

		lines := strings.Split(contentStr, "\n")
		for lineIdx, lineText := range lines {
			if query == "" || strings.Contains(strings.ToLower(lineText), queryLower) {
				locations = append(locations, MatchLocation{
					FilePath: file,
					Line:     lineIdx + 1,
					Column:   strings.Index(strings.ToLower(lineText), queryLower) + 1,
				})
			}
		}
	}

	excerpts := BuildMultiBufferExcerpts(fileContents, locations, 2)

	byFile := make(map[string][]MultiBufferChunk)
	for _, exc := range excerpts {
		byFile[exc.FilePath] = append(byFile[exc.FilePath], exc)
	}

	var resFiles []MultiBufferFile
	totalHits := len(locations)

	var sortedPaths []string
	for p := range byFile {
		sortedPaths = append(sortedPaths, p)
	}
	sort.Strings(sortedPaths)

	for _, path := range sortedPaths {
		rel, err := filepath.Rel(cleanDir, path)
		if err != nil {
			rel = path
		}
		resFiles = append(resFiles, MultiBufferFile{
			FilePath:       path,
			RelativePath:   rel,
			OriginalSHA256: fileHashes[path],
			Chunks:         byFile[path],
		})
	}

	return &MultiBufferResult{
		Query:      query,
		Files:      resFiles,
		TotalHits:  totalHits,
		TotalFiles: len(resFiles),
	}, nil
}

func BuildGoMultiBufferFromLocations(dir string, locations []MatchLocation, contextLines int) (*MultiBufferResult, error) {
	fileContents := make(map[string]string)
	fileHashes := make(map[string]string)

	for _, loc := range locations {
		if _, exists := fileContents[loc.FilePath]; !exists {
			var data []byte
			if OverlayReader != nil {
				if d, err := OverlayReader(loc.FilePath); err == nil && len(d) > 0 {
					data = d
				}
			}
			if len(data) == 0 {
				var err error
				data, err = os.ReadFile(loc.FilePath)
				if err != nil {
					continue
				}
			}
			fileContents[loc.FilePath] = string(data)
			fileHashes[loc.FilePath] = CalculateSHA256(data)
		}
	}

	excerpts := BuildMultiBufferExcerpts(fileContents, locations, contextLines)

	byFile := make(map[string][]MultiBufferChunk)
	for _, exc := range excerpts {
		byFile[exc.FilePath] = append(byFile[exc.FilePath], exc)
	}

	var sortedPaths []string
	for p := range byFile {
		sortedPaths = append(sortedPaths, p)
	}
	sort.Strings(sortedPaths)

	var resFiles []MultiBufferFile
	for _, path := range sortedPaths {
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			rel = path
		}
		resFiles = append(resFiles, MultiBufferFile{
			FilePath:       path,
			RelativePath:   rel,
			OriginalSHA256: fileHashes[path],
			Chunks:         byFile[path],
		})
	}

	return &MultiBufferResult{
		Files:      resFiles,
		TotalHits:  len(locations),
		TotalFiles: len(resFiles),
	}, nil
}

func ApplyMultiBufferEdits(fileContents map[string]string, edits []MultiBufferExcerpt) (map[string]string, []MultiBufferExcerpt, error) {
	updated := make(map[string]string)
	for k, v := range fileContents {
		updated[k] = v
	}

	if len(edits) == 0 {
		return updated, []MultiBufferExcerpt{}, nil
	}

	byFile := make(map[string][]MultiBufferExcerpt)
	for _, e := range edits {
		byFile[e.FilePath] = append(byFile[e.FilePath], e)
	}

	var undoSnapshot []MultiBufferExcerpt

	var filePaths []string
	for p := range byFile {
		filePaths = append(filePaths, p)
	}
	sort.Strings(filePaths)

	for _, filePath := range filePaths {
		fileEdits := byFile[filePath]
		content, ok := updated[filePath]
		if !ok {
			return nil, nil, fmt.Errorf("%w: %s", ErrFileNotFound, filePath)
		}
		srcLines := strings.Split(content, "\n")

		sort.Slice(fileEdits, func(i, j int) bool {
			return fileEdits[i].StartLine < fileEdits[j].StartLine
		})

		type editItem struct {
			ed        MultiBufferExcerpt
			origSlice string
			newLines  []string
			newHash   string
		}

		var validated []editItem
		for _, ed := range fileEdits {
			if ed.StartLine < 1 || ed.EndLine > len(srcLines) || ed.StartLine > ed.EndLine {
				return nil, nil, fmt.Errorf("%w: [%d, %d] for file %s (file has %d lines)",
					ErrEditOutOfBounds, ed.StartLine, ed.EndLine, filePath, len(srcLines))
			}

			currentSlice := strings.Join(srcLines[ed.StartLine-1:ed.EndLine], "\n")
			currentHash := CalculateSHA256([]byte(currentSlice))

			if ed.OriginalHash != "" && currentHash != ed.OriginalHash {
				return nil, nil, fmt.Errorf("hash mismatch in %s: original was modified", filePath)
			}

			newLines := strings.Split(ed.Lines, "\n")
			newHash := CalculateSHA256([]byte(ed.Lines))

			validated = append(validated, editItem{
				ed:        ed,
				origSlice: currentSlice,
				newLines:  newLines,
				newHash:   newHash,
			})
		}

		cumDelta := 0
		var fileUndo []MultiBufferExcerpt
		for _, item := range validated {
			finalStart := item.ed.StartLine + cumDelta
			finalEnd := finalStart + len(item.newLines) - 1
			delta := len(item.newLines) - (item.ed.EndLine - item.ed.StartLine + 1)
			cumDelta += delta

			fileUndo = append(fileUndo, MultiBufferExcerpt{
				FilePath:     filePath,
				StartLine:    finalStart,
				EndLine:      finalEnd,
				Lines:        item.origSlice,
				OriginalHash: item.newHash,
			})
		}
		undoSnapshot = append(undoSnapshot, fileUndo...)

		sort.Slice(fileEdits, func(i, j int) bool {
			return fileEdits[i].StartLine > fileEdits[j].StartLine
		})

		for _, ed := range fileEdits {
			newLines := strings.Split(ed.Lines, "\n")
			var result []string
			result = append(result, srcLines[:ed.StartLine-1]...)
			result = append(result, newLines...)
			result = append(result, srcLines[ed.EndLine:]...)
			srcLines = result
		}

		if strings.HasSuffix(filePath, ".go") {
			formatted, err := format.Source([]byte(strings.Join(srcLines, "\n")))
			if err == nil {
				updated[filePath] = string(formatted)
			} else {
				updated[filePath] = strings.Join(srcLines, "\n")
			}
		} else {
			updated[filePath] = strings.Join(srcLines, "\n")
		}
	}

	return updated, undoSnapshot, nil
}

func ExcerptsToFileEdits(excerpts []MultiBufferExcerpt) []MultiBufferFileEdit {
	byFile := make(map[string][]MultiBufferEdit)
	for _, exc := range excerpts {
		byFile[exc.FilePath] = append(byFile[exc.FilePath], MultiBufferEdit{
			FilePath:     exc.FilePath,
			StartLine:    exc.StartLine,
			EndLine:      exc.EndLine,
			NewLines:     exc.Lines,
			OriginalHash: exc.OriginalHash,
		})
	}

	var res []MultiBufferFileEdit
	for path, edits := range byFile {
		res = append(res, MultiBufferFileEdit{
			FilePath: path,
			Edits:    edits,
		})
	}
	return res
}

func ApplyGoMultiBufferEdits(fileEdits []MultiBufferFileEdit) (*ApplyResult, error) {
	if len(fileEdits) == 0 {
		return &ApplyResult{Success: true, FilesModified: []string{}}, nil
	}

	type stagedFile struct {
		filePath   string
		newContent []byte
		undoEdits  []MultiBufferEdit
	}

	staged := make(map[string]stagedFile)

	for _, fe := range fileEdits {
		diskBytes, err := os.ReadFile(fe.FilePath)
		if err != nil {
			return &ApplyResult{
				Success:      false,
				ConflictFile: fe.FilePath,
				ErrorMessage: fmt.Sprintf("cannot read %s: %v", fe.FilePath, err),
			}, err
		}

		if fe.OriginalSHA256 != "" {
			currentFileHash := CalculateSHA256(diskBytes)
			if currentFileHash != fe.OriginalSHA256 {
				return &ApplyResult{
					Success:      false,
					ConflictFile: fe.FilePath,
					ErrorMessage: fmt.Sprintf("file %s was modified externally (expected SHA256 %s, got %s)",
						fe.FilePath, fe.OriginalSHA256, currentFileHash),
				}, ErrFileModifiedExternally
			}
		}

		srcLines := strings.Split(string(diskBytes), "\n")

		edits := make([]MultiBufferEdit, len(fe.Edits))
		copy(edits, fe.Edits)
		sort.Slice(edits, func(i, j int) bool {
			return edits[i].StartLine < edits[j].StartLine
		})

		for i := 0; i < len(edits)-1; i++ {
			if edits[i].EndLine >= edits[i+1].StartLine {
				return &ApplyResult{
					Success:      false,
					ConflictFile: fe.FilePath,
					ErrorMessage: fmt.Sprintf("%v in %s: [%d..%d] and [%d..%d]",
						ErrOverlappingEdits, fe.FilePath, edits[i].StartLine, edits[i].EndLine,
						edits[i+1].StartLine, edits[i+1].EndLine),
				}, ErrOverlappingEdits
			}
		}

		type validatedEdit struct {
			ed        MultiBufferEdit
			origSlice string
			newLines  []string
			newHash   string
		}

		var validatedList []validatedEdit
		for _, ed := range edits {
			if ed.StartLine < 1 || ed.EndLine > len(srcLines) || ed.StartLine > ed.EndLine {
				return &ApplyResult{
					Success:      false,
					ConflictFile: fe.FilePath,
					ErrorMessage: fmt.Sprintf("%v in %s: range [%d..%d], total lines %d",
						ErrEditOutOfBounds, fe.FilePath, ed.StartLine, ed.EndLine, len(srcLines)),
				}, ErrEditOutOfBounds
			}

			currentSlice := strings.Join(srcLines[ed.StartLine-1:ed.EndLine], "\n")
			currentHash := CalculateSHA256([]byte(currentSlice))

			if ed.OriginalHash != "" && currentHash != ed.OriginalHash {
				return &ApplyResult{
					Success:      false,
					ConflictFile: fe.FilePath,
					ErrorMessage: fmt.Sprintf("hash mismatch in %s at lines [%d..%d]: content changed",
						fe.FilePath, ed.StartLine, ed.EndLine),
				}, fmt.Errorf("hash mismatch in %s: original was modified", fe.FilePath)
			}

			newLines := strings.Split(ed.NewLines, "\n")
			newHash := CalculateSHA256([]byte(ed.NewLines))

			validatedList = append(validatedList, validatedEdit{
				ed:        ed,
				origSlice: currentSlice,
				newLines:  newLines,
				newHash:   newHash,
			})
		}

		cumDelta := 0
		var fileUndoEdits []MultiBufferEdit
		for _, item := range validatedList {
			finalStart := item.ed.StartLine + cumDelta
			finalEnd := finalStart + len(item.newLines) - 1
			delta := len(item.newLines) - (item.ed.EndLine - item.ed.StartLine + 1)
			cumDelta += delta

			fileUndoEdits = append(fileUndoEdits, MultiBufferEdit{
				FilePath:     fe.FilePath,
				StartLine:    finalStart,
				EndLine:      finalEnd,
				NewLines:     item.origSlice,
				OriginalHash: item.newHash,
			})
		}

		sort.Slice(edits, func(i, j int) bool {
			return edits[i].StartLine > edits[j].StartLine
		})

		for _, ed := range edits {
			newLines := strings.Split(ed.NewLines, "\n")
			var result []string
			result = append(result, srcLines[:ed.StartLine-1]...)
			result = append(result, newLines...)
			result = append(result, srcLines[ed.EndLine:]...)
			srcLines = result
		}

		assembled := strings.Join(srcLines, "\n")
		var finalBytes []byte
		if strings.HasSuffix(fe.FilePath, ".go") {
			formatted, err := format.Source([]byte(assembled))
			if err == nil {
				finalBytes = formatted
			} else {
				finalBytes = []byte(assembled)
			}
		} else {
			finalBytes = []byte(assembled)
		}

		staged[fe.FilePath] = stagedFile{
			filePath:   fe.FilePath,
			newContent: finalBytes,
			undoEdits:  fileUndoEdits,
		}
	}

	createdTemps := make(map[string]string)
	rollbackTemps := func() {
		for _, tmp := range createdTemps {
			_ = os.Remove(tmp)
		}
	}

	nonce := fmt.Sprintf("%d_%06d", time.Now().UnixNano(), rand.Intn(1_000_000))

	for filePath, sf := range staged {
		dir := filepath.Dir(filePath)
		base := filepath.Base(filePath)
		tmpPath := filepath.Join(dir, fmt.Sprintf(".golens_tmp_%s_%s.tmp", base, nonce))

		if err := os.WriteFile(tmpPath, sf.newContent, 0o644); err != nil {
			rollbackTemps()
			return &ApplyResult{
				Success:      false,
				ConflictFile: filePath,
				ErrorMessage: fmt.Sprintf("failed to write temp file %s: %v", tmpPath, err),
			}, err
		}
		createdTemps[filePath] = tmpPath
	}

	backups := make(map[string]string)
	renamedFiles := make([]string, 0, len(staged))

	rollbackRenames := func() []string {
		var kept []string
		keep := make(map[string]bool)
		for _, fp := range renamedFiles {
			if bak, ok := backups[fp]; ok {
				if err := renameFile(bak, fp); err != nil {
					kept = append(kept, bak)
					keep[bak] = true
				}
			}
		}
		for _, bak := range backups {
			if !keep[bak] {
				_ = os.Remove(bak)
			}
		}
		rollbackTemps()
		sort.Strings(kept)
		return kept
	}

	for filePath, tmpPath := range createdTemps {
		dir := filepath.Dir(filePath)
		base := filepath.Base(filePath)
		bakPath := filepath.Join(dir, fmt.Sprintf(".golens_bak_%s_%s.bak", base, nonce))

		if err := copyFile(filePath, bakPath); err != nil {
			kept := rollbackRenames()
			return &ApplyResult{
				Success:      false,
				ConflictFile: filePath,
				ErrorMessage: withKeptBackups(fmt.Sprintf("failed to create backup for %s: %v", filePath, err), kept),
			}, err
		}
		backups[filePath] = bakPath

		if err := renameFile(tmpPath, filePath); err != nil {
			kept := rollbackRenames()
			return &ApplyResult{
				Success:      false,
				ConflictFile: filePath,
				ErrorMessage: withKeptBackups(fmt.Sprintf("failed to rename temp to %s: %v", filePath, err), kept),
			}, err
		}
		renamedFiles = append(renamedFiles, filePath)
	}

	for _, bak := range backups {
		_ = os.Remove(bak)
	}

	var undoSnapshot []MultiBufferFileEdit
	var modifiedPaths []string

	for filePath, sf := range staged {
		modifiedPaths = append(modifiedPaths, filePath)
		undoSnapshot = append(undoSnapshot, MultiBufferFileEdit{
			FilePath:       filePath,
			OriginalSHA256: CalculateSHA256(sf.newContent),
			Edits:          sf.undoEdits,
		})
	}

	sort.Strings(modifiedPaths)

	return &ApplyResult{
		Success:       true,
		FilesModified: modifiedPaths,
		UndoSnapshot:  undoSnapshot,
	}, nil
}

var renameFile = os.Rename

func withKeptBackups(msg string, kept []string) string {
	if len(kept) == 0 {
		return msg
	}
	return fmt.Sprintf("%s; could not restore the original files, recover them from these backups: %s", msg, strings.Join(kept, ", "))
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err = io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}
