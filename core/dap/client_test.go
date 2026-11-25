package dap

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/go-dap"
)

type fakeAdapter struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func pipeClient(t *testing.T) (*Client, *fakeAdapter) {
	a, b := net.Pipe()
	c := newClient(a)
	go c.readLoop()
	t.Cleanup(func() { _ = a.Close(); _ = b.Close(); <-c.readDone })
	return c, &fakeAdapter{t: t, conn: b, r: bufio.NewReader(b)}
}

func (f *fakeAdapter) next() dap.Message {
	f.t.Helper()
	_ = f.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	m, err := dap.ReadProtocolMessage(f.r)
	if err != nil {
		f.t.Fatalf("read: %v", err)
	}
	return m
}

func (f *fakeAdapter) respond(req dap.RequestMessage, body string) {
	r := req.GetRequest()
	msg := `{"seq":1000,"type":"response","request_seq":` + itoa(r.Seq) + `,"success":true,"command":"` + r.Command + `","body":` + body + `}`
	_ = dap.WriteProtocolMessage(f.conn, decode(f.t, msg))
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func decode(t *testing.T, s string) dap.Message {
	m, err := dap.DecodeProtocolMessage([]byte(s))
	if err != nil {
		t.Fatalf("decode %s: %v", s, err)
	}
	return m
}

func TestConditionalBreakpointsAndLogpoints(t *testing.T) {
	bps, err := ParseBreakpoints(`[{"line":10,"condition":" i > 3 "},{"line":12,"logMessage":"i={i}"},{"line":14,"hitCondition":"5"}]`)
	if err != nil || len(bps) != 3 {
		t.Fatalf("parse %v %v", bps, err)
	}
	args := setBreakpointsArguments("/w/main.go", bps)
	if args.Source.Path != "/w/main.go" || args.Breakpoints[0].Condition != "i > 3" || args.Breakpoints[1].LogMessage != "i={i}" || args.Breakpoints[2].HitCondition != "5" {
		t.Fatalf("args %+v", args)
	}
	legacy, err := ParseBreakpoints(`[3,7]`)
	if err != nil || len(legacy) != 2 || legacy[1].Line != 7 || legacy[1].Condition != "" {
		t.Fatalf("legacy %v %v", legacy, err)
	}
	if _, err := ParseBreakpoints(`{"x":1}`); err == nil {
		t.Fatal("garbage must fail")
	}
}

func TestEvaluateUsesCallOnlyForCalls(t *testing.T) {
	cases := map[string]bool{
		"x":                    false,
		"s.Field":              false,
		"m[\"k\"]":             false,
		"len(s)":               false,
		"int64(x) + 1":         false,
		"v.(fmt.Stringer)":     false,
		`"f(x)"`:               false,
		"s.String()":           true,
		"compute(1, 2)":        true,
		"a + pkg.Fn(b)":        true,
		"buf.Len() > cap(buf)": true,
	}
	for expr, want := range cases {
		if got := HasCall(expr); got != want {
			t.Errorf("HasCall(%q) = %v, want %v", expr, got, want)
		}
	}
	if a := evaluateArguments("s.String()", 3); a.Expression != "call s.String()" || a.Context != "repl" || a.FrameId != 3 {
		t.Fatalf("call args %+v", a)
	}
	if a := evaluateArguments("x.y", 3); a.Expression != "x.y" || a.Context != "watch" {
		t.Fatalf("watch args %+v", a)
	}
	if a := evaluateArguments("call f()", 1); a.Expression != "call f()" {
		t.Fatalf("explicit call must not be doubled: %+v", a)
	}
}

func TestRequestBuildersOverTheWire(t *testing.T) {
	c, f := pipeClient(t)
	done := make(chan error, 1)
	go func() {
		_, err := c.SetVariable(7, "count", "42")
		done <- err
	}()
	m := f.next().(*dap.SetVariableRequest)
	if m.Arguments.VariablesReference != 7 || m.Arguments.Name != "count" || m.Arguments.Value != "42" {
		t.Fatalf("setVariable %+v", m.Arguments)
	}
	f.respond(m, `{"value":"42","type":"int"}`)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	go func() { done <- c.SetExceptionBreakpoints(ExceptionFilters) }()
	e := f.next().(*dap.SetExceptionBreakpointsRequest)
	if strings.Join(e.Arguments.Filters, ",") != "unrecovered-panic,runtime-fatal-throw" {
		t.Fatalf("filters %v", e.Arguments.Filters)
	}
	f.respond(e, `{"breakpoints":[]}`)
	<-done
	go func() { _, err := c.GetVariables(9); done <- err }()
	v := f.next().(*dap.VariablesRequest)
	if v.Arguments.Count != maxVariablesPage {
		t.Fatalf("variables must be paged: %+v", v.Arguments)
	}
	f.respond(v, `{"variables":[{"name":"d","value":"time.Duration(1500000000)","type":"time.Duration","variablesReference":0},{"name":"s","value":"`+strings.Repeat("x", 3000)+`","variablesReference":0}]}`)
	<-done
	if c.pendingCount() != 0 {
		t.Fatalf("%d pending requests after responses", c.pendingCount())
	}
}

func TestStopReleasesPendingRequestsAndTempDir(t *testing.T) {
	c, f := pipeClient(t)
	dir, err := os.MkdirTemp("", "golens-debug-test-")
	if err != nil {
		t.Fatal(err)
	}
	c.tempDir = dir
	errs := make(chan error, 3)
	for i := 0; i < 3; i++ {
		go func() { _, err := c.GetStackTrace(1); errs <- err }()
	}
	for i := 0; i < 3; i++ {
		f.next()
	}
	go func() {
		for {
			m, err := dap.ReadProtocolMessage(f.r)
			if err != nil {
				return
			}
			if d, ok := m.(*dap.DisconnectRequest); ok {
				f.respond(d, `{}`)
			}
		}
	}()
	c.Stop()
	for i := 0; i < 3; i++ {
		if err := <-errs; err == nil {
			t.Fatal("request must fail after stop")
		}
	}
	if n := c.pendingCount(); n != 0 {
		t.Fatalf("%d pending requests leaked on stop", n)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("temp debug binary dir not removed: %v", err)
	}
	if _, err := c.GetThreads(); err == nil {
		t.Fatal("requests after stop must fail fast")
	}
	c.Stop()
}

func TestTimeoutDoesNotLeakPending(t *testing.T) {
	c, f := pipeClient(t)
	go f.next()
	if _, err := c.SendRequestTimeout(&dap.ThreadsRequest{Request: c.NewRequest("threads")}, 20*time.Millisecond); err == nil {
		t.Fatal("expected timeout")
	}
	if c.pendingCount() != 0 {
		t.Fatal("timed-out request leaked")
	}
}

func TestGoroutinesGroupedByIdenticalStack(t *testing.T) {
	src := &dap.Source{Path: "/w/main.go"}
	worker := []dap.StackFrame{{Name: "runtime.gopark"}, {Name: "main.worker", Source: src, Line: 12}}
	threads := []dap.Thread{{Id: 1, Name: "main"}, {Id: 2, Name: "w1"}, {Id: 3, Name: "w2"}, {Id: 4, Name: "w3"}}
	stacks := map[int][]dap.StackFrame{
		1: {{Name: "main.main", Source: src, Line: 30}},
		2: worker, 3: worker, 4: {{Name: "runtime.gopark"}, {Name: "main.worker", Source: src, Line: 14}},
	}
	groups := GroupByStack(threads, stacks)
	if len(groups) != 3 || groups[1].Count != 2 || groups[1].ThreadIDs[1] != 3 || groups[0].Location != "main.go:30" || groups[2].Count != 1 || groups[1].Top != "main.worker" || groups[1].Location != "main.go:12" {
		t.Fatalf("groups %+v", groups)
	}
}

func TestReadableValues(t *testing.T) {
	cases := []struct{ typ, in, want string }{
		{"time.Duration", "time.Duration(1500000000)", "1.5s"},
		{"time.Duration", "-2000", "-2µs"},
		{"net.IP", "net.IP len: 4, cap: 4, [127,0,0,1]", "127.0.0.1"},
		{"net.IP", "net.IP len: 16, cap: 16, [0,0,0,0,0,0,0,0,0,0,255,255,10,0,0,1]", "10.0.0.1"},
		{"net.IP", "net.IP len: 16, cap: 16, [32,1,13,184,0,0,0,0,0,0,0,0,0,0,0,1]", "2001:db8::1"},
		{"int", "42", "42"},
		{"struct { main.name string; main.a int }", `struct { main.name string; main.a int } {name: "small", a: 2}`, `{name: "small", a: 2}`},
		{"[]struct { main.a int }", "[]struct { main.a int } len: 1, cap: 1, [{a: 2}]", "len: 1, cap: 1, [{a: 2}]"},
		{"main.Point", "main.Point {x: 1}", "main.Point {x: 1}"},
		{"net.IP", "net.IP len: 3, cap: 3, [1,2,3]", "net.IP len: 3, cap: 3, [1,2,3]"},
	}
	for _, c := range cases {
		if got := Readable(c.typ, c.in); got != c.want {
			t.Errorf("Readable(%s, %q) = %q, want %q", c.typ, c.in, got, c.want)
		}
	}
	if got := truncateValue(strings.Repeat("é", 1000)); len(got) > maxValueBytes+3 || !strings.HasSuffix(got, "…") {
		t.Fatalf("truncate %d", len(got))
	}
}

func TestDlvLoggingOnlyWhenEnabled(t *testing.T) {
	if strings.Contains(strings.Join(dlvArgs(false), " "), "--log") {
		t.Fatal("dlv must not log by default")
	}
	if !strings.Contains(strings.Join(dlvArgs(true), " "), "--log-output=dap") {
		t.Fatal("debug logging enables the dap log")
	}
	var batches []string
	b := &logBatcher{emit: func(s string) { batches = append(batches, s) }}
	for i := 0; i < logBatchLines+3; i++ {
		b.add("line")
	}
	b.flush()
	if len(batches) != 2 || strings.Count(batches[0], "\n") != logBatchLines-1 {
		t.Fatalf("batches %d", len(batches))
	}
	args := launchArguments(RunConfig{ActiveFilePath: "/w/cmd/main.go"}, "/w/cmd", "/tmp/x/__debug_bin")
	if args["output"] != "/tmp/x/__debug_bin" || args["program"] != "." || args["dlvCwd"] != "/w/cmd" || args["cwd"] != "/w/cmd" || args["mode"] != "debug" || args["maxStringLen"] != maxStringLen || args["outputMode"] != "remote" {
		t.Fatalf("launch args %v", args)
	}
	if args := launchArguments(RunConfig{ActiveFilePath: "/w/pkg/a_test.go"}, "/w/pkg", "x"); args["mode"] != "test" || args["program"] != "." {
		t.Fatalf("test file launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "TestRows", TestRow: "a b", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if args["mode"] != "test" || args["program"] != "." || !reflect.DeepEqual(args["args"], []string{"-test.run", "^TestRows$/^a_b$", "-test.v"}) {
		t.Fatalf("test launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "TestMatrix", TestRow: "alpha/step1", TestPattern: `^TestMatrix$/^(?:alpha|beta)$/^step1$`, WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if args["mode"] != "test" || args["program"] != "." || !reflect.DeepEqual(args["args"], []string{"-test.run", `^TestMatrix$/^(?:alpha|beta)$/^step1$`, "-test.v"}) {
		t.Fatalf("caret pattern launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "BenchmarkEncode", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if args["mode"] != "test" || args["program"] != "." || !reflect.DeepEqual(args["args"], []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$", "-test.benchmem", "-test.v"}) {
		t.Fatalf("top-level benchmark launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "BenchmarkEncode", TestRow: "small payload", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if args["mode"] != "test" || args["program"] != "." || !reflect.DeepEqual(args["args"], []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^small_payload$", "-test.benchmem", "-test.v"}) {
		t.Fatalf("sub-benchmark launch args %v", args)
	}
	args = launchArguments(RunConfig{TestPattern: "^BenchmarkEncode$/^v2$", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if args["mode"] != "test" || args["program"] != "." || !reflect.DeepEqual(args["args"], []string{"-test.run", "^$", "-test.bench", "^BenchmarkEncode$/^v2$", "-test.benchmem", "-test.v"}) {
		t.Fatalf("benchmark pattern launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "TestEncode", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if !reflect.DeepEqual(args["args"], []string{"-test.run", "^TestEncode$", "-test.v"}) {
		t.Fatalf("normal test launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "FuzzEncode", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if !reflect.DeepEqual(args["args"], []string{"-test.run", "^FuzzEncode$", "-test.v"}) {
		t.Fatalf("fuzz launch args %v", args)
	}
	args = launchArguments(RunConfig{Test: "Benchmarklower", WorkingDirectory: "/w/pkg"}, "/w/pkg", "/tmp/x/__debug_bin")
	if !reflect.DeepEqual(args["args"], []string{"-test.run", "^Benchmarklower$", "-test.v"}) {
		t.Fatalf("non-benchmark helper launch args %v", args)
	}
}

func TestAttachRunConfigAndArguments(t *testing.T) {
	var localCfg RunConfig
	if err := json.Unmarshal([]byte(`{"attachPid":4242,"remoteAddr":""}`), &localCfg); err != nil {
		t.Fatalf("unmarshal local attach config: %v", err)
	}
	if localCfg.AttachPID != 4242 || localCfg.RemoteAddr != "" {
		t.Fatalf("unexpected localCfg: %+v", localCfg)
	}
	localArgs := attachArguments(localCfg)
	if localArgs["mode"] != "local" || localArgs["processId"] != 4242 || localArgs["stackTraceDepth"] != stackTraceLevels {
		t.Fatalf("unexpected local attach args: %+v", localArgs)
	}

	var remoteCfg RunConfig
	if err := json.Unmarshal([]byte(`{"remoteAddr":"127.0.0.1:2345"}`), &remoteCfg); err != nil {
		t.Fatalf("unmarshal remote attach config: %v", err)
	}
	if remoteCfg.RemoteAddr != "127.0.0.1:2345" || remoteCfg.AttachPID != 0 {
		t.Fatalf("unexpected remoteCfg: %+v", remoteCfg)
	}
	remoteArgs := attachArguments(remoteCfg)
	if remoteArgs["mode"] != "remote" || remoteArgs["processId"] != nil || remoteArgs["maxStringLen"] != maxStringLen {
		t.Fatalf("unexpected remote attach args: %+v", remoteArgs)
	}

	c, f := pipeClient(t)
	c.attached = true
	detachCh := make(chan bool, 1)
	go func() {
		m, err := dap.ReadProtocolMessage(f.r)
		if err != nil {
			return
		}
		if d, ok := m.(*dap.DisconnectRequest); ok && d.Arguments != nil {
			detachCh <- d.Arguments.TerminateDebuggee
			f.respond(d, `{}`)
		}
	}()
	c.Stop()
	select {
	case term := <-detachCh:
		if term {
			t.Fatal("attached client Stop() must send TerminateDebuggee=false")
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for disconnect request")
	}
}

func TestListDebuggableProcesses(t *testing.T) {
	samplePS := strings.Join([]string{
		"    1 /sbin/launchd /sbin/launchd",
		"  300 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
		"  450 /Users/dev/go/bin/gopls /Users/dev/go/bin/gopls serve",
		"  451 /Users/dev/go/bin/dlv /Users/dev/go/bin/dlv dap --listen=127.0.0.1:0",
		"  500 /Applications/GoLensApp.app/Contents/MacOS/GoLensApp /Applications/GoLensApp.app/Contents/MacOS/GoLensApp",
		" 1200 /usr/bin/git /usr/bin/git status",
		" 2500 /Users/dev/project/bin/api-server /Users/dev/project/bin/api-server --port 8080",
		" 3100 /var/folders/xx/go-build123/b001/exe/main /var/folders/xx/go-build123/b001/exe/main",
	}, "\n")
	parsed := parseDebuggableProcesses(samplePS, 9999)
	if len(parsed) != 3 {
		t.Fatalf("expected 3 filtered processes, got %d: %+v", len(parsed), parsed)
	}
	if parsed[0].PID != 3100 || parsed[0].Name != "main" {
		t.Fatalf("expected go-build binary first, got %+v", parsed[0])
	}
	if parsed[1].PID != 2500 || parsed[1].Name != "api-server" {
		t.Fatalf("expected user binary second, got %+v", parsed[1])
	}
	if parsed[2].PID != 1200 || parsed[2].Name != "git" {
		t.Fatalf("expected /usr/bin/git last, got %+v", parsed[2])
	}

	hostComm := strings.Join([]string{
		" 4100 /Users/dev/Library/Containers/dev.golens.test/Data/tmp/kvservice/.git/kvservice-server",
		" 4200 /Users/dev/My Go Projects/server/bin/orders-daemon",
	}, "\n")
	hostArgs := strings.Join([]string{
		" 4100 ./.git/kvservice-server -daemon",
		" 4200 /Users/dev/My Go Projects/server/bin/orders-daemon --port 9000",
	}, "\n")
	hostParsed := parseHostDebuggableProcesses(hostComm, hostArgs, 9999)
	if len(hostParsed) != 2 {
		t.Fatalf("expected 2 host processes, got %d: %+v", len(hostParsed), hostParsed)
	}
	if hostParsed[0].Name != "orders-daemon" && hostParsed[1].Name != "orders-daemon" {
		t.Fatalf("expected orders-daemon with spaced path, got %+v", hostParsed)
	}
	if hostParsed[0].Name != "kvservice-server" && hostParsed[1].Name != "kvservice-server" {
		t.Fatalf("expected kvservice-server in Data/tmp, got %+v", hostParsed)
	}

	rawJSON := ListDebuggableProcesses()
	var live []DebugProcessInfo
	if err := json.Unmarshal([]byte(rawJSON), &live); err != nil {
		t.Fatalf("ListDebuggableProcesses returned invalid JSON: %v (%s)", err, rawJSON)
	}
	if len(live) > 100 {
		t.Fatalf("expected at most 100 processes, got %d", len(live))
	}
	for _, p := range live {
		if p.Name == "GoLensApp" || p.Name == "gopls" || p.Name == "dlv" {
			t.Fatalf("excluded process leaked into ListDebuggableProcesses: %+v", p)
		}
	}
}

func TestGoroutineGroupsRequestsStacksConcurrently(t *testing.T) {
	c, f := pipeClient(t)
	type result struct {
		data []byte
		err  error
	}
	done := make(chan result, 1)
	go func() {
		data, err := c.GoroutineGroups()
		done <- result{data, err}
	}()
	threadsReq := f.next().(*dap.ThreadsRequest)
	f.respond(threadsReq, `{"threads":[{"id":1,"name":"g1"},{"id":2,"name":"g2"},{"id":3,"name":"g3"}]}`)
	var reqs []*dap.StackTraceRequest
	for range 3 {
		reqs = append(reqs, f.next().(*dap.StackTraceRequest))
	}
	for i := len(reqs) - 1; i >= 0; i-- {
		name := "main.worker"
		if reqs[i].Arguments.ThreadId == 2 {
			name = "main.other"
		}
		f.respond(reqs[i], `{"stackFrames":[{"id":1,"name":"`+name+`","line":3}],"totalFrames":1}`)
	}
	var r result
	select {
	case r = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("GoroutineGroups did not finish")
	}
	if r.err != nil {
		t.Fatal(r.err)
	}
	var groups []GoroutineGroup
	if err := json.Unmarshal(r.data, &groups); err != nil {
		t.Fatal(err)
	}
	if len(groups) != 2 || groups[0].Top != "main.worker" || !reflect.DeepEqual(groups[0].ThreadIDs, []int{1, 3}) || groups[1].Top != "main.other" {
		t.Fatalf("groups %+v", groups)
	}
}
