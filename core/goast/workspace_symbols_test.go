package goast

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func createTestWorkspaceForSymbols(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	writeFile := func(relPath, content string) {
		t.Helper()
		full := filepath.Join(root, filepath.FromSlash(relPath))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", relPath, err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", relPath, err)
		}
	}

	writeFile("main.go", `package main

const DefaultPort = 8080

var globalBanner = "golens"

func ComputeSum(a int, b int) int {
	return a + b
}

func main() {
	_ = ComputeSum(1, 2)
}
`)

	writeFile("store/store.go", `package store

type Reader interface {
	Get(key string) (string, bool)
}

type KVStore struct {
	items map[string]string
}

func NewKVStore() *KVStore {
	return &KVStore{items: map[string]string{}}
}

func (s *KVStore) Get(key string) (string, bool) {
	v, ok := s.items[key]
	return v, ok
}

func (s *KVStore) Put(key, val string) {
	s.items[key] = val
}
`)

	writeFile("ledger/account.go", `package ledger

type Currency string

type Account struct {
	ID      string
	Balance int64
}

func (a *Account) Deposit(amount int64) {
	a.Balance += amount
}
`)

	writeFile(".golens-scratch/scratch.go", `package main

func ScratchSecretSymbol() {}
`)

	writeFile("vendor/pkg/ignored.go", `package pkg

func VendorIgnoredSymbol() {}
`)

	return root
}

func parseSymbolResults(t *testing.T, rawJSON string) []WorkspaceSymbolItem {
	t.Helper()
	var items []WorkspaceSymbolItem
	if err := json.Unmarshal([]byte(rawJSON), &items); err != nil {
		t.Fatalf("failed to unmarshal WorkspaceSymbolItem JSON: %v\nraw: %s", err, rawJSON)
	}
	return items
}

func TestWorkspaceSymbolsEmptyQueryAndHiddenSkipped(t *testing.T) {
	root := createTestWorkspaceForSymbols(t)
	raw := SearchWorkspaceSymbolsJSON(root, "", 100)
	items := parseSymbolResults(t, raw)

	if len(items) == 0 {
		t.Fatalf("expected non-empty symbols for workspace")
	}

	packagesSeen := map[string]bool{}
	for _, item := range items {
		packagesSeen[item.Package] = true
		if item.Name == "ScratchSecretSymbol" || strings.Contains(item.RelPath, ".golens-scratch") {
			t.Fatalf("expected .golens-scratch to be skipped, found %+v", item)
		}
		if item.Name == "VendorIgnoredSymbol" || strings.Contains(item.RelPath, "vendor/") {
			t.Fatalf("expected vendor directory to be skipped, found %+v", item)
		}
	}

	for _, wantPkg := range []string{"main", "store", "ledger"} {
		if !packagesSeen[wantPkg] {
			t.Errorf("expected symbols from package %q, seen=%v", wantPkg, packagesSeen)
		}
	}
}

func TestWorkspaceSymbolsKVStoreRanksStructFirst(t *testing.T) {
	root := createTestWorkspaceForSymbols(t)
	raw := SearchWorkspaceSymbolsJSON(root, "KVStore", 50)
	items := parseSymbolResults(t, raw)

	if len(items) == 0 {
		t.Fatalf("expected matches for query KVStore")
	}

	first := items[0]
	if first.Name != "KVStore" || first.Kind != "struct" {
		t.Fatalf("expected first match to be struct KVStore, got %+v", first)
	}
	if first.Signature != "type KVStore struct" {
		t.Errorf("expected signature 'type KVStore struct', got %q", first.Signature)
	}
	if first.RelPath != "store/store.go" {
		t.Errorf("expected relPath 'store/store.go', got %q", first.RelPath)
	}
}

func TestWorkspaceSymbolsGetFindsKVStoreMethod(t *testing.T) {
	root := createTestWorkspaceForSymbols(t)
	raw := SearchWorkspaceSymbolsJSON(root, "Get", 50)
	items := parseSymbolResults(t, raw)

	foundMethod := false
	for _, item := range items {
		if item.Name == "Get" && item.Kind == "method" && item.Receiver == "*KVStore" {
			foundMethod = true
			if !strings.Contains(item.Signature, "(*KVStore)") && !strings.Contains(item.Signature, "*KVStore") {
				t.Errorf("expected method signature to mention *KVStore, got %q", item.Signature)
			}
			if item.Line <= 0 || item.Col <= 0 {
				t.Errorf("expected valid 1-based line/col, got %d:%d", item.Line, item.Col)
			}
		}
	}
	if !foundMethod {
		t.Fatalf("expected query 'Get' to find (*KVStore).Get, got %+v", items)
	}

	rawQualified := SearchWorkspaceSymbolsJSON(root, "KVStore.Get", 50)
	qualifiedItems := parseSymbolResults(t, rawQualified)
	if len(qualifiedItems) == 0 || qualifiedItems[0].Name != "Get" || qualifiedItems[0].Receiver != "*KVStore" {
		t.Fatalf("expected query 'KVStore.Get' to rank (*KVStore).Get first, got %+v", qualifiedItems)
	}
}

func TestWorkspaceSymbolsCamelCaseAndPackageQualified(t *testing.T) {
	root := createTestWorkspaceForSymbols(t)

	camelItems := parseSymbolResults(t, SearchWorkspaceSymbolsJSON(root, "CS", 20))
	foundComputeSum := false
	for _, item := range camelItems {
		if item.Name == "ComputeSum" && item.Kind == "func" {
			foundComputeSum = true
			if item.Signature != "func ComputeSum(a int, b int) int" {
				t.Errorf("unexpected ComputeSum signature: %q", item.Signature)
			}
		}
	}
	if !foundComputeSum {
		t.Fatalf("expected CamelCase query 'CS' to match ComputeSum, got %+v", camelItems)
	}

	pkgItems := parseSymbolResults(t, SearchWorkspaceSymbolsJSON(root, "ledger.Account", 20))
	if len(pkgItems) == 0 || pkgItems[0].Name != "Account" || pkgItems[0].Package != "ledger" {
		t.Fatalf("expected package-qualified query 'ledger.Account' to find Account, got %+v", pkgItems)
	}
}
