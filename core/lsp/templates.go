package lsp

import "strings"

var selectionTokens = []string{"${TM_SELECTED_TEXT}", "$TM_SELECTED_TEXT"}

func escapeSnippetText(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `$`, `\$`, `}`, `\}`)
	return r.Replace(s)
}

func dedentLines(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	common := ""
	first := true
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		lead := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		if first {
			common, first = lead, false
			continue
		}
		for !strings.HasPrefix(lead, common) {
			common = common[:len(common)-1]
		}
	}
	for i, line := range lines {
		lines[i] = strings.TrimPrefix(line, common)
	}
	return strings.Join(lines, "\n")
}

func UsesSelection(body string) bool {
	for _, token := range selectionTokens {
		if strings.Contains(body, token) {
			return true
		}
	}
	return false
}

func substituteSelection(line string, selectionLines []string) string {
	lead := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
	joined := strings.Join(selectionLines, "\n"+lead)
	var b strings.Builder
	for len(line) > 0 {
		if strings.HasPrefix(line, `\`) && len(line) > 1 {
			b.WriteString(line[:2])
			line = line[2:]
			continue
		}
		matched := false
		for _, token := range selectionTokens {
			if strings.HasPrefix(line, token) {
				b.WriteString(joined)
				line = line[len(token):]
				matched = true
				break
			}
		}
		if !matched {
			b.WriteByte(line[0])
			line = line[1:]
		}
	}
	return b.String()
}

func ExpandTemplate(body, indent, selection string) ExpandedSnippet {
	selectionLines := strings.Split(escapeSnippetText(dedentLines(selection)), "\n")
	lines := strings.Split(body, "\n")
	for i, line := range lines {
		lines[i] = substituteSelection(line, selectionLines)
	}
	return indentSnippet(ExpandSnippet(strings.Join(lines, "\n")), indent)
}
