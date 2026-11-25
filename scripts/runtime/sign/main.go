package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

const keyEnv = "GOLENS_RUNTIME_SIGNING_KEY"

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sign:", err)
		os.Exit(1)
	}
}

func usage() error {
	return errors.New(`usage:
  keygen <private-key-path>                          write a new key (mode 0600), print its public key
  public-key                                          print the public key of $` + keyEnv + `
  sign <manifest> [<signature>]                       sign with $` + keyEnv + ` (default <manifest>.sig)
  verify -public-key <base64> <manifest> [<signature>]`)
}

func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "keygen":
		if len(args) != 2 {
			return usage()
		}
		pub, err := keygen(args[1])
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, pub)
	case "public-key":
		if len(args) != 1 {
			return usage()
		}
		key, err := loadPrivateKey(os.Getenv(keyEnv))
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)))
	case "sign":
		if len(args) < 2 || len(args) > 3 {
			return usage()
		}
		key, err := loadPrivateKey(os.Getenv(keyEnv))
		if err != nil {
			return err
		}
		return signFile(key, args[1], signaturePath(args[1:]))
	case "verify":
		fs := flag.NewFlagSet("verify", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		pubFlag := fs.String("public-key", "", "")
		if err := fs.Parse(args[1:]); err != nil || *pubFlag == "" || fs.NArg() < 1 || fs.NArg() > 2 {
			return usage()
		}
		pub, err := decodeFixed(*pubFlag, ed25519.PublicKeySize, "public key")
		if err != nil {
			return err
		}
		if err := verifyFile(ed25519.PublicKey(pub), fs.Arg(0), signaturePath(fs.Args())); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "signature OK")
	default:
		return usage()
	}
	return nil
}

func signaturePath(args []string) string {
	if len(args) == 2 {
		return args[1]
	}
	return args[0] + ".sig"
}

func keygen(path string) (string, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	_, werr := fmt.Fprintln(f, base64.StdEncoding.EncodeToString(priv.Seed()))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(path)
		return "", werr
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

func loadPrivateKey(path string) (ed25519.PrivateKey, error) {
	if path == "" {
		return nil, fmt.Errorf("%s is not set", keyEnv)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := decodeFixed(string(raw), ed25519.SeedSize, "private key")
	if err != nil {
		return nil, err
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func decodeFixed(text string, size int, what string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(text))
	if err != nil {
		return nil, fmt.Errorf("%s is not base64", what)
	}
	if len(b) != size {
		return nil, fmt.Errorf("%s has %d bytes, want %d", what, len(b), size)
	}
	return b, nil
}

func signFile(key ed25519.PrivateKey, manifest, sigPath string) error {
	msg, err := os.ReadFile(manifest)
	if err != nil {
		return err
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, msg))
	return os.WriteFile(sigPath, []byte(sig), 0o644)
}

func verifyFile(pub ed25519.PublicKey, manifest, sigPath string) error {
	msg, err := os.ReadFile(manifest)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(sigPath)
	if err != nil {
		return err
	}
	sig, err := decodeFixed(string(raw), ed25519.SignatureSize, "signature")
	if err != nil {
		return err
	}
	if !ed25519.Verify(pub, msg, sig) {
		return errors.New("signature does not match the manifest")
	}
	return nil
}
