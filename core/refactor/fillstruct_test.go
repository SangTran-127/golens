package refactor

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

func TestFillStructFields_EmptyStructLiteral(t *testing.T) {
	dir := t.TempDir()
	src := `package main

import "time"

type Profile struct {
	Bio string
}

type ServerConfig struct {
	Host     string
	Port     int
	TLS      bool
	Tags     []string
	Headers  map[string]string
	Timeout  time.Duration
	Profile  Profile
	Parent   *ServerConfig
	Callback func(int) error
	Done     chan struct{}
	LastErr  error
	Meta     any
}

func main() {
	cfg := &ServerConfig{}
	_ = cfg
}
`
	filePath := filepath.Join(dir, "main.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	raw, err := FillStructFields(dir, filePath, src, 24, 10)
	if err != nil {
		t.Fatalf("FillStructFields failed: %v (raw=%s)", err, raw)
	}

	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if res.Error != "" {
		t.Fatalf("unexpected error in result: %s", res.Error)
	}
	if res.StructName != "ServerConfig" {
		t.Fatalf("expected structName=ServerConfig, got %q", res.StructName)
	}
	if res.AddedFieldCount != 12 {
		t.Fatalf("expected addedFieldCount=12, got %d (%v)", res.AddedFieldCount, res.AddedFields)
	}

	expectedChecks := []string{
		`Host: ""`,
		`Port: 0`,
		`TLS: false`,
		`Tags: nil`,
		`Headers: nil`,
		`Timeout: 0`,
		`Profile: Profile{}`,
		`Parent: nil`,
		`Callback: nil`,
		`Done: nil`,
		`LastErr: nil`,
		`Meta: nil`,
	}
	for _, want := range expectedChecks {
		if !strings.Contains(res.UpdatedSource, want) {
			t.Errorf("updatedSource missing %q:\n%s", want, res.UpdatedSource)
		}
	}
}

func TestFillStructFields_PartiallyFilledCrossFileAndCustomTypes(t *testing.T) {
	dir := t.TempDir()
	storeSrc := `package main

type StoreMetaType map[string]string
type RetryLimit int
type NamespacePrefix string

type AuditConfig struct {
	Enabled bool
}

type KVStore struct {
	namespace string
	prefix    NamespacePrefix
	maxItems  RetryLimit
	readonly  bool
	meta      StoreMetaType
	audit     AuditConfig
	onEvict   func(key string)
}
`
	mainSrc := `package main

func main() {
	s := &KVStore{namespace: "ns"}
	_ = s
}
`
	storePath := filepath.Join(dir, "store.go")
	mainPath := filepath.Join(dir, "main.go")
	if err := os.WriteFile(storePath, []byte(storeSrc), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}
	if err := os.WriteFile(mainPath, []byte(mainSrc), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	raw, err := FillStructFields(dir, mainPath, mainSrc, 4, 8)
	if err != nil {
		t.Fatalf("FillStructFields failed: %v", err)
	}

	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if res.StructName != "KVStore" {
		t.Fatalf("expected structName=KVStore, got %q", res.StructName)
	}
	if res.AddedFieldCount != 6 {
		t.Fatalf("expected addedFieldCount=6, got %d (%v)", res.AddedFieldCount, res.AddedFields)
	}

	expected := `&KVStore{namespace: "ns", prefix: "", maxItems: 0, readonly: false, meta: nil, audit: AuditConfig{}, onEvict: nil}`
	if !strings.Contains(res.UpdatedSource, expected) {
		t.Fatalf("expected updatedSource to contain:\n%s\ngot:\n%s", expected, res.UpdatedSource)
	}
}

func TestFillStructFields_MultiLineCompositeLit(t *testing.T) {
	dir := t.TempDir()
	src := `package main

type Payload struct {
	UserName string
	Count    int
	Active   bool
	Tags     []string
}

func build() *Payload {
	return &Payload{
		UserName: "alice",
	}
}
`
	filePath := filepath.Join(dir, "payload.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("write payload.go: %v", err)
	}

	raw, err := FillStructFields(dir, filePath, src, 12, 5)
	if err != nil {
		t.Fatalf("FillStructFields failed: %v", err)
	}

	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if res.StructName != "Payload" {
		t.Fatalf("expected Payload, got %q", res.StructName)
	}
	if res.AddedFieldCount != 3 {
		t.Fatalf("expected 3 added fields, got %d (%v)", res.AddedFieldCount, res.AddedFields)
	}
	for _, want := range []string{`UserName: "alice",`, `Count: 0,`, `Active: false,`, `Tags: nil,`} {
		if !strings.Contains(res.UpdatedSource, want) {
			t.Errorf("expected multi-line output to contain %q, got:\n%s", want, res.UpdatedSource)
		}
	}
}

func TestFillStructFields_FallbackFromStructTypeDecl(t *testing.T) {
	dir := t.TempDir()
	src := `package main

type KVStore struct {
	namespace string
	limit     int
}

func NewKVStore() *KVStore {
	return &KVStore{}
}
`
	filePath := filepath.Join(dir, "store.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}

	raw, err := FillStructFields(dir, filePath, src, 3, 6)
	if err != nil {
		t.Fatalf("FillStructFields fallback failed: %v", err)
	}

	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if res.StructName != "KVStore" || res.AddedFieldCount != 2 {
		t.Fatalf("unexpected fallback result: %+v", res)
	}
	if !strings.Contains(res.UpdatedSource, `return &KVStore{namespace: "", limit: 0}`) {
		t.Fatalf("unexpected updatedSource:\n%s", res.UpdatedSource)
	}
}

func TestFillStructFields_ImportedNumericAndInterfaceTypes(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/fillmode\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}
	src := `package main

import "os"

type Config struct {
	Mode os.FileMode
}

func main() {
	_ = Config{}
}
`
	filePath := filepath.Join(dir, "main.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	raw, err := FillStructFields(dir, filePath, src, 10, 12)
	if err != nil {
		t.Fatalf("FillStructFields failed: %v", err)
	}

	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if res.Error != "" {
		t.Fatalf("unexpected error in result: %s", res.Error)
	}
	if !strings.Contains(res.UpdatedSource, `Config{Mode: 0}`) {
		t.Fatalf("expected Config{Mode: 0}, got:\n%s", res.UpdatedSource)
	}
	if err := os.WriteFile(filePath, []byte(res.UpdatedSource), 0644); err != nil {
		t.Fatalf("write updated main.go: %v", err)
	}
	cmd := exec.Command("go", "build", ".")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("expected generated code to compile cleanly, got error %v:\n%s", err, string(out))
	}
}

func typeCheckFillFiles(t *testing.T, pkgName string, sources map[string]string) {
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

func lineColAtSubstring(src, sub string) (int, int) {
	off := strings.Index(src, sub)
	if off < 0 {
		return -1, -1
	}
	line := 1 + strings.Count(src[:off], "\n")
	lastNL := strings.LastIndexByte(src[:off], '\n')
	col := off - lastNL + 1
	return line, col
}

func TestFillStructFields_EdgeCases_TypeCheck(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		src         string
		cursorNeed  string
		mustContain []string
		mustOmit    []string
	}{
		{
			name:    "generic_struct_concrete_instantiation",
			pkgName: "box",
			src: `package box

type Box[K comparable, V any] struct {
	Key   K
	Value V
	Tags  []V
}

func makeBox() Box[string, int] {
	return Box[string, int]{}
}
`,
			cursorNeed:  "Box[string, int]{}",
			mustContain: []string{`Key: ""`, `Value: 0`, `Tags: nil`},
		},
		{
			name:    "generic_struct_inside_generic_function",
			pkgName: "box",
			src: `package box

type Pair[A, B any] struct {
	First  A
	Second B
}

func zeroPair[T, U any]() Pair[T, U] {
	return Pair[T, U]{}
}
`,
			cursorNeed:  "Pair[T, U]{}",
			mustContain: []string{"First: *new(T)", "Second: *new(U)"},
		},
		{
			name:    "embedded_struct_and_pointer_fields",
			pkgName: "embed",
			src: `package embed

type Meta struct{ ID int }
type Logger struct{ Level string }

type Service struct {
	Meta
	*Logger
	Name string
}

func build() Service {
	return Service{}
}
`,
			cursorNeed:  "Service{}",
			mustContain: []string{"Meta: Meta{}", "Logger: nil", `Name: ""`},
		},
		{
			name:    "multiline_preserves_comments_and_aliased_external_types",
			pkgName: "web",
			src: `package web

import (
	h "net/http"
	tm "time"
)

type Req struct {
	Header h.Header
	Since  tm.Time
	Count  int
}

func build() Req {
	// leading comment inside function
	return Req{
		// keep comment on Count
		Count: 5,
	}
}
`,
			cursorNeed:  "// keep comment on Count",
			mustContain: []string{"// keep comment on Count", "Count: 5", "Header:", "Since:"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			line, col := lineColAtSubstring(tc.src, tc.cursorNeed)
			if line < 0 {
				t.Fatalf("cursor target %q not found", tc.cursorNeed)
			}
			raw, callErr := FillStructFields("", "main.go", tc.src, line, col)
			if callErr != nil {
				t.Fatalf("FillStructFields error: %v", callErr)
			}
			var res FillStructResult
			if err := json.Unmarshal([]byte(raw), &res); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if res.Error != "" {
				t.Fatalf("res.Error = %q", res.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(res.UpdatedSource, want) {
					t.Errorf("expected %q in UpdatedSource:\n%s", want, res.UpdatedSource)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(res.UpdatedSource, forbid) {
					t.Errorf("did not expect %q in UpdatedSource:\n%s", forbid, res.UpdatedSource)
				}
			}
			typeCheckFillFiles(t, tc.pkgName, map[string]string{"main.go": res.UpdatedSource})
		})
	}
}

func TestFillStructFields_CrossPackageSkipsUnexportedAndBuildTags(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module fillmod\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}
	accountSrc := `package fillmod

type Account struct {
	Name   string
	secret string
}
`
	ignoredSrc := `//go:build ignore

package fillmod

type Account struct {
	IgnoredField int
}
`
	testSrc := `package fillmod_test

import "fillmod"

func buildAccount() fillmod.Account {
	return fillmod.Account{}
}
`
	if err := os.WriteFile(filepath.Join(dir, "account.go"), []byte(accountSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "account_ignored.go"), []byte(ignoredSrc), 0644); err != nil {
		t.Fatal(err)
	}
	testPath := filepath.Join(dir, "account_test.go")
	if err := os.WriteFile(testPath, []byte(testSrc), 0644); err != nil {
		t.Fatal(err)
	}

	line, col := lineColAtSubstring(testSrc, "fillmod.Account{}")
	raw, callErr := FillStructFields(dir, testPath, testSrc, line, col)
	if callErr != nil {
		t.Fatalf("FillStructFields error: %v", callErr)
	}
	var res FillStructResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("res.Error = %q", res.Error)
	}
	if !strings.Contains(res.UpdatedSource, `Name: ""`) {
		t.Fatalf("expected exported field Name filled:\n%s", res.UpdatedSource)
	}
	if strings.Contains(res.UpdatedSource, "secret") || strings.Contains(res.UpdatedSource, "IgnoredField") {
		t.Fatalf("did not expect unexported or build-ignored field in external test:\n%s", res.UpdatedSource)
	}
	if err := os.WriteFile(testPath, []byte(res.UpdatedSource), 0644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "test", "-c", ".")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go test -c failed: %v\n%s\nupdated:\n%s", err, string(out), res.UpdatedSource)
	}
}
