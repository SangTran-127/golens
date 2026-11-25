package kube

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golens/core/docker"

	utilnet "k8s.io/apimachinery/pkg/util/net"

	"k8s.io/client-go/rest"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const (
	KindUnreachable      = "unreachable"
	KindPluginMissing    = "credentialPluginMissing"
	KindPluginFailed     = "credentialPluginFailed"
	KindNeedsSignIn      = "needsSignIn"
	KindUnauthorized     = "unauthorized"
	KindForbidden        = "forbidden"
	KindNotFound         = "notFound"
	KindConfig           = "config"
	KindOther            = "other"
	requestTimeout       = 15 * time.Second
	pluginDiagnoseLimit  = 30 * time.Second
	maxErrorBody         = 64 << 10
	maxPluginStderrBytes = 4 << 10
)

type Error struct {
	Kind          string   `json:"kind"`
	Message       string   `json:"message"`
	Server        string   `json:"server,omitempty"`
	Plugin        string   `json:"plugin,omitempty"`
	Verb          string   `json:"verb,omitempty"`
	Resource      string   `json:"resource,omitempty"`
	Namespace     string   `json:"namespace,omitempty"`
	SignInCommand []string `json:"signInCommand,omitempty"`
	status        int
}

func (e *Error) Error() string { return e.Message }

func asError(err error) *Error {
	if err == nil {
		return nil
	}
	var ke *Error
	if errors.As(err, &ke) {
		return ke
	}
	return &Error{Kind: KindOther, Message: firstLine(err.Error())}
}

func pluginMissing(contextName, plugin string) *Error {
	return &Error{Kind: KindPluginMissing, Plugin: plugin,
		Message: fmt.Sprintf("Couldn’t sign in to “%s” because the credential helper “%s” wasn’t found.", contextName, plugin)}
}

type client struct {
	context   string
	namespace string
	server    string
	base      *url.URL
	http      *http.Client
	exec      *clientcmdapi.ExecConfig
	key       string
}

var clients struct {
	sync.Mutex
	m map[string]*client
}

func clientFor(contextName string) (*client, error) {
	r, err := resolveContext(contextName)
	if err != nil {
		return nil, err
	}
	key := r.key
	clients.Lock()
	defer clients.Unlock()
	if c := clients.m[r.name]; c != nil && c.key == key {
		return c, nil
	}
	base, _, err := rest.DefaultServerUrlFor(r.rest)
	if err != nil {
		return nil, &Error{Kind: KindConfig, Server: r.server, Message: "The server address of “" + r.name + "” isn’t valid."}
	}
	hc, err := rest.HTTPClientFor(r.rest)
	if err != nil {
		return nil, &Error{Kind: KindConfig, Server: r.server, Message: "The credentials of “" + r.name + "” can’t be used: " + firstLine(err.Error())}
	}
	c := &client{context: r.name, namespace: r.namespace, server: r.server, base: base, http: hc, exec: r.exec, key: key}
	if clients.m == nil {
		clients.m = map[string]*client{}
	}
	if old := clients.m[r.name]; old != nil {
		utilnet.CloseIdleConnectionsFor(old.http.Transport)
	}
	clients.m[r.name] = c
	return c, nil
}

func closeClients() {
	clients.Lock()
	defer clients.Unlock()
	for _, c := range clients.m {
		utilnet.CloseIdleConnectionsFor(c.http.Transport)
	}
	clients.m = nil
}

type request struct {
	method      string
	path        string
	query       url.Values
	body        []byte
	contentType string
	verb        string
	resource    string
	namespace   string
}

func (c *client) do(ctx context.Context, r request) (*http.Response, error) {
	u := *c.base
	u.Path = strings.TrimSuffix(u.Path, "/") + r.path
	u.RawQuery = r.query.Encode()
	var body io.Reader
	if r.body != nil {
		body = bytes.NewReader(r.body)
	}
	req, err := http.NewRequestWithContext(ctx, r.method, u.String(), body)
	if err != nil {
		return nil, &Error{Kind: KindOther, Message: firstLine(err.Error())}
	}
	req.Header.Set("Accept", "application/json")
	if r.contentType != "" {
		req.Header.Set("Content-Type", r.contentType)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return nil, ctx.Err()
		}
		return nil, c.transportError(ctx, err)
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp, nil
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
	return nil, c.statusError(ctx, resp.StatusCode, data, r)
}

func (c *client) getJSON(ctx context.Context, r request, out any) error {
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	r.method = http.MethodGet
	resp, err := c.do(ctx, r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return c.bodyError(ctx, err)
	}
	return nil
}

func (c *client) bodyError(ctx context.Context, err error) error {
	var syntax *json.SyntaxError
	var typ *json.UnmarshalTypeError
	if errors.As(err, &syntax) || errors.As(err, &typ) {
		return &Error{Kind: KindOther, Server: c.server, Message: fmt.Sprintf("The cluster at %s sent a response GoLens can’t read.", c.server)}
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return ctx.Err()
	}
	return c.transportError(ctx, err)
}

func (c *client) stream(ctx context.Context, r request) (*http.Response, context.CancelFunc, error) {
	ctx, cancel := context.WithCancel(ctx)
	headers := time.AfterFunc(requestTimeout, cancel)
	resp, err := c.do(ctx, r)
	waited := !headers.Stop()
	if err != nil {
		cancel()
		if waited && errors.Is(err, context.Canceled) {
			return nil, nil, &Error{Kind: KindUnreachable, Server: c.server, Message: fmt.Sprintf("The cluster at %s didn’t answer in time.", c.server)}
		}
		return nil, nil, err
	}
	return resp, cancel, nil
}

type apiStatus struct {
	Kind    string `json:"kind"`
	Status  string `json:"status"`
	Message string `json:"message"`
	Reason  string `json:"reason"`
	Code    int    `json:"code"`
	Details struct {
		Name string `json:"name"`
		Kind string `json:"kind"`
	} `json:"details"`
}

func (c *client) statusError(ctx context.Context, code int, body []byte, r request) *Error {
	var st apiStatus
	_ = json.Unmarshal(body, &st)
	switch code {
	case http.StatusForbidden:
		e := &Error{Kind: KindForbidden, status: code, Verb: r.verb, Resource: r.resource, Namespace: r.namespace}
		if r.namespace != "" {
			e.Message = fmt.Sprintf("Your account can’t %s %s in “%s”.", r.verb, r.resource, r.namespace)
		} else {
			e.Message = fmt.Sprintf("Your account can’t %s %s in this cluster.", r.verb, r.resource)
		}
		return e
	case http.StatusUnauthorized:
		if c.exec != nil {
			e := c.signInError("")
			e.status = code
			return e
		}
		return &Error{Kind: KindUnauthorized, status: code, Server: c.server,
			Message: fmt.Sprintf("The cluster of “%s” didn’t accept your credentials.", c.context)}
	case http.StatusNotFound:
		return &Error{Kind: KindNotFound, status: code, Message: notFoundMessage(st, r)}
	}
	msg := sentence(st.Message)
	if msg == "" {
		msg = fmt.Sprintf("The cluster answered with HTTP %d.", code)
	}
	return &Error{Kind: KindOther, status: code, Message: msg}
}

var objectNouns = map[string]string{
	"pods": "pod", "deployments": "deployment", "services": "service", "namespaces": "namespace",
	"events": "event", "replicasets": "replica set", "pods/log": "pod",
}

func notFoundMessage(st apiStatus, r request) string {
	kind := st.Details.Kind
	if kind == "" {
		kind = r.resource
	}
	noun := objectNouns[kind]
	switch {
	case st.Details.Name == "" || noun == "":
		if r.namespace != "" {
			return fmt.Sprintf("The object no longer exists in “%s”.", r.namespace)
		}
		return "The object no longer exists."
	case noun == "namespace":
		return fmt.Sprintf("The namespace “%s” doesn’t exist.", st.Details.Name)
	case r.namespace != "":
		return fmt.Sprintf("The %s “%s” doesn’t exist in “%s”.", noun, st.Details.Name, r.namespace)
	}
	return fmt.Sprintf("The %s “%s” doesn’t exist.", noun, st.Details.Name)
}

func sentence(s string) string {
	s = firstLine(s)
	if s == "" {
		return ""
	}
	s = strings.ToUpper(s[:1]) + s[1:]
	if !strings.HasSuffix(s, ".") {
		s += "."
	}
	return s
}

func (c *client) transportError(ctx context.Context, err error) *Error {
	msg := err.Error()
	if i := strings.Index(msg, "exec: executable "); i >= 0 && c.exec != nil {
		rest := msg[i:]
		if strings.Contains(rest, " not found") {
			return pluginMissing(c.context, filepath.Base(c.exec.Command))
		}
		return c.diagnosePlugin(ctx)
	}
	if strings.Contains(msg, "getting credentials:") && c.exec != nil {
		return c.diagnosePlugin(ctx)
	}
	e := &Error{Kind: KindUnreachable, Server: c.server}
	var unknownAuthority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var netErr net.Error
	switch {
	case errors.As(err, &unknownAuthority), errors.As(err, &hostname), errors.As(err, &invalid):
		e.Message = fmt.Sprintf("GoLens can’t verify the certificate of the cluster at %s.", c.server)
	case errors.As(err, &netErr) && netErr.Timeout():
		e.Message = fmt.Sprintf("The cluster at %s didn’t answer in time.", c.server)
	default:
		e.Message = fmt.Sprintf("GoLens can’t reach the cluster at %s.", c.server)
	}
	return e
}

var signInHints = []string{
	"sso", "expired", "reauth", "re-auth", "login", "log in", "sign in", "sign-in", "browser", "devicecode",
	"device code", "interactive", "refresh token", "invalid_grant", "aadsts", "credentials",
}

func (c *client) diagnosePlugin(ctx context.Context) *Error {
	plugin := filepath.Base(c.exec.Command)
	stderr := runPluginForDiagnosis(ctx, c.exec)
	low := strings.ToLower(stderr)
	for _, h := range signInHints {
		if strings.Contains(low, h) {
			return c.signInError(low)
		}
	}
	e := &Error{Kind: KindPluginFailed, Plugin: plugin, Server: c.server,
		Message: fmt.Sprintf("The credential helper “%s” for “%s” failed.", plugin, c.context)}
	if line := firstLine(stderr); line != "" {
		e.Message = fmt.Sprintf("The credential helper “%s” for “%s” failed: %s", plugin, c.context, strings.TrimSuffix(line, ".")+".")
	}
	return e
}

func (c *client) signInError(low string) *Error {
	plugin := ""
	var cmd []string
	if c.exec != nil {
		plugin = filepath.Base(c.exec.Command)
		cmd = signInCommand(c.exec, low)
	}
	e := &Error{Kind: KindNeedsSignIn, Plugin: plugin, Server: c.server, SignInCommand: cmd}
	if cmd != nil {
		e.Message = fmt.Sprintf("Your sign-in for “%s” has expired; run “%s” in Terminal to sign in again.", c.context, strings.Join(cmd, " "))
	} else {
		e.Message = fmt.Sprintf("Your sign-in for “%s” has expired; sign in again in Terminal.", c.context)
	}
	return e
}

func runPluginForDiagnosis(ctx context.Context, ex *clientcmdapi.ExecConfig) string {
	ctx, cancel := context.WithTimeout(ctx, pluginDiagnoseLimit)
	defer cancel()
	cmd := exec.CommandContext(ctx, ex.Command, ex.Args...)
	env := docker.Env()
	for _, e := range ex.Env {
		env = append(env, e.Name+"="+e.Value)
	}
	apiVersion := ex.APIVersion
	if apiVersion == "" {
		apiVersion = "client.authentication.k8s.io/v1"
	}
	env = append(env, `KUBERNETES_EXEC_INFO={"apiVersion":"`+apiVersion+`","kind":"ExecCredential","spec":{"interactive":false}}`)
	cmd.Env = env
	var stderr limitedBuffer
	cmd.Stdout = io.Discard
	cmd.Stderr = &stderr
	cmd.WaitDelay = time.Second
	_ = cmd.Run()
	return strings.TrimSpace(stderr.String())
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := maxPluginStderrBytes - b.Len(); room > 0 {
		b.Buffer.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func argValue(args []string, names ...string) string {
	for i, a := range args {
		for _, n := range names {
			if a == n && i+1 < len(args) {
				return args[i+1]
			}
			if v, ok := strings.CutPrefix(a, n+"="); ok {
				return v
			}
		}
	}
	return ""
}

func envValue(env []clientcmdapi.ExecEnvVar, name string) string {
	for _, e := range env {
		if e.Name == name {
			return e.Value
		}
	}
	return ""
}

func signInCommand(ex *clientcmdapi.ExecConfig, lowStderr string) []string {
	plugin := filepath.Base(ex.Command)
	switch {
	case plugin == "aws":
		if !strings.Contains(lowStderr, "sso") {
			return nil
		}
		cmd := []string{"aws", "sso", "login"}
		profile := argValue(ex.Args, "--profile")
		if profile == "" {
			profile = envValue(ex.Env, "AWS_PROFILE")
		}
		if profile != "" {
			cmd = append(cmd, "--profile", profile)
		}
		return cmd
	case plugin == "gke-gcloud-auth-plugin", plugin == "gcloud":
		return []string{"gcloud", "auth", "login"}
	case plugin == "kubelogin":
		if argValue(ex.Args, "--login", "-l") == "azurecli" {
			return []string{"az", "login"}
		}
		return append([]string{plugin}, ex.Args...)
	case plugin == "kubectl-oidc_login", plugin == "kubectl" && len(ex.Args) > 0 && ex.Args[0] == "oidc-login":
		return append([]string{plugin}, ex.Args...)
	}
	return nil
}
