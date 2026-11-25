package goast

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

type GoGenerateDirective struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Command string `json:"command"`
	RunArg  string `json:"runArg"`
	Label   string `json:"label"`
}

func ScanGoGenerateDirectives(filePath, src string) (string, error) {
	if src == "" && filePath != "" {
		if data, err := os.ReadFile(filePath); err == nil {
			src = string(data)
		}
	}

	directives := make([]GoGenerateDirective, 0)
	if src == "" {
		b, err := json.Marshal(directives)
		return string(b), err
	}

	lines := strings.Split(src, "\n")
	for i, rawLine := range lines {
		line := strings.TrimRight(rawLine, "\r")
		if !strings.HasPrefix(line, "//go:generate ") && !strings.HasPrefix(line, "//go:generate\t") {
			continue
		}
		cmd := strings.TrimSpace(strings.TrimPrefix(line, "//go:generate"))
		if cmd == "" {
			continue
		}
		shortCmd := cmd
		if len(shortCmd) > 36 {
			shortCmd = shortCmd[:33] + "…"
		}
		directives = append(directives, GoGenerateDirective{
			File:    filePath,
			Line:    i + 1,
			Command: cmd,
			RunArg:  regexp.QuoteMeta(cmd),
			Label:   fmt.Sprintf("▶ Run go:generate (%s)", shortCmd),
		})
	}

	b, err := json.Marshal(directives)
	return string(b), err
}
