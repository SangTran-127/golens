package vmexec

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkspaceSlug(t *testing.T) {
	hostPath := "/Users/developer/Projects/My Go App"
	slug := WorkspaceSlug(hostPath)

	canonical := filepath.Clean(hostPath)
	name := strings.ReplaceAll(filepath.Base(canonical), " ", "-")
	h := sha256.Sum256([]byte(canonical))
	expected := name + "-" + hex.EncodeToString(h[:])[:8]

	if slug != expected {
		t.Fatalf("expected slug %q, got %q", expected, slug)
	}

	// Verify deterministic consistency
	slug2 := WorkspaceSlug(hostPath)
	if slug != slug2 {
		t.Fatalf("slug should be deterministic: %q != %q", slug, slug2)
	}

	// Verify empty path handling
	emptySlug := WorkspaceSlug("")
	if emptySlug != "workspace-default" {
		t.Fatalf("unexpected empty slug: %q", emptySlug)
	}
}

func TestHostToGuestAndGuestToHost(t *testing.T) {
	workspaceRoot := "/Users/developer/Projects/demo"
	slug := WorkspaceSlug(workspaceRoot)
	guestRoot := "/workspaces/" + slug

	// 1. Root mapping
	guestPath := HostToGuestPath(workspaceRoot, workspaceRoot)
	if guestPath != guestRoot {
		t.Fatalf("expected guest root %q, got %q", guestRoot, guestPath)
	}
	hostBack := GuestToHostPath(workspaceRoot, guestPath)
	if hostBack != filepath.Clean(workspaceRoot) {
		t.Fatalf("expected host root %q, got %q", workspaceRoot, hostBack)
	}

	// 2. Subdirectory mapping
	hostSub := filepath.Join(workspaceRoot, "cmd", "server", "main.go")
	expectedGuestSub := guestRoot + "/cmd/server/main.go"
	guestSub := HostToGuestPath(workspaceRoot, hostSub)
	if guestSub != expectedGuestSub {
		t.Fatalf("expected %q, got %q", expectedGuestSub, guestSub)
	}
	hostSubBack := GuestToHostPath(workspaceRoot, guestSub)
	if hostSubBack != hostSub {
		t.Fatalf("expected %q, got %q", hostSub, hostSubBack)
	}

	// 3. Unrelated host path remains unchanged
	unrelated := "/etc/hosts"
	if res := HostToGuestPath(workspaceRoot, unrelated); res != unrelated {
		t.Fatalf("expected unrelated path %q, got %q", unrelated, res)
	}
	if res := GuestToHostPath(workspaceRoot, unrelated); res != unrelated {
		t.Fatalf("expected unrelated path %q, got %q", unrelated, res)
	}
}

func TestDefaultVMEnv(t *testing.T) {
	env := DefaultVMEnv("amd64", map[string]string{
		"CUSTOM_VAR": "hello",
		"CGO_ENABLED": "1",
	})

	m := make(map[string]string)
	for _, entry := range env {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) == 2 {
			m[parts[0]] = parts[1]
		}
	}

	if m["GOOS"] != "linux" {
		t.Fatalf("expected GOOS=linux, got %q", m["GOOS"])
	}
	if m["GOARCH"] != "amd64" {
		t.Fatalf("expected GOARCH=amd64, got %q", m["GOARCH"])
	}
	if m["GOCACHE"] != "/cache/gobuild" {
		t.Fatalf("expected GOCACHE=/cache/gobuild, got %q", m["GOCACHE"])
	}
	if m["GOMODCACHE"] != "/cache/gomod" {
		t.Fatalf("expected GOMODCACHE=/cache/gomod, got %q", m["GOMODCACHE"])
	}
	if m["CUSTOM_VAR"] != "hello" {
		t.Fatalf("expected CUSTOM_VAR=hello, got %q", m["CUSTOM_VAR"])
	}
	if m["CGO_ENABLED"] != "1" {
		t.Fatalf("expected user override CGO_ENABLED=1, got %q", m["CGO_ENABLED"])
	}
}
