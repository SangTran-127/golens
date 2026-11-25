package goast

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/bridge"
)

func TestDisassembleFunctionARM64AndAMD64(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module testdisasmpkg\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"//go:noinline",
		"func Compute(a, b int) int {",
		"\treturn a + b",
		"}",
		"",
		"func main() {",
		"\tprintln(Compute(10, 20))",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	// 1. Test arm64
	resARM64, err := DisassembleFunction(tmpDir, "Compute", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction arm64 failed: %v", err)
	}
	if resARM64.TargetArch != "arm64" {
		t.Errorf("TargetArch = %q; want arm64", resARM64.TargetArch)
	}
	if len(resARM64.Instructions) == 0 {
		t.Fatalf("expected non-empty instructions for arm64")
	}
	if resARM64.Instructions[0].Line < 1 {
		t.Errorf("expected positive line number, got %d", resARM64.Instructions[0].Line)
	}

	// 2. Test amd64 cross-compile
	resAMD64, err := DisassembleFunction(tmpDir, "Compute", "amd64")
	if err != nil {
		t.Fatalf("DisassembleFunction amd64 failed: %v", err)
	}
	if resAMD64.TargetArch != "amd64" {
		t.Errorf("TargetArch = %q; want amd64", resAMD64.TargetArch)
	}
	if len(resAMD64.Instructions) == 0 {
		t.Fatalf("expected non-empty instructions for amd64")
	}

	// 3. Test invalid architecture
	_, errInvalid := DisassembleFunction(tmpDir, "Compute", "invalid_arch")
	if errInvalid == nil {
		t.Errorf("expected error for invalid architecture")
	}

	// 4. Test non-existent function
	resNone, errNone := DisassembleFunction(tmpDir, "NonExistentFunc", "arm64")
	if errNone == nil && len(resNone.Instructions) > 0 {
		t.Errorf("expected empty instructions for non-existent function, got %d", len(resNone.Instructions))
	}
}
