package testutil

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"sync"
	"testing"
	"time"
)

var detailSink [][]byte

func detailWriteProfile(t *testing.T, name string, write func(f *os.File) error) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := write(f); err != nil {
		_ = f.Close()
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func detailSampleTypeIndex(d ProfileDetail, name string) int {
	for i, st := range d.SampleTypes {
		if st.Type == name {
			return i
		}
	}
	return -1
}

func detailBurnCPU(d time.Duration) uint64 {
	deadline := time.Now().Add(d)
	var x uint64 = 1
	for time.Now().Before(deadline) {
		for i := 0; i < 100000; i++ {
			x = x*6364136223846793005 + 1442695040888963407
		}
	}
	return x
}

func TestProfileDetailCPU(t *testing.T) {
	path := detailWriteProfile(t, "cpu.pprof", func(f *os.File) error {
		if err := pprof.StartCPUProfile(f); err != nil {
			return err
		}
		detailSink = append(detailSink[:0], []byte{byte(detailBurnCPU(400 * time.Millisecond))})
		pprof.StopCPUProfile()
		return nil
	})
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != "cpu" || d.SampleType != "cpu" || d.Unit != "nanoseconds" {
		t.Fatalf("mode/type/unit = %s/%s/%s", d.Mode, d.SampleType, d.Unit)
	}
	if detailSampleTypeIndex(d, "samples") < 0 || detailSampleTypeIndex(d, "cpu") < 0 || len(d.SampleTypes) != 2 {
		t.Fatalf("sample types = %+v", d.SampleTypes)
	}
	if d.TotalValue <= 0 || d.SampleCount <= 0 || d.CountTotal <= 0 || d.CountType != "samples" {
		t.Fatalf("total=%d samples=%d count=%d/%s", d.TotalValue, d.SampleCount, d.CountTotal, d.CountType)
	}
	if d.DurationNanos < int64(300*time.Millisecond) {
		t.Fatalf("duration = %d", d.DurationNanos)
	}
	if d.PeriodType != "cpu" || d.PeriodUnit != "nanoseconds" || d.Period <= 0 {
		t.Fatalf("period = %d %s %s", d.Period, d.PeriodType, d.PeriodUnit)
	}
	if d.Truncated || len(d.Entries) == 0 || d.EntriesBeforeCap != len(d.Entries) {
		t.Fatalf("truncated=%v entries=%d before=%d", d.Truncated, len(d.Entries), d.EntriesBeforeCap)
	}
	if len(d.ContentSHA256) != 64 {
		t.Fatalf("sha = %q", d.ContentSHA256)
	}
	var sawBurn bool
	for _, e := range d.Entries {
		if e.Function == "golens/core/testutil.detailBurnCPU" && e.Flat > 0 {
			sawBurn = true
		}
	}
	if !sawBurn {
		t.Fatalf("detailBurnCPU not found in entries")
	}
}

func TestProfileDetailMatchesExistingEntries(t *testing.T) {
	path := detailWriteProfile(t, "cpu.pprof", func(f *os.File) error {
		if err := pprof.StartCPUProfile(f); err != nil {
			return err
		}
		detailBurnCPU(200 * time.Millisecond)
		pprof.StopCPUProfile()
		return nil
	})
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	existing, err := ParseProfile(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(existing) != len(d.Entries) {
		t.Fatalf("entry count differs: existing %d detail %d", len(existing), len(d.Entries))
	}
	for i := range existing {
		a, b := existing[i], d.Entries[i]
		if a.Function != b.Function || a.Flat != b.Flat || a.Cum != b.Cum || a.FlatPercent != b.FlatPercent || a.CumPercent != b.CumPercent || a.Count != b.Count || a.File != b.File || a.Line != b.Line {
			t.Fatalf("entry %d differs: %+v vs %+v", i, a, b)
		}
	}
}

func TestProfileDetailHeapAllocAndInuse(t *testing.T) {
	prevRate := runtime.MemProfileRate
	runtime.MemProfileRate = 1
	defer func() { runtime.MemProfileRate = prevRate }()

	const chunks = 48
	const chunkSize = 1 << 20
	detailSink = detailSink[:0]
	for i := 0; i < chunks; i++ {
		detailSink = append(detailSink, make([]byte, chunkSize))
	}
	defer func() { detailSink = nil }()
	runtime.GC()
	runtime.GC()

	path := detailWriteProfile(t, "heap.pprof", func(f *os.File) error {
		return pprof.Lookup("heap").WriteTo(f, 0)
	})

	alloc, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if alloc.Mode != "memory" || alloc.SampleType != "alloc_space" || alloc.Unit != "bytes" {
		t.Fatalf("default = %s/%s/%s", alloc.Mode, alloc.SampleType, alloc.Unit)
	}
	for _, want := range []string{"alloc_objects", "alloc_space", "inuse_objects", "inuse_space"} {
		if detailSampleTypeIndex(alloc, want) < 0 {
			t.Fatalf("sample type %s missing from %+v", want, alloc.SampleTypes)
		}
	}
	if alloc.TotalValue < chunks*chunkSize {
		t.Fatalf("alloc total %d below known allocation %d", alloc.TotalValue, chunks*chunkSize)
	}

	inuse, err := ParseProfileDetailedWithOptions(path, ProfileDetailOptions{SampleTypeOverride: "inuse_space"})
	if err != nil {
		t.Fatal(err)
	}
	if inuse.SampleType != "inuse_space" || inuse.Unit != "bytes" || inuse.Mode != "memory" {
		t.Fatalf("override = %s/%s/%s", inuse.Mode, inuse.SampleType, inuse.Unit)
	}
	if inuse.TotalValue < chunks*chunkSize {
		t.Fatalf("inuse total %d below retained %d", inuse.TotalValue, chunks*chunkSize)
	}
	if inuse.ContentSHA256 != alloc.ContentSHA256 {
		t.Fatalf("same file produced different hashes")
	}
	var found bool
	for _, e := range inuse.Entries {
		if e.Function == "golens/core/testutil.TestProfileDetailHeapAllocAndInuse" && e.Flat >= chunks*chunkSize {
			found = true
		}
	}
	if !found {
		t.Fatalf("known allocation site missing from inuse entries")
	}

	if _, err := ParseProfileDetailedWithOptions(path, ProfileDetailOptions{SampleTypeOverride: "nope"}); err == nil {
		t.Fatalf("unknown sample type should fail")
	}
}

func TestProfileDetailBlock(t *testing.T) {
	runtime.SetBlockProfileRate(1)
	defer runtime.SetBlockProfileRate(0)
	ch := make(chan struct{})
	go func() {
		time.Sleep(60 * time.Millisecond)
		close(ch)
	}()
	<-ch

	path := detailWriteProfile(t, "block.pprof", func(f *os.File) error {
		return pprof.Lookup("block").WriteTo(f, 0)
	})
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != "block" || d.SampleType != "delay" || d.Unit != "nanoseconds" {
		t.Fatalf("block = %s/%s/%s", d.Mode, d.SampleType, d.Unit)
	}
	if detailSampleTypeIndex(d, "contentions") < 0 || len(d.SampleTypes) != 2 {
		t.Fatalf("sample types = %+v", d.SampleTypes)
	}
	if d.TotalValue < int64(40*time.Millisecond) {
		t.Fatalf("block delay total = %d", d.TotalValue)
	}
	if d.CountType != "contentions" || d.CountTotal <= 0 {
		t.Fatalf("count = %s %d", d.CountType, d.CountTotal)
	}
}

func TestProfileDetailMutex(t *testing.T) {
	prev := runtime.SetMutexProfileFraction(1)
	defer runtime.SetMutexProfileFraction(prev)
	var mu sync.Mutex
	mu.Lock()
	done := make(chan struct{})
	go func() {
		mu.Lock()
		mu.Unlock()
		close(done)
	}()
	time.Sleep(60 * time.Millisecond)
	mu.Unlock()
	<-done

	path := detailWriteProfile(t, "mutex.pprof", func(f *os.File) error {
		return pprof.Lookup("mutex").WriteTo(f, 0)
	})
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != "mutex" || d.SampleType != "delay" || d.Unit != "nanoseconds" {
		t.Fatalf("mutex = %s/%s/%s", d.Mode, d.SampleType, d.Unit)
	}
	if d.TotalValue < int64(40*time.Millisecond) {
		t.Fatalf("mutex delay total = %d", d.TotalValue)
	}
	override, err := ParseProfileDetailedWithOptions(path, ProfileDetailOptions{ModeOverride: "block"})
	if err != nil {
		t.Fatal(err)
	}
	if override.Mode != "block" {
		t.Fatalf("override mode = %s", override.Mode)
	}
	if _, err := ParseProfileDetailedWithOptions(path, ProfileDetailOptions{ModeOverride: "wall"}); err == nil {
		t.Fatalf("unsupported mode should fail")
	}
}

func TestProfileDetailTruncationReportsPreCapCount(t *testing.T) {
	const sites = 640
	stringsList := []string{""}
	fileIdx := int64(findOrAddString(&stringsList, "work.go"))
	functions := make([]pprofFunction, sites)
	locations := make([]pprofLocation, sites)
	samples := make([]pprofSample, sites)
	var wantTotal int64
	for i := 0; i < sites; i++ {
		nameIdx := int64(findOrAddString(&stringsList, fmt.Sprintf("pkg.Site%04d", i)))
		functions[i] = pprofFunction{id: uint64(i + 1), name: nameIdx, systemName: nameIdx, filename: fileIdx, startLine: int64(i + 1)}
		locations[i] = pprofLocation{id: uint64(i + 1), lines: []pprofLine{{functionID: uint64(i + 1), line: int64(i + 1)}}}
		value := int64(1000 + i)
		wantTotal += value
		samples[i] = pprofSample{locationIDs: []uint64{uint64(i + 1)}, values: []int64{1, value}}
	}
	data := buildAdversarialPprof(
		[]sampleTypeSpec{{typ: "contentions", unit: "count"}, {typ: "delay", unit: "nanoseconds"}},
		samples, functions, locations, stringsList,
	)
	path := filepath.Join(t.TempDir(), "block.pprof")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if !d.Truncated || d.EntriesBeforeCap != sites || len(d.Entries) != maxProfileEntries || d.EntryCap != maxProfileEntries {
		t.Fatalf("truncated=%v before=%d len=%d cap=%d", d.Truncated, d.EntriesBeforeCap, len(d.Entries), d.EntryCap)
	}
	if d.TotalValue != wantTotal {
		t.Fatalf("total = %d, want full total %d independent of the entry cap", d.TotalValue, wantTotal)
	}
	if d.SampleCount != sites || d.CountTotal != sites {
		t.Fatalf("samples=%d countTotal=%d", d.SampleCount, d.CountTotal)
	}
}

func TestProfileDetailSeparatesSkippedAndZeroValueSamples(t *testing.T) {
	stringsList := []string{""}
	fileIdx := int64(findOrAddString(&stringsList, "a.go"))
	nameIdx := int64(findOrAddString(&stringsList, "pkg.Work"))
	functions := []pprofFunction{{id: 1, name: nameIdx, systemName: nameIdx, filename: fileIdx, startLine: 3}}
	locations := []pprofLocation{{id: 1, lines: []pprofLine{{functionID: 1, line: 3}}}}
	samples := []pprofSample{
		{locationIDs: []uint64{1}, values: []int64{5}},
		{locationIDs: []uint64{1}, values: []int64{0}},
		{locationIDs: nil, values: []int64{9}},
	}
	data := buildAdversarialPprof([]sampleTypeSpec{{typ: "cpu", unit: "nanoseconds"}}, samples, functions, locations, stringsList)
	path := filepath.Join(t.TempDir(), "cpu.pprof")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if d.TotalValue != 5 || d.SkippedSamples != 1 || d.ZeroValueSamples != 1 || d.SampleCount != 3 {
		t.Fatalf("total=%d skipped=%d zero=%d samples=%d", d.TotalValue, d.SkippedSamples, d.ZeroValueSamples, d.SampleCount)
	}
	if d.DurationNanos != 0 || d.Period != 0 {
		t.Fatalf("absent metadata should be zero, got %d %d", d.DurationNanos, d.Period)
	}
}

func TestProfileDetailRejectsEmptyAndGarbage(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.pprof")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseProfileDetailed(empty); err == nil {
		t.Fatal("empty profile should fail")
	}
	garbage := filepath.Join(dir, "garbage.pprof")
	if err := os.WriteFile(garbage, bytes.Repeat([]byte{0xff}, 32), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseProfileDetailed(garbage); err == nil {
		t.Fatal("garbage profile should fail")
	}
	if _, err := ParseProfileDetailed(filepath.Join(dir, "missing.pprof")); err == nil {
		t.Fatal("missing file should fail")
	}
}

func TestProfileDetailRecursionCountsCumulativeOnce(t *testing.T) {
	stringsList := []string{""}
	fileIdx := int64(findOrAddString(&stringsList, "r.go"))
	recurse := int64(findOrAddString(&stringsList, "pkg.Recurse"))
	mainFn := int64(findOrAddString(&stringsList, "pkg.Main"))
	functions := []pprofFunction{
		{id: 1, name: recurse, systemName: recurse, filename: fileIdx, startLine: 10},
		{id: 2, name: mainFn, systemName: mainFn, filename: fileIdx, startLine: 1},
	}
	locations := []pprofLocation{
		{id: 1, lines: []pprofLine{{functionID: 1, line: 11}}},
		{id: 2, lines: []pprofLine{{functionID: 2, line: 2}}},
	}
	samples := []pprofSample{{locationIDs: []uint64{1, 1, 1, 1, 2}, values: []int64{100}}}
	data := buildAdversarialPprof([]sampleTypeSpec{{typ: "cpu", unit: "nanoseconds"}}, samples, functions, locations, stringsList)
	path := filepath.Join(t.TempDir(), "cpu.pprof")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	d, err := ParseProfileDetailed(path)
	if err != nil {
		t.Fatal(err)
	}
	if d.TotalValue != 100 {
		t.Fatalf("total = %d", d.TotalValue)
	}
	for _, e := range d.Entries {
		if e.Function == "pkg.Recurse" && (e.Flat != 100 || e.Cum != 100) {
			t.Fatalf("recursive frame flat=%d cum=%d, want 100/100", e.Flat, e.Cum)
		}
		if e.Cum > d.TotalValue {
			t.Fatalf("%s cum %d exceeds total %d", e.Function, e.Cum, d.TotalValue)
		}
	}
}
