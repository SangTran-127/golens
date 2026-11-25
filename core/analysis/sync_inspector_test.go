package analysis

import (
	"go/ast"
	"go/format"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSyncSafetyInspectAllCategories(t *testing.T) {
	src := `package sample

import "sync"

type SafeCounter struct {
	mu    sync.Mutex
	count int
}

func (s SafeCounter) ValueCopyInc() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.count++
	return s.count
}

func (s *SafeCounter) PointerSafeInc() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.count++
	return s.count
}

func ProcessBatchInLoop(mu *sync.Mutex, rwmu *sync.RWMutex, items []string) {
	for i := 0; i < len(items); i++ {
		mu.Lock()
		defer mu.Unlock()
	}

	for _, item := range items {
		_ = item
		rwmu.RLock()
		defer rwmu.RUnlock()
	}
}

func ForgotUnlock(mu *sync.Mutex, rwmu *sync.RWMutex) int {
	mu.Lock()
	rwmu.RLock()
	return 42
}
`

	report := InspectSyncSafety(SyncSafetyInspectRequest{
		FilePath: "sample.go",
		Content:  src,
		Scope:    "file",
	})

	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.ValueReceiverCopy != 1 {
		t.Fatalf("expected 1 valueReceiverCopy finding, got %d", report.ValueReceiverCopy)
	}
	if report.DeferUnlockLoop != 2 {
		t.Fatalf("expected 2 deferUnlockLoop findings, got %d", report.DeferUnlockLoop)
	}
	if report.MissingUnlock != 2 {
		t.Fatalf("expected 2 missingUnlock findings, got %d", report.MissingUnlock)
	}
	if report.TotalCount != 5 {
		t.Fatalf("expected totalCount 5, got %d", report.TotalCount)
	}
	if report.AutoFixable != 3 {
		t.Fatalf("expected autoFixable 3, got %d", report.AutoFixable)
	}

	foundValueRecv := false
	foundDeferLoop := false
	foundMissingUnlock := false
	for _, f := range report.Findings {
		switch f.Category {
		case "SYNC_VALUE_RECEIVER":
			foundValueRecv = true
			if !strings.Contains(f.Replacement, "(s *SafeCounter)") {
				t.Errorf("expected pointer receiver replacement, got %q", f.Replacement)
			}
		case "SYNC_DEFER_UNLOCK_LOOP":
			foundDeferLoop = true
			if f.CanAutoFix {
				t.Errorf("expected SYNC_DEFER_UNLOCK_LOOP CanAutoFix=false")
			}
		case "SYNC_LOCK_NO_UNLOCK":
			foundMissingUnlock = true
			if !f.CanAutoFix {
				t.Errorf("expected SYNC_LOCK_NO_UNLOCK CanAutoFix=true")
			}
		}
	}
	if !foundValueRecv || !foundDeferLoop || !foundMissingUnlock {
		t.Fatalf("missing expected categories: valueRecv=%v deferLoop=%v missingUnlock=%v", foundValueRecv, foundDeferLoop, foundMissingUnlock)
	}
}

func TestSyncSafetySingleFixAndFixAll(t *testing.T) {
	src := `package sample

import "sync"

type SafeCounter struct {
	mu    sync.Mutex
	count int
}

func (s SafeCounter) Snapshot() int {
	return s.count
}

func UpdateWithoutUnlock(mu *sync.Mutex) int {
	mu.Lock()
	return 10
}
`

	initial := InspectSyncSafety(SyncSafetyInspectRequest{
		FilePath: "counter.go",
		Content:  src,
		Scope:    "file",
	})
	if initial.TotalCount != 2 {
		t.Fatalf("expected 2 findings, got %d", initial.TotalCount)
	}

	var valueRecvID, missingUnlockID string
	for _, f := range initial.Findings {
		if f.Category == "SYNC_VALUE_RECEIVER" {
			valueRecvID = f.ID
		}
		if f.Category == "SYNC_LOCK_NO_UNLOCK" {
			missingUnlockID = f.ID
		}
	}
	if valueRecvID == "" || missingUnlockID == "" {
		t.Fatalf("expected both finding IDs, got valueRecvID=%q missingUnlockID=%q", valueRecvID, missingUnlockID)
	}

	singleRes := ApplySyncSafetyFixes(SyncSafetyFixRequest{
		FilePath:  "counter.go",
		Content:   src,
		FindingID: valueRecvID,
	})
	if singleRes.Error != "" {
		t.Fatalf("unexpected single fix error: %s", singleRes.Error)
	}
	if singleRes.AppliedCount != 1 {
		t.Fatalf("expected appliedCount 1, got %d", singleRes.AppliedCount)
	}
	if !strings.Contains(singleRes.NewContent, "func (s *SafeCounter) Snapshot() int") {
		t.Fatalf("expected pointer receiver in single fix output:\n%s", singleRes.NewContent)
	}

	allRes := ApplySyncSafetyFixes(SyncSafetyFixRequest{
		FilePath:  "counter.go",
		Content:   src,
		FindingID: "",
	})
	if allRes.Error != "" {
		t.Fatalf("unexpected fix-all error: %s", allRes.Error)
	}
	if allRes.AppliedCount != 2 {
		t.Fatalf("expected appliedCount 2, got %d", allRes.AppliedCount)
	}
	if !strings.Contains(allRes.NewContent, "func (s *SafeCounter) Snapshot() int") {
		t.Errorf("missing pointer receiver in fix-all output:\n%s", allRes.NewContent)
	}
	if !strings.Contains(allRes.NewContent, "defer mu.Unlock()") {
		t.Errorf("missing defer mu.Unlock() in fix-all output:\n%s", allRes.NewContent)
	}

	formatted, err := format.Source([]byte(allRes.NewContent))
	if err != nil {
		t.Fatalf("expected valid go/format output, got err: %v", err)
	}
	if string(formatted) != allRes.NewContent {
		t.Fatalf("expected NewContent to be gofmt-formatted")
	}

	recheck := InspectSyncSafety(SyncSafetyInspectRequest{
		FilePath: "counter.go",
		Content:  allRes.NewContent,
		Scope:    "file",
	})
	if recheck.TotalCount != 0 {
		t.Fatalf("expected 0 remaining findings after fix-all, got %d", recheck.TotalCount)
	}
}

func TestSyncSafetyWorkspaceScanning(t *testing.T) {
	tmpDir := t.TempDir()

	fileA := filepath.Join(tmpDir, "a.go")
	err := os.WriteFile(fileA, []byte(`package pkg

import "sync"

type SafeStore struct {
	mu sync.Mutex
}

func (s SafeStore) Read() {}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	fileB := filepath.Join(tmpDir, "b.go")
	err = os.WriteFile(fileB, []byte(`package pkg

import "sync"

func LeakLock(mu *sync.Mutex) {
	mu.Lock()
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	testFile := filepath.Join(tmpDir, "b_test.go")
	err = os.WriteFile(testFile, []byte(`package pkg

import "sync"

func IgnoreTestLock(mu *sync.Mutex) {
	mu.Lock()
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	report := InspectSyncSafety(SyncSafetyInspectRequest{
		WorkspacePath: tmpDir,
		Scope:         "workspace",
	})
	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.TotalCount != 2 {
		t.Fatalf("expected 2 workspace findings (excluding _test.go), got %d", report.TotalCount)
	}
	if report.ValueReceiverCopy != 1 || report.MissingUnlock != 1 {
		t.Fatalf("unexpected counts: valueRecv=%d missingUnlock=%d", report.ValueReceiverCopy, report.MissingUnlock)
	}
}

func TestSyncSafetyValueReceiverFixPreservesInterfaceConformance(t *testing.T) {
	src := `package sample

import "sync"

type Counter interface {
	Count() int
}

type Cache struct {
	mu sync.Mutex
	n  int
}

func (c Cache) Count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

var _ Counter = Cache{}

func NewCounter() Counter {
	return Cache{n: 1}
}
`

	res := ApplySyncSafetyFixes(SyncSafetyFixRequest{
		FilePath: "cache.go",
		Content:  src,
	})
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if res.AppliedCount != 1 {
		t.Fatalf("expected AppliedCount 1, got %d", res.AppliedCount)
	}
	if !strings.Contains(res.NewContent, "func (c *Cache) Count() int") {
		t.Errorf("expected pointer receiver in fixed output:\n%s", res.NewContent)
	}
	if !strings.Contains(res.NewContent, "var _ Counter = &Cache{}") {
		t.Errorf("expected var _ Counter = &Cache{} in fixed output:\n%s", res.NewContent)
	}
	if !strings.Contains(res.NewContent, "return &Cache{n: 1}") {
		t.Errorf("expected return &Cache{n: 1} in fixed output:\n%s", res.NewContent)
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, "cache.go", res.NewContent, parser.AllErrors)
	if err != nil {
		t.Fatalf("expected fixed file to parse cleanly, got error: %v\nOutput:\n%s", err, res.NewContent)
	}

	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("sample", fset, []*ast.File{astFile}, nil); err != nil {
		t.Fatalf("expected fixed file to pass go/types typechecking, got error: %v\nOutput:\n%s", err, res.NewContent)
	}
}

func TestSyncSafetyValueReceiverFixUpdatesSiblingFilesInPackage(t *testing.T) {
	tmpDir := t.TempDir()
	cachePath := filepath.Join(tmpDir, "cache.go")
	consumerPath := filepath.Join(tmpDir, "consumer.go")

	cacheSrc := `package main

import "sync"

type Cache struct {
	mu    sync.Mutex
	items int
}

type Counter interface {
	Count() int
}

func (c Cache) Count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.items
}
`
	consumerSrc := `package main

import "fmt"

func NewCounter() Counter {
	return Cache{}
}

func main() {
	c := NewCounter()
	fmt.Println(c.Count())
}
`
	if err := os.WriteFile(cachePath, []byte(cacheSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(consumerPath, []byte(consumerSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	res := ApplySyncSafetyFixes(SyncSafetyFixRequest{
		FilePath: cachePath,
		Content:  cacheSrc,
	})
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if !strings.Contains(res.NewContent, "func (c *Cache) Count() int") {
		t.Fatalf("expected pointer receiver in cache.go, got:\n%s", res.NewContent)
	}

	diskConsumerBytes, err := os.ReadFile(consumerPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(diskConsumerBytes) != consumerSrc {
		t.Fatalf("expected ApplySyncSafetyFixes not to mutate sibling file on disk directly")
	}

	var updatedConsumer string
	for _, edit := range res.FileEdits {
		if sameSyncFilePath(edit.FilePath, consumerPath) {
			updatedConsumer = edit.NewContent
			break
		}
	}
	if !strings.Contains(updatedConsumer, "return &Cache{}") {
		t.Fatalf("expected sibling consumer.go in FileEdits to be updated to return &Cache{}, got:\n%s", updatedConsumer)
	}

	fset := token.NewFileSet()
	f1, err := parser.ParseFile(fset, cachePath, res.NewContent, parser.AllErrors)
	if err != nil {
		t.Fatal(err)
	}
	f2, err := parser.ParseFile(fset, consumerPath, updatedConsumer, parser.AllErrors)
	if err != nil {
		t.Fatal(err)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("main", fset, []*ast.File{f1, f2}, nil); err != nil {
		t.Fatalf("expected multi-file package to typecheck cleanly after sync fix, got: %v", err)
	}
}

