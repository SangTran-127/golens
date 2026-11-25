package docker

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestContextFactsCache(t *testing.T) {
	clock := time.Date(2026, 11, 5, 10, 0, 0, 0, time.UTC)
	oldNow := factsNow
	factsNow = func() time.Time { return clock }
	t.Cleanup(func() { factsNow = oldNow })

	dir := writeTree(t, map[string]string{"go.mod": "module m\n\ngo 1.21\n", "main.go": mainGoFile})
	path := filepath.Join(dir, "Dockerfile")
	df := "FROM golang:1.21\n"
	count := func(code string) int { return len(withCode(Inspect(path, df), code)) }

	start := factsLoads
	if n := count("DF001"); n != 0 {
		t.Fatalf("DF001 = %d before go.mod change", n)
	}
	if err := os.WriteFile(filepath.Join(dir, ".dockerignore"), []byte(".git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(5 * time.Second)
	if n := count("DF007"); n != 1 {
		t.Fatalf("cached facts should not see the new .dockerignore yet, DF007 = %d", n)
	}
	if got := factsLoads - start; got != 1 {
		t.Fatalf("loads within TTL = %d, want 1", got)
	}

	modPath := filepath.Join(dir, "go.mod")
	if err := os.WriteFile(modPath, []byte("module m\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(modPath, clock, clock.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if n := count("DF001"); n != 1 {
		t.Fatalf("DF001 = %d after go.mod change, want 1", n)
	}
	if got := factsLoads - start; got != 2 {
		t.Fatalf("loads after go.mod change = %d, want 2", got)
	}

	clock = clock.Add(contextFactsTTL)
	if n := count("DF007"); n != 0 {
		t.Fatalf("expired facts should see .dockerignore, DF007 = %d", n)
	}
	if got := factsLoads - start; got != 3 {
		t.Fatalf("loads after TTL = %d, want 3", got)
	}
}
