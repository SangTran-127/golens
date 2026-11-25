package analysis

import (
	"encoding/json"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectGoUnsafeSafety(t *testing.T) {
	src := `package native

/*
#include <stdlib.h>
*/
import "C"
import "unsafe"

type Header struct {
	A int64
	B int64
}

func ProcessBuffer(name string, payload []byte, hdr *Header, rawPtr *byte, count int, strLen int) ([]byte, string) {
	cs := C.CString(name)
	cb := C.CBytes(payload)

	addr := uintptr(unsafe.Pointer(hdr))
	fieldPtr := (*int64)(unsafe.Pointer(addr + 8))
	rawCopy := unsafe.Pointer(addr)

	sliceView := unsafe.Slice(rawPtr, count)
	strView := unsafe.String(rawPtr, strLen)

	_ = cs
	_ = cb
	_ = fieldPtr
	_ = rawCopy
	return sliceView, strView
}
`

	res, err := InspectGoUnsafeSafety(src, "bridge.go")
	if err != nil {
		t.Fatalf("InspectGoUnsafeSafety returned unexpected error: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("expected empty Error field, got %q", res.Error)
	}
	if res.CgoLeakCount != 2 {
		t.Fatalf("expected CgoLeakCount=2, got %d (issues: %+v)", res.CgoLeakCount, res.Issues)
	}
	if res.UintptrSplitCount != 2 {
		t.Fatalf("expected UintptrSplitCount=2, got %d (issues: %+v)", res.UintptrSplitCount, res.Issues)
	}
	if res.UnsafeSliceCount != 2 {
		t.Fatalf("expected UnsafeSliceCount=2, got %d (issues: %+v)", res.UnsafeSliceCount, res.Issues)
	}
	if len(res.Issues) != 6 {
		t.Fatalf("expected 6 total issues, got %d: %+v", len(res.Issues), res.Issues)
	}

	for _, iss := range res.Issues {
		if iss.ID == "" {
			t.Fatalf("expected non-empty ID on issue %+v", iss)
		}
		if !iss.CanAutoFix {
			t.Fatalf("expected CanAutoFix=true on issue %+v", iss)
		}
		if iss.FuncName != "ProcessBuffer" {
			t.Fatalf("expected FuncName=ProcessBuffer, got %q", iss.FuncName)
		}

		switch iss.Category {
		case "cgo_cstring_leak":
			if iss.Severity != "error" {
				t.Fatalf("expected severity=error for cgo_cstring_leak, got %q", iss.Severity)
			}
			if !strings.Contains(iss.ReplacementPreview, "defer C.free(unsafe.Pointer(") {
				t.Fatalf("expected defer C.free(unsafe.Pointer(...)) in preview, got %q", iss.ReplacementPreview)
			}
		case "uintptr_split_conversion":
			if iss.Severity != "error" {
				t.Fatalf("expected severity=error for uintptr_split_conversion, got %q", iss.Severity)
			}
			if !strings.Contains(iss.ReplacementPreview, "unsafe.Pointer(uintptr(unsafe.Pointer(hdr))") {
				t.Fatalf("unexpected uintptr_split_conversion preview: %q", iss.ReplacementPreview)
			}
		case "unsafe_slice_bounds":
			if iss.Severity != "warning" {
				t.Fatalf("expected severity=warning for unsafe_slice_bounds, got %q", iss.Severity)
			}
			if !strings.Contains(iss.ReplacementPreview, "max(0, ") {
				t.Fatalf("expected max(0, ...) in unsafe_slice_bounds preview, got %q", iss.ReplacementPreview)
			}
		default:
			t.Fatalf("unexpected category %q", iss.Category)
		}
	}
}

func TestInspectGoUnsafeSafety_ApplyFixesSingleAndAll(t *testing.T) {
	src := `package native

// #include <stdlib.h>
import "C"

func CallNative(label string, p *int, n int) {
	cs := C.CString(label)
	_ = cs
}
`

	initial, err := InspectGoUnsafeSafety(src, "cgo_only.go")
	if err != nil {
		t.Fatalf("InspectGoUnsafeSafety failed: %v", err)
	}
	if len(initial.Issues) != 1 || initial.CgoLeakCount != 1 {
		t.Fatalf("expected 1 cgo_cstring_leak issue, got %+v", initial)
	}

	singleFix, err := ApplyGoUnsafeSafetyFixes(src, "cgo_only.go", initial.Issues[0].ID, false)
	if err != nil {
		t.Fatalf("ApplyGoUnsafeSafetyFixes single failed: %v", err)
	}
	if singleFix.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1, got %d", singleFix.FixedCount)
	}
	if !strings.Contains(singleFix.NewContent, `"unsafe"`) {
		t.Fatalf("expected \"unsafe\" import to be added automatically:\n%s", singleFix.NewContent)
	}
	if !strings.Contains(singleFix.NewContent, "defer C.free(unsafe.Pointer(cs))") {
		t.Fatalf("expected defer C.free(unsafe.Pointer(cs)) in fixed content:\n%s", singleFix.NewContent)
	}

	fset := token.NewFileSet()
	if _, parseErr := parser.ParseFile(fset, "cgo_only.go", singleFix.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("single-fixed Go code failed to parse: %v\nNewContent:\n%s", parseErr, singleFix.NewContent)
	}
	if formatted, fmtErr := format.Source([]byte(singleFix.NewContent)); fmtErr != nil || string(formatted) != singleFix.NewContent {
		t.Fatalf("expected single-fixed Go code to be go/format compliant (err=%v):\n%s", fmtErr, singleFix.NewContent)
	}

	// Multi-issue file for applyAll=true
	multiSrc := `package native

// #include <stdlib.h>
import "C"
import "unsafe"

func DecodePacket(tag string, base *uint64, raw *byte, length int, nameLen int) ([]byte, string) {
	cTag := C.CString(tag)
	addr := uintptr(unsafe.Pointer(base))
	nextPtr := (*uint64)(unsafe.Pointer(addr + 8))
	buf := unsafe.Slice(raw, length)
	str := unsafe.String(raw, nameLen)
	_ = cTag
	_ = nextPtr
	return buf, str
}
`

	fixAll, err := ApplyGoUnsafeSafetyFixes(multiSrc, "packet.go", "", true)
	if err != nil {
		t.Fatalf("ApplyGoUnsafeSafetyFixes applyAll failed: %v", err)
	}
	if fixAll.FixedCount != 4 {
		t.Fatalf("expected FixedCount=4, got %d\nNewContent:\n%s", fixAll.FixedCount, fixAll.NewContent)
	}

	fsetAll := token.NewFileSet()
	if _, parseErr := parser.ParseFile(fsetAll, "packet.go", fixAll.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("applyAll fixed Go code failed to parse: %v\nNewContent:\n%s", parseErr, fixAll.NewContent)
	}
	if formatted, fmtErr := format.Source([]byte(fixAll.NewContent)); fmtErr != nil || string(formatted) != fixAll.NewContent {
		t.Fatalf("expected applyAll fixed Go code to be go/format compliant (err=%v):\n%s", fmtErr, fixAll.NewContent)
	}

	if !strings.Contains(fixAll.NewContent, "defer C.free(unsafe.Pointer(cTag))") {
		t.Fatalf("expected defer C.free(unsafe.Pointer(cTag)) in fixed output:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "unsafe.Pointer(uintptr(unsafe.Pointer(base)) + 8)") {
		t.Fatalf("expected inlined unsafe.Pointer(uintptr(unsafe.Pointer(base)) + 8) in fixed output:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "unsafe.Slice(raw, max(0, length))") {
		t.Fatalf("expected unsafe.Slice(raw, max(0, length)) in fixed output:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "unsafe.String(raw, max(0, nameLen))") {
		t.Fatalf("expected unsafe.String(raw, max(0, nameLen)) in fixed output:\n%s", fixAll.NewContent)
	}

	recheck, err := InspectGoUnsafeSafety(fixAll.NewContent, "packet.go")
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	if len(recheck.Issues) != 0 || recheck.CgoLeakCount != 0 || recheck.UintptrSplitCount != 0 || recheck.UnsafeSliceCount != 0 {
		t.Fatalf("expected 0 issues after applying all fixes, got %+v\nNewContent:\n%s", recheck, fixAll.NewContent)
	}
}

func TestInspectGoUnsafeSafety_SafePatternsNotFlagged(t *testing.T) {
	safeSrc := `package native

// #include <stdlib.h>
import "C"
import "unsafe"

const fixedHeaderLen = 32

func SafeOperations(name string, data []byte, ptr *byte, n int, m int) ([]byte, string) {
	cs := C.CString(name)
	defer C.free(unsafe.Pointer(cs))

	cb := C.CBytes(data)
	C.free(unsafe.Pointer(cb))

	inlinePtr := unsafe.Pointer(uintptr(unsafe.Pointer(ptr)) + 8)
	addedPtr := unsafe.Add(unsafe.Pointer(ptr), 16)
	_ = inlinePtr
	_ = addedPtr

	if n >= 0 {
		_ = unsafe.Slice(ptr, n)
	}
	if m > 0 {
		_ = unsafe.String(ptr, m)
	}

	clamped := unsafe.Slice(ptr, max(0, n))
	constSlice := unsafe.Slice(ptr, fixedHeaderLen)
	litString := unsafe.String(ptr, 16)
	_ = constSlice
	return clamped, litString
}
`

	res, err := InspectGoUnsafeSafety(safeSrc, "safe.go")
	if err != nil {
		t.Fatalf("unexpected error on safe code: %v", err)
	}
	if len(res.Issues) != 0 || res.CgoLeakCount != 0 || res.UintptrSplitCount != 0 || res.UnsafeSliceCount != 0 {
		t.Fatalf("expected 0 issues for safe code, got %+v", res)
	}
}

func TestInspectGoUnsafeSafety_JSONWrappersAndDiskRead(t *testing.T) {
	tmpDir := t.TempDir()
	diskPath := filepath.Join(tmpDir, "disk_unsafe.go")
	src := `package disk

// #include <stdlib.h>
import "C"
import "unsafe"

func ReadNative(s string, p *byte, size int) []byte {
	cs := C.CString(s)
	addr := uintptr(unsafe.Pointer(p))
	shifted := (*byte)(unsafe.Pointer(addr + 4))
	out := unsafe.Slice(shifted, size)
	_ = cs
	return out
}
`
	if err := os.WriteFile(diskPath, []byte(src), 0o600); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	reqBytes, _ := json.Marshal(UnsafeSafetyInspectRequest{
		FilePath: diskPath,
	})
	rawInspect := InspectUnsafeSafety(string(reqBytes))
	var inspectRes UnsafeSafetyInspectResult
	if err := json.Unmarshal([]byte(rawInspect), &inspectRes); err != nil {
		t.Fatalf("failed to unmarshal InspectUnsafeSafety JSON: %v", err)
	}
	if inspectRes.CgoLeakCount != 1 || inspectRes.UintptrSplitCount != 1 || inspectRes.UnsafeSliceCount != 1 || len(inspectRes.Issues) != 3 {
		t.Fatalf("unexpected disk inspect result: %+v", inspectRes)
	}

	fixReqBytes, _ := json.Marshal(UnsafeSafetyFixRequest{
		FilePath: diskPath,
		All:      true,
	})
	rawFix := ApplyUnsafeSafetyFix(string(fixReqBytes))
	var fixRes UnsafeSafetyFixResult
	if err := json.Unmarshal([]byte(rawFix), &fixRes); err != nil {
		t.Fatalf("failed to unmarshal ApplyUnsafeSafetyFix JSON: %v", err)
	}
	if fixRes.FixedCount != 3 || fixRes.Error != "" {
		t.Fatalf("expected FixedCount=3 without error, got %+v", fixRes)
	}
	if !strings.Contains(fixRes.NewContent, "defer C.free(unsafe.Pointer(cs))") {
		t.Fatalf("expected defer C.free(unsafe.Pointer(cs)) in fixed content:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, "unsafe.Pointer(uintptr(unsafe.Pointer(p)) + 4)") {
		t.Fatalf("expected inlined uintptr conversion in fixed content:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, "unsafe.Slice(shifted, max(0, size))") {
		t.Fatalf("expected clamped unsafe.Slice length in fixed content:\n%s", fixRes.NewContent)
	}
}
