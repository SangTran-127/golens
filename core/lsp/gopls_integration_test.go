package lsp

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func alive(pid int) bool {
	return pid > 0 && syscall.Kill(pid, 0) == nil
}

func waitFor(t *testing.T, what string, d time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func makeModule(t *testing.T, name, src string) string {
	dir := filepath.Join(t.TempDir(), name+" dir")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module "+name+"\n\ngo 1.21\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "main.go"), []byte(src), 0o644)
	return dir
}

func TestRealGoplsLifecycle(t *testing.T) {
	setupPATH()
	if _, err := exec.LookPath("gopls"); err != nil || testing.Short() {
		t.Skip("gopls not installed")
	}
	freshStore(t)
	t.Cleanup(Shutdown)
	src := "package main\n\nimport \"strings\"\n\nfunc main() {\n\tvar b strings.Builder\n\tb.Wr\n}\n"
	a := makeModule(t, "alpha", src)
	b := makeModule(t, "beta", "package main\n\nfunc main() {}\n")

	OpenWorkspace(a)
	waitFor(t, "gopls for alpha", 20*time.Second, func() bool { return ServerPID() != 0 })
	shared := ServerPID()
	for i, root := range []string{b, a, b, a, b} {
		OpenWorkspace(root)
		if p := ServerPID(); p != shared {
			t.Fatalf("switch %d: gopls changed from %d to %d", i, shared, p)
		}
		if GetActiveDir() != root {
			t.Fatalf("switch %d: active dir %s", i, GetActiveDir())
		}
	}
	if roots := OpenWorkspaceRoots(); len(roots) != 2 {
		t.Fatalf("open roots %v, want alpha and beta", roots)
	}
	if RootForPath(filepath.Join(a, "main.go")) != a || RootForPath(filepath.Join(b, "main.go")) != b {
		t.Fatal("files are not routed to their own project root")
	}

	CloseWorkspaceFolder(b)
	if p := ServerPID(); p != shared {
		t.Fatalf("closing beta restarted gopls: %d -> %d", shared, p)
	}
	if GetActiveDir() != a {
		t.Fatalf("active dir after closing beta: %s", GetActiveDir())
	}
	if roots := OpenWorkspaceRoots(); len(roots) != 1 || roots[0] != a {
		t.Fatalf("open roots after closing beta: %v", roots)
	}
	path := filepath.Join(a, "main.go")
	OpenDocument(path, []byte(src))
	caret := strings.Index(src, "b.Wr") + 4
	var res completionStart
	waitFor(t, "completion before crash", 20*time.Second, func() bool {
		_ = json.Unmarshal([]byte(StartCompletion(path, caret, 1, "")), &res)
		return res.OK && res.Count > 0
	})

	crashed := ServerPID()
	if crashed <= 0 {
		t.Fatal("no gopls to crash")
	}
	_ = syscall.Kill(crashed, syscall.SIGKILL)
	start := time.Now()
	waitFor(t, "restart after crash", 10*time.Second, func() bool { p := ServerPID(); return p != 0 && p != crashed })
	t.Logf("gopls restarted in %v", time.Since(start))
	if time.Since(start) > 3*time.Second {
		t.Fatalf("restart took %v (budget 3s)", time.Since(start))
	}
	waitFor(t, "completion after restart (didOpen replayed)", 20*time.Second, func() bool {
		_ = json.Unmarshal([]byte(StartCompletion(path, caret, 1, "")), &res)
		return res.OK && res.Count > 0
	})

	last := ServerPID()
	Shutdown()
	waitFor(t, "gopls exit on shutdown", 5*time.Second, func() bool { return !alive(last) })
	if ServerPID() != 0 {
		t.Fatal("server still registered after shutdown")
	}
}
