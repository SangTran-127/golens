package httpfile

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	MaxResponseBytes  = 8 << 20
	defaultTimeoutSec = 30
)

type RunInput struct {
	Path          string            `json:"path"`
	Content       string            `json:"content"`
	WorkspaceRoot string            `json:"workspaceRoot"`
	Environment   string            `json:"environment"`
	Index         int               `json:"index"`
	Globals       map[string]string `json:"globals"`
	RunID         string            `json:"runId"`
	TimeoutSec    int               `json:"timeoutSec"`
}

type ResolvedRequest struct {
	Index       int      `json:"index"`
	Name        string   `json:"name"`
	Title       string   `json:"title"`
	Line        int      `json:"line"`
	Method      string   `json:"method"`
	URL         string   `json:"url"`
	Headers     []Header `json:"headers"`
	Body        string   `json:"body"`
	IsGRPC      bool     `json:"isGRPC"`
	Handler     string   `json:"handler,omitempty"`
	HandlerLine int      `json:"handlerLine,omitempty"`
	HandlerName string   `json:"handlerName,omitempty"`
}

type Timing struct {
	DNSMs       int64 `json:"dnsMs"`
	ConnectMs   int64 `json:"connectMs"`
	TLSMs       int64 `json:"tlsMs"`
	FirstByteMs int64 `json:"firstByteMs"`
	TotalMs     int64 `json:"totalMs"`
}

type Response struct {
	Status      int      `json:"status"`
	StatusText  string   `json:"statusText"`
	Protocol    string   `json:"protocol"`
	Headers     []Header `json:"headers"`
	Body        string   `json:"body"`
	PrettyBody  string   `json:"prettyBody,omitempty"`
	ContentType string   `json:"contentType"`
	IsJSON      bool     `json:"isJSON"`
	Size        int      `json:"size"`
	Truncated   bool     `json:"truncated"`
	Timing      Timing   `json:"timing"`
}

type RunError struct {
	Kind      string   `json:"kind"`
	Message   string   `json:"message"`
	Detail    string   `json:"detail,omitempty"`
	Variables []string `json:"variables,omitempty"`
	File      string   `json:"file,omitempty"`
}

type RunResult struct {
	RunID    string           `json:"runId"`
	Request  *ResolvedRequest `json:"request,omitempty"`
	Response *Response        `json:"response,omitempty"`
	Error    *RunError        `json:"error,omitempty"`
}

var (
	cancelMu sync.Mutex
	cancels  = map[string]context.CancelFunc{}
)

func Cancel(runID string) bool {
	cancelMu.Lock()
	defer cancelMu.Unlock()
	if c, ok := cancels[runID]; ok {
		c()
		delete(cancels, runID)
		return true
	}
	return false
}

func Run(in RunInput) RunResult {
	result := RunResult{RunID: in.RunID}
	file := Parse(in.Content)
	if in.Index < 0 || in.Index >= len(file.Requests) {
		result.Error = &RunError{Kind: "parse", Message: "This request no longer exists in the file.", Detail: "The file changed since the run started. Place the cursor inside a request and run it again."}
		return result
	}
	req := file.Requests[in.Index]
	envs := LoadEnvironments(in.Path, in.WorkspaceRoot)
	envVars := map[string]string{}
	if in.Environment != "" {
		envVars = envs.Variables(in.Environment)
	}
	fileVars := map[string]string{}
	for _, v := range file.Variables {
		fileVars[v.Name] = v.Value
	}
	resolver := NewResolver(in.Globals, fileVars, envVars)
	resolved, rerr := resolveRequest(req, in.Path, in.WorkspaceRoot, resolver)
	result.Request = &resolved
	if rerr != nil {
		result.Error = rerr
		return result
	}
	if missing := resolver.Missing(); len(missing) > 0 {
		result.Error = missingError(missing, in.Environment, envs)
		return result
	}

	timeout := in.TimeoutSec
	if req.TimeoutSec > 0 {
		timeout = req.TimeoutSec
	}
	if timeout <= 0 {
		timeout = defaultTimeoutSec
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	if in.RunID != "" {
		cancelMu.Lock()
		cancels[in.RunID] = cancel
		cancelMu.Unlock()
		defer func() {
			cancelMu.Lock()
			delete(cancels, in.RunID)
			cancelMu.Unlock()
		}()
	}
	defer cancel()

	var resp *Response
	var err error
	if resolved.IsGRPC {
		resp, err = ExecuteGRPC(ctx, resolved)
	} else {
		resp, err = ExecuteHTTP(ctx, resolved, req.NoRedirect)
	}
	if err != nil {
		result.Error = classifyError(ctx, err, resolved, timeout)
		if resp != nil {
			result.Response = resp
		}
		return result
	}
	result.Response = resp
	return result
}

func missingError(missing []string, env string, envs Environments) *RunError {
	quoted := make([]string, len(missing))
	for i, m := range missing {
		quoted[i] = "{{" + m + "}}"
	}
	subject := "Variable " + quoted[0] + " has no value."
	if len(missing) > 1 {
		subject = "Variables " + strings.Join(quoted, ", ") + " have no value."
	}
	var detail string
	switch {
	case env == "" && len(envs.Names) > 0:
		detail = "No environment is selected. Choose one of " + strings.Join(envs.Names, ", ") + ", or set the value with client.global.set in an earlier request."
	case env == "":
		detail = "Define it in an http-client.env.json environment, with @name = value in this file, or with client.global.set in an earlier request."
	default:
		detail = "The environment “" + env + "” does not define it. Add it to http-client.env.json, or run the request that sets it with client.global.set first."
	}
	return &RunError{Kind: "unresolved", Message: subject, Detail: detail, Variables: missing}
}

func resolveRequest(req Request, httpPath, workspaceRoot string, r *Resolver) (ResolvedRequest, *RunError) {
	out := ResolvedRequest{
		Index:       req.Index,
		Name:        req.Name,
		Title:       req.Title,
		Line:        req.Line,
		Method:      req.Method,
		URL:         strings.TrimSpace(r.Resolve(req.URL)),
		IsGRPC:      req.IsGRPC,
		Handler:     req.Handler,
		HandlerLine: req.HandlerLine,
		Headers:     make([]Header, 0, len(req.Headers)),
	}
	for _, h := range req.Headers {
		out.Headers = append(out.Headers, Header{Name: r.Resolve(h.Name), Value: r.Resolve(h.Value)})
	}
	baseDir := filepath.Dir(httpPath)
	var body strings.Builder
	for i, part := range req.Body {
		if i > 0 {
			body.WriteString("\n")
		}
		if part.File == "" {
			body.WriteString(r.Resolve(part.Text))
			continue
		}
		target := r.Resolve(part.File)
		if !filepath.IsAbs(target) {
			target = filepath.Join(baseDir, target)
		}
		if !insideRoot(allowedRoot(workspaceRoot, baseDir), target) {
			return out, outsideProjectError("The body file "+part.File, target)
		}
		data, err := os.ReadFile(target)
		if err != nil {
			return out, &RunError{Kind: "file", Message: "The body file " + part.File + " could not be read.", Detail: "Check that the file exists next to this .http file. " + plainFileError(err), File: target}
		}
		if part.Substitute {
			body.WriteString(r.Resolve(string(data)))
		} else {
			body.Write(data)
		}
	}
	out.Body = body.String()
	if req.HandlerFile != "" {
		target := r.Resolve(req.HandlerFile)
		if !filepath.IsAbs(target) {
			target = filepath.Join(baseDir, target)
		}
		if !insideRoot(allowedRoot(workspaceRoot, baseDir), target) {
			return out, outsideProjectError("The response handler "+req.HandlerFile, target)
		}
		data, err := os.ReadFile(target)
		if err != nil {
			return out, &RunError{Kind: "file", Message: "The response handler " + req.HandlerFile + " could not be read.", Detail: "Check that the script exists next to this .http file. " + plainFileError(err), File: target}
		}
		out.Handler = string(data)
		out.HandlerName = filepath.Base(target)
		out.HandlerLine = 1
	}
	if out.URL == "" {
		return out, &RunError{Kind: "parse", Message: "The request has no URL.", Detail: "Write the method and URL on one line, for example GET https://example.com/users."}
	}
	return out, nil
}

func plainFileError(err error) string {
	if errors.Is(err, os.ErrNotExist) {
		return "The file does not exist."
	}
	if errors.Is(err, os.ErrPermission) {
		return "GoLens does not have permission to read it."
	}
	return err.Error()
}

func ExecuteHTTP(ctx context.Context, rr ResolvedRequest, noRedirect bool) (*Response, error) {
	target := rr.URL
	if !strings.Contains(target, "://") {
		target = "http://" + target
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Host == "" {
		return nil, &urlError{raw: rr.URL}
	}
	var bodyReader io.Reader
	if rr.Body != "" {
		bodyReader = strings.NewReader(rr.Body)
	}
	req, err := http.NewRequestWithContext(ctx, rr.Method, parsed.String(), bodyReader)
	if err != nil {
		return nil, &urlError{raw: rr.URL}
	}
	for _, h := range rr.Headers {
		if strings.EqualFold(h.Name, "Host") {
			req.Host = h.Value
			continue
		}
		req.Header.Add(h.Name, h.Value)
	}
	if rr.Body != "" && req.Header.Get("Content-Type") == "" {
		trimmed := strings.TrimSpace(rr.Body)
		if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
			req.Header.Set("Content-Type", "application/json")
		}
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "GoLens-HTTP-Client")
	}

	var timing Timing
	var start, dnsStart, connStart, tlsStart time.Time
	trace := &httptrace.ClientTrace{
		DNSStart:          func(httptrace.DNSStartInfo) { dnsStart = time.Now() },
		DNSDone:           func(httptrace.DNSDoneInfo) { timing.DNSMs = time.Since(dnsStart).Milliseconds() },
		ConnectStart:      func(string, string) { connStart = time.Now() },
		ConnectDone:       func(string, string, error) { timing.ConnectMs = time.Since(connStart).Milliseconds() },
		TLSHandshakeStart: func() { tlsStart = time.Now() },
		TLSHandshakeDone: func(tls.ConnectionState, error) {
			timing.TLSMs = time.Since(tlsStart).Milliseconds()
		},
		GotFirstResponseByte: func() { timing.FirstByteMs = time.Since(start).Milliseconds() },
	}
	req = req.WithContext(httptrace.WithClientTrace(ctx, trace))

	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, ForceAttemptHTTP2: true, DisableKeepAlives: true}}
	if noRedirect {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	start = time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	timing.TotalMs = time.Since(start).Milliseconds()
	if err != nil {
		return nil, err
	}
	out := &Response{
		Status:      resp.StatusCode,
		StatusText:  http.StatusText(resp.StatusCode),
		Protocol:    resp.Proto,
		Headers:     flattenHeaders(resp.Header),
		ContentType: resp.Header.Get("Content-Type"),
		Timing:      timing,
	}
	if len(data) > MaxResponseBytes {
		data = data[:MaxResponseBytes]
		out.Truncated = true
	}
	out.Size = len(data)
	out.Body = string(data)
	out.IsJSON, out.PrettyBody = prettyJSON(out.ContentType, data)
	return out, nil
}

func flattenHeaders(h http.Header) []Header {
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]Header, 0, len(keys))
	for _, k := range keys {
		for _, v := range h[k] {
			out = append(out, Header{Name: k, Value: v})
		}
	}
	return out
}

func prettyJSON(contentType string, data []byte) (bool, string) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return false, ""
	}
	looksJSON := strings.Contains(strings.ToLower(contentType), "json") || trimmed[0] == '{' || trimmed[0] == '['
	if !looksJSON || !json.Valid(trimmed) {
		return false, ""
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, trimmed, "", "  "); err != nil {
		return false, ""
	}
	return true, buf.String()
}

type urlError struct{ raw string }

func (e *urlError) Error() string { return "invalid URL " + e.raw }

func classifyError(ctx context.Context, err error, rr ResolvedRequest, timeoutSec int) *RunError {
	host := hostOf(rr)
	var ue *urlError
	var gerr *grpcError
	var dnsErr *net.DNSError
	var opErr *net.OpError
	switch {
	case errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled):
		return &RunError{Kind: "cancelled", Message: "The request was stopped.", Detail: "Run it again when you are ready."}
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded):
		return &RunError{Kind: "timeout", Message: fmt.Sprintf("%s did not answer within %d seconds.", host, timeoutSec), Detail: "Check that the server is running and not blocked, or raise the limit with # @timeout 60 above the request."}
	case errors.As(err, &ue):
		return &RunError{Kind: "parse", Message: "“" + rr.URL + "” is not a valid URL.", Detail: "Use a full address such as http://localhost:8080/path, or check the variables in it."}
	case errors.As(err, &gerr):
		return &RunError{Kind: "grpc", Message: gerr.message, Detail: gerr.detail}
	case errors.As(err, &dnsErr):
		return &RunError{Kind: "network", Message: "Could not find the server " + dnsErr.Name + ".", Detail: "Check the host name in the URL or your network connection."}
	case errors.As(err, &opErr) && opErr.Err != nil && strings.Contains(strings.ToLower(opErr.Err.Error()), "refused"):
		return &RunError{Kind: "network", Message: "Could not connect to " + host + ".", Detail: "Nothing is listening there. Start your server, for example with Product › Run, then run the request again."}
	case opErr != nil && opErr.Err == nil:
		return &RunError{Kind: "network", Message: "The request to " + host + " failed.", Detail: ""}
	case strings.Contains(strings.ToLower(err.Error()), "connection refused"):
		return &RunError{Kind: "network", Message: "Could not connect to " + host + ".", Detail: "Nothing is listening there. Start your server, for example with Product › Run, then run the request again."}
	case strings.Contains(strings.ToLower(err.Error()), "certificate"):
		return &RunError{Kind: "network", Message: "The server’s certificate is not trusted.", Detail: err.Error()}
	}
	return &RunError{Kind: "network", Message: "The request to " + host + " failed.", Detail: err.Error()}
}

func hostOf(rr ResolvedRequest) string {
	raw := rr.URL
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	if u, err := url.Parse(raw); err == nil && u.Host != "" {
		return u.Host
	}
	return rr.URL
}

func allowedRoot(workspaceRoot, baseDir string) string {
	if workspaceRoot != "" {
		return workspaceRoot
	}
	return baseDir
}

func insideRoot(root, target string) bool {
	resolve := func(p string) string {
		p = filepath.Clean(p)
		var tail []string
		for {
			if real, err := filepath.EvalSymlinks(p); err == nil {
				for i := len(tail) - 1; i >= 0; i-- {
					real = filepath.Join(real, tail[i])
				}
				return real
			}
			parent := filepath.Dir(p)
			if parent == p {
				for i := len(tail) - 1; i >= 0; i-- {
					p = filepath.Join(p, tail[i])
				}
				return p
			}
			tail = append(tail, filepath.Base(p))
			p = parent
		}
	}
	r, t := resolve(root), resolve(target)
	if r == string(filepath.Separator) {
		return strings.HasPrefix(t, r)
	}
	return t == r || strings.HasPrefix(t, r+string(filepath.Separator))
}

func outsideProjectError(what, target string) *RunError {
	return &RunError{
		Kind:    "file",
		Message: what + " is outside the project.",
		Detail:  "Body and handler files must be inside the project folder, so a .http file can't send other files from this Mac. Move the file into the project and refer to it with a relative path.",
		File:    target,
	}
}
