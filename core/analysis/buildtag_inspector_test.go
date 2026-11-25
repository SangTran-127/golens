package analysis

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestInspectBuildTagSafetyDetectsAndFixesAllCategories(t *testing.T) {
	src := `// +build darwin,arm64 linux
//go:build linux
package platform

//go:build cgo

func PlatformName() string {
	return "darwin"
}
`

	reqBytes, _ := json.Marshal(BuildTagSafetyInspectRequest{
		Content:  src,
		FilePath: "platform_darwin.go",
	})
	rawRes := InspectBuildTagSafety(string(reqBytes))

	var res BuildTagSafetyInspectResult
	if err := json.Unmarshal([]byte(rawRes), &res); err != nil {
		t.Fatalf("failed to unmarshal InspectBuildTagSafety result: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if res.MisplacedBuildDirectiveCount != 2 {
		t.Fatalf("expected MisplacedBuildDirectiveCount=2, got %d", res.MisplacedBuildDirectiveCount)
	}
	if res.ConflictingFilenameCount != 1 {
		t.Fatalf("expected ConflictingFilenameCount=1, got %d", res.ConflictingFilenameCount)
	}

	legacyOnlySrc := `// +build darwin,amd64

package platform
`
	legacyRes, err := InspectGoBuildTagSafety(legacyOnlySrc, "platform.go")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if legacyRes.LegacyPlusBuildCount != 1 {
		t.Fatalf("expected LegacyPlusBuildCount=1, got %d", legacyRes.LegacyPlusBuildCount)
	}
	legacyFix, err := ApplyGoBuildTagSafetyFixes(legacyOnlySrc, "platform.go", "", true)
	if err != nil {
		t.Fatalf("unexpected legacy fix error: %v", err)
	}
	if !strings.Contains(legacyFix.NewContent, "//go:build darwin && amd64") {
		t.Fatalf("expected converted //go:build directive, got:\n%s", legacyFix.NewContent)
	}

	fixRes, err := ApplyGoBuildTagSafetyFixes(src, "platform_darwin.go", "", true)
	if err != nil {
		t.Fatalf("unexpected fix error: %v", err)
	}
	if !strings.Contains(fixRes.NewContent, "//go:build darwin") {
		t.Fatalf("expected aligned //go:build darwin, got:\n%s", fixRes.NewContent)
	}

	// OR expression with dead platform branch ('linux') and custom tag ('integration') on _darwin.go:
	// must NOT claim unreachable on all targets, and Fix All must preserve 'integration' ('//go:build darwin && integration')
	orCustomSrc := `//go:build linux || integration

package platform
`
	orRes, err := InspectGoBuildTagSafety(orCustomSrc, "feature_darwin.go")
	if err != nil {
		t.Fatalf("unexpected error on OR build tag: %v", err)
	}
	if len(orRes.Issues) != 1 || orRes.ConflictingFilenameCount != 1 {
		t.Fatalf("expected 1 conflicting platform term issue for '//go:build linux || integration' on feature_darwin.go, got %+v", orRes.Issues)
	}
	if strings.Contains(orRes.Issues[0].Message, "unreachable on all targets") {
		t.Fatalf("must not claim '//go:build linux || integration' is unreachable on all targets: %s", orRes.Issues[0].Message)
	}
	orFix, err := ApplyGoBuildTagSafetyFixes(orCustomSrc, "feature_darwin.go", "", true)
	if err != nil {
		t.Fatalf("unexpected fix error on OR build tag: %v", err)
	}
	if !strings.Contains(orFix.NewContent, "//go:build darwin && integration") {
		t.Fatalf("expected Fix All to preserve custom tag in '//go:build darwin && integration', got:\n%s", orFix.NewContent)
	}
	orReinspect, err := InspectGoBuildTagSafety(orFix.NewContent, "feature_darwin.go")
	if err != nil || len(orReinspect.Issues) != 0 {
		t.Fatalf("expected 0 issues after fixing feature_darwin.go, got %+v", orReinspect.Issues)
	}

	// Unsatisfiable AND expression with custom tag on _darwin.go must preserve custom tag when fixed
	andCustomSrc := `//go:build linux && integration

package platform
`
	andRes, err := InspectGoBuildTagSafety(andCustomSrc, "feature_darwin.go")
	if err != nil || andRes.ConflictingFilenameCount != 1 {
		t.Fatalf("expected 1 conflicting filename issue for '//go:build linux && integration' on feature_darwin.go, got %+v", andRes)
	}
	andFix, err := ApplyGoBuildTagSafetyFixes(andCustomSrc, "feature_darwin.go", "", true)
	if err != nil {
		t.Fatalf("unexpected fix error: %v", err)
	}
	if !strings.Contains(andFix.NewContent, "//go:build darwin && integration") {
		t.Fatalf("expected custom tag 'integration' to be preserved in '//go:build darwin && integration', got:\n%s", andFix.NewContent)
	}
}
