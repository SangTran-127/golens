package analysis

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

func TestInspectGoNumericSafety_NarrowIntConversion(t *testing.T) {
	src := `package numeric

import (
	"math"
	"strconv"
)

func ParsePortAndID(rawPort string, rawID string, bigCount int64, safeSmall int16) (uint16, int32, int8, int32) {
	port, _ := strconv.Atoi(rawPort)
	id64, _ := strconv.ParseInt(rawID, 10, 64)

	if bigCount >= math.MinInt8 && bigCount <= math.MaxInt8 {
		_ = int8(bigCount)
	}

	alreadyClamped := int32(min(max(port, math.MinInt32), math.MaxInt32))
	_ = alreadyClamped

	return uint16(port), int32(id64), int8(safeSmall), int32(42)
}
`

	res, err := InspectGoNumericSafety(src, "numeric.go")
	if err != nil {
		t.Fatalf("InspectGoNumericSafety returned unexpected error: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("expected empty error field, got %q", res.Error)
	}
	if res.NarrowConversionCount != 3 || len(res.Issues) != 3 {
		t.Fatalf("expected 3 narrow_int_conversion issues, got count=%d issues=%+v", res.NarrowConversionCount, res.Issues)
	}

	if res.Issues[0].Category != "narrow_int_conversion" || res.Issues[0].Severity != "warning" {
		t.Fatalf("unexpected issue[0]: %+v", res.Issues[0])
	}
	if res.Issues[0].ReplacementPreview != "uint16(min(max(port, 0), math.MaxUint16))" {
		t.Fatalf("unexpected replacementPreview for uint16(port): %q", res.Issues[0].ReplacementPreview)
	}

	if res.Issues[1].ReplacementPreview != "int32(min(max(id64, math.MinInt32), math.MaxInt32))" {
		t.Fatalf("unexpected replacementPreview for int32(id64): %q", res.Issues[1].ReplacementPreview)
	}

	if res.Issues[2].ReplacementPreview != "int8(min(max(safeSmall, math.MinInt8), math.MaxInt8))" {
		t.Fatalf("unexpected replacementPreview for int8(safeSmall): %q", res.Issues[2].ReplacementPreview)
	}
}

func TestInspectGoNumericSafety_FloatExactEquality(t *testing.T) {
	src := `package billing

func CompareTotals(a, b float64, f32 float32) bool {
	if a == b {
		return true
	}
	if a != 0.1 {
		return false
	}
	if f32 == 0.25 {
		return true
	}
	return false
}
`

	res, err := InspectGoNumericSafety(src, "billing.go")
	if err != nil {
		t.Fatalf("InspectGoNumericSafety failed: %v", err)
	}
	if res.FloatEqualityCount != 3 || len(res.Issues) != 3 {
		t.Fatalf("expected 3 float_exact_equality issues, got count=%d issues=%+v", res.FloatEqualityCount, res.Issues)
	}

	if res.Issues[0].Category != "float_exact_equality" || res.Issues[0].Severity != "warning" {
		t.Fatalf("unexpected issue[0]: %+v", res.Issues[0])
	}
	if res.Issues[0].ReplacementPreview != "math.Abs(a-b) < 1e-9" {
		t.Fatalf("expected math.Abs(a-b) < 1e-9, got %q", res.Issues[0].ReplacementPreview)
	}

	if res.Issues[1].ReplacementPreview != "math.Abs(a-0.1) >= 1e-9" {
		t.Fatalf("expected math.Abs(a-0.1) >= 1e-9, got %q", res.Issues[1].ReplacementPreview)
	}

	if res.Issues[2].ReplacementPreview != "math.Abs(float64(f32)-float64(0.25)) < 1e-9" {
		t.Fatalf("expected float32 conversion epsilon preview, got %q", res.Issues[2].ReplacementPreview)
	}
}

func TestInspectGoNumericSafety_UnguardedDivision(t *testing.T) {
	src := `package stats

const defaultBucketCount = 16

func ComputeMetrics(total int, count int, bucket int, guarded int) int {
	if guarded == 0 {
		return 0
	}
	safePart := total / guarded
	constPart := total / defaultBucketCount
	avg := total / count
	rem := total % bucket
	return safePart + constPart + avg + rem
}
`

	res, err := InspectGoNumericSafety(src, "stats.go")
	if err != nil {
		t.Fatalf("InspectGoNumericSafety failed: %v", err)
	}
	if res.UnguardedDivCount != 2 || len(res.Issues) != 2 {
		t.Fatalf("expected 2 unguarded_division issues, got count=%d issues=%+v", res.UnguardedDivCount, res.Issues)
	}

	if res.Issues[0].Category != "unguarded_division" || res.Issues[0].Severity != "error" {
		t.Fatalf("unexpected issue[0]: %+v", res.Issues[0])
	}
	if res.Issues[0].ReplacementPreview != "total / max(count, 1)" {
		t.Fatalf("expected 'total / max(count, 1)', got %q", res.Issues[0].ReplacementPreview)
	}

	if res.Issues[1].ReplacementPreview != "total % max(bucket, 1)" {
		t.Fatalf("expected 'total %% max(bucket, 1)', got %q", res.Issues[1].ReplacementPreview)
	}
}

func TestInspectGoNumericSafety_ApplyFixesSingleAndAll(t *testing.T) {
	src := `package metrics

import "strconv"

func Evaluate(raw string, total int, divisor int, target float64) (int32, int, bool) {
	parsed, _ := strconv.Atoi(raw)
	narrow := int32(parsed)
	ratio := total / divisor
	matched := target == 0.3
	return narrow, ratio, matched
}
`

	initial, err := InspectGoNumericSafety(src, "metrics.go")
	if err != nil {
		t.Fatalf("InspectGoNumericSafety failed: %v", err)
	}
	if len(initial.Issues) != 3 {
		t.Fatalf("expected 3 initial issues, got %d: %+v", len(initial.Issues), initial.Issues)
	}

	// 1. Test single issue fix (unguarded_division)
	var divIssueID string
	for _, iss := range initial.Issues {
		if iss.Category == "unguarded_division" {
			divIssueID = iss.ID
			break
		}
	}
	if divIssueID == "" {
		t.Fatalf("expected to find unguarded_division issue ID")
	}

	singleFix, err := ApplyGoNumericSafetyFixes(src, "metrics.go", divIssueID, false)
	if err != nil {
		t.Fatalf("ApplyGoNumericSafetyFixes(single) failed: %v", err)
	}
	if singleFix.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1 for single fix, got %d", singleFix.FixedCount)
	}
	if !strings.Contains(singleFix.NewContent, "total / max(divisor, 1)") {
		t.Fatalf("expected single fix to rewrite division, got:\n%s", singleFix.NewContent)
	}

	fset := token.NewFileSet()
	if _, parseErr := parser.ParseFile(fset, "metrics.go", singleFix.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("singleFix.NewContent failed to parse with go/parser: %v\n%s", parseErr, singleFix.NewContent)
	}

	// 2. Test applyAll=true on original source
	allFix, err := ApplyGoNumericSafetyFixes(src, "metrics.go", "", true)
	if err != nil {
		t.Fatalf("ApplyGoNumericSafetyFixes(applyAll=true) failed: %v", err)
	}
	if allFix.FixedCount != 3 {
		t.Fatalf("expected FixedCount=3 for applyAll=true, got %d", allFix.FixedCount)
	}
	if !strings.Contains(allFix.NewContent, `"math"`) {
		t.Fatalf("expected math import to be added automatically, got:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "int32(min(max(parsed, math.MinInt32), math.MaxInt32))") {
		t.Fatalf("expected clamped int32 conversion in fixed output, got:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "total / max(divisor, 1)") {
		t.Fatalf("expected guarded division in fixed output, got:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "math.Abs(target-0.3) < 1e-9") {
		t.Fatalf("expected math.Abs epsilon comparison in fixed output, got:\n%s", allFix.NewContent)
	}

	if _, parseErr := parser.ParseFile(fset, "metrics.go", allFix.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("allFix.NewContent failed to parse with go/parser: %v\n%s", parseErr, allFix.NewContent)
	}

	afterInspect, err := InspectGoNumericSafety(allFix.NewContent, "metrics.go")
	if err != nil {
		t.Fatalf("re-inspect after applyAll failed: %v", err)
	}
	if len(afterInspect.Issues) != 0 {
		t.Fatalf("expected 0 remaining issues after applyAll, got %+v", afterInspect.Issues)
	}
}

func TestInspectGoNumericSafety_JSONWrappersAndCompoundCases(t *testing.T) {
	src := `package calc

import "strconv"

func Process(rawFloat string, items []string, step int) (uint8, uint32, bool, int) {
	f, _ := strconv.ParseFloat(rawFloat, 64)
	n := len(items)
	b8 := uint8(n)
	u32 := uint32(n)
	eq := (f + 0.1) == 0.3
	q := n / step
	return b8, u32, eq, q
}
`

	reqJSON := `{"filePath":"calc.go","content":` + strconvQuoteForTest(src) + `}`
	rawInspect := InspectNumericSafety(reqJSON)
	if !strings.Contains(rawInspect, `"narrowConversionCount":2`) ||
		!strings.Contains(rawInspect, `"floatEqualityCount":1`) ||
		!strings.Contains(rawInspect, `"unguardedDivCount":1`) {
		t.Fatalf("unexpected InspectNumericSafety JSON response: %s", rawInspect)
	}

	fixReqJSON := `{"filePath":"calc.go","all":true,"content":` + strconvQuoteForTest(src) + `}`
	rawFix := ApplyNumericSafetyFix(fixReqJSON)
	if !strings.Contains(rawFix, `"fixedCount":4`) {
		t.Fatalf("expected fixedCount:4 in ApplyNumericSafetyFix JSON response: %s", rawFix)
	}
}

func strconvQuoteForTest(s string) string {
	escaped := strings.ReplaceAll(s, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	escaped = strings.ReplaceAll(escaped, "\n", `\n`)
	escaped = strings.ReplaceAll(escaped, "\t", `\t`)
	return `"` + escaped + `"`
}

