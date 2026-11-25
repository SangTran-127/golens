package refactor

import (
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

func TestInspectFuzzTest_StandaloneFunction(t *testing.T) {
	src := `package mathutil

func ComputeSum(a int, b int) int {
	return a + b
}
`

	plan, err := InspectFuzzTest("", "math.go", src, 3, 1, "", true, true)
	if err != nil {
		t.Fatalf("InspectFuzzTest returned unexpected error: %v", err)
	}
	if plan.Error != "" {
		t.Fatalf("expected empty plan.Error, got %q", plan.Error)
	}
	if plan.PackageName != "mathutil" {
		t.Fatalf("expected PackageName %q, got %q", "mathutil", plan.PackageName)
	}
	if plan.TargetFunc != "ComputeSum" {
		t.Fatalf("expected TargetFunc %q, got %q", "ComputeSum", plan.TargetFunc)
	}
	if plan.ReceiverType != "" {
		t.Fatalf("expected empty ReceiverType, got %q", plan.ReceiverType)
	}
	if plan.FuzzFuncName != "FuzzComputeSum" {
		t.Fatalf("expected FuzzFuncName %q, got %q", "FuzzComputeSum", plan.FuzzFuncName)
	}
	if plan.TargetFile != "math_test.go" {
		t.Fatalf("expected TargetFile %q, got %q", "math_test.go", plan.TargetFile)
	}
	if len(plan.Params) != 2 {
		t.Fatalf("expected 2 params, got %d", len(plan.Params))
	}
	if plan.Params[0] != (FuzzParamItem{Name: "a", Type: "int", Supported: true}) {
		t.Errorf("unexpected param[0]: %+v", plan.Params[0])
	}
	if plan.Params[1] != (FuzzParamItem{Name: "b", Type: "int", Supported: true}) {
		t.Errorf("unexpected param[1]: %+v", plan.Params[1])
	}
	if len(plan.Seeds) != 5 {
		t.Fatalf("expected 5 seed rows with includeEdgeSeeds=true, got %d", len(plan.Seeds))
	}

	mustContain := []string{
		"func FuzzComputeSum(f *testing.F)",
		"f.Add(0, 0)",
		"f.Add(42, 42)",
		"f.Add(-1, -1)",
		"f.Add(1024, 1024)",
		"f.Fuzz(func(t *testing.T, a int, b int)",
		"got1 := ComputeSum(a, b)",
		"got2 := ComputeSum(a, b)",
		"if got1 != got2 {",
		`t.Fatalf("non-deterministic output: %v != %v", got1, got2)`,
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	fset := token.NewFileSet()
	parsedFile, parseErr := parser.ParseFile(fset, plan.TargetFile, plan.NewContent, parser.ParseComments)
	if parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}
	if parsedFile.Name.Name != "mathutil" {
		t.Errorf("expected parsed package mathutil, got %s", parsedFile.Name.Name)
	}

	basicPlan, err := InspectFuzzTest("", "math.go", src, 3, 1, "ComputeSum", false, false)
	if err != nil {
		t.Fatalf("InspectFuzzTest (basic) returned unexpected error: %v", err)
	}
	if len(basicPlan.Seeds) != 2 {
		t.Fatalf("expected 2 baseline seed rows with includeEdgeSeeds=false, got %d", len(basicPlan.Seeds))
	}
	if strings.Contains(basicPlan.PreviewCode, "got1 != got2") {
		t.Errorf("expected no determinism check when checkDeterminism=false, got:\n%s", basicPlan.PreviewCode)
	}
	if !strings.Contains(basicPlan.PreviewCode, "_ = ComputeSum(a, b)") {
		t.Errorf("expected '_ = ComputeSum(a, b)' when checkDeterminism=false, got:\n%s", basicPlan.PreviewCode)
	}
}

func TestInspectFuzzTest_StructMethodAndExistingTestFile(t *testing.T) {
	tmpDir := t.TempDir()
	storeFile := filepath.Join(tmpDir, "store.go")
	testFile := filepath.Join(tmpDir, "store_test.go")

	storeSrc := `package store

type KVStore struct {
	namespace string
}

func (k *KVStore) Get(key string) string {
	return k.namespace + ":" + key
}
`
	existingTestSrc := `package store

import "testing"

func TestExisting(t *testing.T) {
	s := &KVStore{namespace: "dev"}
	if s.Get("k") == "" {
		t.Fatal("empty")
	}
}
`
	if err := os.WriteFile(storeFile, []byte(storeSrc), 0644); err != nil {
		t.Fatalf("failed to write store.go: %v", err)
	}
	if err := os.WriteFile(testFile, []byte(existingTestSrc), 0644); err != nil {
		t.Fatalf("failed to write store_test.go: %v", err)
	}

	plan, err := InspectFuzzTest(tmpDir, storeFile, storeSrc, 7, 1, "(*KVStore).Get", true, true)
	if err != nil {
		t.Fatalf("InspectFuzzTest returned unexpected error: %v", err)
	}
	if plan.FuzzFuncName != "FuzzKVStore_Get" {
		t.Fatalf("expected FuzzFuncName %q, got %q", "FuzzKVStore_Get", plan.FuzzFuncName)
	}
	if plan.ReceiverType != "*KVStore" {
		t.Fatalf("expected ReceiverType %q, got %q", "*KVStore", plan.ReceiverType)
	}
	if plan.TargetFile != testFile {
		t.Fatalf("expected TargetFile %q, got %q", testFile, plan.TargetFile)
	}

	mustContain := []string{
		"func FuzzKVStore_Get(f *testing.F)",
		`f.Add("")`,
		`f.Add("alpha")`,
		`f.Add("utf8_λ_00")`,
		"f.Fuzz(func(t *testing.T, key string)",
		"target := &KVStore{}",
		"got1 := target.Get(key)",
		"got2 := target.Get(key)",
		"if got1 != got2 {",
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	fset := token.NewFileSet()
	parsedFile, parseErr := parser.ParseFile(fset, testFile, plan.NewContent, parser.ParseComments)
	if parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}

	foundFuncs := map[string]bool{}
	for _, decl := range parsedFile.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name != nil {
			foundFuncs[fd.Name.Name] = true
		}
	}
	if !foundFuncs["TestExisting"] {
		t.Errorf("expected existing TestExisting function to be preserved in NewContent")
	}
	if !foundFuncs["FuzzKVStore_Get"] {
		t.Errorf("expected FuzzKVStore_Get function to be added in NewContent")
	}
}

func typeCheckFuzzPackage(t *testing.T, pkgName string, sources map[string]string) {
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

func TestInspectFuzzTest_EdgeCases_CompileAndRun(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		fileName    string
		src         string
		line        int
		funcName    string
		determinism bool
		mustContain []string
	}{
		{
			name:     "generic_function_and_comparable_result",
			pkgName:  "genutil",
			fileName: "clamp.go",
			src: `package genutil

func Clamp[T ~int | ~float64](v, lo, hi T) T {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
`,
			line:        3,
			funcName:    "Clamp",
			determinism: true,
			mustContain: []string{"FuzzClamp", "Clamp[int]("},
		},
		{
			name:     "generic_struct_pointer_receiver_and_slice_result",
			pkgName:  "ring",
			fileName: "ring.go",
			src: `package ring

type Ring[T any] struct {
	Items []T
}

func (r *Ring[T]) Snapshot(prefix string) []T {
	if len(r.Items) == 0 && prefix == "" {
		return nil
	}
	return append([]T(nil), r.Items...)
}
`,
			line:        7,
			funcName:    "Snapshot",
			determinism: true,
			mustContain: []string{"FuzzRing_Snapshot", "Ring[int]{}", "reflect.DeepEqual"},
		},
		{
			name:     "non_struct_defined_receiver_and_unexported_func",
			pkgName:  "num",
			fileName: "num.go",
			src: `package num

type Counter int

func (c *Counter) AddScaled(delta int) int {
	return int(*c) + delta
}

type box struct{ raw []byte }

func makeBox(s string) box {
	return box{raw: []byte(s)}
}
`,
			line:        5,
			funcName:    "AddScaled",
			determinism: true,
			mustContain: []string{"FuzzCounter_AddScaled"},
		},
		{
			name:     "unexported_uncomparable_struct_and_func_result",
			pkgName:  "box",
			fileName: "box.go",
			src: `package box

type result struct{ data []byte }

func parseBox(raw []byte) result {
	return result{data: append([]byte(nil), raw...)}
}
`,
			line:        5,
			funcName:    "parseBox",
			determinism: true,
			mustContain: []string{"FuzzParseBox", "reflect.DeepEqual"},
		},
		{
			name:     "name_clashes_params_and_aliased_imports",
			pkgName:  "clash",
			fileName: "clash.go",
			src: `//go:build darwin || linux

package clash

import (
	ctx "context"
	t "time"
)

type Service struct{}

func (s *Service) Handle(c ctx.Context, target, got1, f, zeroArg0 int, d t.Duration) (any, func() int, error) {
	return target + got1 + f + zeroArg0, nil, nil
}
`,
			line:        12,
			funcName:    "Handle",
			determinism: true,
			mustContain: []string{"//go:build darwin || linux", `ctx "context"`, `t "time"`, "FuzzService_Handle", "reflect.DeepEqual"},
		},
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module fuzzcheck\n\ngo 1.22\n"), 0644); err != nil {
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

			plan, err := InspectFuzzTest(pkgDir, srcPath, tc.src, tc.line, 1, tc.funcName, true, tc.determinism)
			if err != nil {
				t.Fatalf("InspectFuzzTest failed: %v", err)
			}
			if plan.Error != "" {
				t.Fatalf("plan.Error = %q", plan.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(plan.NewContent, want) {
					t.Errorf("expected %q in NewContent:\n%s", want, plan.NewContent)
				}
			}
			typeCheckFuzzPackage(t, tc.pkgName, map[string]string{
				tc.fileName:     tc.src,
				plan.TargetFile: plan.NewContent,
			})
			testPath := filepath.Join(pkgDir, filepath.Base(plan.TargetFile))
			if err := os.WriteFile(testPath, []byte(plan.NewContent), 0644); err != nil {
				t.Fatal(err)
			}

			cmd := exec.Command("go", "test", "-v", ".")
			cmd.Dir = pkgDir
			if out, runErr := cmd.CombinedOutput(); runErr != nil {
				t.Fatalf("go test failed: %v\n%s\nNewContent:\n%s", runErr, string(out), plan.NewContent)
			}
		})
	}
}

func TestInspectFuzzTest_ExternalTestPkgRedirectAndBuildTags(t *testing.T) {
	dir := t.TempDir()
	srcPath := filepath.Join(dir, "worker.go")
	extTestPath := filepath.Join(dir, "worker_test.go")
	ignoredPath := filepath.Join(dir, "ignored.go")

	src := `package worker

func Normalize(s string) string { return s }
`
	extTest := `package worker_test

import "testing"

func TestExternal(t *testing.T) {}
`
	ignored := `//go:build ignore

package worker

func IgnoredFn(x int) int { return x }
`
	for p, body := range map[string]string{srcPath: src, extTestPath: extTest, ignoredPath: ignored} {
		if err := os.WriteFile(p, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}

	plan, err := InspectFuzzTest(dir, srcPath, src, 3, 1, "Normalize", true, true)
	if err != nil {
		t.Fatalf("InspectFuzzTest error: %v", err)
	}
	if !strings.HasSuffix(plan.TargetFile, "worker_fuzz_test.go") {
		t.Fatalf("expected external test redirect to worker_fuzz_test.go, got %q", plan.TargetFile)
	}
	for _, fn := range plan.AvailableFunctions {
		if fn == "IgnoredFn" {
			t.Fatalf("expected build-ignored function excluded, got %v", plan.AvailableFunctions)
		}
	}
}
