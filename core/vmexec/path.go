package vmexec

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"golang.org/x/text/unicode/norm"
)

func WorkspaceSlug(hostPath string) string {
	if hostPath == "" {
		return "workspace-default"
	}
	return slugOf(norm.NFD.String(filepath.Clean(hostPath)))
}

func slugOf(canonical string) string {
	name := strings.ReplaceAll(filepath.Base(canonical), " ", "-")
	hash := sha256.Sum256([]byte(canonical))
	shortHash := hex.EncodeToString(hash[:])[:8]
	return name + "-" + shortHash
}

func WorkspaceSlugCandidates(hostPath string) []string {
	if hostPath == "" {
		return []string{WorkspaceSlug(hostPath)}
	}
	clean := filepath.Clean(hostPath)
	out := []string{WorkspaceSlug(hostPath)}
	for _, cand := range []string{slugOf(clean), slugOf(norm.NFC.String(clean))} {
		if !slices.Contains(out, cand) {
			out = append(out, cand)
		}
	}
	return out
}

func HostToGuestPath(workspaceRoot, hostPath string) string {
	if hostPath == "" {
		return ""
	}
	if workspaceRoot == "" {
		return hostPath
	}
	cleanRoot := filepath.Clean(workspaceRoot)
	cleanPath := filepath.Clean(hostPath)
	slug := WorkspaceSlug(cleanRoot)
	guestRoot := "/workspaces/" + slug

	if cleanPath == cleanRoot {
		return guestRoot
	}
	if rel, err := filepath.Rel(cleanRoot, cleanPath); err == nil && !strings.HasPrefix(rel, "..") {
		return filepath.ToSlash(filepath.Join(guestRoot, rel))
	}
	return cleanPath
}

func GuestToHostPath(workspaceRoot, guestPath string) string {
	if guestPath == "" {
		return ""
	}
	if workspaceRoot == "" {
		return guestPath
	}
	cleanRoot := filepath.Clean(workspaceRoot)
	slug := WorkspaceSlug(cleanRoot)
	guestRoot := "/workspaces/" + slug

	if guestPath == guestRoot {
		return cleanRoot
	}
	prefix := guestRoot + "/"
	if strings.HasPrefix(guestPath, prefix) {
		rel := strings.TrimPrefix(guestPath, prefix)
		return filepath.Join(cleanRoot, filepath.FromSlash(rel))
	}
	return guestPath
}

func DefaultVMEnv(goarch string, userEnv map[string]string) []string {
	if goarch == "" {
		goarch = "arm64"
	}
	base := map[string]string{
		"GOCACHE":     "/cache/gobuild",
		"GOMODCACHE":  "/cache/gomod",
		"GOOS":        "linux",
		"GOARCH":      goarch,
		"PATH":        "/usr/local/go/bin:/usr/bin:/bin",
		"HOME":        "/root",
		"CGO_ENABLED": "0",
	}
	for k, v := range userEnv {
		base[k] = v
	}
	keys := make([]string, 0, len(base))
	for k := range base {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, k := range keys {
		env = append(env, k+"="+base[k])
	}
	return env
}
