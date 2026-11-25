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

func TestGenerateInterfaceMock_StoreReader(t *testing.T) {
	dir := t.TempDir()
	srcFile := filepath.Join(dir, "store.go")
	src := `package store

type StoreReader interface {
	Get(key string) (string, bool)
	Keys() []string
}

type StoreWriter interface {
	Set(key string, val string) error
	Delete(key string)
}
`
	if err := os.WriteFile(srcFile, []byte(src), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}

	res, err := GenerateInterfaceMock(dir, srcFile, 4, 1, "", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock error: %v", err)
	}

	if res.PackageName != "store" {
		t.Errorf("expected packageName 'store', got %q", res.PackageName)
	}
	if res.InterfaceName != "StoreReader" {
		t.Errorf("expected interfaceName 'StoreReader', got %q", res.InterfaceName)
	}
	if res.MockName != "MockStoreReader" {
		t.Errorf("expected mockName 'MockStoreReader', got %q", res.MockName)
	}
	if res.MethodCount != 2 {
		t.Errorf("expected methodCount 2, got %d", res.MethodCount)
	}
	if res.SuggestedFileName != "mock_storereader_test.go" {
		t.Errorf("expected suggestedFileName 'mock_storereader_test.go', got %q", res.SuggestedFileName)
	}
	if len(res.AvailableInterfaces) != 2 || res.AvailableInterfaces[0] != "StoreReader" || res.AvailableInterfaces[1] != "StoreWriter" {
		t.Errorf("unexpected availableInterfaces: %v", res.AvailableInterfaces)
	}

	for _, needle := range []string{
		"type MockStoreReader struct",
		"mu sync.Mutex",
		"GetFunc",
		"GetCalls []struct",
		"Key string",
		"KeysFunc",
		"KeysCalls int",
		"var _ StoreReader = (*MockStoreReader)(nil)",
		"m.mu.Lock()",
		"m.mu.Unlock()",
		`return "", false`,
		"return nil",
	} {
		if !strings.Contains(res.GeneratedCode, needle) {
			t.Errorf("expected GeneratedCode to contain %q, got:\n%s", needle, res.GeneratedCode)
		}
	}

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, res.SuggestedFileName, res.StandaloneFileCode, parser.AllErrors); err != nil {
		t.Fatalf("StandaloneFileCode failed to parse: %v\ncode:\n%s", err, res.StandaloneFileCode)
	}
}

func TestGenerateInterfaceMock_LineAndExplicitSelection(t *testing.T) {
	dir := t.TempDir()
	srcFile := filepath.Join(dir, "service.go")
	src := `package service

type User struct {
	ID   int
	Name string
}

type Finder interface {
	Find(id int) (User, error)
}

type Logger interface {
	Log(format string, args ...any)
	Flush([]byte) (int, error)
}
`
	if err := os.WriteFile(srcFile, []byte(src), 0644); err != nil {
		t.Fatalf("write service.go: %v", err)
	}

	resByLine, err := GenerateInterfaceMock(dir, srcFile, 13, 2, "", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock by line error: %v", err)
	}
	if resByLine.InterfaceName != "Logger" {
		t.Errorf("expected Logger at line 13, got %q", resByLine.InterfaceName)
	}
	if !strings.Contains(resByLine.GeneratedCode, "Args []any") {
		t.Errorf("expected variadic parameter to become []any in Calls struct, got:\n%s", resByLine.GeneratedCode)
	}
	if !strings.Contains(resByLine.GeneratedCode, "m.LogFunc(format, args...)") {
		t.Errorf("expected variadic forwarding in LogFunc call, got:\n%s", resByLine.GeneratedCode)
	}
	if !strings.Contains(resByLine.GeneratedCode, "Arg0 []byte") {
		t.Errorf("expected unnamed param to be named arg0/Arg0, got:\n%s", resByLine.GeneratedCode)
	}

	resExplicit, err := GenerateInterfaceMock(dir, srcFile, 13, 2, "Finder", "FakeFinder")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock explicit error: %v", err)
	}
	if resExplicit.InterfaceName != "Finder" {
		t.Errorf("expected Finder, got %q", resExplicit.InterfaceName)
	}
	if resExplicit.MockName != "FakeFinder" {
		t.Errorf("expected FakeFinder, got %q", resExplicit.MockName)
	}
	if !strings.Contains(resExplicit.GeneratedCode, "var zero0 User") || !strings.Contains(resExplicit.GeneratedCode, "return zero0, nil") {
		t.Errorf("expected custom struct zero value 'var zero0 User', got:\n%s", resExplicit.GeneratedCode)
	}

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, resExplicit.SuggestedFileName, resExplicit.StandaloneFileCode, parser.AllErrors); err != nil {
		t.Fatalf("StandaloneFileCode failed to parse: %v\ncode:\n%s", err, resExplicit.StandaloneFileCode)
	}
}

func TestGenerateInterfaceMock_EmbeddedAndStructMatch(t *testing.T) {
	dir := t.TempDir()
	srcFile := filepath.Join(dir, "rw.go")
	src := `package rw

import "context"

type Reader interface {
	ReadItem(ctx context.Context, id string) (string, error)
}

type Writer interface {
	WriteItem(ctx context.Context, id string, val string) error
}

type ReadWriter interface {
	Reader
	Writer
}

type memoryWriter struct{}

func (m *memoryWriter) WriteItem(ctx context.Context, id string, val string) error {
	return nil
}
`
	if err := os.WriteFile(srcFile, []byte(src), 0644); err != nil {
		t.Fatalf("write rw.go: %v", err)
	}

	resEmbedded, err := GenerateInterfaceMock(dir, srcFile, 14, 1, "", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock embedded error: %v", err)
	}
	if resEmbedded.InterfaceName != "ReadWriter" {
		t.Errorf("expected ReadWriter, got %q", resEmbedded.InterfaceName)
	}
	if resEmbedded.MethodCount != 2 {
		t.Errorf("expected 2 embedded methods, got %d", resEmbedded.MethodCount)
	}
	if !strings.Contains(resEmbedded.StandaloneFileCode, `"context"`) || !strings.Contains(resEmbedded.StandaloneFileCode, `"sync"`) {
		t.Errorf("expected StandaloneFileCode to import both sync and context, got:\n%s", resEmbedded.StandaloneFileCode)
	}

	resStruct, err := GenerateInterfaceMock(dir, srcFile, 18, 1, "", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock struct match error: %v", err)
	}
	if resStruct.InterfaceName != "Writer" {
		t.Errorf("expected struct memoryWriter to match Writer interface, got %q", resStruct.InterfaceName)
	}
}

func TestGenerateInterfaceMock_GenericInterface(t *testing.T) {
	dir := t.TempDir()
	srcFile := filepath.Join(dir, "store.go")
	src := `package store

type Store[T any] interface {
	Get(key string) (T, error)
}
`
	if err := os.WriteFile(srcFile, []byte(src), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}

	res, err := GenerateInterfaceMock(dir, srcFile, 3, 1, "", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock generic error: %v", err)
	}
	if !strings.Contains(res.GeneratedCode, "type MockStore[T any] struct") {
		t.Errorf("expected generic MockStore[T any] struct, got:\n%s", res.GeneratedCode)
	}
	if !strings.Contains(res.GeneratedCode, "var _ Store[T] = (*MockStore[T])(nil)") {
		t.Errorf("expected generic compile-time interface assertion, got:\n%s", res.GeneratedCode)
	}
	if !strings.Contains(res.GeneratedCode, "func (m *MockStore[T]) Get(key string) (T, error)") {
		t.Errorf("expected generic receiver *MockStore[T], got:\n%s", res.GeneratedCode)
	}
}

func typeCheckMockSources(t *testing.T, pkgName string, sources map[string]string) {
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

func TestGenerateInterfaceMock_EdgeCases_CompileAndExecute(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		files       map[string]string
		targetFile  string
		line        int
		ifaceName   string
		mustContain []string
		mustOmit    []string
	}{
		{
			name:    "embedded_generic_interface_across_files_with_aliased_imports",
			pkgName: "repo",
			files: map[string]string{
				"base.go": `package repo

import (
	ctx "context"
	"io"
)

type BaseRepo[K comparable, V any] interface {
	Load(c ctx.Context, key K) (V, error)
	Save(c ctx.Context, key K, r io.Reader) error
}
`,
				"user_repo.go": `//go:build darwin || linux

package repo

type UserRepo interface {
	BaseRepo[string, int]
	Count() int
}
`,
				"ignored.go": `//go:build ignore

package repo

type IgnoredRepo interface {
	SkipMe()
}
`,
			},
			targetFile: "user_repo.go",
			line:       5,
			ifaceName:  "UserRepo",
			mustContain: []string{
				"//go:build darwin || linux",
				`ctx "context"`,
				`"io"`,
				"var _ UserRepo = (*MockUserRepo)(nil)",
				"Load(c ctx.Context, key string) (int, error)",
				"Save(c ctx.Context, key string, r io.Reader) error",
				"Count() int",
			},
			mustOmit: []string{"IgnoredRepo"},
		},
		{
			name:    "unexported_interface_and_name_clashes_with_m_and_zero0",
			pkgName: "clash",
			files: map[string]string{
				"secret.go": `package clash

import mySync "sync"

type reader[m any] interface {
	read(x m, zero0 string, fn int) (m, *mySync.Mutex)
}

type writer interface {
	write(m string, zero0 int, fn bool) error
}
`,
			},
			targetFile: "secret.go",
			line:       5,
			ifaceName:  "reader",
			mustContain: []string{
				"type Mockreader[m any] struct",
				"var _ reader[m] = (*Mockreader[m])(nil)",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for fname, body := range tc.files {
				if err := os.WriteFile(filepath.Join(dir, fname), []byte(body), 0644); err != nil {
					t.Fatal(err)
				}
			}
			res, err := GenerateInterfaceMock(dir, filepath.Join(dir, tc.targetFile), tc.line, 1, tc.ifaceName, "")
			if err != nil {
				t.Fatalf("GenerateInterfaceMock failed: %v", err)
			}
			if res.Error != "" {
				t.Fatalf("res.Error = %q", res.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(res.StandaloneFileCode, want) {
					t.Errorf("expected %q in StandaloneFileCode:\n%s", want, res.StandaloneFileCode)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(res.StandaloneFileCode, forbid) {
					t.Errorf("did not expect %q in StandaloneFileCode:\n%s", forbid, res.StandaloneFileCode)
				}
			}
			typeCheckSources := map[string]string{
				res.SuggestedFileName: res.StandaloneFileCode,
			}
			for fname, body := range tc.files {
				if !strings.Contains(body, "//go:build ignore") {
					typeCheckSources[fname] = body
				}
			}
			typeCheckMockSources(t, tc.pkgName, typeCheckSources)
		})
	}
}

func TestGenerateInterfaceMock_RealGoTestExecution(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module mockexec\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}
	baseSrc := `package mockexec

import "context"

type Base[K comparable, V any] interface {
	Fetch(ctx context.Context, k K) (V, error)
}
`
	repoSrc := `package mockexec

type Store interface {
	Base[string, int]
	Ping() bool
}
`
	if err := os.WriteFile(filepath.Join(dir, "base.go"), []byte(baseSrc), 0644); err != nil {
		t.Fatal(err)
	}
	repoPath := filepath.Join(dir, "store.go")
	if err := os.WriteFile(repoPath, []byte(repoSrc), 0644); err != nil {
		t.Fatal(err)
	}

	res, err := GenerateInterfaceMock(dir, repoPath, 3, 1, "Store", "")
	if err != nil {
		t.Fatalf("GenerateInterfaceMock failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, res.SuggestedFileName), []byte(res.StandaloneFileCode), 0644); err != nil {
		t.Fatal(err)
	}

	behaviorTest := `package mockexec

import (
	"context"
	"testing"
)

func TestMockStoreBehavior(t *testing.T) {
	m := &MockStore{
		FetchFunc: func(ctx context.Context, k string) (int, error) {
			return len(k), nil
		},
	}
	v, err := m.Fetch(context.Background(), "abc")
	if err != nil || v != 3 {
		t.Fatalf("Fetch = (%d, %v), want (3, nil)", v, err)
	}
	if m.Ping() {
		t.Fatalf("expected default false for Ping")
	}
	if len(m.FetchCalls) != 1 || m.FetchCalls[0].K != "abc" || m.PingCalls != 1 {
		t.Fatalf("unexpected call records: fetch=%+v ping=%d", m.FetchCalls, m.PingCalls)
	}
}
`
	if err := os.WriteFile(filepath.Join(dir, "store_behavior_test.go"), []byte(behaviorTest), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("go", "test", "-v", "./...")
	cmd.Dir = dir
	if out, runErr := cmd.CombinedOutput(); runErr != nil {
		t.Fatalf("go test failed: %v\n%s\nMock:\n%s", runErr, string(out), res.StandaloneFileCode)
	}
}
