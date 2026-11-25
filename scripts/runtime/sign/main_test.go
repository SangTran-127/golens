package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newKey(t *testing.T) (dir, keyPath, pub string) {
	t.Helper()
	dir = t.TempDir()
	keyPath = filepath.Join(dir, "runtime.key")
	var out bytes.Buffer
	if err := run([]string{"keygen", keyPath}, &out); err != nil {
		t.Fatal(err)
	}
	return dir, keyPath, strings.TrimSpace(out.String())
}

func TestKeygenWritesSeedWithPrivateMode(t *testing.T) {
	_, keyPath, pub := newKey(t)
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key mode = %v, want 0600", info.Mode().Perm())
	}
	raw, _ := os.ReadFile(keyPath)
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		t.Fatalf("key file is not a base64 32-byte seed: %q", raw)
	}
	derived := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if base64.StdEncoding.EncodeToString(derived) != pub {
		t.Fatalf("printed public key does not belong to the seed")
	}
	if strings.Contains(pub, strings.TrimSpace(string(raw))) {
		t.Fatalf("keygen printed private material")
	}
}

func TestKeygenRefusesToOverwrite(t *testing.T) {
	_, keyPath, _ := newKey(t)
	if err := run([]string{"keygen", keyPath}, &bytes.Buffer{}); err == nil {
		t.Fatal("keygen overwrote an existing key")
	}
}

func TestSignAndVerify(t *testing.T) {
	dir, keyPath, pub := newKey(t)
	t.Setenv(keyEnv, keyPath)
	manifest := filepath.Join(dir, "golens-linux-runtime.json")
	if err := os.WriteFile(manifest, []byte("{\n  \"version\": \"2026.11.23\"\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"sign", manifest}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(manifest + ".sig")
	if err != nil {
		t.Fatal(err)
	}
	sig, err := base64.StdEncoding.DecodeString(string(raw))
	if err != nil || len(sig) != ed25519.SignatureSize {
		t.Fatalf("signature file is not a base64 64-byte signature: %q", raw)
	}

	var out bytes.Buffer
	if err := run([]string{"public-key"}, &out); err != nil || strings.TrimSpace(out.String()) != pub {
		t.Fatalf("public-key = %q, %v; want %q", out.String(), err, pub)
	}
	if err := run([]string{"verify", "-public-key", pub, manifest}, &bytes.Buffer{}); err != nil {
		t.Fatalf("verify: %v", err)
	}

	if err := os.WriteFile(manifest, []byte("{\n  \"version\": \"2026.11.24\"\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"verify", "-public-key", pub, manifest}, &bytes.Buffer{}); err == nil {
		t.Fatal("verify accepted a changed manifest")
	}

	_, _, otherPub := newKey(t)
	if err := os.WriteFile(manifest, []byte("{\n  \"version\": \"2026.11.23\"\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"verify", "-public-key", otherPub, manifest}, &bytes.Buffer{}); err == nil {
		t.Fatal("verify accepted another key")
	}
}

func TestLoadPrivateKeyRejectsBadInput(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"short":  base64.StdEncoding.EncodeToString(make([]byte, 16)),
		"base64": "not base64!",
	} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadPrivateKey(path); err == nil {
			t.Errorf("%s: key accepted", name)
		}
	}
	if _, err := loadPrivateKey(""); err == nil {
		t.Error("empty key path accepted")
	}
}
