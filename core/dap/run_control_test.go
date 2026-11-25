package dap

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/google/go-dap"
)

func (f *fakeAdapter) event(name, body string) {
	_ = dap.WriteProtocolMessage(f.conn, decode(f.t, `{"seq":2000,"type":"event","event":"`+name+`","body":`+body+`}`))
}

func breakpointLines(req *dap.SetBreakpointsRequest) []int {
	lines := []int{}
	for _, b := range req.Arguments.Breakpoints {
		lines = append(lines, b.Line)
	}
	return lines
}

func TestPauseSendsPauseForTheThread(t *testing.T) {
	c, f := pipeClient(t)
	done := make(chan error, 1)
	go func() { done <- c.Pause(17) }()
	m := f.next().(*dap.PauseRequest)
	if m.Command != "pause" || m.Arguments.ThreadId != 17 {
		t.Fatalf("pause %+v", m)
	}
	f.respond(m, `{}`)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestStopWithoutAGoroutineNamesTheFirstUserGoroutine(t *testing.T) {
	c, f := pipeClient(t)
	got := make(chan string, 1)
	c.onEvent = func(name, payload string) {
		if name == "stopped" {
			got <- payload
		}
	}
	f.event("stopped", `{"reason":"pause","allThreadsStopped":true}`)
	req := f.next().(*dap.ThreadsRequest)
	f.respond(req, `{"threads":[{"id":2,"name":"[Go 2] runtime.gopark"},{"id":7,"name":"* [Go 7] main.worker"},{"id":9,"name":"[Go 9] time.Sleep"}]}`)
	var stopped dap.StoppedEvent
	if err := json.Unmarshal([]byte(<-got), &stopped); err != nil {
		t.Fatal(err)
	}
	if stopped.Body.ThreadId != 7 || stopped.Body.Reason != "pause" {
		t.Fatalf("stopped %+v", stopped.Body)
	}
}

func TestRunToLineRemovesItsBreakpointAtTheNextStop(t *testing.T) {
	c, f := pipeClient(t)
	keep := []Breakpoint{{Line: 3, Condition: "i > 2"}, {Line: 9, LogMessage: "at nine"}}
	done := make(chan error, 1)
	go func() { done <- c.RunToLine("/w/main.go", 9, keep, 5) }()

	set := f.next().(*dap.SetBreakpointsRequest)
	if got := breakpointLines(set); !reflect.DeepEqual(got, []int{3, 9}) {
		t.Fatalf("temporary breakpoint request lines %v", got)
	}
	if set.Arguments.Breakpoints[0].Condition != "i > 2" || set.Arguments.Breakpoints[1].LogMessage != "" {
		t.Fatalf("own breakpoint kept and temporary one plain: %+v", set.Arguments.Breakpoints)
	}
	f.respond(set, `{"breakpoints":[{"verified":true,"line":3},{"verified":true,"line":9}]}`)
	cont := f.next().(*dap.ContinueRequest)
	if cont.Arguments.ThreadId != 5 {
		t.Fatalf("continue thread %d", cont.Arguments.ThreadId)
	}
	f.respond(cont, `{"allThreadsContinued":true}`)
	if err := <-done; err != nil {
		t.Fatal(err)
	}

	edited := make(chan error, 1)
	go func() { _, err := c.SetBreakpoints("/w/main.go", []Breakpoint{{Line: 4}}); edited <- err }()
	mid := f.next().(*dap.SetBreakpointsRequest)
	if got := breakpointLines(mid); !reflect.DeepEqual(got, []int{4, 9}) {
		t.Fatalf("an edit while running keeps the temporary line: %v", got)
	}
	f.respond(mid, `{"breakpoints":[{"verified":true,"line":4},{"verified":true,"line":9}]}`)
	if err := <-edited; err != nil {
		t.Fatal(err)
	}

	f.event("stopped", `{"reason":"breakpoint","threadId":5,"allThreadsStopped":true}`)
	restore := f.next().(*dap.SetBreakpointsRequest)
	if got := breakpointLines(restore); !reflect.DeepEqual(got, []int{4}) {
		t.Fatalf("restore after the stop sends only the person's breakpoints: %v", got)
	}
	f.respond(restore, `{"breakpoints":[{"verified":true,"line":4}]}`)

	again := make(chan error, 1)
	go func() { _, err := c.SetBreakpoints("/w/main.go", []Breakpoint{{Line: 4}}); again <- err }()
	later := f.next().(*dap.SetBreakpointsRequest)
	if got := breakpointLines(later); !reflect.DeepEqual(got, []int{4}) {
		t.Fatalf("no temporary line after the stop: %v", got)
	}
	f.respond(later, `{"breakpoints":[{"verified":true,"line":4}]}`)
	<-again
}

func TestRunToLineOnALineWithoutCodeRestoresAndDoesNotContinue(t *testing.T) {
	c, f := pipeClient(t)
	keep := []Breakpoint{{Line: 3}}
	done := make(chan error, 1)
	go func() { done <- c.RunToLine("/w/main.go", 1, keep, 1) }()
	set := f.next().(*dap.SetBreakpointsRequest)
	f.respond(set, `{"breakpoints":[{"verified":true,"line":3},{"verified":false,"line":1,"message":"could not find statement"}]}`)
	restore := f.next().(*dap.SetBreakpointsRequest)
	if got := breakpointLines(restore); !reflect.DeepEqual(got, []int{3}) {
		t.Fatalf("restore lines %v", got)
	}
	f.respond(restore, `{"breakpoints":[{"verified":true,"line":3}]}`)
	if err := <-done; err == nil {
		t.Fatal("a line without code must fail")
	}
	c.mu.Lock()
	pending := c.runTo
	c.mu.Unlock()
	if pending != nil {
		t.Fatal("failed run to line left a temporary breakpoint pending")
	}
}

func TestRunToLineEndsWhenTheProgramExits(t *testing.T) {
	c, f := pipeClient(t)
	go func() { _ = c.RunToLine("/w/main.go", 9, nil, 1) }()
	set := f.next().(*dap.SetBreakpointsRequest)
	f.respond(set, `{"breakpoints":[{"verified":true,"line":9}]}`)
	cont := f.next().(*dap.ContinueRequest)
	f.respond(cont, `{}`)
	f.event("exited", `{"exitCode":0}`)
	restore := f.next().(*dap.SetBreakpointsRequest)
	if len(restore.Arguments.Breakpoints) != 0 {
		t.Fatalf("exit clears the temporary breakpoint: %v", breakpointLines(restore))
	}
	f.respond(restore, `{"breakpoints":[]}`)
}

func TestFunctionBreakpointsNeedTheCapability(t *testing.T) {
	c, f := pipeClient(t)
	if _, err := c.SetFunctionBreakpoints([]FunctionBreakpoint{{Name: "main.handler"}}); err == nil {
		t.Fatal("function breakpoints must be refused before the adapter advertises them")
	}
	done := make(chan error, 1)
	go func() { done <- c.initialize() }()
	init := f.next().(*dap.InitializeRequest)
	f.respond(init, `{"supportsFunctionBreakpoints":true,"supportsConditionalBreakpoints":true}`)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if !c.Capabilities().SupportsFunctionBreakpoints {
		t.Fatal("capabilities from initialize were not kept")
	}
	got := make(chan []byte, 1)
	go func() {
		data, err := c.SetFunctionBreakpoints([]FunctionBreakpoint{{Name: " main.handler "}, {Name: ""}, {Name: "(*Server).Serve", Condition: " n > 1 "}})
		if err != nil {
			t.Error(err)
		}
		got <- data
	}()
	req := f.next().(*dap.SetFunctionBreakpointsRequest)
	want := []dap.FunctionBreakpoint{{Name: "main.handler"}, {Name: "(*Server).Serve", Condition: "n > 1"}}
	if !reflect.DeepEqual(req.Arguments.Breakpoints, want) {
		t.Fatalf("function breakpoints %+v", req.Arguments.Breakpoints)
	}
	f.respond(req, `{"breakpoints":[{"verified":true},{"verified":false,"message":"could not find function"}]}`)
	if data := <-got; string(data) == "" {
		t.Fatal("no breakpoint result")
	}
	c.mu.Lock()
	tracked := c.fnBps
	c.mu.Unlock()
	if !tracked {
		t.Fatal("function breakpoints must be tracked so a detach clears them")
	}
}

func TestClearingFunctionBreakpointsThatWereNeverSetSendsNothing(t *testing.T) {
	c, _ := pipeClient(t)
	data, err := c.SetFunctionBreakpoints(nil)
	if err != nil || string(data) != "[]" {
		t.Fatalf("empty list without the capability: %s %v", data, err)
	}
	if c.pendingCount() != 0 {
		t.Fatal("no request must be sent")
	}
	bps, err := ParseFunctionBreakpoints(`[{"name":"main.tick"},{"name":"(*Server).Serve","condition":"n > 1"}]`)
	if err != nil || len(bps) != 2 || bps[1].Condition != "n > 1" {
		t.Fatalf("parse %+v %v", bps, err)
	}
	if _, err := ParseFunctionBreakpoints(`{"name":1}`); err == nil {
		t.Fatal("garbage must fail")
	}
}
