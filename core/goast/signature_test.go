package goast

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

func applyEditsToText(src string, edits []SigTextEdit) string {
	lines := strings.Split(src, "\n")
	lineStarts := make([]int, len(lines))
	off := 0
	for i, l := range lines {
		lineStarts[i] = off
		off += len(l) + 1
	}
	posToOffset := func(p LSPWirePos) int {
		if p.Line < 0 {
			return 0
		}
		if p.Line >= len(lines) {
			return len(src)
		}
		lineBytes := []byte(lines[p.Line])
		u16 := 0
		bIdx := 0
		for bIdx < len(lineBytes) && u16 < p.Character {
			_, rLen := utf8.DecodeRune(lineBytes[bIdx:])
			u16 += utf16Len(lineBytes[bIdx : bIdx+rLen])
			bIdx += rLen
		}
		return lineStarts[p.Line] + bIdx
	}

	type byteEdit struct {
		start int
		end   int
		text  string
	}
	resolved := make([]byteEdit, len(edits))
	for i, e := range edits {
		resolved[i] = byteEdit{
			start: posToOffset(e.Range.Start),
			end:   posToOffset(e.Range.End),
			text:  e.NewText,
		}
	}
	sort.Slice(resolved, func(i, j int) bool {
		if resolved[i].start != resolved[j].start {
			return resolved[i].start > resolved[j].start
		}
		return resolved[i].end > resolved[j].end
	})
	out := src
	for _, e := range resolved {
		out = out[:e.start] + e.text + out[e.end:]
	}
	return out
}

func TestInspectFuncSignature_FuncAndMethod(t *testing.T) {
	src := []byte(`package demo

type Server struct{}

func Calculate(a, b int, label string) (int, error) {
	return a + b, nil
}

func (s *Server) Handle(req string) (res string, err error) {
	return req, nil
}
`)

	calcIdx := strings.Index(string(src), "Calculate")
	raw := InspectFuncSignature("/proj/demo.go", src, calcIdx)
	if raw == "" {
		t.Fatalf("expected non-empty signature JSON for Calculate")
	}
	var spec FuncSignatureSpec
	if err := json.Unmarshal([]byte(raw), &spec); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if spec.Name != "Calculate" || spec.OrigName != "Calculate" {
		t.Fatalf("unexpected name: %+v", spec)
	}
	if spec.Receiver != "" {
		t.Fatalf("expected empty receiver, got %q", spec.Receiver)
	}
	if spec.NameLine != 5 || spec.NameCol != 6 {
		t.Fatalf("expected line 5 col 6, got line %d col %d", spec.NameLine, spec.NameCol)
	}
	if len(spec.Params) != 3 {
		t.Fatalf("expected 3 flattened params, got %d: %+v", len(spec.Params), spec.Params)
	}
	if spec.Params[0].Name != "a" || spec.Params[0].Type != "int" || spec.Params[0].OrigIndex != 0 {
		t.Fatalf("unexpected param 0: %+v", spec.Params[0])
	}
	if spec.Params[1].Name != "b" || spec.Params[1].Type != "int" || spec.Params[1].OrigIndex != 1 {
		t.Fatalf("unexpected param 1: %+v", spec.Params[1])
	}
	if spec.Params[2].Name != "label" || spec.Params[2].Type != "string" || spec.Params[2].OrigIndex != 2 {
		t.Fatalf("unexpected param 2: %+v", spec.Params[2])
	}
	if len(spec.Results) != 2 || spec.Results[0].Type != "int" || spec.Results[1].Type != "error" {
		t.Fatalf("unexpected results: %+v", spec.Results)
	}

	handleIdx := strings.Index(string(src), "Handle")
	rawMethod := InspectFuncSignature("/proj/demo.go", src, handleIdx)
	if rawMethod == "" {
		t.Fatalf("expected non-empty signature JSON for Handle")
	}
	var methodSpec FuncSignatureSpec
	if err := json.Unmarshal([]byte(rawMethod), &methodSpec); err != nil {
		t.Fatalf("unmarshal method failed: %v", err)
	}
	if methodSpec.Receiver != "s *Server" {
		t.Fatalf("expected receiver 's *Server', got %q", methodSpec.Receiver)
	}
	if len(methodSpec.Results) != 2 || methodSpec.Results[0].Name != "res" || methodSpec.Results[1].Name != "err" {
		t.Fatalf("unexpected named results: %+v", methodSpec.Results)
	}
}

func TestApplyChangeSignature_FullRefactoringAcrossFiles(t *testing.T) {
	declPath := "/proj/math.go"
	callerPath := "/proj/caller.go"

	declSrc := `package demo

type Holder struct {
	x int
}

func Compute(x int, y int, unused string) int {
	h := Holder{x: x}
	return h.x + x + y
}

func localCaller() int {
	return Compute(10, 20, "drop")
}
`
	callerSrc := `package demo

func ExternalCaller() int {
	res := Compute(1, 2, "old")
	return res
}
`

	// Refactoring:
	// 1. Rename Compute -> Evaluate
	// 2. Reorder y (origIndex 1) before x (origIndex 0, renamed to base)
	// 3. Remove unused (origIndex 2)
	// 4. Add factor int (origIndex -1, defaultValue "100")
	// 5. Add error return value
	req := ChangeSignatureRequest{
		Spec: FuncSignatureSpec{
			Path:     declPath,
			Name:     "Evaluate",
			OrigName: "Compute",
			Receiver: "",
			NameLine: 7,
			NameCol:  6,
			Params: []ParamSpec{
				{OrigIndex: 1, Name: "y", Type: "int"},
				{OrigIndex: 0, Name: "base", Type: "int"},
				{OrigIndex: -1, Name: "factor", Type: "int", DefaultValue: "100"},
			},
			Results: []ParamSpec{
				{OrigIndex: 0, Name: "", Type: "int"},
				{OrigIndex: -1, Name: "", Type: "error"},
			},
		},
		References: []SigRefLocation{
			{Path: declPath, Line: 12, Col: 8},
			{Path: callerPath, Line: 3, Col: 8},
		},
		Buffers: map[string]string{
			declPath:   declSrc,
			callerPath: callerSrc,
		},
	}

	reqBytes, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal req: %v", err)
	}
	respStr := ApplyChangeSignature(string(reqBytes))
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(respStr), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	newDecl := applyEditsToText(declSrc, resp.EditsByPath[declPath])
	newCaller := applyEditsToText(callerSrc, resp.EditsByPath[callerPath])

	if !strings.Contains(newDecl, "func Evaluate(y int, base int, factor int) (int, error) {") {
		t.Fatalf("expected updated signature header in decl, got:\n%s", newDecl)
	}
	if !strings.Contains(newDecl, "h := Holder{x: base}") {
		t.Fatalf("expected struct field key preserved and value renamed in decl, got:\n%s", newDecl)
	}
	if !strings.Contains(newDecl, "return h.x + base + y") {
		t.Fatalf("expected renamed parameter 'base' in body while preserving 'h.x', got:\n%s", newDecl)
	}
	if !strings.Contains(newDecl, "return Evaluate(20, 10, 100)") {
		t.Fatalf("expected updated local call site in decl, got:\n%s", newDecl)
	}
	if !strings.Contains(newCaller, "res := Evaluate(2, 1, 100)") {
		t.Fatalf("expected updated call site in caller.go, got:\n%s", newCaller)
	}
}

func TestApplyChangeSignature_MethodAndRecursiveZeroValues(t *testing.T) {
	declPath := "/proj/fib.go"
	declSrc := `package demo

func Fib(n int) int {
	if n <= 1 {
		return n
	}
	return Fib(n - 1)
}
`
	req := ChangeSignatureRequest{
		Spec: FuncSignatureSpec{
			Path:     declPath,
			Name:     "FibMemo",
			OrigName: "Fib",
			NameLine: 3,
			NameCol:  6,
			Params: []ParamSpec{
				{OrigIndex: 0, Name: "k", Type: "int"},
				{OrigIndex: -1, Name: "label", Type: "string", DefaultValue: ""},
				{OrigIndex: -1, Name: "verbose", Type: "bool", DefaultValue: ""},
			},
			Results: []ParamSpec{
				{OrigIndex: 0, Name: "", Type: "int"},
			},
		},
		Buffers: map[string]string{
			declPath: declSrc,
		},
	}
	reqBytes, _ := json.Marshal(req)
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(ApplyChangeSignature(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	newDecl := applyEditsToText(declSrc, resp.EditsByPath[declPath])
	if !strings.Contains(newDecl, "func FibMemo(k int, label string, verbose bool) int {") {
		t.Fatalf("unexpected header:\n%s", newDecl)
	}
	if !strings.Contains(newDecl, `return FibMemo(k - 1, "", false)`) {
		t.Fatalf("expected recursive call updated with renamed param and zero values, got:\n%s", newDecl)
	}
}

func TestApplyChangeSignature_SamePackageDiskSiblingsWithoutReferences(t *testing.T) {
	dir := t.TempDir()
	storePath := dir + "/store.go"
	mainPath := dir + "/main.go"
	storeSrc := "package main\n\nfunc ComputeTotal(a int, b int) int {\n\treturn a + b\n}\n"
	mainSrc := "package main\n\nfunc main() {\n\t_ = ComputeTotal(10, 20)\n}\n"
	if err := os.WriteFile(storePath, []byte(storeSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mainPath, []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}

	req := ChangeSignatureRequest{
		Spec: FuncSignatureSpec{
			Path:     storePath,
			Name:     "ComputeSum",
			OrigName: "ComputeTotal",
			NameLine: 3,
			NameCol:  6,
			Params: []ParamSpec{
				{OrigIndex: 0, Name: "a", Type: "int"},
				{OrigIndex: 1, Name: "b", Type: "int"},
			},
			Results: []ParamSpec{
				{OrigIndex: 0, Name: "", Type: "int"},
			},
		},
		References: []SigRefLocation{
			{Path: storePath, Line: 2, Col: 5},
		},
		Buffers: map[string]string{
			storePath: storeSrc,
		},
	}
	reqBytes, _ := json.Marshal(req)
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(ApplyChangeSignature(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	newMain := applyEditsToText(mainSrc, resp.EditsByPath[mainPath])
	if !strings.Contains(newMain, "ComputeSum(10, 20)") {
		t.Fatalf("expected sibling main.go call site updated even when gopls only returned declaration reference, got:\n%s", newMain)
	}
}

func TestInspectFuncSignature_CallSiteCrossFile(t *testing.T) {
	dir := t.TempDir()
	ledgerPath := dir + "/ledger.go"
	mainPath := dir + "/main.go"
	ledgerSrc := "package main\n\ntype Account struct{\n\tOwner string\n\tCurrency string\n}\n\nfunc NewAccount(owner string, currency string) *Account {\n\treturn &Account{Owner: owner, Currency: currency}\n}\n"
	mainSrc := "package main\n\nfunc main() {\n\tstore := NewAccount(\"Alice\", \"VND\")\n\t_ = store\n}\n"
	if err := os.WriteFile(ledgerPath, []byte(ledgerSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mainPath, []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}

	callOffset := strings.Index(mainSrc, "NewAccount")
	raw := InspectFuncSignature(mainPath, []byte(mainSrc), callOffset)
	if raw == "" {
		t.Fatal("expected non-empty signature JSON at NewAccount call site")
	}
	var spec FuncSignatureSpec
	if err := json.Unmarshal([]byte(raw), &spec); err != nil {
		t.Fatalf("unmarshal spec: %v", err)
	}
	if spec.Name != "NewAccount" || spec.Path != ledgerPath {
		t.Fatalf("expected NewAccount in %s, got Name=%q Path=%q", ledgerPath, spec.Name, spec.Path)
	}
	if len(spec.Params) != 2 || spec.Params[0].Name != "owner" || spec.Params[1].Name != "currency" {
		t.Fatalf("unexpected params: %+v", spec.Params)
	}
}

func TestChangeSignatureMethodReceiverCollision(t *testing.T) {
	src := `package main

type A struct{}

func (a A) Run(x int) {
}

type B struct{}

func (b B) Run(s string) {
}

func main() {
	a := A{}
	b := B{}
	a.Run(42)
	b.Run("hello")
}
`
	filePath := "/proj/collision.go"
	callOffset := strings.Index(src, `b.Run("hello")`) + len("b.")
	raw := InspectFuncSignature(filePath, []byte(src), callOffset)
	if raw == "" {
		t.Fatal("expected non-empty signature JSON at b.Run(\"hello\")")
	}
	var spec FuncSignatureSpec
	if err := json.Unmarshal([]byte(raw), &spec); err != nil {
		t.Fatalf("unmarshal spec: %v", err)
	}
	if spec.Receiver != "b B" {
		t.Fatalf("expected receiver 'b B', got %q", spec.Receiver)
	}
	if len(spec.Params) != 1 || spec.Params[0].Name != "s" || spec.Params[0].Type != "string" {
		t.Fatalf("expected param (s string), got %+v", spec.Params)
	}

	spec.Params = append(spec.Params, ParamSpec{
		OrigIndex:    -1,
		Name:         "tag",
		Type:         "string",
		DefaultValue: `"ok"`,
	})
	reqBytes, err := json.Marshal(ChangeSignatureRequest{
		Spec: spec,
		Buffers: map[string]string{
			filePath: src,
		},
	})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(ApplyChangeSignature(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}
	updated := applyEditsToText(src, resp.EditsByPath[filePath])
	if !strings.Contains(updated, "func (b B) Run(s string, tag string) {") {
		t.Fatalf("expected updated B.Run declaration, got:\n%s", updated)
	}
	if !strings.Contains(updated, `b.Run("hello", "ok")`) {
		t.Fatalf("expected updated b.Run call site, got:\n%s", updated)
	}
	if !strings.Contains(updated, "a.Run(42)") {
		t.Fatalf("expected a.Run(42) to remain untouched, got:\n%s", updated)
	}
}




