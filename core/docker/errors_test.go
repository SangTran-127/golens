package docker

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeStubExec(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\nif [ \"$1\" = \"__warmup__\" ]; then exit 0; fi\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	_, _, _ = runCLI(10*time.Second, "", "", p, "__warmup__")
	return p
}

func prependPATH(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestLookPathAndEnvEdges(t *testing.T) {
	if got := LookPath(""); got != "" {
		t.Fatalf("LookPath(\"\") = %q, want empty", got)
	}
	if got := LookPath("golens-nonexistent-binary-xyz-999"); got != "" {
		t.Fatalf("LookPath(missing) = %q, want empty", got)
	}
	dir := t.TempDir()
	if got := LookPath(dir + "/"); got != "" {
		t.Fatalf("LookPath(dir) = %q, want empty", got)
	}
	nonExec := filepath.Join(dir, "plain")
	if err := os.WriteFile(nonExec, []byte("#!/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := LookPath(nonExec); got != "" {
		t.Fatalf("LookPath(non-exec) = %q, want empty", got)
	}
	execFile := writeStubExec(t, dir, "mycli", "exit 0\n")
	if got := LookPath(execFile); got != execFile {
		t.Fatalf("LookPath(%q) = %q", execFile, got)
	}

	dirA := t.TempDir()
	dirB := t.TempDir()
	if err := os.WriteFile(filepath.Join(dirA, "shadowed"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	wantB := writeStubExec(t, dirB, "shadowed", "exit 0\n")
	t.Setenv("PATH", dirA+string(os.PathListSeparator)+dirB)
	if got := LookPath("shadowed"); got != wantB {
		t.Fatalf("LookPath(shadowed) = %q, want %q", got, wantB)
	}

	origPath, hadPath := os.LookupEnv("PATH")
	_ = os.Unsetenv("PATH")
	t.Cleanup(func() {
		if hadPath {
			_ = os.Setenv("PATH", origPath)
		} else {
			_ = os.Unsetenv("PATH")
		}
	})
	env := Env()
	foundPath := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=/opt/homebrew/bin") {
			foundPath = true
		}
	}
	if !foundPath {
		t.Fatalf("Env() without PATH did not append searchDirs: %v", env)
	}
}

func TestRunCLIAndBuildSummaryHookErrors(t *testing.T) {
	dir := t.TempDir()
	okBin := writeStubExec(t, dir, "echo-stdin", "cat\n")
	out, stderr, err := runCLI(10*time.Second, dir, "hello-in", okBin)
	if err != nil || out != "hello-in" || stderr != "" {
		t.Fatalf("runCLI success = (%q, %q, %v)", out, stderr, err)
	}

	out, _, err = runCLI(10*time.Second, filepath.Join(dir, "missing-subdir"), "ok", okBin)
	if err != nil || out != "ok" {
		t.Fatalf("runCLI missing dir = (%q, %v)", out, err)
	}

	if _, _, err := runCLI(time.Second, "", "", filepath.Join(dir, "no-such-bin")); err == nil {
		t.Fatal("expected error for missing binary")
	}

	failBin := writeStubExec(t, dir, "fail-bin", "echo boom >&2\nexit 2\n")
	if _, stderr, err := runCLI(10*time.Second, "", "", failBin); err == nil || !strings.Contains(stderr, "boom") {
		t.Fatalf("runCLI fail = (%q, %v)", stderr, err)
	}

	if _, stderr, err := runCLI(100*time.Millisecond, "", "", "/bin/sh", "-c", "exec /bin/sleep 5"); err == nil || !strings.Contains(err.Error(), "timed out after") || !strings.Contains(stderr, "timed out after") {
		t.Fatalf("runCLI timeout empty stderr = (%q, %v)", stderr, err)
	}

	if _, stderr, err := runCLI(250*time.Millisecond, "", "", "/bin/sh", "-c", "echo partial-err >&2; exec /bin/sleep 5"); err == nil || !strings.Contains(stderr, "partial-err") {
		t.Fatalf("runCLI timeout partial stderr = (%q, %v)", stderr, err)
	}

	if hook := BuildSummaryHook("docker", []string{"docker", "run", "alpine"}); hook != nil {
		t.Fatal("expected nil hook for docker run")
	}
	if hook := BuildSummaryHook("docker", []string{"git", "build", "-t", "x"}); hook != nil {
		t.Fatal("expected nil hook for non-docker binary")
	}
	if hook := BuildSummaryHook("docker", []string{"docker", "build", "-t"}); hook != nil {
		t.Fatal("expected nil hook for trailing -t")
	}

	stubOK := writeStubExec(t, dir, "docker", "echo 1234567\n")
	hookOK := BuildSummaryHook(stubOK, []string{"docker", "buildx", "build", "--tag=app:1"})
	if hookOK == nil {
		t.Fatal("expected non-nil hook for buildx build")
	}
	if lines := hookOK(); len(lines) != 1 || !strings.Contains(lines[0], "Built app:1") || !strings.Contains(lines[0], "1.2 MB") {
		t.Fatalf("hookOK lines = %v", lines)
	}

	stubFail := writeStubExec(t, dir, "docker-fail", "echo not-a-size\nexit 1\n")
	hookFail := BuildSummaryHook(stubFail, []string{"docker", "image", "build", "-t", "app:2"})
	if lines := hookFail(); len(lines) != 1 || !strings.Contains(lines[0], "Built app:2 in") {
		t.Fatalf("hookFail lines = %v", lines)
	}

	for _, tc := range []struct {
		n    int64
		want string
	}{
		{500, "500 B"},
		{1500, "1.5 kB"},
		{1_500_000_000_000, "1.5 TB"},
		{1_500_000_000_000_000, "1.5 PB"},
	} {
		if got := humanSize(tc.n); got != tc.want {
			t.Errorf("humanSize(%d) = %q, want %q", tc.n, got, tc.want)
		}
	}
}

func TestValidateComposeWithStubCLIAndErrors(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing-compose.yaml")
	res := ValidateCompose(missing)
	if res.OK || len(res.Diagnostics) != 1 || !strings.Contains(res.Diagnostics[0].Message, "Couldn’t read") {
		t.Fatalf("missing compose result = %+v", res)
	}
	rawJSON := ValidateComposeJSON(missing)
	var decoded ComposeResult
	if err := json.Unmarshal([]byte(rawJSON), &decoded); err != nil || decoded.OK {
		t.Fatalf("ValidateComposeJSON = %s, err=%v", rawJSON, err)
	}

	composePath := filepath.Join(dir, "compose.yaml")
	if err := os.WriteFile(composePath, []byte("services:\n  web:\n    image: alpine\n\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	stubDir := t.TempDir()
	prependPATH(t, stubDir)

	writeStubExec(t, stubDir, "docker", "exit 0\n")
	if res := ValidateCompose(composePath); !res.OK || len(res.Diagnostics) != 0 {
		t.Fatalf("ValidateCompose ok = %+v", res)
	}

	writeStubExec(t, stubDir, "docker", "exit 1\n")
	if res := ValidateCompose(composePath); res.OK || res.Output == "" || len(res.Diagnostics) != 1 {
		t.Fatalf("ValidateCompose empty stderr fail = %+v", res)
	}

	writeStubExec(t, stubDir, "docker", "echo 'yaml: line 99, column 2: bad map\ncompose.yaml:1:999: bad token' >&2\nexit 1\n")
	res = ValidateCompose(composePath)
	if res.OK || len(res.Diagnostics) != 2 {
		t.Fatalf("ValidateCompose parsed diags = %+v", res)
	}

	diags := parseComposeErrors("line 1, column 3: bad", "compose.yaml", "  \xF0\x90\x8D\x88: x")
	if len(diags) != 1 || diags[0].Col <= 0 {
		t.Fatalf("UTF-8 compose diag = %+v", diags)
	}
}

func TestHadolintFindingsAndInspectErrors(t *testing.T) {
	stubDir := t.TempDir()
	prependPATH(t, stubDir)

	content := "FROM golang:1.24-alpine\nRUN echo \"\U00010348\"\n"
	df := parseDockerfile(content)

	if got := hadolintFindings(df, t.TempDir(), "   "); got != nil {
		t.Fatalf("blank content should yield nil findings, got %+v", got)
	}

	writeStubExec(t, stubDir, "hadolint", "exit 1\n")
	if got := hadolintFindings(df, t.TempDir(), content); got != nil {
		t.Fatalf("failing hadolint should return nil, got %+v", got)
	}

	writeStubExec(t, stubDir, "hadolint", "echo '{not json'\n")
	if got := hadolintFindings(df, t.TempDir(), content); got != nil {
		t.Fatalf("invalid hadolint JSON should return nil, got %+v", got)
	}

	writeStubExec(t, stubDir, "hadolint", `cat <<'EOF'
[
  {"line":1,"column":1,"level":"error","code":"DL3000","message":"err"},
  {"line":2,"column":12,"level":"warning","code":"DL3001","message":"warn"},
  {"line":99,"column":1,"level":"info","code":"DL3002","message":"info"}
]
EOF
`)
	got := Inspect("Dockerfile", content)
	var hl []Finding
	for _, f := range got {
		if f.Source == sourceHadolint {
			hl = append(hl, f)
		}
	}
	if len(hl) != 3 || hl[0].Severity != sevError || hl[1].Severity != sevWarning || hl[2].Severity != sevInfo || hl[2].Line != len(df.lines)-1 {
		t.Fatalf("hadolint findings = %+v", hl)
	}

	if invalid := parseDockerfile("FROM\nRUN \"unclosed\n\t \n"); len(invalid.insts) != 2 {
		t.Fatalf("malformed dockerfile insts = %+v", invalid.insts)
	}
	if col := utf16Col("a\xffb", 10); col != 3 {
		t.Fatalf("utf16Col invalid UTF-8 clamped = %d, want 3", col)
	}
}

func TestGenerateErrorAndEdgeBranches(t *testing.T) {
	if out := GenerateJSON(t.TempDir(), `{bad`); !strings.Contains(out, "invalid options") {
		t.Fatalf("GenerateJSON bad json = %s", out)
	}
	if res := Generate("relative/dir", GenerateOptions{}); !strings.Contains(res.Error, "absolute path") {
		t.Fatalf("relative path error = %+v", res)
	}
	noMod := t.TempDir()
	if res := Generate(noMod, GenerateOptions{}); !strings.Contains(res.Error, "No go.mod") {
		t.Fatalf("no go.mod error = %+v", res)
	}

	libDir := writeTree(t, map[string]string{
		"go.mod": "module example.com/lib\n",
		"lib.go": "package lib\n",
	})
	if res := Generate(libDir, GenerateOptions{}); !strings.Contains(res.Error, "no main package") {
		t.Fatalf("no main package error = %+v", res)
	}

	cgoDir := writeTree(t, map[string]string{
		"go.mod":  "module example.com/app\nrequire example.com/dep v1.0.0\n",
		"main.go": "package main\nimport \"C\"\nfunc main() {}\n",
	})
	res := Generate(cgoDir, GenerateOptions{})
	if res.Error != "" || !res.UsesCgo || len(res.Warnings) < 2 || !strings.Contains(res.Dockerfile, "golang:1-bookworm") {
		t.Fatalf("cgo + missing directive/go.sum result = %+v", res)
	}

	if badPkg := Generate(cgoDir, GenerateOptions{Package: "./nope"}); !strings.Contains(badPkg.Error, "isn’t a main package") {
		t.Fatalf("unknown package error = %+v", badPkg)
	}
	if badBase := Generate(cgoDir, GenerateOptions{Base: "ubuntu"}); !strings.Contains(badBase.Error, "Unknown runtime image") {
		t.Fatalf("unknown base error = %+v", badBase)
	}
	if scratchCgo := Generate(cgoDir, GenerateOptions{Base: BaseScratch}); scratchCgo.Error != "" || !strings.Contains(strings.Join(scratchCgo.Warnings, "\n"), "scratch") {
		t.Fatalf("cgo on scratch warning = %+v", scratchCgo)
	}
	negPort := -1
	if badPort := Generate(cgoDir, GenerateOptions{Port: &negPort}); !strings.Contains(badPort.Error, "outside") {
		t.Fatalf("negative port error = %+v", badPort)
	}
	highPort := 70000
	if badPort := Generate(cgoDir, GenerateOptions{Port: &highPort}); !strings.Contains(badPort.Error, "outside") {
		t.Fatalf("high port error = %+v", badPort)
	}

	if got := binaryName("---", filepath.Join(t.TempDir(), "___")); got != "app" {
		t.Fatalf("binaryName fallback = %q, want app", got)
	}
	p := 9001
	if got := Generate(cgoDir, GenerateOptions{Base: BaseDistrolessBase, Port: &p}); got.Error != "" || got.Port != 9001 {
		t.Fatalf("explicit valid port = %+v", got)
	}
	if res2 := Generate(writeTree(t, map[string]string{
		"go.mod":     "module example.com/p\n",
		"a/main.go":  "package main\nfunc main() {}\n",
		"b/serve.go": "package b\nimport \"net/http\"\nfunc s() { http.ListenAndServe(\":7070\", nil) }\n",
	}), GenerateOptions{}); res2.Port != 7070 {
		t.Fatalf("fallback module port = %d, want 7070", res2.Port)
	}
}

func TestScanGoFilesAndPortsEdgeBranches(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.mod":           "module example.com/ports\n",
		".hidden/skip.go":  "package main\nfunc main() {}\n",
		"_private/skip.go": "package main\nfunc main() {}\n",
		"vendor/v/main.go": "package main\nfunc main() {}\n",
		"broken.go":        "package broken\nfunc ((( {}\n",
		"_under.go":        "package main\nfunc main() {}\n",
		"cmd/app/main.go": `package main
import (
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"strconv"
)
var cycleA = cycleB
var cycleB = cycleA
func helper() func() *http.Server { return nil }
func two() (string, string) { return "", "" }
func main() {
	x, y := two()
	_, _ = x, y
	_ = cycleA
	_ = os.Getenv("PORT")
	_ = fmt.Sprintf("%s:%d", "127.0.0.1", 8081)
	p := strconv.Itoa(9090)
	_ = http.ListenAndServe(fmt.Sprintf(":%s", p), nil)
	_, _ = tls.Listen("tcp", ":8443", nil)
	_ = (&http.Server{Addr: ":" + strconv.Itoa(7777)})
	_ = helper()()
	_ = &http.Server{nil}
}
`,
	})
	if os.Geteuid() != 0 {
		lockedDir := filepath.Join(root, "lockeddir")
		if err := os.MkdirAll(lockedDir, 0o755); err != nil {
			t.Fatal(err)
		}
		lockedFile := filepath.Join(root, "locked.go")
		if err := os.WriteFile(lockedFile, []byte("package main\n// Listen\n"), 0o000); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(lockedDir, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = os.Chmod(lockedDir, 0o755)
			_ = os.Chmod(lockedFile, 0o644)
		})
	}

	scan := scanGoFiles(root)
	if !scan.mains["cmd/app"] || scan.mains[".hidden"] || scan.mains["_private"] || scan.mains["vendor/v"] {
		t.Fatalf("scan mains = %+v", scan.mains)
	}
	ports := detectPorts(root)
	gotPorts := map[int]bool{}
	for _, p := range ports {
		gotPorts[p.Port] = true
	}
	for _, want := range []int{9090, 8443, 7777} {
		if !gotPorts[want] {
			t.Fatalf("missing detected port %d in %+v", want, ports)
		}
	}
	if gotPorts[8081] {
		t.Fatalf("2-verb fmt.Sprintf should not resolve as port: %+v", ports)
	}

	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "p.go", `package p
func f() {
	_ = getenv()()
}
`, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	_ = portsInFile(f)
	if _, ok := portOf(""); ok {
		t.Fatal("empty portOf should be false")
	}
	if _, ok := portOf("70000"); ok {
		t.Fatal("out-of-range portOf should be false")
	}
	if _, ok := portOf("notaport"); ok {
		t.Fatal("non-numeric portOf should be false")
	}
	if s := eval(nil, nil, 0); s != "" {
		t.Fatalf("eval(nil) = %q", s)
	}
}
