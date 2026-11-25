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

func TestInspectBenchmarkGen_StandaloneFunction(t *testing.T) {
	src := `package strutil

func FormatBatch(prefix string, count int, tags []string, verbose bool) string {
	return prefix
}
`

	plan, err := InspectBenchmarkGen("", "format.go", src, 3, 1, "", true, false, false)
	if err != nil {
		t.Fatalf("InspectBenchmarkGen returned unexpected error: %v", err)
	}
	if plan.Error != "" {
		t.Fatalf("expected empty plan.Error, got %q", plan.Error)
	}
	if plan.PackageName != "strutil" {
		t.Fatalf("expected PackageName %q, got %q", "strutil", plan.PackageName)
	}
	if plan.TargetFunc != "FormatBatch" {
		t.Fatalf("expected TargetFunc %q, got %q", "FormatBatch", plan.TargetFunc)
	}
	if plan.ReceiverType != "" {
		t.Fatalf("expected empty ReceiverType, got %q", plan.ReceiverType)
	}
	if plan.BenchmarkName != "BenchmarkFormatBatch" {
		t.Fatalf("expected BenchmarkName %q, got %q", "BenchmarkFormatBatch", plan.BenchmarkName)
	}
	if plan.TargetFile != "format_test.go" {
		t.Fatalf("expected TargetFile %q, got %q", "format_test.go", plan.TargetFile)
	}
	if plan.IsExistingTestFile {
		t.Fatalf("expected IsExistingTestFile=false for non-existent format_test.go")
	}
	if len(plan.Params) != 4 {
		t.Fatalf("expected 4 params, got %d", len(plan.Params))
	}
	wantParams := []BenchmarkParamInfo{
		{Name: "prefix", Type: "string", SampleExpr: `"sample"`},
		{Name: "count", Type: "int", SampleExpr: "100"},
		{Name: "tags", Type: "[]string", SampleExpr: `[]string{"a", "b", "c"}`},
		{Name: "verbose", Type: "bool", SampleExpr: "true"},
	}
	for i, want := range wantParams {
		if plan.Params[i] != want {
			t.Errorf("param[%d] = %+v, want %+v", i, plan.Params[i], want)
		}
	}

	mustContainSingle := []string{
		"func BenchmarkFormatBatch(b *testing.B)",
		"b.ReportAllocs()",
		"b.ResetTimer()",
		"for i := 0; i < b.N; i++ {",
		`_ = FormatBatch("sample", 100, []string{"a", "b", "c"}, true)`,
	}
	for _, needle := range mustContainSingle {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	fset := token.NewFileSet()
	parsedFile, parseErr := parser.ParseFile(fset, plan.TargetFile, plan.NewContent, parser.ParseComments)
	if parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}
	if parsedFile.Name.Name != "strutil" {
		t.Errorf("expected parsed package strutil, got %s", parsedFile.Name.Name)
	}

	parallelTablePlan, err := InspectBenchmarkGen("", "format.go", src, 3, 1, "FormatBatch", true, true, true)
	if err != nil {
		t.Fatalf("InspectBenchmarkGen (parallel+table) returned unexpected error: %v", err)
	}
	mustContainParallelTable := []string{
		"benchmarks := []struct {",
		"name",
		`{name: "small", prefix: "sample", count: 100, tags: []string{"a", "b", "c"}, verbose: true}`,
		"for _, bm := range benchmarks {",
		"b.Run(bm.name, func(b *testing.B) {",
		"b.ReportAllocs()",
		"b.ResetTimer()",
		"b.RunParallel(func(pb *testing.PB) {",
		"for pb.Next() {",
		"_ = FormatBatch(bm.prefix, bm.count, bm.tags, bm.verbose)",
	}
	for _, needle := range mustContainParallelTable {
		if !strings.Contains(parallelTablePlan.PreviewCode, needle) {
			t.Errorf("Parallel+Table PreviewCode missing %q:\n%s", needle, parallelTablePlan.PreviewCode)
		}
	}
	if _, parseErr := parser.ParseFile(token.NewFileSet(), parallelTablePlan.TargetFile, parallelTablePlan.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("parallel+table NewContent failed to parse: %v\n%s", parseErr, parallelTablePlan.NewContent)
	}
}

func TestInspectBenchmarkGen_StructMethodAndExistingTestFile(t *testing.T) {
	tmpDir := t.TempDir()
	cacheFile := filepath.Join(tmpDir, "cache.go")
	testFile := filepath.Join(tmpDir, "cache_test.go")

	cacheSrc := `package cache

type LRUStore struct {
	capacity int
}

func (c *LRUStore) Lookup(key string) (string, bool) {
	return key, true
}
`
	existingTestSrc := `package cache

import "testing"

func TestExisting(t *testing.T) {
	store := &LRUStore{capacity: 16}
	if _, ok := store.Lookup("k"); !ok {
		t.Fatal("expected hit")
	}
}
`
	if err := os.WriteFile(cacheFile, []byte(cacheSrc), 0644); err != nil {
		t.Fatalf("failed to write cache.go: %v", err)
	}
	if err := os.WriteFile(testFile, []byte(existingTestSrc), 0644); err != nil {
		t.Fatalf("failed to write cache_test.go: %v", err)
	}

	plan, err := InspectBenchmarkGen(tmpDir, cacheFile, cacheSrc, 7, 1, "(*LRUStore).Lookup", true, true, false)
	if err != nil {
		t.Fatalf("InspectBenchmarkGen returned unexpected error: %v", err)
	}
	if plan.BenchmarkName != "BenchmarkLRUStore_Lookup" {
		t.Fatalf("expected BenchmarkName %q, got %q", "BenchmarkLRUStore_Lookup", plan.BenchmarkName)
	}
	if plan.ReceiverType != "*LRUStore" {
		t.Fatalf("expected ReceiverType %q, got %q", "*LRUStore", plan.ReceiverType)
	}
	if plan.TargetFile != testFile {
		t.Fatalf("expected TargetFile %q, got %q", testFile, plan.TargetFile)
	}
	if !plan.IsExistingTestFile {
		t.Fatalf("expected IsExistingTestFile=true when cache_test.go exists on disk")
	}

	mustContain := []string{
		"func BenchmarkLRUStore_Lookup(b *testing.B)",
		"target := &LRUStore{}",
		"b.ReportAllocs()",
		"b.ResetTimer()",
		"b.RunParallel(func(pb *testing.PB) {",
		"for pb.Next() {",
		`_, _ = target.Lookup("sample")`,
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
	if !foundFuncs["BenchmarkLRUStore_Lookup"] {
		t.Errorf("expected BenchmarkLRUStore_Lookup function to be added in NewContent")
	}
}

func TestInspectBenchmarkGen_LineSelectionAndReplaceExisting(t *testing.T) {
	tmpDir := t.TempDir()
	workerFile := filepath.Join(tmpDir, "worker.go")
	testFile := filepath.Join(tmpDir, "worker_test.go")

	workerSrc := `package worker

func Warmup() {
}

func ProcessVariadic(tag string, values ...int) error {
	return nil
}
`
	existingBenchSrc := `package worker

import "testing"

func BenchmarkProcessVariadic(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_ = ProcessVariadic("old", 1)
	}
}
`
	if err := os.WriteFile(workerFile, []byte(workerSrc), 0644); err != nil {
		t.Fatalf("failed to write worker.go: %v", err)
	}
	if err := os.WriteFile(testFile, []byte(existingBenchSrc), 0644); err != nil {
		t.Fatalf("failed to write worker_test.go: %v", err)
	}

	plan, err := InspectBenchmarkGen(tmpDir, workerFile, workerSrc, 6, 1, "", false, false, true)
	if err != nil {
		t.Fatalf("InspectBenchmarkGen returned unexpected error: %v", err)
	}
	if plan.TargetFunc != "ProcessVariadic" {
		t.Fatalf("expected line 6 to select ProcessVariadic, got %q", plan.TargetFunc)
	}
	if len(plan.AvailableFuncs) != 2 {
		t.Fatalf("expected 2 available functions, got %v", plan.AvailableFuncs)
	}
	if strings.Contains(plan.PreviewCode, "b.ReportAllocs()") {
		t.Errorf("expected no b.ReportAllocs() when reportAllocs=false, got:\n%s", plan.PreviewCode)
	}
	if strings.Contains(plan.NewContent, `"old"`) {
		t.Errorf("expected existing BenchmarkProcessVariadic to be replaced in NewContent, got:\n%s", plan.NewContent)
	}
	if _, parseErr := parser.ParseFile(token.NewFileSet(), testFile, plan.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("updated NewContent failed to parse: %v\n%s", parseErr, plan.NewContent)
	}
}

func typeCheckBenchPackage(t *testing.T, pkgName string, sources map[string]string) {
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

func TestInspectBenchmarkGen_EdgeCases_CompileAndRun(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		fileName    string
		src         string
		line        int
		funcName    string
		reportAlloc bool
		parallel    bool
		tableDriven bool
		mustContain []string
	}{
		{
			name:     "generic_function_sum",
			pkgName:  "alg",
			fileName: "sum.go",
			src: `package alg

func SumSlice[T ~int | ~float64](xs []T) T {
	var total T
	for _, x := range xs {
		total += x
	}
	return total
}
`,
			line:        3,
			funcName:    "SumSlice",
			reportAlloc: true,
			parallel:    false,
			tableDriven: false,
			mustContain: []string{"BenchmarkSumSlice", "SumSlice[int]("},
		},
		{
			name:     "generic_struct_pointer_receiver",
			pkgName:  "store",
			fileName: "store.go",
			src: `package store

type Cache[K comparable, V any] struct {
	Data map[K]V
}

func (c *Cache[K, V]) Put(k K, v V) int {
	if c.Data == nil {
		c.Data = map[K]V{}
	}
	c.Data[k] = v
	return len(c.Data)
}
`,
			line:        7,
			funcName:    "Put",
			reportAlloc: true,
			parallel:    false,
			tableDriven: true,
			mustContain: []string{"BenchmarkCache_Put", "Cache[int, int]{}"},
		},
		{
			name:     "non_struct_defined_receiver_and_pointer_param",
			pkgName:  "scale",
			fileName: "scale.go",
			src: `package scale

type Factor int

func (f Factor) Apply(target *Factor) int {
	if target == nil {
		return int(f)
	}
	return int(f) + int(*target)
}
`,
			line:        5,
			funcName:    "Apply",
			reportAlloc: false,
			parallel:    false,
			tableDriven: false,
			mustContain: []string{"BenchmarkFactor_Apply", "new(Factor)"},
		},
		{
			name:     "variadic_table_driven_and_name_clashes",
			pkgName:  "clash",
			fileName: "clash.go",
			src: `//go:build darwin || linux

package clash

import b "bytes"

func joinBuf(bm, pb *b.Buffer, benchmarks int, i string, vals ...int) int {
	_ = bm
	_ = pb
	return benchmarks + len(i) + len(vals)
}
`,
			line:        7,
			funcName:    "joinBuf",
			reportAlloc: true,
			parallel:    true,
			tableDriven: true,
			mustContain: []string{"//go:build darwin || linux", `b "bytes"`, "BenchmarkJoinBuf", "..."},
		},
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module benchcheck\n\ngo 1.22\n"), 0644); err != nil {
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

			plan, err := InspectBenchmarkGen(pkgDir, srcPath, tc.src, tc.line, 1, tc.funcName, tc.reportAlloc, tc.parallel, tc.tableDriven)
			if err != nil {
				t.Fatalf("InspectBenchmarkGen failed: %v", err)
			}
			if plan.Error != "" {
				t.Fatalf("plan.Error = %q", plan.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(plan.NewContent, want) {
					t.Errorf("expected %q in NewContent:\n%s", want, plan.NewContent)
				}
			}
			typeCheckBenchPackage(t, tc.pkgName, map[string]string{
				tc.fileName:     tc.src,
				plan.TargetFile: plan.NewContent,
			})
			testPath := filepath.Join(pkgDir, filepath.Base(plan.TargetFile))
			if err := os.WriteFile(testPath, []byte(plan.NewContent), 0644); err != nil {
				t.Fatal(err)
			}

			cmd := exec.Command("go", "test", "-run=^$", "-bench=.", "-benchtime=1x", ".")
			cmd.Dir = pkgDir
			if out, runErr := cmd.CombinedOutput(); runErr != nil {
				t.Fatalf("go test -bench failed: %v\n%s\nNewContent:\n%s", runErr, string(out), plan.NewContent)
			}
		})
	}
}

func TestInspectBenchmarkGen_ExternalTestRedirectAndBuildTags(t *testing.T) {
	dir := t.TempDir()
	srcPath := filepath.Join(dir, "job.go")
	extTestPath := filepath.Join(dir, "job_test.go")
	ignoredPath := filepath.Join(dir, "ignored.go")

	src := `package job

func Run(n int) int { return n }
`
	extTest := `package job_test

import "testing"

func TestExternal(t *testing.T) {}
`
	ignored := `//go:build ignore

package job

func IgnoredBenchTarget(x int) int { return x }
`
	for p, body := range map[string]string{srcPath: src, extTestPath: extTest, ignoredPath: ignored} {
		if err := os.WriteFile(p, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}

	plan, err := InspectBenchmarkGen(dir, srcPath, src, 3, 1, "Run", true, false, false)
	if err != nil {
		t.Fatalf("InspectBenchmarkGen error: %v", err)
	}
	if !strings.HasSuffix(plan.TargetFile, "job_bench_test.go") {
		t.Fatalf("expected external test redirect to job_bench_test.go, got %q", plan.TargetFile)
	}
	for _, fn := range plan.AvailableFuncs {
		if fn == "IgnoredBenchTarget" {
			t.Fatalf("expected build-ignored function excluded, got %v", plan.AvailableFuncs)
		}
	}
}
