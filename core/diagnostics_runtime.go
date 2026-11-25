package main

import (
	"encoding/json"
	"runtime"
	"runtime/debug"

	"golens/core/lsp"
)

type RuntimeDiagnosticsReport struct {
	GoHeapAllocBytes uint64 `json:"goHeapAllocBytes"`
	GoHeapSysBytes   uint64 `json:"goHeapSysBytes"`
	GoHeapIdleBytes  uint64 `json:"goHeapIdleBytes"`
	GoReleasedBytes  uint64 `json:"goReleasedBytes"`
	GoGoroutines     int    `json:"goGoroutines"`
	GoGCCycles       uint32 `json:"goGCCycles"`
	OpenLSPBuffers   int    `json:"openLSPBuffers"`
	GoplsPID         int    `json:"goplsPID"`
	GoplsRSSBytes    int64  `json:"goplsRSSBytes"`
}

func collectRuntimeDiagnosticsReport() RuntimeDiagnosticsReport {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	var openBuffers int
	var goplsPID int
	var goplsRSS int64
	if client := lsp.GetClient(); client != nil {
		openBuffers = client.OpenBufferCount()
		goplsPID, goplsRSS = client.GoplsProcessInfo()
	}

	return RuntimeDiagnosticsReport{
		GoHeapAllocBytes: ms.HeapAlloc,
		GoHeapSysBytes:   ms.HeapSys,
		GoHeapIdleBytes:  ms.HeapIdle,
		GoReleasedBytes:  ms.HeapReleased,
		GoGoroutines:     runtime.NumGoroutine(),
		GoGCCycles:       ms.NumGC,
		OpenLSPBuffers:   openBuffers,
		GoplsPID:         goplsPID,
		GoplsRSSBytes:    goplsRSS,
	}
}

func collectRuntimeDiagnosticsJSON() string {
	report := collectRuntimeDiagnosticsReport()
	data, err := json.Marshal(report)
	if err != nil {
		return "{}"
	}
	return string(data)
}

func releaseRuntimeMemory() {
	runtime.GC()
	debug.FreeOSMemory()
}
