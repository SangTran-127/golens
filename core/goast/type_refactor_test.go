package goast

import (
	"encoding/json"
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

func TestTypeRefactor_ExtractTypeMapFieldAndAnonStruct(t *testing.T) {
	src := `package config

type ServiceConfig struct {
	attrs map[string]string
	meta  struct {
		Code int
	}
}
`
	fieldIdx := strings.Index(src, "attrs map[string]string")
	if fieldIdx < 0 {
		t.Fatalf("failed to locate attrs field")
	}
	mapStart := strings.Index(src, "map[string]string")
	mapEnd := mapStart + len("map[string]string")

	inspectReqBytes, _ := json.Marshal(ExtractTypeRequest{
		Path:        "/proj/config.go",
		Src:         src,
		StartOffset: mapStart,
		EndOffset:   mapEnd,
		NewTypeName: "CustomAttrs",
	})
	rawInspect := InspectExtractTypeJSON(string(inspectReqBytes))
	var inspectReply ExtractTypeReply
	if err := json.Unmarshal([]byte(rawInspect), &inspectReply); err != nil {
		t.Fatalf("unmarshal inspect reply failed: %v", err)
	}
	if inspectReply.Error != "" {
		t.Fatalf("unexpected inspect error: %s", inspectReply.Error)
	}
	if inspectReply.DefaultTypeName != "AttrsType" {
		t.Fatalf("DefaultTypeName = %q, want %q", inspectReply.DefaultTypeName, "AttrsType")
	}
	if inspectReply.PreviewDeclaration != "type CustomAttrs map[string]string" {
		t.Fatalf("PreviewDeclaration = %q, want %q", inspectReply.PreviewDeclaration, "type CustomAttrs map[string]string")
	}
	if inspectReply.PreviewReplacement != "attrs CustomAttrs" {
		t.Fatalf("PreviewReplacement = %q, want %q", inspectReply.PreviewReplacement, "attrs CustomAttrs")
	}

	applyReqBytes, _ := json.Marshal(ExtractTypeRequest{
		Path:        "/proj/config.go",
		Src:         src,
		StartOffset: fieldIdx,
		EndOffset:   fieldIdx,
		NewTypeName: "CustomAttrs",
	})
	rawApply := ApplyExtractTypeJSON(string(applyReqBytes))
	var applyReply ExtractTypeReply
	if err := json.Unmarshal([]byte(rawApply), &applyReply); err != nil {
		t.Fatalf("unmarshal apply reply failed: %v", err)
	}
	if applyReply.Error != "" {
		t.Fatalf("unexpected apply error: %s", applyReply.Error)
	}
	edits := applyReply.EditsByPath["/proj/config.go"]
	if len(edits) != 2 {
		t.Fatalf("expected 2 edits, got %d", len(edits))
	}

	updated := applyEditsToText(src, edits)
	fset := token.NewFileSet()
	parsedFile, err := parser.ParseFile(fset, "/proj/config.go", updated, parser.AllErrors)
	if err != nil {
		t.Fatalf("updated code failed to parse: %v\ncode:\n%s", err, updated)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("config", fset, []*ast.File{parsedFile}, nil); err != nil {
		t.Fatalf("updated code failed to typecheck: %v\ncode:\n%s", err, updated)
	}
	if !strings.Contains(updated, "type CustomAttrs map[string]string\n\ntype ServiceConfig struct {\n\tattrs CustomAttrs") {
		t.Fatalf("unexpected updated code:\n%s", updated)
	}

	anonIdx := strings.Index(updated, "struct {\n\t\tCode int\n\t}")
	if anonIdx < 0 {
		t.Fatalf("failed to find anonymous struct in updated code")
	}
	anonApply := ApplyExtractType(ExtractTypeRequest{
		Path:        "/proj/config.go",
		Src:         updated,
		StartOffset: anonIdx,
		EndOffset:   anonIdx,
		NewTypeName: "MetaInfo",
	})
	if anonApply.Error != "" {
		t.Fatalf("unexpected error extracting anonymous struct: %s", anonApply.Error)
	}
	updated2 := applyEditsToText(updated, anonApply.Edits)
	fset2 := token.NewFileSet()
	parsedFile2, err := parser.ParseFile(fset2, "/proj/config.go", updated2, parser.AllErrors)
	if err != nil {
		t.Fatalf("second updated code failed to parse: %v\ncode:\n%s", err, updated2)
	}
	if _, err := conf.Check("config", fset2, []*ast.File{parsedFile2}, nil); err != nil {
		t.Fatalf("second updated code failed to typecheck: %v\ncode:\n%s", err, updated2)
	}
	if !strings.Contains(updated2, "type MetaInfo struct {\n\tCode int\n}") || !strings.Contains(updated2, "meta  MetaInfo") {
		t.Fatalf("expected MetaInfo in second updated code:\n%s", updated2)
	}
}

func TestTypeRefactor_ExtractTypeFromCompositeLit(t *testing.T) {
	src := `package runner

func BuildIndex() int {
	lookup := map[string]int{"alpha": 1, "beta": 2}
	return lookup["alpha"]
}
`
	litOffset := strings.Index(src, `"alpha": 1`)
	reply := ApplyExtractType(ExtractTypeRequest{
		Path:        "/proj/runner.go",
		Src:         src,
		StartOffset: litOffset,
		EndOffset:   litOffset,
		NewTypeName: "LookupTable",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if reply.PreviewDeclaration != "type LookupTable map[string]int" {
		t.Fatalf("PreviewDeclaration = %q, want %q", reply.PreviewDeclaration, "type LookupTable map[string]int")
	}
	updated := applyEditsToText(src, reply.Edits)
	fset := token.NewFileSet()
	parsedFile, err := parser.ParseFile(fset, "/proj/runner.go", updated, parser.AllErrors)
	if err != nil {
		t.Fatalf("updated code failed to parse: %v\ncode:\n%s", err, updated)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("runner", fset, []*ast.File{parsedFile}, nil); err != nil {
		t.Fatalf("updated code failed to typecheck: %v\ncode:\n%s", err, updated)
	}
	if !strings.Contains(updated, `lookup := LookupTable{"alpha": 1, "beta": 2}`) {
		t.Fatalf("expected composite literal to use LookupTable:\n%s", updated)
	}
}

func TestTypeRefactor_PropagateInterfaceMethods(t *testing.T) {
	tmpDir := t.TempDir()
	ifacePath := filepath.Join(tmpDir, "iface.go")
	storePath := filepath.Join(tmpDir, "store.go")

	ifaceSrc := `package storage

type StoreReader interface {
	Get(key string) string
	Keys() []string
}
`
	storeSrc := `package storage

type KVStore struct {
	data map[string]string
}

func (k *KVStore) Get(key string) string {
	return k.data[key]
}

type UnrelatedHelper struct {
	count int
}
`
	if err := os.WriteFile(ifacePath, []byte(ifaceSrc), 0644); err != nil {
		t.Fatalf("write iface.go: %v", err)
	}
	if err := os.WriteFile(storePath, []byte(storeSrc), 0644); err != nil {
		t.Fatalf("write store.go: %v", err)
	}

	keysOffset := strings.Index(ifaceSrc, "Keys() []string")
	reqBytes, _ := json.Marshal(ExtractTypeRequest{
		WorkspacePath: tmpDir,
		Path:          ifacePath,
		Src:           ifaceSrc,
		StartOffset:   keysOffset,
	})
	rawReply := PropagateInterfaceMethodsJSON(string(reqBytes))
	var reply ExtractTypeReply
	if err := json.Unmarshal([]byte(rawReply), &reply); err != nil {
		t.Fatalf("unmarshal reply failed: %v", err)
	}
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	if len(reply.PropagatedStructs) != 1 || reply.PropagatedStructs[0] != "KVStore" {
		t.Fatalf("PropagatedStructs = %v, want [KVStore]", reply.PropagatedStructs)
	}

	storeEdits := reply.EditsByPath[storePath]
	if len(storeEdits) == 0 {
		t.Fatalf("expected edits for %s, got editsByPath=%v", storePath, reply.EditsByPath)
	}

	updatedStore := applyEditsToText(storeSrc, storeEdits)
	if !strings.Contains(updatedStore, "func (k *KVStore) Keys() []string") {
		t.Fatalf("expected Keys() method stub on *KVStore, got:\n%s", updatedStore)
	}

	fset := token.NewFileSet()
	fIface, err := parser.ParseFile(fset, ifacePath, ifaceSrc, parser.AllErrors)
	if err != nil {
		t.Fatalf("parse iface.go failed: %v", err)
	}
	fStore, err := parser.ParseFile(fset, storePath, updatedStore, parser.AllErrors)
	if err != nil {
		t.Fatalf("parse updated store.go failed: %v\ncode:\n%s", err, updatedStore)
	}

	verifySrc := `package storage
var _ StoreReader = (*KVStore)(nil)
`
	fVerify, err := parser.ParseFile(fset, filepath.Join(tmpDir, "verify.go"), verifySrc, parser.AllErrors)
	if err != nil {
		t.Fatalf("parse verify.go failed: %v", err)
	}

	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("storage", fset, []*ast.File{fIface, fStore, fVerify}, nil); err != nil {
		t.Fatalf("package failed to compile after propagating interface methods: %v\nupdated store.go:\n%s", err, updatedStore)
	}
}
