package safety

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golens/core/lsp"
)

func AuditGoWorkFile(goWorkPath string, content string) ([]Finding, error) {
	trimmedPath := strings.TrimSpace(goWorkPath)
	if content == "" && trimmedPath != "" {
		raw, err := os.ReadFile(trimmedPath)
		if err != nil {
			return nil, err
		}
		content = string(raw)
	}

	relFile := "go.work"
	workDir := ""
	if trimmedPath != "" {
		relFile = filepath.Base(trimmedPath)
		workDir = filepath.Dir(trimmedPath)
	}

	report := lsp.ParseGoWorkContentWithDir(content, workDir)
	findings := make([]Finding, 0, len(report.Diagnostics))
	for _, d := range report.Diagnostics {
		prefix := "DEP_GOWORK"
		if strings.HasPrefix(d.Code, "local-replace") {
			prefix = "DEP_REPLACE"
		}
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("%s:%s:%d:%s", prefix, relFile, d.Line, d.Code),
			Kind:     "hazard",
			Severity: d.Severity,
			Title:    d.Message,
			Detail:   d.Message,
			File:     trimmedPath,
			RelFile:  relFile,
			Line:     max(1, d.Line),
			Col:      1,
			Symbol:   d.Code,
		})
	}
	return findings, nil
}
