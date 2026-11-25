package analysis

import (
	"encoding/json"
	"math"
	"testing"
)

func TestCompareBenchmarkRuns_RawBenchOutput(t *testing.T) {
	baselineRaw := `
goos: darwin
goarch: arm64
pkg: example.com/kvservice
BenchmarkLookup-10    	100000000	        10.00 ns/op	      64 B/op	       2 allocs/op
BenchmarkEncode-10    	 50000000	       100.0 ns/op	     256 B/op	       4 allocs/op
BenchmarkSteady-10    	 20000000	        50.00 ns/op	      32 B/op	       1 allocs/op
PASS
ok  	example.com/kvservice	3.421s
`
	currentRaw := `
goos: darwin
goarch: arm64
pkg: example.com/kvservice
BenchmarkLookup-8     	120000000	         8.76 ns/op	      48 B/op	       1 allocs/op
BenchmarkEncode-8     	 45000000	       108.2 ns/op	     320 B/op	       5 allocs/op
BenchmarkSteady-8     	 20000000	        50.20 ns/op	      32 B/op	       1 allocs/op
BenchmarkBrandNew-8   	 10000000	        15.50 ns/op	      16 B/op	       1 allocs/op
PASS
`

	outJSON, err := CompareBenchmarkRuns(baselineRaw, currentRaw)
	if err != nil {
		t.Fatalf("CompareBenchmarkRuns returned unexpected error: %v", err)
	}

	var report BenchmarkComparisonReport
	if err := json.Unmarshal([]byte(outJSON), &report); err != nil {
		t.Fatalf("failed to unmarshal report JSON: %v\nraw: %s", err, outJSON)
	}

	if report.FasterCount != 1 || report.RegressedCount != 1 || report.UnchangedCount != 1 {
		t.Fatalf("unexpected summary counts: faster=%d regressed=%d unchanged=%d",
			report.FasterCount, report.RegressedCount, report.UnchangedCount)
	}

	if len(report.Items) != 4 {
		t.Fatalf("expected 4 diff items, got %d", len(report.Items))
	}

	lookup := report.Items[0]
	if lookup.Name != "BenchmarkLookup" {
		t.Errorf("expected normalized name BenchmarkLookup, got %q", lookup.Name)
	}
	if lookup.Verdict != "faster" {
		t.Errorf("expected verdict faster, got %q", lookup.Verdict)
	}
	if math.Abs(lookup.NsDeltaPct-(-12.4)) > 0.05 {
		t.Errorf("expected nsDeltaPct ~ -12.4, got %v", lookup.NsDeltaPct)
	}
	if math.Abs(lookup.BytesDeltaPct-(-25.0)) > 0.05 {
		t.Errorf("expected bytesDeltaPct ~ -25.0, got %v", lookup.BytesDeltaPct)
	}
	if math.Abs(lookup.AllocsDeltaPct-(-50.0)) > 0.05 {
		t.Errorf("expected allocsDeltaPct ~ -50.0, got %v", lookup.AllocsDeltaPct)
	}
	if lookup.InlineBadge != "-12.4% faster" {
		t.Errorf("expected inlineBadge %q, got %q", "-12.4% faster", lookup.InlineBadge)
	}

	encode := report.Items[1]
	if encode.Name != "BenchmarkEncode" {
		t.Errorf("expected normalized name BenchmarkEncode, got %q", encode.Name)
	}
	if encode.Verdict != "regressed" {
		t.Errorf("expected verdict regressed, got %q", encode.Verdict)
	}
	if math.Abs(encode.NsDeltaPct-8.2) > 0.05 {
		t.Errorf("expected nsDeltaPct ~ 8.2, got %v", encode.NsDeltaPct)
	}
	if encode.InlineBadge != "+8.2% slower" {
		t.Errorf("expected inlineBadge %q, got %q", "+8.2% slower", encode.InlineBadge)
	}

	steady := report.Items[2]
	if steady.Name != "BenchmarkSteady" {
		t.Errorf("expected normalized name BenchmarkSteady, got %q", steady.Name)
	}
	if steady.Verdict != "unchanged" {
		t.Errorf("expected verdict unchanged, got %q", steady.Verdict)
	}
	if steady.InlineBadge != "≈0.4% ns/op" {
		t.Errorf("expected inlineBadge %q, got %q", "≈0.4% ns/op", steady.InlineBadge)
	}

	brandNew := report.Items[3]
	if brandNew.Name != "BenchmarkBrandNew" || brandNew.Verdict != "new" {
		t.Errorf("expected BenchmarkBrandNew with verdict new, got %+v", brandNew)
	}
}

func TestCompareBenchmarkRuns_JSONMapAndMixedInput(t *testing.T) {
	baselineJSON := `{
		"BenchmarkLookup-10": {"nsPerOp": 20.0, "bytesPerOp": 128, "allocsPerOp": 4},
		"example.com/pkg::BenchmarkScan": {"nsPerOp": 100.0, "bytesPerOp": 64, "allocsPerOp": 2}
	}`
	currentJSON := `{
		"BenchmarkLookup": {"nsPerOp": 15.0, "bytesPerOp": 64, "allocsPerOp": 2},
		"BenchmarkScan-12": {"nsPerOp": 110.0, "bytesPerOp": 64, "allocsPerOp": 2}
	}`

	outJSON, err := CompareBenchmarkRuns(baselineJSON, currentJSON)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var report BenchmarkComparisonReport
	if err := json.Unmarshal([]byte(outJSON), &report); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}

	if report.FasterCount != 1 || report.RegressedCount != 1 || report.UnchangedCount != 0 {
		t.Fatalf("unexpected counts: %+v", report)
	}
	if len(report.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(report.Items))
	}
	if report.Items[0].Name != "BenchmarkLookup" || report.Items[0].InlineBadge != "-25.0% faster" {
		t.Errorf("unexpected item[0]: %+v", report.Items[0])
	}
	if report.Items[1].Name != "BenchmarkScan" || report.Items[1].InlineBadge != "+10.0% slower" {
		t.Errorf("unexpected item[1]: %+v", report.Items[1])
	}
}

func TestNormalizeBenchmarkName(t *testing.T) {
	cases := map[string]string{
		"BenchmarkLookup-10":                  "BenchmarkLookup",
		"BenchmarkLookup/sub_case-8":          "BenchmarkLookup/sub_case",
		"BenchmarkLookup":                     "BenchmarkLookup",
		"example.com/foo::BenchmarkParse-16":  "BenchmarkParse",
		"example.com/foo\x00BenchmarkParse-4": "BenchmarkParse",
	}
	for input, want := range cases {
		if got := NormalizeBenchmarkName(input); got != want {
			t.Errorf("NormalizeBenchmarkName(%q) = %q, want %q", input, got, want)
		}
	}
}
