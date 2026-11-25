package goast

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestGoGenerateScanDirectives(t *testing.T) {
	src := `package sample

// Normal comment that mentions go:generate
// go:generate with a space after slashes is not a directive
//go:generate
//go:generatex invalid directive

//go:generate stringer -type=Status
type Status int

//go:generate	go run ./gen.go -out=types_gen.go -pkg=sample -verbose
`
	raw, err := ScanGoGenerateDirectives("/tmp/sample.go", src)
	if err != nil {
		t.Fatalf("ScanGoGenerateDirectives failed: %v", err)
	}

	var got []GoGenerateDirective
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("failed to unmarshal directives JSON %q: %v", raw, err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 directives, got %d: %+v", len(got), got)
	}

	first := got[0]
	if first.File != "/tmp/sample.go" {
		t.Errorf("expected file /tmp/sample.go, got %q", first.File)
	}
	if first.Line != 8 {
		t.Errorf("expected first directive on line 8, got %d", first.Line)
	}
	if first.Command != "stringer -type=Status" {
		t.Errorf("expected command %q, got %q", "stringer -type=Status", first.Command)
	}
	if first.Label != "▶ Run go:generate (stringer -type=Status)" {
		t.Errorf("unexpected label: %q", first.Label)
	}
	if first.RunArg != "stringer -type=Status" {
		t.Errorf("unexpected runArg: %q", first.RunArg)
	}

	second := got[1]
	if second.Line != 11 {
		t.Errorf("expected second directive on line 11, got %d", second.Line)
	}
	wantCmd2 := "go run ./gen.go -out=types_gen.go -pkg=sample -verbose"
	if second.Command != wantCmd2 {
		t.Errorf("expected command %q, got %q", wantCmd2, second.Command)
	}
	wantLabel2 := "▶ Run go:generate (go run ./gen.go -out=types_gen.go…)"
	if second.Label != wantLabel2 {
		t.Errorf("expected truncated label %q, got %q", wantLabel2, second.Label)
	}
	wantRunArg2 := `go run \./gen\.go -out=types_gen\.go -pkg=sample -verbose`
	if second.RunArg != wantRunArg2 {
		t.Errorf("expected escaped runArg %q, got %q", wantRunArg2, second.RunArg)
	}
}

func TestGoGenerateScanFromDiskAndEmpty(t *testing.T) {
	emptyJSON, err := ScanGoGenerateDirectives("/nonexistent/file.go", "package main\nfunc main() {}\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if emptyJSON != "[]" {
		t.Fatalf("expected empty JSON array [], got %q", emptyJSON)
	}

	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "gen_target.go")
	content := "package main\n\n//go:generate echo hello_golens\n"
	if err := os.WriteFile(filePath, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	raw, err := ScanGoGenerateDirectives(filePath, "")
	if err != nil {
		t.Fatalf("ScanGoGenerateDirectives from disk failed: %v", err)
	}

	var got []GoGenerateDirective
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 directive from disk, got %d", len(got))
	}
	if got[0].Line != 3 || got[0].Command != "echo hello_golens" {
		t.Errorf("unexpected directive from disk: %+v", got[0])
	}
}

func TestGoGenerateIgnoresIndentedDirectives(t *testing.T) {
	src := "package sample\n\nfunc demo() {\n\t//go:generate echo indented\n    //go:generate echo spaces\n}\n//go:generate echo real\n"
	raw, err := ScanGoGenerateDirectives("/tmp/indented.go", src)
	if err != nil {
		t.Fatalf("ScanGoGenerateDirectives failed: %v", err)
	}
	var got []GoGenerateDirective
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected exactly 1 directive (ignoring indented ones), got %d: %+v", len(got), got)
	}
	if got[0].Line != 7 || got[0].Command != "echo real" {
		t.Fatalf("expected line 7 'echo real', got %+v", got[0])
	}
}

