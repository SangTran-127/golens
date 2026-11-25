package runner

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
	"golens/core/testutil"
)

func TestRewriteMainFuncPreservesExactLineNumbers(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "main.go")
	original := strings.Join([]string{
		"package main",
		"",
		"import \"fmt\"",
		"",
		"func helper() {",
		"\tfmt.Println(\"helper\")",
		"}",
		"",
		"func main() {",
		"\thelper()",
		"}",
		"",
	}, "\n")
	if err := os.WriteFile(mainPath, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	found, err := findMainFile(dir)
	if err != nil {
		t.Fatalf("findMainFile failed: %v", err)
	}
	if found != mainPath {
		t.Fatalf("findMainFile = %q, want %q", found, mainPath)
	}

	rewritten, err := rewriteMainFunc(mainPath)
	if err != nil {
		t.Fatalf("rewriteMainFunc failed: %v", err)
	}

	origLines := strings.Split(original, "\n")
	newLines := strings.Split(string(rewritten), "\n")
	if len(origLines) != len(newLines) {
		t.Fatalf("line count changed: got %d, want %d", len(newLines), len(origLines))
	}
	for i := range origLines {
		if i == 8 {
			if newLines[i] != "func _golensOriginalMain() {" {
				t.Fatalf("line %d = %q, want %q", i+1, newLines[i], "func _golensOriginalMain() {")
			}
			continue
		}
		if newLines[i] != origLines[i] {
			t.Fatalf("line %d modified: got %q, want %q", i+1, newLines[i], origLines[i])
		}
	}
}

func TestProfileWithConfigZeroEditLiveApplication(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	tmpWorkspace := t.TempDir()
	goModContent := "module example.com/profiledemo\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpWorkspace, "go.mod"), []byte(goModContent), 0o644); err != nil {
		t.Fatal(err)
	}

	mainSource := strings.Join([]string{
		"package main",                              // line 1
		"",                                          // line 2
		"import (",                                  // line 3
		"\t\"fmt\"",                                 // line 4
		"\t\"math\"",                                // line 5
		")",                                         // line 6
		"",                                          // line 7
		"var sink [][]byte",                         // line 8
		"var cpuSink float64",                       // line 9
		"",                                          // line 10
		"//go:noinline",                             // line 11
		"func heavyCPUWork() {",                     // line 12
		"\tacc := 0.0",                              // line 13
		"\tfor i := 1; i < 8_000_000; i++ {",        // line 14
		"\t\tacc += math.Sqrt(float64(i)) * 1.0001", // line 15
		"\t}",                                       // line 16
		"\tcpuSink = acc",                           // line 17
		"}",                                         // line 18
		"",                                          // line 19
		"//go:noinline",                             // line 20
		"func allocateHeapBlocks() {",               // line 21
		"\tfor i := 0; i < 64; i++ {",               // line 22
		"\t\tbuf := make([]byte, 64*1024)",          // line 23
		"\t\tbuf[0] = byte(i)",                      // line 24
		"\t\tsink = append(sink, buf)",              // line 25
		"\t}",                                       // line 26
		"}",                                         // line 27
		"",                                          // line 28
		"func main() {",                             // line 29
		"\theavyCPUWork()",                          // line 30
		"\tallocateHeapBlocks()",                    // line 31
		"\tfmt.Println(\"hello from profiled app\")", // line 32
		"}",                                         // line 33
		"",
	}, "\n")

	mainFilePath := filepath.Join(tmpWorkspace, "main.go")
	if err := os.WriteFile(mainFilePath, []byte(mainSource), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := exec.LookPath("git"); err == nil {
		runGit := func(args ...string) {
			cmd := exec.Command("git", args...)
			cmd.Dir = tmpWorkspace
			_ = cmd.Run()
		}
		runGit("init")
		runGit("config", "user.email", "test@example.com")
		runGit("config", "user.name", "Test")
		runGit("add", ".")
		runGit("commit", "-m", "initial")
	}

	var mu sync.Mutex
	var logs []string
	var profilePayloads []string

	t.Cleanup(bridge.SetLog(func(msg string) {
		mu.Lock()
		logs = append(logs, msg)
		mu.Unlock()
	}))
	t.Cleanup(bridge.SetStderr(func(msg string) {
		mu.Lock()
		logs = append(logs, "STDERR: "+msg)
		mu.Unlock()
	}))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "testProfile" {
			mu.Lock()
			profilePayloads = append(profilePayloads, payload)
			mu.Unlock()
		}
	}))
	routeRunOutputToLogs(t)
	t.Cleanup(StopRun)

	run := ProfileWithConfig(tmpWorkspace, "")
	if run == nil {
		t.Fatal("ProfileWithConfig returned nil")
	}

	select {
	case <-run.done:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for profiled application to exit")
	}

	diskBytes, err := os.ReadFile(mainFilePath)
	if err != nil {
		t.Fatalf("failed to read main.go after run: %v", err)
	}
	if !bytes.Equal(diskBytes, []byte(mainSource)) {
		t.Fatalf("main.go on disk was modified!\ngot:\n%s\nwant:\n%s", string(diskBytes), mainSource)
	}

	hookOnDisk := filepath.Join(tmpWorkspace, "_golens_profile_entry.go")
	if _, err := os.Stat(hookOnDisk); !os.IsNotExist(err) {
		t.Fatalf("_golens_profile_entry.go exists on disk in workspace: err=%v", err)
	}
	hookOnDisk2 := filepath.Join(tmpWorkspace, "golens_profile_entry.go")
	if _, err := os.Stat(hookOnDisk2); !os.IsNotExist(err) {
		t.Fatalf("golens_profile_entry.go exists on disk in workspace: err=%v", err)
	}

	if _, err := exec.LookPath("git"); err == nil {
		gitCmd := exec.Command("git", "status", "--porcelain")
		gitCmd.Dir = tmpWorkspace
		if out, err := gitCmd.Output(); err == nil {
			if trimmed := strings.TrimSpace(string(out)); trimmed != "" {
				t.Fatalf("git status not clean after profile run:\n%s", trimmed)
			}
		}
	}

	mu.Lock()
	gotPayloads := append([]string(nil), profilePayloads...)
	gotLogs := append([]string(nil), logs...)
	mu.Unlock()

	if len(gotPayloads) != 1 {
		t.Fatalf("expected 1 testProfile status event, got %d (logs: %v)", len(gotPayloads), gotLogs)
	}

	var decoded struct {
		CPU []testutil.ProfileEntry `json:"cpu"`
		Mem []testutil.ProfileEntry `json:"mem"`
	}
	if err := json.Unmarshal([]byte(gotPayloads[0]), &decoded); err != nil {
		t.Fatalf("failed to unmarshal testProfile payload: %v", err)
	}

	if len(decoded.CPU) == 0 && len(decoded.Mem) == 0 {
		t.Fatalf("expected non-empty CPU or Mem profile entries, got empty payload: %s (logs: %v)", gotPayloads[0], gotLogs)
	}

	foundGreeting := false
	foundSummary := false
	for _, line := range gotLogs {
		if strings.Contains(line, "hello from profiled app") {
			foundGreeting = true
		}
		if strings.Contains(line, "Application profile captured") {
			foundSummary = true
		}
	}
	if !foundGreeting {
		t.Fatalf("expected greeting output in logs, got %v", gotLogs)
	}
	if !foundSummary {
		t.Fatalf("expected profile summary in logs, got %v", gotLogs)
	}

	allEntries := append(append([]testutil.ProfileEntry{}, decoded.CPU...), decoded.Mem...)
	foundMainGoEntry := false
	foundAccurateLine := false
	for _, e := range allEntries {
		if strings.Contains(e.File, "_golens_profile_entry.go") {
			t.Fatalf("synthetic _golens_profile_entry.go leaked into profile entries: %+v", e)
		}
		if strings.Contains(e.Function, "_golensOriginalMain") {
			t.Fatalf("synthetic _golensOriginalMain leaked into profile entries: %+v", e)
		}
		if e.File == mainFilePath {
			foundMainGoEntry = true
			switch e.Function {
			case "main.heavyCPUWork":
				if e.Line != 12 {
					t.Fatalf("main.heavyCPUWork line = %d, want 12", e.Line)
				}
				foundAccurateLine = true
			case "main.allocateHeapBlocks":
				if e.Line != 21 {
					t.Fatalf("main.allocateHeapBlocks line = %d, want 21", e.Line)
				}
				foundAccurateLine = true
			case "main.main":
				if e.Line != 29 {
					t.Fatalf("main.main line = %d, want 29", e.Line)
				}
				foundAccurateLine = true
			}
		}
	}
	if !foundMainGoEntry {
		t.Fatalf("expected at least one ProfileEntry pointing to %q, got entries: %+v", mainFilePath, allEntries)
	}
	if !foundAccurateLine {
		t.Fatalf("expected accurate line number for main.heavyCPUWork (12), main.allocateHeapBlocks (21), or main.main (29), got: %+v", allEntries)
	}
}

func TestProfileWithConfigSubdirectoryAndStopCapturesProfile(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	tmpWorkspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpWorkspace, "go.mod"), []byte("module example.com/subapp\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmdDir := filepath.Join(tmpWorkspace, "cmd", "worker")
	if err := os.MkdirAll(cmdDir, 0o755); err != nil {
		t.Fatal(err)
	}

	appPath := filepath.Join(cmdDir, "app.go")
	appSrc := strings.Join([]string{
		"package main",
		"",
		"import (",
		"\t\"fmt\"",
		"\t\"time\"",
		")",
		"",
		"var globalAllocs [][]byte",
		"",
		"//go:noinline",
		"func allocateBeforeWait() {",
		"\tfor i := 0; i < 32; i++ {",
		"\t\tb := make([]byte, 32*1024)",
		"\t\tb[0] = byte(i)",
		"\t\tglobalAllocs = append(globalAllocs, b)",
		"\t}",
		"}",
		"",
		"func main() {",
		"\tallocateBeforeWait()",
		"\tfmt.Println(\"worker-ready\")",
		"\ttime.Sleep(30 * time.Second)",
		"}",
		"",
	}, "\n")
	if err := os.WriteFile(appPath, []byte(appSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	readyCh := make(chan struct{}, 1)
	var mu sync.Mutex
	var profilePayloads []string

	t.Cleanup(bridge.SetLog(func(msg string) {
		if strings.TrimSpace(msg) == "worker-ready" {
			select {
			case readyCh <- struct{}{}:
			default:
			}
		}
	}))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "testProfile" {
			mu.Lock()
			profilePayloads = append(profilePayloads, payload)
			mu.Unlock()
		}
	}))
	routeRunOutputToLogs(t)
	t.Cleanup(StopRun)

	run := ProfileWithConfig(tmpWorkspace, `{"workingDirectory":"cmd/worker"}`)
	if run == nil {
		t.Fatal("ProfileWithConfig returned nil")
	}

	select {
	case <-readyCh:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for worker-ready")
	}

	StopRun()

	select {
	case <-run.done:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for stopped profile run to finish")
	}

	mu.Lock()
	gotPayloads := append([]string(nil), profilePayloads...)
	mu.Unlock()

	if len(gotPayloads) != 1 {
		t.Fatalf("expected 1 testProfile payload after StopRun, got %d", len(gotPayloads))
	}

	var decoded struct {
		CPU []testutil.ProfileEntry `json:"cpu"`
		Mem []testutil.ProfileEntry `json:"mem"`
	}
	if err := json.Unmarshal([]byte(gotPayloads[0]), &decoded); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if len(decoded.Mem) == 0 {
		t.Fatalf("expected non-empty Mem profile entries after StopRun, got empty")
	}

	foundWorkerAlloc := false
	for _, e := range decoded.Mem {
		if e.File == appPath && e.Function == "main.allocateBeforeWait" && e.Line == 11 {
			foundWorkerAlloc = true
		}
	}
	if !foundWorkerAlloc {
		t.Fatalf("expected main.allocateBeforeWait at %s:11, got %+v", appPath, decoded.Mem)
	}
}

func TestProfileWithConfigOSExitZeroFlushesProfiles(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	tmpWorkspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpWorkspace, "go.mod"), []byte("module example.com/exitprobe\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	mainFilePath := filepath.Join(tmpWorkspace, "main.go")
	mainSrc := `package main
import("fmt";"os";"time")
var sink []byte
func main(){for i:=0;i<500000;i++ {sink=append(sink,byte(i))};time.Sleep(300*time.Millisecond);fmt.Println("exiting normally");os.Exit(0)}
`
	if err := os.WriteFile(mainFilePath, []byte(mainSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var logs []string
	var profilePayloads []string

	t.Cleanup(bridge.SetLog(func(msg string) {
		mu.Lock()
		logs = append(logs, msg)
		mu.Unlock()
	}))
	t.Cleanup(bridge.SetStderr(func(msg string) {
		mu.Lock()
		logs = append(logs, "STDERR: "+msg)
		mu.Unlock()
	}))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "testProfile" {
			mu.Lock()
			profilePayloads = append(profilePayloads, payload)
			mu.Unlock()
		}
	}))
	routeRunOutputToLogs(t)
	t.Cleanup(StopRun)

	run := ProfileWithConfig(tmpWorkspace, "")
	if run == nil {
		t.Fatal("ProfileWithConfig returned nil")
	}

	select {
	case <-run.done:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for profiled application to exit")
	}

	mu.Lock()
	gotPayloads := append([]string(nil), profilePayloads...)
	gotLogs := append([]string(nil), logs...)
	mu.Unlock()

	if len(gotPayloads) != 1 {
		t.Fatalf("expected 1 testProfile status event, got %d (logs: %v)", len(gotPayloads), gotLogs)
	}

	var decoded struct {
		CPU []testutil.ProfileEntry `json:"cpu"`
		Mem []testutil.ProfileEntry `json:"mem"`
	}
	if err := json.Unmarshal([]byte(gotPayloads[0]), &decoded); err != nil {
		t.Fatalf("failed to unmarshal testProfile payload: %v", err)
	}

	if len(decoded.Mem) == 0 {
		t.Fatalf("expected non-empty Mem profile entries when calling os.Exit(0), got CPU=%d Mem=%d (logs: %v)", len(decoded.CPU), len(decoded.Mem), gotLogs)
	}
}

