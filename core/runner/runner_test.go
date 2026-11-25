package runner

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golens/core/bridge"
)

func TestStreamLinesSurvivesHugeLines(t *testing.T) {
	huge := strings.Repeat("x", 200<<10)
	input := "first\r\n" + huge + "\nafter huge\nlast-without-newline"
	var got []string
	streamLines(strings.NewReader(input), func(s string) { got = append(got, s) })
	if len(got) != 4 {
		t.Fatalf("got %d lines: %q", len(got), got)
	}
	if got[0] != "first" || got[2] != "after huge" || got[3] != "last-without-newline" {
		t.Fatalf("lines %q", []string{got[0], got[2], got[3]})
	}
	if len(got[1]) > maxOutputLine+len("…") || !strings.HasSuffix(got[1], "…") {
		t.Fatalf("huge line not truncated: %d bytes", len(got[1]))
	}
}

func TestParseGoTestJSONStream(t *testing.T) {
	stream := strings.Join([]string{
		`{"Action":"start","Package":"x"}`,
		`{"Action":"run","Package":"x","Test":"TestA"}`,
		`{"Action":"output","Package":"x","Test":"TestA","Output":"=== RUN   TestA\n"}`,
		`{"Action":"pass","Package":"x","Test":"TestA","Elapsed":0.01}`,
		`{"Action":"run","Package":"x","Test":"TestB/row_1"}`,
		`{"Action":"output","Package":"x","Test":"TestB/row_1","Output":"    b_test.go:12: got 3, want 4\n"}`,
		`{"Action":"fail","Package":"x","Test":"TestB/row_1","Elapsed":0}`,
		`{"Action":"fail","Package":"x","Test":"TestB","Elapsed":0}`,
		`{"Action":"skip","Package":"x","Test":"TestC"}`,
		`# x [build failed]`,
		`{"Action":"fail","Package":"x","Elapsed":0.2}`,
	}, "\n")
	var results []TestResult
	var lines []string
	a := newAggregator(7, func(r TestResult) { results = append(results, r) })
	parseTestStream(strings.NewReader(stream), a, func(s string) { lines = append(lines, s) })
	var final []string
	for _, r := range results {
		if r.Status != "running" {
			final = append(final, r.Test+"="+r.Status)
		}
	}
	if strings.Join(final, ",") != "TestA=pass,TestB/row_1=fail,TestB=fail,TestC=skip" {
		t.Fatalf("results %v", final)
	}
	// TestB failed only through its subtest, so it isn't counted again.
	if a.passed != 1 || a.failed != 1 || a.skipped != 1 {
		t.Fatalf("counts %d %d %d", a.passed, a.failed, a.skipped)
	}
	for _, r := range results {
		if r.Test == "TestB/row_1" && r.Status == "fail" && (len(r.Output) != 1 || !strings.Contains(r.Output[0], "b_test.go:12")) {
			t.Fatalf("failure output %v", r.Output)
		}
	}
	if len(lines) != 3 || lines[2] != "# x [build failed]" {
		t.Fatalf("console lines %v", lines)
	}
	if got := strings.Join(testArgs("^TestA$", nil), " "); got != "test -json -run ^TestA$ ." {
		t.Fatalf("args %s", got)
	}
}

func TestParentFailingAfterPassingSubtestsCounts(t *testing.T) {
	a := newAggregator(1, func(TestResult) {})
	parseTestStream(strings.NewReader(strings.Join([]string{
		`{"Action":"run","Package":"x","Test":"TestP"}`,
		`{"Action":"run","Package":"x","Test":"TestP/a"}`,
		`{"Action":"pass","Package":"x","Test":"TestP/a"}`,
		`{"Action":"run","Package":"x","Test":"TestP/b"}`,
		`{"Action":"pass","Package":"x","Test":"TestP/b"}`,
		`{"Action":"fail","Package":"x","Test":"TestP"}`,
	}, "\n")), a, func(string) {})
	if a.passed != 2 || a.failed != 1 {
		t.Fatalf("counts %d passed %d failed", a.passed, a.failed)
	}
}

func TestTestRequestPattern(t *testing.T) {
	cases := map[string]TestRequest{
		"":                                      {Dir: "/x"},
		"^TestA$":                               {Test: "TestA"},
		"^TestA$/^a_b$/^c\\.d$":                 {Test: "TestA", Row: "a b/c.d"},
		`^TestMatrix$/^(?:alpha|beta)$/^step1$`: {Test: "TestMatrix", Row: "alpha/step1", PatternOverride: `^TestMatrix$/^(?:alpha|beta)$/^step1$`},
		"^(TestA|TestB)$":                       {Test: "TestC", Failed: []string{"TestA", "TestB"}},
	}
	for want, req := range cases {
		if got := req.Pattern(); got != want {
			t.Fatalf("%+v: got %q want %q", req, got, want)
		}
	}
	if RunTests("{") != 0 || RunTests(`{"test":"TestA"}`) != 0 {
		t.Fatal("invalid request started a run")
	}
}

func TestStopTestsCancelsRun(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\n\ngo 1.22\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "x_test.go"), []byte("package x\n\nimport (\n\t\"testing\"\n\t\"time\"\n)\n\nfunc TestSlow(t *testing.T) { time.Sleep(time.Minute) }\n"), 0o644)
	done := make(chan TestResult, 4)
	started := make(chan struct{}, 4)
	old := TestEvent
	TestEvent = func(s string) {
		var r TestResult
		_ = json.Unmarshal([]byte(s), &r)
		if r.Status == "running" {
			started <- struct{}{}
		}
		if r.Kind == "done" {
			done <- r
		}
	}
	t.Cleanup(func() { TestEvent = old })
	RunTestsJSON(dir, "", nil)
	select {
	case <-started:
	case <-time.After(60 * time.Second):
		t.Fatal("test never started")
	}
	begin := time.Now()
	StopTests()
	select {
	case r := <-done:
		if r.Status != "cancelled" {
			t.Fatalf("cancelled run reported %q", r.Status)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no done event after stop")
	}
	if time.Since(begin) > 5*time.Second {
		t.Fatalf("stop took %v", time.Since(begin))
	}
}

func TestRunTestsJSONRealGo(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\n\ngo 1.22\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "x_test.go"), []byte("package x\n\nimport \"testing\"\n\nfunc TestOK(t *testing.T) {}\n\nfunc TestRows(t *testing.T) {\n\tfor _, n := range []string{\"a b\", \"c\"} {\n\t\tt.Run(n, func(t *testing.T) {\n\t\t\tif n == \"c\" {\n\t\t\t\tt.Fatal(\"boom\")\n\t\t\t}\n\t\t})\n\t}\n}\n"), 0o644)
	var mu sync.Mutex
	var got []TestResult
	done := make(chan TestResult, 1)
	old := TestEvent
	TestEvent = func(s string) {
		var r TestResult
		_ = json.Unmarshal([]byte(s), &r)
		mu.Lock()
		got = append(got, r)
		mu.Unlock()
		if r.Kind == "done" {
			done <- r
		}
	}
	t.Cleanup(func() { TestEvent = old })
	RunTests(`{"dir":"` + dir + `","test":"TestRows","row":"a b"}`)
	r := <-done
	if r.Status != "pass" || r.Passed != 1 || r.Failed != 0 {
		t.Fatalf("single row run %+v", r)
	}
	RunTestsJSON(dir, "", nil)
	r = <-done
	if r.Status != "fail" || r.Failed != 1 || r.Passed != 2 {
		t.Fatalf("full run %+v", r)
	}
	RunTests(`{"dir":"` + dir + `","failed":["TestRows"]}`)
	r = <-done
	if r.Status != "fail" || r.Failed != 1 || r.Passed != 1 {
		t.Fatalf("rerun failed %+v", r)
	}
	RunTests(`{"dir":"` + dir + `","failed":["TestRows","TestRows/c"]}`)
	r = <-done
	if r.Status != "fail" || r.Failed != 1 || r.Passed != 0 {
		t.Fatalf("rerun failed subtest only should skip passing siblings: %+v", r)
	}
}

func TestStopRunStopsTheWholeProcessGroup(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "grandchild.pid")
	// The child waits on a grandchild that also holds the output pipe open.
	run := startProgram(exec.Command("sh", "-c", `sleep 60 & echo $! > "$0"; wait`, pidFile))
	var grandchild int
	for i := 0; i < 100 && grandchild == 0; i++ {
		time.Sleep(20 * time.Millisecond)
		if b, err := os.ReadFile(pidFile); err == nil {
			grandchild, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		}
	}
	if grandchild == 0 {
		t.Fatal("grandchild did not start")
	}
	child := run.cmd.Process.Pid
	StopRun()
	select {
	case <-run.done:
	case <-time.After(5 * time.Second):
		t.Fatal("run did not finish after StopRun")
	}
	// The orphaned grandchild is reaped by launchd, not us, so it may linger briefly after the signal.
	for _, pid := range []int{child, grandchild} {
		alive := true
		for i := 0; i < 100 && alive; i++ {
			alive = syscall.Kill(pid, 0) == nil
			if alive {
				time.Sleep(20 * time.Millisecond)
			}
		}
		if alive {
			t.Errorf("process %d still alive 2 s after StopRun", pid)
		}
	}
	if !run.stopped.Load() {
		t.Error("run not marked as stopped")
	}
}

func TestProgramStdinAndPromptFlushing(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module interactive\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	src := `package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	sc := bufio.NewScanner(os.Stdin)
	for {
		fmt.Print("prompt> ")
		if !sc.Scan() {
			fmt.Println("eof")
			return
		}
		fmt.Printf("echo:%s\n", sc.Text())
	}
}
`
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	linesCh := make(chan string, 32)
	var eventsMu sync.Mutex
	var events []string
	t.Cleanup(bridge.SetLog(func(msg string) {
		linesCh <- msg
	}))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic == "runEvent" {
			eventsMu.Lock()
			events = append(events, payload)
			eventsMu.Unlock()
		}
	}))
	routeRunOutputToLogs(t)
	t.Cleanup(StopRun)

	waitForLine := func(want string) {
		t.Helper()
		deadline := time.After(15 * time.Second)
		for {
			select {
			case got := <-linesCh:
				if got == want {
					return
				}
			case <-deadline:
				t.Fatalf("timed out waiting for line %q", want)
			}
		}
	}

	run := RunProject(dir)
	if run == nil {
		t.Fatal("RunProject returned nil")
	}

	waitForLine("prompt> ")
	if err := WriteProgramStdin(run.id, "hello world\n"); err != nil {
		t.Fatalf("WriteProgramStdin failed: %v", err)
	}
	waitForLine("echo:hello world")
	waitForLine("prompt> ")

	if err := CloseProgramStdin(run.id); err != nil {
		t.Fatalf("CloseProgramStdin failed: %v", err)
	}
	waitForLine("eof")
	waitForLine("Process exited successfully.")

	select {
	case <-run.done:
	case <-time.After(5 * time.Second):
		t.Fatal("run did not finish after stdin EOF")
	}

	eventsMu.Lock()
	defer eventsMu.Unlock()
	if len(events) < 3 {
		t.Fatalf("expected started, output, and exited runEvents, got %d", len(events))
	}
}

func TestConcurrentMultiProcessRuns(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module multi\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	serverDir := filepath.Join(root, "cmd", "server")
	cliDir := filepath.Join(root, "cmd", "cli")
	if err := os.MkdirAll(serverDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(cliDir, 0o755); err != nil {
		t.Fatal(err)
	}

	serverSrc := `package main

import (
	"fmt"
	"time"
)

func main() {
	fmt.Println("server-ready")
	time.Sleep(60 * time.Second)
}
`
	cliSrc := `package main

import (
	"fmt"
	"time"
)

func main() {
	fmt.Println("cli-ready")
	time.Sleep(60 * time.Second)
}
`
	if err := os.WriteFile(filepath.Join(serverDir, "main.go"), []byte(serverSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cliDir, "main.go"), []byte(cliSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	linesCh := make(chan string, 64)
	t.Cleanup(bridge.SetLog(func(msg string) {
		linesCh <- msg
	}))
	routeRunOutputToLogs(t)
	t.Cleanup(StopRun)

	waitForLine := func(want string) {
		t.Helper()
		deadline := time.After(15 * time.Second)
		for {
			select {
			case got := <-linesCh:
				if got == want {
					return
				}
			case <-deadline:
				t.Fatalf("timed out waiting for %q", want)
			}
		}
	}

	serverRun1 := RunWithConfig(root, `{"workingDirectory":"cmd/server"}`)
	waitForLine("server-ready")

	cliRun := RunWithConfig(root, `{"workingDirectory":"cmd/cli"}`)
	waitForLine("cli-ready")

	// Starting cmd/cli must NOT stop cmd/server.
	select {
	case <-serverRun1.done:
		t.Fatal("cmd/server was killed when cmd/cli started")
	default:
	}

	// Re-running cmd/server MUST stop the first cmd/server while keeping cmd/cli alive.
	serverRun2 := RunWithConfig(root, `{"workingDirectory":"cmd/server"}`)
	select {
	case <-serverRun1.done:
	case <-time.After(5 * time.Second):
		t.Fatal("previous cmd/server was not stopped on re-run")
	}
	waitForLine("server-ready")

	select {
	case <-cliRun.done:
		t.Fatal("cmd/cli was killed when cmd/server restarted")
	default:
	}

	// StopRun() must stop all active programs.
	StopRun()
	for name, r := range map[string]*processRun{"server2": serverRun2, "cli": cliRun} {
		select {
		case <-r.done:
		case <-time.After(5 * time.Second):
			t.Fatalf("%s did not stop after StopRun", name)
		}
	}
}

func TestProfileSkipsExcludedBuildTagMainFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/buildtagprofile\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	linuxFile := filepath.Join(dir, "00_linux.go")
	linuxSrc := "//go:build linux\n\npackage main\n\nfunc main() {\n}\n"
	if err := os.WriteFile(linuxFile, []byte(linuxSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	darwinFile := filepath.Join(dir, "main.go")
	darwinSrc := strings.Join([]string{
		"//go:build darwin",
		"",
		"package main",
		"",
		"import \"fmt\"",
		"",
		"var globalSink [][]byte",
		"",
		"//go:noinline",
		"func allocateOnDarwin() {",
		"\tfor i := 0; i < 32; i++ {",
		"\t\tb := make([]byte, 32*1024)",
		"\t\tb[0] = byte(i)",
		"\t\tglobalSink = append(globalSink, b)",
		"\t}",
		"}",
		"",
		"func main() {",
		"\tallocateOnDarwin()",
		"\tfmt.Println(\"darwin-profile-ok\")",
		"}",
		"",
	}, "\n")
	if err := os.WriteFile(darwinFile, []byte(darwinSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	found, err := findMainFileWithConfig(dir, map[string]string{"GOOS": "darwin"}, "")
	if err != nil {
		t.Fatalf("findMainFileWithConfig failed: %v", err)
	}
	if found != darwinFile {
		t.Fatalf("findMainFileWithConfig selected %q, want %q", found, darwinFile)
	}

	if testing.Short() {
		return
	}

	var mu sync.Mutex
	var logs []string
	var stderrs []string
	var profilePayloads []string

	t.Cleanup(bridge.SetLog(func(msg string) {
		mu.Lock()
		logs = append(logs, msg)
		mu.Unlock()
	}))
	t.Cleanup(bridge.SetStderr(func(msg string) {
		mu.Lock()
		stderrs = append(stderrs, msg)
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

	run := ProfileWithConfig(dir, "")
	if run == nil {
		t.Fatal("ProfileWithConfig returned nil")
	}
	select {
	case <-run.done:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for profile run")
	}

	mu.Lock()
	gotPayloads := append([]string(nil), profilePayloads...)
	gotLogs := append([]string(nil), logs...)
	mu.Unlock()

	if len(gotPayloads) != 1 {
		t.Fatalf("expected 1 testProfile payload, got %d (logs: %v)", len(gotPayloads), gotLogs)
	}

	// Verify that a failed build does not emit empty testProfile or fake capture message.
	brokenDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(brokenDir, "go.mod"), []byte("module example.com/brokenprofile\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	brokenMain := filepath.Join(brokenDir, "main.go")
	if err := os.WriteFile(brokenMain, []byte("package main\n\nfunc main() {\n\tundefinedSymbolForProfileTest()\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	logs = nil
	stderrs = nil
	profilePayloads = nil
	mu.Unlock()

	failedRun := ProfileWithConfig(brokenDir, "")
	if failedRun == nil {
		t.Fatal("ProfileWithConfig on broken package returned nil")
	}
	select {
	case <-failedRun.done:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for failed profile run")
	}

	mu.Lock()
	brokenPayloads := append([]string(nil), profilePayloads...)
	brokenLogs := append([]string(nil), logs...)
	brokenStderrs := append([]string(nil), stderrs...)
	mu.Unlock()

	if len(brokenPayloads) != 0 {
		t.Fatalf("expected 0 testProfile payloads on failed build, got %d: %v", len(brokenPayloads), brokenPayloads)
	}
	for _, l := range brokenLogs {
		if strings.Contains(l, "Application profile captured") {
			t.Fatalf("unexpected success log on failed profile run: %q", l)
		}
	}
	foundFailErr := false
	for _, s := range brokenStderrs {
		if strings.Contains(s, "Application profiling failed") {
			foundFailErr = true
			break
		}
	}
	if !foundFailErr {
		t.Fatalf("expected stderr 'Application profiling failed', got stderrs=%v logs=%v", brokenStderrs, brokenLogs)
	}
}

func TestAuditStopBlockedByStdin(t *testing.T) {
	run := startProgram(exec.Command("sleep", "20"))
	if run == nil {
		t.Fatal("startProgram returned nil")
	}
	t.Cleanup(func() {
		if run.cmd != nil && run.cmd.Process != nil {
			_ = syscall.Kill(-run.cmd.Process.Pid, syscall.SIGKILL)
		}
	})

	writeDone := make(chan error, 1)
	go func() {
		payload := strings.Repeat("x", 4*1024*1024)
		writeDone <- WriteProgramStdin(run.id, payload)
	}()

	time.Sleep(150 * time.Millisecond)

	stopDone := make(chan struct{})
	go func() {
		StopProgramRun(run.id)
		close(stopDone)
	}()

	select {
	case <-stopDone:
	case <-time.After(1500 * time.Millisecond):
		t.Fatal("StopProgramRun was blocked by full stdin pipe write (> 1.5s)")
	}

	select {
	case <-writeDone:
	case <-time.After(1500 * time.Millisecond):
		t.Fatal("WriteProgramStdin did not unblock after StopProgramRun")
	}
}

// routeRunOutputToLogs replays batched runEvent output lines through bridge.Log and bridge.Stderr so
// tests can wait for a program's output line by line.
func routeRunOutputToLogs(t *testing.T) {
	t.Helper()
	t.Cleanup(bridge.WrapStatus(func(topic, payload string, prev func(string, string)) {
		if topic == "runEvent" || topic == "taskLog" {
			var ev runOutputEvent
			if json.Unmarshal([]byte(payload), &ev) == nil {
				for _, line := range ev.Lines {
					if line.Stderr {
						bridge.Stderr(line.Text)
					} else {
						bridge.Log(line.Text)
					}
				}
			}
		}
		if prev != nil {
			prev(topic, payload)
		}
	}))
}

func TestRunOutputBatcherPreservesOrderAndFlushes(t *testing.T) {
	var mu sync.Mutex
	var events []runOutputEvent
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		if topic != "runEvent" {
			return
		}
		var ev runOutputEvent
		if err := json.Unmarshal([]byte(payload), &ev); err != nil {
			t.Errorf("bad payload %q: %v", payload, err)
			return
		}
		mu.Lock()
		events = append(events, ev)
		mu.Unlock()
	}))

	b := &runOutputBatcher{id: 7}
	t.Cleanup(b.flush)
	b.add("one", false)
	b.add("two", true)
	b.add("three", false)
	b.flush()

	mu.Lock()
	got := append([]runOutputEvent(nil), events...)
	mu.Unlock()
	if len(got) != 1 || got[0].ID != 7 {
		t.Fatalf("expected one batch for run 7, got %+v", got)
	}
	want := []runOutputLine{{"one", false}, {"two", true}, {"three", false}}
	if len(got[0].Lines) != len(want) {
		t.Fatalf("lines = %+v, want %+v", got[0].Lines, want)
	}
	for i := range want {
		if got[0].Lines[i] != want[i] {
			t.Fatalf("line %d = %+v, want %+v", i, got[0].Lines[i], want[i])
		}
	}

	big := strings.Repeat("x", runOutputFlushBytes)
	b.add(big, false)
	mu.Lock()
	n := len(events)
	mu.Unlock()
	if n != 2 {
		t.Fatalf("expected an immediate flush at the size limit, got %d events", n)
	}

	b.add("late", false)
	deadline := time.Now().Add(2 * time.Second)
	for {
		mu.Lock()
		n = len(events)
		mu.Unlock()
		if n == 3 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("timed flush did not emit the pending line")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestRunOutputBatcherFlushWaitsForTimersAndBridgeSwaps(t *testing.T) {
	for i := 0; i < 20; i++ {
		var afterFlush atomic.Bool
		var lateCalls atomic.Int64
		var count atomic.Int64
		b := &runOutputBatcher{
			id: int64(100 + i),
			emit: func(id int64, lines []runOutputLine) {
				if afterFlush.Load() {
					lateCalls.Add(int64(len(lines)))
				}
				count.Add(int64(len(lines)))
			},
		}
		b.add("tick", false)
		if i%2 == 0 {
			time.Sleep(runOutputFlushDelay)
		}
		b.flush()
		afterFlush.Store(true)
		time.Sleep(runOutputFlushDelay / 2)
		if got := lateCalls.Load(); got != 0 {
			t.Fatalf("iteration %d: emitted %d lines after flush returned", i, got)
		}
		if got := count.Load(); got != 1 {
			t.Fatalf("iteration %d: emitted %d total lines, want 1", i, got)
		}
	}

	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				restore := bridge.SetStatus(func(string, string) {})
				bridge.Status("runEvent", "{}")
				restore()
			}
		}
	}()
	for i := 0; i < 10; i++ {
		dir := t.TempDir()
		cmd := exec.Command("/bin/sh", "-c", "printf 'done\\n'")
		cmd.Dir = dir
		run := startProgramWithMeta(cmd, "batcher-race", "batcher-race", dir)
		<-run.done
	}
	close(stop)
	wg.Wait()
}
