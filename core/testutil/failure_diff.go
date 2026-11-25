package testutil

import (
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type DiffLine struct {
	Type    string `json:"type"`
	Text    string `json:"text"`
	LineNum int    `json:"lineNum"`
}

type TestFailureAnnotation struct {
	File           string     `json:"file"`
	Line           int        `json:"line"`
	TestName       string     `testName:"testName" json:"testName"`
	Message        string     `json:"message"`
	Got            string     `json:"got,omitempty"`
	Want           string     `json:"want,omitempty"`
	DiffLines      []DiffLine `json:"diffLines,omitempty"`
	DiffTruncated  bool       `json:"diffTruncated,omitempty"`
	DiffTotalLines int        `json:"diffTotalLines,omitempty"`
}

var (
	ansiEscapeRegex = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)
	fileLineRegex   = regexp.MustCompile(`^\s*((?:[a-zA-Z]:)?[^:\r\n]+\.go):(\d+):(?:\s*(.*))?$`)
	gotWantRegex1   = regexp.MustCompile(`(?i)got:?\s*(.+?)(?:,\s*|\s+)want:?\s*(.+)$`)
	wantGotRegex2   = regexp.MustCompile(`(?i)want:?\s*(.+?)(?:,\s*|\s+)got:?\s*(.+)$`)
	testifyExpected = regexp.MustCompile(`(?i)expected:\s*(.+)`)
	testifyActual   = regexp.MustCompile(`(?i)actual\s*:\s*(.+)`)
)

func stripANSI(s string) string {
	return ansiEscapeRegex.ReplaceAllString(s, "")
}

func isAbsolutePath(p string) bool {
	if filepath.IsAbs(p) {
		return true
	}
	if len(p) >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/') {
		c := p[0]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			return true
		}
	}
	return false
}

func isTestRunnerBoundary(line string) bool {
	t := strings.TrimSpace(line)
	if strings.HasPrefix(t, "--- FAIL:") ||
		strings.HasPrefix(t, "--- PASS:") ||
		strings.HasPrefix(t, "--- SKIP:") ||
		strings.HasPrefix(t, "=== RUN") ||
		strings.HasPrefix(t, "=== CONT") ||
		strings.HasPrefix(t, "=== PAUSE") ||
		t == "FAIL" || t == "PASS" ||
		strings.HasPrefix(t, "FAIL\t") ||
		strings.HasPrefix(t, "ok\t") ||
		strings.HasPrefix(t, "?\t") ||
		strings.HasPrefix(t, "exit status ") {
		return true
	}
	return false
}

const maxAnnotationsCap = 100

func ParseTestFailureLocations(pkgDir string, testName string, outputLines []string) []TestFailureAnnotation {
	if len(outputLines) == 0 {
		return nil
	}

	type failureBlock struct {
		file  string
		line  int
		lines []string
	}

	var blocks []failureBlock
	var current *failureBlock

	for _, rawLine := range outputLines {
		cleanLine := stripANSI(rawLine)
		trimmed := strings.TrimRight(cleanLine, "\r\n")

		if isTestRunnerBoundary(trimmed) {
			current = nil
			continue
		}

		trimmedSpace := strings.TrimSpace(trimmed)
		if strings.HasPrefix(trimmedSpace, "Error Trace:") {
			startNewTrace := current == nil
			if !startNewTrace {
				for _, existing := range current.lines {
					et := strings.TrimSpace(existing)
					if strings.HasPrefix(et, "Test:") || strings.HasPrefix(et, "Error Trace:") {
						startNewTrace = true
						break
					}
				}
			}
			if startNewTrace {
				traceFile := ""
				traceLine := 0
				if m := traceFrameRegex.FindStringSubmatch(trimmedSpace); m != nil {
					if ln, err := strconv.Atoi(m[2]); err == nil && ln > 0 {
						traceFile = resolveTracePath(pkgDir, m[1])
						traceLine = ln
					}
				}
				blocks = append(blocks, failureBlock{
					file:  traceFile,
					line:  traceLine,
					lines: []string{trimmed},
				})
				current = &blocks[len(blocks)-1]
				continue
			}
		}

		m := fileLineRegex.FindStringSubmatch(trimmed)
		if m != nil {
			lineNum, err := strconv.Atoi(m[2])
			if err == nil {
				filePath := m[1]
				if !isAbsolutePath(filePath) && pkgDir != "" {
					filePath = filepath.Join(pkgDir, filePath)
				}
				rest := strings.TrimSpace(m[3])
				var bLines []string
				if rest != "" {
					bLines = append(bLines, rest)
				}
				blocks = append(blocks, failureBlock{
					file:  filePath,
					line:  lineNum,
					lines: bLines,
				})
				current = &blocks[len(blocks)-1]
				continue
			}
		}

		if current != nil {
			current.lines = append(current.lines, trimmed)
		}
	}

	if len(blocks) == 0 {
		return nil
	}

	annotations := make([]TestFailureAnnotation, 0, len(blocks))
	for _, block := range blocks {
		fullText := strings.TrimSpace(strings.Join(block.lines, "\n"))
		if fullText == "" {
			fullText = "Test failed"
		}

		resolvedFile, resolvedLine := unwrapTestifyErrorTrace(pkgDir, block.file, block.line, block.lines)
		if resolvedFile == "" || resolvedLine <= 0 {
			continue
		}

		ann := TestFailureAnnotation{
			File:     resolvedFile,
			Line:     resolvedLine,
			TestName: testName,
			Message:  fullText,
		}

		if diffLines, got, want, ok := parseGoCmpDiff(block.lines); ok {
			ann.Got = got
			ann.Want = want
			if len(diffLines) > maxDiffOutputLines {
				ann.DiffTruncated = true
				ann.DiffTotalLines = len(diffLines)
				ann.DiffLines = diffLines[:maxDiffOutputLines]
			} else {
				ann.DiffLines = diffLines
			}
		} else if diffLines, got, want, truncated, total, ok := parseTestifyBlock(block.lines); ok {
			if summary := parseTestifyMessageSummary(block.lines); summary != "" {
				ann.Message = summary
			}
			ann.Got = got
			ann.Want = want
			ann.DiffLines = diffLines
			ann.DiffTruncated = truncated
			if truncated {
				ann.DiffTotalLines = total
			}
		} else if diffLines, got, want, truncated, total, ok := parseMultiLineGotWant(block.lines); ok {
			ann.Got = got
			ann.Want = want
			ann.DiffLines = diffLines
			ann.DiffTruncated = truncated
			if truncated {
				ann.DiffTotalLines = total
			}
		} else if g, w, ok := parseGotWant(fullText); ok {
			ann.Got = g
			ann.Want = w
			diffLines, truncated, total := computeBoundedLCSDiff(g, w)
			ann.DiffLines = diffLines
			ann.DiffTruncated = truncated
			if truncated {
				ann.DiffTotalLines = total
			}
		}

		annotations = append(annotations, ann)
		if len(annotations) >= maxAnnotationsCap {
			break
		}
	}

	return annotations
}

func parseGotWant(text string) (got string, want string, ok bool) {
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if m := gotWantRegex1.FindStringSubmatch(trimmed); m != nil {
			return strings.TrimSpace(m[1]), strings.TrimSpace(m[2]), true
		}
		if m := wantGotRegex2.FindStringSubmatch(trimmed); m != nil {
			return strings.TrimSpace(m[2]), strings.TrimSpace(m[1]), true
		}
	}
	return "", "", false
}

func parseTestify(lines []string) (expected string, actual string, ok bool) {
	return parseTestifyExpectedActual(lines)
}

func parseGoCmpDiff(lines []string) (diff []DiffLine, got string, want string, ok bool) {
	isGoCmp := false
	gotMinus := true

	for _, l := range lines {
		if strings.Contains(l, "(-got +want)") {
			isGoCmp = true
			gotMinus = true
			break
		} else if strings.Contains(l, "(-want +got)") {
			isGoCmp = true
			gotMinus = false
			break
		}
	}

	if !isGoCmp {
		return nil, "", "", false
	}

	var gotLines, wantLines []string
	var result []DiffLine
	lineNo := 1

	for _, l := range lines {
		trimmed := strings.TrimRight(l, "\r\n")
		rawTrimmed := strings.TrimSpace(trimmed)
		if isTestRunnerBoundary(rawTrimmed) {
			break
		}
		if strings.HasPrefix(rawTrimmed, "(-") || strings.HasPrefix(rawTrimmed, "(+") {
			continue
		}

		if strings.HasPrefix(trimmed, "-") || strings.HasPrefix(rawTrimmed, "-") {
			content := strings.TrimPrefix(trimmed, "-")
			content = strings.TrimPrefix(content, " ")
			typ := "got"
			if !gotMinus {
				typ = "want"
			}
			result = append(result, DiffLine{Type: typ, Text: content, LineNum: lineNo})
			lineNo++
			if typ == "got" {
				gotLines = append(gotLines, content)
			} else {
				wantLines = append(wantLines, content)
			}
		} else if strings.HasPrefix(trimmed, "+") || strings.HasPrefix(rawTrimmed, "+") {
			content := strings.TrimPrefix(trimmed, "+")
			content = strings.TrimPrefix(content, " ")
			typ := "want"
			if !gotMinus {
				typ = "got"
			}
			result = append(result, DiffLine{Type: typ, Text: content, LineNum: lineNo})
			lineNo++
			if typ == "want" {
				wantLines = append(wantLines, content)
			} else {
				gotLines = append(gotLines, content)
			}
		} else if (strings.HasPrefix(trimmed, "  ") || strings.HasPrefix(trimmed, "\t")) && rawTrimmed != "" {
			content := strings.TrimSpace(trimmed)
			result = append(result, DiffLine{Type: "same", Text: content, LineNum: lineNo})
			lineNo++
			gotLines = append(gotLines, content)
			wantLines = append(wantLines, content)
		}
	}

	return result, strings.Join(gotLines, "\n"), strings.Join(wantLines, "\n"), len(result) > 0
}

func generateDiffLines(got, want string) []DiffLine {
	lines, _, _ := computeBoundedLCSDiff(got, want)
	return lines
}
