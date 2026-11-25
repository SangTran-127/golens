package httpfile

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadEnvironmentsMergesPrivateAndShared(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, PublicEnvFile), `{"$shared":{"version":"v1"},"dev":{"host":"http://localhost:8080","port":8080},"prod":{"host":"https://api.example.com"}}`)
	writeFile(t, filepath.Join(root, PrivateEnvFile), `{"dev":{"token":"secret","host":"http://127.0.0.1:9000"}}`)
	httpPath := filepath.Join(root, "api", "requests", "users.http")
	writeFile(t, httpPath, "GET {{host}}\n")

	envs := LoadEnvironments(httpPath, root)
	if strings.Join(envs.Names, ",") != "dev,prod" {
		t.Fatalf("names = %v", envs.Names)
	}
	dev := envs.Variables("dev")
	if dev["host"] != "http://127.0.0.1:9000" || dev["token"] != "secret" || dev["port"] != "8080" || dev["version"] != "v1" {
		t.Fatalf("dev = %v", dev)
	}
	if envs.Variables("prod")["token"] != "" {
		t.Fatalf("private dev values leaked into prod")
	}
	if !envs.Has("dev") || envs.Has("$shared") || envs.Has("staging") {
		t.Fatalf("Has misreports")
	}
}

func TestLoadEnvironmentsReportsSyntaxErrors(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, PublicEnvFile), "{\n  \"dev\": {\n    \"host\": \n  }\n}")
	envs := LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Issues) != 1 || !strings.Contains(envs.Issues[0].Message, "line 4") {
		t.Fatalf("issues = %+v", envs.Issues)
	}
}

func TestLoadEnvironmentsStopsAtRoot(t *testing.T) {
	outer := t.TempDir()
	writeFile(t, filepath.Join(outer, PublicEnvFile), `{"outside":{}}`)
	root := filepath.Join(outer, "project")
	envs := LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Names) != 0 {
		t.Fatalf("env above the workspace root must not load: %v", envs.Names)
	}
}

func TestResolverPrecedenceAndDynamic(t *testing.T) {
	r := NewResolver(map[string]string{"token": "global"}, map[string]string{"token": "file", "base": "{{host}}/api"}, map[string]string{"token": "env", "host": "http://h"})
	r.Now = func() time.Time { return time.Unix(1700000000, 0) }
	got := r.Resolve("{{ base }}?t={{token}}&ts={{$timestamp}}&u={{missing}}")
	if got != "http://h/api?t=global&ts=1700000000&u={{missing}}" {
		t.Fatalf("resolved = %q", got)
	}
	if m := r.Missing(); len(m) != 1 || m[0] != "missing" {
		t.Fatalf("missing = %v", m)
	}
	id := NewResolver(nil, nil, nil).Resolve("{{$uuid}}")
	if len(id) != 36 || id[14] != '4' {
		t.Fatalf("uuid = %q", id)
	}
	t.Setenv("GOLENS_HTTP_TEST", "fromenv")
	if v := NewResolver(nil, nil, nil).Resolve("{{$env.GOLENS_HTTP_TEST}}"); v != "fromenv" {
		t.Fatalf("env = %q", v)
	}
	n := NewResolver(nil, nil, nil).Resolve("{{$random.integer(5, 6)}}")
	if n != "5" {
		t.Fatalf("random.integer = %q", n)
	}
}

func TestRunHTTPWithEnvironmentIncludesAndHeaders(t *testing.T) {
	var gotBody, gotAuth, gotType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		gotAuth = r.Header.Get("Authorization")
		gotType = r.Header.Get("Content-Type")
		w.Header().Set("Content-Type", "application/json")
		w.Header().Add("X-Multi", "a")
		w.Header().Add("X-Multi", "b")
		w.WriteHeader(201)
		_, _ = w.Write([]byte(`{"id":7,"name":"ok"}`))
	}))
	defer srv.Close()

	root := t.TempDir()
	writeFile(t, filepath.Join(root, PublicEnvFile), `{"dev":{"host":"`+srv.URL+`"}}`)
	writeFile(t, filepath.Join(root, "payload.json"), `{"user":"{{user}}"}`)
	writeFile(t, filepath.Join(root, "tpl.json"), `{"user":"{{user}}"}`)
	content := "@user = ana\n### Create\nPOST {{host}}/users\nAuthorization: Bearer {{token}}\n\n< ./payload.json\n\n### Template\nPOST {{host}}/users\n\n<@ ./tpl.json\n"
	httpPath := filepath.Join(root, "users.http")

	res := Run(RunInput{Path: httpPath, Content: content, WorkspaceRoot: root, Environment: "dev", Index: 0, Globals: map[string]string{"token": "abc"}})
	if res.Error != nil {
		t.Fatalf("error = %+v", res.Error)
	}
	if res.Response.Status != 201 || res.Response.StatusText != "Created" || !res.Response.IsJSON {
		t.Fatalf("response = %+v", res.Response)
	}
	if !strings.Contains(res.Response.PrettyBody, "\n  \"id\": 7") {
		t.Fatalf("pretty = %q", res.Response.PrettyBody)
	}
	if gotAuth != "Bearer abc" || gotBody != `{"user":"{{user}}"}` || gotType != "application/json" {
		t.Fatalf("server saw auth=%q body=%q type=%q", gotAuth, gotBody, gotType)
	}
	multi := 0
	for _, h := range res.Response.Headers {
		if h.Name == "X-Multi" {
			multi++
		}
	}
	if multi != 2 {
		t.Fatalf("multi-value header lost: %+v", res.Response.Headers)
	}
	if res.Request.URL != srv.URL+"/users" || res.Request.Title != "Create" {
		t.Fatalf("resolved request = %+v", res.Request)
	}

	res = Run(RunInput{Path: httpPath, Content: content, WorkspaceRoot: root, Environment: "dev", Index: 1})
	if res.Error != nil || gotBody != `{"user":"ana"}` {
		t.Fatalf("substituting include: err=%+v body=%q", res.Error, gotBody)
	}
}

func TestRunReportsUnresolvedVariables(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, PublicEnvFile), `{"dev":{},"prod":{}}`)
	res := Run(RunInput{Path: filepath.Join(root, "a.http"), Content: "GET {{host}}/x\nAuthorization: {{token}}\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "unresolved" || strings.Join(res.Error.Variables, ",") != "host,token" {
		t.Fatalf("error = %+v", res.Error)
	}
	if !strings.Contains(res.Error.Detail, "No environment is selected") || !strings.Contains(res.Error.Detail, "dev, prod") {
		t.Fatalf("detail = %q", res.Error.Detail)
	}
	res = Run(RunInput{Path: filepath.Join(root, "a.http"), Content: "GET {{host}}/x\n", WorkspaceRoot: root, Environment: "dev"})
	if !strings.Contains(res.Error.Detail, "“dev” does not define it") {
		t.Fatalf("detail = %q", res.Error.Detail)
	}
}

func TestRunReportsMissingBodyFileAndBadIndex(t *testing.T) {
	root := t.TempDir()
	res := Run(RunInput{Path: filepath.Join(root, "a.http"), Content: "POST http://localhost/x\n\n< ./nope.json\n"})
	if res.Error == nil || res.Error.Kind != "file" || !strings.Contains(res.Error.Detail, "does not exist") {
		t.Fatalf("error = %+v", res.Error)
	}
	res = Run(RunInput{Content: "GET http://localhost/\n", Index: 3})
	if res.Error == nil || res.Error.Kind != "parse" {
		t.Fatalf("error = %+v", res.Error)
	}
}

func TestRunRefusesFilesOutsideTheProject(t *testing.T) {
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.json")
	if err := os.WriteFile(secret, []byte(`{"k":"v"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "inside.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(root, "link.json")); err != nil {
		t.Fatal(err)
	}
	httpPath := filepath.Join(root, "a.http")
	rel, err := filepath.Rel(root, secret)
	if err != nil {
		t.Fatal(err)
	}
	for _, include := range []string{"< " + secret, "< ./" + rel, "< ./link.json", "> " + secret} {
		content := "POST http://localhost/x\n\n" + include + "\n"
		if strings.HasPrefix(include, ">") {
			content = "POST http://localhost/x\n\n{}\n\n" + include + "\n"
		}
		res := Run(RunInput{Path: httpPath, Content: content, WorkspaceRoot: root})
		if res.Error == nil || res.Error.Kind != "file" || !strings.Contains(res.Error.Message, "outside the project") {
			t.Fatalf("%q: error = %+v", include, res.Error)
		}
	}
	res := Run(RunInput{Path: httpPath, Content: "POST http://127.0.0.1:1/x\n\n< ./inside.json\n", WorkspaceRoot: root})
	if res.Error != nil && strings.Contains(res.Error.Message, "outside the project") {
		t.Fatalf("a file inside the project was refused: %+v", res.Error)
	}
}

func TestRunConnectionRefusedIsPlainLanguage(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	res := Run(RunInput{Content: "GET http://" + addr + "/\n", TimeoutSec: 3})
	if res.Error == nil || res.Error.Kind != "network" || !strings.Contains(res.Error.Message, "Could not connect to "+addr) {
		t.Fatalf("error = %+v", res.Error)
	}
}

func TestRunTimeoutAndCancel(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)

	res := Run(RunInput{Content: "# @timeout 1\nGET " + srv.URL + "\n"})
	if res.Error == nil || res.Error.Kind != "timeout" || !strings.Contains(res.Error.Message, "1 seconds") {
		t.Fatalf("timeout error = %+v", res.Error)
	}

	done := make(chan RunResult)
	go func() { done <- Run(RunInput{Content: "GET " + srv.URL + "\n", RunID: "run-1", TimeoutSec: 10}) }()
	deadline := time.Now().Add(2 * time.Second)
	for !Cancel("run-1") {
		if time.Now().After(deadline) {
			t.Fatal("run never registered for cancellation")
		}
		time.Sleep(10 * time.Millisecond)
	}
	res = <-done
	if res.Error == nil || res.Error.Kind != "cancelled" {
		t.Fatalf("cancel error = %+v", res.Error)
	}
}

func TestRunNoRedirectAndTruncation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/old" {
			http.Redirect(w, r, "/new", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte(strings.Repeat("x", MaxResponseBytes+10)))
	}))
	defer srv.Close()
	res := Run(RunInput{Content: "# @no-redirect\nGET " + srv.URL + "/old\n"})
	if res.Error != nil || res.Response.Status != 302 {
		t.Fatalf("no-redirect = %+v %+v", res.Error, res.Response)
	}
	res = Run(RunInput{Content: "GET " + srv.URL + "/old\n"})
	if res.Error != nil || res.Response.Status != 200 || !res.Response.Truncated || res.Response.Size != MaxResponseBytes {
		t.Fatalf("follow+truncate = %+v size=%d", res.Error, res.Response.Size)
	}
}

func startGRPC(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := grpc.NewServer()
	hs := health.NewServer()
	hs.SetServingStatus("orders", healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(s, hs)
	reflection.Register(s)
	go func() { _ = s.Serve(ln) }()
	t.Cleanup(s.Stop)
	return ln.Addr().String()
}

func TestGRPCUnaryViaReflection(t *testing.T) {
	addr := startGRPC(t)
	content := "GRPC " + addr + "/grpc.health.v1.Health/Check\nx-trace: 1\n\n{\"service\": \"orders\"}\n"
	res := Run(RunInput{Content: content, TimeoutSec: 5})
	if res.Error != nil {
		t.Fatalf("error = %+v", res.Error)
	}
	if res.Response.Status != 0 || res.Response.StatusText != "OK" || res.Response.Protocol != "gRPC" {
		t.Fatalf("status = %+v", res.Response)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(res.Response.Body), &body); err != nil || body["status"] != "SERVING" {
		t.Fatalf("body = %q err=%v", res.Response.Body, err)
	}

	res = Run(RunInput{Content: "GRPC " + addr + "/grpc.health.v1.Health/Check\n\n{\"service\": \"unknown\"}\n", TimeoutSec: 5})
	if res.Error != nil || res.Response.Status != 5 || res.Response.StatusText != "NotFound" {
		t.Fatalf("not found = %+v %+v", res.Error, res.Response)
	}
}

func TestGRPCErrorsArePlainLanguage(t *testing.T) {
	addr := startGRPC(t)
	cases := []struct{ content, want string }{
		{"GRPC " + addr + "/grpc.health.v1.Health/Nope\n", "has no method Nope"},
		{"GRPC " + addr + "/no.Such/Method\n", "does not know the service no.Such"},
		{"GRPC " + addr + "/grpc.health.v1.Health/Check\n\n{\"bogus\": 1}\n", "does not match grpc.health.v1.HealthCheckRequest"},
		{"GRPC " + addr + "\n", "needs a method"},
	}
	for _, c := range cases {
		res := Run(RunInput{Content: c.content, TimeoutSec: 5})
		if res.Error == nil || res.Error.Kind != "grpc" && res.Error.Kind != "parse" || !strings.Contains(res.Error.Message, c.want) {
			t.Fatalf("%q -> %+v", c.content, res.Error)
		}
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := ln.Addr().String()
	ln.Close()
	res := Run(RunInput{Content: "GRPC " + dead + "/grpc.health.v1.Health/Check\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "Could not connect to "+dead) {
		t.Fatalf("dead = %+v", res.Error)
	}
}

func TestGRPCServerStreaming(t *testing.T) {
	addr := startGRPC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	resp, err := ExecuteGRPC(ctx, ResolvedRequest{URL: addr + "/grpc.health.v1.Health/Watch", Body: `{"service":"orders"}`})
	if err != nil && err != context.DeadlineExceeded {
		t.Fatalf("watch err = %v", err)
	}
	_ = resp
}

func TestParseGRPCTarget(t *testing.T) {
	g, err := ParseGRPCTarget("grpcs://api.example.com/pkg.v1.Svc/Do")
	if err != nil || !g.TLS || g.Address != "api.example.com:443" || g.Service != "pkg.v1.Svc" || g.Method != "Do" {
		t.Fatalf("target = %+v err=%v", g, err)
	}
	g, err = ParseGRPCTarget("localhost:50051/Svc/Do")
	if err != nil || g.TLS || g.Address != "localhost:50051" || g.Service != "Svc" {
		t.Fatalf("target = %+v err=%v", g, err)
	}
}
