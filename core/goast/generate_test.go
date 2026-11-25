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

func TestGenerateCode_Constructor(t *testing.T) {
	path := "/proj/config.go"
	src := `package demo

type Config struct {
	ID         string
	MaxRetries int
	Type       string
	a, b       string
}
`
	offset := strings.Index(src, "MaxRetries")
	req := GenerateCodeRequest{
		Kind:   "constructor",
		Path:   path,
		Offset: offset,
		Buffers: map[string]string{
			path: src,
		},
	}
	reqBytes, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal req: %v", err)
	}
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	updated := applyEditsToText(src, resp.EditsByPath[path])
	if !strings.Contains(updated, "func NewConfig(id string, maxRetries int, typeVal string, a string, b string) *Config {") {
		t.Fatalf("expected NewConfig signature with safe param names, got:\n%s", updated)
	}
	for _, wantLine := range []string{
		"ID:         id,",
		"MaxRetries: maxRetries,",
		"Type:       typeVal,",
		"a:          a,",
		"b:          b,",
	} {
		if !strings.Contains(updated, wantLine) {
			t.Fatalf("expected %q in constructor body, got:\n%s", wantLine, updated)
		}
	}
}

func TestGenerateCode_ExtractInterfaceAcrossFiles(t *testing.T) {
	tmpDir := t.TempDir()
	storePath := filepath.Join(tmpDir, "store.go")
	extraPath := filepath.Join(tmpDir, "store_extra.go")

	storeSrc := `package storage

type Store struct {
	db string
}

func (s *Store) Get(key string) (string, error) {
	return s.db + key, nil
}

func (s *Store) internalHelper() {}
`
	extraSrc := `package storage

func (s *Store) Put(key string, val string) error {
	return nil
}

func (s Store) Close() error {
	return nil
}

func (s *Store) unexportedExtra() {}
`

	if err := os.WriteFile(storePath, []byte(storeSrc), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}
	if err := os.WriteFile(extraPath, []byte(extraSrc), 0644); err != nil {
		t.Fatalf("write store_extra.go: %v", err)
	}

	offset := strings.Index(storeSrc, "type Store struct")
	req := GenerateCodeRequest{
		Kind:   "extract_interface",
		Path:   storePath,
		Offset: offset,
	}
	reqBytes, _ := json.Marshal(req)
	var resp ChangeSignatureResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	updated := applyEditsToText(storeSrc, resp.EditsByPath[storePath])

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, storePath, updated, parser.AllErrors); err != nil {
		t.Fatalf("extracted interface code failed to parse: %v\n%s", err, updated)
	}

	if !strings.Contains(updated, "type Storer interface {") {
		t.Fatalf("expected Storer interface, got:\n%s", updated)
	}
	for _, wantMethod := range []string{
		"Get(key string) (string, error)",
		"Put(key string, val string) error",
		"Close() error",
	} {
		if !strings.Contains(updated, wantMethod) {
			t.Fatalf("expected method %q in Storer interface, got:\n%s", wantMethod, updated)
		}
	}
	insertedIface := resp.EditsByPath[storePath][0].NewText
	for _, unwanted := range []string{"internalHelper", "unexportedExtra"} {
		if strings.Contains(insertedIface, unwanted) {
			t.Fatalf("expected unexported method %q to be excluded from Storer, got:\n%s", unwanted, insertedIface)
		}
	}
	if strings.Index(updated, "type Storer interface") > strings.Index(updated, "type Store struct") {
		t.Fatalf("expected Storer interface to be inserted before Store struct, got:\n%s", updated)
	}
}

func TestListWorkspaceInterfaces_And_ImplementInterface(t *testing.T) {
	tmpDir := t.TempDir()
	ifacePath := filepath.Join(tmpDir, "contracts.go")
	implPath := filepath.Join(tmpDir, "memory_store.go")

	ifaceSrc := `package storage

type Repository interface {
	Get(key string) (string, error)
	Put(key string, value string) error
	Delete(key string) error
}
`
	implSrc := `package storage

type MemoryStore struct {
	items map[string]string
}

func (m *MemoryStore) Get(key string) (string, error) {
	return m.items[key], nil
}
`
	if err := os.WriteFile(ifacePath, []byte(ifaceSrc), 0644); err != nil {
		t.Fatalf("write contracts.go: %v", err)
	}
	if err := os.WriteFile(implPath, []byte(implSrc), 0644); err != nil {
		t.Fatalf("write memory_store.go: %v", err)
	}

	var candidates []InterfaceCandidate
	if err := json.Unmarshal([]byte(ListWorkspaceInterfaces(tmpDir, implPath)), &candidates); err != nil {
		t.Fatalf("unmarshal candidates: %v", err)
	}

	foundRepo := false
	foundReader := false
	for _, c := range candidates {
		if c.Name == "Repository" && c.Package == "storage" && len(c.Methods) == 3 {
			foundRepo = true
		}
		if c.Name == "io.Reader" && c.Package == "io" {
			foundReader = true
		}
	}
	if !foundRepo {
		t.Fatalf("expected workspace interface Repository in candidates, got: %+v", candidates)
	}
	if !foundReader {
		t.Fatalf("expected stdlib interface io.Reader in candidates")
	}

	offset := strings.Index(implSrc, "MemoryStore")
	req := GenerateCodeRequest{
		Action:     "implement_interface",
		Path:       implPath,
		Offset:     offset,
		TargetName: "Repository",
	}
	reqBytes, _ := json.Marshal(req)
	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	updated := applyEditsToText(implSrc, resp.EditsByPath[implPath])
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, implPath, updated, parser.AllErrors); err != nil {
		t.Fatalf("generated implementation failed to parse: %v\n%s", err, updated)
	}

	if strings.Count(updated, "func (m *MemoryStore) Get(") != 1 {
		t.Fatalf("expected existing Get method not to be duplicated, got:\n%s", updated)
	}
	for _, wantStub := range []string{
		"func (m *MemoryStore) Put(key string, value string) error",
		"func (m *MemoryStore) Delete(key string) error",
		`panic("not implemented")`,
	} {
		if !strings.Contains(updated, wantStub) {
			t.Fatalf("expected %q in generated code, got:\n%s", wantStub, updated)
		}
	}
}

func TestGenerateCode_MoveSymbolToNewAndExistingFile(t *testing.T) {
	tmpDir := t.TempDir()
	srcPath := filepath.Join(tmpDir, "service.go")
	srcContent := `package service

// Primary keeps the service running.
func Primary() string {
	return Helper()
}

// Helper returns the greeting.
func Helper() string {
	return "ok"
}
`
	if err := os.WriteFile(srcPath, []byte(srcContent), 0644); err != nil {
		t.Fatalf("write service.go: %v", err)
	}

	offset := strings.Index(srcContent, "func Helper")
	req := GenerateCodeRequest{
		Action:     "move_symbol",
		Path:       srcPath,
		Offset:     offset,
		TargetName: "helpers.go",
	}
	reqBytes, _ := json.Marshal(req)
	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal move_symbol resp: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected move_symbol error: %s", resp.Error)
	}

	wantDest := filepath.Join(tmpDir, "helpers.go")
	if resp.TargetPath != wantDest {
		t.Fatalf("expected targetPath %q, got %q", wantDest, resp.TargetPath)
	}

	updatedSrc := applyEditsToText(srcContent, resp.EditsByPath[srcPath])
	if strings.Contains(updatedSrc, "func Helper") {
		t.Fatalf("expected Helper to be removed from service.go, got:\n%s", updatedSrc)
	}
	if !strings.Contains(updatedSrc, "func Primary()") {
		t.Fatalf("expected Primary to remain in service.go, got:\n%s", updatedSrc)
	}

	destDiskBytes, err := os.ReadFile(wantDest)
	if err != nil {
		t.Fatalf("expected new destination file %s to be written on disk: %v", wantDest, err)
	}
	destDisk := string(destDiskBytes)
	if !strings.Contains(destDisk, "package service") || !strings.Contains(destDisk, "func Helper() string") {
		t.Fatalf("unexpected content in %s:\n%s", wantDest, destDisk)
	}
	if edits, ok := resp.EditsByPath[wantDest]; ok {
		t.Fatalf("expected no insert edit for the file written on disk, got %d edits", len(edits))
	}
}

func TestGenerateCode_MoveSymbolReportsNewFileWriteFailure(t *testing.T) {
	tmpDir := t.TempDir()
	srcPath := filepath.Join(tmpDir, "service.go")
	srcContent := "package service\n\nfunc Helper() string {\n\treturn \"ok\"\n}\n"
	if err := os.WriteFile(srcPath, []byte(srcContent), 0o644); err != nil {
		t.Fatalf("write service.go: %v", err)
	}
	if err := os.Chmod(tmpDir, 0o555); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(tmpDir, 0o755) })

	req := GenerateCodeRequest{
		Action:     "move_symbol",
		Path:       srcPath,
		Offset:     strings.Index(srcContent, "func Helper"),
		TargetName: "helpers.go",
	}
	reqBytes, _ := json.Marshal(req)
	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal move_symbol resp: %v", err)
	}
	if resp.Error == "" {
		t.Fatalf("expected an error when the destination file cannot be written")
	}
	if len(resp.EditsByPath) != 0 {
		t.Fatalf("expected no edits when the destination file cannot be written, got %v", resp.EditsByPath)
	}
}

func typeCheckGoastPackage(t *testing.T, pkgName string, sources map[string]string) {
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

func TestGenerateCode_Constructor_EdgeCases_TypeCheck(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		src         string
		cursorNeed  string
		mustContain []string
		mustOmit    []string
	}{
		{
			name:    "generic_struct_embedded_and_sync_locks_skipped",
			pkgName: "cache",
			src: `package cache

import (
	"sync"
	"sync/atomic"
)

type Meta struct{ Version int }
type Logger struct{}

type Box[K comparable, V any] struct {
	Meta
	*Logger
	mu    sync.Mutex
	rw    *sync.RWMutex
	count atomic.Int64
	Key   K
	Data  map[K]V
}
`,
			cursorNeed:  "type Box",
			mustContain: []string{"func NewBox[K comparable, V any](", "Meta", "*Logger", "*Box[K, V]", "rw *sync.RWMutex"},
			mustOmit:    []string{"mu sync.Mutex,", "count atomic.Int64,", "mu:", "count:"},
		},
		{
			name:    "unexported_struct_clashes_and_aliased_imports",
			pkgName: "clientpkg",
			src: `//go:build darwin || linux

package clientpkg

import h "net/http"

// client connects upstream.
type client struct {
	host  string
	error int
	type_ string
	hc    *h.Client
}

func KeepHelper() int { return 1 }
`,
			cursorNeed:  "type client struct",
			mustContain: []string{"//go:build darwin || linux", "// client connects upstream.", "func newClient(", "*h.Client", "KeepHelper"},
			mustOmit:    nil,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			off := strings.Index(tc.src, tc.cursorNeed)
			if off < 0 {
				t.Fatalf("missing %q", tc.cursorNeed)
			}
			reqBytes, _ := json.Marshal(GenerateCodeRequest{
				Kind:    "constructor",
				Path:    "/proj/box.go",
				Offset:  off,
				Buffers: map[string]string{"/proj/box.go": tc.src},
			})
			var resp GenerateCodeResponse
			if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if resp.Error != "" {
				t.Fatalf("resp.Error = %q", resp.Error)
			}
			updated := applyEditsToText(tc.src, resp.EditsByPath["/proj/box.go"])
			for _, want := range tc.mustContain {
				if !strings.Contains(updated, want) {
					t.Errorf("expected %q in:\n%s", want, updated)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(updated, forbid) {
					t.Errorf("did not expect %q in:\n%s", forbid, updated)
				}
			}
			typeCheckGoastPackage(t, tc.pkgName, map[string]string{"box.go": updated})
		})
	}
}

func TestGenerateCode_ImplementInterface_StdlibGenericsAndPromoted(t *testing.T) {
	cases := []struct {
		name        string
		pkgName     string
		src         string
		cursorNeed  string
		target      string
		mustContain []string
		mustOmit    []string
	}{
		{
			name:    "http_handler_adds_import_and_avoids_r_param_clash",
			pkgName: "web",
			src: `package web

type Router struct{}
`,
			cursorNeed:  "type Router",
			target:      "http.Handler",
			mustContain: []string{`"net/http"`, "ServeHTTP(", "*http.Request", "http.ResponseWriter"},
		},
		{
			name:    "json_marshaler_omits_unused_encoding_json",
			pkgName: "codec",
			src: `package codec

type Token struct{ Raw string }
`,
			cursorNeed:  "type Token",
			target:      "json.Marshaler",
			mustContain: []string{"MarshalJSON() ([]byte, error)"},
			mustOmit:    []string{`"encoding/json"`},
		},
		{
			name:    "sql_scanner_omits_unused_database_sql",
			pkgName: "dbscan",
			src: `package dbscan

type NullText struct{}
`,
			cursorNeed:  "type NullText",
			target:      "sql.Scanner",
			mustContain: []string{"Scan(src any) error"},
			mustOmit:    []string{`"database/sql"`},
		},
		{
			name:    "driver_valuer_adds_database_sql_driver",
			pkgName: "dbtypes",
			src: `package dbtypes

type Val struct{}
`,
			cursorNeed:  "type Val",
			target:      "driver.Valuer",
			mustContain: []string{`"database/sql/driver"`, "Value() (driver.Value, error)"},
		},
		{
			name:    "generic_interface_and_skip_promoted_method",
			pkgName: "repo",
			src: `package repo

type Store[K comparable, V any] interface {
	Get(key K) (V, error)
	Put(key K, val V) error
}

type Getter[K comparable, V any] struct{}

func (g *Getter[K, V]) Get(key K) (V, error) {
	var zero V
	return zero, nil
}

type MemStore[K comparable, V any] struct {
	*Getter[K, V]
}
`,
			cursorNeed:  "type MemStore",
			target:      "Store[K, V]",
			mustContain: []string{"func (m *MemStore[K, V]) Put(key K, val V) error"},
			mustOmit:    []string{"func (m *MemStore[K, V]) Get("},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			off := strings.Index(tc.src, tc.cursorNeed)
			if off < 0 {
				t.Fatalf("missing %q", tc.cursorNeed)
			}
			reqBytes, _ := json.Marshal(GenerateCodeRequest{
				Action:     "implement_interface",
				Path:       "/proj/impl.go",
				Offset:     off,
				TargetName: tc.target,
				Buffers:    map[string]string{"/proj/impl.go": tc.src},
			})
			var resp GenerateCodeResponse
			if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if resp.Error != "" {
				t.Fatalf("resp.Error = %q", resp.Error)
			}
			updated := applyEditsToText(tc.src, resp.EditsByPath["/proj/impl.go"])
			for _, want := range tc.mustContain {
				if !strings.Contains(updated, want) {
					t.Errorf("expected %q in:\n%s", want, updated)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(updated, forbid) {
					t.Errorf("did not expect %q in:\n%s", forbid, updated)
				}
			}
			typeCheckGoastPackage(t, tc.pkgName, map[string]string{"impl.go": updated})
		})
	}
}

func TestGenerateCode_ImplementInterface_CrossPackageModuleAndBuildTags(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module genexec\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(dir, "contracts")
	svcDir := filepath.Join(dir, "svc")
	if err := os.MkdirAll(otherDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(svcDir, 0755); err != nil {
		t.Fatal(err)
	}

	ifaceSrc := `package contracts

import c "context"

type Worker interface {
	Run(ctx c.Context, id string) error
}
`
	ignoredSrc := `//go:build ignore

package contracts

type HiddenWorker interface {
	Secret()
}
`
	svcSrc := `package svc

type Handler struct{}
`
	if err := os.WriteFile(filepath.Join(otherDir, "worker.go"), []byte(ifaceSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(otherDir, "ignored.go"), []byte(ignoredSrc), 0644); err != nil {
		t.Fatal(err)
	}
	svcPath := filepath.Join(svcDir, "handler.go")
	if err := os.WriteFile(svcPath, []byte(svcSrc), 0644); err != nil {
		t.Fatal(err)
	}

	off := strings.Index(svcSrc, "type Handler")
	reqBytes, _ := json.Marshal(GenerateCodeRequest{
		Action:       "implement_interface",
		Path:         svcPath,
		WorkspaceDir: dir,
		Offset:       off,
		TargetName:   "Worker",
		Buffers:      map[string]string{svcPath: svcSrc},
	})
	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("resp.Error = %q", resp.Error)
	}
	updated := applyEditsToText(svcSrc, resp.EditsByPath[svcPath])
	if !strings.Contains(updated, "Run(") || !strings.Contains(updated, "Context") {
		t.Fatalf("expected Run method with Context imported:\n%s", updated)
	}
	if err := os.WriteFile(svcPath, []byte(updated), 0644); err != nil {
		t.Fatal(err)
	}
	testFile := `package svc

import (
	"genexec/contracts"
	"testing"
)

func TestHandlerImplementsContractsWorker(t *testing.T) {
	var _ contracts.Worker = (*Handler)(nil)
}
`
	if err := os.WriteFile(filepath.Join(svcDir, "handler_test.go"), []byte(testFile), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("go", "test", "-v", "./...")
	cmd.Dir = dir
	if out, runErr := cmd.CombinedOutput(); runErr != nil {
		t.Fatalf("go test failed: %v\n%s\nUpdated:\n%s", runErr, string(out), updated)
	}
}

func TestGenerateCode_ConstructorKeepsExistingConstructor(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.go")
	src := `package srv

type Server struct {
	addr string
}

func NewServer(addr string) *Server {
	if addr == "" {
		addr = ":8080"
	}
	return &Server{addr: addr}
}
`
	sibling := `package srv

type Pool struct{}

type Worker struct {
	pool *Pool
}
`
	if err := os.WriteFile(filepath.Join(dir, "worker.go"), []byte(sibling), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ctor.go"), []byte("package srv\n\nfunc NewWorker() *Worker { return &Worker{} }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ path, src, cursor, want string }{
		{path, src, "type Server", "NewServer already exists"},
		{filepath.Join(dir, "worker.go"), sibling, "type Worker", "NewWorker already exists"},
	} {
		reqBytes, _ := json.Marshal(GenerateCodeRequest{
			Kind:    "constructor",
			Path:    tc.path,
			Offset:  strings.Index(tc.src, tc.cursor),
			Buffers: map[string]string{tc.path: tc.src},
		})
		var resp GenerateCodeResponse
		if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if !strings.Contains(resp.Error, tc.want) || len(resp.EditsByPath) != 0 {
			t.Fatalf("%s: resp = %+v, want error %q and no edits", tc.cursor, resp, tc.want)
		}
	}
}

func TestGenerateCode_ConstructorKeepsPointerFieldsNamedLikeLocks(t *testing.T) {
	path := "/proj/worker.go"
	src := `package srv

import "sync"

type Pool struct{}

type Worker struct {
	pool *Pool
	wg   *sync.WaitGroup
	mu   sync.Mutex
}
`
	reqBytes, _ := json.Marshal(GenerateCodeRequest{
		Kind:    "constructor",
		Path:    path,
		Offset:  strings.Index(src, "type Worker"),
		Buffers: map[string]string{path: src},
	})
	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(GenerateCode(string(reqBytes))), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("resp.Error = %q", resp.Error)
	}
	updated := applyEditsToText(src, resp.EditsByPath[path])
	if !strings.Contains(updated, "func NewWorker(pool *Pool, wg *sync.WaitGroup) *Worker {") {
		t.Fatalf("constructor dropped pointer fields:\n%s", updated)
	}
	typeCheckGoastPackage(t, "srv", map[string]string{"worker.go": updated})
}
