package testutil

import (
	"bufio"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

const (
	maxCoverageFiles      = 500
	maxCoverageBlockLines = 2000
)

type FileCoverage struct {
	File           string `json:"file"`
	CoveredLines   []int  `json:"coveredLines"`
	UncoveredLines []int  `json:"uncoveredLines"`
}

func ParseCoverProfile(profilePath, workspaceRoot, modulePath string, suiteDirs map[string]string) ([]FileCoverage, map[string]float64, error) {
	f, err := os.Open(profilePath)
	if err != nil {
		return nil, nil, err
	}
	defer func() { _ = f.Close() }()

	modRoot := workspaceRoot
	if modulePath == "" && workspaceRoot != "" {
		if r, m := FindModuleRoot(workspaceRoot); m != "" {
			modRoot = r
			modulePath = m
		}
	}

	var fileOrder []string
	fileLines := make(map[string]map[int]bool)
	pkgTotalStmts := make(map[string]int)
	pkgCoveredStmts := make(map[string]int)

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "mode:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 3 {
			continue
		}
		numStmt, err1 := strconv.Atoi(fields[1])
		count, err2 := strconv.Atoi(fields[2])
		if err1 != nil || err2 != nil || numStmt < 0 || count < 0 {
			continue
		}
		loc := fields[0]
		colonIdx := strings.LastIndexByte(loc, ':')
		if colonIdx <= 0 {
			continue
		}
		fileSpec := loc[:colonIdx]
		rangeSpec := loc[colonIdx+1:]
		startLine, endLine, ok := parseLineRange(rangeSpec)
		if !ok {
			continue
		}
		if endLine-startLine >= maxCoverageBlockLines {
			endLine = startLine + maxCoverageBlockLines - 1
		}

		importPath, baseName := splitImportAndFile(fileSpec)
		if importPath != "" && numStmt > 0 {
			pkgTotalStmts[importPath] += numStmt
			if count > 0 {
				pkgCoveredStmts[importPath] += numStmt
			}
		}

		resolved := resolveCoverageFile(fileSpec, importPath, baseName, workspaceRoot, modRoot, modulePath, suiteDirs)
		lines, exists := fileLines[resolved]
		if !exists {
			if len(fileOrder) >= maxCoverageFiles {
				continue
			}
			lines = make(map[int]bool)
			fileLines[resolved] = lines
			fileOrder = append(fileOrder, resolved)
		}
		for ln := startLine; ln <= endLine; ln++ {
			if count > 0 {
				lines[ln] = true
			} else if _, seen := lines[ln]; !seen {
				lines[ln] = false
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, nil, err
	}

	filesCov := make([]FileCoverage, 0, len(fileOrder))
	for _, path := range fileOrder {
		lines := fileLines[path]
		covered := make([]int, 0)
		uncovered := make([]int, 0)
		for ln, cov := range lines {
			if cov {
				covered = append(covered, ln)
			} else {
				uncovered = append(uncovered, ln)
			}
		}
		slices.Sort(covered)
		slices.Sort(uncovered)
		filesCov = append(filesCov, FileCoverage{
			File:           path,
			CoveredLines:   covered,
			UncoveredLines: uncovered,
		})
	}

	pkgCov := make(map[string]float64, len(pkgTotalStmts))
	for pkg, total := range pkgTotalStmts {
		if total > 0 {
			pkgCov[pkg] = 100.0 * float64(pkgCoveredStmts[pkg]) / float64(total)
		}
	}

	return filesCov, pkgCov, nil
}

func parseLineRange(rangeSpec string) (int, int, bool) {
	commaIdx := strings.IndexByte(rangeSpec, ',')
	if commaIdx <= 0 {
		return 0, 0, false
	}
	startLine, ok1 := parseLineNum(rangeSpec[:commaIdx])
	endLine, ok2 := parseLineNum(rangeSpec[commaIdx+1:])
	if !ok1 || !ok2 || startLine <= 0 || endLine < startLine {
		return 0, 0, false
	}
	return startLine, endLine, true
}

func parseLineNum(posSpec string) (int, bool) {
	dotIdx := strings.IndexByte(posSpec, '.')
	if dotIdx <= 0 {
		return 0, false
	}
	n, err := strconv.Atoi(posSpec[:dotIdx])
	return n, err == nil
}

func splitImportAndFile(fileSpec string) (string, string) {
	slashIdx := strings.LastIndexByte(fileSpec, '/')
	if slashIdx <= 0 {
		return "", fileSpec
	}
	return fileSpec[:slashIdx], fileSpec[slashIdx+1:]
}

func resolveCoverageFile(fileSpec, importPath, baseName, workspaceRoot, modRoot, modulePath string, suiteDirs map[string]string) string {
	if filepath.IsAbs(fileSpec) {
		return filepath.Clean(fileSpec)
	}
	if suiteDirs != nil && importPath != "" {
		if dir, ok := suiteDirs[importPath]; ok && dir != "" {
			if filepath.IsAbs(dir) {
				return filepath.Join(dir, baseName)
			}
			if workspaceRoot != "" {
				return filepath.Join(workspaceRoot, dir, baseName)
			}
			return filepath.Join(dir, baseName)
		}
	}
	if modulePath != "" && modRoot != "" {
		if importPath == modulePath {
			return filepath.Join(modRoot, baseName)
		}
		if rel, ok := strings.CutPrefix(importPath, modulePath+"/"); ok {
			return filepath.Join(modRoot, filepath.FromSlash(rel), baseName)
		}
	}
	if workspaceRoot != "" {
		candidate := filepath.Join(workspaceRoot, filepath.FromSlash(fileSpec))
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return fileSpec
}
