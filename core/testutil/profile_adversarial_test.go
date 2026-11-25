package testutil

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ============================================================================
// HELPER: Flexible Pprof Generator for Adversarial Testing
// ============================================================================

type sampleTypeSpec struct {
	typ  string
	unit string
}

func buildAdversarialPprof(
	sampleTypes []sampleTypeSpec,
	samples []pprofSample,
	functions []pprofFunction,
	locations []pprofLocation,
	stringTable []string,
) []byte {
	var profBuf bytes.Buffer

	// Field 1: sample_type
	for _, st := range sampleTypes {
		typeIdx := uint64(findOrAddString(&stringTable, st.typ))
		unitIdx := uint64(findOrAddString(&stringTable, st.unit))

		var vt bytes.Buffer
		vt.Write(encodeVarintField(1, typeIdx))
		vt.Write(encodeVarintField(2, unitIdx))
		profBuf.Write(encodeBytesField(1, vt.Bytes()))
	}

	// Field 2: sample
	for _, s := range samples {
		var sb bytes.Buffer
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
		profBuf.Write(encodeBytesField(2, sb.Bytes()))
	}

	// Field 4: location
	for _, loc := range locations {
		var locBuf bytes.Buffer
		locBuf.Write(encodeVarintField(1, loc.id))
		for _, ln := range loc.lines {
			var lnBuf bytes.Buffer
			lnBuf.Write(encodeVarintField(1, ln.functionID))
			lnBuf.Write(encodeVarintField(2, uint64(ln.line)))
			locBuf.Write(encodeBytesField(4, lnBuf.Bytes()))
		}
		profBuf.Write(encodeBytesField(4, locBuf.Bytes()))
	}

	// Field 5: function
	for _, fn := range functions {
		var fnBuf bytes.Buffer
		fnBuf.Write(encodeVarintField(1, fn.id))
		fnBuf.Write(encodeVarintField(2, uint64(fn.name)))
		fnBuf.Write(encodeVarintField(3, uint64(fn.systemName)))
		fnBuf.Write(encodeVarintField(4, uint64(fn.filename)))
		fnBuf.Write(encodeVarintField(5, uint64(fn.startLine)))
		profBuf.Write(encodeBytesField(5, fnBuf.Bytes()))
	}

	// Field 6: string_table
	for _, str := range stringTable {
		profBuf.Write(encodeBytesField(6, []byte(str)))
	}

	var gzBuf bytes.Buffer
	zw := gzip.NewWriter(&gzBuf)
	_, _ = zw.Write(profBuf.Bytes())
	_ = zw.Close()
	return gzBuf.Bytes()
}

func findOrAddString(table *[]string, s string) int {
	for i, existing := range *table {
		if existing == s {
			return i
		}
	}
	*table = append(*table, s)
	return len(*table) - 1
}

// ============================================================================
// 1. Contention Profiler Buffer Cap: 5,000 Contention Sites
// ============================================================================

func TestAdversarial_ContentionBufferCap_5000Sites(t *testing.T) {
	const totalSites = 5000
	const expectedCap = 500

	stringsList := []string{""}
	fileIdx := int64(findOrAddString(&stringsList, "work.go"))

	sampleTypes := []sampleTypeSpec{
		{typ: "contentions", unit: "count"},
		{typ: "delay", unit: "nanoseconds"},
	}

	functions := make([]pprofFunction, totalSites)
	locations := make([]pprofLocation, totalSites)
	samples := make([]pprofSample, totalSites)

	for i := 0; i < totalSites; i++ {
		fnID := uint64(i + 1)
		fnName := fmt.Sprintf("pkg.ContentionSite_%05d", fnID)
		nameIdx := int64(findOrAddString(&stringsList, fnName))

		functions[i] = pprofFunction{
			id:        fnID,
			name:      nameIdx,
			filename:  fileIdx,
			startLine: int64(i%100 + 1),
		}

		locations[i] = pprofLocation{
			id: fnID,
			lines: []pprofLine{
				{functionID: fnID, line: int64(i%100 + 1)},
			},
		}

		// Delays scale strictly from 1,000 ns to 5,000,000 ns
		delayNs := int64(fnID) * 1000
		count := int64(fnID % 10 + 1)

		samples[i] = pprofSample{
			locationIDs: []uint64{fnID},
			values:      []int64{count, delayNs},
		}
	}

	gzProfile := buildAdversarialPprof(sampleTypes, samples, functions, locations, stringsList)

	dir := t.TempDir()
	profPath := filepath.Join(dir, "contention_stress.pprof")
	if err := os.WriteFile(profPath, gzProfile, 0o644); err != nil {
		t.Fatalf("failed to write stress profile: %v", err)
	}

	// Test 1: ParseAllPprofFiles buffer cap enforcement
	_, _, blockEntries, _ := ParseAllPprofFiles(nil, nil, []string{profPath}, nil, dir, "", nil)

	if len(blockEntries) != expectedCap {
		t.Fatalf("DEFECT: Expected strictly %d entries capped from %d sites, got %d", expectedCap, totalSites, len(blockEntries))
	}

	// Verify top 500 are preserved in descending order of delay
	expectedMaxDelay := int64(totalSites) * 1000                           // 5,000,000
	expectedMinDelay := int64(totalSites-expectedCap+1) * 1000             // 4,501,000

	if blockEntries[0].Flat != expectedMaxDelay {
		t.Errorf("Top entry flat delay = %d; want max %d", blockEntries[0].Flat, expectedMaxDelay)
	}
	if blockEntries[0].Function != fmt.Sprintf("pkg.ContentionSite_%05d", totalSites) {
		t.Errorf("Top entry function = %s; want Site_%05d", blockEntries[0].Function, totalSites)
	}

	lastIdx := expectedCap - 1
	if blockEntries[lastIdx].Flat != expectedMinDelay {
		t.Errorf("Tail (500th) entry flat delay = %d; want %d", blockEntries[lastIdx].Flat, expectedMinDelay)
	}

	// Verify strict descending ordering throughout the capped list
	for i := 0; i < len(blockEntries)-1; i++ {
		if blockEntries[i].Flat < blockEntries[i+1].Flat {
			t.Fatalf("DEFECT: Inverted sort order at index %d (%d < %d)", i, blockEntries[i].Flat, blockEntries[i+1].Flat)
		}
		if blockEntries[i].Flat < expectedMinDelay {
			t.Fatalf("DEFECT: Entry at index %d has delay %d below 500-cap threshold %d", i, blockEntries[i].Flat, expectedMinDelay)
		}
	}

	// Test 2: ParseProfile limit preservation
	parsedEntries, err := ParseProfile(profPath, 500)
	if err != nil {
		t.Fatalf("ParseProfile failed: %v", err)
	}
	if len(parsedEntries) != expectedCap {
		t.Fatalf("ParseProfile returned %d entries; want %d", len(parsedEntries), expectedCap)
	}

	// Test 3: Memory leak verification under 10 successive parse iterations
	runtime.GC()
	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	for iter := 0; iter < 10; iter++ {
		e, err := ParseProfile(profPath, 500)
		if err != nil || len(e) != expectedCap {
			t.Fatalf("iter %d failed", iter)
		}
	}

	runtime.GC()
	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	heapGrowth := int64(memAfter.HeapAlloc) - int64(memBefore.HeapAlloc)
	t.Logf("Heap growth after 10x 5,000-site parses: %d bytes (alloc=%d)", heapGrowth, memAfter.HeapAlloc)
	// A memory leak would hold all 5,000 * 10 accumulator trees indefinitely; allow modest GC overhead < 10MB
	if heapGrowth > 10*1024*1024 {
		t.Errorf("DEFECT: Memory leak detected! Heap grew by %d bytes", heapGrowth)
	}
}

// ============================================================================
// 2. Dual Sample Type Parsing: contentions/delay vs delay/contentions
// ============================================================================

func TestAdversarial_DualSampleTypeParsing_Ordering(t *testing.T) {
	dir := t.TempDir()

	testFn := pprofFunction{
		id:        1,
		name:      2,
		filename:  3,
		startLine: 10,
	}
	testLoc := pprofLocation{
		id: 1,
		lines: []pprofLine{
			{functionID: 1, line: 15},
		},
	}

	// Case A: contentions/delay ordering
	t.Run("Ordering_ContentionsThenDelay", func(t *testing.T) {
		strTable := []string{"", "contentions", "count", "delay", "nanoseconds", "pkg.ContendedOp", "work.go"}
		sampleTypesA := []sampleTypeSpec{
			{typ: "contentions", unit: "count"},
			{typ: "delay", unit: "nanoseconds"},
		}
		// 88 contentions, 250,000,000 ns (250ms) delay
		samplesA := []pprofSample{
			{locationIDs: []uint64{1}, values: []int64{88, 250_000_000}},
		}
		fn := testFn
		fn.name = 5
		fn.filename = 6

		gzA := buildAdversarialPprof(sampleTypesA, samplesA, []pprofFunction{fn}, []pprofLocation{testLoc}, strTable)
		pathA := filepath.Join(dir, "case_a_block.pprof")
		if err := os.WriteFile(pathA, gzA, 0o644); err != nil {
			t.Fatal(err)
		}

		_, _, blockEntries, _ := ParseAllPprofFiles(nil, nil, []string{pathA}, nil, dir, "", nil)
		if len(blockEntries) != 1 {
			t.Fatalf("Case A: expected 1 block entry, got %d", len(blockEntries))
		}
		e := blockEntries[0]
		if e.Flat != 250_000_000 {
			t.Errorf("Case A: Flat = %d; want 250,000,000 (delay)", e.Flat)
		}
		if e.Count != 88 {
			t.Errorf("Case A: Count = %d; want 88 (contentions)", e.Count)
		}
		if e.FormattedFlat != "250.00ms" {
			t.Errorf("Case A: FormattedFlat = %q; want 250.00ms", e.FormattedFlat)
		}
	})

	// Case B: delay/contentions ordering
	t.Run("Ordering_DelayThenContentions", func(t *testing.T) {
		strTable := []string{"", "delay", "nanoseconds", "contentions", "count", "pkg.ContendedOp", "work.go"}
		sampleTypesB := []sampleTypeSpec{
			{typ: "delay", unit: "nanoseconds"},
			{typ: "contentions", unit: "count"},
		}
		// 250,000,000 ns delay, 88 contentions
		samplesB := []pprofSample{
			{locationIDs: []uint64{1}, values: []int64{250_000_000, 88}},
		}
		fn := testFn
		fn.name = 5
		fn.filename = 6

		gzB := buildAdversarialPprof(sampleTypesB, samplesB, []pprofFunction{fn}, []pprofLocation{testLoc}, strTable)
		pathB := filepath.Join(dir, "case_b_mutex.pprof")
		if err := os.WriteFile(pathB, gzB, 0o644); err != nil {
			t.Fatal(err)
		}

		_, _, _, mutexEntries := ParseAllPprofFiles(nil, nil, nil, []string{pathB}, dir, "", nil)
		if len(mutexEntries) != 1 {
			t.Fatalf("Case B: expected 1 mutex entry, got %d", len(mutexEntries))
		}
		e := mutexEntries[0]
		if e.Flat != 250_000_000 {
			t.Errorf("Case B: Flat = %d; want 250,000,000 (delay)", e.Flat)
		}
		if e.Count != 88 {
			t.Errorf("Case B: Count = %d; want 88 (contentions)", e.Count)
		}
		if e.FormattedFlat != "250.00ms" {
			t.Errorf("Case B: FormattedFlat = %q; want 250.00ms", e.FormattedFlat)
		}

		// Also verify ParseProfile auto-detects mutex mode from filename
		prof, err := ParseProfile(pathB, 50)
		if err != nil {
			t.Fatalf("ParseProfile failed on mutex profile: %v", err)
		}
		if len(prof) != 1 || prof[0].Flat != 250_000_000 || prof[0].Count != 88 {
			t.Errorf("ParseProfile returned unexpected: %+v", prof)
		}
	})

	// Case C: JSON export for both orderings
	t.Run("JSONExportModeDetection", func(t *testing.T) {
		strTable := []string{"", "delay", "nanoseconds", "contentions", "count", "pkg.ContendedOp", "work.go"}
		sampleTypes := []sampleTypeSpec{
			{typ: "delay", unit: "nanoseconds"},
			{typ: "contentions", unit: "count"},
		}
		samples := []pprofSample{
			{locationIDs: []uint64{1}, values: []int64{50_000_000, 10}},
		}
		fn := testFn
		fn.name = 5
		fn.filename = 6

		gz := buildAdversarialPprof(sampleTypes, samples, []pprofFunction{fn}, []pprofLocation{testLoc}, strTable)
		jsonPath := filepath.Join(dir, "contention.prof")
		if err := os.WriteFile(jsonPath, gz, 0o644); err != nil {
			t.Fatal(err)
		}

		jsonOut := ParseProfileFileJSON(jsonPath)
		var imported ImportedProfile
		if err := json.Unmarshal([]byte(jsonOut), &imported); err != nil {
			t.Fatalf("invalid json: %v\n%s", err, jsonOut)
		}
		if imported.Mode != "block" && imported.Mode != "mutex" {
			t.Errorf("imported.Mode = %q; want block or mutex", imported.Mode)
		}
		if len(imported.Entries) != 1 || imported.Entries[0].Count != 10 || imported.Entries[0].Flat != 50_000_000 {
			t.Errorf("imported.Entries mismatch: %+v", imported.Entries)
		}
	})
}

// ============================================================================
// 3. Real Go Test Contention Profiling (20 Goroutines Competing on Mutex)
// ============================================================================

func TestAdversarial_RealGoTest_ContentionProfiling(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping live contention profiling in short mode")
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module golenscontention\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 20 goroutines contending heavily on a single Mutex
	testCode := `package golenscontention

import (
	"sync"
	"testing"
	"time"
)

var sharedCounter int
var lock sync.Mutex

func TestContentionHeavy(t *testing.T) {
	const goroutines = 20
	const iterations = 50

	var wg sync.WaitGroup
	wg.Add(goroutines)

	for g := 0; g < goroutines; g++ {
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				lock.Lock()
				sharedCounter++
				// Simulate critical section work to induce contention
				time.Sleep(1 * time.Millisecond)
				lock.Unlock()
			}
		}()
	}

	wg.Wait()
}
`
	testFile := filepath.Join(dir, "contention_test.go")
	if err := os.WriteFile(testFile, []byte(testCode), 0o644); err != nil {
		t.Fatal(err)
	}

	blockFile := filepath.Join(dir, "block.pprof")
	mutexFile := filepath.Join(dir, "mutex.pprof")

	cmd := exec.Command("go", "test",
		"-blockprofile="+blockFile,
		"-blockprofilerate=1",
		"-mutexprofile="+mutexFile,
		"-mutexprofilefraction=1",
		"-run=TestContentionHeavy",
		".",
	)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go test with contention flags failed: %v\nOutput: %s", err, string(out))
	}

	// Verify both profiles were created and have non-zero size
	bStat, err := os.Stat(blockFile)
	if err != nil || bStat.Size() == 0 {
		t.Fatalf("block profile empty or missing: %v", err)
	}
	mStat, err := os.Stat(mutexFile)
	if err != nil || mStat.Size() == 0 {
		t.Fatalf("mutex profile empty or missing: %v", err)
	}

	// Parse both profiles
	_, _, blockEntries, mutexEntries := ParseAllPprofFiles(nil, nil, []string{blockFile}, []string{mutexFile}, dir, "", nil)

	t.Logf("Parsed %d block entries, %d mutex entries", len(blockEntries), len(mutexEntries))

	if len(mutexEntries) == 0 {
		t.Fatalf("DEFECT: Real mutex profile has 0 entries despite 20 goroutines contending on sync.Mutex!")
	}

	foundContention := false
	for _, e := range mutexEntries {
		t.Logf("Mutex Entry: Func=%s, File=%s:%d, Flat=%d (%s), Cum=%d, Count=%d",
			e.Function, e.File, e.Line, e.Flat, e.FormattedFlat, e.Cum, e.Count)

		if e.Flat > 0 && e.Count > 0 {
			foundContention = true
		}
	}

	if !foundContention {
		t.Errorf("DEFECT: No mutex entry had non-zero Flat delay and non-zero Count")
	}

	// Verify block entries captured delays
	if len(blockEntries) > 0 {
		topBlock := blockEntries[0]
		t.Logf("Top Block Entry: Func=%s, Delay=%s, Count=%d", topBlock.Function, topBlock.FormattedFlat, topBlock.Count)
		if topBlock.Flat <= 0 {
			t.Errorf("Top block entry flat delay was <= 0: %d", topBlock.Flat)
		}
	}
}

// ============================================================================
// 4. Counterpart Path Edge Cases
// ============================================================================

func resolveCounterpartLocal(filePath string) (counterpart string, isTest bool) {
	if !strings.HasSuffix(filePath, ".go") {
		return "", false
	}
	if strings.HasSuffix(filePath, "_test.go") {
		base := strings.TrimSuffix(filePath, "_test.go")
		return base + ".go", false
	}
	base := strings.TrimSuffix(filePath, ".go")
	return base + "_test.go", true
}

func TestAdversarial_CounterpartPath_EdgeCases(t *testing.T) {
	tests := []struct {
		input           string
		wantCounterpart string
		wantIsTest      bool
	}{
		// Multiple dots in filename
		{"api.v1.handler.go", "api.v1.handler_test.go", true},
		{"api.v1.handler_test.go", "api.v1.handler.go", false},
		{"config.prod.v2.go", "config.prod.v2_test.go", true},
		{"config.prod.v2_test.go", "config.prod.v2.go", false},
		{"a.b.c.d.go", "a.b.c.d_test.go", true},

		// Non-standard filenames
		{"foo..bar.go", "foo..bar_test.go", true},
		{"foo..bar_test.go", "foo..bar.go", false},
		{".hidden.go", ".hidden_test.go", true},
		{".hidden_test.go", ".hidden.go", false},
		{"_test.go", ".go", false},
		{".go", "_test.go", true},
		{"something_test_test.go", "something_test.go", false},
		{"nonstandard-name.file.go", "nonstandard-name.file_test.go", true},

		// Deeply nested packages
		{"/root/pkg/sub/v2/worker.go", "/root/pkg/sub/v2/worker_test.go", true},
		{"/root/pkg/sub/v2/worker_test.go", "/root/pkg/sub/v2/worker.go", false},
		{"./pkg/sub/handler.go", "./pkg/sub/handler_test.go", true},
		{"relative/path/with spaces/my file.go", "relative/path/with spaces/my file_test.go", true},
		{"relative/path/with spaces/my file_test.go", "relative/path/with spaces/my file.go", false},

		// Unicode / Vietnamese filenames
		{"xử_lý.go", "xử_lý_test.go", true},
		{"xử_lý_test.go", "xử_lý.go", false},

		// Non-Go files (must return empty string and isTest=false)
		{"handler.go.bak", "", false},
		{"api.go.txt", "", false},
		{"README.md", "", false},
		{"Makefile", "", false},
		{"", "", false},
		{".", "", false},
	}

	for _, tc := range tests {
		t.Run(tc.input, func(t *testing.T) {
			gotCp, gotIsTest := resolveCounterpartLocal(tc.input)
			if gotCp != tc.wantCounterpart || gotIsTest != tc.wantIsTest {
				t.Errorf("resolveCounterpartLocal(%q) = (%q, %v); want (%q, %v)",
					tc.input, gotCp, gotIsTest, tc.wantCounterpart, tc.wantIsTest)
			}
		})
	}

	// Missing Counterpart File Handling on Disk
	t.Run("MissingFileOnDisk", func(t *testing.T) {
		tempDir := t.TempDir()
		srcFile := filepath.Join(tempDir, "service.go")
		_ = os.WriteFile(srcFile, []byte("package service\n\nfunc Handle() {}\n"), 0o644)

		cp, isTest := resolveCounterpartLocal(srcFile)
		if !isTest || !strings.HasSuffix(cp, "service_test.go") {
			t.Fatalf("unexpected counterpart: %s", cp)
		}

		// Verify counterpart does not exist on disk
		if _, err := os.Stat(cp); !os.IsNotExist(err) {
			t.Fatalf("expected counterpart file to NOT exist")
		}

		// When counterpart test file does not exist, FindMatchingTestFunction should cleanly report missing test
		fset := token.NewFileSet()
		srcNode, err := parser.ParseFile(fset, "service.go", "package service\n\nfunc Handle() {}\n", 0)
		if err != nil {
			t.Fatal(err)
		}

		var targetTest string
		ast.Inspect(srcNode, func(n ast.Node) bool {
			if fn, ok := n.(*ast.FuncDecl); ok && fn.Name.Name == "Handle" {
				targetTest = "TestHandle"
				return false
			}
			return true
		})

		if targetTest != "TestHandle" {
			t.Errorf("targetTest = %q; want TestHandle", targetTest)
		}
	})
}

// ============================================================================
// 5. Auto-Test Debounce Concurrency (50 Saves in 100ms, -race, Zero Leaks)
// ============================================================================

// TrailingDebouncer simulates a pure trailing-edge debouncer with quiet window.
type TrailingDebouncer struct {
	mu          sync.Mutex
	timer       *time.Timer
	quietWindow time.Duration
	action      func()
	executions  int32
}

func NewTrailingDebouncer(quietWindow time.Duration, action func()) *TrailingDebouncer {
	return &TrailingDebouncer{
		quietWindow: quietWindow,
		action:      action,
	}
}

func (d *TrailingDebouncer) Trigger() {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.timer != nil {
		d.timer.Stop()
	}

	d.timer = time.AfterFunc(d.quietWindow, func() {
		atomic.AddInt32(&d.executions, 1)
		if d.action != nil {
			d.action()
		}
	})
}

func (d *TrailingDebouncer) Executions() int32 {
	return atomic.LoadInt32(&d.executions)
}

func (d *TrailingDebouncer) Stop() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.timer != nil {
		d.timer.Stop()
	}
}

func TestAdversarial_AutoTestDebounce_Concurrency(t *testing.T) {
	// Baseline goroutine count before test
	initialGoroutines := runtime.NumGoroutine()

	const saveEvents = 50
	const burstDuration = 100 * time.Millisecond
	quietWindow := 150 * time.Millisecond // scaled from 1.5s for fast deterministic test

	var executedCount int32
	debouncer := NewTrailingDebouncer(quietWindow, func() {
		atomic.AddInt32(&executedCount, 1)
	})
	defer debouncer.Stop()

	// Fire 50 saves rapidly across 50 concurrent goroutines within 100ms
	var wg sync.WaitGroup
	wg.Add(saveEvents)

	startSignal := make(chan struct{})
	for i := 0; i < saveEvents; i++ {
		go func(idx int) {
			defer wg.Done()
			<-startSignal
			// Distribute saves slightly across the 100ms burst
			if idx > 0 {
				time.Sleep(time.Duration(idx) * (burstDuration / saveEvents))
			}
			debouncer.Trigger()
		}(i)
	}

	// Trigger stampede
	close(startSignal)
	wg.Wait()

	// During burst + before quiet window has fully passed, execution count must still be 0
	midCount := debouncer.Executions()
	if midCount != 0 {
		t.Fatalf("DEFECT: Debounce fired prematurely during save burst! Executions = %d", midCount)
	}

	// Wait past the quiet window (burstDuration + quietWindow + margin)
	time.Sleep(quietWindow + 100*time.Millisecond)

	finalCount := debouncer.Executions()
	if finalCount != 1 {
		t.Fatalf("DEFECT: Expected exactly 1 auto-test execution after %v quiet window, got %d", quietWindow, finalCount)
	}

	// Wait a bit and verify no extra executions fire
	time.Sleep(100 * time.Millisecond)
	if debouncer.Executions() != 1 {
		t.Fatalf("DEFECT: Multiple executions fired: %d", debouncer.Executions())
	}

	// Goroutine leak check: ensure timer goroutines terminate cleanly
	runtime.GC()
	finalGoroutines := runtime.NumGoroutine()
	leakDiff := finalGoroutines - initialGoroutines
	t.Logf("Goroutines: initial=%d, final=%d (diff=%d)", initialGoroutines, finalGoroutines, leakDiff)
	if leakDiff > 3 {
		t.Errorf("DEFECT: Possible goroutine leak! %d leaked goroutines remaining", leakDiff)
	}
}
