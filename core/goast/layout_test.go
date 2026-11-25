package goast

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStructLayoutOptimizationAndEdits(t *testing.T) {
	src := `package models

type BadLayout struct {
	FlagA   bool   ` + "`json:\"flag_a\"`" + `
	Count   int64  ` + "`json:\"count\"`" + `
	FlagB   bool   ` + "`json:\"flag_b\"`" + `
	Title   string ` + "`json:\"title\"`" + `
	Tiny    int8
	Items   []int
	ShortID uint16 ` + "`db:\"short_id\"`" + `
}
`
	report := InspectStructLayout("models.go", []byte(src), 25, "arm64")
	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.StructName != "BadLayout" {
		t.Fatalf("expected StructName BadLayout, got %q", report.StructName)
	}
	if report.Arch != "arm64" || report.WordSize != 8 {
		t.Fatalf("expected arm64 wordSize 8, got %s %d", report.Arch, report.WordSize)
	}

	if len(report.Fields) != 7 {
		t.Fatalf("expected 7 fields, got %d", len(report.Fields))
	}

	// Verify original layout offsets & padding:
	// 0: FlagA (size 1, align 1) -> offset 0, pad 0
	// 1: Count (size 8, align 8) -> offset 8, pad 7
	// 2: FlagB (size 1, align 1) -> offset 16, pad 0
	// 3: Title (size 16, align 8) -> offset 24, pad 7
	// 4: Tiny (size 1, align 1) -> offset 40, pad 0
	// 5: Items (size 24, align 8) -> offset 48, pad 7
	// 6: ShortID (size 2, align 2) -> offset 72, pad 0 (ends at 74, tail padding 6 -> total 80)
	if report.Fields[0].Offset != 0 || report.Fields[0].PaddingBefore != 0 {
		t.Errorf("unexpected FlagA layout: %+v", report.Fields[0])
	}
	if report.Fields[1].Offset != 8 || report.Fields[1].PaddingBefore != 7 {
		t.Errorf("unexpected Count layout: %+v", report.Fields[1])
	}
	if report.Fields[2].Offset != 16 || report.Fields[2].PaddingBefore != 0 {
		t.Errorf("unexpected FlagB layout: %+v", report.Fields[2])
	}
	if report.Fields[3].Offset != 24 || report.Fields[3].PaddingBefore != 7 {
		t.Errorf("unexpected Title layout: %+v", report.Fields[3])
	}
	if report.Fields[5].Offset != 48 || report.Fields[5].PaddingBefore != 7 {
		t.Errorf("unexpected Items layout: %+v", report.Fields[5])
	}
	if report.CurrentSize != 80 {
		t.Errorf("expected CurrentSize 80, got %d", report.CurrentSize)
	}
	if report.CurrentAlign != 8 {
		t.Errorf("expected CurrentAlign 8, got %d", report.CurrentAlign)
	}
	if report.TailPadding != 6 {
		t.Errorf("expected TailPadding 6, got %d", report.TailPadding)
	}
	if report.CurrentPadding != 27 {
		t.Errorf("expected CurrentPadding 27, got %d", report.CurrentPadding)
	}

	// Optimized order:
	// Items ([]int, align 8, size 24) -> 0..24
	// Title (string, align 8, size 16) -> 24..40
	// Count (int64, align 8, size 8) -> 40..48
	// ShortID (uint16, align 2, size 2) -> 48..50
	// FlagA (bool, align 1, size 1) -> 50..51
	// FlagB (bool, align 1, size 1) -> 51..52
	// Tiny (int8, align 1, size 1) -> 52..53 (tail pad 3 -> 56)
	if report.OptimizedSize != 56 {
		t.Errorf("expected OptimizedSize 56, got %d", report.OptimizedSize)
	}
	if report.SavedBytes != 24 {
		t.Errorf("expected SavedBytes 24, got %d", report.SavedBytes)
	}
	wantOrder := []string{"Items", "Title", "Count", "ShortID", "FlagA", "FlagB", "Tiny"}
	for i, want := range wantOrder {
		if report.OptimizedFields[i].Name != want {
			t.Errorf("optimized field %d: want %s, got %s", i, want, report.OptimizedFields[i].Name)
		}
	}

	edits := report.EditsByPath["models.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit for models.go, got %d", len(edits))
	}
	updated := applyEditsToText(src, edits)
	if !strings.Contains(updated, "Items   []int\n\tTitle   string `json:\"title\"`\n\tCount   int64  `json:\"count\"`") {
		t.Errorf("unexpected formatted struct output:\n%s", updated)
	}

	// Verify re-running on optimized source yields 0 saved bytes
	recheck := InspectStructLayout("models.go", []byte(updated), 25, "arm64")
	if recheck.SavedBytes != 0 || recheck.CurrentSize != 56 {
		t.Errorf("expected 0 saved bytes after optimization, got SavedBytes=%d CurrentSize=%d", recheck.SavedBytes, recheck.CurrentSize)
	}
}

func TestStructLayout32BitVs64BitAndMultiNames(t *testing.T) {
	src := `package main

type Packet struct {
	A, B byte
	Ptr  *int
	Seq  int64
	Str  string
}
`
	rep64 := InspectStructLayout("pkt.go", []byte(src), 0, "amd64")
	if rep64.WordSize != 8 {
		t.Fatalf("expected wordSize 8 on amd64, got %d", rep64.WordSize)
	}
	if len(rep64.Fields) != 5 {
		t.Fatalf("expected 5 expanded fields, got %d", len(rep64.Fields))
	}
	if rep64.Fields[0].Name != "A" || rep64.Fields[1].Name != "B" {
		t.Fatalf("expected expanded multi-name fields A, B; got %v", rep64.Fields)
	}
	// On 64-bit: A(1), B(1), pad(6), Ptr(8), Seq(8), Str(16) -> 40 bytes
	if rep64.CurrentSize != 40 {
		t.Errorf("expected 64-bit size 40, got %d", rep64.CurrentSize)
	}

	rep32 := InspectStructLayout("pkt.go", []byte(src), 0, "386")
	if rep32.WordSize != 4 || rep32.Arch != "386" {
		t.Fatalf("expected wordSize 4 on 386, got %d (%s)", rep32.WordSize, rep32.Arch)
	}
	// On 32-bit: A(1), B(1), pad(2), Ptr(4, align 4), Seq(8, align 4), Str(8, align 4) -> 24 bytes
	if rep32.CurrentSize != 24 || rep32.CurrentAlign != 4 {
		t.Errorf("expected 32-bit size 24 align 4, got size=%d align=%d", rep32.CurrentSize, rep32.CurrentAlign)
	}
}

func TestStructLayoutSpecialAndNestedTypes(t *testing.T) {
	src := `package pkg

import (
	"sync"
	"time"
	"unsafe"
)

type Inner struct {
	X int32
	Y int32
}

type Node struct {
	Next *Node
	Self Node
}

type ComplexStruct struct {
	Empty    struct{}
	Arr      [3]uint16
	Mu       sync.Mutex
	WG       sync.WaitGroup
	When     time.Time
	Dur      time.Duration
	AnyVal   any
	Err      error
	Iface    interface{}
	C64      complex64
	C128     complex128
	RawPtr   unsafe.Pointer
	Ch       chan int
	Lookup   map[string]int
	Callback func()
	Nested   Inner
}
`
	offset := strings.Index(src, "type ComplexStruct")
	rep := InspectStructLayout("complex.go", []byte(src), offset, "arm64")
	if rep.Error != "" {
		t.Fatalf("unexpected error: %s", rep.Error)
	}
	if rep.StructName != "ComplexStruct" {
		t.Fatalf("expected ComplexStruct, got %s", rep.StructName)
	}

	byName := map[string]StructFieldLayout{}
	for _, f := range rep.Fields {
		byName[f.Name] = f
	}

	checks := []struct {
		name  string
		size  int
		align int
	}{
		{"Empty", 0, 1},
		{"Arr", 6, 2},
		{"Mu", 8, 4},
		{"WG", 8, 4},
		{"When", 24, 8},
		{"Dur", 8, 8},
		{"AnyVal", 16, 8},
		{"Err", 16, 8},
		{"Iface", 16, 8},
		{"C64", 8, 8},
		{"C128", 16, 8},
		{"RawPtr", 8, 8},
		{"Ch", 8, 8},
		{"Lookup", 8, 8},
		{"Callback", 8, 8},
		{"Nested", 8, 4},
	}

	for _, c := range checks {
		got, ok := byName[c.name]
		if !ok {
			t.Fatalf("missing field %s", c.name)
		}
		if got.Size != c.size || got.Align != c.align {
			t.Errorf("field %s: want size=%d align=%d, got size=%d align=%d", c.name, c.size, c.align, got.Size, got.Align)
		}
	}

	// Verify cycle guard on recursive Node struct does not infinite-loop
	nodeOffset := strings.Index(src, "type Node")
	nodeRep := InspectStructLayout("complex.go", []byte(src), nodeOffset, "arm64")
	if nodeRep.Error != "" || nodeRep.StructName != "Node" {
		t.Fatalf("failed on recursive struct Node: %+v", nodeRep)
	}
}

func TestStructLayoutNoStructAndJSONWrapper(t *testing.T) {
	raw := InspectStructLayoutJSON("none.go", []byte("package main\n\nfunc main() {}\n"), 0, "")
	var rep StructLayoutReport
	if err := json.Unmarshal([]byte(raw), &rep); err != nil {
		t.Fatalf("failed to unmarshal JSON report: %v", err)
	}
	if rep.Error == "" {
		t.Fatalf("expected error when file has no structs")
	}
}
