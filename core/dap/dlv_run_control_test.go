package dap

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

const loopDebuggee = `package main

import (
	"fmt"
	"time"
)

func tick(i int) int {
	return i * 2
}

func main() {
	total := 0
	for i := 0; ; i++ {
		total += tick(i)
		time.Sleep(20 * time.Millisecond)
		if i%100 == 0 {
			fmt.Println("tick", i, total)
		}
	}
}
`

func TestRealDelvePauseRunToLineAndFunctionBreakpoint(t *testing.T) {
	if _, err := resolveHostDelvePath(); err != nil || testing.Short() || (!bridge.IsHostMode() && bridge.GetVsockDialer() == nil) {
		t.Skip("dlv not installed or vsock dialer unset")
	}
	dir := t.TempDir()
	if real, err := filepath.EvalSymlinks(dir); err == nil {
		dir = real
	}
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module loopdbg\n\ngo 1.22\n"), 0o644)
	main := filepath.Join(dir, "main.go")
	_ = os.WriteFile(main, []byte(loopDebuggee), 0o644)

	stops := make(chan map[string]any, 16)
	t.Cleanup(bridge.SetDebugEvent(func(name, payload string) {
		if name == "stopped" {
			var m map[string]any
			_ = json.Unmarshal([]byte(payload), &m)
			body, _ := m["body"].(map[string]any)
			stops <- body
		}
	}))
	t.Cleanup(bridge.SetLog(func(string) {}))
	t.Cleanup(bridge.SetDebug(func(string) {}))

	cfg, _ := json.Marshal(RunConfig{WorkingDirectory: dir})
	if err := StartDebug(string(cfg)); err != nil {
		t.Fatal(err)
	}
	c := GetClient()
	t.Cleanup(c.Stop)
	if !c.Capabilities().SupportsFunctionBreakpoints {
		t.Fatal("Delve does not advertise supportsFunctionBreakpoints")
	}
	if err := c.ConfigurationDone(); err != nil {
		t.Fatal(err)
	}
	wait := func(what string) map[string]any {
		t.Helper()
		select {
		case b := <-stops:
			return b
		case <-time.After(60 * time.Second):
			t.Fatalf("timed out waiting for %s", what)
			return nil
		}
	}
	time.Sleep(500 * time.Millisecond)

	if err := c.Pause(1); err != nil {
		t.Fatal(err)
	}
	stop := wait("pause")
	if stop["reason"] != "pause" {
		t.Fatalf("pause stopped with %v", stop)
	}
	id, _ := stop["threadId"].(float64)
	tid := int(id)
	if tid == 0 {
		t.Fatalf("a pause must name a goroutine to show: %v", stop)
	}
	frames, err := c.stackTrace(tid, 20)
	if err != nil || len(frames) == 0 {
		t.Fatalf("no stack after pause on goroutine %d: %v", tid, err)
	}
	t.Logf("paused on goroutine %d at %s", tid, frames[0].Name)

	target := lineOf(loopDebuggee, "time.Sleep(20")
	if err := c.RunToLine(main, target, nil, tid); err != nil {
		t.Fatal(err)
	}
	stop = wait("run to line")
	tid = int(stop["threadId"].(float64))
	frames, err = c.stackTrace(tid, 5)
	if err != nil || len(frames) == 0 || frames[0].Line != target {
		t.Fatalf("run to line stopped at %+v, want line %d (%v)", frames, target, err)
	}
	if err := c.Continue(tid); err != nil {
		t.Fatal(err)
	}
	select {
	case b := <-stops:
		t.Fatalf("the temporary breakpoint stayed: stopped again %v", b)
	case <-time.After(1500 * time.Millisecond):
	}

	if err := c.Pause(1); err != nil {
		t.Fatal(err)
	}
	stop = wait("second pause")
	data, err := c.SetFunctionBreakpoints([]FunctionBreakpoint{{Name: "main.tick"}, {Name: "main.noSuchFunction"}})
	if err != nil {
		t.Fatal(err)
	}
	var verified []struct {
		Verified bool
		Message  string
	}
	_ = json.Unmarshal(data, &verified)
	if len(verified) != 2 || !verified[0].Verified || verified[1].Verified || verified[1].Message == "" {
		t.Fatalf("function breakpoints %s", data)
	}
	t.Logf("unknown function: %s", verified[1].Message)
	if err := c.Continue(int(stop["threadId"].(float64))); err != nil {
		t.Fatal(err)
	}
	stop = wait("function breakpoint")
	frames, err = c.stackTrace(int(stop["threadId"].(float64)), 5)
	if err != nil || len(frames) == 0 || !strings.HasSuffix(frames[0].Name, "main.tick") {
		t.Fatalf("function breakpoint stopped at %+v (%v)", frames, err)
	}
}
