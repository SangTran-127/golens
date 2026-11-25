package docker

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxAPIVersion = "1.56"
	minAPIVersion = "1.40"
)

const (
	ReasonDown        = "down"
	ReasonPermission  = "permission"
	ReasonTimeout     = "timeout"
	ReasonTooOld      = "tooOld"
	ReasonUnsupported = "unsupported"
)

type EngineError struct {
	Reason  string
	Socket  string
	Message string
	Err     error
	Issue   *Issue
}

func (e *EngineError) Error() string { return e.Message }

func (e *EngineError) Unwrap() error { return e.Err }

type Issue struct {
	Code     string `json:"code"`
	Title    string `json:"title"`
	Message  string `json:"message"`
	Fix      string `json:"fix,omitempty"`
	FixTitle string `json:"fixTitle,omitempty"`
	Command  string `json:"command,omitempty"`
}

type IssueError struct {
	Issue Issue
}

func (e *IssueError) Error() string { return e.Issue.Message }

var SSHDialer func(ctx context.Context, host string) (net.Conn, error)

type dialFunc func(ctx context.Context) (net.Conn, error)

type APIError struct {
	StatusCode int
	Message    string
}

func (e *APIError) Error() string { return e.Message }

var (
	hostDialers     sync.Map
	sharedTransport = &http.Transport{
		DialContext:         dialHost,
		MaxIdleConnsPerHost: 2,
		IdleConnTimeout:     30 * time.Second,
		DisableCompression:  true,
	}
	tlsTransports sync.Map
)

func registerHost(key string, dial dialFunc) string {
	sum := sha256.Sum256([]byte(key))
	host := hex.EncodeToString(sum[:8]) + ".sock"
	hostDialers.Store(host, dial)
	return host
}

func socketHost(path string) string {
	return registerHost("unix:"+path, func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", path)
	})
}

func dialHost(ctx context.Context, _, addr string) (net.Conn, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	dial, ok := hostDialers.Load(host)
	if !ok {
		return nil, fmt.Errorf("unknown Docker engine host %q", host)
	}
	return dial.(dialFunc)(ctx)
}

func CloseIdleConnections() {
	sharedTransport.CloseIdleConnections()
	tlsTransports.Range(func(_, v any) bool {
		v.(*http.Transport).CloseIdleConnections()
		return true
	})
}

type Client struct {
	Endpoint   Endpoint
	APIVersion string
	CloseAfter bool
	scheme     string
	host       string
	http       *http.Client
}

func NewClient(ep Endpoint) (*Client, error) {
	c := &Client{Endpoint: ep, scheme: "http", http: &http.Client{Transport: sharedTransport}}
	switch ep.Kind {
	case KindUnix:
		c.host = socketHost(ep.Socket)
	case KindSSH:
		dial := SSHDialer
		if dial == nil {
			return nil, &EngineError{Reason: ReasonUnsupported, Socket: ep.Host, Message: fmt.Sprintf("Docker context ‘%s’ points to %s, and this build of GoLens can’t open SSH connections.", ep.Context, ep.Host)}
		}
		host := ep.Host
		c.host = registerHost("ssh:"+host, func(ctx context.Context) (net.Conn, error) { return dial(ctx, host) })
	case KindTCP:
		addr, err := tcpAddress(ep.Host)
		if err != nil {
			return nil, &EngineError{Reason: ReasonUnsupported, Socket: ep.Host, Message: err.Error(), Err: err}
		}
		if !ep.TLS {
			c.host = registerHost("tcp:"+addr, func(ctx context.Context) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "tcp", addr)
			})
			break
		}
		tr, err := tlsTransport(ep)
		if err != nil {
			return nil, &EngineError{Reason: ReasonUnsupported, Socket: ep.Host, Err: err, Message: fmt.Sprintf("GoLens couldn’t read the TLS certificates of Docker context ‘%s’: %v.", ep.Context, rootCause(err))}
		}
		c.scheme, c.host, c.http = "https", addr, &http.Client{Transport: tr}
	default:
		return nil, &EngineError{Reason: ReasonUnsupported, Socket: ep.Host, Message: fmt.Sprintf("Docker host %s isn’t a unix://, ssh:// or tcp:// address.", ep.Host)}
	}
	return c, nil
}

func tcpAddress(host string) (string, error) {
	u, err := url.Parse(host)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("Docker host %q has no address.", host)
	}
	if u.Port() == "" {
		port := "2375"
		if u.Scheme == "https" {
			port = "2376"
		}
		return net.JoinHostPort(u.Hostname(), port), nil
	}
	return u.Host, nil
}

func tlsTransport(ep Endpoint) (*http.Transport, error) {
	if tr, ok := tlsTransports.Load(ep); ok {
		return tr.(*http.Transport), nil
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: ep.SkipTLSVerify}
	if ep.CAFile != "" {
		pem, err := os.ReadFile(ep.CAFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("%s holds no certificate", ep.CAFile)
		}
		cfg.RootCAs = pool
	}
	if ep.CertFile != "" && ep.KeyFile != "" {
		pair, err := tls.LoadX509KeyPair(ep.CertFile, ep.KeyFile)
		if err != nil {
			return nil, err
		}
		cfg.Certificates = []tls.Certificate{pair}
	}
	tr := &http.Transport{
		TLSClientConfig:     cfg,
		MaxIdleConnsPerHost: 2,
		IdleConnTimeout:     30 * time.Second,
		DisableCompression:  true,
	}
	actual, _ := tlsTransports.LoadOrStore(ep, tr)
	return actual.(*http.Transport), nil
}

func Connect(ctx context.Context, ep Endpoint) (*Client, error) {
	c, err := NewClient(ep)
	if err != nil {
		return nil, err
	}
	if err := c.Negotiate(ctx); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Client) Negotiate(ctx context.Context) error {
	resp, err := c.send(ctx, http.MethodGet, "/_ping", nil, nil)
	if err != nil {
		return err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<10))
	resp.Body.Close()
	server := resp.Header.Get("API-Version")
	if server == "" {
		addr := c.Endpoint.Address()
		return &EngineError{Reason: ReasonTooOld, Socket: addr, Message: fmt.Sprintf("Docker Engine at %s didn’t report its API version, so GoLens can’t talk to it.", addr)}
	}
	if compareAPIVersion(server, minAPIVersion) < 0 {
		addr := c.Endpoint.Address()
		return &EngineError{Reason: ReasonTooOld, Socket: addr, Message: fmt.Sprintf("Docker Engine at %s speaks API %s, older than the %s GoLens needs; update your Docker engine.", addr, server, minAPIVersion)}
	}
	c.APIVersion = maxAPIVersion
	if compareAPIVersion(server, maxAPIVersion) < 0 {
		c.APIVersion = server
	}
	return nil
}

func (c *Client) Do(ctx context.Context, method, path string, query url.Values, body io.Reader) (*http.Response, error) {
	if c.APIVersion == "" {
		if err := c.Negotiate(ctx); err != nil {
			return nil, err
		}
	}
	return c.send(ctx, method, "/v"+c.APIVersion+path, query, body)
}

func (c *Client) GetJSON(ctx context.Context, path string, query url.Values, out any) error {
	resp, err := c.Do(ctx, http.MethodGet, path, query, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return c.wrap(err, time.Time{})
	}
	return nil
}

type EngineVersion struct {
	Version       string `json:"Version"`
	APIVersion    string `json:"ApiVersion"`
	MinAPIVersion string `json:"MinAPIVersion"`
	OS            string `json:"Os"`
	Arch          string `json:"Arch"`
}

func (c *Client) Version(ctx context.Context) (EngineVersion, error) {
	var v EngineVersion
	err := c.GetJSON(ctx, "/version", nil, &v)
	return v, err
}

func (c *Client) send(ctx context.Context, method, path string, query url.Values, body io.Reader) (*http.Response, error) {
	u := url.URL{Scheme: c.scheme, Host: c.host, Path: path}
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	req.Close = c.CloseAfter
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	start := time.Now()
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, c.wrap(err, start)
	}
	if resp.StatusCode/100 != 2 {
		defer resp.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		var msg struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(data, &msg) != nil || msg.Message == "" {
			msg.Message = strings.TrimSpace(string(data))
		}
		if msg.Message == "" {
			msg.Message = resp.Status
		}
		return nil, &APIError{StatusCode: resp.StatusCode, Message: msg.Message}
	}
	return resp, nil
}

func (c *Client) wrap(err error, start time.Time) error {
	sock := c.Endpoint.Address()
	var netErr net.Error
	var issueErr *IssueError
	switch {
	case errors.As(err, &issueErr):
		issue := issueErr.Issue
		return &EngineError{Reason: ReasonDown, Socket: sock, Err: err, Message: issue.Message, Issue: &issue}
	case errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()):
		waited := "the time allowed"
		if !start.IsZero() {
			waited = time.Since(start).Round(100 * time.Millisecond).String()
		}
		return &EngineError{Reason: ReasonTimeout, Socket: sock, Err: err, Message: fmt.Sprintf("Docker Engine at %s didn’t answer within %s.", sock, waited)}
	case errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM):
		return &EngineError{Reason: ReasonPermission, Socket: sock, Err: err, Message: fmt.Sprintf("GoLens isn’t allowed to open the Docker socket at %s; check your Docker provider’s settings.", sock)}
	case errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ENOTSOCK):
		return &EngineError{Reason: ReasonDown, Socket: sock, Err: err, Message: fmt.Sprintf("Docker Engine isn’t running at %s.", sock)}
	case errors.Is(err, context.Canceled):
		return err
	}
	return &EngineError{Reason: ReasonDown, Socket: sock, Err: err, Message: fmt.Sprintf("Docker Engine at %s stopped answering: %v.", sock, rootCause(err))}
}

func rootCause(err error) error {
	for {
		next := errors.Unwrap(err)
		if next == nil {
			return err
		}
		err = next
	}
}

func compareAPIVersion(a, b string) int {
	pa, pb := strings.SplitN(a, ".", 2), strings.SplitN(b, ".", 2)
	for i := range 2 {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}
