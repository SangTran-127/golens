package fsutil

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"golens/core/bridge"
	"golens/core/vmexec"
)

type SSHSigningKeyInfo struct {
	Path           string `json:"path"`
	PublicKeyPath  string `json:"publicKeyPath"`
	KeyType        string `json:"keyType"`
	Fingerprint    string `json:"fingerprint"`
	Comment        string `json:"comment"`
	PublicKey      string `json:"publicKey"`
	IsSecurityKey  bool   `json:"isSecurityKey"`
	HasPassphrase  bool   `json:"hasPassphrase"`
	VerifyRequired bool   `json:"verifyRequired"`
}

type SSHSigningDiscoveryResult struct {
	Keys               []SSHSigningKeyInfo `json:"keys"`
	HasHomebrewOpenSSH bool                `json:"hasHomebrewOpenSSH"`
}

type SignPayloadError struct {
	Code    string
	Message string
}

func (e *SignPayloadError) Error() string {
	return e.Message
}

type ExpectedCommitPayload struct {
	TreeSHA       string
	ParentSHAs    []string
	AuthorLine    string
	CommitterLine string
	Message       []byte
}

type ExpectedTagPayload struct {
	ObjectSHA  string
	TagName    string
	TaggerLine string
	Message    []byte
}

type CommitSignatureVerification struct {
	Status      string `json:"status"`
	Fingerprint string `json:"fingerprint,omitempty"`
	SignerEmail string `json:"signerEmail,omitempty"`
}

func FindHomebrewSSHKeygen() string {
	for _, cand := range []string{"/opt/homebrew/bin/ssh-keygen", "/usr/local/bin/ssh-keygen"} {
		if fi, err := os.Stat(cand); err == nil && !fi.IsDir() {
			return cand
		}
	}
	return ""
}

func resolveSSHKeygenForSigning(isSecurityKey bool) (string, error) {
	if hb := FindHomebrewSSHKeygen(); hb != "" {
		return hb, nil
	}
	if isSecurityKey {
		return "", errors.New("OpenSSH from Homebrew is required to sign with a security key (brew install openssh).")
	}
	if fi, err := os.Stat("/usr/bin/ssh-keygen"); err == nil && !fi.IsDir() {
		return "/usr/bin/ssh-keygen", nil
	}
	return "", errors.New("ssh-keygen was not found on this Mac.")
}

func ExpandRealHomePath(p string) string {
	p = strings.TrimSpace(p)
	if p == "~" {
		if home := vmexec.RealHomeDir(); home != "" {
			return home
		}
	}
	if strings.HasPrefix(p, "~/") {
		if home := vmexec.RealHomeDir(); home != "" {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func DiscoverSSHSigningKeys(extraPaths []string) SSHSigningDiscoveryResult {
	res := SSHSigningDiscoveryResult{
		Keys:               []SSHSigningKeyInfo{},
		HasHomebrewOpenSSH: FindHomebrewSSHKeygen() != "",
	}

	seen := map[string]bool{}
	var candidates []string

	if home := vmexec.RealHomeDir(); home != "" {
		sshDir := filepath.Join(home, ".ssh")
		if entries, err := os.ReadDir(sshDir); err == nil {
			for _, entry := range entries {
				if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pub") {
					continue
				}
				privPath := filepath.Join(sshDir, strings.TrimSuffix(entry.Name(), ".pub"))
				candidates = append(candidates, privPath)
			}
		}
	}

	for _, extra := range extraPaths {
		expanded := ExpandRealHomePath(extra)
		expanded = strings.TrimSuffix(expanded, ".pub")
		if expanded != "" {
			candidates = append(candidates, expanded)
		}
	}

	for _, privPath := range candidates {
		cleanPriv := filepath.Clean(privPath)
		if seen[cleanPriv] {
			continue
		}
		info, err := InspectSSHSigningKey(cleanPriv)
		if err != nil {
			continue
		}
		seen[cleanPriv] = true
		res.Keys = append(res.Keys, info)
	}

	sort.SliceStable(res.Keys, func(i, j int) bool {
		if res.Keys[i].IsSecurityKey != res.Keys[j].IsSecurityKey {
			return res.Keys[i].IsSecurityKey
		}
		if res.Keys[i].HasPassphrase != res.Keys[j].HasPassphrase {
			return !res.Keys[i].HasPassphrase
		}
		return filepath.Base(res.Keys[i].Path) < filepath.Base(res.Keys[j].Path)
	})

	return res
}

func InspectSSHSigningKey(privOrPubPath string) (SSHSigningKeyInfo, error) {
	expanded := ExpandRealHomePath(privOrPubPath)
	privPath := strings.TrimSuffix(expanded, ".pub")
	pubPath := privPath + ".pub"

	privFi, err := os.Stat(privPath)
	if err != nil || privFi.IsDir() {
		return SSHSigningKeyInfo{}, fmt.Errorf("private key handle not found at %s", privPath)
	}

	hasPass, privKeyType, privPubBytes, err := CheckPrivateKeyHeader(privPath)
	if err != nil {
		return SSHSigningKeyInfo{}, err
	}

	var pubKey ssh.PublicKey
	var comment string
	var pubLine string

	if pubBytes, err := os.ReadFile(pubPath); err == nil {
		parsed, cmt, _, _, perr := ssh.ParseAuthorizedKey(pubBytes)
		if perr == nil {
			pubKey = parsed
			comment = strings.TrimSpace(cmt)
			pubLine = strings.TrimSpace(string(pubBytes))
		}
	}
	if pubKey == nil && len(privPubBytes) > 0 {
		if parsed, perr := ssh.ParsePublicKey(privPubBytes); perr == nil {
			pubKey = parsed
			pubLine = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(parsed)))
		}
	}
	if pubKey == nil {
		return SSHSigningKeyInfo{}, fmt.Errorf("unable to parse public key for %s", privPath)
	}

	keyType := pubKey.Type()
	if keyType == "" {
		keyType = privKeyType
	}
	isSK := strings.HasPrefix(keyType, "sk-")

	return SSHSigningKeyInfo{
		Path:          privPath,
		PublicKeyPath: pubPath,
		KeyType:       keyType,
		Fingerprint:   ssh.FingerprintSHA256(pubKey),
		Comment:       comment,
		PublicKey:     pubLine,
		IsSecurityKey: isSK,
		HasPassphrase: hasPass,
	}, nil
}

func CheckPrivateKeyHeader(privKeyPath string) (hasPassphrase bool, keyType string, pubKeyBlob []byte, err error) {
	raw, err := os.ReadFile(privKeyPath)
	if err != nil {
		return false, "", nil, err
	}
	const beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
	const endMarker = "-----END OPENSSH PRIVATE KEY-----"
	start := bytes.Index(raw, []byte(beginMarker))
	end := bytes.Index(raw, []byte(endMarker))
	if start < 0 || end <= start {
		return false, "", nil, errors.New("unsupported SSH private key format (expected OpenSSH format)")
	}
	b64Body := bytes.ReplaceAll(raw[start+len(beginMarker):end], []byte("\n"), nil)
	b64Body = bytes.ReplaceAll(b64Body, []byte("\r"), nil)
	decoded, err := base64.StdEncoding.DecodeString(string(b64Body))
	if err != nil {
		return false, "", nil, fmt.Errorf("corrupt OpenSSH key base64: %w", err)
	}
	const magic = "openssh-key-v1\x00"
	if !bytes.HasPrefix(decoded, []byte(magic)) {
		return false, "", nil, errors.New("invalid openssh-key-v1 header")
	}
	rest := decoded[len(magic):]
	cipherName, rest, ok := readSSHString(rest)
	if !ok {
		return false, "", nil, errors.New("truncated openssh-key-v1 ciphername")
	}
	kdfName, rest, ok := readSSHString(rest)
	if !ok {
		return false, "", nil, errors.New("truncated openssh-key-v1 kdfname")
	}
	_, rest, ok = readSSHString(rest)
	if !ok || len(rest) < 4 {
		return false, "", nil, errors.New("truncated openssh-key-v1 kdfoptions")
	}
	numKeys := binary.BigEndian.Uint32(rest[:4])
	rest = rest[4:]
	if numKeys == 0 {
		return false, "", nil, errors.New("no keys in openssh-key-v1 file")
	}
	pubBlob, _, ok := readSSHString(rest)
	if !ok {
		return false, "", nil, errors.New("truncated openssh-key-v1 public key")
	}
	ktBytes, _, _ := readSSHString(pubBlob)
	encrypted := string(kdfName) != "none" || string(cipherName) != "none"
	return encrypted, string(ktBytes), pubBlob, nil
}

func readSSHString(b []byte) (val []byte, rest []byte, ok bool) {
	if len(b) < 4 {
		return nil, nil, false
	}
	n := binary.BigEndian.Uint32(b[:4])
	if uint32(len(b)-4) < n {
		return nil, nil, false
	}
	return b[4 : 4+n], b[4+n:], true
}

func VerifyGitCommitPayload(payload []byte, exp ExpectedCommitPayload) error {
	sep := bytes.Index(payload, []byte("\n\n"))
	if sep < 0 {
		return &SignPayloadError{
			Code:    "malformed_payload",
			Message: "The commit payload is malformed and could not be verified for signing.",
		}
	}
	headerBlock := string(payload[:sep])
	bodyBytes := payload[sep+2:]
	lines := strings.Split(headerBlock, "\n")
	if len(lines) < 3 {
		return &SignPayloadError{
			Code:    "malformed_payload",
			Message: "The commit header is incomplete and could not be verified for signing.",
		}
	}

	idx := 0
	if !strings.HasPrefix(lines[idx], "tree ") {
		return &SignPayloadError{
			Code:    "malformed_payload",
			Message: "The commit payload is missing its tree header.",
		}
	}
	gotTree := strings.TrimSpace(strings.TrimPrefix(lines[idx], "tree "))
	if !strings.EqualFold(gotTree, strings.TrimSpace(exp.TreeSHA)) {
		return &SignPayloadError{
			Code:    "hook_modified_index",
			Message: "A pre-commit hook modified staged files. Review the updated changes and click Commit again to sign.",
		}
	}
	idx++

	var gotParents []string
	for idx < len(lines) && strings.HasPrefix(lines[idx], "parent ") {
		gotParents = append(gotParents, strings.TrimSpace(strings.TrimPrefix(lines[idx], "parent ")))
		idx++
	}
	if len(gotParents) != len(exp.ParentSHAs) {
		return &SignPayloadError{
			Code:    "parent_mismatch",
			Message: "The repository HEAD changed while preparing the commit. Try committing again.",
		}
	}
	for i := range gotParents {
		if !strings.EqualFold(gotParents[i], strings.TrimSpace(exp.ParentSHAs[i])) {
			return &SignPayloadError{
				Code:    "parent_mismatch",
				Message: "The repository HEAD changed while preparing the commit. Try committing again.",
			}
		}
	}

	if idx >= len(lines) || !strings.HasPrefix(lines[idx], "author ") {
		return &SignPayloadError{
			Code:    "identity_mismatch",
			Message: "The commit payload is missing its author header.",
		}
	}
	gotAuthor := strings.TrimPrefix(lines[idx], "author ")
	if gotAuthor != exp.AuthorLine {
		return &SignPayloadError{
			Code:    "identity_mismatch",
			Message: "The commit author identity did not match the expected configuration.",
		}
	}
	idx++

	if idx >= len(lines) || !strings.HasPrefix(lines[idx], "committer ") {
		return &SignPayloadError{
			Code:    "identity_mismatch",
			Message: "The commit payload is missing its committer header.",
		}
	}
	gotCommitter := strings.TrimPrefix(lines[idx], "committer ")
	if gotCommitter != exp.CommitterLine {
		return &SignPayloadError{
			Code:    "identity_mismatch",
			Message: "The committer identity did not match the expected configuration.",
		}
	}
	idx++

	if idx < len(lines) && strings.HasPrefix(lines[idx], "encoding ") {
		enc := strings.TrimSpace(strings.TrimPrefix(lines[idx], "encoding "))
		if enc == "" || strings.ContainsAny(enc, " \t\r\n") {
			return &SignPayloadError{
				Code:    "unexpected_header",
				Message: "The commit encoding header is invalid.",
			}
		}
		idx++
	}

	if idx < len(lines) {
		for _, rem := range lines[idx:] {
			if strings.HasPrefix(rem, "mergetag ") || strings.HasPrefix(rem, " ") {
				return &SignPayloadError{
					Code:    "mergetag_unsupported",
					Message: "Merging a signed tag includes a mergetag header that cannot be automatically verified for signing. You can complete this merge commit without signing.",
				}
			}
		}
		return &SignPayloadError{
			Code:    "unexpected_header",
			Message: "The commit contains extra headers that cannot be verified for signing.",
		}
	}

	if !bytes.Equal(bodyBytes, exp.Message) {
		return &SignPayloadError{
			Code:    "hook_modified_message",
			Message: "A Git hook modified the commit message during commit. Review your hooks or commit without signing.",
		}
	}

	return nil
}

func VerifyGitTagPayload(payload []byte, exp ExpectedTagPayload) error {
	sep := bytes.Index(payload, []byte("\n\n"))
	if sep < 0 {
		return &SignPayloadError{
			Code:    "malformed_payload",
			Message: "The tag payload is malformed and could not be verified for signing.",
		}
	}
	headerBlock := string(payload[:sep])
	bodyBytes := payload[sep+2:]
	lines := strings.Split(headerBlock, "\n")
	if len(lines) < 4 {
		return &SignPayloadError{
			Code:    "malformed_payload",
			Message: "The tag header is incomplete and could not be verified for signing.",
		}
	}

	if !strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(lines[0], "object ")), strings.TrimSpace(exp.ObjectSHA)) || !strings.HasPrefix(lines[0], "object ") {
		return &SignPayloadError{
			Code:    "object_mismatch",
			Message: "The tag target commit did not match the expected revision.",
		}
	}
	if lines[1] != "type commit" {
		return &SignPayloadError{
			Code:    "type_mismatch",
			Message: "Only annotated tags pointing to commits can be signed.",
		}
	}
	if lines[2] != "tag "+exp.TagName {
		return &SignPayloadError{
			Code:    "tag_name_mismatch",
			Message: "The tag name in the payload did not match the requested tag.",
		}
	}
	if lines[3] != "tagger "+exp.TaggerLine {
		return &SignPayloadError{
			Code:    "identity_mismatch",
			Message: "The tagger identity did not match the expected configuration.",
		}
	}
	idx := 4
	if idx < len(lines) && strings.HasPrefix(lines[idx], "encoding ") {
		idx++
	}
	if idx < len(lines) {
		return &SignPayloadError{
			Code:    "unexpected_header",
			Message: "The tag contains unexpected headers and could not be verified for signing.",
		}
	}
	if !bytes.Equal(bodyBytes, exp.Message) {
		return &SignPayloadError{
			Code:    "hook_modified_message",
			Message: "The tag message did not match the expected text.",
		}
	}
	return nil
}

func SignWithSSHKeygenOnHost(ctx context.Context, privKeyPath string, payload []byte) ([]byte, error) {
	info, err := InspectSSHSigningKey(privKeyPath)
	if err != nil {
		return nil, err
	}
	if info.HasPassphrase {
		return nil, &SignPayloadError{
			Code:    "key_has_passphrase",
			Message: "This SSH key is protected by a passphrase. Choose a hardware security key (-sk) or an unencrypted signing key.",
		}
	}
	sshKeygenBin, err := resolveSSHKeygenForSigning(info.IsSecurityKey)
	if err != nil {
		return nil, &SignPayloadError{
			Code:    "missing_homebrew_openssh",
			Message: err.Error(),
		}
	}

	var randBytes [8]byte
	_, _ = rand.Read(randBytes[:])
	bufPath := filepath.Join(os.TempDir(), "golens-sign-"+hex.EncodeToString(randBytes[:]))
	sigPath := bufPath + ".sig"
	if err := os.WriteFile(bufPath, payload, 0600); err != nil {
		return nil, fmt.Errorf("failed to create temporary signing buffer: %w", err)
	}
	defer func() {
		_ = os.Remove(bufPath)
		_ = os.Remove(sigPath)
	}()

	signCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(signCtx, sshKeygenBin, "-Y", "sign", "-n", "git", "-f", info.Path, bufPath)
	cmd.Env = []string{
		"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
		"HOME=" + vmexec.RealHomeDir(),
		"SSH_ASKPASS=",
		"SSH_ASKPASS_REQUIRE=never",
		"DISPLAY=",
	}

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	var stdoutBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start ssh-keygen: %w", err)
	}

	var (
		stderrMu     sync.Mutex
		stderrBuf    bytes.Buffer
		touchTimer   *time.Timer
		emittedTouch bool
	)
	stopTouchStatus := func() {
		stderrMu.Lock()
		if touchTimer != nil {
			touchTimer.Stop()
			touchTimer = nil
		}
		wasEmitted := emittedTouch
		emittedTouch = false
		stderrMu.Unlock()
		if wasEmitted {
			bridge.Status("gitTouchSecurityKey", "done")
		}
	}
	defer stopTouchStatus()

	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		tmp := make([]byte, 512)
		for {
			n, rerr := stderrPipe.Read(tmp)
			if n > 0 {
				stderrMu.Lock()
				stderrBuf.Write(tmp[:n])
				current := stderrBuf.String()
				if (strings.Contains(current, "Confirm user presence") || strings.Contains(current, "touch")) && touchTimer == nil && !emittedTouch {
					touchTimer = time.AfterFunc(100*time.Millisecond, func() {
						stderrMu.Lock()
						if touchTimer == nil {
							stderrMu.Unlock()
							return
						}
						emittedTouch = true
						stderrMu.Unlock()
						bridge.Status("gitTouchSecurityKey", "waiting")
					})
				}
				stderrMu.Unlock()
			}
			if rerr != nil {
				return
			}
		}
	}()

	waitErr := cmd.Wait()
	<-stderrDone
	stopTouchStatus()

	if waitErr != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return nil, context.Canceled
		}
		if errors.Is(signCtx.Err(), context.DeadlineExceeded) {
			return nil, &SignPayloadError{
				Code:    "touch_timeout",
				Message: "Timed out waiting for you to touch your security key.",
			}
		}
		stderrMu.Lock()
		errText := strings.TrimSpace(stderrBuf.String())
		stderrMu.Unlock()
		lower := strings.ToLower(errText)
		switch {
		case strings.Contains(lower, "device not found") || strings.Contains(lower, "no device"):
			return nil, &SignPayloadError{
				Code:    "device_not_found",
				Message: "Security key not detected. Plug in your security key and try again.",
			}
		case strings.Contains(lower, "pin required") || strings.Contains(lower, "verify-required") || strings.Contains(lower, "passphrase"):
			return nil, &SignPayloadError{
				Code:    "pin_or_passphrase_required",
				Message: "This security key requires a PIN or passphrase that cannot be prompted here. Use a touch-only security key (without -O verify-required).",
			}
		case errText != "":
			return nil, &SignPayloadError{
				Code:    "ssh_keygen_failed",
				Message: errText,
			}
		default:
			return nil, waitErr
		}
	}

	sigBytes, err := os.ReadFile(sigPath)
	if err != nil || len(sigBytes) == 0 {
		return nil, errors.New("ssh-keygen completed without producing a signature file")
	}
	return sigBytes, nil
}

func computeExpectedTreeSHAInVM(ctx context.Context, mount, dir string) (string, error) {
	revCmd := GitCommand(ctx, mount, dir, "rev-parse", "--git-path", "index")
	revOut, err := revCmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to locate git index path: %w", err)
	}
	guestIndexPath := strings.TrimSpace(string(revOut))
	if guestIndexPath == "" {
		return "", errors.New("git rev-parse --git-path index returned empty path")
	}
	if !strings.HasPrefix(guestIndexPath, "/") {
		guestDir := vmexec.HostToGuestPath(mount, dir)
		guestIndexPath = filepath.Join(guestDir, guestIndexPath)
	}

	var randBytes [8]byte
	_, _ = rand.Read(randBytes[:])
	tmpIndex := "/tmp/golens-idx-" + hex.EncodeToString(randBytes[:])

	cpCmd := vmexec.CommandContext(ctx, "cp", "-f", guestIndexPath, tmpIndex)
	cpCmd.DialTimeout = GitDialTimeout
	if cpErr := cpCmd.Run(); cpErr != nil {
		_ = cpErr
	}
	defer func() {
		rmCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		rmCmd := vmexec.CommandContext(rmCtx, "rm", "-f", tmpIndex)
		rmCmd.DialTimeout = GitDialTimeout
		_ = rmCmd.Run()
	}()

	wtRes := RunGitWithOptions(ctx, GitRunOptions{
		Root:     mount,
		Dir:      dir,
		Mounted:  true,
		ExtraEnv: map[string]string{"GIT_INDEX_FILE": tmpIndex},
	}, "write-tree")
	if wtRes.Err != nil || wtRes.ExitCode != 0 {
		return "", fmt.Errorf("git write-tree failed: %s", strings.TrimSpace(string(wtRes.Output)))
	}
	return strings.TrimSpace(string(wtRes.Output)), nil
}

func readExpectedCommitParentsAndAmendAuthor(ctx context.Context, root, dir string, amend bool) (parents []string, amendAuthor string, err error) {
	if amend {
		catRes := RunGitWithOptions(ctx, GitRunOptions{Root: root, Dir: dir, Mounted: true}, "cat-file", "commit", "HEAD")
		if catRes.Err != nil || catRes.ExitCode != 0 {
			return nil, "", fmt.Errorf("failed to read HEAD commit for amend: %s", strings.TrimSpace(string(catRes.Output)))
		}
		raw := catRes.Output
		sep := bytes.Index(raw, []byte("\n\n"))
		headerPart := string(raw)
		if sep >= 0 {
			headerPart = string(raw[:sep])
		}
		for _, line := range strings.Split(headerPart, "\n") {
			if strings.HasPrefix(line, "parent ") {
				parents = append(parents, strings.TrimSpace(strings.TrimPrefix(line, "parent ")))
			} else if strings.HasPrefix(line, "author ") && amendAuthor == "" {
				amendAuthor = strings.TrimPrefix(line, "author ")
			}
		}
		if amendAuthor == "" {
			return nil, "", errors.New("HEAD commit is missing author header")
		}
		return parents, amendAuthor, nil
	}

	headRes := RunGitWithOptions(ctx, GitRunOptions{Root: root, Dir: dir, Mounted: true}, "rev-parse", "--verify", "HEAD")
	if headRes.Err == nil && headRes.ExitCode == 0 {
		if sha := strings.TrimSpace(string(headRes.Output)); sha != "" {
			parents = append(parents, sha)
		}
	}
	mergeRes := RunGitWithOptions(ctx, GitRunOptions{Root: root, Dir: dir, Mounted: true}, "rev-parse", "--verify", "MERGE_HEAD")
	if mergeRes.Err == nil && mergeRes.ExitCode == 0 {
		for _, line := range strings.Split(strings.TrimSpace(string(mergeRes.Output)), "\n") {
			if sha := strings.TrimSpace(line); sha != "" {
				parents = append(parents, sha)
			}
		}
	}
	return parents, "", nil
}

func readGitUserIdentityInVM(ctx context.Context, root, dir string) (name, email string, err error) {
	nameRes := RunGitWithOptions(ctx, GitRunOptions{Root: root, Dir: dir, Mounted: true}, "config", "user.name")
	emailRes := RunGitWithOptions(ctx, GitRunOptions{Root: root, Dir: dir, Mounted: true}, "config", "user.email")
	name = strings.TrimSpace(string(nameRes.Output))
	email = strings.TrimSpace(string(emailRes.Output))
	if name == "" || email == "" {
		return "", "", errors.New("Set your Author Name and Author Email in Source Control settings before signing commits.")
	}
	return name, email, nil
}

func computeExpectedTreeSHAOnHost(ctx context.Context, dir string) (string, error) {
	revRes := runGitOnHost(ctx, dir, GitRunOptions{Root: dir, Dir: dir}, []string{"rev-parse", "--git-path", "index"})
	if revRes.Err != nil || revRes.ExitCode != 0 {
		return "", fmt.Errorf("failed to locate git index path: %s", strings.TrimSpace(string(revRes.Output)))
	}
	hostIndexPath := strings.TrimSpace(string(revRes.Output))
	if hostIndexPath == "" {
		return "", errors.New("git rev-parse --git-path index returned empty path")
	}
	if !filepath.IsAbs(hostIndexPath) {
		hostIndexPath = filepath.Join(dir, hostIndexPath)
	}

	var randBytes [8]byte
	_, _ = rand.Read(randBytes[:])
	tmpIndex := filepath.Join(os.TempDir(), "golens-idx-"+hex.EncodeToString(randBytes[:]))
	if srcBytes, readErr := os.ReadFile(hostIndexPath); readErr == nil {
		if writeErr := os.WriteFile(tmpIndex, srcBytes, 0o600); writeErr != nil {
			return "", fmt.Errorf("failed to snapshot git index: %w", writeErr)
		}
	}
	defer func() {
		_ = os.Remove(tmpIndex)
	}()

	wtRes := runGitOnHost(ctx, dir, GitRunOptions{
		Root:     dir,
		Dir:      dir,
		ExtraEnv: map[string]string{"GIT_INDEX_FILE": tmpIndex},
	}, []string{"write-tree"})
	if wtRes.Err != nil || wtRes.ExitCode != 0 {
		return "", fmt.Errorf("git write-tree failed: %s", strings.TrimSpace(string(wtRes.Output)))
	}
	return strings.TrimSpace(string(wtRes.Output)), nil
}

func shouldSignOnHost(ctx context.Context) (bool, error) {
	if bridge.IsHostMode() {
		return true, nil
	}
	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	flags, err := vmexec.PingFlags(pingCtx, vmexec.DefaultPort)
	if err != nil {
		if !bridge.IsSandboxed() && isVMUnavailable(err) {
			return true, nil
		}
		return false, nil
	}
	if flags&vmexec.FlagSignRelayCapable == 0 {
		return false, &SignPayloadError{
			Code:    "vm_agent_outdated",
			Message: "The Linux VM runtime needs to be updated to support commit signing.",
		}
	}
	return false, nil
}

func withHostGitSignHelper(
	ctx context.Context,
	onSign func(reqCtx context.Context, payload []byte) ([]byte, error),
	run func(signProgram string, extraEnv map[string]string) GitRunResult,
) GitRunResult {
	tmpDir, err := os.MkdirTemp("/tmp", "gs-*")
	if err != nil {
		tmpDir, err = os.MkdirTemp("", "gs-*")
	}
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()
	_ = os.Chmod(tmpDir, 0o700)

	sockPath := filepath.Join(tmpDir, "s.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	_ = os.Chmod(sockPath, 0o600)

	mux := http.NewServeMux()
	mux.HandleFunc("/sign", func(w http.ResponseWriter, r *http.Request) {
		reqCtx, cancel := context.WithCancel(ctx)
		defer cancel()
		go func() {
			select {
			case <-r.Context().Done():
				cancel()
			case <-reqCtx.Done():
			}
		}()
		payload, readErr := io.ReadAll(io.LimitReader(r.Body, 16<<20))
		if readErr != nil {
			http.Error(w, readErr.Error(), http.StatusBadRequest)
			return
		}
		sig, signErr := onSign(reqCtx, payload)
		if signErr != nil {
			http.Error(w, signErr.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(sig)
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	defer func() {
		shutCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = srv.Shutdown(shutCtx)
		_ = ln.Close()
	}()

	scriptPath := filepath.Join(tmpDir, "sign.sh")
	const script = "#!/bin/sh\nset -eu\nfor last; do :; done\n/usr/bin/curl -sS --fail --unix-socket \"$GOLENS_SIGN_SOCK\" --data-binary @- -o \"${last}.sig\" http://localhost/sign < \"$last\"\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o700); err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	return run(scriptPath, map[string]string{"GOLENS_SIGN_SOCK": sockPath})
}

func RunSignedGitCommit(ctx context.Context, root, dir, privKeyPath, rawMessage string, amend bool) GitRunResult {
	if dir == "" {
		dir = root
	}
	useHost, err := shouldSignOnHost(ctx)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	mount := dir
	if !useHost {
		var inside bool
		mount, inside = ResolveGitMount(root, dir)
		if !inside && root == "" {
			mount = latestKnownRootContaining(filepath.Clean(dir))
			inside = mount != ""
		}
		if !inside {
			return GitRunResult{ExitCode: -1, Flags: GitResultOutside, Err: ErrOutsideWorkspace}
		}
	}

	keyInfo, err := InspectSSHSigningKey(privKeyPath)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	if keyInfo.HasPassphrase {
		msg := "This SSH key is protected by a passphrase. Choose a hardware security key (-sk) or an unencrypted signing key."
		return GitRunResult{ExitCode: 1, Err: errors.New(msg), Output: []byte(msg)}
	}
	if _, err := resolveSSHKeygenForSigning(keyInfo.IsSecurityKey); err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	userName, userEmail, err := readGitUserIdentityInVM(ctx, mount, dir)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	stripRes := RunGitWithOptions(ctx, GitRunOptions{
		Root:    mount,
		Dir:     dir,
		Input:   []byte(rawMessage),
		Mounted: !useHost,
	}, "stripspace")
	if stripRes.Err != nil || stripRes.ExitCode != 0 {
		return stripRes
	}
	expectedMessage := stripRes.Output

	var expectedTree string
	if useHost {
		expectedTree, err = computeExpectedTreeSHAOnHost(ctx, dir)
	} else {
		expectedTree, err = computeExpectedTreeSHAInVM(ctx, mount, dir)
	}
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	expectedParents, amendAuthor, err := readExpectedCommitParentsAndAmendAuthor(ctx, mount, dir, amend)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	now := time.Now()
	pinnedDate := fmt.Sprintf("%d %s", now.Unix(), now.Format("-0700"))
	committerLine := fmt.Sprintf("%s <%s> %s", userName, userEmail, pinnedDate)
	authorLine := committerLine
	if amend && amendAuthor != "" {
		authorLine = amendAuthor
	}

	exp := ExpectedCommitPayload{
		TreeSHA:       expectedTree,
		ParentSHAs:    expectedParents,
		AuthorLine:    authorLine,
		CommitterLine: committerLine,
		Message:       expectedMessage,
	}

	var (
		signMu      sync.Mutex
		signedCount int
		signErr     error
	)
	onSign := func(reqCtx context.Context, payload []byte) ([]byte, error) {
		signMu.Lock()
		if signedCount >= 1 {
			signMu.Unlock()
			err := errors.New("multiple signing requests in a single commit are not allowed")
			return nil, err
		}
		if verr := VerifyGitCommitPayload(payload, exp); verr != nil {
			signErr = verr
			signMu.Unlock()
			return nil, verr
		}
		signedCount++
		signMu.Unlock()

		sig, serr := SignWithSSHKeygenOnHost(reqCtx, keyInfo.Path, payload)
		if serr != nil {
			signMu.Lock()
			signErr = serr
			signMu.Unlock()
			return nil, serr
		}
		return sig, nil
	}

	var res GitRunResult
	if useHost {
		res = withHostGitSignHelper(ctx, onSign, func(signProgram string, helperEnv map[string]string) GitRunResult {
			args := []string{
				"-c", "gpg.format=ssh",
				"-c", "gpg.ssh.program=" + signProgram,
				"-c", "user.signingkey=" + keyInfo.Path,
				"-c", "user.name=" + userName,
				"-c", "user.email=" + userEmail,
				"commit", "-S", "--cleanup=verbatim", "-F", "-",
			}
			if amend {
				args = append(args, "--amend")
			}
			extraEnv := map[string]string{
				"GIT_AUTHOR_DATE":    pinnedDate,
				"GIT_COMMITTER_DATE": pinnedDate,
			}
			for k, v := range helperEnv {
				extraEnv[k] = v
			}
			return runGitOnHost(ctx, dir, GitRunOptions{
				Root:     dir,
				Dir:      dir,
				Input:    expectedMessage,
				ExtraEnv: extraEnv,
			}, args)
		})
	} else {
		args := []string{
			"-c", "gpg.format=ssh",
			"-c", "gpg.ssh.program=/usr/local/bin/golens-git-sign",
			"-c", "user.signingkey=" + keyInfo.Path,
			"-c", "user.name=" + userName,
			"-c", "user.email=" + userEmail,
			"commit", "-S", "--cleanup=verbatim", "-F", "-",
		}
		if amend {
			args = append(args, "--amend")
		}
		res = RunGitWithOptions(ctx, GitRunOptions{
			Root:    mount,
			Dir:     dir,
			Input:   expectedMessage,
			Mounted: true,
			ExtraEnv: map[string]string{
				"GIT_AUTHOR_DATE":    pinnedDate,
				"GIT_COMMITTER_DATE": pinnedDate,
			},
			OnSignRequest: onSign,
		}, args...)
	}

	signMu.Lock()
	capturedErr := signErr
	signMu.Unlock()
	if res.ExitCode != 0 && capturedErr != nil {
		if errors.Is(capturedErr, context.Canceled) {
			res.Flags |= GitResultCancelled
			res.Err = context.Canceled
		} else {
			res.Err = capturedErr
			res.Output = []byte(capturedErr.Error())
		}
	}
	return res
}

func RunSignedGitTag(ctx context.Context, root, dir, privKeyPath, tagName, revision, rawMessage string) GitRunResult {
	if dir == "" {
		dir = root
	}
	useHost, err := shouldSignOnHost(ctx)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	mount := dir
	if !useHost {
		var inside bool
		mount, inside = ResolveGitMount(root, dir)
		if !inside && root == "" {
			mount = latestKnownRootContaining(filepath.Clean(dir))
			inside = mount != ""
		}
		if !inside {
			return GitRunResult{ExitCode: -1, Flags: GitResultOutside, Err: ErrOutsideWorkspace}
		}
	}

	keyInfo, err := InspectSSHSigningKey(privKeyPath)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}
	if keyInfo.HasPassphrase {
		msg := "This SSH key is protected by a passphrase. Choose a hardware security key (-sk) or an unencrypted signing key."
		return GitRunResult{ExitCode: 1, Err: errors.New(msg), Output: []byte(msg)}
	}
	if _, err := resolveSSHKeygenForSigning(keyInfo.IsSecurityKey); err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	userName, userEmail, err := readGitUserIdentityInVM(ctx, mount, dir)
	if err != nil {
		return GitRunResult{ExitCode: 1, Err: err, Output: []byte(err.Error())}
	}

	stripRes := RunGitWithOptions(ctx, GitRunOptions{
		Root:    mount,
		Dir:     dir,
		Input:   []byte(rawMessage),
		Mounted: !useHost,
	}, "stripspace")
	if stripRes.Err != nil || stripRes.ExitCode != 0 {
		return stripRes
	}
	expectedMessage := stripRes.Output

	revRes := RunGitWithOptions(ctx, GitRunOptions{
		Root:    mount,
		Dir:     dir,
		Mounted: !useHost,
	}, "rev-parse", "--verify", revision+"^{commit}")
	if revRes.Err != nil || revRes.ExitCode != 0 {
		return revRes
	}
	expectedObjectSHA := strings.TrimSpace(string(revRes.Output))

	now := time.Now()
	pinnedDate := fmt.Sprintf("%d %s", now.Unix(), now.Format("-0700"))
	taggerLine := fmt.Sprintf("%s <%s> %s", userName, userEmail, pinnedDate)

	exp := ExpectedTagPayload{
		ObjectSHA:  expectedObjectSHA,
		TagName:    tagName,
		TaggerLine: taggerLine,
		Message:    expectedMessage,
	}

	var (
		signMu      sync.Mutex
		signedCount int
		signErr     error
	)
	onSign := func(reqCtx context.Context, payload []byte) ([]byte, error) {
		signMu.Lock()
		if signedCount >= 1 {
			signMu.Unlock()
			return nil, errors.New("multiple signing requests in a single tag are not allowed")
		}
		if verr := VerifyGitTagPayload(payload, exp); verr != nil {
			signErr = verr
			signMu.Unlock()
			return nil, verr
		}
		signedCount++
		signMu.Unlock()

		sig, serr := SignWithSSHKeygenOnHost(reqCtx, keyInfo.Path, payload)
		if serr != nil {
			signMu.Lock()
			signErr = serr
			signMu.Unlock()
			return nil, serr
		}
		return sig, nil
	}

	var res GitRunResult
	if useHost {
		res = withHostGitSignHelper(ctx, onSign, func(signProgram string, helperEnv map[string]string) GitRunResult {
			args := []string{
				"-c", "gpg.format=ssh",
				"-c", "gpg.ssh.program=" + signProgram,
				"-c", "user.signingkey=" + keyInfo.Path,
				"-c", "user.name=" + userName,
				"-c", "user.email=" + userEmail,
				"tag", "-s", "--cleanup=verbatim", "-F", "-", tagName, revision,
			}
			extraEnv := map[string]string{
				"GIT_AUTHOR_DATE":    pinnedDate,
				"GIT_COMMITTER_DATE": pinnedDate,
			}
			for k, v := range helperEnv {
				extraEnv[k] = v
			}
			return runGitOnHost(ctx, dir, GitRunOptions{
				Root:     dir,
				Dir:      dir,
				Input:    expectedMessage,
				ExtraEnv: extraEnv,
			}, args)
		})
	} else {
		args := []string{
			"-c", "gpg.format=ssh",
			"-c", "gpg.ssh.program=/usr/local/bin/golens-git-sign",
			"-c", "user.signingkey=" + keyInfo.Path,
			"-c", "user.name=" + userName,
			"-c", "user.email=" + userEmail,
			"tag", "-s", "--cleanup=verbatim", "-F", "-", tagName, revision,
		}
		res = RunGitWithOptions(ctx, GitRunOptions{
			Root:    mount,
			Dir:     dir,
			Input:   expectedMessage,
			Mounted: true,
			ExtraEnv: map[string]string{
				"GIT_AUTHOR_DATE":    pinnedDate,
				"GIT_COMMITTER_DATE": pinnedDate,
			},
			OnSignRequest: onSign,
		}, args...)
	}

	signMu.Lock()
	capturedErr := signErr
	signMu.Unlock()
	if res.ExitCode != 0 && capturedErr != nil {
		if errors.Is(capturedErr, context.Canceled) {
			res.Flags |= GitResultCancelled
			res.Err = context.Canceled
		} else {
			res.Err = capturedErr
			res.Output = []byte(capturedErr.Error())
		}
	}
	return res
}

type sshSigEnvelope struct {
	Version       uint32
	PublicKey     []byte
	Namespace     string
	Reserved      string
	HashAlgorithm string
	Signature     []byte
}

type sshSigSignedData struct {
	Namespace     string
	Reserved      string
	HashAlgorithm string
	Hash          []byte
}

func VerifyCommitSignature(rawCommit []byte, allowedEmail, allowedPubKeyLine string) CommitSignatureVerification {
	sep := bytes.Index(rawCommit, []byte("\n\n"))
	if sep < 0 {
		return CommitSignatureVerification{Status: "N"}
	}
	headerBlock := string(rawCommit[:sep])
	bodyBytes := rawCommit[sep+2:]
	lines := strings.Split(headerBlock, "\n")

	var (
		hasSig         bool
		sigLines       []string
		strippedHeader []string
		committerEmail string
		inSig          bool
	)

	for _, line := range lines {
		if inSig {
			if strings.HasPrefix(line, " ") {
				sigLines = append(sigLines, strings.TrimPrefix(line, " "))
				continue
			}
			inSig = false
		}
		if !hasSig && strings.HasPrefix(line, "gpgsig ") {
			hasSig = true
			inSig = true
			sigLines = append(sigLines, strings.TrimPrefix(line, "gpgsig "))
			continue
		}
		if strings.HasPrefix(line, "committer ") {
			committerEmail = extractEmailFromIdentLine(strings.TrimPrefix(line, "committer "))
		}
		strippedHeader = append(strippedHeader, line)
	}

	if !hasSig {
		return CommitSignatureVerification{Status: "N"}
	}

	var signedCommitBuf bytes.Buffer
	signedCommitBuf.WriteString(strings.Join(strippedHeader, "\n"))
	signedCommitBuf.WriteString("\n\n")
	signedCommitBuf.Write(bodyBytes)
	signedCommitBytes := signedCommitBuf.Bytes()

	const beginSSH = "-----BEGIN SSH SIGNATURE-----"
	const endSSH = "-----END SSH SIGNATURE-----"
	sigPEM := strings.Join(sigLines, "\n")
	start := strings.Index(sigPEM, beginSSH)
	end := strings.Index(sigPEM, endSSH)
	if start < 0 || end <= start {
		return CommitSignatureVerification{Status: "B", SignerEmail: committerEmail}
	}
	b64 := strings.ReplaceAll(sigPEM[start+len(beginSSH):end], "\n", "")
	b64 = strings.ReplaceAll(b64, "\r", "")
	b64 = strings.TrimSpace(b64)
	rawSig, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(rawSig) < 6 || string(rawSig[:6]) != "SSHSIG" {
		return CommitSignatureVerification{Status: "B", SignerEmail: committerEmail}
	}

	var env sshSigEnvelope
	if err := ssh.Unmarshal(rawSig[6:], &env); err != nil {
		return CommitSignatureVerification{Status: "B", SignerEmail: committerEmail}
	}
	if env.Version != 1 || env.Namespace != "git" {
		return CommitSignatureVerification{Status: "B", SignerEmail: committerEmail}
	}

	pubKey, err := ssh.ParsePublicKey(env.PublicKey)
	if err != nil {
		return CommitSignatureVerification{Status: "B", SignerEmail: committerEmail}
	}
	fingerprint := ssh.FingerprintSHA256(pubKey)

	var digest []byte
	switch env.HashAlgorithm {
	case "sha512":
		sum := sha512.Sum512(signedCommitBytes)
		digest = sum[:]
	case "sha256":
		sum := sha256.Sum256(signedCommitBytes)
		digest = sum[:]
	default:
		return CommitSignatureVerification{Status: "B", Fingerprint: fingerprint, SignerEmail: committerEmail}
	}

	signedBlob := append([]byte("SSHSIG"), ssh.Marshal(sshSigSignedData{
		Namespace:     env.Namespace,
		Reserved:      env.Reserved,
		HashAlgorithm: env.HashAlgorithm,
		Hash:          digest,
	})...)

	var sshSig ssh.Signature
	if err := ssh.Unmarshal(env.Signature, &sshSig); err != nil {
		return CommitSignatureVerification{Status: "B", Fingerprint: fingerprint, SignerEmail: committerEmail}
	}

	if err := pubKey.Verify(signedBlob, &sshSig); err != nil {
		return CommitSignatureVerification{Status: "B", Fingerprint: fingerprint, SignerEmail: committerEmail}
	}

	if strings.TrimSpace(allowedPubKeyLine) != "" && strings.TrimSpace(allowedEmail) != "" {
		if allowedKey, _, _, _, aerr := ssh.ParseAuthorizedKey([]byte(allowedPubKeyLine)); aerr == nil {
			if bytes.Equal(allowedKey.Marshal(), pubKey.Marshal()) &&
				strings.EqualFold(strings.TrimSpace(committerEmail), strings.TrimSpace(allowedEmail)) {
				return CommitSignatureVerification{
					Status:      "G",
					Fingerprint: fingerprint,
					SignerEmail: committerEmail,
				}
			}
		}
	}

	return CommitSignatureVerification{
		Status:      "U",
		Fingerprint: fingerprint,
		SignerEmail: committerEmail,
	}
}

func extractEmailFromIdentLine(ident string) string {
	lt := strings.IndexByte(ident, '<')
	gt := strings.IndexByte(ident, '>')
	if lt >= 0 && gt > lt {
		return strings.TrimSpace(ident[lt+1 : gt])
	}
	return ""
}

func WriteAllowedSignersFile(path, email, pubKeyLine string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	email = strings.TrimSpace(email)
	pubKeyLine = strings.TrimSpace(pubKeyLine)
	if email == "" || pubKeyLine == "" {
		_ = os.Remove(path)
		return nil
	}
	content := fmt.Sprintf("%s namespaces=\"git\" %s\n", email, pubKeyLine)
	return os.WriteFile(path, []byte(content), 0600)
}

func ReadAllowedSigner(path string) (email, pubKeyLine string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	line := strings.TrimSpace(string(b))
	if line == "" {
		return "", ""
	}
	const marker = ` namespaces="git" `
	idx := strings.Index(line, marker)
	if idx <= 0 {
		return "", ""
	}
	return strings.TrimSpace(line[:idx]), strings.TrimSpace(line[idx+len(marker):])
}

var _ io.Reader = (*bytes.Reader)(nil)
