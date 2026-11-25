package analysis

import (
	"encoding/json"
	"fmt"
	"go/build/constraint"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

const (
	goBuildDirectivePrefix = "//go:build "
)

type BuildTagSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type BuildTagSafetyIssue struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	FuncName           string `json:"funcName"`
	Expr               string `json:"expr"`
	Message            string `json:"message"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	ReplacementPreview string `json:"replacementPreview"`
	CanAutoFix         bool   `json:"canAutoFix"`
}

type BuildTagSafetyInspectResult struct {
	Issues                       []BuildTagSafetyIssue `json:"issues"`
	LegacyPlusBuildCount         int                   `json:"legacyPlusBuildCount"`
	MisplacedBuildDirectiveCount int                   `json:"misplacedBuildDirectiveCount"`
	ConflictingFilenameCount     int                   `json:"conflictingFilenameCount"`
	Error                        string                `json:"error,omitempty"`
}

type BuildTagSafetyFixRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	IssueID  string `json:"issueId"`
	All      bool   `json:"all"`
}

type BuildTagSafetyFixResult struct {
	NewContent string `json:"newContent"`
	FixedCount int    `json:"fixedCount"`
	Error      string `json:"error,omitempty"`
}

var knownGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "js": true,
	"linux": true, "netbsd": true, "openbsd": true, "plan9": true,
	"solaris": true, "wasip1": true, "windows": true, "zos": true,
}

var knownGOARCH = map[string]bool{
	"386": true, "amd64": true, "arm": true, "arm64": true,
	"loong64": true, "mips": true, "mips64": true, "mips64le": true,
	"mipsle": true, "ppc64": true, "ppc64le": true, "riscv64": true,
	"s390x": true, "wasm": true,
}

func InspectBuildTagSafety(reqJSON string) string {
	var req BuildTagSafetyInspectRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalBuildTagInspectResult(BuildTagSafetyInspectResult{
				Issues: []BuildTagSafetyIssue{},
				Error:  err.Error(),
			})
		}
		if strings.TrimSpace(req.FilePath) == "" {
			var alt struct {
				Path string `json:"path"`
			}
			if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.Path) != "" {
				req.FilePath = alt.Path
			}
		}
	}

	res, err := InspectGoBuildTagSafety(req.Content, req.FilePath)
	if err != nil && res.Error == "" {
		res.Error = err.Error()
	}
	return marshalBuildTagInspectResult(res)
}

func ApplyBuildTagSafetyFixes(reqJSON string) string {
	var req BuildTagSafetyFixRequest
	if strings.TrimSpace(reqJSON) != "" {
		if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
			return marshalBuildTagFixResult(BuildTagSafetyFixResult{
				Error: err.Error(),
			})
		}
		var alt struct {
			Path    string `json:"path"`
			IssueID string `json:"issueID"`
		}
		if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil {
			if strings.TrimSpace(req.FilePath) == "" && strings.TrimSpace(alt.Path) != "" {
				req.FilePath = alt.Path
			}
			if strings.TrimSpace(req.IssueID) == "" && strings.TrimSpace(alt.IssueID) != "" {
				req.IssueID = alt.IssueID
			}
		}
	}

	res, err := ApplyGoBuildTagSafetyFixes(req.Content, req.FilePath, req.IssueID, req.All)
	if err != nil && res.Error == "" {
		res.Error = err.Error()
	}
	return marshalBuildTagFixResult(res)
}

func InspectGoBuildTagSafety(content string, filePath string) (BuildTagSafetyInspectResult, error) {
	res := BuildTagSafetyInspectResult{
		Issues: []BuildTagSafetyIssue{},
	}

	src, parsePath, err := resolveBuildTagSource(content, filePath)
	if err != nil {
		res.Error = err.Error()
		return res, err
	}
	if strings.TrimSpace(src) == "" {
		return res, nil
	}

	issues, _ := analyzeAndRewriteBuildTags(src, parsePath, "", false)
	for _, iss := range issues {
		res.Issues = append(res.Issues, iss)
		switch iss.Category {
		case "legacy_plus_build_directive":
			res.LegacyPlusBuildCount++
		case "misplaced_build_directive_after_package":
			res.MisplacedBuildDirectiveCount++
		case "conflicting_filename_os_arch_suffix":
			res.ConflictingFilenameCount++
		}
	}
	return res, nil
}

func ApplyGoBuildTagSafetyFixes(content string, filePath string, issueID string, applyAll bool) (BuildTagSafetyFixResult, error) {
	src, parsePath, err := resolveBuildTagSource(content, filePath)
	if err != nil {
		return BuildTagSafetyFixResult{
			NewContent: content,
			Error:      err.Error(),
		}, err
	}
	if strings.TrimSpace(src) == "" {
		return BuildTagSafetyFixResult{
			NewContent: src,
			FixedCount: 0,
		}, nil
	}

	targetID := strings.TrimSpace(issueID)
	if !applyAll && targetID == "" {
		applyAll = true
	}

	issues, fixedSrc := analyzeAndRewriteBuildTags(src, parsePath, targetID, applyAll)
	fixedCount := 0
	if applyAll {
		fixedCount = len(issues)
	} else {
		for _, iss := range issues {
			if iss.ID == targetID {
				fixedCount = 1
				break
			}
		}
		if fixedCount == 0 && targetID != "" {
			notFoundErr := fmt.Errorf("build tag issue %q not found", targetID)
			return BuildTagSafetyFixResult{
				NewContent: src,
				FixedCount: 0,
				Error:      notFoundErr.Error(),
			}, notFoundErr
		}
	}

	if formatted, fmtErr := format.Source([]byte(fixedSrc)); fmtErr == nil {
		fixedSrc = string(formatted)
	}

	return BuildTagSafetyFixResult{
		NewContent: fixedSrc,
		FixedCount: fixedCount,
	}, nil
}

func resolveBuildTagSource(content string, filePath string) (string, string, error) {
	parsePath := strings.TrimSpace(filePath)
	if parsePath == "" {
		parsePath = "buildtag.go"
	}
	if content != "" {
		return content, parsePath, nil
	}
	if strings.TrimSpace(filePath) != "" {
		raw, err := os.ReadFile(filePath)
		if err != nil {
			return "", parsePath, err
		}
		return string(raw), parsePath, nil
	}
	return "", parsePath, nil
}

func analyzeAndRewriteBuildTags(src string, filePath string, targetID string, applyAll bool) ([]BuildTagSafetyIssue, string) {
	lines := strings.Split(src, "\n")
	fset := token.NewFileSet()
	astFile, _ := parser.ParseFile(fset, filePath, src, parser.PackageClauseOnly|parser.ParseComments)

	pkgLine := 1
	pkgName := "main"
	if astFile != nil && astFile.Name != nil {
		pkgLine = fset.Position(astFile.Package).Line
		pkgName = astFile.Name.Name
	} else {
		for i, line := range lines {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "package ") {
				pkgLine = i + 1
				fields := strings.Fields(trimmed)
				if len(fields) >= 2 {
					pkgName = fields[1]
				}
				break
			}
		}
	}

	fileOS, fileArch := extractFilenameOSArch(filePath)

	hasGoBuildTop := false
	for i := 0; i < len(lines) && i < pkgLine; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, goBuildDirectivePrefix) {
			hasGoBuildTop = true
		}
	}

	var issues []BuildTagSafetyIssue
	var hoistedDirectives []string
	removeLineIdx := make(map[int]bool)
	replaceLineIdx := make(map[int]string)
	insertBlankAfterIdx := make(map[int]bool)

	for idx, rawLine := range lines {
		lineNum := idx + 1
		trimmed := strings.TrimSpace(rawLine)

		if strings.HasPrefix(trimmed, "// +build ") || strings.HasPrefix(trimmed, "//+build ") {
			rawExpr := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(trimmed, "// +build"), "//+build"))
			goBuildExpr := convertPlusBuildToGoBuild(rawExpr)
			replacement := goBuildDirectivePrefix + goBuildExpr
			if !hasGoBuildTop {
				id := fmt.Sprintf("legacy_plus_build_directive:%d:1", lineNum)
				issues = append(issues, BuildTagSafetyIssue{
					ID:                 id,
					Category:           "legacy_plus_build_directive",
					Severity:           "warning",
					Line:               lineNum,
					Column:             1,
					FuncName:           pkgName,
					Expr:               trimmed,
					Message:            fmt.Sprintf("Legacy '%s' directive without a modern '//go:build' expression is deprecated since Go 1.17", trimmed),
					Suggestion:         fmt.Sprintf("Replace legacy '+build' directive with '%s'", replacement),
					FixTitle:           "Upgrade to //go:build Directive",
					ReplacementPreview: replacement,
					CanAutoFix:         true,
				})
				if applyAll || targetID == id {
					if lineNum < pkgLine {
						replaceLineIdx[idx] = replacement
						if idx+1 == pkgLine-1 {
							insertBlankAfterIdx[idx] = true
						}
					} else {
						removeLineIdx[idx] = true
						hoistedDirectives = append(hoistedDirectives, replacement)
					}
				}
			}
			continue
		}

		if strings.HasPrefix(trimmed, goBuildDirectivePrefix) {
			expr := strings.TrimSpace(strings.TrimPrefix(trimmed, "//go:build"))

			isAfterPkg := lineNum > pkgLine
			isAttachedToPkg := lineNum < pkgLine && !hasBlankLineBetween(lines, idx, pkgLine-1)
			if isAfterPkg || isAttachedToPkg {
				id := fmt.Sprintf("misplaced_build_directive_after_package:%d:1", lineNum)
				var msg string
				if isAfterPkg {
					msg = fmt.Sprintf("Build directive '%s' appears after 'package %s' and is ignored by the Go toolchain", trimmed, pkgName)
				} else {
					msg = fmt.Sprintf("Build directive '%s' has no blank line separating it from 'package %s', so Go treats it as a package doc comment instead of a build constraint", trimmed, pkgName)
				}
				preview := fmt.Sprintf("%s\n\npackage %s", trimmed, pkgName)
				issues = append(issues, BuildTagSafetyIssue{
					ID:                 id,
					Category:           "misplaced_build_directive_after_package",
					Severity:           "error",
					Line:               lineNum,
					Column:             1,
					FuncName:           pkgName,
					Expr:               trimmed,
					Message:            msg,
					Suggestion:         "Place '//go:build' at the top of the file followed by at least one blank line before 'package'",
					FixTitle:           "Move //go:build Above package With Blank Line",
					ReplacementPreview: preview,
					CanAutoFix:         true,
				})
				if applyAll || targetID == id {
					if isAfterPkg {
						removeLineIdx[idx] = true
						hoistedDirectives = append(hoistedDirectives, trimmed)
					} else {
						insertBlankAfterIdx[idx] = true
					}
				}
			}

			if conflictMsg, fixedDirective, conflicts := checkFilenameConstraintConflict(expr, fileOS, fileArch, filepath.Base(filePath)); conflicts {
				id := fmt.Sprintf("conflicting_filename_os_arch_suffix:%d:1", lineNum)
				issues = append(issues, BuildTagSafetyIssue{
					ID:                 id,
					Category:           "conflicting_filename_os_arch_suffix",
					Severity:           "error",
					Line:               lineNum,
					Column:             1,
					FuncName:           pkgName,
					Expr:               trimmed,
					Message:            conflictMsg,
					Suggestion:         fmt.Sprintf("Align the build tag with the file's implicit OS/Arch suffix using '%s'", fixedDirective),
					FixTitle:           "Align //go:build With Filename OS/Arch Suffix",
					ReplacementPreview: fixedDirective,
					CanAutoFix:         true,
				})
				if applyAll || targetID == id {
					replaceLineIdx[idx] = fixedDirective
				}
			}
		}
	}

	var outLines []string
	if len(hoistedDirectives) > 0 {
		for _, d := range hoistedDirectives {
			outLines = append(outLines, d)
		}
		outLines = append(outLines, "")
	}

	for idx, line := range lines {
		if removeLineIdx[idx] {
			continue
		}
		if rep, ok := replaceLineIdx[idx]; ok {
			outLines = append(outLines, rep)
		} else {
			outLines = append(outLines, line)
		}
		if insertBlankAfterIdx[idx] {
			outLines = append(outLines, "")
		}
	}

	return issues, strings.Join(outLines, "\n")
}

func hasBlankLineBetween(lines []string, startIdx int, pkgIdx int) bool {
	for i := startIdx + 1; i < pkgIdx && i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "" {
			return true
		}
	}
	return false
}

func convertPlusBuildToGoBuild(expr string) string {
	orGroups := strings.Fields(expr)
	if len(orGroups) == 0 {
		return "unix"
	}
	var convertedGroups []string
	for _, grp := range orGroups {
		andTerms := strings.Split(grp, ",")
		var cleanTerms []string
		for _, t := range andTerms {
			t = strings.TrimSpace(t)
			if t != "" {
				cleanTerms = append(cleanTerms, t)
			}
		}
		if len(cleanTerms) == 1 {
			convertedGroups = append(convertedGroups, cleanTerms[0])
		} else if len(cleanTerms) > 1 {
			convertedGroups = append(convertedGroups, "("+strings.Join(cleanTerms, " && ")+")")
		}
	}
	return strings.Join(convertedGroups, " || ")
}

func extractFilenameOSArch(filePath string) (string, string) {
	base := filepath.Base(strings.TrimSpace(filePath))
	if !strings.HasSuffix(base, ".go") {
		return "", ""
	}
	stem := strings.TrimSuffix(base, ".go")
	stem = strings.TrimSuffix(stem, "_test")
	parts := strings.Split(stem, "_")
	if len(parts) < 2 {
		return "", ""
	}
	last := parts[len(parts)-1]
	if len(parts) >= 3 {
		prev := parts[len(parts)-2]
		if knownGOOS[prev] && knownGOARCH[last] {
			return prev, last
		}
	}
	if knownGOOS[last] {
		return last, ""
	}
	if knownGOARCH[last] {
		return "", last
	}
	return "", ""
}

var unixGOOS = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "illumos": true, "ios": true, "linux": true,
	"netbsd": true, "openbsd": true, "solaris": true,
}

func checkFilenameConstraintConflict(expr string, fileOS string, fileArch string, baseName string) (string, string, bool) {
	if fileOS == "" && fileArch == "" {
		return "", "", false
	}

	parsed, err := constraint.Parse(goBuildDirectivePrefix + strings.TrimSpace(expr))
	if err != nil {
		return "", "", false
	}

	if !hasConflictingPlatformLiteral(parsed, fileOS, fileArch) {
		return "", "", false
	}

	var desiredTerms []string
	if fileOS != "" {
		desiredTerms = append(desiredTerms, fileOS)
	}
	if fileArch != "" {
		desiredTerms = append(desiredTerms, fileArch)
	}
	platformPrefix := strings.Join(desiredTerms, " && ")
	implicitLabel := strings.Join(desiredTerms, "/")

	simplified, state := simplifyConstraintForPlatform(parsed, fileOS, fileArch)
	if state == platformEvalDynamic && simplified != nil {
		combined := combinePlatformWithResidual(desiredTerms, simplified)
		fixedDirective := goBuildDirectivePrefix + combined.String()
		msg := fmt.Sprintf(
			"Build constraint '//go:build %s' contains platform term(s) conflicting with filename suffix on '%s' (implicit %s); effective constraint is '%s'",
			expr, baseName, implicitLabel, fixedDirective,
		)
		return msg, fixedDirective, true
	}

	if state == platformEvalTrue {
		fixedDirective := goBuildDirectivePrefix + platformPrefix
		msg := fmt.Sprintf(
			"Build constraint '//go:build %s' contains redundant/conflicting platform branch on '%s' (implicit %s); simplify to '%s'",
			expr, baseName, implicitLabel, fixedDirective,
		)
		return msg, fixedDirective, true
	}

	rewritten := rewriteConflictingConstraintExpr(parsed, fileOS, fileArch)
	fixedDirective := goBuildDirectivePrefix + platformPrefix
	if rewritten != nil && isBuildConstraintSatisfiable(rewritten, fileOS, fileArch) {
		fixedDirective = goBuildDirectivePrefix + rewritten.String()
	}

	msg := fmt.Sprintf(
		"Build constraint '//go:build %s' conflicts with filename suffix on '%s' (implicit %s), making this file unreachable on all targets",
		expr, baseName, implicitLabel,
	)
	return msg, fixedDirective, true
}

type platformEvalState int

const (
	platformEvalFalse platformEvalState = iota
	platformEvalTrue
	platformEvalDynamic
)

func hasConflictingPlatformLiteral(expr constraint.Expr, fileOS string, fileArch string) bool {
	if expr == nil {
		return false
	}
	switch node := expr.(type) {
	case *constraint.TagExpr:
		if fileOS != "" {
			if (knownGOOS[node.Tag] && node.Tag != fileOS) || (node.Tag == "unix" && !unixGOOS[fileOS]) {
				return true
			}
		}
		if fileArch != "" && knownGOARCH[node.Tag] && node.Tag != fileArch {
			return true
		}
		return false
	case *constraint.NotExpr:
		if inner, ok := node.X.(*constraint.TagExpr); ok {
			if fileOS != "" && (inner.Tag == fileOS || (inner.Tag == "unix" && unixGOOS[fileOS])) {
				return true
			}
			if fileArch != "" && inner.Tag == fileArch {
				return true
			}
			return false
		}
		return hasConflictingPlatformLiteral(node.X, fileOS, fileArch)
	case *constraint.AndExpr:
		return hasConflictingPlatformLiteral(node.X, fileOS, fileArch) || hasConflictingPlatformLiteral(node.Y, fileOS, fileArch)
	case *constraint.OrExpr:
		return hasConflictingPlatformLiteral(node.X, fileOS, fileArch) || hasConflictingPlatformLiteral(node.Y, fileOS, fileArch)
	default:
		return false
	}
}

func simplifyConstraintForPlatform(expr constraint.Expr, fileOS string, fileArch string) (constraint.Expr, platformEvalState) {
	switch node := expr.(type) {
	case *constraint.TagExpr:
		if fileOS != "" {
			if node.Tag == fileOS || (node.Tag == "unix" && unixGOOS[fileOS]) {
				return nil, platformEvalTrue
			}
			if knownGOOS[node.Tag] || node.Tag == "unix" {
				return nil, platformEvalFalse
			}
		}
		if fileArch != "" {
			if node.Tag == fileArch {
				return nil, platformEvalTrue
			}
			if knownGOARCH[node.Tag] {
				return nil, platformEvalFalse
			}
		}
		return node, platformEvalDynamic
	case *constraint.NotExpr:
		sub, st := simplifyConstraintForPlatform(node.X, fileOS, fileArch)
		switch st {
		case platformEvalTrue:
			return nil, platformEvalFalse
		case platformEvalFalse:
			return nil, platformEvalTrue
		default:
			return &constraint.NotExpr{X: sub}, platformEvalDynamic
		}
	case *constraint.AndExpr:
		left, lSt := simplifyConstraintForPlatform(node.X, fileOS, fileArch)
		right, rSt := simplifyConstraintForPlatform(node.Y, fileOS, fileArch)
		if lSt == platformEvalFalse || rSt == platformEvalFalse {
			return nil, platformEvalFalse
		}
		if lSt == platformEvalTrue && rSt == platformEvalTrue {
			return nil, platformEvalTrue
		}
		if lSt == platformEvalTrue {
			return right, platformEvalDynamic
		}
		if rSt == platformEvalTrue {
			return left, platformEvalDynamic
		}
		if left.String() == right.String() {
			return left, platformEvalDynamic
		}
		return &constraint.AndExpr{X: left, Y: right}, platformEvalDynamic
	case *constraint.OrExpr:
		left, lSt := simplifyConstraintForPlatform(node.X, fileOS, fileArch)
		right, rSt := simplifyConstraintForPlatform(node.Y, fileOS, fileArch)
		if lSt == platformEvalTrue || rSt == platformEvalTrue {
			return nil, platformEvalTrue
		}
		if lSt == platformEvalFalse && rSt == platformEvalFalse {
			return nil, platformEvalFalse
		}
		if lSt == platformEvalFalse {
			return right, platformEvalDynamic
		}
		if rSt == platformEvalFalse {
			return left, platformEvalDynamic
		}
		if left.String() == right.String() {
			return left, platformEvalDynamic
		}
		return &constraint.OrExpr{X: left, Y: right}, platformEvalDynamic
	default:
		return expr, platformEvalDynamic
	}
}

func combinePlatformWithResidual(desiredTerms []string, residual constraint.Expr) constraint.Expr {
	var cur constraint.Expr
	for _, t := range desiredTerms {
		tagExpr := &constraint.TagExpr{Tag: t}
		if cur == nil {
			cur = tagExpr
		} else {
			cur = &constraint.AndExpr{X: cur, Y: tagExpr}
		}
	}
	if cur == nil {
		return residual
	}
	if residual == nil {
		return cur
	}
	return &constraint.AndExpr{X: cur, Y: residual}
}

func isBuildConstraintSatisfiable(expr constraint.Expr, fileOS string, fileArch string) bool {
	if expr == nil {
		return true
	}

	var customTags []string
	seenCustom := make(map[string]bool)
	var collectTags func(e constraint.Expr)
	collectTags = func(e constraint.Expr) {
		switch node := e.(type) {
		case *constraint.TagExpr:
			t := node.Tag
			if !knownGOOS[t] && !knownGOARCH[t] && t != "unix" && !seenCustom[t] {
				seenCustom[t] = true
				customTags = append(customTags, t)
			}
		case *constraint.NotExpr:
			collectTags(node.X)
		case *constraint.AndExpr:
			collectTags(node.X)
			collectTags(node.Y)
		case *constraint.OrExpr:
			collectTags(node.X)
			collectTags(node.Y)
		}
	}
	collectTags(expr)
	if len(customTags) > 12 {
		customTags = customTags[:12]
	}

	var candidateOS []string
	if fileOS != "" {
		candidateOS = []string{fileOS}
	} else {
		for k := range knownGOOS {
			candidateOS = append(candidateOS, k)
		}
		candidateOS = append(candidateOS, "_other_os")
	}

	var candidateArch []string
	if fileArch != "" {
		candidateArch = []string{fileArch}
	} else {
		for k := range knownGOARCH {
			candidateArch = append(candidateArch, k)
		}
		candidateArch = append(candidateArch, "_other_arch")
	}

	totalMasks := 1 << len(customTags)
	for _, goos := range candidateOS {
		for _, goarch := range candidateArch {
			for mask := 0; mask < totalMasks; mask++ {
				ok := expr.Eval(func(tag string) bool {
					if knownGOOS[tag] {
						return tag == goos
					}
					if knownGOARCH[tag] {
						return tag == goarch
					}
					if tag == "unix" {
						return unixGOOS[goos]
					}
					for i, ct := range customTags {
						if ct == tag {
							return (mask & (1 << i)) != 0
						}
					}
					return true
				})
				if ok {
					return true
				}
			}
		}
	}
	return false
}

func rewriteConflictingConstraintExpr(expr constraint.Expr, fileOS string, fileArch string) constraint.Expr {
	switch node := expr.(type) {
	case *constraint.TagExpr:
		if fileOS != "" && (knownGOOS[node.Tag] || (node.Tag == "unix" && !unixGOOS[fileOS])) {
			return &constraint.TagExpr{Tag: fileOS}
		}
		if fileArch != "" && knownGOARCH[node.Tag] {
			return &constraint.TagExpr{Tag: fileArch}
		}
		return node
	case *constraint.NotExpr:
		if inner, ok := node.X.(*constraint.TagExpr); ok {
			if fileOS != "" && (inner.Tag == fileOS || (inner.Tag == "unix" && unixGOOS[fileOS])) {
				return &constraint.TagExpr{Tag: fileOS}
			}
			if fileArch != "" && inner.Tag == fileArch {
				return &constraint.TagExpr{Tag: fileArch}
			}
		}
		return &constraint.NotExpr{X: rewriteConflictingConstraintExpr(node.X, fileOS, fileArch)}
	case *constraint.AndExpr:
		left := rewriteConflictingConstraintExpr(node.X, fileOS, fileArch)
		right := rewriteConflictingConstraintExpr(node.Y, fileOS, fileArch)
		if left.String() == right.String() {
			return left
		}
		return &constraint.AndExpr{X: left, Y: right}
	case *constraint.OrExpr:
		left := rewriteConflictingConstraintExpr(node.X, fileOS, fileArch)
		right := rewriteConflictingConstraintExpr(node.Y, fileOS, fileArch)
		if left.String() == right.String() {
			return left
		}
		return &constraint.OrExpr{X: left, Y: right}
	default:
		return expr
	}
}

func marshalBuildTagInspectResult(res BuildTagSafetyInspectResult) string {
	if res.Issues == nil {
		res.Issues = []BuildTagSafetyIssue{}
	}
	raw, err := json.Marshal(res)
	if err != nil {
		return `{"issues":[],"legacyPlusBuildCount":0,"misplacedBuildDirectiveCount":0,"conflictingFilenameCount":0,"error":"failed to marshal build tag safety result"}`
	}
	return string(raw)
}

func marshalBuildTagFixResult(res BuildTagSafetyFixResult) string {
	raw, err := json.Marshal(res)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"failed to marshal build tag safety fix result"}`
	}
	return string(raw)
}
