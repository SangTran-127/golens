package goast

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

func TestExtractMethod_FreeFunction(t *testing.T) {
	src := `package billing

import "fmt"

func formatLabel(prefix string) string {
	return prefix + ":"
}

func CalculateInvoice(base int, taxRate int) (string, int) {
	prefix := "INV"
	label := formatLabel(prefix)
	total := base + (base * taxRate / 100)
	summary := fmt.Sprintf("%s %d", label, total)
	return summary, total
}
`
	selText := "total := base + (base * taxRate / 100)\n\tsummary := fmt.Sprintf(\"%s %d\", label, total)"
	startByte := strings.Index(src, selText)
	if startByte < 0 {
		t.Fatalf("failed to find selection in src")
	}
	endByte := startByte + len(selText)

	inspectReply := InspectExtractMethod(ExtractMethodReq{
		Path:      "/proj/billing.go",
		Src:       src,
		StartByte: startByte,
		EndByte:   endByte,
	})
	if inspectReply.Error != "" {
		t.Fatalf("unexpected inspect error: %s", inspectReply.Error)
	}
	if inspectReply.Receiver != "" {
		t.Fatalf("expected empty receiver for free function, got %q", inspectReply.Receiver)
	}
	if inspectReply.DefaultName != "extractedFunc" {
		t.Fatalf("expected defaultName 'extractedFunc', got %q", inspectReply.DefaultName)
	}
	wantSig := "func extractedFunc(base int, taxRate int, label string) (int, string)"
	if inspectReply.PreviewSignature != wantSig {
		t.Fatalf("PreviewSignature = %q, want %q", inspectReply.PreviewSignature, wantSig)
	}
	wantCall := "total, summary := extractedFunc(base, taxRate, label)"
	if inspectReply.PreviewCall != wantCall {
		t.Fatalf("PreviewCall = %q, want %q", inspectReply.PreviewCall, wantCall)
	}

	reqBytes, _ := json.Marshal(ExtractMethodReq{
		Path:      "/proj/billing.go",
		Src:       src,
		StartByte: inspectReply.StartByte,
		EndByte:   inspectReply.EndByte,
		FuncName:  "buildInvoiceSummary",
	})
	rawApply := ApplyExtractMethodJSON(string(reqBytes))
	var applyReply ExtractMethodReply
	if err := json.Unmarshal([]byte(rawApply), &applyReply); err != nil {
		t.Fatalf("unmarshal apply reply failed: %v", err)
	}
	if applyReply.Error != "" {
		t.Fatalf("unexpected apply error: %s", applyReply.Error)
	}

	edits := applyReply.EditsByPath["/proj/billing.go"]
	if len(edits) != 2 {
		t.Fatalf("expected 2 edits, got %d", len(edits))
	}

	updated := applyEditsToText(src, edits)
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "/proj/billing.go", updated, parser.AllErrors); err != nil {
		t.Fatalf("updated code failed to parse: %v\ncode:\n%s", err, updated)
	}

	wantUpdated := `package billing

import "fmt"

func formatLabel(prefix string) string {
	return prefix + ":"
}

func CalculateInvoice(base int, taxRate int) (string, int) {
	prefix := "INV"
	label := formatLabel(prefix)
	total, summary := buildInvoiceSummary(base, taxRate, label)
	return summary, total
}

func buildInvoiceSummary(base int, taxRate int, label string) (int, string) {
	total := base + (base * taxRate / 100)
	summary := fmt.Sprintf("%s %d", label, total)
	return total, summary
}
`
	if updated != wantUpdated {
		t.Fatalf("updated code mismatch:\ngot:\n%s\nwant:\n%s", updated, wantUpdated)
	}
}

func TestExtractMethod_StructMethodPreservesReceiver(t *testing.T) {
	src := `package account

import "fmt"

type Account struct {
	Owner   string
	Balance int
}

func (a *Account) Deposit(amount int) error {
	if amount <= 0 {
		return fmt.Errorf("invalid amount: %d", amount)
	}
	a.Balance += amount
	err := a.validate()
	if err != nil {
		return err
	}
	return nil
}

func (a *Account) validate() error {
	return nil
}
`
	selText := "a.Balance += amount\n\terr := a.validate()"
	startByte := strings.Index(src, selText)
	endByte := startByte + len(selText)

	reply := ApplyExtractMethod(ExtractMethodReq{
		Path:      "/proj/account.go",
		Src:       src,
		StartByte: startByte,
		EndByte:   endByte,
		FuncName:  "applyDeposit",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.Receiver != "a *Account" {
		t.Fatalf("expected receiver 'a *Account', got %q", reply.Receiver)
	}
	wantSig := "func (a *Account) applyDeposit(amount int) error"
	if reply.PreviewSignature != wantSig {
		t.Fatalf("PreviewSignature = %q, want %q", reply.PreviewSignature, wantSig)
	}
	wantCall := "err := a.applyDeposit(amount)"
	if reply.PreviewCall != wantCall {
		t.Fatalf("PreviewCall = %q, want %q", reply.PreviewCall, wantCall)
	}

	updated := applyEditsToText(src, reply.EditsByPath["/proj/account.go"])
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "/proj/account.go", updated, parser.AllErrors); err != nil {
		t.Fatalf("updated code failed to parse: %v\ncode:\n%s", err, updated)
	}
	if !strings.Contains(updated, "err := a.applyDeposit(amount)") {
		t.Fatalf("expected method call on receiver in updated code:\n%s", updated)
	}
	if !strings.Contains(updated, "func (a *Account) applyDeposit(amount int) error {\n\ta.Balance += amount\n\terr := a.validate()\n\treturn err\n}") {
		t.Fatalf("expected extracted method body in updated code:\n%s", updated)
	}
}

func TestExtractVariable_SelectionAndCursor(t *testing.T) {
	src := `package calc

type Service struct{}

func (s *Service) ComputeTotal(a, b int) int {
	return a + b
}

func Run(s *Service, x int) int {
	res := s.ComputeTotal(x, 10) + 5
	return res
}
`
	exprStr := "s.ComputeTotal(x, 10)"
	startByte := strings.Index(src, exprStr)
	endByte := startByte + len(exprStr)

	reply := ApplyExtractVariable(ExtractVarReq{
		Path:      "/proj/calc.go",
		Src:       src,
		StartByte: startByte,
		EndByte:   endByte,
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.VarName != "total" {
		t.Fatalf("expected smart variable name 'total', got %q", reply.VarName)
	}

	updated := applyEditsToText(src, reply.EditsByPath["/proj/calc.go"])
	wantUpdated := `package calc

type Service struct{}

func (s *Service) ComputeTotal(a, b int) int {
	return a + b
}

func Run(s *Service, x int) int {
	total := s.ComputeTotal(x, 10)
	res := total + 5
	return res
}
`
	if updated != wantUpdated {
		t.Fatalf("updated code mismatch:\ngot:\n%s\nwant:\n%s", updated, wantUpdated)
	}

	cursorOffset := strings.Index(updated, "total + 5") + 3
	cursorReply := ApplyExtractVariable(ExtractVarReq{
		Path:      "/proj/calc.go",
		Src:       updated,
		StartByte: cursorOffset,
		EndByte:   cursorOffset,
		VarName:   "sumWithBonus",
	})
	if cursorReply.Error != "" {
		t.Fatalf("unexpected error at cursor: %s", cursorReply.Error)
	}
	updated2 := applyEditsToText(updated, cursorReply.EditsByPath["/proj/calc.go"])
	if !strings.Contains(updated2, "\tsumWithBonus := total + 5\n\tres := sumWithBonus\n") {
		t.Fatalf("unexpected second extraction:\n%s", updated2)
	}
}

func TestExtractInlineVariable_RoundTripAndPrecedence(t *testing.T) {
	src := `package mathutil

func Scale(a, b, factor int) int {
	sum := a + b
	scaled := sum * factor
	return scaled + sum
}
`
	offset := strings.Index(src, "sum := a + b")
	reqJSON, _ := json.Marshal(InlineVarReq{
		Path:   "/proj/math.go",
		Src:    src,
		Offset: offset,
	})
	rawReply := ApplyInlineVariableJSON(string(reqJSON))
	var reply ExtractVarReply
	if err := json.Unmarshal([]byte(rawReply), &reply); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if reply.Error != "" {
		t.Fatalf("unexpected inline error: %s", reply.Error)
	}
	if reply.VarName != "sum" {
		t.Fatalf("expected VarName 'sum', got %q", reply.VarName)
	}

	updated := applyEditsToText(src, reply.EditsByPath["/proj/math.go"])
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "/proj/math.go", updated, parser.AllErrors); err != nil {
		t.Fatalf("inlined code failed to parse: %v\ncode:\n%s", err, updated)
	}

	wantUpdated := `package mathutil

func Scale(a, b, factor int) int {
	scaled := (a + b) * factor
	return scaled + (a + b)
}
`
	if updated != wantUpdated {
		t.Fatalf("inlined code mismatch:\ngot:\n%s\nwant:\n%s", updated, wantUpdated)
	}
}

func TestInlineVariableRejectsSideEffectingCallDuplication(t *testing.T) {
	src := `package counter

var seq int

func next() int {
	seq++
	return seq
}

func DoubleNext() int {
	x := next()
	return x + x
}
`
	offset := strings.Index(src, "x := next()")
	reply := ApplyInlineVariable(InlineVarReq{
		Path:   "/proj/counter.go",
		Src:    src,
		Offset: offset,
	})
	if reply.Error == "" {
		t.Fatalf("expected error when inlining side-effecting call into multiple usages, got edits: %+v", reply.EditsByPath)
	}
	if !strings.Contains(reply.Error, "cannot inline variable initialized with a function call or side-effecting expression into multiple usages") {
		t.Fatalf("unexpected error message: %q", reply.Error)
	}
	if len(reply.EditsByPath) != 0 {
		t.Fatalf("expected no edits when inline is rejected, got %+v", reply.EditsByPath)
	}
}

func TestInlineVariableRejectsInterveningStateAndVariableMutation(t *testing.T) {
	t.Run("call_with_intervening_statement", func(t *testing.T) {
		src := `package main

var state int

func next() int {
	state++
	return state
}

func f() int {
	x := next()
	state = 10
	return x
}
`
		reply := ApplyInlineVariable(InlineVarReq{
			Path:   "/tmp/inline.go",
			Src:    src,
			Offset: strings.Index(src, "x :="),
		})
		if reply.Error == "" {
			t.Fatalf("expected error when inlining x := next() across state = 10, got edits: %+v", reply.EditsByPath)
		}
		if len(reply.EditsByPath) != 0 {
			t.Fatalf("expected no edits when inline is rejected, got %+v", reply.EditsByPath)
		}
	})

	t.Run("referenced_var_mutated_before_use", func(t *testing.T) {
		src := `package main

func f() int {
	v := 1
	x := v
	v = 2
	return x
}
`
		reply := ApplyInlineVariable(InlineVarReq{
			Path:   "/tmp/inline.go",
			Src:    src,
			Offset: strings.Index(src, "x :="),
		})
		if reply.Error == "" {
			t.Fatalf("expected error when inlining x := v across v = 2, got edits: %+v", reply.EditsByPath)
		}
		if !strings.Contains(reply.Error, "modified before usage") {
			t.Fatalf("unexpected error message: %q", reply.Error)
		}
		if len(reply.EditsByPath) != 0 {
			t.Fatalf("expected no edits when inline is rejected, got %+v", reply.EditsByPath)
		}
	})
}

