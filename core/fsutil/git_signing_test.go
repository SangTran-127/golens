package fsutil

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"golens/core/bridge"
	"golens/core/vmexec"
)

func TestGitSigning_CheckPrivateKeyHeader(t *testing.T) {
	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "id_ed25519")
	cmd := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "", "-C", "dev@example.com", "-f", keyPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen failed: %v (%s)", err, string(out))
	}

	hasPass, keyType, _, err := CheckPrivateKeyHeader(keyPath)
	if err != nil {
		t.Fatalf("CheckPrivateKeyHeader failed: %v", err)
	}
	if hasPass {
		t.Errorf("expected hasPass=false for unencrypted key")
	}
	if keyType != "ssh-ed25519" {
		t.Errorf("expected keyType=ssh-ed25519, got %q", keyType)
	}

	encKeyPath := filepath.Join(tmp, "id_ed25519_enc")
	cmdEnc := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "secretpass", "-C", "dev@example.com", "-f", encKeyPath)
	if out, err := cmdEnc.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen encrypted failed: %v (%s)", err, string(out))
	}
	hasPassEnc, _, _, err := CheckPrivateKeyHeader(encKeyPath)
	if err != nil {
		t.Fatalf("CheckPrivateKeyHeader encrypted failed: %v", err)
	}
	if !hasPassEnc {
		t.Errorf("expected hasPass=true for passphrase-protected key")
	}
}

func TestGitSigning_VerifyGitCommitPayload(t *testing.T) {
	exp := ExpectedCommitPayload{
		TreeSHA:       "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
		ParentSHAs:    []string{"1111111111111111111111111111111111111111"},
		AuthorLine:    "Orig Author <orig@example.com> 1700000000 +0700",
		CommitterLine: "Sang Tran <sang@example.com> 1700000500 +0700",
		Message:       []byte("feat: support hardware security key\n\nDetailed body.\n"),
	}

	validPayload := []byte(fmt.Sprintf(
		"tree %s\nparent %s\nauthor %s\ncommitter %s\n\n%s",
		exp.TreeSHA, exp.ParentSHAs[0], exp.AuthorLine, exp.CommitterLine, string(exp.Message),
	))

	if err := VerifyGitCommitPayload(validPayload, exp); err != nil {
		t.Fatalf("expected valid payload to pass, got: %v", err)
	}

	// Hook modified index (different tree SHA)
	badTreePayload := bytes.Replace(validPayload, []byte(exp.TreeSHA), []byte("2222222222222222222222222222222222222222"), 1)
	if err := VerifyGitCommitPayload(badTreePayload, exp); err == nil || !strings.Contains(err.Error(), "pre-commit hook modified staged files") {
		t.Fatalf("expected hook_modified_index error, got: %v", err)
	}

	// Hook modified commit message
	badMsgPayload := append([]byte(nil), validPayload...)
	badMsgPayload = append(badMsgPayload, []byte("Signed-off-by: hook\n")...)
	if err := VerifyGitCommitPayload(badMsgPayload, exp); err == nil || !strings.Contains(err.Error(), "hook modified the commit message") {
		t.Fatalf("expected hook_modified_message error, got: %v", err)
	}

	// Mergetag header rejected with clear message
	mergeTagPayload := []byte(fmt.Sprintf(
		"tree %s\nparent %s\nauthor %s\ncommitter %s\nmergetag object 3333333333333333333333333333333333333333\n type commit\n\n%s",
		exp.TreeSHA, exp.ParentSHAs[0], exp.AuthorLine, exp.CommitterLine, string(exp.Message),
	))
	if err := VerifyGitCommitPayload(mergeTagPayload, exp); err == nil || !strings.Contains(err.Error(), "mergetag") {
		t.Fatalf("expected mergetag error, got: %v", err)
	}
}

func TestGitSigning_VerifyCommitSignature_StandardAndSK(t *testing.T) {
	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "id_ed25519")
	if out, err := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "", "-C", "sang@example.com", "-f", keyPath).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen failed: %v (%s)", err, string(out))
	}
	pubBytes, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		t.Fatal(err)
	}
	pubLine := strings.TrimSpace(string(pubBytes))

	commitBody := []byte("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" +
		"parent 1111111111111111111111111111111111111111\n" +
		"author Sang Tran <sang@example.com> 1700000000 +0700\n" +
		"committer Sang Tran <sang@example.com> 1700000000 +0700\n\n" +
		"feat: signed commit test\n")

	sigBytes, err := SignWithSSHKeygenOnHost(context.Background(), keyPath, commitBody)
	if err != nil {
		t.Fatalf("SignWithSSHKeygenOnHost failed: %v", err)
	}

	rawCommit := embedSSHSignatureIntoCommit(commitBody, string(sigBytes))

	// 1. Verified ('G') when key and committer email match allowed_signers
	vG := VerifyCommitSignature(rawCommit, "sang@example.com", pubLine)
	if vG.Status != "G" {
		t.Fatalf("expected status G, got %+v", vG)
	}

	// 2. Signed ('U') when signature is valid but signed by a different email/key than configured
	vU := VerifyCommitSignature(rawCommit, "other@example.com", pubLine)
	if vU.Status != "U" {
		t.Fatalf("expected status U when email differs, got %+v", vU)
	}

	// 3. Invalid ('B') when commit message is tampered with
	tampered := bytes.Replace(rawCommit, []byte("feat: signed commit test"), []byte("feat: tampered message!"), 1)
	vB := VerifyCommitSignature(tampered, "sang@example.com", pubLine)
	if vB.Status != "B" {
		t.Fatalf("expected status B on tampered commit, got %+v", vB)
	}

	// 4. Unsigned ('N') when no gpgsig header exists
	vN := VerifyCommitSignature(commitBody, "sang@example.com", pubLine)
	if vN.Status != "N" {
		t.Fatalf("expected status N on unsigned commit, got %+v", vN)
	}

	// 5. Security Key (sk-ssh-ed25519@openssh.com) SSHSIG verification with 5-byte flags+counter Rest
	skCommit, skPubLine := buildSyntheticSKCommitSignature(t, commitBody, "sang@example.com")
	vSK := VerifyCommitSignature(skCommit, "sang@example.com", skPubLine)
	if vSK.Status != "G" {
		t.Fatalf("expected status G for sk-ssh-ed25519@openssh.com signature, got %+v", vSK)
	}
}

func embedSSHSignatureIntoCommit(unsignedCommit []byte, sigPEM string) []byte {
	sep := bytes.Index(unsignedCommit, []byte("\n\n"))
	headers := string(unsignedCommit[:sep])
	body := unsignedCommit[sep+2:]

	sigLines := strings.Split(strings.TrimSpace(sigPEM), "\n")
	var gpgsigHeader strings.Builder
	for i, l := range sigLines {
		if i == 0 {
			gpgsigHeader.WriteString("gpgsig " + l + "\n")
		} else {
			gpgsigHeader.WriteString(" " + l + "\n")
		}
	}
	return append([]byte(headers+"\n"+gpgsigHeader.String()+"\n"), body...)
}

func buildSyntheticSKCommitSignature(t *testing.T, unsignedCommit []byte, email string) ([]byte, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	const skKeyType = "sk-ssh-ed25519@openssh.com"
	const appID = "ssh:"

	// sk-ssh-ed25519@openssh.com public key wire format: string(keytype) || string(32-byte pub) || string(application)
	rawSKPub := ssh.Marshal(struct {
		KeyType     string
		Pub         []byte
		Application string
	}{
		KeyType:     skKeyType,
		Pub:         pub,
		Application: appID,
	})
	sshPub, err := ssh.ParsePublicKey(rawSKPub)
	if err != nil {
		t.Fatalf("ParsePublicKey sk failed: %v", err)
	}
	pubLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub))) + " " + email

	msgHash := sha512.Sum512(unsignedCommit)
	signedData := append([]byte("SSHSIG"), ssh.Marshal(sshSigSignedData{
		Namespace:     "git",
		Reserved:      "",
		HashAlgorithm: "sha512",
		Hash:          msgHash[:],
	})...)

	var flags byte = 0x01 // user present
	var counter uint32 = 42
	var rest [5]byte
	rest[0] = flags
	binary.BigEndian.PutUint32(rest[1:5], counter)

	appHash := sha512.New() // Note: x/crypto/ssh uses sha256(application) || flags || counter || sha256(message)
	_ = appHash
	// Construct exact FIDO2 signed message verified by x/crypto/ssh skEd25519PublicKey.Verify
	// Using ssh.Signature with Format, Blob, and Rest (5 bytes)
	appDigest := sha256.Sum256([]byte(appID))
	dataDigest := sha256.Sum256(signedData)
	var fidoMsg bytes.Buffer
	fidoMsg.Write(appDigest[:])
	fidoMsg.Write(rest[:])
	fidoMsg.Write(dataDigest[:])
	edSig := ed25519.Sign(priv, fidoMsg.Bytes())

	innerSig := ssh.Marshal(ssh.Signature{
		Format: skKeyType,
		Blob:   edSig,
		Rest:   rest[:],
	})

	envBytes := append([]byte("SSHSIG"), ssh.Marshal(sshSigEnvelope{
		Version:       1,
		PublicKey:     rawSKPub,
		Namespace:     "git",
		Reserved:      "",
		HashAlgorithm: "sha512",
		Signature:     innerSig,
	})...)

	pemStr := "-----BEGIN SSH SIGNATURE-----\n" +
		base64.StdEncoding.EncodeToString(envBytes) +
		"\n-----END SSH SIGNATURE-----\n"
	return embedSSHSignatureIntoCommit(unsignedCommit, pemStr), pubLine
}

func TestGitSigning_MockVMSignRelayRoundTrip(t *testing.T) {
	resetWorkspaceRoots(t)
	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "id_ed25519")
	if out, err := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "", "-C", "sang@example.com", "-f", keyPath).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen failed: %v (%s)", err, string(out))
	}

	ws := "/Users/test/velo"
	RegisterWorkspaceRoot(ws)

	const (
		treeSHA   = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
		parentSHA = "1111111111111111111111111111111111111111"
	)

	var receivedSig []byte
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		host, guest := net.Pipe()
		go func() {
			defer guest.Close()
			fc := vmexec.NewFrameConn(guest)
			header, payload, err := fc.ReadFrame()
			if err != nil {
				return
			}
			if header.Type == vmexec.FramePing {
				_ = fc.WriteFrame(vmexec.FramePong, vmexec.FlagSignRelayCapable, nil)
				return
			}
			if header.Type != vmexec.FrameExecInit {
				return
			}
			var init vmexec.ExecInit
			_ = json.Unmarshal(payload, &init)
			// Drain FrameStdin / FrameStdinClose before responding when needed
			joined := strings.Join(init.Argv, " ")
			switch {
			case strings.Contains(joined, "config user.name"):
				_, _, _ = fc.ReadFrame()
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("Sang Tran\n"))
				guestExit(fc, 0)
			case strings.Contains(joined, "config user.email"):
				_, _, _ = fc.ReadFrame()
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("sang@example.com\n"))
				guestExit(fc, 0)
			case strings.Contains(joined, "stripspace"):
				for {
					h, _, err := fc.ReadFrame()
					if err != nil || h.Type == vmexec.FrameStdinClose {
						break
					}
				}
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("feat: relay signed commit\n"))
				guestExit(fc, 0)
			case strings.Contains(joined, "rev-parse --git-path index"):
				_, _, _ = fc.ReadFrame()
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(".git/index\n"))
				guestExit(fc, 0)
			case init.Argv[0] == "cp" || init.Argv[0] == "rm":
				_, _, _ = fc.ReadFrame()
				guestExit(fc, 0)
			case strings.Contains(joined, "write-tree"):
				_, _, _ = fc.ReadFrame()
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(treeSHA+"\n"))
				guestExit(fc, 0)
			case strings.Contains(joined, "rev-parse --verify HEAD"):
				_, _, _ = fc.ReadFrame()
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(parentSHA+"\n"))
				guestExit(fc, 0)
			case strings.Contains(joined, "rev-parse --verify MERGE_HEAD"):
				_, _, _ = fc.ReadFrame()
				guestExit(fc, 1)
			case strings.Contains(joined, "commit -S"):
				if !init.EnableCommitSigning {
					t.Errorf("expected EnableCommitSigning=true on commit -S")
				}
				for {
					h, _, err := fc.ReadFrame()
					if err != nil || h.Type == vmexec.FrameStdinClose {
						break
					}
				}
				var pinnedDate string
				for _, kv := range init.Env {
					if strings.HasPrefix(kv, "GIT_COMMITTER_DATE=") {
						pinnedDate = strings.TrimPrefix(kv, "GIT_COMMITTER_DATE=")
					}
				}
				ident := fmt.Sprintf("Sang Tran <sang@example.com> %s", pinnedDate)
				commitPayload := fmt.Sprintf("tree %s\nparent %s\nauthor %s\ncommitter %s\n\nfeat: relay signed commit\n",
					treeSHA, parentSHA, ident, ident)
				if err := fc.WriteFrame(vmexec.FrameSignRequest, 0, []byte(commitPayload)); err != nil {
					t.Errorf("WriteFrame FrameSignRequest failed: %v", err)
					guestExit(fc, 1)
					return
				}
				h, sigPl, err := fc.ReadFrame()
				if err != nil || h.Type != vmexec.FrameSignResponse || h.Flags != 0 {
					t.Errorf("expected valid FrameSignResponse, got h=%+v err=%v payload=%s", h, err, string(sigPl))
					guestExit(fc, 1)
					return
				}
				receivedSig = sigPl
				_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("[main 2222222] feat: relay signed commit\n"))
				guestExit(fc, 0)
			default:
				_, _, _ = fc.ReadFrame()
				guestExit(fc, 0)
			}
		}()
		return host, nil
	})
	t.Cleanup(func() { bridge.SetVsockConnDialer(nil) })

	res := RunSignedGitCommit(context.Background(), ws, ws, keyPath, "feat: relay signed commit", false)
	if res.Err != nil || res.ExitCode != 0 {
		t.Fatalf("RunSignedGitCommit failed: exit=%d err=%v out=%s", res.ExitCode, res.Err, string(res.Output))
	}
	if !bytes.Contains(receivedSig, []byte("-----BEGIN SSH SIGNATURE-----")) {
		t.Fatalf("expected SSH signature from host relay, got: %s", string(receivedSig))
	}
}

func TestGitSigning_HostModeSignedCommitAmendAndTagEndToEnd(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	resetWorkspaceRoots(t)
	prevMode := bridge.ExecutionMode()
	bridge.SetExecutionMode("host")
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })

	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		t.Fatal("vsock must not be dialed in host signing mode")
		return nil, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "id_ed25519")
	if out, err := exec.Command("/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "", "-C", "sang@example.com", "-f", keyPath).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen failed: %v (%s)", err, string(out))
	}
	pubBytes, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		t.Fatal(err)
	}
	pubLine := strings.TrimSpace(string(pubBytes))

	repo := filepath.Join(tmp, "repo with space")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.name", "Sang Tran"},
		{"config", "user.email", "sang@example.com"},
	} {
		if res := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, args...); res.Err != nil || res.ExitCode != 0 {
			t.Fatalf("git %v failed: %+v (%s)", args, res, string(res.Output))
		}
	}

	if err := os.WriteFile(filepath.Join(repo, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if res := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "add", "main.go"); res.Err != nil || res.ExitCode != 0 {
		t.Fatalf("git add failed: %+v", res)
	}

	// 1. Signed initial commit on unborn HEAD
	c1 := RunSignedGitCommit(context.Background(), repo, repo, keyPath, "feat: initial host signed commit", false)
	if c1.Err != nil || c1.ExitCode != 0 {
		t.Fatalf("host RunSignedGitCommit (initial) failed: exit=%d err=%v out=%s", c1.ExitCode, c1.Err, string(c1.Output))
	}
	cat1 := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "cat-file", "commit", "HEAD")
	if v := VerifyCommitSignature(cat1.Output, "sang@example.com", pubLine); v.Status != "G" {
		t.Fatalf("expected verified signature G on initial commit, got %+v\nraw:\n%s", v, string(cat1.Output))
	}

	// 2. Signed amend commit
	c2 := RunSignedGitCommit(context.Background(), repo, repo, keyPath, "feat: amended host signed commit", true)
	if c2.Err != nil || c2.ExitCode != 0 {
		t.Fatalf("host RunSignedGitCommit (amend) failed: exit=%d err=%v out=%s", c2.ExitCode, c2.Err, string(c2.Output))
	}
	cat2 := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "cat-file", "commit", "HEAD")
	if v := VerifyCommitSignature(cat2.Output, "sang@example.com", pubLine); v.Status != "G" || !bytes.Contains(cat2.Output, []byte("amended host signed commit")) {
		t.Fatalf("expected verified signature G on amended commit, got %+v", v)
	}

	// 3. Signed annotated tag
	tRes := RunSignedGitTag(context.Background(), repo, repo, keyPath, "v1.0.0", "HEAD", "Release v1.0.0")
	if tRes.Err != nil || tRes.ExitCode != 0 {
		t.Fatalf("host RunSignedGitTag failed: exit=%d err=%v out=%s", tRes.ExitCode, tRes.Err, string(tRes.Output))
	}
	catTag := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "cat-file", "tag", "v1.0.0")
	if catTag.Err != nil || !bytes.Contains(catTag.Output, []byte("-----BEGIN SSH SIGNATURE-----")) {
		t.Fatalf("expected SSH signature on tag v1.0.0, got: %s", string(catTag.Output))
	}
}
