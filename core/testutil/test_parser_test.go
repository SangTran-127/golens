package testutil

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

const tableSrc = `package x

import (
	"fmt"
	"testing"
)

func TestSlice(t *testing.T) {
	tests := []struct {
		name string
		in   int
	}{
		{name: "zero", in: 0},
		{"positive value", 1},
		{name: "neg" + "ative", in: -1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {})
	}
}

func TestFormatted(t *testing.T) {
	cases := []struct {
		op string
		n  int
	}{
		{"add", 1},
		{op: "sub", n: 2},
	}
	for _, c := range cases {
		t.Run(fmt.Sprintf("%s_%d", c.op, c.n), func(t *testing.T) {})
	}
}

func TestMap(t *testing.T) {
	for name, tc := range map[string]struct{ want int }{
		"first":  {1},
		"second": {2},
	} {
		t.Run(name, func(t *testing.T) { _ = tc })
	}
}

func TestDynamic(t *testing.T) {
	for i := range 3 {
		t.Run(fmt.Sprint(i), func(t *testing.T) {})
	}
}

func TestOpaque(t *testing.T) {
	tests := []struct{ name string }{{name: compute()}}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {})
	}
}

func compute() string { return "x" }
func helperTest(t *testing.T) {}
func Testlower(t *testing.T) {}
`

func rowsOf(t *testing.T, name string) []TableRow {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "x_test.go", tableSrc, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == name {
			return TableRows(fset, fn)
		}
	}
	t.Fatalf("no %s", name)
	return nil
}

func names(rows []TableRow) []string {
	var out []string
	for _, r := range rows {
		out = append(out, r.Name)
	}
	return out
}

func TestTableRowNames(t *testing.T) {
	if got := names(rowsOf(t, "TestSlice")); !reflect.DeepEqual(got, []string{"zero", "positive value", "negative"}) {
		t.Fatalf("slice rows %v", got)
	}
	if rows := rowsOf(t, "TestSlice"); rows[0].Line != 13 || rows[2].Line != 15 {
		t.Fatalf("row lines %+v", rows)
	}
	if got := names(rowsOf(t, "TestFormatted")); !reflect.DeepEqual(got, []string{"add_1", "sub_2"}) {
		t.Fatalf("formatted rows %v", got)
	}
	if got := names(rowsOf(t, "TestMap")); !reflect.DeepEqual(got, []string{"first", "second"}) {
		t.Fatalf("map rows %v", got)
	}
	if got := rowsOf(t, "TestDynamic"); len(got) != 0 {
		t.Fatalf("dynamic rows must be skipped: %v", got)
	}
	if got := rowsOf(t, "TestOpaque"); len(got) != 0 {
		t.Fatalf("non-constant names must be skipped: %v", got)
	}
}

func TestRunPatternsQuoteEachSegment(t *testing.T) {
	cases := []struct {
		test string
		rows []string
		want string
		hit  string
	}{
		{"TestSlice", []string{"positive value"}, `^TestSlice$/^positive_value$`, "TestSlice/positive_value"},
		{"TestX", []string{"a+b (c)"}, `^TestX$/^a\+b_\(c\)$`, "TestX/a+b_(c)"},
		{"TestX", []string{"outer/inner"}, `^TestX$/^outer$/^inner$`, "TestX/outer/inner"},
		{"TestY", nil, `^TestY$`, "TestY"},
	}
	for _, c := range cases {
		got := RunPattern(c.test, c.rows...)
		if got != c.want {
			t.Errorf("RunPattern(%q, %v) = %q, want %q", c.test, c.rows, got, c.want)
		}
		segs := regexp.MustCompile(`/`).Split(c.hit, -1)
		parts := regexp.MustCompile(`\$/\^`).Split(got, -1)
		for i := range segs {
			p := parts[i]
			if i > 0 {
				p = "^" + p
			}
			if i < len(parts)-1 {
				p += "$"
			}
			if !regexp.MustCompile(p).MatchString(segs[i]) {
				t.Errorf("segment %q does not match %q", p, segs[i])
			}
		}
	}
	if got := FailedPattern([]string{"TestA", "TestB"}); got != "^(TestA|TestB)$" {
		t.Fatalf("failed pattern %q", got)
	}
}

func TestDiscoverSkipsHelpersAndFindsRows(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "x_test.go"), []byte(tableSrc), 0o644)
	_ = os.MkdirAll(filepath.Join(dir, "testdata"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "testdata", "y_test.go"), []byte(tableSrc), 0o644)
	var suites []GoTestSuite
	if err := json.Unmarshal([]byte(DiscoverTests(dir)), &suites); err != nil || len(suites) != 1 {
		t.Fatalf("suites %v %v", suites, err)
	}
	var got []string
	for _, tf := range suites[0].Tests {
		got = append(got, tf.Name)
	}
	if !reflect.DeepEqual(got, []string{"TestSlice", "TestFormatted", "TestMap", "TestDynamic", "TestOpaque"}) {
		t.Fatalf("tests %v", got)
	}
	if len(suites[0].Tests[0].Rows) != 3 {
		t.Fatalf("rows %+v", suites[0].Tests[0].Rows)
	}
}

func TestTestifySuiteDiscoveryAndFileTests(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/suitetest\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	runnerSrc := `package suitetest

import (
	"testing"
	"github.com/stretchr/testify/suite"
)

type AuthSuite struct {
	suite.Suite
}

func TestAuthSuite(t *testing.T) {
	suite.Run(t, new(AuthSuite))
}

func (s *AuthSuite) TestLogin() {}
func (s *AuthSuite) SetupTest() {}
func (s *AuthSuite) helperMethod() {}

type BillingSuite struct {
	suite.Suite
}

func TestBillingSuite(t *testing.T) {
	suite.Run(t, &BillingSuite{})
}

type LocalVarSuite struct {
	suite.Suite
}

func TestLocalVarSuite(t *testing.T) {
	s := new(LocalVarSuite)
	suite.Run(t, s)
}

func (s LocalVarSuite) TestWithValueReceiver() {}
`

	methodsSrc := `package suitetest

func (s *BillingSuite) TestCharge() {}
func (s *BillingSuite) TestRefund() {}
`

	runnerPath := filepath.Join(dir, "runner_test.go")
	methodsPath := filepath.Join(dir, "methods_test.go")
	if err := os.WriteFile(runnerPath, []byte(runnerSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(methodsPath, []byte(methodsSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	var suites []GoTestSuite
	if err := json.Unmarshal([]byte(DiscoverTests(dir)), &suites); err != nil || len(suites) != 1 {
		t.Fatalf("DiscoverTests failed: %v, suites=%+v", err, suites)
	}
	testsByName := make(map[string]GoTestFunc)
	for _, tf := range suites[0].Tests {
		testsByName[tf.Name] = tf
	}

	auth := testsByName["TestAuthSuite"]
	if !reflect.DeepEqual(names(auth.Rows), []string{"TestLogin"}) {
		t.Fatalf("TestAuthSuite rows = %+v", auth.Rows)
	}
	if auth.Rows[0].Line != 16 {
		t.Fatalf("TestLogin line = %d, want 16", auth.Rows[0].Line)
	}

	billing := testsByName["TestBillingSuite"]
	if !reflect.DeepEqual(names(billing.Rows), []string{"TestCharge", "TestRefund"}) {
		t.Fatalf("TestBillingSuite rows = %+v", billing.Rows)
	}
	if billing.Rows[0].File != methodsPath || billing.Rows[0].Line != 3 {
		t.Fatalf("TestCharge row = %+v, want file=%s line=3", billing.Rows[0], methodsPath)
	}

	localVar := testsByName["TestLocalVarSuite"]
	if !reflect.DeepEqual(names(localVar.Rows), []string{"TestWithValueReceiver"}) {
		t.Fatalf("TestLocalVarSuite rows = %+v", localVar.Rows)
	}

	// Verify FileTests on runner_test.go (same-file suite methods have line > 0).
	runnerFT := FileTests(runnerPath, []byte(runnerSrc))
	if runnerFT.ImportPath != "example.com/suitetest" {
		t.Fatalf("ImportPath = %q", runnerFT.ImportPath)
	}
	var foundAuth bool
	for _, tf := range runnerFT.Tests {
		if tf.Name == "TestAuthSuite" {
			foundAuth = true
			if tf.Line != 12 || len(tf.Rows) != 1 || tf.Rows[0].Name != "TestLogin" || tf.Rows[0].Line != 16 {
				t.Fatalf("runnerFT TestAuthSuite = %+v", tf)
			}
		}
	}
	if !foundAuth {
		t.Fatalf("TestAuthSuite not found in runnerFT: %+v", runnerFT.Tests)
	}

	// Verify FileTests on methods_test.go (runner is in sibling runner_test.go, so runner Line == 0 and row lines > 0).
	methodsFT := FileTests(methodsPath, []byte(methodsSrc))
	if len(methodsFT.Tests) != 1 {
		t.Fatalf("methodsFT.Tests = %+v, want 1 synthetic runner entry", methodsFT.Tests)
	}
	syn := methodsFT.Tests[0]
	if syn.Name != "TestBillingSuite" || syn.Line != 0 || !reflect.DeepEqual(names(syn.Rows), []string{"TestCharge", "TestRefund"}) {
		t.Fatalf("methodsFT synthetic runner = %+v", syn)
	}
	if syn.Rows[0].Line != 3 || syn.Rows[1].Line != 4 {
		t.Fatalf("methodsFT row lines = %+v", syn.Rows)
	}
}

func TestBenchmarkDiscoveryAndFileTests(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/benchtest\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	benchSrc := `package benchtest

import "testing"

func BenchmarkStore(b *testing.B) {
	cases := []struct {
		name string
		size int
	}{
		{name: "small", size: 16},
		{name: "large", size: 4096},
	}
	for _, tc := range cases {
		b.Run(tc.name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				_ = tc.size
			}
		})
	}
}

func Benchmarklower(b *testing.B) {}
func BenchmarkWrongParam(t *testing.T) {}
`

	benchPath := filepath.Join(dir, "store_test.go")
	if err := os.WriteFile(benchPath, []byte(benchSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	var suites []GoTestSuite
	if err := json.Unmarshal([]byte(DiscoverTests(dir)), &suites); err != nil || len(suites) != 1 {
		t.Fatalf("DiscoverTests failed: %v, suites=%+v", err, suites)
	}
	if len(suites[0].Tests) != 1 || suites[0].Tests[0].Name != "BenchmarkStore" {
		t.Fatalf("expected [BenchmarkStore], got %+v", suites[0].Tests)
	}
	if !reflect.DeepEqual(names(suites[0].Tests[0].Rows), []string{"small", "large"}) {
		t.Fatalf("BenchmarkStore rows = %+v", suites[0].Tests[0].Rows)
	}

	ft := ParseFileTests(benchPath, []byte(benchSrc))
	if ft.ImportPath != "example.com/benchtest" || len(ft.Tests) != 1 || ft.Tests[0].Name != "BenchmarkStore" {
		t.Fatalf("ParseFileTests = %+v", ft)
	}
	if !reflect.DeepEqual(names(ft.Tests[0].Rows), []string{"small", "large"}) {
		t.Fatalf("ParseFileTests rows = %+v", ft.Tests[0].Rows)
	}
}

func TestFuzzDiscoveryAndFileTests(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/fuzztest\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	fuzzSrc := `package fuzztest

import "testing"

func FuzzParse(f *testing.F) {
	f.Add("hello")
	f.Fuzz(func(t *testing.T, s string) {})
}

func Fuzzlower(f *testing.F) {}
func FuzzWrongParam(t *testing.T) {}
`

	fuzzPath := filepath.Join(dir, "parse_test.go")
	if err := os.WriteFile(fuzzPath, []byte(fuzzSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	var suites []GoTestSuite
	if err := json.Unmarshal([]byte(DiscoverTests(dir)), &suites); err != nil || len(suites) != 1 {
		t.Fatalf("DiscoverTests failed: %v, suites=%+v", err, suites)
	}
	if len(suites[0].Tests) != 1 || suites[0].Tests[0].Name != "FuzzParse" {
		t.Fatalf("expected [FuzzParse], got %+v", suites[0].Tests)
	}

	ft := ParseFileTests(fuzzPath, []byte(fuzzSrc))
	if ft.ImportPath != "example.com/fuzztest" || len(ft.Tests) != 1 || ft.Tests[0].Name != "FuzzParse" {
		t.Fatalf("ParseFileTests = %+v", ft)
	}
}
