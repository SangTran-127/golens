package testutil

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

func TestNestedSubtestsAndEndLines(t *testing.T) {
	src := `package nested

import "testing"

func TestNestedTree(t *testing.T) {
	t.Run("auth", func(t *testing.T) {
		t.Run("valid token", func(sub *testing.T) {
			if false {
				sub.Fatal("nope")
			}
		})
		t.Run("a+b (edge)", func(sub *testing.T) {
			_ = 1
		})
	})
}

func BenchmarkNested(b *testing.B) {
	b.Run("encode", func(b *testing.B) {
		b.Run("json", func(b *testing.B) {
			for i := 0; i < b.N; i++ {
			}
		})
	})
}
`
	ft := FileTests("/tmp/nested_test.go", []byte(src))
	if len(ft.Tests) != 2 {
		t.Fatalf("expected 2 tests, got %+v", ft.Tests)
	}
	if ft.Tests[0].Line != 5 || ft.Tests[0].EndLine != 16 {
		t.Fatalf("TestNestedTree span = %d..%d, want 5..16", ft.Tests[0].Line, ft.Tests[0].EndLine)
	}
	wantRows := []string{"auth", "auth/valid token", "auth/a+b (edge)"}
	if got := names(ft.Tests[0].Rows); !reflect.DeepEqual(got, wantRows) {
		t.Fatalf("rows = %v, want %v", got, wantRows)
	}
	if ft.Tests[0].Rows[1].ID != "auth/valid_token" {
		t.Fatalf("row ID = %q, want auth/valid_token", ft.Tests[0].Rows[1].ID)
	}
	if ft.Tests[0].Rows[0].Line != 6 || ft.Tests[0].Rows[0].EndLine != 15 {
		t.Fatalf("auth row span = %d..%d, want 6..15", ft.Tests[0].Rows[0].Line, ft.Tests[0].Rows[0].EndLine)
	}
	if ft.Tests[0].Rows[1].Line != 7 || ft.Tests[0].Rows[1].EndLine != 11 {
		t.Fatalf("valid token row span = %d..%d, want 7..11", ft.Tests[0].Rows[1].Line, ft.Tests[0].Rows[1].EndLine)
	}
	wantBenchRows := []string{"encode", "encode/json"}
	if got := names(ft.Tests[1].Rows); !reflect.DeepEqual(got, wantBenchRows) {
		t.Fatalf("bench rows = %v, want %v", got, wantBenchRows)
	}
}

func TestResolveCaretTargetNestedAndTableDriven(t *testing.T) {
	src := `package caret

import "testing"

func TestAuth(t *testing.T) {
	t.Run("login", func(t *testing.T) {
		cases := []struct {
			name string
			ok   bool
		}{
			{
				name: "valid user",
				ok:   true,
			},
			{name: "expired+bad (1)", ok: false},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				if !tc.ok {
					t.Log("checked")
				}
			})
		}
		t.Run("logout", func(t *testing.T) {
			t.Log("done")
		})
	})
}
`
	if got := ResolveCaretTarget([]byte(src), 1); got.Found {
		t.Fatalf("line 1 should not match a test, got %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 5); !got.Found || got.Test != "TestAuth" || len(got.Subtests) != 0 || got.Pattern != "^TestAuth$" {
		t.Fatalf("line 5 = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 13); !got.Found || got.Test != "TestAuth" || got.SubtestPath != "login/valid user" || got.Pattern != `^TestAuth$/^login$/^valid_user$` {
		t.Fatalf("line 13 (multi-line row literal) = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 15); !got.Found || got.SubtestPath != "login/expired+bad (1)" || got.Pattern != `^TestAuth$/^login$/^expired\+bad_\(1\)$` {
		t.Fatalf("line 15 (escaped row literal) = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 20); !got.Found || got.SubtestPath != "login" || got.Pattern != `^TestAuth$/^login$` {
		t.Fatalf("line 20 (table t.Run body inside login) = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 25); !got.Found || got.SubtestPath != "login/logout" || got.Pattern != `^TestAuth$/^login$/^logout$` {
		t.Fatalf("line 25 (nested literal t.Run) = %+v", got)
	}
}

func TestResolveCaretTargetLoopNestedSubtest(t *testing.T) {
	src := `package loopline

import "testing"

func TestMatrix(t *testing.T) {
	rows := []struct{ name string }{
		{name: "alpha"},
		{name: "beta"},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			t.Run("step1", func(t *testing.T) {
				_ = r
			})
		})
	}
}
`
	if got := ResolveCaretTarget([]byte(src), 7); !got.Found || got.SubtestPath != "alpha" || got.Pattern != `^TestMatrix$/^alpha$` {
		t.Fatalf("row literal caret = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 13); !got.Found || got.Pattern != `^TestMatrix$/^(?:alpha|beta)$/^step1$` {
		t.Fatalf("nested step1 inside table loop = %+v", got)
	}
}

func TestFailedSubtestPatternEscapingAndPruning(t *testing.T) {
	if got := FailedSubtestPattern(nil); got != "" {
		t.Fatalf("empty = %q", got)
	}
	if got := FailedSubtestPattern([]string{"TestA", "TestB"}); got != "^(TestA|TestB)$" {
		t.Fatalf("top-level = %q", got)
	}

	got := FailedSubtestPattern([]string{
		"TestFoo",
		"TestFoo/subA",
		"TestFoo/subA/leaf (1)+2",
		"TestFoo/subB",
		"TestBar",
	})
	want := `^TestBar$|^TestFoo$/^subB$|^TestFoo$/^subA$/^leaf_\(1\)\+2$`
	if got != want {
		t.Fatalf("FailedSubtestPattern = %q, want %q", got, want)
	}

	groupGot := FailedSubtestPattern([]string{
		"TestFoo",
		"TestFoo/case 1",
		"TestFoo/case|2",
	})
	groupWant := `^TestFoo$/^(?:case_1|case\|2)$`
	if groupGot != groupWant {
		t.Fatalf("grouped subtests = %q, want %q", groupGot, groupWant)
	}

	if _, err := regexp.Compile(groupGot); err != nil {
		t.Fatalf("invalid regexp %q: %v", groupGot, err)
	}
}

func TestFailedSubtestPatternExecutesOnlyFailingSubtestsInGoTest(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/subrun\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	src := `package subrun

import "testing"

func TestSuite(t *testing.T) {
	t.Run("group", func(t *testing.T) {
		t.Run("pass_sibling", func(t *testing.T) {
			t.Log("RAN_PASS_SIBLING")
		})
		t.Run("fail case (a+b)", func(t *testing.T) {
			t.Log("RAN_FAIL_LEAF")
		})
	})
	t.Run("other_top_sibling", func(t *testing.T) {
		t.Log("RAN_OTHER_TOP_SIBLING")
	})
}

func TestIndependent(t *testing.T) {
	t.Log("RAN_INDEPENDENT")
}
`
	if err := os.WriteFile(filepath.Join(dir, "sub_test.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	pat := FailedSubtestPattern([]string{
		"TestSuite",
		"TestSuite/group",
		"TestSuite/group/fail case (a+b)",
	})
	cmd := exec.Command("go", "test", "-v", "-run", pat, ".")
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go test failed: %v\n%s", err, string(out))
	}
	text := string(out)
	if !strings.Contains(text, "RAN_FAIL_LEAF") {
		t.Fatalf("expected failing leaf to run, output:\n%s", text)
	}
	if strings.Contains(text, "RAN_PASS_SIBLING") || strings.Contains(text, "RAN_OTHER_TOP_SIBLING") || strings.Contains(text, "RAN_INDEPENDENT") {
		t.Fatalf("siblings should not have run for pattern %q, output:\n%s", pat, text)
	}
}

func TestUntestedPackageFunctions(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/untested\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	prodSrc := `package billing

type Client[T any] struct{}

func NewClient() *Client[string] { return nil }
func (c *Client[T]) Charge(amount int) error { return nil }
func (c *Client[T]) Refund(id string) error { return nil }
func ParseAmount(raw string) (int, error) { return 0, nil }
func ParseAll() {}
func internalHelper() {}
`
	testSrc := `package billing_test

import "testing"

func TestNewClient(t *testing.T) {}
func TestClient_Charge_Success(t *testing.T) {}
func TestParseAmount(t *testing.T) {}
`
	if err := os.WriteFile(filepath.Join(dir, "billing.go"), []byte(prodSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "billing_test.go"), []byte(testSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	got := UntestedPackageFunctions(dir)
	var testNames []string
	for _, item := range got {
		testNames = append(testNames, item.TestName)
	}
	want := []string{"TestClient_Refund", "TestParseAll"}
	if !reflect.DeepEqual(testNames, want) {
		b, _ := json.Marshal(got)
		t.Fatalf("untested = %v (%s), want %v", testNames, string(b), want)
	}
	if got[0].Receiver != "Client" || !strings.Contains(got[0].Signature, "Refund(id string) error") {
		t.Fatalf("unexpected method entry: %+v", got[0])
	}
	if got[1].FuncName != "ParseAll" || got[1].Signature != "func ParseAll()" {
		t.Fatalf("unexpected func entry: %+v", got[1])
	}
}

func TestIsBenchmarkTargetAndDebugTestArgs(t *testing.T) {
	cases := []struct {
		testName string
		pattern  string
		want     bool
	}{
		{testName: "BenchmarkEncode", want: true},
		{testName: "Benchmark", want: true},
		{pattern: "BenchmarkFoo", want: true},
		{pattern: "^BenchmarkFoo$", want: true},
		{pattern: "^BenchmarkEncode$/^v2$", want: true},
		{testName: "Benchmarklower", want: false},
		{pattern: "^Benchmarklower$", want: false},
		{testName: "TestEncode", pattern: "^TestEncode$", want: false},
		{testName: "FuzzEncode", pattern: "^FuzzEncode$", want: false},
	}
	for _, tc := range cases {
		if got := IsBenchmarkTarget(tc.testName, tc.pattern); got != tc.want {
			t.Fatalf("IsBenchmarkTarget(%q, %q) = %v, want %v", tc.testName, tc.pattern, got, tc.want)
		}
	}

	pat, args := DebugTestArgs("BenchmarkEncode", "small payload", "")
	if pat != "^BenchmarkEncode$/^small_payload$" {
		t.Fatalf("pattern = %q", pat)
	}
	wantBench := []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^small_payload$", "-test.benchmem", "-test.v"}
	if !reflect.DeepEqual(args, wantBench) {
		t.Fatalf("args = %v, want %v", args, wantBench)
	}

	pat, args = DebugTestArgs("TestEncode", "", "")
	if pat != "^TestEncode$" || !reflect.DeepEqual(args, []string{"-test.run", "^TestEncode$", "-test.v"}) {
		t.Fatalf("test args = %q %v", pat, args)
	}
}

func TestGo124BenchmarkLoopAndTableSubbenchmarks(t *testing.T) {
	src := `package benchloop

import "testing"

func BenchmarkLoopTop(b *testing.B) {
	for b.Loop() {
		_ = 42
	}
}

func BenchmarkTableLoop(b *testing.B) {
	cases := []struct {
		name string
		size int
	}{
		{name: "small payload", size: 8},
		{name: "large payload", size: 1024},
	}
	for _, tc := range cases {
		b.Run(tc.name, func(b *testing.B) {
			if tc.size > 0 {
				b.Run("encode", func(b *testing.B) {
					for b.Loop() {
						_ = tc.size
					}
				})
			}
		})
	}
	for _, label := range []string{"alpha", "beta"} {
		b.Run(label, func(b *testing.B) {
			for b.Loop() {
				_ = len(label)
			}
		})
	}
	if true {
		b.Run("conditional", func(b *testing.B) {
			for b.Loop() {
				_ = 1
			}
		})
	}
}
`
	ft := FileTests("/tmp/bench_loop_test.go", []byte(src))
	if len(ft.Tests) != 2 {
		t.Fatalf("expected 2 benchmarks, got %+v", ft.Tests)
	}
	if ft.Tests[0].Name != "BenchmarkLoopTop" {
		t.Fatalf("first benchmark = %+v", ft.Tests[0])
	}
	wantRows := []string{
		"small payload",
		"small payload/encode",
		"large payload",
		"large payload/encode",
		"alpha",
		"beta",
		"conditional",
	}
	if got := names(ft.Tests[1].Rows); !reflect.DeepEqual(got, wantRows) {
		t.Fatalf("table loop rows = %v, want %v", got, wantRows)
	}

	if got := ResolveCaretTarget([]byte(src), 7); !got.Found || got.Test != "BenchmarkLoopTop" || got.Pattern != "^BenchmarkLoopTop$" {
		t.Fatalf("top-level b.Loop caret = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 16); !got.Found || got.Test != "BenchmarkTableLoop" || got.SubtestPath != "small payload" || got.Pattern != "^BenchmarkTableLoop$/^small_payload$" {
		t.Fatalf("row literal caret = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 22); !got.Found || got.Test != "BenchmarkTableLoop" || got.Pattern != "^BenchmarkTableLoop$/^(?:small_payload|large_payload)$/^encode$" {
		t.Fatalf("nested b.Loop inside table caret = %+v", got)
	}
	if got := ResolveCaretTarget([]byte(src), 38); !got.Found || got.Test != "BenchmarkTableLoop" || got.SubtestPath != "conditional" || got.Pattern != "^BenchmarkTableLoop$/^conditional$" {
		t.Fatalf("conditional b.Run with b.Loop caret = %+v", got)
	}
}

func TestResolveCaretTargetInFileCrossFileSuiteAndMultiRunner(t *testing.T) {
	dir := t.TempDir()
	hiddenDir := filepath.Join(dir, ".hidden")
	testdataDir := filepath.Join(dir, "testdata")
	if err := os.MkdirAll(hiddenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(testdataDir, 0o755); err != nil {
		t.Fatal(err)
	}

	runnerFile := filepath.Join(dir, "suite_test.go")
	runnerSrc := `package suitetest

import (
	"testing"

	"github.com/stretchr/testify/suite"
)

type AuthSuite struct {
	suite.Suite
}

func TestAuthPrimarySuite(t *testing.T) {
	suite.Run(t, new(AuthSuite))
}
`
	if err := os.WriteFile(runnerFile, []byte(runnerSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	ignoredHidden := filepath.Join(dir, ".ignored_test.go")
	if err := os.WriteFile(ignoredHidden, []byte("package suitetest\nfunc TestHiddenSuite(t *testing.T) { suite.Run(t, &AuthSuite{}) }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(testdataDir, "fixture_test.go"), []byte("package suitetest\nfunc TestFixtureSuite(t *testing.T) { suite.Run(t, &AuthSuite{}) }\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	methodsFile := filepath.Join(dir, "auth_methods_test.go")
	methodsSrc := `package suitetest

func (s *AuthSuite) TestLogin() {
	s.Run("valid token", func() {
		_ = 1
	})
	cases := []struct{ name string }{
		{name: "expired"},
		{name: "revoked"},
	}
	for _, tc := range cases {
		s.Run(tc.name, func() {
			s.Run("check", func() {
				_ = tc.name
			})
		})
	}
}
`
	if err := os.WriteFile(methodsFile, []byte(methodsSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	if orphan := ResolveCaretTarget([]byte(methodsSrc), 3); orphan.Found {
		t.Fatalf("expected ResolveCaretTarget without path not to scan directory, got %+v", orphan)
	}

	gotMethod := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 3, nil)
	if !gotMethod.Found || gotMethod.Test != "TestAuthPrimarySuite" || gotMethod.SubtestPath != "TestLogin" || gotMethod.Pattern != "^TestAuthPrimarySuite$/^TestLogin$" {
		t.Fatalf("cross-file suite method = %+v", gotMethod)
	}

	gotNested := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 5, nil)
	if !gotNested.Found || gotNested.Test != "TestAuthPrimarySuite" || gotNested.SubtestPath != "TestLogin/valid token" || gotNested.Pattern != "^TestAuthPrimarySuite$/^TestLogin$/^valid_token$" {
		t.Fatalf("cross-file suite nested subtest = %+v", gotNested)
	}

	gotTableRow := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 8, nil)
	if !gotTableRow.Found || gotTableRow.Test != "TestAuthPrimarySuite" || gotTableRow.SubtestPath != "TestLogin/expired" || gotTableRow.Pattern != "^TestAuthPrimarySuite$/^TestLogin$/^expired$" {
		t.Fatalf("cross-file suite table row subtest = %+v", gotTableRow)
	}

	gotLoop := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 14, nil)
	if !gotLoop.Found || gotLoop.Test != "TestAuthPrimarySuite" || gotLoop.Pattern != "^TestAuthPrimarySuite$/^TestLogin$/^(?:expired|revoked)$/^check$" {
		t.Fatalf("cross-file suite loop subtest = %+v", gotLoop)
	}

	extraRunnerFile := filepath.Join(dir, "extra_runner_test.go")
	if err := os.WriteFile(extraRunnerFile, []byte("package suitetest\nfunc TestDiskPlaceholder(t *testing.T) {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	unsavedExtraRunner := `package suitetest

import (
	"testing"

	"github.com/stretchr/testify/suite"
)

func TestAuthSecondarySuite(t *testing.T) {
	s := &AuthSuite{}
	suite.Run(t, s)
}
`
	readOverlay := func(p string) ([]byte, error) {
		if filepath.Clean(p) == filepath.Clean(extraRunnerFile) {
			return []byte(unsavedExtraRunner), nil
		}
		return os.ReadFile(p)
	}

	gotMultiMethod := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 3, readOverlay)
	if !gotMultiMethod.Found || gotMultiMethod.Test != "TestAuthSecondarySuite" || gotMultiMethod.Pattern != "^(?:TestAuthSecondarySuite|TestAuthPrimarySuite)$/^TestLogin$" {
		t.Fatalf("multi-runner pattern (alphabetical extra_runner before suite_test) = %+v", gotMultiMethod)
	}

	gotMultiNested := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 5, readOverlay)
	if !gotMultiNested.Found || gotMultiNested.Pattern != "^(?:TestAuthSecondarySuite|TestAuthPrimarySuite)$/^TestLogin$/^valid_token$" {
		t.Fatalf("multi-runner nested pattern = %+v", gotMultiNested)
	}

	gotMultiLoop := ResolveCaretTargetInFile(methodsFile, []byte(methodsSrc), 14, readOverlay)
	if !gotMultiLoop.Found || gotMultiLoop.Pattern != "^(?:TestAuthSecondarySuite|TestAuthPrimarySuite)$/^TestLogin$/^(?:expired|revoked)$/^check$" {
		t.Fatalf("multi-runner loop pattern = %+v", gotMultiLoop)
	}
}
