package dap

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
)

const debuggee = `package main

import (
	"fmt"
	"net"
	"time"
)

func label(i int) string { return fmt.Sprintf("item-%d", i) }

func worker(ch chan int) { <-ch }

func main() {
	ch := make(chan int)
	for w := 0; w < 3; w++ {
		go worker(ch)
	}
	delay := 1500 * time.Millisecond
	ip := net.IPv4(10, 0, 0, 1).To4()
	row := struct {
		name string
		n    int
	}{"small", 2}
	total := 0
	for i := 0; i < 6; i++ {
		total += i
		fmt.Println(label(i))
	}
	_ = delay
	_ = ip
	_ = row
	var xs []int
	fmt.Println(total, xs[3])
}
`

type events struct {
	mu   sync.Mutex
	list []string
	out  []string
	ch   chan string
}

func lineOf(src, needle string) int {
	return strings.Count(src[:strings.Index(src, needle)], "\n") + 1
}

func TestRealDelveSession(t *testing.T) {
	if _, err := resolveHostDelvePath(); err != nil || testing.Short() || (!bridge.IsHostMode() && bridge.GetVsockDialer() == nil) {
		t.Skip("dlv not installed or vsock dialer unset")
	}
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module dbg\n\ngo 1.22\n"), 0o644)
	main := filepath.Join(dir, "main.go")
	_ = os.WriteFile(main, []byte(debuggee), 0o644)

	ev := &events{ch: make(chan string, 64)}
	t.Cleanup(bridge.SetDebugEvent(func(name, payload string) {
		ev.mu.Lock()
		ev.list = append(ev.list, name)
		if name == "output" {
			ev.out = append(ev.out, payload)
		}
		ev.mu.Unlock()
		if name == "stopped" || name == "terminated" {
			ev.ch <- payload
		}
	}))
	var logs []string
	var logMu sync.Mutex
	logFn := func(s string) { logMu.Lock(); logs = append(logs, s); logMu.Unlock() }
	t.Cleanup(bridge.SetLog(logFn))
	t.Cleanup(bridge.SetDebug(logFn))

	cfg, _ := json.Marshal(RunConfig{WorkingDirectory: dir})
	if err := StartDebug(string(cfg)); err != nil {
		t.Fatal(err)
	}
	c := GetClient()
	tempDir := c.tempDir
	if !strings.HasPrefix(filepath.Base(tempDir), "golens-debug-") {
		t.Fatalf("temp dir %q", tempDir)
	}
	t.Cleanup(c.Stop)
	loop := lineOf(debuggee, "total += i")
	logLine := lineOf(debuggee, "fmt.Println(label(i))")
	bps, err := c.SetBreakpoints(main, []Breakpoint{{Line: loop, Condition: "i == 4"}, {Line: logLine, LogMessage: "logged {i}"}})
	if err != nil {
		t.Fatal(err)
	}
	var verified []struct{ Verified bool }
	_ = json.Unmarshal(bps, &verified)
	if len(verified) != 2 || !verified[0].Verified || !verified[1].Verified {
		t.Fatalf("breakpoints %s", bps)
	}
	if err := c.ConfigurationDone(); err != nil {
		t.Fatal(err)
	}
	wait := func(what string) map[string]any {
		t.Helper()
		select {
		case p := <-ev.ch:
			var m map[string]any
			_ = json.Unmarshal([]byte(p), &m)
			return m
		case <-time.After(60 * time.Second):
			t.Fatalf("timed out waiting for %s", what)
			return nil
		}
	}
	stop := wait("conditional breakpoint")
	body := stop["body"].(map[string]any)
	tid := int(body["threadId"].(float64))
	frames, _ := c.stackTrace(tid, 5)
	if frames[0].Line != loop {
		t.Fatalf("stopped at line %d, want %d", frames[0].Line, loop)
	}
	frameID := frames[0].Id
	if v, err := c.Evaluate("i", frameID); err != nil || v != "4" {
		t.Fatalf("condition i == 4 not honoured: %q %v", v, err)
	}
	if v, err := c.Evaluate("label(i)", frameID); err != nil || !strings.Contains(v, "item-4") {
		t.Fatalf("evaluate with a call: %q %v", v, err)
	}
	scopes, _ := c.GetScopes(frameID)
	var sc []struct{ VariablesReference int }
	_ = json.Unmarshal(scopes, &sc)
	vars, _ := c.variables(sc[0].VariablesReference)
	values := map[string]string{}
	for _, v := range vars {
		values[v.Name] = v.Value
	}
	if values["delay"] != "1.5s" || values["ip"] != "10.0.0.1" || values["row"] != `{name: "small", n: 2}` {
		t.Fatalf("readable values %v", values)
	}
	if _, err := c.SetVariable(sc[0].VariablesReference, "total", "100"); err != nil {
		t.Fatal(err)
	}
	if v, _ := c.Evaluate("total", frameID); v != "100" {
		t.Fatalf("setVariable: total = %q", v)
	}
	groups, err := c.GoroutineGroups()
	if err != nil {
		t.Fatal(err)
	}
	var gg []GoroutineGroup
	_ = json.Unmarshal(groups, &gg)
	workers := 0
	for _, g := range gg {
		for _, f := range g.Frames {
			if f == "main.worker" && g.Count == 3 {
				workers++
			}
		}
	}
	if workers != 1 {
		t.Fatalf("three identical workers must form one group: %s", groups)
	}
	if err := c.Continue(tid); err != nil {
		t.Fatal(err)
	}
	stop = wait("panic")
	body = stop["body"].(map[string]any)
	if body["reason"] != "exception" {
		t.Fatalf("expected a stop on panic, got %v", body)
	}
	info, err := c.ExceptionInfo(int(body["threadId"].(float64)))
	if err != nil || !strings.Contains(string(info), "index out of range") {
		t.Fatalf("exception info %s %v", info, err)
	}
	ev.mu.Lock()
	logged := strings.Join(ev.out, "\n")
	ev.mu.Unlock()
	if !strings.Contains(logged, "logged 4") || !strings.Contains(logged, "logged 5") {
		t.Fatalf("logpoint output missing: %s", logged)
	}
	logMu.Lock()
	for _, l := range logs {
		if strings.HasPrefix(l, "[dlv]") {
			t.Fatalf("dlv log line forwarded without debug logging: %s", l)
		}
	}
	logMu.Unlock()
	pid := c.cmd.Process.Pid
	c.Stop()
	if _, err := os.Stat(tempDir); !os.IsNotExist(err) {
		t.Fatalf("debug binary dir survived stop: %v", err)
	}
	if c.pendingCount() != 0 {
		t.Fatal("pending requests after stop")
	}
	if exec.Command("kill", "-0", itoa(pid)).Run() == nil {
		t.Fatalf("dlv %d still running", pid)
	}
}

func TestRealDelveAttachAndDetach(t *testing.T) {
	if _, err := resolveHostDelvePath(); err != nil || testing.Short() || (!bridge.IsHostMode() && bridge.GetVsockDialer() == nil) {
		t.Skip("dlv not installed or vsock dialer unset")
	}
	dir := t.TempDir()
	if realDir, err := filepath.EvalSymlinks(dir); err == nil {
		dir = realDir
	}
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module attachdbg\n\ngo 1.22\n"), 0o644)
	src := `package main

import "time"

func daemonStep(iter int) int {
	return iter + 1
}

func main() {
	for i := 0; i < 10000; i++ {
		_ = daemonStep(i)
		time.Sleep(30 * time.Millisecond)
	}
}
`
	mainPath := filepath.Join(dir, "main.go")
	_ = os.WriteFile(mainPath, []byte(src), 0o644)

	binPath := filepath.Join(dir, "attach-target")
	buildCmd := exec.Command("go", "build", "-gcflags=all=-N -l", "-o", binPath, ".")
	buildCmd.Dir = dir
	if out, err := buildCmd.CombinedOutput(); err != nil {
		t.Fatalf("go build failed: %v\n%s", err, out)
	}

	targetCmd := exec.Command(binPath)
	targetCmd.Dir = dir
	if err := targetCmd.Start(); err != nil {
		t.Fatalf("start target: %v", err)
	}
	targetPID := targetCmd.Process.Pid
	t.Cleanup(func() {
		if targetCmd.Process != nil {
			_ = targetCmd.Process.Kill()
			_, _ = targetCmd.Process.Wait()
		}
	})
	time.Sleep(150 * time.Millisecond)

	stoppedCh := make(chan string, 16)
	t.Cleanup(bridge.SetDebugEvent(func(name, payload string) {
		if name == "stopped" {
			stoppedCh <- payload
		}
	}))
	t.Cleanup(bridge.SetLog(func(string) {}))
	t.Cleanup(bridge.SetDebug(func(string) {}))

	cfg, _ := json.Marshal(RunConfig{
		WorkingDirectory: dir,
		ActiveFilePath:   mainPath,
		AttachPID:        targetPID,
	})
	if err := StartDebug(string(cfg)); err != nil {
		t.Fatalf("StartDebug attach: %v", err)
	}
	c := GetClient()
	t.Cleanup(c.Stop)

	bpLine := lineOf(src, "return iter + 1")
	unprefixedMain := strings.TrimPrefix(mainPath, "/private")
	bps, err := c.SetBreakpoints(unprefixedMain, []Breakpoint{{Line: bpLine}})
	if err != nil {
		t.Fatalf("SetBreakpoints: %v", err)
	}
	var verified []struct {
		Verified bool
		Message  string
	}
	_ = json.Unmarshal(bps, &verified)
	if len(verified) != 1 || !verified[0].Verified {
		t.Fatalf("breakpoint not verified: %s", bps)
	}
	if err := c.ConfigurationDone(); err != nil {
		t.Fatalf("ConfigurationDone: %v", err)
	}

	select {
	case payload := <-stoppedCh:
		var m map[string]any
		_ = json.Unmarshal([]byte(payload), &m)
		body, _ := m["body"].(map[string]any)
		tid := int(body["threadId"].(float64))
		frames, err := c.stackTrace(tid, 5)
		if err != nil || len(frames) == 0 {
			t.Fatalf("stackTrace after attach stop: %v %v", frames, err)
		}
		if frames[0].Line != bpLine || !strings.Contains(frames[0].Name, "daemonStep") {
			t.Fatalf("unexpected top frame: %+v (want line %d in daemonStep)", frames[0], bpLine)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for attached process to hit breakpoint in daemonStep")
	}

	c.Stop()
	time.Sleep(150 * time.Millisecond)
	if err := exec.Command("kill", "-0", itoa(targetPID)).Run(); err != nil {
		t.Fatalf("attached target process %d should remain alive after detach, but kill -0 failed: %v", targetPID, err)
	}
}
