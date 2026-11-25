package refactor

import (
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectStructConstructor_StandardConstructor(t *testing.T) {
	src := `package main

type KVStore struct {
	namespace  string
	maxRetries int
	items      map[string]string
}

func (k *KVStore) Get(key string) string {
	return k.namespace + ":" + key
}
`

	plan, err := InspectStructConstructor("", "store.go", src, 4, 1, "", false, true)
	if err != nil {
		t.Fatalf("InspectStructConstructor returned unexpected error: %v", err)
	}
	if plan.Error != "" {
		t.Fatalf("expected empty plan.Error, got %q", plan.Error)
	}
	if plan.PackageName != "main" {
		t.Fatalf("expected PackageName %q, got %q", "main", plan.PackageName)
	}
	if plan.TargetStruct != "KVStore" {
		t.Fatalf("expected TargetStruct %q, got %q", "KVStore", plan.TargetStruct)
	}
	if plan.ConstructorName != "NewKVStore" {
		t.Fatalf("expected ConstructorName %q, got %q", "NewKVStore", plan.ConstructorName)
	}
	if plan.IncludeOptions {
		t.Fatalf("expected IncludeOptions=false, got true")
	}
	if !plan.ReturnPointer {
		t.Fatalf("expected ReturnPointer=true, got false")
	}
	if len(plan.Fields) != 3 {
		t.Fatalf("expected 3 fields, got %d", len(plan.Fields))
	}

	wantFields := []ConstructorFieldItem{
		{FieldName: "namespace", ParamName: "namespace", FieldType: "string", OptionFuncName: "WithNamespace", IsMap: false},
		{FieldName: "maxRetries", ParamName: "maxRetries", FieldType: "int", OptionFuncName: "WithMaxRetries", IsMap: false},
		{FieldName: "items", ParamName: "items", FieldType: "map[string]string", OptionFuncName: "WithItems", IsMap: true},
	}
	for i, want := range wantFields {
		if plan.Fields[i] != want {
			t.Errorf("field[%d] = %+v, want %+v", i, plan.Fields[i], want)
		}
	}

	mustContain := []string{
		"func NewKVStore(namespace string, maxRetries int, items map[string]string) *KVStore",
		"return &KVStore{",
		"namespace:  namespace,",
		"maxRetries: maxRetries,",
		"items:      items,",
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	valPlan, err := InspectStructConstructor("", "store.go", src, 4, 1, "KVStore", false, false)
	if err != nil {
		t.Fatalf("InspectStructConstructor (value return) error: %v", err)
	}
	if !strings.Contains(valPlan.PreviewCode, "func NewKVStore(namespace string, maxRetries int, items map[string]string) KVStore") {
		t.Errorf("expected value return signature, got:\n%s", valPlan.PreviewCode)
	}
	if !strings.Contains(valPlan.PreviewCode, "return KVStore{") {
		t.Errorf("expected value literal return, got:\n%s", valPlan.PreviewCode)
	}
}

func TestInspectStructConstructor_FunctionalOptions(t *testing.T) {
	src := `package store

type Payload struct {
	ID string
}

type KVStore struct {
	namespace  string
	MaxRetries int
	data       map[string]string
}

func ExistingHelper() string {
	return "ok"
}
`

	plan, err := InspectStructConstructor("", "store.go", src, 8, 1, "KVStore", true, true)
	if err != nil {
		t.Fatalf("InspectStructConstructor returned unexpected error: %v", err)
	}
	if plan.TargetStruct != "KVStore" {
		t.Fatalf("expected TargetStruct %q, got %q", "KVStore", plan.TargetStruct)
	}
	if len(plan.AvailableStructs) != 2 {
		t.Fatalf("expected 2 available structs, got %v", plan.AvailableStructs)
	}

	mustContain := []string{
		"type KVStoreOption func(*KVStore)",
		"func WithNamespace(namespace string) KVStoreOption",
		"cfg.namespace = namespace",
		"func WithMaxRetries(maxRetries int) KVStoreOption",
		"cfg.MaxRetries = maxRetries",
		"func WithData(data map[string]string) KVStoreOption",
		"cfg.data = data",
		"func NewKVStore(opts ...KVStoreOption) *KVStore",
		"data: make(map[string]string),",
		"for _, opt := range opts {",
		"if opt != nil {",
		"opt(cfg)",
		"return cfg",
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	fset := token.NewFileSet()
	parsedFile, parseErr := parser.ParseFile(fset, "store.go", plan.NewContent, parser.ParseComments)
	if parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}

	foundTypes := map[string]bool{}
	foundFuncs := map[string]bool{}
	for _, decl := range parsedFile.Decls {
		switch d := decl.(type) {
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				if ts, ok := spec.(*ast.TypeSpec); ok && ts.Name != nil {
					foundTypes[ts.Name.Name] = true
				}
			}
		case *ast.FuncDecl:
			if d.Name != nil {
				foundFuncs[d.Name.Name] = true
			}
		}
	}

	for _, wantType := range []string{"Payload", "KVStore", "KVStoreOption"} {
		if !foundTypes[wantType] {
			t.Errorf("expected type %q in NewContent, got %v", wantType, foundTypes)
		}
	}
	for _, wantFn := range []string{"ExistingHelper", "WithNamespace", "WithMaxRetries", "WithData", "NewKVStore"} {
		if !foundFuncs[wantFn] {
			t.Errorf("expected func %q in NewContent, got %v", wantFn, foundFuncs)
		}
	}
}

func TestInspectStructConstructor_PreservesExistingConstructorDefaultValues(t *testing.T) {
	src := `package main

import "fmt"

type Config struct {
	Secure bool
}

func NewConfig() *Config {
	return &Config{Secure: true}
}

func main() {
	fmt.Println(NewConfig().Secure)
}
`
	plan, err := InspectStructConstructor("", "main.go", src, 5, 1, "Config", true, true)
	if err != nil {
		t.Fatalf("InspectStructConstructor failed: %v", err)
	}
	if !strings.Contains(plan.PreviewCode, "Secure: true,") {
		t.Fatalf("expected generated constructor to preserve existing default 'Secure: true', got:\n%s", plan.PreviewCode)
	}
}

func typeCheckConstructorOutput(t *testing.T, pkgName, filename, src string) {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse %s failed: %v\n%s", filename, err, src)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check(pkgName, fset, []*ast.File{f}, nil); err != nil {
		t.Fatalf("typecheck %s failed: %v\n%s", filename, err, src)
	}
}

func TestInspectStructConstructor_EdgeCases_TypeCheck(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		src         string
		line        int
		structName  string
		withOptions bool
		initColls   bool
		mustContain []string
		mustOmit    []string
	}{
		{
			name:    "generic_struct_with_options_and_embedded",
			pkgName: "cache",
			src: `package cache

import "sync"

type Meta struct{ Tag string }

type Cache[K comparable, V any] struct {
	Meta
	mu      sync.Mutex
	entries map[K]V
	label   string
}
`,
			line:        7,
			structName:  "Cache",
			withOptions: true,
			initColls:   true,
			mustContain: []string{
				"type CacheOption[K comparable, V any] func(*Cache[K, V])",
				"func WithMeta[K comparable, V any](",
				"func NewCache[K comparable, V any](opts ...CacheOption[K, V]) *Cache[K, V]",
				"entries: make(map[K]V),",
			},
			mustOmit: []string{"WithMu"},
		},
		{
			name:    "generic_struct_standard_constructor",
			pkgName: "pair",
			src: `package pair

type Pair[A, B any] struct {
	First  A
	Second B
}
`,
			line:        3,
			structName:  "Pair",
			withOptions: false,
			initColls:   true,
			mustContain: []string{"func NewPair[A, B any](first A, second B) *Pair[A, B]"},
		},
		{
			name:    "unexported_struct_and_name_clashes",
			pkgName: "clashes",
			src: `package clashes

import (
	"net/http"
	cfg "strings"
)

type builder interface{}

type service struct {
	opts   int
	cfg    string
	make   bool
	client *http.Client
	buf    cfg.Builder
	_      builder
}
`,
			line:        10,
			structName:  "service",
			withOptions: true,
			initColls:   true,
			mustContain: []string{"serviceOption", "opts ...serviceOption"},
		},
		{
			name:    "preserves_build_tag_comments_and_replaces_existing",
			pkgName: "app",
			src: `//go:build darwin || linux

package app

// Runner executes jobs.
type Runner struct {
	Workers int
	Strict  bool
}

type RunnerOption func(*Runner)

func WithRunnerWorkers(v int) RunnerOption {
	return func(r *Runner) { r.Workers = v }
}

func NewRunner(opts ...RunnerOption) *Runner {
	r := &Runner{Strict: true}
	for _, o := range opts {
		o(r)
	}
	return r
}

// KeepHelper stays untouched.
func KeepHelper() int { return 7 }
`,
			line:        6,
			structName:  "Runner",
			withOptions: true,
			initColls:   true,
			mustContain: []string{"//go:build darwin || linux", "// Runner executes jobs.", "// KeepHelper stays untouched.", "Strict: true,"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan, err := InspectStructConstructor("", "model.go", tc.src, tc.line, 1, tc.structName, tc.withOptions, tc.initColls)
			if err != nil {
				t.Fatalf("InspectStructConstructor error: %v", err)
			}
			if plan.Error != "" {
				t.Fatalf("plan.Error = %q", plan.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(plan.NewContent, want) {
					t.Errorf("expected %q in NewContent:\n%s", want, plan.NewContent)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(plan.NewContent, forbid) {
					t.Errorf("did not expect %q in NewContent:\n%s", forbid, plan.NewContent)
				}
			}
			typeCheckConstructorOutput(t, tc.pkgName, "model.go", plan.NewContent)
		})
	}
}

func TestInspectStructConstructor_BuildTagMultiFile(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "main.go")
	mainSrc := `package main

type Service struct {
	Name string
}
`
	ignoredSrc := `//go:build ignore

package main

type IgnoredOther struct{ X int }
`
	if err := os.WriteFile(mainPath, []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.go"), []byte(ignoredSrc), 0644); err != nil {
		t.Fatal(err)
	}

	plan, err := InspectStructConstructor(dir, mainPath, mainSrc, 3, 1, "Service", false, true)
	if err != nil {
		t.Fatalf("InspectStructConstructor failed: %v", err)
	}
	for _, s := range plan.AvailableStructs {
		if s == "IgnoredOther" {
			t.Fatalf("expected build-ignored struct excluded, got %v", plan.AvailableStructs)
		}
	}
	typeCheckConstructorOutput(t, "main", mainPath, plan.NewContent)
}
