package safety

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type goModAdvisory struct {
	Module       string
	ID           string
	FixedVersion string
	AllVersions  bool
	Summary      string
}

var offlineModuleAdvisories = []goModAdvisory{
	{
		Module:       "golang.org/x/crypto",
		ID:           "CVE-2024-45337 / GO-2024-3321",
		FixedVersion: "v0.31.0",
		Summary:      "SSH ServerConfig.PublicKeyCallback authorization bypass and Terrapin prefix truncation (CVE-2023-48795)",
	},
	{
		Module:       "golang.org/x/net",
		ID:           "CVE-2024-45338 / GO-2023-2102",
		FixedVersion: "v0.33.0",
		Summary:      "HTTP/2 Rapid Reset DoS (CVE-2023-44487) and non-linear HTML parsing denial of service",
	},
	{
		Module:       "golang.org/x/text",
		ID:           "CVE-2022-32149 / GO-2022-1059",
		FixedVersion: "v0.3.8",
		Summary:      "Denial of service via crafted Accept-Language header in golang.org/x/text/language",
	},
	{
		Module:       "gopkg.in/yaml.v2",
		ID:           "CVE-2021-4235 / GO-2022-0411",
		FixedVersion: "v2.4.0",
		Summary:      "Excessive memory consumption via alias bomb in YAML parsing",
	},
	{
		Module:       "gopkg.in/yaml.v3",
		ID:           "CVE-2022-28948 / GO-2022-0603",
		FixedVersion: "v3.0.1",
		Summary:      "Panic during YAML unmarshaling of crafted input",
	},
	{
		Module:       "github.com/dgrijalva/jwt-go",
		ID:           "CVE-2020-26160 / GO-2020-0017",
		FixedVersion: "github.com/golang-jwt/jwt/v5 v5.2.2",
		AllVersions:  true,
		Summary:      "Unmaintained module with JWT audience claim verification bypass",
	},
	{
		Module:       "github.com/golang-jwt/jwt",
		ID:           "CVE-2020-26160 / GO-2025-3553",
		FixedVersion: "v3.2.3",
		Summary:      "JWT audience verification bypass and excessive allocation during token parsing",
	},
	{
		Module:       "github.com/golang-jwt/jwt/v4",
		ID:           "CVE-2025-30204 / GO-2025-3553",
		FixedVersion: "v4.5.2",
		Summary:      "Excessive memory allocation when parsing malformed Authorization bearer headers",
	},
	{
		Module:       "github.com/golang-jwt/jwt/v5",
		ID:           "CVE-2025-30204 / GO-2025-3553",
		FixedVersion: "v5.2.2",
		Summary:      "Excessive memory allocation when parsing malformed Authorization bearer headers",
	},
	{
		Module:       "google.golang.org/protobuf",
		ID:           "CVE-2024-24786 / GO-2024-2611",
		FixedVersion: "v1.33.0",
		Summary:      "Infinite loop in protojson.Unmarshal when unmarshaling malformed JSON messages",
	},
	{
		Module:       "google.golang.org/grpc",
		ID:           "CVE-2023-44487 / GO-2023-2102",
		FixedVersion: "v1.58.3",
		Summary:      "HTTP/2 Rapid Reset stream cancellation denial of service",
	},
	{
		Module:       "github.com/gin-gonic/gin",
		ID:           "CVE-2023-29401 / GO-2023-1839",
		FixedVersion: "v1.9.1",
		Summary:      "Content-Disposition filename header injection in Context.FileAttachment",
	},
	{
		Module:       "github.com/gorilla/websocket",
		ID:           "CVE-2020-27813 / GO-2020-0019",
		FixedVersion: "v1.4.2",
		Summary:      "Integer overflow leading to denial of service during frame length parsing",
	},
	{
		Module:       "golang.org/x/image",
		ID:           "CVE-2024-24792 / GO-2024-2824",
		FixedVersion: "v0.18.0",
		Summary:      "Panic on malformed TIFF and BMP image decoding",
	},
}

var pseudoVersionPinRe = regexp.MustCompile(`^v\d+\.\d+\.\d+-(?:0\.\d{14}|\d{14}|[0-9a-zA-Z.]+-\d{14})-[0-9a-fA-F]{12,}(\+incompatible)?$`)

func AuditGoModFile(goModPath string, content string) ([]Finding, error) {
	trimmedPath := strings.TrimSpace(goModPath)
	if content == "" && trimmedPath != "" {
		raw, err := os.ReadFile(trimmedPath)
		if err != nil {
			return nil, err
		}
		content = string(raw)
	}

	relFile := "go.mod"
	if trimmedPath != "" {
		relFile = filepath.Base(trimmedPath)
	}

	normalized := strings.ReplaceAll(content, "\r\n", "\n")
	lines := strings.Split(normalized, "\n")

	var findings []Finding
	inBlock := ""

	for idx, rawLine := range lines {
		lineNum := idx + 1
		col := firstNonSpaceCol(rawLine)
		stripped := stripLineComment(rawLine)
		fields := strings.Fields(stripped)
		if len(fields) == 0 {
			continue
		}

		if inBlock != "" {
			if fields[0] == ")" {
				inBlock = ""
				continue
			}
			switch inBlock {
			case "require":
				if len(fields) >= 2 {
					findings = append(findings, checkRequireEntry(trimmedPath, relFile, lineNum, col, fields[0], fields[1])...)
				}
			case "replace":
				if f, ok := checkReplaceTokens(trimmedPath, relFile, lineNum, col, fields); ok {
					findings = append(findings, f)
				}
			}
			continue
		}

		directive := fields[0]
		if len(fields) >= 2 && fields[1] == "(" {
			inBlock = directive
			continue
		}
		if strings.HasSuffix(directive, "(") {
			inBlock = strings.TrimSuffix(directive, "(")
			continue
		}

		switch directive {
		case "go":
			if len(fields) >= 2 {
				if f, ok := checkGoToolchainDirective(trimmedPath, relFile, lineNum, col, fields[1]); ok {
					findings = append(findings, f)
				}
			}
		case "require":
			if len(fields) >= 3 {
				findings = append(findings, checkRequireEntry(trimmedPath, relFile, lineNum, col, fields[1], fields[2])...)
			}
		case "replace":
			if len(fields) >= 3 {
				if f, ok := checkReplaceTokens(trimmedPath, relFile, lineNum, col, fields[1:]); ok {
					findings = append(findings, f)
				}
			}
		}
	}

	return findings, nil
}

func auditWorkspaceGoMod(workspaceDir string) []Finding {
	if workspaceDir == "" {
		return nil
	}

	var findings []Finding
	_ = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name(), path == workspaceDir) {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if name != "go.mod" && name != "go.work" {
			return nil
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		absFile, absErr := filepath.Abs(path)
		if absErr != nil {
			absFile = path
		}
		absFile = filepath.Clean(absFile)
		var modFindings []Finding
		var auditErr error
		if name == "go.work" {
			modFindings, auditErr = AuditGoWorkFile(absFile, string(raw))
		} else {
			modFindings, auditErr = AuditGoModFile(absFile, string(raw))
		}
		if auditErr != nil {
			return nil
		}
		rel := relPath(workspaceDir, absFile)
		for i := range modFindings {
			modFindings[i].File = absFile
			modFindings[i].RelFile = rel
		}
		findings = append(findings, modFindings...)
		return nil
	})

	return findings
}

func firstNonSpaceCol(line string) int {
	for i, r := range line {
		if r != ' ' && r != '\t' {
			return i + 1
		}
	}
	return 1
}

func stripLineComment(line string) string {
	if idx := strings.Index(line, "//"); idx >= 0 {
		return strings.TrimSpace(line[:idx])
	}
	return strings.TrimSpace(line)
}

func checkGoToolchainDirective(goModPath, relFile string, lineNum, col int, rawVer string) (Finding, bool) {
	ver := strings.TrimSpace(rawVer)
	major, minor, ok := parseGoDirectiveVersion(ver)
	if !ok {
		return Finding{}, false
	}
	if major > 1 || (major == 1 && minor >= 23) {
		return Finding{}, false
	}

	detail := fmt.Sprintf(
		"Go %s predates Go 1.23+ toolchain and standard library security patches; upgrade directive to 'go 1.23' or newer.",
		ver,
	)
	if major == 1 && minor <= 21 {
		detail = fmt.Sprintf(
			"Go %s predates Go 1.22 per-iteration loop variable semantics and Go 1.23+ toolchain security patches; upgrade directive to 'go 1.23' or newer and verify loop variable capture.",
			ver,
		)
	}

	return Finding{
		ID:       fmt.Sprintf("DEP_TOOLCHAIN:%s:%d", relFile, lineNum),
		Kind:     "hazard",
		Severity: 2,
		Title:    fmt.Sprintf("go.mod targets Go %s, which is out of date", ver),
		Detail:   detail,
		File:     goModPath,
		RelFile:  relFile,
		Line:     lineNum,
		Col:      col,
		Symbol:   "go " + ver,
	}, true
}

func parseGoDirectiveVersion(raw string) (int, int, bool) {
	v := strings.TrimPrefix(strings.TrimSpace(raw), "go")
	parts := strings.Split(v, ".")
	if len(parts) < 2 {
		return 0, 0, false
	}
	major, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, false
	}
	minorStr := parts[1]
	for i, r := range minorStr {
		if r < '0' || r > '9' {
			minorStr = minorStr[:i]
			break
		}
	}
	minor, err := strconv.Atoi(minorStr)
	if err != nil {
		return 0, 0, false
	}
	return major, minor, true
}

func checkReplaceTokens(goModPath, relFile string, lineNum, col int, tokens []string) (Finding, bool) {
	arrowIdx := -1
	for i, tok := range tokens {
		if tok == "=>" {
			arrowIdx = i
			break
		}
	}
	if arrowIdx <= 0 || arrowIdx+1 >= len(tokens) {
		return Finding{}, false
	}

	oldMod := strings.Trim(tokens[0], "\"`")
	rightTokens := tokens[arrowIdx+1:]
	targetPath := strings.Trim(rightTokens[0], "\"`")
	targetSummary := strings.Join(rightTokens, " ")

	isLocalPath := len(rightTokens) == 1 ||
		strings.HasPrefix(targetPath, "./") ||
		strings.HasPrefix(targetPath, "../") ||
		strings.HasPrefix(targetPath, "/") ||
		targetPath == "." ||
		targetPath == ".." ||
		!strings.Contains(targetPath, ".")

	severity := 2
	detail := fmt.Sprintf(
		"Module replacement '%s => %s' overrides canonical module resolution; verify fork provenance and go.sum hashes.",
		oldMod,
		targetSummary,
	)
	if isLocalPath {
		detail = fmt.Sprintf(
			"Local filesystem replacement '%s => %s' bypasses go.sum checksum verification and compromises hermetic builds.",
			oldMod,
			targetSummary,
		)
		if goModPath != "" {
			resolved := filepath.FromSlash(targetPath)
			if !filepath.IsAbs(resolved) {
				resolved = filepath.Join(filepath.Dir(goModPath), resolved)
			}
			resolved = filepath.Clean(resolved)
			if info, statErr := os.Stat(resolved); statErr != nil || !info.IsDir() {
				severity = 1
				detail += " Target directory does not exist on disk."
			} else if _, modErr := os.Stat(filepath.Join(resolved, "go.mod")); modErr != nil {
				detail += " Target directory has no go.mod file."
			}
		}
	}

	return Finding{
		ID:       fmt.Sprintf("DEP_REPLACE:%s:%d:%s", relFile, lineNum, oldMod),
		Kind:     "hazard",
		Severity: severity,
		Title:    fmt.Sprintf("Replace directive %s => %s is not verified", oldMod, targetSummary),
		Detail:   detail,
		File:     goModPath,
		RelFile:  relFile,
		Line:     lineNum,
		Col:      col,
		Symbol:   oldMod,
	}, true
}

func checkRequireEntry(goModPath, relFile string, lineNum, col int, rawMod, rawVer string) []Finding {
	modPath := strings.Trim(rawMod, "\"`")
	modVer := strings.Trim(rawVer, "\"`")
	if modPath == "" || modVer == "" {
		return nil
	}

	var findings []Finding
	if adv, ok := matchModuleAdvisory(modPath, modVer); ok {
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("DEP_VULN:%s:%s:%d", adv.ID, relFile, lineNum),
			Kind:     "vuln",
			Severity: 1,
			Title:    fmt.Sprintf("%s %s has a known vulnerability (%s)", modPath, modVer, adv.ID),
			Detail:   fmt.Sprintf("%s. Upgrade %s from %s to %s or newer.", adv.Summary, modPath, modVer, adv.FixedVersion),
			File:     goModPath,
			RelFile:  relFile,
			Line:     lineNum,
			Col:      col,
			Symbol:   modPath,
		})
	}

	if isPseudoVersionPin(modVer) {
		findings = append(findings, Finding{
			ID:       fmt.Sprintf("DEP_PIN:%s:%d:%s", relFile, lineNum, modPath),
			Kind:     "hazard",
			Severity: 2,
			Title:    fmt.Sprintf("%s %s uses an unpinned pseudo-version", modPath, modVer),
			Detail:   fmt.Sprintf("Module %q is pinned to untagged commit pseudo-version %s; prefer a tagged semantic release for supply-chain verification.", modPath, modVer),
			File:     goModPath,
			RelFile:  relFile,
			Line:     lineNum,
			Col:      col,
			Symbol:   modPath,
		})
	}

	return findings
}

func matchModuleAdvisory(modPath, modVer string) (goModAdvisory, bool) {
	for _, adv := range offlineModuleAdvisories {
		if adv.Module != modPath {
			continue
		}
		if adv.AllVersions {
			return adv, true
		}
		if compareSemver(modVer, adv.FixedVersion) < 0 {
			return adv, true
		}
	}
	return goModAdvisory{}, false
}

func isPseudoVersionPin(ver string) bool {
	trimmed := strings.TrimSpace(ver)
	if strings.HasPrefix(trimmed, "v0.0.0-") {
		return true
	}
	return pseudoVersionPinRe.MatchString(trimmed)
}

func compareSemver(v1, v2 string) int {
	maj1, min1, pat1, pre1, ok1 := parseSemverParts(v1)
	maj2, min2, pat2, pre2, ok2 := parseSemverParts(v2)
	if !ok1 || !ok2 {
		return 0
	}
	if maj1 != maj2 {
		if maj1 < maj2 {
			return -1
		}
		return 1
	}
	if min1 != min2 {
		if min1 < min2 {
			return -1
		}
		return 1
	}
	if pat1 != pat2 {
		if pat1 < pat2 {
			return -1
		}
		return 1
	}
	if pre1 != "" && pre2 == "" {
		return -1
	}
	if pre1 == "" && pre2 != "" {
		return 1
	}
	return strings.Compare(pre1, pre2)
}

func parseSemverParts(raw string) (int, int, int, string, bool) {
	v := strings.TrimSpace(raw)
	v = strings.TrimPrefix(v, "v")
	v = strings.TrimSuffix(v, "+incompatible")
	if idx := strings.IndexByte(v, '+'); idx >= 0 {
		v = v[:idx]
	}

	pre := ""
	if idx := strings.IndexByte(v, '-'); idx >= 0 {
		pre = v[idx+1:]
		v = v[:idx]
	}

	parts := strings.Split(v, ".")
	if len(parts) < 2 {
		return 0, 0, 0, "", false
	}
	major, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, 0, "", false
	}
	minor, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, 0, 0, "", false
	}
	patch := 0
	if len(parts) >= 3 {
		p, err := strconv.Atoi(parts[2])
		if err != nil {
			return 0, 0, 0, "", false
		}
		patch = p
	}
	return major, minor, patch, pre, true
}
