package docker

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type ComposeDiagnostic struct {
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	EndLine  int    `json:"endLine"`
	EndCol   int    `json:"endCol"`
	Severity int    `json:"severity"`
	Message  string `json:"message"`
}

type ComposeResult struct {
	OK          bool                `json:"ok"`
	Diagnostics []ComposeDiagnostic `json:"diagnostics"`
	Output      string              `json:"output"`
}

func ValidateCompose(composePath string) ComposeResult {
	res := ComposeResult{Diagnostics: []ComposeDiagnostic{}}
	data, err := os.ReadFile(composePath)
	if err != nil {
		res.Diagnostics = append(res.Diagnostics, ComposeDiagnostic{Severity: 1, Message: "Couldn’t read the compose file: " + err.Error()})
		return res
	}
	cli := LookPath("docker")
	if cli == "" {
		res.Diagnostics = append(res.Diagnostics, ComposeDiagnostic{Severity: 1, Message: "Docker CLI was not found. Install OrbStack or Docker Desktop, or add docker to PATH, then validate again."})
		return res
	}
	base := filepath.Base(composePath)
	_, stderr, err := runCLI(20*time.Second, filepath.Dir(composePath), "", cli, "compose", "-f", base, "config", "--quiet")
	res.Output = strings.TrimSpace(stderr)
	if err == nil {
		res.OK = true
		return res
	}
	if res.Output == "" {
		res.Output = err.Error()
	}
	res.Diagnostics = parseComposeErrors(res.Output, base, string(data))
	return res
}

func ValidateComposeJSON(composePath string) string {
	b, err := json.Marshal(ValidateCompose(composePath))
	if err != nil {
		return `{"ok":false,"diagnostics":[],"output":"failed to encode result"}`
	}
	return string(b)
}

var (
	yamlLineRe   = regexp.MustCompile(`line (\d+)(?:, column (\d+))?(:?)`)
	fileLineRe   = regexp.MustCompile(`\.ya?ml:(\d+)(?::(\d+))?`)
	keyPathRe    = regexp.MustCompile(`\b(?:services|networks|volumes|configs|secrets)(?:\.[A-Za-z0-9_.\-]+)?`)
	extraPropRe  = regexp.MustCompile(`additional propert(?:y|ies) '([^']+)'`)
	serviceRefRe = regexp.MustCompile(`service "([^"]+)"`)
)

func parseComposeErrors(stderr, base, text string) []ComposeDiagnostic {
	lines := strings.Split(text, "\n")
	var diags []ComposeDiagnostic
	for _, raw := range strings.Split(stderr, "\n") {
		msg := cleanComposeMessage(raw, base)
		if msg == "" {
			continue
		}
		line, col := -1, -1
		if m := fileLineRe.FindStringSubmatch(msg); m != nil {
			line, col = atoiOr(m[1], 0)-1, atoiOr(m[2], 0)-1
		} else if ms := yamlLineRe.FindAllStringSubmatch(msg, -1); ms != nil {
			pick := ms[len(ms)-1]
			for _, m := range ms {
				if m[3] == ":" {
					pick = m
				}
			}
			line, col = atoiOr(pick[1], 0)-1, atoiOr(pick[2], 0)-1
		} else if path := composeKeyPath(msg); len(path) > 0 {
			line = locateKeyPath(lines, path)
		}
		if line < 0 {
			continue
		}
		diags = append(diags, composeDiagAt(lines, line, col, msg))
	}
	if len(diags) == 0 {
		msg := strings.TrimSpace(stderr)
		if cleaned := cleanComposeMessage(msg, base); cleaned != "" {
			msg = cleaned
		}
		diags = append(diags, composeDiagAt(lines, 0, -1, msg))
	}
	return diags
}

func cleanComposeMessage(line, base string) string {
	line = strings.TrimSpace(line)
	if i := strings.LastIndex(line, base+": "); i >= 0 {
		line = line[i+len(base)+2:]
	}
	return strings.TrimSpace(line)
}

func composeKeyPath(msg string) []string {
	if m := strings.TrimRight(keyPathRe.FindString(msg), "."); m != "" {
		path := strings.Split(m, ".")
		if p := extraPropRe.FindStringSubmatch(msg); p != nil {
			path = append(path, p[1])
		}
		return path
	}
	if m := serviceRefRe.FindStringSubmatch(msg); m != nil {
		return []string{"services", m[1]}
	}
	return nil
}

func locateKeyPath(lines []string, path []string) int {
	found := -1
	parentIndent := -1
	start := 0
	for _, key := range path {
		hit := -1
		for i := start; i < len(lines); i++ {
			t := strings.TrimSpace(lines[i])
			if t == "" || strings.HasPrefix(t, "#") {
				continue
			}
			indent := len(lines[i]) - len(strings.TrimLeft(lines[i], " "))
			if indent <= parentIndent {
				break
			}
			k, _, ok := strings.Cut(t, ":")
			if ok && strings.Trim(strings.TrimSpace(k), `"'`) == key {
				hit = i
				parentIndent = indent
				break
			}
		}
		if hit < 0 {
			break
		}
		found = hit
		start = hit + 1
	}
	return found
}

func composeDiagAt(lines []string, line, col int, msg string) ComposeDiagnostic {
	if line >= len(lines) {
		line = len(lines) - 1
		for line > 0 && strings.TrimSpace(lines[line]) == "" {
			line--
		}
	}
	if line < 0 {
		line = 0
	}
	text := ""
	if line < len(lines) {
		text = strings.TrimSuffix(lines[line], "\r")
	}
	start := len(text) - len(strings.TrimLeft(text, " \t"))
	startCol := utf16Col(text, start)
	if col >= 0 {
		startCol = utf16Col(text, runeByteOffset(text, col))
	}
	endCol := utf16Col(text, len(text))
	if endCol < startCol {
		endCol = startCol
	}
	return ComposeDiagnostic{Line: line, Col: startCol, EndLine: line, EndCol: endCol, Severity: 1, Message: msg}
}

func runeByteOffset(s string, runeCol int) int {
	n := 0
	for i := range s {
		if n == runeCol {
			return i
		}
		n++
	}
	return len(s)
}

func atoiOr(s string, def int) int {
	if v, err := strconv.Atoi(s); err == nil {
		return v
	}
	return def
}
