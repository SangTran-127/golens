package main

import (
	"encoding/json"
	"testing"

	"golens/core/lsp"
)

func TestCollectRuntimeDiagnosticsJSON_ValidReport(t *testing.T) {
	raw := collectRuntimeDiagnosticsJSON()
	if raw == "" || raw == "{}" {
		t.Fatalf("expected non-empty JSON report, got %q", raw)
	}

	var report RuntimeDiagnosticsReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("failed to unmarshal RuntimeDiagnosticsReport: %v (raw=%s)", err, raw)
	}

	if report.GoHeapAllocBytes == 0 {
		t.Errorf("expected positive goHeapAllocBytes, got 0")
	}
	if report.GoHeapSysBytes < report.GoHeapAllocBytes {
		t.Errorf("expected goHeapSysBytes (%d) >= goHeapAllocBytes (%d)", report.GoHeapSysBytes, report.GoHeapAllocBytes)
	}
	if report.GoGoroutines <= 0 {
		t.Errorf("expected positive goGoroutines, got %d", report.GoGoroutines)
	}
	if report.OpenLSPBuffers < 0 {
		t.Errorf("expected non-negative openLSPBuffers, got %d", report.OpenLSPBuffers)
	}
	if report.GoplsPID < 0 {
		t.Errorf("expected non-negative goplsPID, got %d", report.GoplsPID)
	}
	if report.GoplsRSSBytes < 0 {
		t.Errorf("expected non-negative goplsRSSBytes, got %d", report.GoplsRSSBytes)
	}
}

func TestCollectRuntimeDiagnosticsJSON_TracksOpenLSPBuffers(t *testing.T) {
	testPath := "/tmp/golens_diagnostics_runtime_test.go"
	lsp.CloseDocument(testPath)
	before := collectRuntimeDiagnosticsReport().OpenLSPBuffers

	lsp.OpenDocument(testPath, []byte("package main\nfunc main() {}\n"))
	defer lsp.CloseDocument(testPath)

	during := collectRuntimeDiagnosticsReport().OpenLSPBuffers
	if during != before+1 {
		t.Fatalf("expected openLSPBuffers=%d after opening buffer, got %d", before+1, during)
	}

	lsp.CloseDocument(testPath)
	after := collectRuntimeDiagnosticsReport().OpenLSPBuffers
	if after != before {
		t.Fatalf("expected openLSPBuffers=%d after closing buffer, got %d", before, after)
	}
}

func TestReleaseRuntimeMemory_ExecutesCleanly(t *testing.T) {
	before := collectRuntimeDiagnosticsReport()
	scratch := make([]byte, 2<<20)
	scratch[0] = 1
	_ = scratch

	releaseRuntimeMemory()

	after := collectRuntimeDiagnosticsReport()
	if after.GoGCCycles <= before.GoGCCycles {
		t.Errorf("expected goGCCycles to advance after releaseRuntimeMemory (before=%d, after=%d)", before.GoGCCycles, after.GoGCCycles)
	}
	if after.GoHeapAllocBytes == 0 {
		t.Errorf("expected positive goHeapAllocBytes after releaseRuntimeMemory")
	}
}
