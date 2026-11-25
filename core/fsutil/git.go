package fsutil

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

type GitExecResult struct {
	Output   string `json:"output"`
	ExitCode int    `json:"exitCode"`
	Error    string `json:"error,omitempty"`
}

var ErrOutsideWorkspace = errors.New("this folder isn't shared with the Linux VM, so Git can't run in it")

const GitDialTimeout = 300 * time.Millisecond

const (
	GitResultTruncated   uint32 = 1 << 0
	GitResultUnavailable uint32 = 1 << 1
	GitResultCancelled   uint32 = 1 << 2
	GitResultOutside     uint32 = 1 << 3
	GitResultHeaderSize         = 16
)

type GitRunOptions struct {
	Root          string
	Dir           string
	Input         []byte
	MaxOutput     int
	Mounted       bool
	ExtraEnv      map[string]string
	OnSignRequest func(ctx context.Context, payload []byte) ([]byte, error)
}

type GitRunResult struct {
	Output    []byte
	ExitCode  int
	Truncated bool
	Flags     uint32
	Err       error
}

type GitHostCredential struct {
	Provider string `json:"provider"`
	Scheme   string `json:"scheme"`
	Host     string `json:"host"`
	Username string `json:"username"`
	Token    string `json:"token"`
}

var (
	gitCredsMu   sync.RWMutex
	gitHostCreds []GitHostCredential
)

func SetGitHostCredentialsJSON(raw string) {
	var creds []GitHostCredential
	if strings.TrimSpace(raw) != "" {
		_ = json.Unmarshal([]byte(raw), &creds)
	}
	SetGitHostCredentials(creds)
}

func SetGitHostCredentials(creds []GitHostCredential) {
	gitCredsMu.Lock()
	defer gitCredsMu.Unlock()
	cleaned := make([]GitHostCredential, 0, len(creds))
	for _, c := range creds {
		host := strings.TrimSpace(strings.ToLower(c.Host))
		host = strings.TrimPrefix(host, "https://")
		host = strings.TrimPrefix(host, "http://")
		host = strings.TrimRight(host, "/")
		token := strings.TrimSpace(c.Token)
		if host == "" || token == "" {
			continue
		}
		scheme := strings.TrimSpace(strings.ToLower(c.Scheme))
		if scheme != "http" {
			scheme = "https"
		}
		cleaned = append(cleaned, GitHostCredential{
			Provider: strings.TrimSpace(strings.ToLower(c.Provider)),
			Scheme:   scheme,
			Host:     host,
			Username: strings.TrimSpace(c.Username),
			Token:    token,
		})
	}
	gitHostCreds = cleaned
}

func GitAuthEnvMap() map[string]string {
	return buildGitAuthEnvMap(true)
}

func GitHostAuthEnvMap() map[string]string {
	return buildGitAuthEnvMap(false)
}

func buildGitAuthEnvMap(rewriteSSHToHTTPS bool) map[string]string {
	gitCredsMu.RLock()
	creds := append([]GitHostCredential(nil), gitHostCreds...)
	gitCredsMu.RUnlock()
	if len(creds) == 0 {
		return nil
	}
	type kv struct{ k, v string }
	var pairs []kv
	for _, c := range creds {
		authUser := c.Username
		if c.Provider == "gitlab" {
			authUser = "oauth2"
		} else if authUser == "" {
			authUser = "x-access-token"
		}
		basic := base64.StdEncoding.EncodeToString([]byte(authUser + ":" + c.Token))
		origin := c.Scheme + "://" + c.Host + "/"
		pairs = append(pairs, kv{"http." + origin + ".extraheader", "Authorization: Basic " + basic})
		if rewriteSSHToHTTPS {
			pairs = append(pairs,
				kv{"url." + origin + ".insteadOf", "git@" + c.Host + ":"},
				kv{"url." + origin + ".insteadOf", "ssh://git@" + c.Host + "/"},
			)
		}
	}
	env := make(map[string]string, len(pairs)*2+1)
	env["GIT_CONFIG_COUNT"] = strconv.Itoa(len(pairs))
	for i, p := range pairs {
		idx := strconv.Itoa(i)
		env["GIT_CONFIG_KEY_"+idx] = p.k
		env["GIT_CONFIG_VALUE_"+idx] = p.v
	}
	return env
}

var gitRemoteSubcommands = map[string]bool{
	"fetch":     true,
	"pull":      true,
	"push":      true,
	"clone":     true,
	"ls-remote": true,
}

var gitRemoteVerbs = map[string]map[string]bool{
	"remote":    {"update": true, "prune": true, "show": true, "set-head": true},
	"submodule": {"add": true, "update": true},
	"lfs":       {"fetch": true, "pull": true, "push": true, "clone": true},
}

var gitGlobalOptionsWithValue = map[string]bool{
	"-c":           true,
	"-C":           true,
	"--git-dir":    true,
	"--work-tree":  true,
	"--namespace":  true,
	"--config-env": true,
}

func gitSubcommand(args []string) (string, []string) {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if gitGlobalOptionsWithValue[arg] {
			i++
			continue
		}
		if strings.HasPrefix(arg, "-") {
			continue
		}
		return arg, args[i+1:]
	}
	return "", nil
}

func gitArgsNeedAuth(args []string) bool {
	sub, tail := gitSubcommand(args)
	if gitRemoteSubcommands[sub] {
		return true
	}
	verbs, ok := gitRemoteVerbs[sub]
	if !ok {
		return false
	}
	for _, arg := range tail {
		if !strings.HasPrefix(arg, "-") {
			return verbs[arg]
		}
	}
	return false
}

func GitVMEnv(withAuth bool) []string {
	overrides := map[string]string{
		"GIT_CONFIG_NOSYSTEM": "1",
		"GIT_TERMINAL_PROMPT": "0",
		"GIT_ASKPASS":         "",
		"GIT_PAGER":           "cat",
	}
	if withAuth {
		for k, v := range GitAuthEnvMap() {
			overrides[k] = v
		}
	}
	return vmexec.DefaultVMEnv("arm64", overrides)
}

func GitCommand(ctx context.Context, workspaceRoot, dir string, args ...string) *vmexec.Cmd {
	guestDir := vmexec.HostToGuestPath(workspaceRoot, dir)
	gitArgs := append([]string{"-c", "credential.helper="}, args...)
	cmd := vmexec.CommandContext(ctx, "git", gitArgs...)
	cmd.Dir = guestDir
	cmd.Env = GitVMEnv(gitArgsNeedAuth(args))
	cmd.DialTimeout = GitDialTimeout
	return cmd
}

func RunGit(ctx context.Context, workspaceRoot, dir string, input []byte, args ...string) ([]byte, int, error) {
	res := RunGitWithOptions(ctx, GitRunOptions{Root: workspaceRoot, Dir: dir, Input: input}, args...)
	return res.Output, res.ExitCode, res.Err
}

func RunGitWithOptions(ctx context.Context, opts GitRunOptions, args ...string) GitRunResult {
	dir := opts.Dir
	if dir == "" {
		dir = opts.Root
	}
	if bridge.IsHostMode() {
		return runGitOnHost(ctx, dir, opts, args)
	}
	mount, inside := ResolveGitMount(opts.Root, dir)
	if opts.Mounted && opts.Root == "" {
		mount = latestKnownRootContaining(filepath.Clean(dir))
		inside = mount != ""
	}
	if !inside {
		if !bridge.IsSandboxed() {
			return runGitOnHost(ctx, dir, opts, args)
		}
		return GitRunResult{ExitCode: -1, Flags: GitResultOutside, Err: ErrOutsideWorkspace}
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	out := &cappedBuffer{limit: opts.MaxOutput, onTruncate: cancel}
	cmd := GitCommand(runCtx, mount, dir, args...)
	for k, v := range opts.ExtraEnv {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.OnSignRequest = opts.OnSignRequest
	if len(opts.Input) > 0 {
		cmd.Stdin = bytes.NewReader(opts.Input)
	}
	cmd.Stdout = out
	cmd.Stderr = out
	err := cmd.Run()

	res := GitRunResult{Output: out.Bytes()}
	var exitErr *vmexec.ExitError
	switch {
	case out.Truncated():
		res.Truncated = true
		res.Flags |= GitResultTruncated
	case err == nil:
	case errors.As(err, &exitErr):
		res.ExitCode = exitErr.ExitCode()
		res.Err = err
	case isVMUnavailable(err):
		if !bridge.IsSandboxed() {
			return runGitOnHost(ctx, dir, opts, args)
		}
		res.ExitCode = -1
		res.Flags |= GitResultUnavailable
		res.Err = err
	default:
		res.ExitCode = -1
		res.Err = err
	}
	if errors.Is(ctx.Err(), context.Canceled) && !res.Truncated {
		res.Flags |= GitResultCancelled
		if res.Err == nil {
			res.ExitCode = -1
			res.Err = ctx.Err()
		}
	}
	res.Output = postProcessGitOutput(res.Output, mount, args, res.ExitCode != 0)
	return res
}

func isVMUnavailable(err error) bool {
	return errors.Is(err, vmexec.ErrVMUnavailable) ||
		errors.Is(err, bridge.ErrVMNotRunning) ||
		errors.Is(err, bridge.ErrDialerUnset)
}

func buildHostGitEnv(extra map[string]string, withAuth bool) []string {
	base := os.Environ()
	merged := make(map[string]string, len(base)+12)
	order := make([]string, 0, len(base)+12)
	setVar := func(k, v string) {
		if _, exists := merged[k]; !exists {
			order = append(order, k)
		}
		merged[k] = v
	}
	for _, kv := range base {
		parts := strings.SplitN(kv, "=", 2)
		if len(parts) == 2 && parts[0] != "GIT_EDITOR" && parts[0] != "GIT_SEQUENCE_EDITOR" {
			setVar(parts[0], parts[1])
		}
	}

	realHome := vmexec.RealHomeDir()
	if merged["HOME"] == "" && realHome != "" {
		setVar("HOME", realHome)
	}

	pathEntries := strings.Split(merged["PATH"], string(os.PathListSeparator))
	seenPath := make(map[string]bool, len(pathEntries)+8)
	cleanPaths := make([]string, 0, len(pathEntries)+8)
	addPath := func(p string) {
		p = strings.TrimSpace(p)
		if p == "" || seenPath[p] {
			return
		}
		seenPath[p] = true
		cleanPaths = append(cleanPaths, p)
	}
	for _, p := range pathEntries {
		addPath(p)
	}
	addPath("/opt/homebrew/bin")
	addPath("/usr/local/bin")
	addPath("/usr/local/go/bin")
	addPath("/Applications/1Password.app/Contents/MacOS")
	if realHome != "" {
		addPath(filepath.Join(realHome, ".local", "bin"))
		addPath(filepath.Join(realHome, "go", "bin"))
	}
	addPath("/usr/bin")
	addPath("/bin")
	addPath("/usr/sbin")
	addPath("/sbin")
	setVar("PATH", strings.Join(cleanPaths, string(os.PathListSeparator)))

	setVar("GIT_TERMINAL_PROMPT", "0")
	setVar("GIT_PAGER", "cat")
	if withAuth {
		for k, v := range GitHostAuthEnvMap() {
			setVar(k, v)
		}
	}
	for k, v := range extra {
		setVar(k, v)
	}

	out := make([]string, 0, len(order))
	for _, k := range order {
		out = append(out, k+"="+merged[k])
	}
	return out
}

func runGitOnHost(ctx context.Context, dir string, opts GitRunOptions, args []string) GitRunResult {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	hostEnv := buildHostGitEnv(opts.ExtraEnv, gitArgsNeedAuth(args))
	gitBin := "git"
	for _, kv := range hostEnv {
		if strings.HasPrefix(kv, "PATH=") {
			for _, p := range strings.Split(strings.TrimPrefix(kv, "PATH="), string(os.PathListSeparator)) {
				cand := filepath.Join(p, "git")
				if st, err := os.Stat(cand); err == nil && !st.IsDir() {
					gitBin = cand
					break
				}
			}
			break
		}
	}
	hostCmd := exec.CommandContext(runCtx, gitBin, args...)
	if dir != "" {
		hostCmd.Dir = dir
	}
	hostCmd.Env = hostEnv
	if len(opts.Input) > 0 {
		hostCmd.Stdin = bytes.NewReader(opts.Input)
	}
	out := &cappedBuffer{limit: opts.MaxOutput, onTruncate: cancel}
	hostCmd.Stdout = out
	hostCmd.Stderr = out
	err := hostCmd.Run()

	res := GitRunResult{Output: out.Bytes()}
	var exitErr *exec.ExitError
	switch {
	case out.Truncated():
		res.Truncated = true
		res.Flags |= GitResultTruncated
	case err == nil:
	case errors.As(err, &exitErr):
		res.ExitCode = exitErr.ExitCode()
		res.Err = err
	default:
		res.ExitCode = -1
		res.Err = err
	}
	if errors.Is(ctx.Err(), context.Canceled) && !res.Truncated {
		res.Flags |= GitResultCancelled
		if res.Err == nil {
			res.ExitCode = -1
			res.Err = ctx.Err()
		}
	}
	return res
}

type cappedBuffer struct {
	mu         sync.Mutex
	buf        bytes.Buffer
	limit      int
	truncated  bool
	onTruncate func()
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.truncated {
		return len(p), nil
	}
	if c.limit > 0 && c.buf.Len()+len(p) > c.limit {
		c.buf.Write(p[:c.limit-c.buf.Len()])
		c.truncated = true
		if c.onTruncate != nil {
			c.onTruncate()
		}
		return len(p), nil
	}
	c.buf.Write(p)
	return len(p), nil
}

func (c *cappedBuffer) Bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Bytes()
}

func (c *cappedBuffer) Truncated() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.truncated
}

func postProcessGitOutput(out []byte, workspaceRoot string, args []string, failed bool) []byte {
	if len(out) == 0 || workspaceRoot == "" || !bytes.Contains(out, []byte("/workspaces/")) {
		return out
	}
	switch sub, _ := gitSubcommand(args); sub {
	case "rev-parse", "worktree":
		return translateGuestPaths(out, workspaceRoot)
	}
	if failed {
		return translateGuestPaths(out, workspaceRoot)
	}
	return out
}

func translateGuestPaths(out []byte, workspaceRoot string) []byte {
	roots := append([]string{filepath.Clean(workspaceRoot)}, knownWorkspaceRoots()...)
	seen := map[string]bool{}
	for _, root := range roots {
		guest := vmexec.HostToGuestPath(root, root)
		if seen[guest] || guest == root {
			continue
		}
		seen[guest] = true
		out = replaceGuestRoot(out, []byte(guest), []byte(root))
	}
	return out
}

func replaceGuestRoot(out, guest, host []byte) []byte {
	if !bytes.Contains(out, guest) {
		return out
	}
	var b bytes.Buffer
	b.Grow(len(out))
	for {
		i := bytes.Index(out, guest)
		if i < 0 {
			b.Write(out)
			break
		}
		end := i + len(guest)
		if end == len(out) || isPathBoundary(out[end]) {
			b.Write(out[:i])
			b.Write(host)
		} else {
			b.Write(out[:end])
		}
		out = out[end:]
	}
	return b.Bytes()
}

func isPathBoundary(c byte) bool {
	switch c {
	case '/', '\n', '\r', '\t', ' ', 0, '\'', '"', ':', '`':
		return true
	}
	return false
}

func EncodedGitResultSize(res GitRunResult) int {
	errText := ""
	if res.Err != nil {
		errText = res.Err.Error()
	}
	return GitResultHeaderSize + len(errText) + len(res.Output)
}

func EncodeGitResult(dst []byte, res GitRunResult) {
	errText := ""
	if res.Err != nil {
		errText = res.Err.Error()
	}
	binary.LittleEndian.PutUint32(dst[0:4], uint32(int32(res.ExitCode)))
	binary.LittleEndian.PutUint32(dst[4:8], res.Flags)
	binary.LittleEndian.PutUint32(dst[8:12], uint32(len(errText)))
	binary.LittleEndian.PutUint32(dst[12:16], uint32(len(res.Output)))
	n := copy(dst[GitResultHeaderSize:], errText)
	copy(dst[GitResultHeaderSize+n:], res.Output)
}

func DecodeGitResult(src []byte) (GitRunResult, string, bool) {
	if len(src) < GitResultHeaderSize {
		return GitRunResult{}, "", false
	}
	errLen := int(binary.LittleEndian.Uint32(src[8:12]))
	outLen := int(binary.LittleEndian.Uint32(src[12:16]))
	if GitResultHeaderSize+errLen+outLen != len(src) {
		return GitRunResult{}, "", false
	}
	res := GitRunResult{
		ExitCode: int(int32(binary.LittleEndian.Uint32(src[0:4]))),
		Flags:    binary.LittleEndian.Uint32(src[4:8]),
		Output:   src[GitResultHeaderSize+errLen:],
	}
	res.Truncated = res.Flags&GitResultTruncated != 0
	return res, string(src[GitResultHeaderSize : GitResultHeaderSize+errLen]), true
}
