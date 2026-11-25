package goast

import (
	"encoding/json"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateTableDriven_FreeFunctionReturningStructAndError(t *testing.T) {
	src := `package bank

import "context"

type Account struct {
	Owner   string
	Balance int
}

func NewAccount(ctx context.Context, owner string, initial int) (*Account, error) {
	return &Account{Owner: owner, Balance: initial}, nil
}
`
	offset := strings.Index(src, "func NewAccount") + 5
	reply := GenerateTableDrivenTest(GenerateTestReq{
		Path:   "/workspace/bank/account.go",
		Src:    src,
		Offset: offset,
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.TargetFuncName != "NewAccount" {
		t.Errorf("TargetFuncName = %q, want NewAccount", reply.TargetFuncName)
	}
	if reply.TestFuncName != "TestNewAccount" {
		t.Errorf("TestFuncName = %q, want TestNewAccount", reply.TestFuncName)
	}
	if reply.TestFilePath != "/workspace/bank/account_test.go" {
		t.Errorf("TestFilePath = %q, want /workspace/bank/account_test.go", reply.TestFilePath)
	}
	if !strings.Contains(reply.PreviewCode, "func TestNewAccount(t *testing.T)") {
		t.Errorf("missing TestNewAccount signature in preview:\n%s", reply.PreviewCode)
	}
	if strings.Contains(reply.PreviewCode, "ctx context.Context") {
		t.Errorf("context.Context should be skipped from test table struct:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "NewAccount(context.Background(), tt.owner, tt.initial)") {
		t.Errorf("expected context.Background() passed in call:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "if (err != nil) != tt.wantErr") {
		t.Errorf("expected wantErr check in preview:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "reflect.DeepEqual(got, tt.want)") {
		t.Errorf("expected reflect.DeepEqual for *Account return:\n%s", reply.PreviewCode)
	}
}

func TestGenerateTableDriven_MethodReceiver(t *testing.T) {
	src := `package bank

type Account struct {
	Balance int
}

func (a *Account) Deposit(amount int) error {
	a.Balance += amount
	return nil
}
`
	offset := strings.Index(src, "Deposit")
	reply := GenerateTableDrivenTest(GenerateTestReq{
		Path:   "/workspace/bank/account.go",
		Src:    src,
		Offset: offset,
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.ReceiverType != "*Account" {
		t.Errorf("ReceiverType = %q, want *Account", reply.ReceiverType)
	}
	if reply.TestFuncName != "TestAccount_Deposit" {
		t.Errorf("TestFuncName = %q, want TestAccount_Deposit", reply.TestFuncName)
	}
	if !strings.Contains(reply.PreviewCode, "a := &Account{}") {
		t.Errorf("expected receiver initialization in preview:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "err := a.Deposit(tt.amount)") {
		t.Errorf("expected method call in preview:\n%s", reply.PreviewCode)
	}
}

func TestGenerateTableDriven_PureFunctionWithParallelAndCustomName(t *testing.T) {
	src := `package mathutil

func Add(int, int) int {
	return 0
}
`
	raw := GenerateTableDrivenTestJSON(`{
		"path": "/workspace/mathutil/add.go",
		"src": ` + mustJSONString(src) + `,
		"offset": 20,
		"testFuncName": "TestAdd_Parallel",
		"includeParallel": true
	}`)
	var reply GenerateTestReply
	if err := json.Unmarshal([]byte(raw), &reply); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.TestFuncName != "TestAdd_Parallel" {
		t.Errorf("TestFuncName = %q, want TestAdd_Parallel", reply.TestFuncName)
	}
	if strings.Count(reply.PreviewCode, "t.Parallel()") != 2 {
		t.Errorf("expected 2 t.Parallel() calls (outer + subtest), got:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "got := Add(tt.arg0, tt.arg1)") {
		t.Errorf("expected synthesized arg0, arg1 in call:\n%s", reply.PreviewCode)
	}
	if !strings.Contains(reply.PreviewCode, "if got != tt.want") {
		t.Errorf("expected direct != comparison for int result:\n%s", reply.PreviewCode)
	}
}

func TestGenerateTableDriven_ApplyNewAndAppendExisting(t *testing.T) {
	tmpDir := t.TempDir()
	srcPath := filepath.Join(tmpDir, "calc.go")
	src := `package calc

func Multiply(a, b int) int {
	return a * b
}

func Divide(a, b int) ([]int, error) {
	return []int{a / b}, nil
}
`
	if err := os.WriteFile(srcPath, []byte(src), 0644); err != nil {
		t.Fatalf("write src: %v", err)
	}

	reply1 := GenerateTableDrivenTest(GenerateTestReq{
		Path:   srcPath,
		Src:    src,
		Offset: strings.Index(src, "Multiply"),
		Apply:  true,
	})
	if reply1.Error != "" || !reply1.Applied {
		t.Fatalf("apply first test failed: %+v", reply1)
	}

	testBytes1, err := os.ReadFile(reply1.TestFilePath)
	if err != nil {
		t.Fatalf("read generated test file: %v", err)
	}
	testStr1 := string(testBytes1)
	if !strings.Contains(testStr1, "package calc") || !strings.Contains(testStr1, `"testing"`) || !strings.Contains(testStr1, "func TestMultiply(t *testing.T)") {
		t.Fatalf("unexpected initial test file content:\n%s", testStr1)
	}

	reply2 := GenerateTableDrivenTest(GenerateTestReq{
		Path:   srcPath,
		Src:    src,
		Offset: strings.Index(src, "Divide"),
		Apply:  true,
	})
	if reply2.Error != "" || !reply2.Applied {
		t.Fatalf("append second test failed: %+v", reply2)
	}

	testBytes2, err := os.ReadFile(reply2.TestFilePath)
	if err != nil {
		t.Fatalf("read appended test file: %v", err)
	}
	testStr2 := string(testBytes2)
	if !strings.Contains(testStr2, "func TestMultiply(t *testing.T)") || !strings.Contains(testStr2, "func TestDivide(t *testing.T)") {
		t.Fatalf("expected both TestMultiply and TestDivide in file:\n%s", testStr2)
	}
	if !strings.Contains(testStr2, `"reflect"`) {
		t.Fatalf("expected reflect import added when appending slice-returning test:\n%s", testStr2)
	}
}

func mustJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func typeCheckTestGenPackage(t *testing.T, pkgName string, sources map[string]string) {
	t.Helper()
	fset := token.NewFileSet()
	var files []*ast.File
	for name, src := range sources {
		f, err := parser.ParseFile(fset, name, src, parser.ParseComments)
		if err != nil {
			t.Fatalf("parse %s failed: %v\n%s", name, err, src)
		}
		files = append(files, f)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check(pkgName, fset, files, nil); err != nil {
		t.Fatalf("typecheck %s failed: %v\nsources:\n%v", pkgName, err, sources)
	}
}

func TestGenerateTableDriven_EdgeCases_CompileAndGoTest(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		fileName    string
		src         string
		targetSub   string
		parallel    bool
		mustContain []string
	}{
		{
			name:     "generic_function_with_constraints_and_func_return",
			pkgName:  "genfn",
			fileName: "mapslice.go",
			src: `package genfn

func Transform[T ~int | ~float64, U comparable](vals []T, mapFn func(T) U) ([]U, func() int) {
	out := make([]U, 0, len(vals))
	for _, v := range vals {
		out = append(out, mapFn(v))
	}
	return out, func() int { return len(out) }
}
`,
			targetSub:   "func Transform",
			parallel:    true,
			mustContain: []string{"Transform[int, int](", "got1 == nil"},
		},
		{
			name:     "generic_pointer_receiver",
			pkgName:  "repo",
			fileName: "repo.go",
			src: `package repo

type Repo[K comparable, V any] struct {
	data map[K]V
}

func (r *Repo[K, V]) Lookup(k K) (V, bool) {
	var zero V
	if r.data == nil {
		return zero, false
	}
	v, ok := r.data[k]
	return v, ok
}
`,
			targetSub:   "Lookup(",
			mustContain: []string{"&Repo[int, int]{}", "r.Lookup("},
		},
		{
			name:     "non_struct_defined_receiver_and_interface_types",
			pkgName:  "modes",
			fileName: "modes.go",
			src: `package modes

import (
	"io"
	"time"
)

type Mode int

func (m *Mode) Combine(d time.Duration, r io.Reader, h func(string) int) Mode {
	_ = d
	_ = r
	_ = h
	return *m
}
`,
			targetSub:   "Combine(",
			mustContain: []string{"var mVal Mode", "m := &mVal", "*new(time.Duration)"},
		},
		{
			name:     "name_clashes_params_aliases_and_type_named_t",
			pkgName:  "clash",
			fileName: "clash.go",
			src: `//go:build darwin || linux

package clash

import (
	ctx "context"
	tm "time"
)

type t struct{ n int }

func (reflect *t) Run(c ctx.Context, name string, skip bool, want int, want1 string, wantErr bool, arg0 int, d tm.Duration) (int, string, error) {
	return want + arg0 + reflect.n + int(d), want1, nil
}
`,
			targetSub:   "func (reflect *t) Run",
			mustContain: []string{"//go:build darwin || linux", "func Test_t_Run(", `ctx "context"`, `tm "time"`, "ctx.Background()"},
		},
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module testgenexec\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}

	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pkgDir := filepath.Join(dir, tc.pkgName+string(rune('a'+i)))
			if err := os.MkdirAll(pkgDir, 0755); err != nil {
				t.Fatal(err)
			}
			srcPath := filepath.Join(pkgDir, tc.fileName)
			if err := os.WriteFile(srcPath, []byte(tc.src), 0644); err != nil {
				t.Fatal(err)
			}
			off := strings.Index(tc.src, tc.targetSub)
			if off < 0 {
				t.Fatalf("missing %q", tc.targetSub)
			}
			reply := GenerateTableDrivenTest(GenerateTestReq{
				Path:            srcPath,
				Src:             tc.src,
				Offset:          off,
				IncludeParallel: tc.parallel,
				Apply:           true,
			})
			if reply.Error != "" || !reply.Applied {
				t.Fatalf("GenerateTableDrivenTest failed: %+v", reply)
			}
			testBytes, err := os.ReadFile(reply.TestFilePath)
			if err != nil {
				t.Fatalf("read generated test file: %v", err)
			}
			testSrc := string(testBytes)
			for _, want := range tc.mustContain {
				if !strings.Contains(testSrc, want) {
					t.Errorf("expected %q in generated test:\n%s", want, testSrc)
				}
			}
			typeCheckTestGenPackage(t, tc.pkgName, map[string]string{
				tc.fileName:                       tc.src,
				filepath.Base(reply.TestFilePath): testSrc,
			})

			cmd := exec.Command("go", "test", "-v", ".")
			cmd.Dir = pkgDir
			if out, runErr := cmd.CombinedOutput(); runErr != nil {
				t.Fatalf("go test failed: %v\n%s\nGenerated:\n%s", runErr, string(out), testSrc)
			}
		})
	}
}

func TestGenerateTableDriven_RegenerateKeepsTestsExternalRedirectAndBuildTags(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module idemp\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}
	srcPath := filepath.Join(dir, "calc.go")
	extTestPath := filepath.Join(dir, "calc_test.go")
	ignoredPath := filepath.Join(dir, "ignored.go")

	src := `package idemp

func Add(a, b int) int { return a + b }
`
	extTest := `package idemp_test

import "testing"

func TestExternalContract(t *testing.T) {}
`
	ignoredSrc := `//go:build ignore

package idemp

type IgnoredType int
`
	for p, body := range map[string]string{srcPath: src, extTestPath: extTest, ignoredPath: ignoredSrc} {
		if err := os.WriteFile(p, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}

	reply1 := GenerateTableDrivenTest(GenerateTestReq{
		Path:  srcPath,
		Src:   src,
		Apply: true,
	})
	if reply1.Error != "" || !reply1.Applied {
		t.Fatalf("first Apply failed: %+v", reply1)
	}
	if !strings.HasSuffix(reply1.TestFilePath, "calc_unit_test.go") {
		t.Fatalf("expected external test redirect to calc_unit_test.go, got %q", reply1.TestFilePath)
	}

	firstBytes, err := os.ReadFile(reply1.TestFilePath)
	if err != nil {
		t.Fatal(err)
	}
	updatedWithCustom := string(firstBytes) + "\nfunc TestKeepCustom(t *testing.T) {}\n"
	if err := os.WriteFile(reply1.TestFilePath, []byte(updatedWithCustom), 0644); err != nil {
		t.Fatal(err)
	}

	reply2 := GenerateTableDrivenTest(GenerateTestReq{
		Path:  srcPath,
		Src:   src,
		Apply: true,
	})
	if reply2.Error != "" || !reply2.Applied {
		t.Fatalf("second Apply failed: %+v", reply2)
	}
	secondBytes, err := os.ReadFile(reply2.TestFilePath)
	if err != nil {
		t.Fatal(err)
	}
	secondSrc := string(secondBytes)
	if strings.Count(secondSrc, "func TestAdd(") != 1 || strings.Count(secondSrc, "func TestAdd2(") != 1 || reply2.TestFuncName != "TestAdd2" {
		t.Fatalf("expected the first TestAdd kept and the new test named TestAdd2, got %q:\n%s", reply2.TestFuncName, secondSrc)
	}
	explicit := GenerateTableDrivenTest(GenerateTestReq{Path: srcPath, Src: src, TestFuncName: "TestKeepCustom", Apply: true})
	if explicit.Applied || !strings.Contains(explicit.Error, "TestKeepCustom already exists") {
		t.Fatalf("expected an explicit existing name to be refused: %+v", explicit)
	}
	if !strings.Contains(secondSrc, "func TestKeepCustom(") {
		t.Fatalf("expected unrelated TestKeepCustom preserved:\n%s", secondSrc)
	}

	cmd := exec.Command("go", "test", "-v", "./...")
	cmd.Dir = dir
	if out, runErr := cmd.CombinedOutput(); runErr != nil {
		t.Fatalf("go test failed: %v\n%s\nTest file:\n%s", runErr, string(out), secondSrc)
	}

	unskipped := strings.Replace(secondSrc, "skip: true,", "skip: false,", 1)
	unskipped = strings.Replace(unskipped, "want: 0,", "want: 2,", 1)
	if unskipped == secondSrc {
		t.Fatalf("expected skip: true in generated test:\n%s", secondSrc)
	}
	if err := os.WriteFile(reply2.TestFilePath, []byte(unskipped), 0644); err != nil {
		t.Fatal(err)
	}
	cmdRun := exec.Command("go", "test", "-v", "-run", "^TestAdd$", "./...")
	cmdRun.Dir = dir
	if out, runErr := cmdRun.CombinedOutput(); runErr != nil {
		t.Fatalf("unskipped go test failed: %v\n%s\nTest file:\n%s", runErr, string(out), unskipped)
	}
}
