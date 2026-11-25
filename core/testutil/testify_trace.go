package testutil

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	traceFrameRegex      = regexp.MustCompile(`^\s*(?:Error Trace:\s*)?((?:[a-zA-Z]:)?[^:\r\n]+\.go):(\d+):?\s*$`)
	hunkHeaderRegex      = regexp.MustCompile(`^@@\s*-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@`)
	testifyExpectedField = regexp.MustCompile(`^(?i)expected\s*:\s*(.*)$`)
	testifyActualField   = regexp.MustCompile(`^(?i)actual\s*:\s*(.*)$`)
	gotLabelLineRegex    = regexp.MustCompile(`^(?i)got\s*:\s*(.*)$`)
	wantLabelLineRegex   = regexp.MustCompile(`^(?i)want\s*:\s*(.*)$`)
)

type traceFrame struct {
	file string
	line int
}

func unwrapTestifyErrorTrace(pkgDir, fallbackFile string, fallbackLine int, lines []string) (string, int) {
	inTrace := false
	var frames []traceFrame

	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if strings.HasPrefix(trimmed, "Error Trace:") {
			inTrace = true
			if m := traceFrameRegex.FindStringSubmatch(trimmed); m != nil {
				if ln, err := strconv.Atoi(m[2]); err == nil && ln > 0 {
					frames = append(frames, traceFrame{file: resolveTracePath(pkgDir, m[1]), line: ln})
				}
			}
			continue
		}
		if !inTrace {
			continue
		}
		if trimmed == "" || isTestifySectionHeader(trimmed) {
			inTrace = false
			continue
		}
		if m := traceFrameRegex.FindStringSubmatch(trimmed); m != nil {
			if ln, err := strconv.Atoi(m[2]); err == nil && ln > 0 {
				frames = append(frames, traceFrame{file: resolveTracePath(pkgDir, m[1]), line: ln})
				continue
			}
		}
		inTrace = false
	}

	if len(frames) == 0 {
		return fallbackFile, fallbackLine
	}

	cleanPkg := ""
	if pkgDir != "" {
		cleanPkg = filepath.Clean(pkgDir)
	}

	bestIdx := -1
	for i, fr := range frames {
		if isExternalTraceFile(fr.file) {
			continue
		}
		if strings.HasSuffix(fr.file, "_test.go") && frameMatchesPkgDir(fr.file, cleanPkg) {
			bestIdx = i
		}
	}
	if bestIdx >= 0 {
		return frames[bestIdx].file, frames[bestIdx].line
	}

	for i, fr := range frames {
		if isExternalTraceFile(fr.file) {
			continue
		}
		if strings.HasSuffix(fr.file, "_test.go") {
			bestIdx = i
		}
	}
	if bestIdx >= 0 {
		return frames[bestIdx].file, frames[bestIdx].line
	}

	for i, fr := range frames {
		if isExternalTraceFile(fr.file) {
			continue
		}
		if frameMatchesPkgDir(fr.file, cleanPkg) {
			bestIdx = i
		}
	}
	if bestIdx >= 0 {
		return frames[bestIdx].file, frames[bestIdx].line
	}

	return fallbackFile, fallbackLine
}

func resolveTracePath(pkgDir, filePath string) string {
	cleaned := filepath.Clean(filePath)
	if isAbsolutePath(cleaned) || pkgDir == "" {
		return cleaned
	}
	return filepath.Join(pkgDir, cleaned)
}

func frameMatchesPkgDir(frameFile, cleanPkg string) bool {
	if cleanPkg == "" {
		return false
	}
	if filepath.Clean(filepath.Dir(frameFile)) == cleanPkg {
		return true
	}
	if strings.HasPrefix(frameFile, cleanPkg+string(filepath.Separator)) {
		return true
	}
	base := filepath.Base(frameFile)
	if base != "" {
		if _, err := os.Stat(filepath.Join(cleanPkg, base)); err == nil {
			return true
		}
	}
	return false
}

func isExternalTraceFile(path string) bool {
	slashed := filepath.ToSlash(path)
	return strings.Contains(slashed, "/pkg/mod/") ||
		strings.Contains(slashed, "/vendor/") ||
		strings.Contains(slashed, "stretchr/testify") ||
		strings.Contains(slashed, "/src/testing/") ||
		strings.Contains(slashed, "/src/runtime/")
}

func isTestifySectionHeader(trimmed string) bool {
	return strings.HasPrefix(trimmed, "Error:") ||
		strings.HasPrefix(trimmed, "Test:") ||
		strings.HasPrefix(trimmed, "Messages:") ||
		strings.HasPrefix(trimmed, "Diff:") ||
		strings.HasPrefix(trimmed, "Error Trace:")
}

func parseTestifyBlock(lines []string) (diff []DiffLine, got, want string, truncated bool, totalLines int, ok bool) {
	exp, act, hasPair := parseTestifyExpectedActual(lines)
	diffLines, dGot, dWant, dTrunc, dTotal, hasDiff := parseTestifyDiffSection(lines)

	if hasDiff {
		if !hasPair {
			want = dWant
			got = dGot
		} else {
			want = exp
			got = act
		}
		return diffLines, got, want, dTrunc, dTotal, true
	}

	if hasPair {
		computed, cTrunc, cTotal := computeBoundedLCSDiff(act, exp)
		return computed, act, exp, cTrunc, cTotal, true
	}

	return nil, "", "", false, 0, false
}

func parseTestifyExpectedActual(lines []string) (expected string, actual string, ok bool) {
	var expLines, actLines []string
	var expFound, actFound bool
	var expInline, actInline bool
	mode := ""
	expCol := 0
	actCol := 0

	for _, raw := range lines {
		line := strings.TrimRight(raw, "\r\n")
		trimmed := strings.TrimSpace(line)

		if isTestRunnerBoundary(trimmed) || trimmed == "Diff:" ||
			strings.HasPrefix(trimmed, "Test:") ||
			strings.HasPrefix(trimmed, "Messages:") ||
			strings.HasPrefix(trimmed, "Error Trace:") {
			mode = ""
			continue
		}

		if m := testifyExpectedField.FindStringSubmatch(trimmed); m != nil {
			expFound = true
			mode = "expected"
			expLines = nil
			val := strings.TrimSpace(m[1])
			expInline = val != ""
			if val != "" {
				expLines = append(expLines, val)
			}
			expCol = leadingSpacesCount(line)
			continue
		}

		if m := testifyActualField.FindStringSubmatch(trimmed); m != nil {
			actFound = true
			mode = "actual"
			actLines = nil
			val := strings.TrimSpace(m[1])
			actInline = val != ""
			if val != "" {
				actLines = append(actLines, val)
			}
			actCol = leadingSpacesCount(line)
			continue
		}

		if strings.HasPrefix(trimmed, "Error:") {
			mode = ""
			continue
		}

		switch mode {
		case "expected":
			if trimmed == "" {
				mode = ""
				continue
			}
			expLines = append(expLines, stripIndentAtLeast(line, expCol))
		case "actual":
			if trimmed == "" {
				mode = ""
				continue
			}
			actLines = append(actLines, stripIndentAtLeast(line, actCol))
		}
	}

	if !expFound || !actFound {
		return "", "", false
	}

	if expInline {
		expected = dedentNonFirstLines(expLines)
	} else {
		expected = dedentAllLines(expLines)
	}
	if actInline {
		actual = dedentNonFirstLines(actLines)
	} else {
		actual = dedentAllLines(actLines)
	}
	return expected, actual, true
}

func parseTestifyDiffSection(lines []string) (diff []DiffLine, got, want string, truncated bool, totalLines int, ok bool) {
	diffIdx := -1
	for i, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "Diff:" || strings.HasPrefix(trimmed, "Diff:") {
			diffIdx = i
			break
		}
	}
	if diffIdx < 0 {
		return nil, "", "", false, 0, false
	}

	expectedIsMinus := true
	headerPrefix := ""
	hasPrefix := false
	inBody := false

	var wantLines []string
	var gotLines []string
	var allLines []DiffLine
	wantLineNo := 1
	gotLineNo := 1

	for i := diffIdx + 1; i < len(lines); i++ {
		line := strings.TrimRight(lines[i], "\r\n")
		trimmed := strings.TrimSpace(line)

		if isTestRunnerBoundary(trimmed) ||
			strings.HasPrefix(trimmed, "Test:") ||
			strings.HasPrefix(trimmed, "Messages:") ||
			strings.HasPrefix(trimmed, "Error Trace:") {
			break
		}

		if strings.HasPrefix(trimmed, "--- ") {
			if strings.Contains(strings.ToLower(trimmed), "actual") {
				expectedIsMinus = false
			} else if strings.Contains(strings.ToLower(trimmed), "expected") {
				expectedIsMinus = true
			}
			headerPrefix = leadingWhitespace(line)
			hasPrefix = true
			inBody = true
			continue
		}

		if strings.HasPrefix(trimmed, "+++ ") {
			if !hasPrefix {
				headerPrefix = leadingWhitespace(line)
				hasPrefix = true
			}
			inBody = true
			continue
		}

		if m := hunkHeaderRegex.FindStringSubmatch(trimmed); m != nil {
			if !hasPrefix {
				headerPrefix = leadingWhitespace(line)
				hasPrefix = true
			}
			if w, err := strconv.Atoi(m[1]); err == nil && w > 0 {
				wantLineNo = w
			}
			if g, err := strconv.Atoi(m[2]); err == nil && g > 0 {
				gotLineNo = g
			}
			inBody = true
			continue
		}

		if !inBody && trimmed == "" {
			continue
		}

		if trimmed == "" && !hasPrefix {
			continue
		}

		bodyLine := line
		if hasPrefix && strings.HasPrefix(bodyLine, headerPrefix) {
			bodyLine = bodyLine[len(headerPrefix):]
		} else {
			bodyLine = strings.TrimLeft(bodyLine, " \t")
		}

		if bodyLine == "" {
			if inBody {
				allLines = append(allLines, DiffLine{Type: "same", Text: "", LineNum: wantLineNo})
				wantLines = append(wantLines, "")
				gotLines = append(gotLines, "")
				wantLineNo++
				gotLineNo++
			}
			continue
		}

		switch bodyLine[0] {
		case '-':
			content := bodyLine[1:]
			typ := "want"
			lineNum := wantLineNo
			if !expectedIsMinus {
				typ = "got"
				lineNum = gotLineNo
				gotLineNo++
				gotLines = append(gotLines, content)
			} else {
				wantLineNo++
				wantLines = append(wantLines, content)
			}
			allLines = append(allLines, DiffLine{Type: typ, Text: content, LineNum: lineNum})
			inBody = true
		case '+':
			content := bodyLine[1:]
			typ := "got"
			lineNum := gotLineNo
			if !expectedIsMinus {
				typ = "want"
				lineNum = wantLineNo
				wantLineNo++
				wantLines = append(wantLines, content)
			} else {
				gotLineNo++
				gotLines = append(gotLines, content)
			}
			allLines = append(allLines, DiffLine{Type: typ, Text: content, LineNum: lineNum})
			inBody = true
		case ' ':
			content := bodyLine[1:]
			allLines = append(allLines, DiffLine{Type: "same", Text: content, LineNum: wantLineNo})
			wantLines = append(wantLines, content)
			gotLines = append(gotLines, content)
			wantLineNo++
			gotLineNo++
			inBody = true
		default:
			if inBody {
				allLines = append(allLines, DiffLine{Type: "same", Text: bodyLine, LineNum: wantLineNo})
				wantLines = append(wantLines, bodyLine)
				gotLines = append(gotLines, bodyLine)
				wantLineNo++
				gotLineNo++
			}
		}
	}

	for len(allLines) > 0 && allLines[len(allLines)-1].Type == "same" && allLines[len(allLines)-1].Text == "" {
		allLines = allLines[:len(allLines)-1]
	}
	wantLines = trimTrailingEmptyLines(wantLines)
	gotLines = trimTrailingEmptyLines(gotLines)

	if len(allLines) == 0 {
		return nil, "", "", false, 0, false
	}

	total := len(allLines)
	if total > maxDiffOutputLines {
		return allLines[:maxDiffOutputLines], strings.Join(gotLines, "\n"), strings.Join(wantLines, "\n"), true, total, true
	}
	return allLines, strings.Join(gotLines, "\n"), strings.Join(wantLines, "\n"), false, total, true
}

func parseMultiLineGotWant(lines []string) (diff []DiffLine, got, want string, truncated bool, totalLines int, ok bool) {
	var gotLines, wantLines []string
	var gotFound, wantFound bool
	mode := ""
	gotIndent := 0
	wantIndent := 0

	for _, raw := range lines {
		line := strings.TrimRight(raw, "\r\n")
		trimmed := strings.TrimSpace(line)

		if isTestRunnerBoundary(trimmed) || isTestifySectionHeader(trimmed) {
			mode = ""
			continue
		}

		if gotWantRegex1.MatchString(trimmed) || wantGotRegex2.MatchString(trimmed) {
			return nil, "", "", false, 0, false
		}

		if m := gotLabelLineRegex.FindStringSubmatch(trimmed); m != nil {
			gotFound = true
			mode = "got"
			gotLines = nil
			val := strings.TrimSpace(m[1])
			if val != "" {
				gotLines = append(gotLines, val)
			}
			gotIndent = leadingSpacesCount(line)
			continue
		}

		if m := wantLabelLineRegex.FindStringSubmatch(trimmed); m != nil {
			wantFound = true
			mode = "want"
			wantLines = nil
			val := strings.TrimSpace(m[1])
			if val != "" {
				wantLines = append(wantLines, val)
			}
			wantIndent = leadingSpacesCount(line)
			continue
		}

		if m := testifyActualField.FindStringSubmatch(trimmed); m != nil {
			gotFound = true
			mode = "got"
			gotLines = nil
			val := strings.TrimSpace(m[1])
			if val != "" {
				gotLines = append(gotLines, val)
			}
			gotIndent = leadingSpacesCount(line)
			continue
		}

		if m := testifyExpectedField.FindStringSubmatch(trimmed); m != nil {
			wantFound = true
			mode = "want"
			wantLines = nil
			val := strings.TrimSpace(m[1])
			if val != "" {
				wantLines = append(wantLines, val)
			}
			wantIndent = leadingSpacesCount(line)
			continue
		}

		switch mode {
		case "got":
			if trimmed == "" && len(gotLines) == 0 {
				continue
			}
			if trimmed == "" {
				gotLines = append(gotLines, "")
				continue
			}
			gotLines = append(gotLines, stripIndentAtLeast(line, gotIndent))
		case "want":
			if trimmed == "" && len(wantLines) == 0 {
				continue
			}
			if trimmed == "" {
				wantLines = append(wantLines, "")
				continue
			}
			wantLines = append(wantLines, stripIndentAtLeast(line, wantIndent))
		}
	}

	if !gotFound || !wantFound {
		return nil, "", "", false, 0, false
	}

	gotLines = trimTrailingEmptyLines(gotLines)
	wantLines = trimTrailingEmptyLines(wantLines)
	if len(gotLines) <= 1 && len(wantLines) <= 1 {
		return nil, "", "", false, 0, false
	}

	got = dedentAllLines(gotLines)
	want = dedentAllLines(wantLines)
	computed, trunc, total := computeBoundedLCSDiff(got, want)
	return computed, got, want, trunc, total, true
}

func leadingWhitespace(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	return s[:i]
}

func leadingSpacesCount(s string) int {
	return len(leadingWhitespace(s))
}

func stripIndentAtLeast(line string, minIndent int) string {
	ws := leadingWhitespace(line)
	if len(ws) > minIndent {
		return line[minIndent:]
	}
	return strings.TrimLeft(line, " \t")
}

func dedentNonFirstLines(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	if len(lines) == 1 {
		return lines[0]
	}
	rest := dedentAllLines(lines[1:])
	if rest == "" {
		return lines[0]
	}
	return lines[0] + "\n" + rest
}

func dedentAllLines(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	common := -1
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			continue
		}
		n := len(leadingWhitespace(l))
		if common < 0 || n < common {
			common = n
		}
	}
	if common <= 0 {
		return strings.Join(lines, "\n")
	}
	out := make([]string, len(lines))
	for i, l := range lines {
		if len(l) >= common && strings.TrimSpace(l[:common]) == "" {
			out[i] = l[common:]
		} else {
			out[i] = strings.TrimLeft(l, " \t")
		}
	}
	return strings.Join(out, "\n")
}

func trimTrailingEmptyLines(lines []string) []string {
	end := len(lines)
	for end > 0 && strings.TrimSpace(lines[end-1]) == "" {
		end--
	}
	return lines[:end]
}

func parseTestifyMessageSummary(lines []string) string {
	var errSummary, msgSummary string
	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if strings.HasPrefix(trimmed, "Error:") {
			val := strings.TrimSpace(strings.TrimPrefix(trimmed, "Error:"))
			val = strings.TrimSuffix(val, ":")
			if val != "" {
				errSummary = val
			}
		} else if strings.HasPrefix(trimmed, "Messages:") {
			val := strings.TrimSpace(strings.TrimPrefix(trimmed, "Messages:"))
			if val != "" {
				msgSummary = val
			}
		}
	}
	if errSummary != "" && msgSummary != "" {
		return errSummary + " — " + msgSummary
	}
	if msgSummary != "" {
		return msgSummary
	}
	return errSummary
}
