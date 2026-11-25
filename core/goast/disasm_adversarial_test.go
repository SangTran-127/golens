package goast

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

// TestAdversarial_Disasm_DeeplyNestedAndLargeFunction tests whether DisassembleFunction
// handles massive control flow, deep nesting, branches, and thousands of instructions
// without truncation, crash, or memory explosion.
func TestAdversarial_Disasm_DeeplyNestedAndLargeFunction(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module adversariallarge\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	// Generate a function with deep nesting and 1500+ operations
	var sb strings.Builder
	sb.WriteString("package main\n\n")
	sb.WriteString("//go:noinline\n")
	sb.WriteString("func MegaCompute(n int) int {\n")
	sb.WriteString("\tres := n\n")
	sb.WriteString("\tif n > 0 {\n")
	sb.WriteString("\t\tfor i := 0; i < 5; i++ {\n")
	sb.WriteString("\t\t\tif i%2 == 0 {\n")
	sb.WriteString("\t\t\t\tfor j := 0; j < 5; j++ {\n")
	sb.WriteString("\t\t\t\t\tswitch (i + j) % 4 {\n")
	sb.WriteString("\t\t\t\t\tcase 0:\n")
	sb.WriteString("\t\t\t\t\t\tres += (i * 3) ^ (j * 7)\n")
	sb.WriteString("\t\t\t\t\tcase 1:\n")
	sb.WriteString("\t\t\t\t\t\tres -= (i + j) * 2\n")
	sb.WriteString("\t\t\t\t\tcase 2:\n")
	sb.WriteString("\t\t\t\t\t\tres ^= (i + 1) * (j + 2)\n")
	sb.WriteString("\t\t\t\t\tdefault:\n")
	sb.WriteString("\t\t\t\t\t\tres += (j - i)\n")
	sb.WriteString("\t\t\t\t\t}\n")
	sb.WriteString("\t\t\t\t}\n")
	sb.WriteString("\t\t\t}\n")
	sb.WriteString("\t\t}\n")
	sb.WriteString("\t}\n")

	// Append 100 unrolled computational statements to generate hundreds of instructions
	for k := 0; k < 120; k++ {
		sb.WriteString(fmt.Sprintf("\tres += (n * %d) ^ %d\n", k+1, (k*37)%100))
		sb.WriteString(fmt.Sprintf("\tif res %% %d == 0 { res += %d }\n", (k%7)+2, k))
	}
	sb.WriteString("\treturn res\n")
	sb.WriteString("}\n\n")
	sb.WriteString("func main() {\n\tprintln(MegaCompute(42))\n}\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(sb.String()), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	for _, arch := range []string{"arm64", "amd64"} {
		t.Run("Arch_"+arch, func(t *testing.T) {
			start := time.Now()
			res, err := DisassembleFunction(tmpDir, "MegaCompute", arch)
			elapsed := time.Since(start)

			if err != nil {
				t.Fatalf("DisassembleFunction failed for %s: %v", arch, err)
			}
			if res.TargetArch != arch {
				t.Errorf("TargetArch = %q; want %s", res.TargetArch, arch)
			}
			if len(res.Instructions) < 200 {
				t.Errorf("expected at least 200 instructions for large function, got %d", len(res.Instructions))
			}

			// Validate instruction integrity
			for idx, inst := range res.Instructions {
				if inst.Address == "" || !strings.HasPrefix(inst.Address, "0x") {
					t.Errorf("instruction[%d] missing valid address: %q", idx, inst.Address)
					break
				}
				if inst.Mnemonic == "" {
					t.Errorf("instruction[%d] missing mnemonic at %s", idx, inst.Address)
					break
				}
				if inst.Line < 1 {
					t.Errorf("instruction[%d] invalid line number: %d", idx, inst.Line)
					break
				}
			}
			t.Logf("[%s] MegaCompute disassembled %d instructions in %v", arch, len(res.Instructions), elapsed)
		})
	}
}

// TestAdversarial_Disasm_SymbolIsolation_SubstringCollision checks whether requesting disassembly
// for a function name like "Add" erroneously captures other functions whose names contain "Add"
// (e.g. AddExtra, SuperAdd, or runtime functions like runtime.itabAdd or errorAddressString).
func TestAdversarial_Disasm_SymbolIsolation_SubstringCollision(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module symbolcollision\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"//go:noinline",
		"func Add(a, b int) int {",
		"\treturn a + b",
		"}",
		"",
		"//go:noinline",
		"func AddExtra(a, b int) int {",
		"\treturn a + b + 100",
		"}",
		"",
		"//go:noinline",
		"func SuperAdd(a, b int) int {",
		"\treturn a + b + 999",
		"}",
		"",
		"func main() {",
		"\tprintln(Add(1, 2))",
		"\tprintln(AddExtra(3, 4))",
		"\tprintln(SuperAdd(5, 6))",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	res, err := DisassembleFunction(tmpDir, "Add", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction('Add') failed: %v", err)
	}

	t.Logf("DisassembleFunction('Add') returned %d instructions", len(res.Instructions))

	// Check if any instruction belongs to AddExtra (lines 9-11) or SuperAdd (lines 14-16)
	// or comes from a runtime/stdlib file
	for _, inst := range res.Instructions {
		if !strings.HasSuffix(inst.Source, "main.go") {
			t.Errorf("LEAKED SYMBOL: Instruction from non-target file %q at line %d (op=%s %s)",
				inst.Source, inst.Line, inst.Mnemonic, inst.Operands)
		}
		if inst.Line >= 9 && inst.Line <= 16 {
			t.Errorf("LEAKED FUNCTION: Instruction from AddExtra/SuperAdd at line %d (op=%s %s)",
				inst.Line, inst.Mnemonic, inst.Operands)
		}
	}
}

// TestAdversarial_Disasm_CrossCompilationArchitectures verifies both ARM64 and AMD64
// disassemblies on the exact same functions and verifies architecture-specific opcodes.
func TestAdversarial_Disasm_CrossCompilationArchitectures(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module crossarch\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"//go:noinline",
		"func BitwiseTransform(x, y uint64) uint64 {",
		"\ta := x ^ y",
		"\tb := (x << 3) | (y >> 2)",
		"\treturn a + b",
		"}",
		"",
		"func main() {",
		"\tprintln(BitwiseTransform(123, 456))",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	// 1. Disassemble ARM64
	resARM64, err := DisassembleFunction(tmpDir, "BitwiseTransform", "arm64")
	if err != nil {
		t.Fatalf("arm64 disassembly failed: %v", err)
	}
	if len(resARM64.Instructions) == 0 {
		t.Fatalf("arm64 returned 0 instructions")
	}

	// Verify ARM64 specific instructions (e.g., EOR, ORR, ADD, RET, MOVD, LSL, LSR)
	foundARM64Op := false
	for _, inst := range resARM64.Instructions {
		m := inst.Mnemonic
		if strings.HasPrefix(m, "EOR") || strings.HasPrefix(m, "ORR") || strings.HasPrefix(m, "ADD") ||
			strings.HasPrefix(m, "MOVD") || strings.HasPrefix(m, "RET") {
			foundARM64Op = true
			break
		}
	}
	if !foundARM64Op {
		t.Errorf("expected ARM64 mnemonic, got instructions: %+v", resARM64.Instructions)
	}

	// 2. Disassemble AMD64
	resAMD64, err := DisassembleFunction(tmpDir, "BitwiseTransform", "amd64")
	if err != nil {
		t.Fatalf("amd64 disassembly failed: %v", err)
	}
	if len(resAMD64.Instructions) == 0 {
		t.Fatalf("amd64 returned 0 instructions")
	}

	// Verify AMD64 specific instructions (e.g., XORQ, SHLQ, SHRQ, ORQ, ADDQ, MOVQ, RET)
	foundAMD64Op := false
	for _, inst := range resAMD64.Instructions {
		m := inst.Mnemonic
		if strings.HasPrefix(m, "XOR") || strings.HasPrefix(m, "SHL") || strings.HasPrefix(m, "SHR") ||
			strings.HasPrefix(m, "OR") || strings.HasPrefix(m, "ADD") || strings.HasPrefix(m, "MOV") || strings.HasPrefix(m, "RET") {
			foundAMD64Op = true
			break
		}
	}
	if !foundAMD64Op {
		t.Errorf("expected AMD64 mnemonic, got instructions: %+v", resAMD64.Instructions)
	}

	// Line mapping check: both architectures should map back to lines 5, 6, 7
	for _, inst := range resARM64.Instructions {
		if inst.Line < 4 || inst.Line > 8 {
			t.Errorf("arm64 instruction mapped to out-of-bounds line %d", inst.Line)
		}
	}
	for _, inst := range resAMD64.Instructions {
		if inst.Line < 4 || inst.Line > 8 {
			t.Errorf("amd64 instruction mapped to out-of-bounds line %d", inst.Line)
		}
	}
}

// TestAdversarial_Disasm_FaultInjection tests compilation failures, invalid build tags,
// missing symbols, and non-existent files to ensure structured errors without crashes or process/file leaks.
func TestAdversarial_Disasm_FaultInjection(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	// Subcase 1: Syntax error
	t.Run("SyntaxError", func(t *testing.T) {
		tmpDir := t.TempDir()
		_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module broken\ngo 1.22\n"), 0644)
		_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc Bad() { return 1 + }\n"), 0644)

		res, err := DisassembleFunction(tmpDir, "Bad", "arm64")
		if err == nil {
			t.Errorf("expected error for syntax error package, got nil (res=%+v)", res)
		} else if !strings.Contains(err.Error(), "build failed") {
			t.Errorf("expected 'build failed' in error message, got %q", err.Error())
		}
	})

	// Subcase 2: Build tags excluding current arch
	t.Run("ExcludedBuildTag", func(t *testing.T) {
		tmpDir := t.TempDir()
		_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module tagged\ngo 1.22\n"), 0644)
		src := "//go:build windows\n\npackage main\nfunc WinOnly() {}\nfunc main() {}\n"
		_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644)

		res, err := DisassembleFunction(tmpDir, "WinOnly", "arm64")
		if err == nil {
			t.Errorf("expected error for excluded build tag, got nil (res=%+v)", res)
		} else if !strings.Contains(err.Error(), "build failed") {
			t.Errorf("expected 'build failed' in error, got %q", err.Error())
		}
	})

	// Subcase 3: Missing / non-existent symbol in valid package
	t.Run("MissingSymbol", func(t *testing.T) {
		tmpDir := t.TempDir()
		_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module validsym\ngo 1.22\n"), 0644)
		_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc RealFunc() {}\nfunc main() {}\n"), 0644)

		res, err := DisassembleFunction(tmpDir, "CompletelyBogusSymbol987", "arm64")
		if err != nil {
			t.Fatalf("unexpected error for missing symbol: %v", err)
		}
		if len(res.Instructions) != 0 {
			t.Errorf("expected 0 instructions for missing symbol, got %d", len(res.Instructions))
		}
	})

	// Subcase 4: Non-existent workspace/file path
	t.Run("NonExistentPath", func(t *testing.T) {
		bogusPath := filepath.Join(os.TempDir(), "golens_nonexistent_dir_123456789")
		_, err := DisassembleFunction(bogusPath, "AnyFunc", "arm64")
		if err == nil {
			t.Errorf("expected error for non-existent path")
		}
	})

	// Subcase 5: Empty directory without Go files
	t.Run("EmptyDir", func(t *testing.T) {
		tmpDir := t.TempDir()
		_, err := DisassembleFunction(tmpDir, "AnyFunc", "arm64")
		if err == nil {
			t.Errorf("expected error for empty directory without Go files")
		}
	})
}

// TestAdversarial_Disasm_TempFileCleanup verifies that no temporary binaries
// are leaked in os.TempDir() after successful or failed disassemblies.
func TestAdversarial_Disasm_TempFileCleanup(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module cleanuptest\ngo 1.22\n"), 0644)
	_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc Target() {}\nfunc main() {}\n"), 0644)

	// Measure temp binaries before
	pattern := filepath.Join(os.TempDir(), "golens_disasm_*")
	beforeMatches, _ := filepath.Glob(pattern)

	// Run successful disassembly
	_, err := DisassembleFunction(tmpDir, "Target", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}

	// Run failed disassembly
	_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc Bad() { broken syntax }\n"), 0644)
	_, _ = DisassembleFunction(tmpDir, "Bad", "arm64")

	// Measure temp binaries after
	afterMatches, _ := filepath.Glob(pattern)

	if len(afterMatches) > len(beforeMatches) {
		t.Errorf("LEAKED TEMP BINARIES: before=%d, after=%d (diff: %+v)",
			len(beforeMatches), len(afterMatches), afterMatches[len(beforeMatches):])
	}
}

// TestAdversarial_Disasm_ProcessIsolation_SetpgidAndTimeout verifies that process execution
// uses Setpgid: true and does not leave zombie or orphan toolchain processes after execution.
func TestAdversarial_Disasm_ProcessIsolation_SetpgidAndTimeout(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module isolation\ngo 1.22\n"), 0644)
	_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc Fast() int { return 1 }\nfunc main() {}\n"), 0644)

	// Verify normal execution leaves 0 orphan processes
	_, err := DisassembleFunction(tmpDir, "Fast", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}

	// Verify no orphan 'golens_disasm_' binary or orphan objdump reparented to launchd (PID 1)
	time.Sleep(50 * time.Millisecond)
	out, _ := exec.Command("pgrep", "-P", "1", "-f", "golens_disasm_").Output()
	if len(strings.TrimSpace(string(out))) > 0 {
		t.Errorf("LEAKED ORPHAN PROCESS: found running golens_disasm process: %s", string(out))
	}
}


// TestAdversarial_Escape_BCEDetection_EdgeCases stress tests bounds check elimination detection
// on dynamic indices, sub-slices, multidimensional slices, and guarded vs unguarded loops.
func TestAdversarial_Escape_BCEDetection_EdgeCases(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module bceedge\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package bceedge",
		"",
		"func DynamicIndex(s []int, i int) int {",
		"\treturn s[i]", // Line 4: should have BCE IsInBounds
		"}",
		"",
		"func SubSlice(s []int, i, j int) []int {",
		"\treturn s[i:j]", // Line 8: should have BCE IsSliceInBounds
		"}",
		"",
		"func MultiDim(grid [][]int, r, c int) int {",
		"\treturn grid[r][c]", // Line 12: should have 2 BCE IsInBounds
		"}",
		"",
		"func LoopUnguarded(s []int) int {",
		"\tsum := 0",
		"\tfor i := 0; i < 10; i++ {",
		"\t\tsum += s[i]", // Line 18: should have BCE IsInBounds
		"\t}",
		"\treturn sum",
		"}",
		"",
		"func LoopGuarded(s []int) int {",
		"\tif len(s) < 10 { return 0 }",
		"\t_ = s[9]", // Hint eliminates bounds check in loop below
		"\tsum := 0",
		"\tfor i := 0; i < 10; i++ {",
		"\t\tsum += s[i]", // Line 28: should NOT have BCE check!
		"\t}",
		"\treturn sum",
		"}",
		"",
	}, "\n")

	filePath := filepath.Join(tmpDir, "bce.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("failed to write bce.go: %v", err)
	}

	rawJSON, err := AnalyzeEscape(tmpDir, filePath)
	if err != nil {
		t.Fatalf("AnalyzeEscape failed: %v", err)
	}

	var res EscapeAnalysisResult
	if err := json.Unmarshal([]byte(rawJSON), &res); err != nil {
		t.Fatalf("json unmarshal failed: %v (raw=%s)", err, rawJSON)
	}

	t.Logf("AnalyzeEscape returned %d items:", len(res.Items))
	for _, it := range res.Items {
		t.Logf("  L%d:%d [%s/%s] %s (hint=%s)", it.Line, it.Col, it.Kind, it.Category, it.Summary, it.Hint)
	}

	// 1. Dynamic index at line 4: MUST be detected as bce_check
	foundLine4 := false
	for _, it := range res.Items {
		if it.Line == 4 && it.Category == "bce_check" {
			foundLine4 = true
			if !strings.Contains(it.Hint, "maxIdx") {
				t.Errorf("line 4 BCE hint missing maxIdx recommendation: %q", it.Hint)
			}
		}
	}
	if !foundLine4 {
		t.Errorf("MISSING BCE CHECK: Expected BCE check on line 4 for dynamic slice index s[i]")
	}

	// 2. Subslice at line 8: MUST be detected as bce_check
	foundLine8 := false
	for _, it := range res.Items {
		if it.Line == 8 && it.Category == "bce_check" {
			foundLine8 = true
		}
	}
	if !foundLine8 {
		t.Errorf("MISSING BCE CHECK: Expected BCE check on line 8 for subslice s[i:j]")
	}

	// 3. MultiDim at line 12: MUST be detected as bce_check
	foundLine12 := false
	for _, it := range res.Items {
		if it.Line == 12 && it.Category == "bce_check" {
			foundLine12 = true
		}
	}
	if !foundLine12 {
		t.Errorf("MISSING BCE CHECK: Expected BCE check on line 12 for grid[r][c]")
	}

	// 4. Loop unguarded at line 18: MUST be detected as bce_check
	foundLine18 := false
	for _, it := range res.Items {
		if it.Line == 18 && it.Category == "bce_check" {
			foundLine18 = true
		}
	}
	if !foundLine18 {
		t.Errorf("MISSING BCE CHECK: Expected BCE check on line 18 for unguarded loop s[i]")
	}

	// 5. Loop guarded at line 28: MUST be eliminated by Go compiler!
	for _, it := range res.Items {
		if it.Line == 28 && it.Category == "bce_check" {
			t.Errorf("FALSE POSITIVE BCE CHECK: Loop guarded with length check should have eliminated BCE on line 28, but got: %+v", it)
		}
	}
}

// TestAdversarial_Escape_BCE_SyntheticMessages tests BCE classification resilience
// against various compiler message formats including 'Found check' and 'Found IsInBounds'.
func TestAdversarial_Escape_BCE_SyntheticMessages(t *testing.T) {
	testCases := []struct {
		name         string
		rawMsg       string
		wantCategory string
	}{
		{"IsInBounds", "./foo.go:10:5: Found IsInBounds", "bce_check"},
		{"IsSliceInBounds", "./foo.go:12:8: Found IsSliceInBounds", "bce_check"},
		{"FoundCheckColloquial", "./foo.go:14:2: Found check (IsInBounds)", "bce_check"},
		{"CannotInlineBudget", "./foo.go:20:6: cannot inline HugeFunc: function too complex", "inline_blocked"},
		{"MovedToHeap", "./foo.go:25:9: moved to heap: buffer", "escape"},
		{"EscapesToHeap", "./foo.go:30:12: &MyStruct{...} escapes to heap", "escape"},
		{"LeakingParam", "./foo.go:35:10: leaking param: ctx to result", "leak"},
		{"CanInline", "./foo.go:40:6: can inline ShortFunc", "inline_ok"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			items := ParseEscapeOutput(tc.rawMsg, "/workspace", "")
			if tc.wantCategory == "" {
				if len(items) > 0 {
					t.Errorf("expected 0 items, got %d: %+v", len(items), items)
				}
				return
			}
			if len(items) != 1 {
				t.Fatalf("expected 1 item, got %d: %+v", len(items), items)
			}
			if items[0].Category != tc.wantCategory {
				t.Errorf("item.Category = %q; want %q", items[0].Category, tc.wantCategory)
			}
		})
	}
}

// TestAdversarial_Disasm_ParseObjdumpOutput_ShortOutputBypass demonstrates the flaw in
// disasm.go line 122: `if !inTargetFunction && len(lines) > 50 { continue }`.
// When total objdump lines <= 50, all functions in the output are included in the result!
func TestAdversarial_Disasm_ParseObjdumpOutput_ShortOutputBypass(t *testing.T) {
	raw := `
TEXT main.Target(SB) /workspace/main.go
  main.go:5		0x1000		0000		MOVD $1, R0
TEXT main.OtherFunction(SB) /workspace/main.go
  main.go:10	0x2000		0000		MOVD $2, R0
`
	res, err := parseObjdumpOutput(raw, "Target", "arm64")
	if err != nil {
		t.Fatalf("parseObjdumpOutput failed: %v", err)
	}

	for _, inst := range res.Instructions {
		if inst.Line == 10 {
			t.Errorf("BUG DETECTED (Short Output Bypass): parseObjdumpOutput included instruction from 'OtherFunction' (line 10) because total lines <= 50! Got: %+v", inst)
		}
	}
}

