package lsp

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golens/core/bridge"
)

const (
	SwiftIDBase         int64 = 1 << 32
	outQueueCap               = 4096
	maxMessageBytes           = 256 << 20
	requestCancelled          = -32800
	contentModified           = -32801
	maxDiagsPerFile           = 500
	maxDiagMessageBytes       = 1024
)

var changeGateMax = 2 * time.Second

var (
	errTimeout      = errors.New("request timed out")
	errCancelled    = errors.New("request cancelled")
	errServerGone   = errors.New("language server not running")
	errBackpressure = errors.New("language server is not reading its input")
)

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type envelope struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *rpcError       `json:"error,omitempty"`
}

type pendingCall struct {
	ch  chan *envelope
	key string
}

type conn struct {
	out     chan []byte
	closed  chan struct{}
	once    sync.Once
	nextID  atomic.Int64
	mu      sync.Mutex
	pending map[int64]*pendingCall
	keyed   map[string]int64
	onDiag  func(path string, payload []byte)
	onFatal func(error)

	diagMu      sync.Mutex
	diagPending map[string][]byte

	rawDiagMu  sync.Mutex
	rawDiags   map[string][]json.RawMessage
	diagOrder  []string
	diagWake   chan struct{}
	diagOnce   sync.Once
	onProgress func(token, kind, title string)
	isRemote   bool

	gateMu    sync.Mutex
	held      *heldChange
	awaitURI  string
	awaitVer  int32
	gateTimer *time.Timer
}

type heldChange struct {
	uri     string
	version int32
	changes []contentChange
}

func (c *conn) sendChange(uri string, version int32, changes []contentChange) error {
	c.gateMu.Lock()
	defer c.gateMu.Unlock()
	if c.held != nil && c.held.uri != uri {
		c.flushLocked()
	}
	if c.held == nil && c.awaitURI == "" {
		return c.writeChangeLocked(uri, version, changes)
	}
	if c.held == nil {
		c.held = &heldChange{uri: uri}
	}
	c.held.version = version
	for _, ch := range changes {
		ch.Text = strings.Clone(ch.Text)
		if ch.Range == nil {
			c.held.changes = c.held.changes[:0]
		}
		c.held.changes = append(c.held.changes, ch)
	}
	return nil
}

func (c *conn) writeChangeLocked(uri string, version int32, changes []contentChange) error {
	c.awaitURI, c.awaitVer = uri, version
	reqTrace.changeSent(uri, version, len(changes))
	if c.gateTimer == nil {
		c.gateTimer = time.AfterFunc(changeGateMax, c.openGate)
	} else {
		c.gateTimer.Reset(changeGateMax)
	}
	return c.notify("textDocument/didChange", map[string]any{
		"textDocument":   versionedDoc{uri, version},
		"contentChanges": changes,
	})
}

func (c *conn) flushLocked() {
	if h := c.held; h != nil {
		c.held = nil
		_ = c.writeChangeLocked(h.uri, h.version, h.changes)
	}
}

func (c *conn) flushChanges() {
	c.gateMu.Lock()
	c.flushLocked()
	c.gateMu.Unlock()
}

func (c *conn) openGate() {
	c.gateMu.Lock()
	c.awaitURI = ""
	c.flushLocked()
	c.gateMu.Unlock()
}

func newConn() *conn {
	return &conn{
		out:     make(chan []byte, outQueueCap),
		closed:  make(chan struct{}),
		pending: make(map[int64]*pendingCall),
		keyed:   make(map[string]int64),
	}
}

func frame(body []byte) []byte {
	head := "Content-Length: " + strconv.Itoa(len(body)) + "\r\n\r\n"
	msg := make([]byte, 0, len(head)+len(body))
	return append(append(msg, head...), body...)
}

func (c *conn) enqueue(body []byte) error {
	select {
	case <-c.closed:
		return errServerGone
	default:
	}
	select {
	case c.out <- frame(body):
		return nil
	default:
		if c.onFatal != nil {
			go c.onFatal(errBackpressure)
		}
		return errBackpressure
	}
}

func (c *conn) notify(method string, params any) error {
	if method != "textDocument/didChange" {
		c.flushChanges()
	}
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  any    `json:"params"`
	}{"2.0", method, params})
	if err != nil {
		return err
	}
	return c.enqueue(body)
}

func (c *conn) respond(id json.RawMessage, result any) {
	body, err := json.Marshal(struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Result  any             `json:"result"`
	}{"2.0", id, result})
	if err == nil {
		_ = c.enqueue(body)
	}
}

func (c *conn) cancelLocked(id int64) {
	p, ok := c.pending[id]
	if !ok {
		return
	}
	delete(c.pending, id)
	if p.key != "" && c.keyed[p.key] == id {
		delete(c.keyed, p.key)
	}
	close(p.ch)
	_ = c.notify("$/cancelRequest", map[string]int64{"id": id})
}

func (c *conn) call(method string, params any, budget time.Duration, key string) (json.RawMessage, error) {
	c.flushChanges()
	id := c.nextID.Add(1)
	body, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		ID      int64  `json:"id"`
		Method  string `json:"method"`
		Params  any    `json:"params"`
	}{"2.0", id, method, params})
	if err != nil {
		return nil, err
	}
	p := &pendingCall{ch: make(chan *envelope, 1), key: key}
	c.mu.Lock()
	if key != "" {
		if old, ok := c.keyed[key]; ok {
			c.cancelLocked(old)
		}
		c.keyed[key] = id
	}
	c.pending[id] = p
	c.mu.Unlock()

	reqTrace.begin(id, method)
	if err := c.enqueue(body); err != nil {
		reqTrace.end(id, "enqueue-failed", 0)
		c.mu.Lock()
		c.dropLocked(id)
		c.mu.Unlock()
		return nil, err
	}

	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case env, ok := <-p.ch:
		if !ok || env == nil {
			reqTrace.end(id, "superseded", 0)
			return nil, errCancelled
		}
		reqTrace.response(id, env, len(env.Result))
		if env.Error != nil {
			if env.Error.Code == requestCancelled || env.Error.Code == contentModified {
				return nil, errCancelled
			}
			return nil, fmt.Errorf("%s: %s", method, env.Error.Message)
		}
		return env.Result, nil
	case <-timer.C:
		reqTrace.end(id, "timeout", 0)
		c.mu.Lock()
		c.cancelLocked(id)
		c.mu.Unlock()
		return nil, fmt.Errorf("%s: %w after %v", method, errTimeout, budget)
	case <-c.closed:
		return nil, errServerGone
	}
}

func (c *conn) dropLocked(id int64) {
	if p, ok := c.pending[id]; ok {
		delete(c.pending, id)
		if p.key != "" && c.keyed[p.key] == id {
			delete(c.keyed, p.key)
		}
	}
}

func (c *conn) close() {
	c.once.Do(func() { close(c.closed) })
	c.gateMu.Lock()
	if c.gateTimer != nil {
		c.gateTimer.Stop()
	}
	c.held = nil
	c.gateMu.Unlock()
}

func (c *conn) writeLoop(w io.WriteCloser) {
	defer func() { _ = w.Close() }()
	for {
		select {
		case msg := <-c.out:
			if _, err := w.Write(msg); err != nil {
				return
			}
		case <-c.closed:
			return
		}
	}
}

func (c *conn) readLoop(r io.Reader) {
	reader := bufio.NewReaderSize(r, 64<<10)
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
				length, _ = strconv.Atoi(strings.TrimSpace(v))
			}
		}
		if length < 0 || length > maxMessageBytes {
			return
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			return
		}
		c.dispatch(body)
	}
}

func parseID(raw json.RawMessage) (int64, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return 0, false
	}
	var n int64
	if json.Unmarshal(raw, &n) == nil {
		return n, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		n, err := strconv.ParseInt(s, 10, 64)
		return n, err == nil
	}
	return 0, false
}

func (c *conn) dispatch(body []byte) {
	var env envelope
	if err := json.Unmarshal(body, &env); err != nil {
		bridge.Debug("[LSP] dropped malformed message: " + err.Error())
		return
	}
	hasID := len(env.ID) > 0 && string(env.ID) != "null"
	switch {
	case env.Method != "" && hasID:
		c.handleServerRequest(&env)
	case env.Method != "":
		c.handleNotification(&env)
	case hasID:
		id, ok := parseID(env.ID)
		if !ok {
			return
		}
		c.mu.Lock()
		p, mine := c.pending[id]
		if mine {
			c.dropLocked(id)
		}
		c.mu.Unlock()
		if mine {
			p.ch <- &env
		} else if id >= SwiftIDBase {
			reqTrace.response(id, &env, len(env.Result))
			bridge.LSPResponse(body)
		}
	}
}

func (c *conn) handleServerRequest(env *envelope) {
	switch env.Method {
	case "workspace/configuration":
		var p struct {
			Items []json.RawMessage `json:"items"`
		}
		_ = json.Unmarshal(env.Params, &p)
		res := make([]any, len(p.Items))
		for i := range res {
			res[i] = goplsSettingsFor(c.isRemote)
		}
		c.respond(env.ID, res)
	case "workspace/applyEdit":
		c.handleApplyEdit(env)
	default:
		c.respond(env.ID, nil)
	}
}

func (c *conn) handleNotification(env *envelope) {
	switch env.Method {
	case "textDocument/publishDiagnostics":
		c.publishDiagnostics(env.Params)
	case "$/progress":
		var p struct {
			Token json.RawMessage `json:"token"`
			Value struct {
				Kind  string `json:"kind"`
				Title string `json:"title"`
			} `json:"value"`
		}
		if json.Unmarshal(env.Params, &p) == nil && c.onProgress != nil {
			c.onProgress(string(p.Token), p.Value.Kind, p.Value.Title)
		}
	case "window/showMessage", "window/logMessage":
		var p struct {
			Type    int    `json:"type"`
			Message string `json:"message"`
		}
		if json.Unmarshal(env.Params, &p) == nil && p.Type <= 2 {
			bridge.Debug("[gopls] " + truncate(p.Message, 4096))
		}
	default:
		if traceLSP {
			bridge.Debug("[gopls raw] " + truncate(string(env.Params), 4096))
		}
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

type lspPos struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type lspRange struct {
	Start lspPos `json:"start"`
	End   lspPos `json:"end"`
}

type uiDiagnostic struct {
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	EndLine  int    `json:"endLine"`
	EndCol   int    `json:"endCol"`
	Severity int    `json:"severity"`
	Message  string `json:"message"`
}

func (c *conn) publishDiagnostics(raw json.RawMessage) {
	var p struct {
		URI         string `json:"uri"`
		Version     *int32 `json:"version"`
		Diagnostics []struct {
			Range    lspRange `json:"range"`
			Severity int      `json:"severity"`
			Message  string   `json:"message"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return
	}
	c.keepRawDiagnostics(raw)
	reqTrace.diagnostics(p.URI, p.Version, len(p.Diagnostics))
	if p.Version != nil {
		c.gateMu.Lock()
		open := p.URI == c.awaitURI && *p.Version >= c.awaitVer
		c.gateMu.Unlock()
		if open {
			c.openGate()
		}
	}
	n := min(len(p.Diagnostics), maxDiagsPerFile)
	out := make([]uiDiagnostic, 0, n)
	for _, d := range p.Diagnostics[:n] {
		out = append(out, uiDiagnostic{
			Line: d.Range.Start.Line, Col: d.Range.Start.Character,
			EndLine: d.Range.End.Line, EndCol: d.Range.End.Character,
			Severity: d.Severity, Message: truncate(d.Message, maxDiagMessageBytes),
		})
	}
	payload, err := json.Marshal(out)
	if err == nil && c.onDiag != nil {
		c.queueDiagnostics(uriToPath(p.URI), payload)
	}
}

func (c *conn) keepRawDiagnostics(raw json.RawMessage) {
	var p struct {
		URI         string            `json:"uri"`
		Diagnostics []json.RawMessage `json:"diagnostics"`
	}
	if json.Unmarshal(raw, &p) != nil || p.URI == "" {
		return
	}
	c.rawDiagMu.Lock()
	defer c.rawDiagMu.Unlock()
	if len(p.Diagnostics) == 0 {
		delete(c.rawDiags, p.URI)
		return
	}
	if c.rawDiags == nil {
		c.rawDiags = make(map[string][]json.RawMessage)
	}
	c.rawDiags[p.URI] = p.Diagnostics[:min(len(p.Diagnostics), maxDiagsPerFile)]
}

func (c *conn) diagnosticsIn(uri string, r lspRange) []json.RawMessage {
	c.rawDiagMu.Lock()
	all := c.rawDiags[uri]
	c.rawDiagMu.Unlock()
	var out []json.RawMessage
	for _, d := range all {
		var head struct {
			Range lspRange `json:"range"`
		}
		if json.Unmarshal(d, &head) == nil && rangesOverlap(head.Range, r) {
			out = append(out, d)
		}
	}
	return out
}

func posBefore(a, b lspPos) bool {
	return a.Line < b.Line || (a.Line == b.Line && a.Character < b.Character)
}

func rangesOverlap(a, b lspRange) bool {
	return !posBefore(a.End, b.Start) && !posBefore(b.End, a.Start)
}

func (c *conn) queueDiagnostics(path string, payload []byte) {
	c.diagOnce.Do(func() {
		c.diagWake = make(chan struct{}, 1)
		go c.deliverDiagnostics()
	})
	c.diagMu.Lock()
	if c.diagPending == nil {
		c.diagPending = make(map[string][]byte)
	}
	if _, queued := c.diagPending[path]; !queued {
		c.diagOrder = append(c.diagOrder, path)
	}
	c.diagPending[path] = payload
	c.diagMu.Unlock()
	select {
	case c.diagWake <- struct{}{}:
	default:
	}
}

func (c *conn) deliverDiagnostics() {
	for {
		select {
		case <-c.closed:
			return
		case <-c.diagWake:
		}
		for {
			c.diagMu.Lock()
			if len(c.diagOrder) == 0 {
				c.diagMu.Unlock()
				break
			}
			path := c.diagOrder[0]
			c.diagOrder = c.diagOrder[1:]
			payload := c.diagPending[path]
			delete(c.diagPending, path)
			c.diagMu.Unlock()
			c.onDiag(path, payload)
		}
	}
}
