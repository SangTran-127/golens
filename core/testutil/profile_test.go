package testutil

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func encodeVarint(v uint64) []byte {
	var out []byte
	for v >= 0x80 {
		out = append(out, byte(v)|0x80)
		v >>= 7
	}
	out = append(out, byte(v))
	return out
}

func encodeTag(fieldNum uint64, wireType int) []byte {
	return encodeVarint((fieldNum << 3) | uint64(wireType))
}

func encodeBytesField(fieldNum uint64, payload []byte) []byte {
	var b bytes.Buffer
	b.Write(encodeTag(fieldNum, 2))
	b.Write(encodeVarint(uint64(len(payload))))
	b.Write(payload)
	return b.Bytes()
}

func encodeVarintField(fieldNum uint64, v uint64) []byte {
	var b bytes.Buffer
	b.Write(encodeTag(fieldNum, 0))
	b.Write(encodeVarint(v))
	return b.Bytes()
}

func buildTestPprofGzip(t *testing.T, sampleTypeIdx, sampleUnitIdx uint64, samples []pprofSample) []byte {
	t.Helper()
	stringsList := []string{
		"",
		"samples",
		"count",
		"cpu",
		"nanoseconds",
		"alloc_space",
		"bytes",
		"example.com/demo.leafWork",
		"example.com/demo.callerWork",
		"example.com/demo/work.go",
	}

	var profBuf bytes.Buffer

	var vt1 bytes.Buffer
	vt1.Write(encodeVarintField(1, 1))
	vt1.Write(encodeVarintField(2, 2))
	profBuf.Write(encodeBytesField(1, vt1.Bytes()))

	var vt2 bytes.Buffer
	vt2.Write(encodeVarintField(1, sampleTypeIdx))
	vt2.Write(encodeVarintField(2, sampleUnitIdx))
	profBuf.Write(encodeBytesField(1, vt2.Bytes()))

	for idx, s := range samples {
		var sb bytes.Buffer
		if idx%2 == 0 {
			var packedLocs bytes.Buffer
			for _, id := range s.locationIDs {
				packedLocs.Write(encodeVarint(id))
			}
			sb.Write(encodeBytesField(1, packedLocs.Bytes()))

			var packedVals bytes.Buffer
			for _, v := range s.values {
				packedVals.Write(encodeVarint(uint64(v)))
			}
			sb.Write(encodeBytesField(2, packedVals.Bytes()))
		} else {
			for _, id := range s.locationIDs {
				sb.Write(encodeVarintField(1, id))
			}
			for _, v := range s.values {
				sb.Write(encodeVarintField(2, uint64(v)))
			}
		}
		profBuf.Write(encodeBytesField(2, sb.Bytes()))
	}

	var fn1 bytes.Buffer
	fn1.Write(encodeVarintField(1, 1))
	fn1.Write(encodeVarintField(2, 7))
	fn1.Write(encodeVarintField(4, 9))
	fn1.Write(encodeVarintField(5, 10))
	profBuf.Write(encodeBytesField(5, fn1.Bytes()))

	var fn2 bytes.Buffer
	fn2.Write(encodeVarintField(1, 2))
	fn2.Write(encodeVarintField(2, 8))
	fn2.Write(encodeVarintField(4, 9))
	fn2.Write(encodeVarintField(5, 25))
	profBuf.Write(encodeBytesField(5, fn2.Bytes()))

	var line1 bytes.Buffer
	line1.Write(encodeVarintField(1, 1))
	line1.Write(encodeVarintField(2, 12))
	var loc1 bytes.Buffer
	loc1.Write(encodeVarintField(1, 100))
	loc1.Write(encodeBytesField(4, line1.Bytes()))
	profBuf.Write(encodeBytesField(4, loc1.Bytes()))

	var line2 bytes.Buffer
	line2.Write(encodeVarintField(1, 2))
	line2.Write(encodeVarintField(2, 28))
	var loc2 bytes.Buffer
	loc2.Write(encodeVarintField(1, 200))
	loc2.Write(encodeBytesField(4, line2.Bytes()))
	profBuf.Write(encodeBytesField(4, loc2.Bytes()))

	for _, str := range stringsList {
		profBuf.Write(encodeBytesField(6, []byte(str)))
	}

	var gzBuf bytes.Buffer
	zw := gzip.NewWriter(&gzBuf)
	if _, err := zw.Write(profBuf.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return gzBuf.Bytes()
}

func TestParsePprofFilesSynthetic(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/demo\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	workFile := filepath.Join(dir, "work.go")
	if err := os.WriteFile(workFile, []byte("package demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cpuSamples := []pprofSample{
		{locationIDs: []uint64{100, 200, 200}, values: []int64{3, 30_000_000}},
		{locationIDs: []uint64{200}, values: []int64{1, 10_000_000}},
	}
	cpuPath := filepath.Join(dir, "cpu.pprof")
	if err := os.WriteFile(cpuPath, buildTestPprofGzip(t, 3, 4, cpuSamples), 0o644); err != nil {
		t.Fatal(err)
	}

	memSamples := []pprofSample{
		{locationIDs: []uint64{100, 200}, values: []int64{2, 65536}},
		{locationIDs: []uint64{200}, values: []int64{1, 65536}},
	}
	memPath := filepath.Join(dir, "mem.pprof")
	if err := os.WriteFile(memPath, buildTestPprofGzip(t, 5, 6, memSamples), 0o644); err != nil {
		t.Fatal(err)
	}

	cpuEntries, memEntries := ParsePprofFiles([]string{cpuPath}, []string{memPath}, dir, "", nil)
	if len(cpuEntries) != 2 {
		t.Fatalf("expected 2 cpu entries, got %d", len(cpuEntries))
	}
	if cpuEntries[0].Function != "example.com/demo.leafWork" ||
		cpuEntries[0].File != workFile ||
		cpuEntries[0].Line != 10 ||
		cpuEntries[0].Flat != 30_000_000 ||
		cpuEntries[0].FlatPercent != 75.0 ||
		cpuEntries[0].Cum != 30_000_000 ||
		cpuEntries[0].CumPercent != 75.0 ||
		cpuEntries[0].FormattedFlat != "30.00ms" ||
		cpuEntries[0].FormattedCum != "30.00ms" {
		t.Fatalf("unexpected cpu[0]: %+v", cpuEntries[0])
	}
	if cpuEntries[1].Function != "example.com/demo.callerWork" ||
		cpuEntries[1].File != workFile ||
		cpuEntries[1].Line != 25 ||
		cpuEntries[1].Flat != 10_000_000 ||
		cpuEntries[1].FlatPercent != 25.0 ||
		cpuEntries[1].Cum != 40_000_000 ||
		cpuEntries[1].CumPercent != 100.0 ||
		cpuEntries[1].FormattedFlat != "10.00ms" ||
		cpuEntries[1].FormattedCum != "40.00ms" {
		t.Fatalf("unexpected cpu[1]: %+v", cpuEntries[1])
	}

	if len(memEntries) != 2 {
		t.Fatalf("expected 2 mem entries, got %d", len(memEntries))
	}
	if memEntries[0].Function != "example.com/demo.callerWork" ||
		memEntries[0].Flat != 65536 ||
		memEntries[0].FlatPercent != 50.0 ||
		memEntries[0].Cum != 131072 ||
		memEntries[0].CumPercent != 100.0 ||
		memEntries[0].FormattedFlat != "64.0 KB" ||
		memEntries[0].FormattedCum != "128.0 KB" {
		t.Fatalf("unexpected mem[0]: %+v", memEntries[0])
	}
	if memEntries[1].Function != "example.com/demo.leafWork" ||
		memEntries[1].Flat != 65536 ||
		memEntries[1].FlatPercent != 50.0 ||
		memEntries[1].Cum != 65536 ||
		memEntries[1].CumPercent != 50.0 ||
		memEntries[1].FormattedFlat != "64.0 KB" ||
		memEntries[1].FormattedCum != "64.0 KB" {
		t.Fatalf("unexpected mem[1]: %+v", memEntries[1])
	}
}

func TestParsePprofFilesRealGoTest(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module realprof\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testSrc := `package realprof

import (
	"testing"
	"time"
)

var sink [][]byte

func allocateAndSpin() {
	for i := 0; i < 64; i++ {
		buf := make([]byte, 8192)
		buf[0] = byte(i)
		sink = append(sink, buf)
	}
	deadline := time.Now().Add(35 * time.Millisecond)
	x := 0
	for time.Now().Before(deadline) {
		for j := 0; j < 10000; j++ {
			x += j ^ (j << 1)
		}
	}
	if x == -1 {
		sink = nil
	}
}

func TestProfileTarget(t *testing.T) {
	allocateAndSpin()
}
`
	if err := os.WriteFile(filepath.Join(dir, "prof_test.go"), []byte(testSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	cpuPath := filepath.Join(dir, "cpu.pprof")
	memPath := filepath.Join(dir, "mem.pprof")
	cmd := exec.Command("go", "test", "-cpuprofile="+cpuPath, "-memprofile="+memPath, "-memprofilerate=1", ".")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go test failed: %v\n%s", err, string(out))
	}

	cpuEntries, memEntries := ParsePprofFiles([]string{cpuPath}, []string{memPath}, dir, "", nil)
	if len(memEntries) == 0 {
		t.Fatal("expected non-empty memory profile entries from real go test")
	}
	foundAlloc := false
	for _, e := range memEntries {
		if strings.Contains(e.Function, "allocateAndSpin") || strings.Contains(e.Function, "TestProfileTarget") {
			foundAlloc = true
			if !strings.HasSuffix(e.File, "prof_test.go") || e.Line <= 0 {
				t.Fatalf("expected resolved file and line on %+v", e)
			}
		}
	}
	if !foundAlloc {
		t.Fatalf("did not find allocateAndSpin in memEntries: %+v", memEntries)
	}
	_ = cpuEntries
}

func TestParseProfileFileJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/demo\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	workFile := filepath.Join(dir, "work.go")
	if err := os.WriteFile(workFile, []byte("package demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cpuSamples := []pprofSample{
		{locationIDs: []uint64{100, 200}, values: []int64{3, 30_000_000}},
	}
	cpuPath := filepath.Join(dir, "custom.prof")
	if err := os.WriteFile(cpuPath, buildTestPprofGzip(t, 3, 4, cpuSamples), 0o644); err != nil {
		t.Fatal(err)
	}
	var cpuImported ImportedProfile
	if err := json.Unmarshal([]byte(ParseProfileFileJSON(cpuPath)), &cpuImported); err != nil {
		t.Fatalf("unmarshal cpuImported: %v", err)
	}
	if cpuImported.Error != "" || cpuImported.Mode != "cpu" || len(cpuImported.Entries) != 2 {
		t.Fatalf("unexpected cpuImported: %+v", cpuImported)
	}

	memSamples := []pprofSample{
		{locationIDs: []uint64{100}, values: []int64{1, 65536}},
	}
	memPath := filepath.Join(dir, "heap.pprof")
	if err := os.WriteFile(memPath, buildTestPprofGzip(t, 5, 6, memSamples), 0o644); err != nil {
		t.Fatal(err)
	}
	var memImported ImportedProfile
	if err := json.Unmarshal([]byte(ParseProfileFileJSON(memPath)), &memImported); err != nil {
		t.Fatalf("unmarshal memImported: %v", err)
	}
	if memImported.Error != "" || memImported.Mode != "memory" || len(memImported.Entries) != 1 || memImported.Entries[0].FormattedFlat != "64.0 KB" {
		t.Fatalf("unexpected memImported: %+v", memImported)
	}

	var missingImported ImportedProfile
	if err := json.Unmarshal([]byte(ParseProfileFileJSON(filepath.Join(dir, "missing.pprof"))), &missingImported); err != nil {
		t.Fatalf("unmarshal missingImported: %v", err)
	}
	if missingImported.Error == "" {
		t.Fatalf("expected error on missing profile, got %+v", missingImported)
	}
}

func TestParsePprofCallGraphEdges(t *testing.T) {
	dir := t.TempDir()
	stringsList := []string{
		"",
		"cpu",
		"nanoseconds",
		"pkg.leafWork",
		"pkg.Compute",
		"main.main",
		"main.go",
	}

	var profBuf bytes.Buffer
	var vt bytes.Buffer
	vt.Write(encodeVarintField(1, 1))
	vt.Write(encodeVarintField(2, 2))
	profBuf.Write(encodeBytesField(1, vt.Bytes()))

	var sb bytes.Buffer
	for _, id := range []uint64{10, 20, 30} {
		sb.Write(encodeVarintField(1, id))
	}
	sb.Write(encodeVarintField(2, 50_000_000))
	profBuf.Write(encodeBytesField(2, sb.Bytes()))

	for idx, nameIdx := range []uint64{3, 4, 5} {
		fnID := uint64(idx + 1)
		locID := uint64((idx + 1) * 10)
		var fn bytes.Buffer
		fn.Write(encodeVarintField(1, fnID))
		fn.Write(encodeVarintField(2, nameIdx))
		fn.Write(encodeVarintField(4, 6))
		fn.Write(encodeVarintField(5, uint64((idx+1)*10)))
		profBuf.Write(encodeBytesField(5, fn.Bytes()))

		var ln bytes.Buffer
		ln.Write(encodeVarintField(1, fnID))
		ln.Write(encodeVarintField(2, uint64((idx+1)*10)))
		var loc bytes.Buffer
		loc.Write(encodeVarintField(1, locID))
		loc.Write(encodeBytesField(4, ln.Bytes()))
		profBuf.Write(encodeBytesField(4, loc.Bytes()))
	}

	for _, str := range stringsList {
		profBuf.Write(encodeBytesField(6, []byte(str)))
	}

	var gzBuf bytes.Buffer
	zw := gzip.NewWriter(&gzBuf)
	if _, err := zw.Write(profBuf.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}

	profPath := filepath.Join(dir, "callgraph.pprof")
	if err := os.WriteFile(profPath, gzBuf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}

	entries, err := ParseProfile(profPath, 50)
	if err != nil {
		t.Fatalf("ParseProfile failed: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d: %+v", len(entries), entries)
	}

	byFunc := make(map[string]ProfileEntry, len(entries))
	for _, e := range entries {
		byFunc[e.Function] = e
	}

	mainEntry := byFunc["main.main"]
	if len(mainEntry.Children) != 1 || mainEntry.Children[0] != "pkg.Compute" || len(mainEntry.Callers) != 0 {
		t.Fatalf("unexpected main.main edges: %+v", mainEntry)
	}

	computeEntry := byFunc["pkg.Compute"]
	if len(computeEntry.Callers) != 1 || computeEntry.Callers[0] != "main.main" ||
		len(computeEntry.Children) != 1 || computeEntry.Children[0] != "pkg.leafWork" {
		t.Fatalf("unexpected pkg.Compute edges: %+v", computeEntry)
	}

	leafEntry := byFunc["pkg.leafWork"]
	if len(leafEntry.Callers) != 1 || leafEntry.Callers[0] != "pkg.Compute" || len(leafEntry.Children) != 0 {
		t.Fatalf("unexpected pkg.leafWork edges: %+v", leafEntry)
	}
}
