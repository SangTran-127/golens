package goast

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
)

// TestAdversarial_Escape_ConcurrentStress tests AnalyzeEscape under concurrent multi-goroutine
// execution to verify cancellation single-flighting and race detector cleanliness.
func TestAdversarial_Escape_ConcurrentStress(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte("module stress\ngo 1.22\n"), 0644)
	_ = os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte("package main\nfunc Compute(x int) *int { return &x }\nfunc main() {}\n"), 0644)

	filePath := filepath.Join(tmpDir, "main.go")

	errCh := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() {
			out, err := AnalyzeEscape(tmpDir, filePath)
			if err != nil {
				errCh <- fmt.Errorf("AnalyzeEscape error: %w", err)
				return
			}
			var res EscapeAnalysisResult
			if err := json.Unmarshal([]byte(out), &res); err != nil {
				errCh <- fmt.Errorf("json unmarshal failed: %w (out=%s)", err, out)
				return
			}
			errCh <- nil
		}()
	}

	for i := 0; i < 8; i++ {
		if err := <-errCh; err != nil {
			t.Errorf("concurrent AnalyzeEscape error: %v", err)
		}
	}
}

// TestAdversarial_Disasm_ReceiverMethods_PointerAndValue tests disassembling functions with receiver
// methods: (*Type).Method (pointer receiver) and Type.Method (value receiver).
func TestAdversarial_Disasm_ReceiverMethods_PointerAndValue(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module receivertest\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"type Service struct {",
		"\tid int",
		"}",
		"",
		"type Client struct {",
		"\ttoken string",
		"}",
		"",
		"//go:noinline",
		"func (s *Service) Execute() int {",
		"\treturn s.id + 10",
		"}",
		"",
		"//go:noinline",
		"func (s Service) ValueExecute() int {",
		"\treturn s.id + 20",
		"}",
		"",
		"//go:noinline",
		"func (c *Client) Execute() int {",
		"\treturn len(c.token) + 30",
		"}",
		"",
		"//go:noinline",
		"func Execute() int {",
		"\treturn 40",
		"}",
		"",
		"func main() {",
		"\ts := &Service{id: 1}",
		"\tc := &Client{token: \"abc\"}",
		"\tprintln(s.Execute())",
		"\tprintln(s.ValueExecute())",
		"\tprintln(c.Execute())",
		"\tprintln(Execute())",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	for _, arch := range []string{"arm64", "amd64"} {
		t.Run("PointerReceiver_Service_Execute_"+arch, func(t *testing.T) {
			res, err := DisassembleFunction(tmpDir, "(*Service).Execute", arch)
			if err != nil {
				t.Fatalf("DisassembleFunction('(*Service).Execute') failed: %v", err)
			}
			if len(res.Instructions) == 0 {
				t.Fatalf("expected instructions for (*Service).Execute, got 0")
			}
			for _, inst := range res.Instructions {
				if !strings.HasSuffix(inst.Source, "main.go") {
					t.Errorf("leaked instruction from foreign file: %s", inst.Source)
				}
				// Lines 12-14 are (s *Service) Execute()
				if inst.Line < 12 || inst.Line > 14 {
					t.Errorf("leaked instruction outside (*Service).Execute: line %d (op=%s %s)",
						inst.Line, inst.Mnemonic, inst.Operands)
				}
			}
		})

		t.Run("ValueReceiver_Service_ValueExecute_"+arch, func(t *testing.T) {
			res, err := DisassembleFunction(tmpDir, "Service.ValueExecute", arch)
			if err != nil {
				t.Fatalf("DisassembleFunction('Service.ValueExecute') failed: %v", err)
			}
			if len(res.Instructions) == 0 {
				t.Fatalf("expected instructions for Service.ValueExecute, got 0")
			}
			for _, inst := range res.Instructions {
				if !strings.HasSuffix(inst.Source, "main.go") {
					t.Errorf("leaked instruction from foreign file: %s", inst.Source)
				}
				// Lines 17-19 are (s Service) ValueExecute()
				if inst.Line < 17 || inst.Line > 19 {
					t.Errorf("leaked instruction outside Service.ValueExecute: line %d (op=%s %s)",
						inst.Line, inst.Mnemonic, inst.Operands)
				}
			}
		})

		t.Run("PointerReceiver_Client_Execute_"+arch, func(t *testing.T) {
			res, err := DisassembleFunction(tmpDir, "(*Client).Execute", arch)
			if err != nil {
				t.Fatalf("DisassembleFunction('(*Client).Execute') failed: %v", err)
			}
			if len(res.Instructions) == 0 {
				t.Fatalf("expected instructions for (*Client).Execute, got 0")
			}
			for _, inst := range res.Instructions {
				if !strings.HasSuffix(inst.Source, "main.go") {
					t.Errorf("leaked instruction from foreign file: %s", inst.Source)
				}
				// Lines 22-24 are (c *Client) Execute()
				if inst.Line < 22 || inst.Line > 24 {
					t.Errorf("leaked instruction outside (*Client).Execute: line %d (op=%s %s)",
						inst.Line, inst.Mnemonic, inst.Operands)
				}
			}
		})
	}
}

// TestAdversarial_Disasm_ShortPrefixAndSubstringCollisions tests functions with short ubiquitous names
// (Init, Get, Len, Close) that are prefixes or substrings of sibling functions or runtime functions.
func TestAdversarial_Disasm_ShortPrefixAndSubstringCollisions(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module shortnamecollision\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"type Closer struct{}",
		"",
		"//go:noinline",
		"func Init() int { return 1 }",
		"",
		"//go:noinline",
		"func Initialize() int { return 2 }",
		"",
		"//go:noinline",
		"func Reinit() int { return 3 }",
		"",
		"//go:noinline",
		"func SuperInit() int { return 4 }",
		"",
		"//go:noinline",
		"func Get() int { return 10 }",
		"",
		"//go:noinline",
		"func GetUser() int { return 20 }",
		"",
		"//go:noinline",
		"func TargetGet() int { return 30 }",
		"",
		"//go:noinline",
		"func Forget() int { return 40 }",
		"",
		"//go:noinline",
		"func Len() int { return 100 }",
		"",
		"//go:noinline",
		"func Length() int { return 200 }",
		"",
		"//go:noinline",
		"func TotalLen() int { return 300 }",
		"",
		"//go:noinline",
		"func Close() int { return 1000 }",
		"",
		"//go:noinline",
		"func CloseAll() int { return 2000 }",
		"",
		"//go:noinline",
		"func Unclose() int { return 3000 }",
		"",
		"//go:noinline",
		"func (c *Closer) Close() int { return 4000 }",
		"",
		"//go:noinline",
		"func (c *Closer) CloseAll() int { return 5000 }",
		"",
		"func main() {",
		"\tc := &Closer{}",
		"\tprintln(Init() + Initialize() + Reinit() + SuperInit())",
		"\tprintln(Get() + GetUser() + TargetGet() + Forget())",
		"\tprintln(Len() + Length() + TotalLen())",
		"\tprintln(Close() + CloseAll() + Unclose() + c.Close() + c.CloseAll())",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	testCases := []struct {
		targetFunc   string
		startLine    int
		endLine      int
		siblingLines []int
	}{
		{"Init", 6, 6, []int{9, 12, 15}},
		{"Get", 18, 18, []int{21, 24, 27}},
		{"Len", 30, 30, []int{33, 36}},
		{"Close", 39, 39, []int{42, 45, 48, 51}},
		{"(*Closer).Close", 48, 48, []int{39, 42, 45, 51}},
	}

	for _, tc := range testCases {
		t.Run("Target_"+tc.targetFunc, func(t *testing.T) {
			res, err := DisassembleFunction(tmpDir, tc.targetFunc, "arm64")
			if err != nil {
				t.Fatalf("DisassembleFunction(%q) failed: %v", tc.targetFunc, err)
			}
			if len(res.Instructions) == 0 {
				t.Fatalf("expected instructions for %q, got 0", tc.targetFunc)
			}

			for _, inst := range res.Instructions {
				if !strings.HasSuffix(inst.Source, "main.go") {
					t.Errorf("LEAKED SYMBOL: Instruction from non-target file %q at line %d (op=%s %s)",
						inst.Source, inst.Line, inst.Mnemonic, inst.Operands)
				}
				for _, sibLine := range tc.siblingLines {
					if inst.Line == sibLine {
						t.Errorf("LEAKED FUNCTION: Instruction from sibling function at line %d (op=%s %s) while querying %q",
							inst.Line, inst.Mnemonic, inst.Operands, tc.targetFunc)
					}
				}
			}
		})
	}
}

// TestAdversarial_Disasm_ProcessIsolation_And_TempFileCleanup_Stress stress tests process isolation
// (Setpgid: true and SIGKILL) and temporary file cleanup under high concurrency and fault injection.
func TestAdversarial_Disasm_ProcessIsolation_And_TempFileCleanup_Stress(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module stressproc\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := `package main
//go:noinline
func Work(n int) int {
	res := 0
	for i := 0; i < n*100; i++ {
		res += (i ^ 42)
	}
	return res
}
func main() { println(Work(10)) }
`
	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	listTempBinaries := func() []string {
		entries, err := os.ReadDir(os.TempDir())
		if err != nil {
			return nil
		}
		var files []string
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), "golens_disasm_") {
				files = append(files, e.Name())
			}
		}
		return files
	}

	preFiles := listTempBinaries()
	preCount := len(preFiles)

	const concurrency = 10
	var wg sync.WaitGroup
	wg.Add(concurrency)

	for i := 0; i < concurrency; i++ {
		go func(workerID int) {
			defer wg.Done()
			arch := "arm64"
			if workerID%2 == 1 {
				arch = "amd64"
			}
			res, err := DisassembleFunction(tmpDir, "Work", arch)
			if err != nil {
				t.Errorf("worker %d failed: %v", workerID, err)
				return
			}
			if len(res.Instructions) == 0 {
				t.Errorf("worker %d returned 0 instructions", workerID)
			}
		}(i)
	}

	wg.Wait()

	// Wait 200ms to ensure all deferred cleanups have finished
	time.Sleep(200 * time.Millisecond)

	postFiles := listTempBinaries()
	postCount := len(postFiles)
	if postCount > preCount {
		t.Errorf("LEAKED TEMP BINARIES: pre=%v, post=%v (leaked %d files)",
			preFiles, postFiles, postCount-preCount)
	}

	// Verify no orphaned 'go tool objdump' or 'golens_disasm_' processes exist
	out, err := exec.Command("pgrep", "-f", "golens_disasm").CombinedOutput()
	if err == nil && len(strings.TrimSpace(string(out))) > 0 {
		pids := strings.Fields(string(out))
		var psInfo []string
		for _, pidStr := range pids {
			info, _ := exec.Command("ps", "-o", "pid,ppid,stat,command", "-p", pidStr).CombinedOutput()
			psInfo = append(psInfo, string(info))
		}
		// If still alive after grace period, fail
		time.Sleep(300 * time.Millisecond)
		out2, err2 := exec.Command("pgrep", "-f", "golens_disasm").CombinedOutput()
		if err2 == nil && len(strings.TrimSpace(string(out2))) > 0 {
			t.Errorf("TRUE ORPHAN PROCESSES DETECTED for golens_disasm (lingering after grace period):\nInitial:\n%s\nStill alive:\n%s",
				strings.Join(psInfo, "\n"), string(out2))
		} else {
			t.Logf("Transient process observed during exit transition (resolved within 300ms):\n%s", strings.Join(psInfo, "\n"))
		}
	}
}

// TestAdversarial_Disasm_BoundaryEdgeCases_ValueReceivers_Unicode tests value receiver methods,
// unparenthesized pointer queries (*Type.Method), and Unicode identifiers under cross-compilation.
func TestAdversarial_Disasm_BoundaryEdgeCases_ValueReceivers_Unicode(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module boundarytest\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package main",
		"",
		"type ValueNode struct {",
		"\tid int",
		"}",
		"",
		"type PtrNode struct {",
		"\tid int",
		"}",
		"",
		"//go:noinline",
		"func Len() int {",
		"\treturn 100",
		"}",
		"",
		"//go:noinline",
		"func (n ValueNode) Len() int {",
		"\treturn n.id + 200",
		"}",
		"",
		"//go:noinline",
		"func (p *PtrNode) Len() int {",
		"\treturn p.id + 300",
		"}",
		"",
		"//go:noinline",
		"func Close() int {",
		"\treturn 1000",
		"}",
		"",
		"//go:noinline",
		"func (n ValueNode) Close() int {",
		"\treturn n.id + 2000",
		"}",
		"",
		"//go:noinline",
		"func (p *PtrNode) Close() int {",
		"\treturn p.id + 3000",
		"}",
		"",
		"//go:noinline",
		"func 計算_Total(a, b int) int {",
		"\treturn a + b + 99",
		"}",
		"",
		"//go:noinline",
		"func Transform_λ(x int) int {",
		"\treturn x * 7",
		"}",
		"",
		"func main() {",
		"\tvn := ValueNode{id: 1}",
		"\tpn := &PtrNode{id: 2}",
		"\tprintln(Len() + vn.Len() + pn.Len())",
		"\tprintln(Close() + vn.Close() + pn.Close())",
		"\tprintln(計算_Total(10, 20) + Transform_λ(5))",
		"}",
		"",
	}, "\n")

	if err := os.WriteFile(filepath.Join(tmpDir, "main.go"), []byte(src), 0644); err != nil {
		t.Fatalf("failed to write main.go: %v", err)
	}

	cases := []struct {
		name           string
		query          string
		minLine        int
		maxLine        int
		forbiddenLines []int
	}{
		{
			name:           "Standalone_Len",
			query:          "Len",
			minLine:        12,
			maxLine:        14,
			forbiddenLines: []int{17, 18, 19, 22, 23, 24},
		},
		{
			name:           "ValueReceiver_ValueNode_Len",
			query:          "ValueNode.Len",
			minLine:        17,
			maxLine:        19,
			forbiddenLines: []int{12, 13, 14, 22, 23, 24},
		},
		{
			name:           "PointerReceiver_PtrNode_Len_Parenthesized",
			query:          "(*PtrNode).Len",
			minLine:        22,
			maxLine:        24,
			forbiddenLines: []int{12, 13, 14, 17, 18, 19},
		},
		{
			name:           "Standalone_Close",
			query:          "Close",
			minLine:        27,
			maxLine:        29,
			forbiddenLines: []int{32, 33, 34, 37, 38, 39},
		},
		{
			name:           "ValueReceiver_ValueNode_Close",
			query:          "ValueNode.Close",
			minLine:        32,
			maxLine:        34,
			forbiddenLines: []int{27, 28, 29, 37, 38, 39},
		},
		{
			name:           "PointerReceiver_PtrNode_Close_Unparenthesized",
			query:          "*PtrNode.Close",
			minLine:        37,
			maxLine:        39,
			forbiddenLines: []int{27, 28, 29, 32, 33, 34},
		},
		{
			name:           "Unicode_Chinese_Identifier",
			query:          "計算_Total",
			minLine:        42,
			maxLine:        44,
			forbiddenLines: []int{12, 13, 14, 17, 18, 19, 22, 23, 24, 27, 28, 29, 32, 33, 34, 37, 38, 39, 47, 48, 49},
		},
		{
			name:           "Unicode_Greek_Identifier",
			query:          "Transform_λ",
			minLine:        47,
			maxLine:        49,
			forbiddenLines: []int{12, 13, 14, 17, 18, 19, 22, 23, 24, 27, 28, 29, 32, 33, 34, 37, 38, 39, 42, 43, 44},
		},
	}

	for _, tc := range cases {
		for _, arch := range []string{"arm64", "amd64"} {
			subName := fmt.Sprintf("%s_%s", tc.name, arch)
			t.Run(subName, func(t *testing.T) {
				res, err := DisassembleFunction(tmpDir, tc.query, arch)
				if err != nil {
					t.Fatalf("DisassembleFunction(%q, %s) failed: %v", tc.query, arch, err)
				}
				if len(res.Instructions) == 0 {
					t.Fatalf("expected instructions for query %q on %s, got 0", tc.query, arch)
				}

				foundTarget := false
				for _, inst := range res.Instructions {
					if !strings.HasSuffix(inst.Source, "main.go") {
						t.Errorf("LEAKED SYMBOL: Instruction from foreign file %q at line %d (op=%s %s)",
							inst.Source, inst.Line, inst.Mnemonic, inst.Operands)
					}
					if inst.Line >= tc.minLine && inst.Line <= tc.maxLine {
						foundTarget = true
					}
					for _, forb := range tc.forbiddenLines {
						if inst.Line == forb {
							t.Errorf("LEAKED FUNCTION: Instruction from sibling line %d while querying %q (%s)",
								inst.Line, tc.query, subName)
						}
					}
				}
				if !foundTarget {
					t.Errorf("Did not find instruction mapped to target lines [%d..%d] for query %q (%s)",
						tc.minLine, tc.maxLine, tc.query, subName)
				}
			})
		}
	}
}


