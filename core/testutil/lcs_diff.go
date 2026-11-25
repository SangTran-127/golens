package testutil

import "strings"

const (
	maxDiffOutputLines = 400
	maxLCSInputLines   = 400
	maxLCSCells        = 160000
	maxLCSWindowSide   = 250
	lcsContextLead     = 6
)

func computeBoundedLCSDiff(got, want string) (lines []DiffLine, truncated bool, totalLines int) {
	normGot := strings.ReplaceAll(got, "\r\n", "\n")
	normWant := strings.ReplaceAll(want, "\r\n", "\n")
	gotParts := strings.Split(normGot, "\n")
	wantParts := strings.Split(normWant, "\n")

	if len(gotParts) == 1 && len(wantParts) == 1 {
		if normGot == normWant {
			return []DiffLine{{Type: "same", Text: normWant, LineNum: 1}}, false, 1
		}
		return []DiffLine{
			{Type: "want", Text: normWant, LineNum: 1},
			{Type: "got", Text: normGot, LineNum: 2},
		}, false, 2
	}

	prefix := 0
	for prefix < len(wantParts) && prefix < len(gotParts) && wantParts[prefix] == gotParts[prefix] {
		prefix++
	}

	suffix := 0
	for len(wantParts)-suffix > prefix && len(gotParts)-suffix > prefix &&
		wantParts[len(wantParts)-1-suffix] == gotParts[len(gotParts)-1-suffix] {
		suffix++
	}

	wMid := wantParts[prefix : len(wantParts)-suffix]
	gMid := gotParts[prefix : len(gotParts)-suffix]

	omittedMiddle := 0
	inputTruncated := false
	if len(wMid) > maxLCSInputLines || len(gMid) > maxLCSInputLines || len(wMid)*len(gMid) > maxLCSCells {
		origW := len(wMid)
		origG := len(gMid)
		if len(wMid) > maxLCSWindowSide {
			wMid = wMid[:maxLCSWindowSide]
		}
		if len(gMid) > maxLCSWindowSide {
			gMid = gMid[:maxLCSWindowSide]
		}
		omittedMiddle = (origW - len(wMid)) + (origG - len(gMid))
		inputTruncated = true
	}

	middle := alignLinesLCS(wMid, gMid, prefix+1, prefix+1)

	totalCount := prefix + len(middle) + suffix + omittedMiddle
	needsTruncate := inputTruncated || totalCount > maxDiffOutputLines

	prefixStart := 0
	if needsTruncate && prefix > lcsContextLead {
		prefixStart = prefix - lcsContextLead
	}

	out := make([]DiffLine, 0, min(totalCount, maxDiffOutputLines))
	for i := prefixStart; i < prefix; i++ {
		if len(out) >= maxDiffOutputLines {
			break
		}
		out = append(out, DiffLine{Type: "same", Text: wantParts[i], LineNum: i + 1})
	}
	for _, dl := range middle {
		if len(out) >= maxDiffOutputLines {
			break
		}
		out = append(out, dl)
	}
	if !inputTruncated {
		wBase := len(wantParts) - suffix
		for i := 0; i < suffix; i++ {
			if len(out) >= maxDiffOutputLines {
				break
			}
			out = append(out, DiffLine{Type: "same", Text: wantParts[wBase+i], LineNum: wBase + i + 1})
		}
	}

	if totalCount < len(out) {
		totalCount = len(out)
	}
	return out, needsTruncate || totalCount > len(out), totalCount
}

func alignLinesLCS(wMid, gMid []string, wStartLine, gStartLine int) []DiffLine {
	m := len(wMid)
	n := len(gMid)
	if m == 0 && n == 0 {
		return nil
	}
	if m == 0 {
		out := make([]DiffLine, n)
		for j, line := range gMid {
			out[j] = DiffLine{Type: "got", Text: line, LineNum: gStartLine + j}
		}
		return out
	}
	if n == 0 {
		out := make([]DiffLine, m)
		for i, line := range wMid {
			out[i] = DiffLine{Type: "want", Text: line, LineNum: wStartLine + i}
		}
		return out
	}

	cols := n + 1
	dp := make([]int32, (m+1)*cols)
	for i := m - 1; i >= 0; i-- {
		row := i * cols
		nextRow := (i + 1) * cols
		for j := n - 1; j >= 0; j-- {
			if wMid[i] == gMid[j] {
				dp[row+j] = dp[nextRow+j+1] + 1
			} else if dp[nextRow+j] >= dp[row+j+1] {
				dp[row+j] = dp[nextRow+j]
			} else {
				dp[row+j] = dp[row+j+1]
			}
		}
	}

	out := make([]DiffLine, 0, m+n)
	i, j := 0, 0
	for i < m || j < n {
		if i < m && j < n && wMid[i] == gMid[j] {
			out = append(out, DiffLine{Type: "same", Text: wMid[i], LineNum: wStartLine + i})
			i++
			j++
		} else if i < m && (j == n || dp[(i+1)*cols+j] >= dp[i*cols+j+1]) {
			out = append(out, DiffLine{Type: "want", Text: wMid[i], LineNum: wStartLine + i})
			i++
		} else {
			out = append(out, DiffLine{Type: "got", Text: gMid[j], LineNum: gStartLine + j})
			j++
		}
	}
	return out
}
