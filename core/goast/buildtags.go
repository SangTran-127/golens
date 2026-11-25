package goast

import (
	"encoding/json"
	"fmt"
	"go/build/constraint"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode"

	"golens/core/bridge"
)

type BuildTargetStatus struct {
	Excluded bool   `json:"excluded"`
	Reason   string `json:"reason,omitempty"`
	GOOS     string `json:"goos"`
	GOARCH   string `json:"goarch"`
	Tags     string `json:"tags,omitempty"`
}

var knownGOOS = map[string]bool{
	"linux":     true,
	"darwin":    true,
	"windows":   true,
	"freebsd":   true,
	"openbsd":   true,
	"netbsd":    true,
	"js":        true,
	"wasip1":    true,
	"plan9":     true,
	"solaris":   true,
	"aix":       true,
	"android":   true,
	"ios":       true,
	"dragonfly": true,
}

var knownGOARCH = map[string]bool{
	"amd64":    true,
	"arm64":    true,
	"386":      true,
	"arm":      true,
	"wasm":     true,
	"ppc64":    true,
	"ppc64le":  true,
	"riscv64":  true,
	"s390x":    true,
	"mips":     true,
	"mipsle":   true,
	"mips64":   true,
	"mips64le": true,
	"loong64":  true,
}

var unixGOOS = map[string]bool{
	"darwin":    true,
	"linux":     true,
	"freebsd":   true,
	"openbsd":   true,
	"netbsd":    true,
	"solaris":   true,
	"aix":       true,
	"dragonfly": true,
}

func DefaultTargetGOOS() string {
	if bridge.IsHostMode() {
		return runtime.GOOS
	}
	return "linux"
}

func CheckBuildTarget(filePath, content, goos, goarch, tagsCSV string) (string, error) {
	goos = strings.TrimSpace(goos)
	if goos == "" {
		goos = DefaultTargetGOOS()
	}
	goarch = strings.TrimSpace(goarch)
	if goarch == "" {
		goarch = runtime.GOARCH
	}
	userTags := parseBuildTags(tagsCSV)
	normalizedTags := strings.Join(userTags, ",")

	status := BuildTargetStatus{
		Excluded: false,
		GOOS:     goos,
		GOARCH:   goarch,
		Tags:     normalizedTags,
	}

	base := filepath.Base(filePath)
	if !strings.HasSuffix(base, ".go") {
		b, err := json.Marshal(status)
		return string(b), err
	}

	if fileGOOS, fileGOARCH := extractFilenameTarget(base); fileGOOS != "" || fileGOARCH != "" {
		if (fileGOOS != "" && fileGOOS != goos) || (fileGOARCH != "" && fileGOARCH != goarch) {
			status.Excluded = true
			status.Reason = fmt.Sprintf("Excluded by filename suffix (%s) for target %s/%s", base, goos, goarch)
			b, err := json.Marshal(status)
			return string(b), err
		}
	}

	if content == "" && filePath != "" {
		if data, err := os.ReadFile(filePath); err == nil {
			content = string(data)
		}
	}

	activeTags := buildActiveTagSet(goos, goarch, userTags)
	if excluded, rawLine := evaluateHeaderConstraints(content, activeTags); excluded {
		status.Excluded = true
		status.Reason = fmt.Sprintf("Excluded by build constraint (%s) for target %s/%s", rawLine, goos, goarch)
	}

	b, err := json.Marshal(status)
	return string(b), err
}

func parseBuildTags(tagsCSV string) []string {
	fields := strings.FieldsFunc(tagsCSV, func(r rune) bool {
		return r == ',' || unicode.IsSpace(r)
	})
	var out []string
	seen := make(map[string]bool, len(fields))
	for _, f := range fields {
		if f != "" && !seen[f] {
			seen[f] = true
			out = append(out, f)
		}
	}
	return out
}

func buildActiveTagSet(goos, goarch string, userTags []string) map[string]bool {
	active := map[string]bool{
		goos:   true,
		goarch: true,
		"cgo":  true,
	}
	if unixGOOS[goos] {
		active["unix"] = true
	}
	for i := 1; i <= 24; i++ {
		active[fmt.Sprintf("go1.%d", i)] = true
	}
	for _, t := range userTags {
		active[t] = true
	}
	return active
}

func extractFilenameTarget(base string) (fileGOOS, fileGOARCH string) {
	stem := strings.TrimSuffix(base, ".go")
	stem = strings.TrimSuffix(stem, "_test")
	parts := strings.Split(stem, "_")
	if len(parts) < 2 {
		return "", ""
	}
	last := parts[len(parts)-1]
	if knownGOARCH[last] {
		fileGOARCH = last
		if len(parts) >= 2 && knownGOOS[parts[len(parts)-2]] {
			fileGOOS = parts[len(parts)-2]
		}
		return fileGOOS, fileGOARCH
	}
	if knownGOOS[last] {
		return last, ""
	}
	return "", ""
}

func evaluateHeaderConstraints(content string, active map[string]bool) (bool, string) {
	var goBuildLine string
	var plusBuildLines []string
	inBlockComment := false

	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if inBlockComment {
			if idx := strings.Index(line, "*/"); idx >= 0 {
				inBlockComment = false
				line = strings.TrimSpace(line[idx+2:])
				if line == "" {
					continue
				}
			} else {
				continue
			}
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "/*") {
			if !strings.Contains(line, "*/") {
				inBlockComment = true
			}
			continue
		}
		if strings.HasPrefix(line, "//") {
			if constraint.IsGoBuild(line) && goBuildLine == "" {
				goBuildLine = line
			} else if constraint.IsPlusBuild(line) {
				plusBuildLines = append(plusBuildLines, line)
			}
			continue
		}
		break
	}

	if goBuildLine != "" {
		expr, err := constraint.Parse(goBuildLine)
		if err == nil && !expr.Eval(func(tag string) bool { return active[tag] }) {
			return true, goBuildLine
		}
		return false, ""
	}

	for _, pb := range plusBuildLines {
		expr, err := constraint.Parse(pb)
		if err == nil && !expr.Eval(func(tag string) bool { return active[tag] }) {
			return true, pb
		}
	}
	return false, ""
}
