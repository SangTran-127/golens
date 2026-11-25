package dap

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golens/core/bridge"
	"golens/core/fsutil"
	"golens/core/lsp"
	"golens/core/testutil"
	"golens/core/vmexec"

	"github.com/google/go-dap"
)

const (
	requestTimeout    = 10 * time.Second
	callTimeout       = 30 * time.Second
	logFlushEvery     = 200 * time.Millisecond
	logBatchLines     = 64
	maxValueBytes     = 1 << 10
	maxVariablesPage  = 200
	stackTraceLevels  = 50
	groupStackLevels  = 12
	maxGroupedThreads = 256
	maxStringLen      = 512
	maxArrayValues    = 64
)

var (
	errStopped = errors.New("debugger stopped")
	portRegex  = regexp.MustCompile(`DAP server listening at: 127\.0\.0\.1:(\d+)`)

	ExceptionFilters = []string{"unrecovered-panic", "runtime-fatal-throw"}
)

type Client struct {
	cmd      *exec.Cmd
	conn     io.ReadWriteCloser
	seq      int
	mu       sync.Mutex
	writeMu  sync.Mutex
	pending  map[int]chan dap.Message
	stopChan chan struct{}
	stopOnce sync.Once
	tempDir  string
	exited   chan struct{}
	readDone chan struct{}
	logs     *logBatcher
	onEvent  func(string, string)
	attached bool
	paused   atomic.Bool
	stopping atomic.Bool
	emitters sync.WaitGroup
	bpFiles  map[string]struct{}
	onStop   func()
	caps     dap.Capabilities
	runTo    *tempBreakpoint
	restored chan struct{}
	fnBps    bool
}

type tempBreakpoint struct {
	file string
	line int
	keep []Breakpoint
}

var (
	defaultClient *Client
	clientMu      sync.RWMutex
)

func GetClient() *Client {
	clientMu.RLock()
	defer clientMu.RUnlock()
	return defaultClient
}

func SetClient(c *Client) {
	clientMu.Lock()
	defer clientMu.Unlock()
	defaultClient = c
}

func clearClient(c *Client) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if defaultClient == c {
		defaultClient = nil
	}
}

func newClient(conn io.ReadWriteCloser) *Client {
	return &Client{
		seq:      1,
		conn:     conn,
		pending:  make(map[int]chan dap.Message),
		bpFiles:  make(map[string]struct{}),
		stopChan: make(chan struct{}),
		readDone: make(chan struct{}),
		onEvent: func(event, payload string) {
			if bridge.HasDebugEvent() {
				bridge.DebugEvent(event, payload)
			}
		},
	}
}

type logBatcher struct {
	mu    sync.Mutex
	lines []string
	timer *time.Timer
	emit  func(string)
}

func (b *logBatcher) add(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, line)
	if len(b.lines) >= logBatchLines {
		b.flushLocked()
		return
	}
	if b.timer == nil {
		b.timer = time.AfterFunc(logFlushEvery, b.flush)
	}
}

func (b *logBatcher) flush() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.flushLocked()
}

func (b *logBatcher) flushLocked() {
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	if len(b.lines) > 0 {
		b.emit(strings.Join(b.lines, "\n"))
		b.lines = b.lines[:0]
	}
}

type RunConfig struct {
	Name             string            `json:"name"`
	EnvVars          map[string]string `json:"envVars"`
	BuildFlags       string            `json:"buildFlags"`
	Args             string            `json:"args"`
	WorkingDirectory string            `json:"workingDirectory"`
	ActiveFilePath   string            `json:"activeFilePath"`
	DebugLogging     bool              `json:"debugLogging"`
	Test             string            `json:"test"`
	TestRow          string            `json:"testRow"`
	TestPattern      string            `json:"testPattern,omitempty"`
	AttachPID        int               `json:"attachPid,omitempty"`
	RemoteAddr       string            `json:"remoteAddr,omitempty"`
	SubstitutePath   []SubstitutePath  `json:"substitutePath,omitempty"`
}

type SubstitutePath struct {
	From string `json:"from"`
	To   string `json:"to"`
}

func attachArguments(config RunConfig) map[string]any {
	args := map[string]any{
		"stackTraceDepth": stackTraceLevels,
		"maxStringLen":    maxStringLen,
		"maxArrayValues":  maxArrayValues,
		"showPprofLabels": []string{"*"},
	}
	if config.RemoteAddr != "" {
		args["mode"] = "remote"
	} else {
		args["mode"] = "local"
		args["processId"] = config.AttachPID
	}
	if len(config.SubstitutePath) > 0 {
		args["substitutePath"] = config.SubstitutePath
	}
	return args
}

func dlvArgs(logging bool) []string {
	args := []string{"dap", "--listen=127.0.0.1:0"}
	if logging {
		args = append(args, "--log=true", "--log-output=dap")
	}
	return args
}

func launchArguments(config RunConfig, dir, output string) map[string]any {
	mode := "debug"
	if config.WorkingDirectory == "" && strings.HasSuffix(config.ActiveFilePath, "_test.go") {
		mode = "test"
	}
	args := map[string]any{
		"program":              ".",
		"mode":                 mode,
		"cwd":                  dir,
		"dlvCwd":               dir,
		"output":               output,
		"outputMode":           "remote",
		"stackTraceDepth":      stackTraceLevels,
		"maxStringLen":         maxStringLen,
		"maxArrayValues":       maxArrayValues,
		"showGlobalVariables":  false,
		"hideSystemGoroutines": false,
		"showPprofLabels":      []string{"*"},
	}
	if len(config.SubstitutePath) > 0 {
		args["substitutePath"] = config.SubstitutePath
	}
	if config.BuildFlags != "" {
		args["buildFlags"] = config.BuildFlags
	}
	if fields := fsutil.SplitArgs(config.Args); len(fields) > 0 {
		args["args"] = fields
	}
	if config.Test != "" || config.TestPattern != "" {
		args["mode"] = "test"
		args["program"] = "."
		_, args["args"] = testutil.DebugTestArgs(config.Test, config.TestRow, config.TestPattern)
	}
	if len(config.EnvVars) > 0 {
		args["env"] = config.EnvVars
	}
	return args
}

func findModuleRoot(startDir string) string {
	dir := filepath.Clean(startDir)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir || parent == "" {
			break
		}
		dir = parent
	}
	return startDir
}

func getHostGoModCache() string {
	if v := os.Getenv("GOMODCACHE"); v != "" {
		return v
	}
	if home, err := os.UserHomeDir(); err == nil {
		sandboxCache := filepath.Join(home, "Library", "Caches", "com.golens.app", "gomod")
		if _, err := os.Stat(sandboxCache); err == nil {
			return sandboxCache
		}
		return filepath.Join(home, "go", "pkg", "mod")
	}
	return "/go/pkg/mod"
}

func StartDebug(configJson string) error {
	if client := GetClient(); client != nil {
		client.Stop()
	}
	var config RunConfig
	if configJson != "" && configJson != "{}" {
		if err := json.Unmarshal([]byte(configJson), &config); err != nil {
			bridge.Debug(fmt.Sprintf("invalid run configuration: %v", err))
		}
	}
	if config.RemoteAddr != "" {
		conn, err := net.DialTimeout("tcp", config.RemoteAddr, 5*time.Second)
		if err != nil {
			return err
		}
		return attachRemote(conn, config, nil)
	}
	dir, note := fsutil.RunDir(lsp.GetActiveDir(), config.WorkingDirectory, config.ActiveFilePath)
	if note != "" {
		bridge.Log(note)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := bridge.DialSandboxVsockWithRetry(ctx, 2345, 10*time.Second)
	if err != nil {
		if bridge.CanFallbackToHost(err) {
			return startHostDebug(dir, config)
		}
		return fmt.Errorf("failed to connect to delve dap in micro-vm (vsock :2345): %w", err)
	}

	moduleRoot := findModuleRoot(dir)
	slug := vmexec.WorkspaceSlug(moduleRoot)
	guestModuleRoot := "/workspaces/" + slug

	relDir, err := filepath.Rel(moduleRoot, dir)
	if err != nil || relDir == "." {
		relDir = ""
	}
	guestCwd := guestModuleRoot
	if relDir != "" {
		guestCwd = filepath.Join(guestModuleRoot, relDir)
	}

	hostModCache := getHostGoModCache()
	guestModCache := "/cache/gomod"

	subs := []SubstitutePath{
		{From: moduleRoot, To: guestModuleRoot},
		{From: hostModCache, To: guestModCache},
	}
	config.SubstitutePath = append(subs, config.SubstitutePath...)

	client := newClient(conn)
	client.attached = config.AttachPID > 0
	SetClient(client)
	go client.readLoop()

	if err = client.initialize(); err != nil {
		client.Stop()
		return err
	}
	if config.AttachPID > 0 {
		rawAttachArgs, err := json.Marshal(attachArguments(config))
		if err != nil {
			client.Stop()
			return err
		}
		if _, err := client.SendRequestTimeout(&dap.AttachRequest{Request: client.NewRequest("attach"), Arguments: rawAttachArgs}, 30*time.Second); err != nil {
			client.Stop()
			return err
		}
		return nil
	}
	launch, err := json.Marshal(launchArguments(config, guestCwd, "/tmp/__debug_bin"))
	if err != nil {
		client.Stop()
		return err
	}
	if _, err := client.SendRequestTimeout(&dap.LaunchRequest{Request: client.NewRequest("launch"), Arguments: launch}, 2*time.Minute); err != nil {
		client.Stop()
		return err
	}
	return nil
}

func resolveHostDelvePath() (string, error) {
	if p, err := exec.LookPath("dlv"); err == nil && p != "" {
		return p, nil
	}
	var candidates []string
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		candidates = append(candidates, filepath.Join(home, "go", "bin", "dlv"))
	}
	candidates = append(candidates, "/opt/homebrew/bin/dlv", "/usr/local/bin/dlv", "/usr/local/go/bin/dlv")
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", errors.New("Delve (dlv) is not installed on this Mac. Run: go install github.com/go-delve/delve/cmd/dlv@latest")
}

func startHostDebug(dir string, config RunConfig) error {
	dlvPath, err := resolveHostDelvePath()
	if err != nil {
		return err
	}

	tempDir, err := os.MkdirTemp("", "golens-debug-*")
	if err != nil {
		return err
	}
	debugBin := filepath.Join(tempDir, fmt.Sprintf("golens_debug_%d", os.Getpid()))

	cmd := exec.Command(dlvPath, dlvArgs(config.DebugLogging)...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		_ = os.RemoveAll(tempDir)
		return err
	}
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		_ = os.RemoveAll(tempDir)
		return err
	}

	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()

	addrCh := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdoutPipe)
		sent := false
		for sc.Scan() {
			line := sc.Text()
			if !sent {
				if m := portRegex.FindStringSubmatch(line); len(m) >= 2 {
					addrCh <- "127.0.0.1:" + m[1]
					sent = true
				} else if idx := strings.Index(line, "DAP server listening at: "); idx >= 0 {
					addr := strings.TrimSpace(line[idx+len("DAP server listening at: "):])
					if addr != "" {
						addrCh <- addr
						sent = true
					}
				}
			}
		}
	}()

	cleanupFailedStart := func() {
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		select {
		case <-exited:
		case <-time.After(time.Second):
		}
		_ = os.Remove(debugBin)
		_ = os.RemoveAll(tempDir)
	}

	var addr string
	select {
	case addr = <-addrCh:
	case <-exited:
		cleanupFailedStart()
		msg := strings.TrimSpace(stderrBuf.String())
		if msg == "" {
			msg = "dlv exited before listening"
		}
		return fmt.Errorf("failed to start dlv dap: %s", msg)
	case <-time.After(10 * time.Second):
		cleanupFailedStart()
		return errors.New("timed out waiting for dlv dap listener")
	}

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		cleanupFailedStart()
		return err
	}

	client := newClient(conn)
	client.cmd = cmd
	client.exited = exited
	client.tempDir = tempDir
	attached := config.AttachPID > 0
	client.attached = attached
	client.onStop = func() {
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			if attached {
				select {
				case <-exited:
				case <-time.After(time.Second):
					_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
				}
			} else {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
		}
		_ = os.Remove(debugBin)
		_ = os.RemoveAll(tempDir)
	}
	SetClient(client)
	go client.readLoop()

	if err = client.initialize(); err != nil {
		client.Stop()
		return err
	}
	if config.AttachPID > 0 {
		rawAttachArgs, err := json.Marshal(attachArguments(config))
		if err != nil {
			client.Stop()
			return err
		}
		if _, err := client.SendRequestTimeout(&dap.AttachRequest{Request: client.NewRequest("attach"), Arguments: rawAttachArgs}, 30*time.Second); err != nil {
			client.Stop()
			return err
		}
		return nil
	}
	launch, err := json.Marshal(launchArguments(config, dir, debugBin))
	if err != nil {
		client.Stop()
		return err
	}
	if _, err := client.SendRequestTimeout(&dap.LaunchRequest{Request: client.NewRequest("launch"), Arguments: launch}, 2*time.Minute); err != nil {
		client.Stop()
		return err
	}
	return nil
}

func StartRemoteAttach(conn io.ReadWriteCloser, config RunConfig, onStop func()) error {
	if client := GetClient(); client != nil {
		client.Stop()
	}
	if config.RemoteAddr == "" {
		config.RemoteAddr = "remote"
	}
	return attachRemote(conn, config, onStop)
}

func attachRemote(conn io.ReadWriteCloser, config RunConfig, onStop func()) error {
	client := newClient(conn)
	client.attached = true
	client.onStop = onStop
	SetClient(client)
	go client.readLoop()

	if err := client.initialize(); err != nil {
		client.Stop()
		return err
	}
	rawAttachArgs, err := json.Marshal(attachArguments(config))
	if err != nil {
		client.Stop()
		return err
	}
	if _, err := client.SendRequestTimeout(&dap.AttachRequest{Request: client.NewRequest("attach"), Arguments: rawAttachArgs}, 30*time.Second); err != nil {
		client.Stop()
		return err
	}
	return nil
}

func (c *Client) initialize() error {
	respMsg, err := c.SendRequest(&dap.InitializeRequest{
		Request: c.NewRequest("initialize"),
		Arguments: dap.InitializeRequestArguments{
			ClientID: "golens", AdapterID: "go", LinesStartAt1: true, ColumnsStartAt1: true, PathFormat: "path",
			SupportsVariableType: true,
		},
	})
	if err != nil {
		return err
	}
	if resp, ok := respMsg.(*dap.InitializeResponse); ok {
		c.mu.Lock()
		c.caps = resp.Body
		c.mu.Unlock()
	}
	return nil
}

func (c *Client) Capabilities() dap.Capabilities {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.caps
}

func (c *Client) ConfigurationDone() error {
	if err := c.SetExceptionBreakpoints(ExceptionFilters); err != nil {
		bridge.Debug("exception breakpoints: " + err.Error())
	}
	_, err := c.SendRequest(&dap.ConfigurationDoneRequest{Request: c.NewRequest("configurationDone")})
	return err
}

func (c *Client) Stop() {
	first := false
	c.stopOnce.Do(func() { first = true })
	if !first {
		return
	}
	c.stopping.Store(true)
	if c.conn != nil {
		c.sendDisconnect()
	}
	close(c.stopChan)
	if c.conn != nil {
		_ = c.conn.Close()
		select {
		case <-c.readDone:
		case <-time.After(2 * time.Second):
		}
	}
	c.emitters.Wait()
	c.mu.Lock()
	c.pending = make(map[int]chan dap.Message)
	c.mu.Unlock()
	if c.cmd != nil && c.cmd.Process != nil {
		select {
		case <-c.exited:
		case <-time.After(2 * time.Second):
			_ = c.cmd.Process.Kill()
			<-c.exited
		}
	}
	if c.logs != nil {
		c.logs.flush()
	}
	if c.tempDir != "" {
		_ = os.RemoveAll(c.tempDir)
	}
	clearClient(c)
	if c.onStop != nil {
		c.onStop()
	}
}

func (c *Client) sendDisconnect() {
	if c.attached && c.cmd != nil && c.paused.Load() {
		c.mu.Lock()
		files := make([]string, 0, len(c.bpFiles))
		for f := range c.bpFiles {
			files = append(files, f)
		}
		c.bpFiles = make(map[string]struct{})
		fnBps := c.fnBps
		c.fnBps = false
		c.mu.Unlock()
		_, _ = c.SendRequestTimeout(&dap.SetExceptionBreakpointsRequest{
			Request:   c.NewRequest("setExceptionBreakpoints"),
			Arguments: dap.SetExceptionBreakpointsArguments{Filters: []string{}},
		}, 500*time.Millisecond)
		for _, f := range files {
			_, _ = c.SendRequestTimeout(&dap.SetBreakpointsRequest{
				Request:   c.NewRequest("setBreakpoints"),
				Arguments: setBreakpointsArguments(f, nil),
			}, 500*time.Millisecond)
		}
		if fnBps {
			_, _ = c.SendRequestTimeout(&dap.SetFunctionBreakpointsRequest{
				Request:   c.NewRequest("setFunctionBreakpoints"),
				Arguments: dap.SetFunctionBreakpointsArguments{Breakpoints: []dap.FunctionBreakpoint{}},
			}, 500*time.Millisecond)
		}
		_, _ = c.SendRequestTimeout(&dap.ContinueRequest{
			Request:   c.NewRequest("continue"),
			Arguments: dap.ContinueArguments{ThreadId: 1},
		}, 500*time.Millisecond)
		time.Sleep(60 * time.Millisecond)
	}
	terminate := !c.attached
	timeout := time.Second
	if c.attached {
		timeout = 3 * time.Second
	}
	done := make(chan struct{})
	go func() {
		_, _ = c.SendRequestTimeout(&dap.DisconnectRequest{
			Request:   c.NewRequest("disconnect"),
			Arguments: &dap.DisconnectArguments{TerminateDebuggee: terminate},
		}, timeout)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
	}
}

func (c *Client) NewRequest(command string) dap.Request {
	c.mu.Lock()
	defer c.mu.Unlock()
	req := dap.Request{ProtocolMessage: dap.ProtocolMessage{Seq: c.seq, Type: "request"}, Command: command}
	c.seq++
	return req
}

func (c *Client) SendRequest(req dap.Message) (dap.Message, error) {
	return c.SendRequestTimeout(req, requestTimeout)
}

func (c *Client) pendingCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.pending)
}

func (c *Client) SendRequestTimeout(req dap.Message, timeout time.Duration) (dap.Message, error) {
	data, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	seq := req.GetSeq()
	ch := make(chan dap.Message, 1)
	c.mu.Lock()
	select {
	case <-c.stopChan:
		c.mu.Unlock()
		return nil, errStopped
	default:
	}
	c.pending[seq] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, seq)
		c.mu.Unlock()
	}()

	var buf bytes.Buffer
	_, _ = fmt.Fprintf(&buf, "Content-Length: %d\r\n\r\n", len(data))
	buf.Write(data)
	c.writeMu.Lock()
	_, err = c.conn.Write(buf.Bytes())
	c.writeMu.Unlock()
	if err != nil {
		return nil, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case resp := <-ch:
		if r, ok := resp.(dap.ResponseMessage); ok && !r.GetResponse().Success {
			msg := r.GetResponse().Message
			if er, ok := resp.(*dap.ErrorResponse); ok && er.Body.Error != nil && er.Body.Error.Format != "" {
				msg = er.Body.Error.Format
			}
			return resp, fmt.Errorf("%s", msg)
		}
		return resp, nil
	case <-c.stopChan:
		return nil, errStopped
	case <-timer.C:
		return nil, fmt.Errorf("timeout waiting for DAP response")
	}
}

func (c *Client) readLoop() {
	defer close(c.readDone)
	reader := bufio.NewReader(c.conn)
	for {
		msg, err := dap.ReadProtocolMessage(reader)
		if err != nil {
			var decodeErr *dap.DecodeProtocolMessageFieldError
			if errors.As(err, &decodeErr) {
				continue
			}
			c.handleEvent(&dap.TerminatedEvent{Event: dap.Event{ProtocolMessage: dap.ProtocolMessage{Type: "event"}, Event: "terminated"}})
			return
		}
		switch m := msg.(type) {
		case dap.ResponseMessage:
			c.mu.Lock()
			ch, ok := c.pending[m.GetResponse().RequestSeq]
			delete(c.pending, m.GetResponse().RequestSeq)
			c.mu.Unlock()
			if ok {
				ch <- m
			}
		case dap.EventMessage:
			c.handleEvent(m)
		}
	}
}

func (c *Client) handleEvent(event dap.EventMessage) {
	switch event.GetEvent().Event {
	case "stopped":
		c.paused.Store(true)
		c.finishRunTo()
		if stopped, ok := event.(*dap.StoppedEvent); ok && stopped.Body.ThreadId == 0 {
			if !c.stopping.Load() {
				c.emitters.Add(1)
				go c.emitStopped(stopped)
			}
			return
		}
	case "continued":
		c.paused.Store(false)
	case "exited", "terminated":
		c.finishRunTo()
	}
	payload, err := json.Marshal(event)
	if err == nil && c.onEvent != nil {
		c.onEvent(event.GetEvent().Event, string(payload))
	}
}

func (c *Client) Continue(threadId int) error {
	c.awaitRestore()
	_, err := c.SendRequest(&dap.ContinueRequest{Request: c.NewRequest("continue"), Arguments: dap.ContinueArguments{ThreadId: threadId}})
	if err != nil {
		return err
	}
	c.paused.Store(false)
	if c.onEvent != nil {
		c.onEvent("continued", "{}")
	}
	return nil
}

func (c *Client) emitStopped(event *dap.StoppedEvent) {
	defer c.emitters.Done()
	if c.stopping.Load() {
		return
	}
	event.Body.ThreadId = c.userGoroutine()
	if c.stopping.Load() {
		return
	}
	if payload, err := json.Marshal(event); err == nil && c.onEvent != nil {
		c.onEvent("stopped", string(payload))
	}
}

func threadFunction(name string) string {
	if i := strings.Index(name, "] "); i >= 0 {
		name = name[i+2:]
	}
	return strings.TrimSpace(name)
}

func (c *Client) userGoroutine() int {
	threads, err := c.threads()
	if err != nil || len(threads) == 0 {
		return 1
	}
	for _, t := range threads {
		if fn := threadFunction(t.Name); fn != "" && !strings.HasPrefix(fn, "runtime.") {
			return t.Id
		}
	}
	return threads[0].Id
}

func (c *Client) Pause(threadId int) error {
	_, err := c.SendRequest(&dap.PauseRequest{Request: c.NewRequest("pause"), Arguments: dap.PauseArguments{ThreadId: threadId}})
	return err
}

func withTemporaryLine(keep []Breakpoint, line int) []Breakpoint {
	out := make([]Breakpoint, 0, len(keep)+1)
	for _, b := range keep {
		if b.Line != line {
			out = append(out, b)
		}
	}
	return append(out, Breakpoint{Line: line})
}

func (c *Client) RunToLine(file string, line int, keep []Breakpoint, threadId int) error {
	c.awaitRestore()
	c.mu.Lock()
	c.runTo = &tempBreakpoint{file: file, line: line, keep: keep}
	c.mu.Unlock()
	resp, err := c.setBreakpoints(file, withTemporaryLine(keep, line))
	if err == nil && (len(resp) == 0 || !resp[len(resp)-1].Verified) {
		err = fmt.Errorf("line %d has no code to stop at", line)
	}
	if err != nil {
		c.mu.Lock()
		t := c.runTo
		c.runTo = nil
		c.mu.Unlock()
		if t != nil {
			_, _ = c.setBreakpoints(file, t.keep)
		}
		return err
	}
	return c.Continue(threadId)
}

func (c *Client) finishRunTo() {
	c.mu.Lock()
	t := c.runTo
	c.runTo = nil
	if t == nil {
		c.mu.Unlock()
		return
	}
	done := make(chan struct{})
	c.restored = done
	c.mu.Unlock()
	go func() {
		defer close(done)
		_, _ = c.setBreakpoints(t.file, t.keep)
	}()
}

func (c *Client) awaitRestore() {
	c.mu.Lock()
	done := c.restored
	c.mu.Unlock()
	if done == nil {
		return
	}
	select {
	case <-done:
	case <-c.stopChan:
	case <-time.After(requestTimeout):
	}
}

type FunctionBreakpoint struct {
	Name      string `json:"name"`
	Condition string `json:"condition,omitempty"`
}

func ParseFunctionBreakpoints(raw string) ([]FunctionBreakpoint, error) {
	var bps []FunctionBreakpoint
	if err := json.Unmarshal([]byte(raw), &bps); err != nil {
		return nil, err
	}
	return bps, nil
}

func (c *Client) SetFunctionBreakpoints(bps []FunctionBreakpoint) ([]byte, error) {
	args := dap.SetFunctionBreakpointsArguments{Breakpoints: []dap.FunctionBreakpoint{}}
	for _, b := range bps {
		if name := strings.TrimSpace(b.Name); name != "" {
			args.Breakpoints = append(args.Breakpoints, dap.FunctionBreakpoint{Name: name, Condition: strings.TrimSpace(b.Condition)})
		}
	}
	c.mu.Lock()
	hadAny := c.fnBps
	c.mu.Unlock()
	if len(args.Breakpoints) == 0 && !hadAny {
		return []byte("[]"), nil
	}
	if !c.Capabilities().SupportsFunctionBreakpoints {
		return nil, errors.New("this debugger doesn't support function breakpoints")
	}
	c.mu.Lock()
	c.fnBps = len(args.Breakpoints) > 0
	c.mu.Unlock()
	respMsg, err := c.SendRequest(&dap.SetFunctionBreakpointsRequest{Request: c.NewRequest("setFunctionBreakpoints"), Arguments: args})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.SetFunctionBreakpointsResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	return json.Marshal(resp.Body.Breakpoints)
}

func (c *Client) StepOver(threadId int) error {
	c.awaitRestore()
	_, err := c.SendRequest(&dap.NextRequest{Request: c.NewRequest("next"), Arguments: dap.NextArguments{ThreadId: threadId}})
	return err
}

func (c *Client) StepInto(threadId int) error {
	c.awaitRestore()
	_, err := c.SendRequest(&dap.StepInRequest{Request: c.NewRequest("stepIn"), Arguments: dap.StepInArguments{ThreadId: threadId}})
	return err
}

func (c *Client) StepOut(threadId int) error {
	c.awaitRestore()
	_, err := c.SendRequest(&dap.StepOutRequest{Request: c.NewRequest("stepOut"), Arguments: dap.StepOutArguments{ThreadId: threadId}})
	return err
}

func (c *Client) threads() ([]dap.Thread, error) {
	respMsg, err := c.SendRequest(&dap.ThreadsRequest{Request: c.NewRequest("threads")})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.ThreadsResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	return resp.Body.Threads, nil
}

func (c *Client) GetThreads() ([]byte, error) {
	t, err := c.threads()
	if err != nil {
		return nil, err
	}
	return json.Marshal(t)
}

var callRegex = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_]*)\s*\(`)

var nonCalls = map[string]bool{
	"len": true, "cap": true, "complex": true, "real": true, "imag": true,
	"int": true, "int8": true, "int16": true, "int32": true, "int64": true,
	"uint": true, "uint8": true, "uint16": true, "uint32": true, "uint64": true, "uintptr": true,
	"float32": true, "float64": true, "string": true, "byte": true, "rune": true, "bool": true,
	"func": true,
}

func stripStrings(expr string) string {
	var b strings.Builder
	var quote rune
	escaped := false
	for _, r := range expr {
		switch {
		case quote != 0:
			if escaped {
				escaped = false
			} else if r == '\\' && quote != '`' {
				escaped = true
			} else if r == quote {
				quote = 0
			}
			b.WriteRune(' ')
		case r == '"' || r == '\'' || r == '`':
			quote = r
			b.WriteRune(' ')
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func HasCall(expr string) bool {
	code := stripStrings(expr)
	for _, m := range callRegex.FindAllStringSubmatchIndex(code, -1) {
		name := code[m[2]:m[3]]
		if nonCalls[name] {
			continue
		}
		return true
	}
	return false
}

func evaluateArguments(expression string, frameId int) dap.EvaluateArguments {
	expr := strings.TrimSpace(expression)
	if HasCall(expr) && !strings.HasPrefix(expr, "call ") {
		return dap.EvaluateArguments{Expression: "call " + expr, FrameId: frameId, Context: "repl"}
	}
	return dap.EvaluateArguments{Expression: expr, FrameId: frameId, Context: "watch"}
}

func (c *Client) Evaluate(expression string, frameId int) (string, error) {
	args := evaluateArguments(expression, frameId)
	timeout := requestTimeout
	if args.Context == "repl" {
		timeout = callTimeout
	}
	respMsg, err := c.SendRequestTimeout(&dap.EvaluateRequest{Request: c.NewRequest("evaluate"), Arguments: args}, timeout)
	if err != nil {
		return "", err
	}
	resp, ok := respMsg.(*dap.EvaluateResponse)
	if !ok {
		return "", fmt.Errorf("unexpected response type")
	}
	return truncateValue(Readable(resp.Body.Type, resp.Body.Result)), nil
}

type WatchEvalResult struct {
	Value              string `json:"value"`
	Type               string `json:"type"`
	VariablesReference int    `json:"variablesReference"`
	Error              string `json:"error,omitempty"`
}

func (c *Client) EvaluateWatch(expression string, frameId int) WatchEvalResult {
	args := evaluateArguments(expression, frameId)
	timeout := requestTimeout
	if args.Context == "repl" {
		timeout = callTimeout
	}
	respMsg, err := c.SendRequestTimeout(&dap.EvaluateRequest{Request: c.NewRequest("evaluate"), Arguments: args}, timeout)
	if err != nil {
		return WatchEvalResult{Error: err.Error()}
	}
	resp, ok := respMsg.(*dap.EvaluateResponse)
	if !ok {
		return WatchEvalResult{Error: "unexpected response type"}
	}
	return WatchEvalResult{
		Value:              truncateValue(Readable(resp.Body.Type, resp.Body.Result)),
		Type:               resp.Body.Type,
		VariablesReference: resp.Body.VariablesReference,
	}
}

type Breakpoint struct {
	Line         int    `json:"line"`
	Condition    string `json:"condition,omitempty"`
	HitCondition string `json:"hitCondition,omitempty"`
	LogMessage   string `json:"logMessage,omitempty"`
}

func ParseBreakpoints(raw string) ([]Breakpoint, error) {
	var bps []Breakpoint
	if err := json.Unmarshal([]byte(raw), &bps); err == nil {
		return bps, nil
	}
	bps = nil
	var lines []int
	if err := json.Unmarshal([]byte(raw), &lines); err != nil {
		return nil, err
	}
	for _, l := range lines {
		bps = append(bps, Breakpoint{Line: l})
	}
	return bps, nil
}

func setBreakpointsArguments(file string, bps []Breakpoint) dap.SetBreakpointsArguments {
	src := make([]dap.SourceBreakpoint, len(bps))
	for i, b := range bps {
		src[i] = dap.SourceBreakpoint{Line: b.Line, Condition: strings.TrimSpace(b.Condition), HitCondition: strings.TrimSpace(b.HitCondition), LogMessage: b.LogMessage}
	}
	return dap.SetBreakpointsArguments{Source: dap.Source{Path: file}, Breakpoints: src}
}

func anyBreakpointVerified(bps []dap.Breakpoint) bool {
	for _, bp := range bps {
		if bp.Verified {
			return true
		}
	}
	return false
}

func alternateSymlinkPath(file string) string {
	if resolved, err := filepath.EvalSymlinks(file); err == nil && resolved != "" && resolved != file {
		return resolved
	}
	if strings.HasPrefix(file, "/private/") {
		return strings.TrimPrefix(file, "/private")
	}
	return ""
}

func (c *Client) SetBreakpoints(file string, bps []Breakpoint) ([]byte, error) {
	c.mu.Lock()
	if t := c.runTo; t != nil && t.file == file {
		t.keep = bps
		bps = withTemporaryLine(bps, t.line)
	}
	c.mu.Unlock()
	resp, err := c.setBreakpoints(file, bps)
	if err != nil {
		return nil, err
	}
	return json.Marshal(resp)
}

func (c *Client) setBreakpoints(file string, bps []Breakpoint) ([]dap.Breakpoint, error) {
	c.mu.Lock()
	if c.bpFiles != nil {
		if len(bps) > 0 {
			c.bpFiles[file] = struct{}{}
			if alt := alternateSymlinkPath(file); alt != "" && alt != file {
				c.bpFiles[alt] = struct{}{}
			}
		} else {
			delete(c.bpFiles, file)
			if alt := alternateSymlinkPath(file); alt != "" && alt != file {
				delete(c.bpFiles, alt)
			}
		}
	}
	c.mu.Unlock()
	respMsg, err := c.SendRequest(&dap.SetBreakpointsRequest{Request: c.NewRequest("setBreakpoints"), Arguments: setBreakpointsArguments(file, bps)})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.SetBreakpointsResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	if len(bps) > 0 && !anyBreakpointVerified(resp.Body.Breakpoints) {
		if alt := alternateSymlinkPath(file); alt != "" && alt != file {
			if altMsg, altErr := c.SendRequest(&dap.SetBreakpointsRequest{Request: c.NewRequest("setBreakpoints"), Arguments: setBreakpointsArguments(alt, bps)}); altErr == nil {
				if altResp, ok := altMsg.(*dap.SetBreakpointsResponse); ok && anyBreakpointVerified(altResp.Body.Breakpoints) {
					resp = altResp
				}
			}
		}
	}
	return resp.Body.Breakpoints, nil
}

func (c *Client) SetExceptionBreakpoints(filters []string) error {
	_, err := c.SendRequest(&dap.SetExceptionBreakpointsRequest{Request: c.NewRequest("setExceptionBreakpoints"), Arguments: dap.SetExceptionBreakpointsArguments{Filters: filters}})
	return err
}

func (c *Client) ExceptionInfo(threadId int) ([]byte, error) {
	respMsg, err := c.SendRequest(&dap.ExceptionInfoRequest{Request: c.NewRequest("exceptionInfo"), Arguments: dap.ExceptionInfoArguments{ThreadId: threadId}})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.ExceptionInfoResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	return json.Marshal(resp.Body)
}

func (c *Client) SetVariable(variablesReference int, name, value string) ([]byte, error) {
	respMsg, err := c.SendRequest(&dap.SetVariableRequest{Request: c.NewRequest("setVariable"), Arguments: dap.SetVariableArguments{VariablesReference: variablesReference, Name: name, Value: value}})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.SetVariableResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	resp.Body.Value = truncateValue(resp.Body.Value)
	return json.Marshal(resp.Body)
}

func (c *Client) stackTrace(threadId, levels int) ([]dap.StackFrame, error) {
	respMsg, err := c.SendRequest(&dap.StackTraceRequest{Request: c.NewRequest("stackTrace"), Arguments: dap.StackTraceArguments{ThreadId: threadId, Levels: levels}})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.StackTraceResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	return resp.Body.StackFrames, nil
}

func (c *Client) GetStackTrace(threadId int) ([]byte, error) {
	frames, err := c.stackTrace(threadId, stackTraceLevels)
	if err != nil {
		return nil, err
	}
	return json.Marshal(frames)
}

func (c *Client) GetScopes(frameId int) ([]byte, error) {
	respMsg, err := c.SendRequest(&dap.ScopesRequest{Request: c.NewRequest("scopes"), Arguments: dap.ScopesArguments{FrameId: frameId}})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.ScopesResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	return json.Marshal(resp.Body.Scopes)
}

func truncateValue(v string) string {
	if len(v) <= maxValueBytes {
		return v
	}
	cut := maxValueBytes
	for cut > 0 && v[cut]&0xC0 == 0x80 {
		cut--
	}
	return v[:cut] + "…"
}

func (c *Client) variables(ref int) ([]dap.Variable, error) {
	respMsg, err := c.SendRequest(&dap.VariablesRequest{Request: c.NewRequest("variables"), Arguments: dap.VariablesArguments{VariablesReference: ref, Count: maxVariablesPage}})
	if err != nil {
		return nil, err
	}
	resp, ok := respMsg.(*dap.VariablesResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response type")
	}
	vars := resp.Body.Variables
	if len(vars) > maxVariablesPage {
		vars = vars[:maxVariablesPage]
	}
	for i := range vars {
		vars[i].Value = truncateValue(Readable(vars[i].Type, vars[i].Value))
	}
	return vars, nil
}

func (c *Client) GetVariables(variablesReference int) ([]byte, error) {
	vars, err := c.variables(variablesReference)
	if err != nil {
		return nil, err
	}
	return json.Marshal(vars)
}

type GoroutineGroup struct {
	Count          int      `json:"count"`
	Top            string   `json:"top"`
	Location       string   `json:"location"`
	Frames         []string `json:"frames"`
	FrameLocations []string `json:"frameLocations"`
	ThreadIDs      []int    `json:"threadIds"`
	Names          []string `json:"names"`
	Labels         []string `json:"labels"`
	System         bool     `json:"system"`
}

func frameKey(f dap.StackFrame) string {
	file := ""
	if f.Source != nil {
		file = f.Source.Path
	}
	return fmt.Sprintf("%s %s:%d", f.Name, file, f.Line)
}

func IsRuntimeFrame(name string) bool {
	return strings.HasPrefix(name, "runtime.") || strings.HasPrefix(name, "runtime/") || strings.HasPrefix(name, "internal/")
}

func ThreadLabels(name string) string {
	open := strings.Index(name, "[Go ")
	if open < 0 {
		return ""
	}
	closing := strings.Index(name[open:], "]")
	if closing < 0 {
		return ""
	}
	fields := strings.Fields(name[open+len("[Go ") : open+closing])
	if len(fields) < 2 {
		return ""
	}
	return strings.Join(fields[1:], " ")
}

func GroupByStack(threads []dap.Thread, stacks map[int][]dap.StackFrame) []GoroutineGroup {
	index := map[string]int{}
	var groups []GoroutineGroup
	for _, t := range threads {
		frames := stacks[t.Id]
		keys := make([]string, len(frames))
		for i, f := range frames {
			keys[i] = frameKey(f)
		}
		k := strings.Join(keys, "\n")
		gi, ok := index[k]
		if !ok {
			g := GoroutineGroup{Frames: make([]string, len(frames)), FrameLocations: make([]string, len(frames)), System: len(frames) > 0}
			for i, f := range frames {
				g.Frames[i] = f.Name
				if f.Source != nil && f.Source.Path != "" {
					g.FrameLocations[i] = fmt.Sprintf("%s:%d", f.Source.Path, f.Line)
				}
				if !IsRuntimeFrame(f.Name) {
					g.System = false
				}
			}
			if len(frames) > 0 {
				f := frames[0]
				for _, cand := range frames {
					if !IsRuntimeFrame(cand.Name) {
						f = cand
						break
					}
				}
				g.Top = f.Name
				if f.Source != nil {
					g.Location = fmt.Sprintf("%s:%d", filepath.Base(f.Source.Path), f.Line)
				}
			}
			groups = append(groups, g)
			gi = len(groups) - 1
			index[k] = gi
		}
		groups[gi].Count++
		groups[gi].ThreadIDs = append(groups[gi].ThreadIDs, t.Id)
		groups[gi].Names = append(groups[gi].Names, t.Name)
		groups[gi].Labels = append(groups[gi].Labels, ThreadLabels(t.Name))
	}
	return groups
}

func FormatGoroutineDump(groups []GoroutineGroup, root string) string {
	ordered := append([]GoroutineGroup(nil), groups...)
	sort.SliceStable(ordered, func(i, j int) bool {
		if ordered[i].System != ordered[j].System {
			return !ordered[i].System
		}
		return ordered[i].Count > ordered[j].Count
	})
	total := 0
	for _, g := range ordered {
		total += g.Count
	}
	var b strings.Builder
	noun := func(n int, word string) string {
		if n == 1 {
			return fmt.Sprintf("%d %s", n, word)
		}
		return fmt.Sprintf("%d %ss", n, word)
	}
	fmt.Fprintf(&b, "Goroutine dump: %s, %s\n", noun(total, "goroutine"), noun(len(ordered), "distinct stack"))
	b.WriteString("Frames marked with > are in this project; the others are in the Go runtime, the standard library or dependencies.\n")
	root = strings.TrimSuffix(root, "/")
	inProject := func(location string) bool {
		return root != "" && strings.HasPrefix(location, root+"/")
	}
	for _, g := range ordered {
		ids := make([]string, len(g.ThreadIDs))
		for i, id := range g.ThreadIDs {
			ids[i] = strconv.Itoa(id)
			if i < len(g.Labels) && g.Labels[i] != "" {
				ids[i] += " [" + g.Labels[i] + "]"
			}
		}
		kind := ""
		if g.System {
			kind = " (system)"
		}
		fmt.Fprintf(&b, "\n%s%s: %s\n", noun(g.Count, "goroutine"), kind, strings.Join(ids, ", "))
		for i, name := range g.Frames {
			location := ""
			if i < len(g.FrameLocations) {
				location = g.FrameLocations[i]
			}
			marker := "  "
			if inProject(location) {
				marker = "> "
			}
			b.WriteString(marker + name + "\n")
			if location != "" {
				b.WriteString("      " + location + "\n")
			}
		}
	}
	return b.String()
}

const groupStackConcurrency = 8

func (c *Client) goroutineStacks(levels int) ([]dap.Thread, map[int][]dap.StackFrame, error) {
	threads, err := c.threads()
	if err != nil {
		return nil, nil, err
	}
	if len(threads) > maxGroupedThreads {
		threads = threads[:maxGroupedThreads]
	}
	frames := make([][]dap.StackFrame, len(threads))
	errs := make([]error, len(threads))
	sem := make(chan struct{}, groupStackConcurrency)
	var stopped atomic.Bool
	var wg sync.WaitGroup
	for i, t := range threads {
		if stopped.Load() {
			break
		}
		sem <- struct{}{}
		wg.Add(1)
		go func(i, id int) {
			defer wg.Done()
			defer func() { <-sem }()
			if stopped.Load() {
				errs[i] = errStopped
				return
			}
			frames[i], errs[i] = c.stackTrace(id, levels)
			if errors.Is(errs[i], errStopped) {
				stopped.Store(true)
			}
		}(i, t.Id)
	}
	wg.Wait()
	stacks := make(map[int][]dap.StackFrame, len(threads))
	for i, t := range threads {
		if errors.Is(errs[i], errStopped) {
			return nil, nil, errs[i]
		}
		stacks[t.Id] = frames[i]
	}
	if stopped.Load() {
		return nil, nil, errStopped
	}
	return threads, stacks, nil
}

func (c *Client) GoroutineGroups() ([]byte, error) {
	threads, stacks, err := c.goroutineStacks(groupStackLevels)
	if err != nil {
		return nil, err
	}
	return json.Marshal(GroupByStack(threads, stacks))
}

func (c *Client) GoroutineDump(root string) (string, error) {
	if !c.paused.Load() {
		return "", errors.New("the program is running")
	}
	threads, stacks, err := c.goroutineStacks(stackTraceLevels)
	if err != nil {
		return "", err
	}
	return FormatGoroutineDump(GroupByStack(threads, stacks), root), nil
}

type DebugProcessInfo struct {
	PID     int    `json:"pid"`
	Name    string `json:"name"`
	Command string `json:"command"`
}

func isExcludedProcess(name, comm, args string) bool {
	switch name {
	case "", "GoLensApp", "gopls", "dlv", "ps", "launchd", "kernel_task", "zsh", "bash", "sh", "login", "sshd", "vminitd", "golens-guest-agent", "init", "systemd", "kthreadd":
		return true
	}
	if (strings.HasPrefix(name, "[") && strings.HasSuffix(name, "]")) ||
		(strings.HasPrefix(comm, "[") && strings.HasSuffix(comm, "]")) {
		return true
	}
	if activeDir := lsp.GetActiveDir(); activeDir != "" && (strings.Contains(comm, activeDir) || strings.Contains(args, activeDir)) {
		return false
	}
	if strings.Contains(comm, "/Data/tmp/") || strings.Contains(args, "/Data/tmp/") {
		return false
	}
	for _, sub := range []string{".app/Contents/", "/Library/", "/.vscode/", "/.codex/", "/.cursor/", "/.gemini/", "/.antigravity/", "/node_modules/"} {
		if strings.Contains(comm, sub) || strings.Contains(args, sub) {
			return true
		}
	}
	for _, prefix := range []string{"/System/", "/Applications/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"} {
		if strings.HasPrefix(comm, prefix) || strings.HasPrefix(args, prefix) {
			return true
		}
	}
	return false
}

func processPriority(p DebugProcessInfo) int {
	lowerCmd := strings.ToLower(p.Command)
	if strings.Contains(lowerCmd, "go-build") || strings.Contains(lowerCmd, "__debug_bin") {
		return 3
	}
	if activeDir := lsp.GetActiveDir(); activeDir != "" && strings.Contains(p.Command, activeDir) {
		return 3
	}
	if strings.HasPrefix(p.Command, "/Users/") || strings.HasPrefix(p.Command, "/var/folders/") || strings.HasPrefix(p.Command, "/tmp/") || strings.HasPrefix(p.Command, "./") {
		return 2
	}
	if strings.HasPrefix(p.Command, "/bin/") || strings.HasPrefix(p.Command, "/usr/bin/") {
		return 0
	}
	return 1
}

func parseDebuggableProcesses(raw string, selfPID int) []DebugProcessInfo {
	var list []DebugProcessInfo
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 1 || pid == selfPID {
			continue
		}
		rest := strings.TrimSpace(line[len(fields[0]):])
		comm := fields[1]
		args := strings.TrimSpace(rest[len(comm):])
		if args == "" {
			args = comm
		}
		execToken := comm
		if argFields := strings.Fields(args); len(argFields) > 0 && strings.HasPrefix(argFields[0], comm) {
			execToken = argFields[0]
		}
		name := filepath.Base(execToken)
		if (name == "." || name == "/" || strings.HasPrefix(name, "-")) && len(strings.Fields(args)) > 0 {
			name = filepath.Base(strings.Fields(args)[0])
		}
		if isExcludedProcess(name, comm, args) {
			continue
		}
		list = append(list, DebugProcessInfo{
			PID:     pid,
			Name:    name,
			Command: args,
		})
	}
	sort.SliceStable(list, func(i, j int) bool {
		pi, pj := processPriority(list[i]), processPriority(list[j])
		if pi != pj {
			return pi > pj
		}
		return list[i].PID > list[j].PID
	})
	if len(list) > 100 {
		list = list[:100]
	}
	return list
}

func parsePIDTable(raw string) map[int]string {
	out := make(map[int]string)
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 1 {
			continue
		}
		val := strings.TrimSpace(line[len(fields[0]):])
		if val != "" {
			out[pid] = val
		}
	}
	return out
}

func parseHostDebuggableProcesses(commRaw, argsRaw string, selfPID int) []DebugProcessInfo {
	comms := parsePIDTable(commRaw)
	argsMap := parsePIDTable(argsRaw)
	var list []DebugProcessInfo
	for pid, comm := range comms {
		if pid == selfPID {
			continue
		}
		args := argsMap[pid]
		if args == "" {
			args = comm
		}
		name := filepath.Base(comm)
		if (name == "." || name == "/" || strings.HasPrefix(name, "-")) && len(strings.Fields(args)) > 0 {
			name = filepath.Base(strings.Fields(args)[0])
		}
		if isExcludedProcess(name, comm, args) {
			continue
		}
		list = append(list, DebugProcessInfo{
			PID:     pid,
			Name:    name,
			Command: args,
		})
	}
	sort.SliceStable(list, func(i, j int) bool {
		pi, pj := processPriority(list[i]), processPriority(list[j])
		if pi != pj {
			return pi > pj
		}
		return list[i].PID > list[j].PID
	})
	if len(list) > 100 {
		list = list[:100]
	}
	return list
}

func ListDebuggableProcesses() string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var list []DebugProcessInfo
	if bridge.IsHostMode() {
		commOut, commErr := exec.CommandContext(ctx, "ps", "-axww", "-o", "pid=,comm=").CombinedOutput()
		argsOut, argsErr := exec.CommandContext(ctx, "ps", "-axww", "-o", "pid=,args=").CombinedOutput()
		if commErr == nil && argsErr == nil {
			list = parseHostDebuggableProcesses(string(commOut), string(argsOut), os.Getpid())
		} else {
			return "[]"
		}
	} else {
		cmd := vmexec.CommandContext(ctx, "ps", "-axo", "pid=,comm=,args=")
		out, err := cmd.CombinedOutput()
		if err != nil && bridge.CanFallbackToHost(err) {
			commOut, commErr := exec.CommandContext(ctx, "ps", "-axww", "-o", "pid=,comm=").CombinedOutput()
			argsOut, argsErr := exec.CommandContext(ctx, "ps", "-axww", "-o", "pid=,args=").CombinedOutput()
			if commErr == nil && argsErr == nil {
				list = parseHostDebuggableProcesses(string(commOut), string(argsOut), os.Getpid())
			} else {
				return "[]"
			}
		} else if err != nil {
			return "[]"
		} else {
			list = parseDebuggableProcesses(string(out), os.Getpid())
		}
	}
	if list == nil {
		list = []DebugProcessInfo{}
	}
	data, err := json.Marshal(list)
	if err != nil {
		return "[]"
	}
	return string(data)
}
