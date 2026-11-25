package fsutil

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

type mockGuest struct {
	init    chan vmexec.ExecInit
	signals chan uint32
}

func installMockGuest(t *testing.T, serve func(fc *vmexec.FrameConn, init vmexec.ExecInit, signals <-chan uint32)) *mockGuest {
	t.Helper()
	g := &mockGuest{init: make(chan vmexec.ExecInit, 8), signals: make(chan uint32, 8)}
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		host, guest := net.Pipe()
		go func() {
			defer guest.Close()
			fc := vmexec.NewFrameConn(guest)
			header, payload, err := fc.ReadFrame()
			if err != nil || header.Type != vmexec.FrameExecInit {
				return
			}
			var init vmexec.ExecInit
			_ = json.Unmarshal(payload, &init)
			g.init <- init
			signals := make(chan uint32, 8)
			go func() {
				for {
					h, p, err := fc.ReadFrame()
					if err != nil {
						close(signals)
						return
					}
					if h.Type == vmexec.FrameSignal && len(p) == 4 {
						sig := binary.BigEndian.Uint32(p)
						signals <- sig
						g.signals <- sig
					}
				}
			}()
			serve(fc, init, signals)
		}()
		return host, nil
	})
	t.Cleanup(func() { bridge.SetVsockConnDialer(nil) })
	return g
}

func guestExit(fc *vmexec.FrameConn, code uint32) {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, code)
	_ = fc.WriteFrame(vmexec.FrameExit, 0, payload)
}

func resetWorkspaceRoots(t *testing.T) {
	t.Helper()
	ForgetWorkspaceRoots()
	t.Cleanup(ForgetWorkspaceRoots)
}

func TestPostProcessGitOutputTranslatesEveryRevParseLine(t *testing.T) {
	resetWorkspaceRoots(t)
	ws := "/Users/test/velo"
	guest := vmexec.HostToGuestPath(ws, ws)
	out := []byte(guest + "\n" + guest + "/.git\n")
	got := string(postProcessGitOutput(out, ws, []string{"--no-optional-locks", "rev-parse", "--show-toplevel", "--absolute-git-dir"}, false))
	want := ws + "\n" + ws + "/.git\n"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPostProcessGitOutputTranslatesErrorsButNotContent(t *testing.T) {
	resetWorkspaceRoots(t)
	ws := "/Users/test/velo"
	guest := vmexec.HostToGuestPath(ws, ws)
	errOut := []byte("fatal: '" + guest + "/x.go' is outside repository at '" + guest + "'\n")
	got := string(postProcessGitOutput(errOut, ws, []string{"add", "x.go"}, true))
	if strings.Contains(got, "/workspaces/") || !strings.Contains(got, ws+"/x.go") {
		t.Fatalf("error text not translated: %q", got)
	}
	content := []byte("path = " + guest + "\n")
	if got := postProcessGitOutput(content, ws, []string{"show", "HEAD:notes.txt"}, false); !bytes.Equal(got, content) {
		t.Fatalf("file content must not be rewritten, got %q", got)
	}
	longer := []byte(guest + "x/file\n")
	if got := postProcessGitOutput(longer, ws, []string{"rev-parse", "--show-toplevel"}, false); !bytes.Equal(got, longer) {
		t.Fatalf("a different slug must not be rewritten, got %q", got)
	}
}

func TestPostProcessGitOutputTranslatesOtherKnownWorkspace(t *testing.T) {
	resetWorkspaceRoots(t)
	other := "/Users/test/other"
	RegisterWorkspaceRoot(other)
	guest := vmexec.HostToGuestPath(other, other)
	got := string(postProcessGitOutput([]byte(guest+"/.git\n"), "/Users/test/velo", []string{"rev-parse", "--git-dir"}, false))
	if got != other+"/.git\n" {
		t.Fatalf("got %q", got)
	}
}

func TestResolveGitMount(t *testing.T) {
	resetWorkspaceRoots(t)
	ws := "/Users/test/velo"

	if mount, ok := ResolveGitMount(ws, ws+"/desktop/State"); !ok || mount != ws {
		t.Fatalf("explicit root with subdirectory: got %q %v", mount, ok)
	}
	if _, ok := ResolveGitMount(ws, "/Users/test"); ok {
		t.Fatal("a folder outside the root must be reported as outside")
	}
	if mount, ok := ResolveGitMount("", ws+"/desktop"); !ok || mount != ws+"/desktop" {
		t.Fatalf("unknown single path keeps its own mount: got %q %v", mount, ok)
	}

	RegisterWorkspaceRoot(ws)
	if mount, ok := ResolveGitMount("", ws+"/desktop/State"); !ok || mount != ws {
		t.Fatalf("single path inside an opened workspace: got %q %v", mount, ok)
	}
	if mount, ok := ResolveGitMount(ws+"/desktop", ws+"/desktop"); !ok || mount != ws {
		t.Fatalf("legacy root==dir inside an opened workspace: got %q %v", mount, ok)
	}

	RegisterWorkspaceRoot(ws + "/desktop")
	if mount, _ := ResolveGitMount("", ws+"/desktop/State"); mount != ws+"/desktop" {
		t.Fatalf("most recently opened workspace wins: got %q", mount)
	}
	RegisterWorkspaceRoot(ws)
	if mount, _ := ResolveGitMount("", ws+"/desktop/State"); mount != ws {
		t.Fatalf("reopening the outer workspace wins again: got %q", mount)
	}
}

func TestResolveGitMountFollowsSymlinkedRoot(t *testing.T) {
	resetWorkspaceRoots(t)
	real := t.TempDir()
	real, _ = filepath.EvalSymlinks(real)
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skip(err)
	}
	if mount, ok := ResolveGitMount(link, filepath.Join(real, "sub")); !ok || mount != real {
		t.Fatalf("got %q %v, want %q", mount, ok, real)
	}
	RegisterWorkspaceRoot(link)
	if mount, ok := ResolveGitMount("", filepath.Join(real, "sub")); !ok || mount != real {
		t.Fatalf("registered alias: got %q %v, want %q", mount, ok, real)
	}
}

func TestRunGitSubdirectoryRunsInMountedGuestFolder(t *testing.T) {
	resetWorkspaceRoots(t)
	ws := "/Users/test/velo"
	g := installMockGuest(t, func(fc *vmexec.FrameConn, init vmexec.ExecInit, _ <-chan uint32) {
		_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte(vmexec.HostToGuestPath(ws, ws)+"\n"))
		guestExit(fc, 0)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res := RunGitWithOptions(ctx, GitRunOptions{Root: ws, Dir: ws + "/desktop/State"}, "rev-parse", "--show-toplevel")
	if res.Err != nil {
		t.Fatalf("unexpected error: %v", res.Err)
	}
	init := <-g.init
	want := vmexec.HostToGuestPath(ws, ws) + "/desktop/State"
	if init.Cwd != want {
		t.Fatalf("guest cwd %q, want %q", init.Cwd, want)
	}
	if string(res.Output) != ws+"\n" {
		t.Fatalf("output %q", res.Output)
	}
}

func TestRunGitOutsideWorkspaceFailsFastInSandbox(t *testing.T) {
	resetWorkspaceRoots(t)
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "test")
	dialed := false
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		dialed = true
		return nil, errors.New("must not dial")
	})
	defer bridge.SetVsockConnDialer(nil)

	start := time.Now()
	res := RunGitWithOptions(context.Background(), GitRunOptions{Root: "/Users/test/velo", Dir: "/Users/test"}, "config", "--global", "--list")
	if !errors.Is(res.Err, ErrOutsideWorkspace) || res.Flags&GitResultOutside == 0 {
		t.Fatalf("got %+v", res)
	}
	if dialed {
		t.Fatal("a folder outside the shared workspace must not reach the VM")
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatalf("took %v", time.Since(start))
	}
}

func waitForStalledDials(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for vmexec.StalledDials() > 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRunGitFailsFastWhenVMDoesNotAnswer(t *testing.T) {
	resetWorkspaceRoots(t)
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "test")
	release := make(chan struct{})
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		select {
		case <-release:
		case <-time.After(3 * time.Second):
		}
		return nil, bridge.ErrVMNotRunning
	})
	defer func() {
		close(release)
		waitForStalledDials(t)
		bridge.SetVsockConnDialer(nil)
	}()

	start := time.Now()
	res := RunGitWithOptions(context.Background(), GitRunOptions{Root: "/Users/test/velo"}, "status")
	elapsed := time.Since(start)
	if res.Flags&GitResultUnavailable == 0 || res.ExitCode != -1 {
		t.Fatalf("expected unavailable result, got %+v", res)
	}
	if elapsed > GitDialTimeout+250*time.Millisecond {
		t.Fatalf("first call took %v", elapsed)
	}

	start = time.Now()
	res = RunGitWithOptions(context.Background(), GitRunOptions{Root: "/Users/test/velo"}, "status")
	if res.Flags&GitResultUnavailable == 0 {
		t.Fatalf("expected unavailable result, got %+v", res)
	}
	if time.Since(start) > 20*time.Millisecond {
		t.Fatalf("calls while a dial is stuck must fail at once, took %v", time.Since(start))
	}
}

func TestRunGitNotRunningFailsFastInSandbox(t *testing.T) {
	resetWorkspaceRoots(t)
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "test")
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return nil, bridge.ErrVMNotRunning
	})
	defer bridge.SetVsockConnDialer(nil)

	start := time.Now()
	res := RunGitWithOptions(context.Background(), GitRunOptions{Root: "/Users/test/velo"}, "status")
	if res.Flags&GitResultUnavailable == 0 || !errors.Is(res.Err, bridge.ErrVMNotRunning) {
		t.Fatalf("got %+v", res)
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatalf("took %v", time.Since(start))
	}
}

func TestRunGitUsesTimeoutDialerWithGitTimeout(t *testing.T) {
	resetWorkspaceRoots(t)
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	guestFile := os.NewFile(uintptr(fds[1]), "guest")
	guestConn, err := net.FileConn(guestFile)
	guestFile.Close()
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		defer guestConn.Close()
		fc := vmexec.NewFrameConn(guestConn)
		if _, _, err := fc.ReadFrame(); err != nil {
			return
		}
		go func() {
			for {
				if _, _, err := fc.ReadFrame(); err != nil {
					return
				}
			}
		}()
		_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("ok\n"))
		guestExit(fc, 0)
	}()

	var gotTimeout time.Duration
	vmexec.SetTimeoutDialer(func(port uint32, timeout time.Duration) (int, error) {
		gotTimeout = timeout
		return fds[0], nil
	})
	defer vmexec.SetTimeoutDialer(nil)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res := RunGitWithOptions(ctx, GitRunOptions{Root: "/Users/test/velo"}, "status")
	if res.Err != nil || string(res.Output) != "ok\n" {
		t.Fatalf("got %+v (%q)", res, res.Output)
	}
	if gotTimeout != GitDialTimeout {
		t.Fatalf("dialer timeout %v, want %v", gotTimeout, GitDialTimeout)
	}
}

func TestRunGitOutputCapStopsTheCommand(t *testing.T) {
	resetWorkspaceRoots(t)
	chunk := bytes.Repeat([]byte("+line of a very large untracked file\n"), 1000)
	g := installMockGuest(t, func(fc *vmexec.FrameConn, init vmexec.ExecInit, signals <-chan uint32) {
		for i := 0; i < 1000; i++ {
			select {
			case sig := <-signals:
				guestExit(fc, 128+sig)
				return
			default:
			}
			if fc.WriteFrame(vmexec.FrameStdout, 0, chunk) != nil {
				return
			}
		}
		guestExit(fc, 1)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	limit := 256 << 10
	res := RunGitWithOptions(ctx, GitRunOptions{Root: "/Users/test/velo", MaxOutput: limit}, "diff", "--no-index", "--", "/dev/null", "tokenizer.json")
	if !res.Truncated || res.Flags&GitResultTruncated == 0 {
		t.Fatalf("expected truncated result, got flags %d err %v", res.Flags, res.Err)
	}
	if len(res.Output) != limit {
		t.Fatalf("kept %d bytes, want %d", len(res.Output), limit)
	}
	if res.Err != nil || res.ExitCode != 0 {
		t.Fatalf("truncation is not a failure: %+v", res.Err)
	}
	select {
	case sig := <-g.signals:
		if sig != uint32(syscall.SIGTERM) {
			t.Fatalf("signal %d", sig)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the guest command was not stopped after the cap")
	}
}

func TestRunGitOnHostOutputCap(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	resetWorkspaceRoots(t)
	bridge.SetVsockConnDialer(nil)
	dir := t.TempDir()
	big := bytes.Repeat([]byte("0123456789abcdef0123456789abcdef\n"), 200000)
	if err := os.WriteFile(filepath.Join(dir, "big.json"), big, 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	limit := 64 << 10
	res := RunGitWithOptions(ctx, GitRunOptions{Root: dir, Dir: dir, MaxOutput: limit}, "diff", "--no-index", "--no-color", "--", "/dev/null", "big.json")
	if !res.Truncated || len(res.Output) != limit {
		t.Fatalf("truncated=%v len=%d err=%v", res.Truncated, len(res.Output), res.Err)
	}
}

func TestCancelGitCallStopsRunningCommand(t *testing.T) {
	resetWorkspaceRoots(t)
	g := installMockGuest(t, func(fc *vmexec.FrameConn, init vmexec.ExecInit, signals <-chan uint32) {
		_ = fc.WriteFrame(vmexec.FrameStdout, 0, []byte("partial"))
		if sig, ok := <-signals; ok {
			guestExit(fc, 128+sig)
		}
	})

	const id = 4242
	ctx, done := BeginGitCall(context.Background(), id)
	defer done()
	resCh := make(chan GitRunResult, 1)
	go func() { resCh <- RunGitWithOptions(ctx, GitRunOptions{Root: "/Users/test/velo"}, "log", "--follow", "--", "a.go") }()

	<-g.init
	if RunningGitCalls() != 1 {
		t.Fatalf("running calls %d", RunningGitCalls())
	}
	start := time.Now()
	CancelGitCall(id)
	select {
	case res := <-resCh:
		if res.Flags&GitResultCancelled == 0 || res.Err == nil {
			t.Fatalf("expected a cancelled result, got %+v", res)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancel did not stop the command")
	}
	if time.Since(start) > time.Second {
		t.Fatalf("cancel took %v", time.Since(start))
	}
	if sig := <-g.signals; sig != uint32(syscall.SIGTERM) {
		t.Fatalf("signal %d", sig)
	}
}

func TestCancelGitCallBeforeStart(t *testing.T) {
	const id = 777
	CancelGitCall(id)
	ctx, done := BeginGitCall(context.Background(), id)
	defer done()
	if ctx.Err() == nil {
		t.Fatal("a call cancelled before it started must start cancelled")
	}
	ctx2, done2 := BeginGitCall(context.Background(), id)
	defer done2()
	if ctx2.Err() != nil {
		t.Fatal("a pending cancel applies once")
	}
}

func TestGitResultEncodingRoundTrip(t *testing.T) {
	res := GitRunResult{Output: []byte("\x00binary\xff\n"), ExitCode: -1, Flags: GitResultTruncated | GitResultUnavailable, Err: errors.New("boom")}
	buf := make([]byte, EncodedGitResultSize(res))
	EncodeGitResult(buf, res)
	got, errText, ok := DecodeGitResult(buf)
	if !ok || errText != "boom" || got.ExitCode != -1 || got.Flags != res.Flags || !got.Truncated || !bytes.Equal(got.Output, res.Output) {
		t.Fatalf("got %+v %q %v", got, errText, ok)
	}
}

func TestRunGitWithoutOpenWorkspaceFailsFastInSandbox(t *testing.T) {
	resetWorkspaceRoots(t)
	t.Setenv("APP_SANDBOX_CONTAINER_ID", "test")
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return nil, errors.New("must not dial")
	})
	defer bridge.SetVsockConnDialer(nil)

	res := RunGitWithOptions(context.Background(), GitRunOptions{Dir: "/Users/test/Projects", Mounted: true}, "clone", "https://example.com/repo.git", "/Users/test/Projects/repo")
	if res.Flags&GitResultOutside == 0 {
		t.Fatalf("got %+v", res)
	}

	RegisterWorkspaceRoot("/Users/test/Projects")
	g := installMockGuest(t, func(fc *vmexec.FrameConn, init vmexec.ExecInit, _ <-chan uint32) { guestExit(fc, 0) })
	res = RunGitWithOptions(context.Background(), GitRunOptions{Dir: "/Users/test/Projects/app", Mounted: true}, "status")
	if res.Err != nil {
		t.Fatalf("inside an opened workspace: %v", res.Err)
	}
	if init := <-g.init; init.Cwd != vmexec.HostToGuestPath("/Users/test/Projects", "/Users/test/Projects/app") {
		t.Fatalf("cwd %q", init.Cwd)
	}
}

func TestGitAuthEnvMapPerHostIsolation(t *testing.T) {
	defer SetGitHostCredentials(nil)
	SetGitHostCredentialsJSON(`[
		{"provider":"github","scheme":"https","host":"github.com","username":"SangTran-127","token":"ghp_secret123"},
		{"provider":"gitlab","scheme":"https","host":"gitlab.lab.sangtran.io.vn","username":"sang","token":"glpat_secret456"}
	]`)
	env := GitAuthEnvMap()
	if env["GIT_CONFIG_COUNT"] != "6" {
		t.Fatalf("expected 6 GIT_CONFIG entries, got %q", env["GIT_CONFIG_COUNT"])
	}
	if env["GIT_CONFIG_KEY_0"] != "http.https://github.com/.extraheader" {
		t.Fatalf("unexpected key 0: %q", env["GIT_CONFIG_KEY_0"])
	}
	if env["GIT_CONFIG_KEY_3"] != "http.https://gitlab.lab.sangtran.io.vn/.extraheader" {
		t.Fatalf("unexpected key 3: %q", env["GIT_CONFIG_KEY_3"])
	}
	if env["GIT_CONFIG_VALUE_1"] != "git@github.com:" {
		t.Fatalf("unexpected value 1: %q", env["GIT_CONFIG_VALUE_1"])
	}

	hostEnv := GitHostAuthEnvMap()
	if hostEnv["GIT_CONFIG_COUNT"] != "2" {
		t.Fatalf("expected 2 host GIT_CONFIG entries without SSH insteadOf, got %q", hostEnv["GIT_CONFIG_COUNT"])
	}
	if hostEnv["GIT_CONFIG_KEY_0"] != "http.https://github.com/.extraheader" ||
		hostEnv["GIT_CONFIG_KEY_1"] != "http.https://gitlab.lab.sangtran.io.vn/.extraheader" {
		t.Fatalf("unexpected host auth env: %+v", hostEnv)
	}
}

func TestRunGitHostModeBypassesVsockAndPreservesCredentialHelper(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	resetWorkspaceRoots(t)
	prevMode := bridge.ExecutionMode()
	bridge.SetExecutionMode("host")
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })

	t.Setenv("APP_SANDBOX_CONTAINER_ID", "test")
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		t.Fatal("vsock dialer must never be called when execution mode is host")
		return nil, errors.New("unexpected vsock dial")
	})
	defer bridge.SetVsockConnDialer(nil)

	RegisterWorkspaceRoot("/Users/test/other-workspace")
	repo := t.TempDir()
	res := RunGitWithOptions(context.Background(), GitRunOptions{Root: "/Users/test/other-workspace", Dir: repo}, "init", "-q")
	if res.Err != nil || res.ExitCode != 0 {
		t.Fatalf("host mode git init failed: %+v (%s)", res, string(res.Output))
	}

	cfgRes := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "config", "credential.helper", "osxkeychain")
	if cfgRes.Err != nil || cfgRes.ExitCode != 0 {
		t.Fatalf("git config failed: %+v", cfgRes)
	}

	getRes := RunGitWithOptions(context.Background(), GitRunOptions{Dir: repo}, "config", "--get-all", "credential.helper")
	if getRes.Err != nil || getRes.ExitCode != 0 {
		t.Fatalf("git config --get-all failed: %+v", getRes)
	}
	gotHelpers := strings.TrimSpace(string(getRes.Output))
	if !strings.Contains(gotHelpers, "osxkeychain") || strings.HasSuffix(gotHelpers, "\n") {
		t.Fatalf("expected credential.helper osxkeychain to remain intact, got %q", gotHelpers)
	}

	envList := buildHostGitEnv(nil, false)
	var pathVal string
	for _, kv := range envList {
		if strings.HasPrefix(kv, "PATH=") {
			pathVal = strings.TrimPrefix(kv, "PATH=")
		}
		if strings.HasPrefix(kv, "GIT_CONFIG_NOSYSTEM=") {
			t.Fatalf("host git env must not set GIT_CONFIG_NOSYSTEM, got %q", kv)
		}
	}
	if !strings.Contains(pathVal, "/opt/homebrew/bin") || !strings.Contains(pathVal, "/usr/local/bin") {
		t.Fatalf("expected enriched PATH in host git env, got %q", pathVal)
	}
}

func TestHostGitEnvDropsInheritedEditorOverrides(t *testing.T) {
	t.Setenv("GIT_EDITOR", "vim")
	t.Setenv("GIT_SEQUENCE_EDITOR", "vim")
	for _, kv := range buildHostGitEnv(nil, false) {
		if strings.HasPrefix(kv, "GIT_EDITOR=") || strings.HasPrefix(kv, "GIT_SEQUENCE_EDITOR=") {
			t.Fatalf("host git env must leave the editor to -c core.editor and -c sequence.editor, got %q", kv)
		}
	}
}
