package httpfile

import (
	"context"
	"encoding/json"
	"errors"
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
	"google.golang.org/grpc/codes"
	reflectv1 "google.golang.org/grpc/reflection/grpc_reflection_v1"
	reflectv1alpha "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

func TestEnvironmentTemplateAndErrorFiles(t *testing.T) {
	def := EnvironmentTemplate(nil)
	var m map[string]map[string]string
	if err := json.Unmarshal([]byte(def), &m); err != nil || m["dev"]["host"] == "" {
		t.Fatalf("default template invalid: %q err=%v", def, err)
	}
	multi := EnvironmentTemplate([]string{"dev", "prod"})
	if err := json.Unmarshal([]byte(multi), &m); err != nil || len(m) != 2 {
		t.Fatalf("multi template invalid: %q err=%v", multi, err)
	}

	root := t.TempDir()
	writeFile(t, filepath.Join(root, PublicEnvFile), "   \n")
	envs := LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Names) != 0 || len(envs.Issues) != 0 {
		t.Fatalf("whitespace env file = %+v", envs)
	}

	writeFile(t, filepath.Join(root, PublicEnvFile), `["not","an","object"]`)
	envs = LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Issues) != 1 || !strings.Contains(envs.Issues[0].Message, "is not a JSON object") {
		t.Fatalf("array json issues = %+v", envs.Issues)
	}

	writeFile(t, filepath.Join(root, PublicEnvFile), `{"dev":"not-an-object"}`)
	envs = LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Issues) != 1 || !strings.Contains(envs.Issues[0].Message, "must be an object") {
		t.Fatalf("bad env entry issues = %+v", envs.Issues)
	}

	writeFile(t, filepath.Join(root, PublicEnvFile), `{"dev":{"ok":true,"n":42,"obj":{"a":1}}}`)
	envs = LoadEnvironments(filepath.Join(root, "a.http"), root)
	if len(envs.Issues) != 0 || envs.Variables("dev")["ok"] != "true" || envs.Variables("dev")["n"] != "42" {
		t.Fatalf("rawToString non-strings = %+v issues=%+v", envs.Variables("dev"), envs.Issues)
	}

	if os.Geteuid() != 0 {
		if err := os.Chmod(filepath.Join(root, PublicEnvFile), 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, PublicEnvFile), 0o644) })
		envs = LoadEnvironments(filepath.Join(root, "a.http"), root)
		if len(envs.Issues) != 1 || !strings.Contains(envs.Issues[0].Message, "could not be read") {
			t.Fatalf("unreadable env file issues = %+v", envs.Issues)
		}
	}

	dirAsEnv := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dirAsEnv, PublicEnvFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := findUpwards(dirAsEnv, dirAsEnv, PublicEnvFile); got != "" {
		t.Fatalf("directory named %s should be ignored, got %q", PublicEnvFile, got)
	}
	if got := findUpwards(dirAsEnv, "", PublicEnvFile); got != "" {
		t.Fatalf("empty root should stop in dir, got %q", got)
	}
}

func TestParserMalformedAndEdgeBranches(t *testing.T) {
	for _, bad := range []string{"@noequals\n", "@ = empty\n", "@bad name = x\n", "@brace{a} = y\n"} {
		if f := Parse(bad); len(f.Variables) != 0 {
			t.Fatalf("invalid variable %q should not be recorded: %+v", bad, f.Variables)
		}
	}
	f := Parse("# @timeout=7s\n# @unknown val\n# @timeout invalid\nDELETE https://example.com\n    /v1/items HTTP/1.1\n# header comment\nX-A: 1\n\nbody line\n>> ./resp.json\n<> ./prev.json\n> {%\n  var a = 1;\n")
	if len(f.Requests) != 1 {
		t.Fatalf("requests = %+v", f.Requests)
	}
	r := f.Requests[0]
	if r.TimeoutSec != 7 || r.Method != "DELETE" || !strings.Contains(r.URL, "/v1/items") {
		t.Fatalf("parsed request = %+v", r)
	}
	if len(r.Headers) != 1 || r.Headers[0].Name != "X-A" {
		t.Fatalf("headers = %+v", r.Headers)
	}
	if !strings.Contains(r.Handler, "var a = 1;") {
		t.Fatalf("unclosed handler script = %q", r.Handler)
	}

	f2 := Parse("GET https://example.com\n  not-a-continuation\n\n> {% firstLine();\n  secondLine(); %}\n")
	if len(f2.Requests) != 1 || !strings.Contains(f2.Requests[0].Handler, "firstLine()") || !strings.Contains(f2.Requests[0].Handler, "secondLine()") {
		t.Fatalf("multiline handler with first-line code = %+v", f2.Requests)
	}

	if _, ok := RequestAtLine(Parse(""), 1); ok {
		t.Fatal("empty file should not match RequestAtLine")
	}
	if _, ok := RequestAtLine(Parse("@a = 1\n\n### R\nGET /x\n"), 1); ok {
		t.Fatal("line before first request should not match RequestAtLine")
	}
	if got := Parse("GET\n"); len(got.Requests) != 1 || got.Requests[0].Method != "GET" {
		t.Fatalf("bare GET = %+v", got.Requests)
	}
}

func TestResolverDepthAndDynamicEdges(t *testing.T) {
	cycle := NewResolver(nil, map[string]string{"a": "{{b}}", "b": "{{a}}"}, nil)
	if got := cycle.Resolve("{{a}}"); !strings.Contains(got, "{{") {
		t.Fatalf("cyclic var should stop at depth limit, got %q", got)
	}

	t.Setenv("GOLENS_PROCESS_ENV_TEST", "pval")
	r := NewResolver(nil, nil, nil)
	r.Now = func() time.Time { return time.Unix(1700000000, 0).UTC() }

	out := r.Resolve("{{$random.uuid}}|{{$isoTimestamp}}|{{$randomInt}}|{{$random.integer}}|{{$random.integer(bad,5)}}|{{$random.integer(10,5)}}|{{$random.integer)(}}|{{$processEnv.GOLENS_PROCESS_ENV_TEST}}|{{$env.GOLENS_MISSING_XYZ}}|{{$unknownDyn}}")
	parts := strings.Split(out, "|")
	if len(parts) != 10 {
		t.Fatalf("parts = %v", parts)
	}
	if len(parts[0]) != 36 || parts[1] != "2023-11-14T22:13:20Z" || parts[7] != "pval" {
		t.Fatalf("dynamic resolved = %v", parts)
	}
	if parts[8] != "{{$env.GOLENS_MISSING_XYZ}}" || parts[9] != "{{$unknownDyn}}" {
		t.Fatalf("missing dynamic vars = %v", parts)
	}
	missing := r.Missing()
	if len(missing) != 2 {
		t.Fatalf("Missing() = %v", missing)
	}
}

func TestRunAndExecuteHTTPErrorPaths(t *testing.T) {
	if Cancel("does-not-exist") {
		t.Fatal("Cancel of unknown run should return false")
	}

	root := t.TempDir()
	httpPath := filepath.Join(root, "api.http")
	writeFile(t, filepath.Join(root, "body.json"), `{"a":1}`)
	writeFile(t, filepath.Join(root, "check.js"), `client.test("ok", function(){});`)
	if err := os.MkdirAll(filepath.Join(root, "subdir"), 0o755); err != nil {
		t.Fatal(err)
	}

	res := Run(RunInput{Path: httpPath, Content: "GET https://example.com\n", WorkspaceRoot: root, Index: -1})
	if res.Error == nil || res.Error.Kind != "parse" {
		t.Fatalf("negative index = %+v", res.Error)
	}

	res = Run(RunInput{Path: httpPath, Content: "GET {{soloMissing}}/x\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "unresolved" || !strings.Contains(res.Error.Message, "Variable {{soloMissing}}") || !strings.Contains(res.Error.Detail, "Define it in an http-client.env.json") {
		t.Fatalf("single missing var = %+v", res.Error)
	}

	res = Run(RunInput{Path: httpPath, Content: "@empty =\nGET {{empty}}\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "parse" || !strings.Contains(res.Error.Message, "no URL") {
		t.Fatalf("empty URL = %+v", res.Error)
	}

	res = Run(RunInput{Path: httpPath, Content: "POST http://127.0.0.1:1/x\n\n< ./missing.json\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "file" || !strings.Contains(res.Error.Detail, "does not exist") {
		t.Fatalf("missing body file = %+v", res.Error)
	}

	res = Run(RunInput{Path: httpPath, Content: "POST http://127.0.0.1:1/x\n\n< ./subdir\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "file" {
		t.Fatalf("dir as body file = %+v", res.Error)
	}

	res = Run(RunInput{Path: httpPath, Content: "POST http://127.0.0.1:1/x\n\n< ./body.json\n\n> ./missing.js\n", WorkspaceRoot: root})
	if res.Error == nil || res.Error.Kind != "file" || !strings.Contains(res.Error.Message, "response handler") {
		t.Fatalf("missing handler = %+v", res.Error)
	}

	if os.Geteuid() != 0 {
		lockedBody := filepath.Join(root, "locked.json")
		writeFile(t, lockedBody, `{}`)
		if err := os.Chmod(lockedBody, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(lockedBody, 0o644) })
		res = Run(RunInput{Path: httpPath, Content: "POST http://127.0.0.1:1/x\n\n< ./locked.json\n", WorkspaceRoot: root})
		if res.Error == nil || res.Error.Kind != "file" || !strings.Contains(res.Error.Detail, "permission") {
			t.Fatalf("permission error = %+v", res.Error)
		}
	}

	var gotHost, gotUA, gotCT, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		gotHost = r.Host
		gotUA = r.Header.Get("User-Agent")
		gotCT = r.Header.Get("Content-Type")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{bad json"))
	}))
	defer srv.Close()

	absBody := filepath.Join(root, "body.json")
	content := "POST " + strings.TrimPrefix(srv.URL, "http://") + "/items\nHost: custom.local\nUser-Agent: CustomAgent/1\n\n[1,2]\n\n> ./check.js\n"
	res = Run(RunInput{Path: httpPath, Content: content, WorkspaceRoot: root})
	if res.Error != nil {
		t.Fatalf("http run err = %+v", res.Error)
	}
	if gotHost != "custom.local" || gotUA != "CustomAgent/1" || gotCT != "application/json" || gotBody != "[1,2]" {
		t.Fatalf("server saw host=%q ua=%q ct=%q body=%q", gotHost, gotUA, gotCT, gotBody)
	}
	if res.Response.IsJSON || res.Request.HandlerName != "check.js" || res.Request.HandlerLine != 1 {
		t.Fatalf("resp=%+v req=%+v", res.Response, res.Request)
	}

	res = Run(RunInput{Path: httpPath, Content: "POST " + srv.URL + "/items\n\n< " + absBody + "\n", WorkspaceRoot: root})
	if res.Error != nil || gotBody != `{"a":1}` {
		t.Fatalf("abs inside root err=%+v body=%q", res.Error, gotBody)
	}

	for _, badURL := range []string{"://", "http:///onlypath", "http://[::1", "http://bad host/x"} {
		res = Run(RunInput{Content: "GET " + badURL + "\n", TimeoutSec: 2})
		if res.Error == nil || res.Error.Kind != "parse" {
			t.Fatalf("badURL %q -> %+v", badURL, res.Error)
		}
	}
	if (&urlError{raw: "bad"}).Error() != "invalid URL bad" {
		t.Fatal("urlError.Error mismatch")
	}

	truncSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Fatal("hijack unsupported")
		}
		conn, buf, err := hj.Hijack()
		if err != nil {
			t.Fatal(err)
		}
		_, _ = buf.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhello")
		_ = buf.Flush()
		_ = conn.Close()
	}))
	defer truncSrv.Close()
	if _, err := ExecuteHTTP(context.Background(), ResolvedRequest{Method: "GET", URL: truncSrv.URL}, false); err == nil {
		t.Fatal("expected error for truncated HTTP body")
	}

	tlsSrv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer tlsSrv.Close()
	res = Run(RunInput{Content: "GET " + tlsSrv.URL + "\n", TimeoutSec: 3})
	if res.Error == nil || res.Error.Kind != "network" || !strings.Contains(res.Error.Message, "certificate") {
		t.Fatalf("untrusted TLS = %+v", res.Error)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ExecuteHTTP(ctx, ResolvedRequest{Method: "GET", URL: srv.URL}, false); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled ExecuteHTTP = %v", err)
	}

	dnsRunErr := classifyError(context.Background(), &net.DNSError{Name: "missing.invalid"}, ResolvedRequest{URL: "http://missing.invalid"}, 5)
	if dnsRunErr.Kind != "network" || !strings.Contains(dnsRunErr.Message, "missing.invalid") {
		t.Fatalf("dns error = %+v", dnsRunErr)
	}
	genericErr := classifyError(context.Background(), errors.New("boom"), ResolvedRequest{URL: "not a url ://"}, 5)
	if genericErr.Kind != "network" || !strings.Contains(genericErr.Message, "failed") {
		t.Fatalf("generic error = %+v", genericErr)
	}
}

func TestParseGRPCTargetErrorsAndSchemes(t *testing.T) {
	if (&grpcError{message: "oops"}).Error() != "oops" {
		t.Fatal("grpcError.Error mismatch")
	}
	if g, err := ParseGRPCTarget("https://api.example.com/pkg.Svc/Call"); err != nil || !g.TLS || g.Address != "api.example.com:443" {
		t.Fatalf("https target = %+v err=%v", g, err)
	}
	if g, err := ParseGRPCTarget("http://api.example.com/pkg.Svc/Call"); err != nil || g.TLS || g.Address != "api.example.com:80" {
		t.Fatalf("http target = %+v err=%v", g, err)
	}
	if g, err := ParseGRPCTarget("grpc://localhost:9090/pkg.Svc/Call"); err != nil || g.TLS || g.Address != "localhost:9090" {
		t.Fatalf("grpc target = %+v err=%v", g, err)
	}
	for _, bad := range []string{"", "localhost:50051", "/pkg.Svc/Call", "localhost:50051/OnlySvc", "localhost:50051/", "localhost:50051//Do"} {
		if _, err := ParseGRPCTarget(bad); err == nil {
			t.Fatalf("expected error for %q", bad)
		}
	}
}

func makeTestProtos() (depFD, mainFD *descriptorpb.FileDescriptorProto, depRaw, mainRaw []byte) {
	depFD = &descriptorpb.FileDescriptorProto{
		Name:    proto.String("dep.proto"),
		Package: proto.String("test.v1"),
		Syntax:  proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{
			{
				Name: proto.String("Msg"),
				Field: []*descriptorpb.FieldDescriptorProto{
					{
						Name:     proto.String("text"),
						Number:   proto.Int32(1),
						Label:    descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
						Type:     descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
						JsonName: proto.String("text"),
					},
				},
			},
		},
	}
	mainFD = &descriptorpb.FileDescriptorProto{
		Name:       proto.String("svc.proto"),
		Package:    proto.String("test.v1"),
		Syntax:     proto.String("proto3"),
		Dependency: []string{"dep.proto"},
		Service: []*descriptorpb.ServiceDescriptorProto{
			{
				Name: proto.String("Echo"),
				Method: []*descriptorpb.MethodDescriptorProto{
					{
						Name:       proto.String("Unary"),
						InputType:  proto.String(".test.v1.Msg"),
						OutputType: proto.String(".test.v1.Msg"),
					},
					{
						Name:            proto.String("StreamOut"),
						InputType:       proto.String(".test.v1.Msg"),
						OutputType:      proto.String(".test.v1.Msg"),
						ServerStreaming: proto.Bool(true),
					},
					{
						Name:            proto.String("StreamIn"),
						InputType:       proto.String(".test.v1.Msg"),
						OutputType:      proto.String(".test.v1.Msg"),
						ClientStreaming: proto.Bool(true),
					},
				},
			},
		},
	}
	depRaw, _ = proto.Marshal(depFD)
	mainRaw, _ = proto.Marshal(mainFD)
	return depFD, mainFD, depRaw, mainRaw
}

type fakeV1Reflect struct {
	reflectv1.UnimplementedServerReflectionServer
	onSymbol func(string) *reflectv1.ServerReflectionResponse
	onFile   func(string) *reflectv1.ServerReflectionResponse
	streamErr error
}

func (f *fakeV1Reflect) ServerReflectionInfo(stream reflectv1.ServerReflection_ServerReflectionInfoServer) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if f.streamErr != nil {
			return f.streamErr
		}
		var resp *reflectv1.ServerReflectionResponse
		switch r := req.MessageRequest.(type) {
		case *reflectv1.ServerReflectionRequest_FileContainingSymbol:
			if f.onSymbol != nil {
				resp = f.onSymbol(r.FileContainingSymbol)
			}
		case *reflectv1.ServerReflectionRequest_FileByFilename:
			if f.onFile != nil {
				resp = f.onFile(r.FileByFilename)
			}
		}
		if resp == nil {
			resp = &reflectv1.ServerReflectionResponse{
				MessageResponse: &reflectv1.ServerReflectionResponse_ErrorResponse{
					ErrorResponse: &reflectv1.ErrorResponse{ErrorCode: int32(codes.NotFound), ErrorMessage: "not found"},
				},
			}
		}
		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

type fakeV1AlphaReflect struct {
	reflectv1alpha.UnimplementedServerReflectionServer
	depRaw    []byte
	mainRaw   []byte
	streamErr error
}

func (f *fakeV1AlphaReflect) ServerReflectionInfo(stream reflectv1alpha.ServerReflection_ServerReflectionInfoServer) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if f.streamErr != nil {
			return f.streamErr
		}
		var resp *reflectv1alpha.ServerReflectionResponse
		switch r := req.MessageRequest.(type) {
		case *reflectv1alpha.ServerReflectionRequest_FileContainingSymbol:
			if r.FileContainingSymbol == "test.v1.Echo" {
				resp = &reflectv1alpha.ServerReflectionResponse{
					MessageResponse: &reflectv1alpha.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1alpha.FileDescriptorResponse{FileDescriptorProto: [][]byte{f.mainRaw}},
					},
				}
			}
		case *reflectv1alpha.ServerReflectionRequest_FileByFilename:
			if r.FileByFilename == "dep.proto" {
				resp = &reflectv1alpha.ServerReflectionResponse{
					MessageResponse: &reflectv1alpha.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1alpha.FileDescriptorResponse{FileDescriptorProto: [][]byte{f.depRaw}},
					},
				}
			}
		}
		if resp == nil {
			resp = &reflectv1alpha.ServerReflectionResponse{
				MessageResponse: &reflectv1alpha.ServerReflectionResponse_ErrorResponse{
					ErrorResponse: &reflectv1alpha.ErrorResponse{ErrorCode: int32(codes.NotFound), ErrorMessage: "missing"},
				},
			}
		}
		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

func startCustomGRPC(t *testing.T, register func(*grpc.Server)) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := grpc.NewServer()
	if register != nil {
		register(s)
	}
	go func() { _ = s.Serve(ln) }()
	t.Cleanup(s.Stop)
	return ln.Addr().String()
}

func mustMsgDesc(depFD *descriptorpb.FileDescriptorProto) protoreflect.MessageDescriptor {
	fd, err := protodesc.NewFile(depFD, nil)
	if err != nil {
		panic(err)
	}
	return fd.Messages().ByName("Msg")
}

func TestGRPCV1AlphaReflectionStreamingAndErrors(t *testing.T) {
	depFD, mainFD, depRaw, mainRaw := makeTestProtos()

	noReflectAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{streamErr: status.Error(codes.Unimplemented, "no v1")})
		reflectv1alpha.RegisterServerReflectionServer(s, &fakeV1AlphaReflect{streamErr: status.Error(codes.Unimplemented, "no v1alpha")})
	})
	res := Run(RunInput{Content: "GRPC " + noReflectAddr + "/pkg.Svc/Call\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "does not offer server reflection") {
		t.Fatalf("no reflection = %+v", res.Error)
	}

	alphaAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{streamErr: status.Error(codes.Unimplemented, "use v1alpha")})
		reflectv1alpha.RegisterServerReflectionServer(s, &fakeV1AlphaReflect{depRaw: depRaw, mainRaw: mainRaw})
		s.RegisterService(&grpc.ServiceDesc{
			ServiceName: "test.v1.Echo",
			HandlerType: (*any)(nil),
			Streams: []grpc.StreamDesc{
				{
					StreamName:    "StreamOut",
					ServerStreams: true,
					Handler: func(srv any, stream grpc.ServerStream) error {
						in := dynamicpb.NewMessage(mustMsgDesc(depFD))
						_ = stream.RecvMsg(in)
						out1 := dynamicpb.NewMessage(mustMsgDesc(depFD))
						out1.Set(out1.Descriptor().Fields().ByName("text"), protoreflect.ValueOfString("first"))
						out2 := dynamicpb.NewMessage(mustMsgDesc(depFD))
						out2.Set(out2.Descriptor().Fields().ByName("text"), protoreflect.ValueOfString("second"))
						if err := stream.SendMsg(out1); err != nil {
							return err
						}
						return stream.SendMsg(out2)
					},
				},
			},
		}, struct{}{})
	})

	resp, err := ExecuteGRPC(context.Background(), ResolvedRequest{
		URL:  alphaAddr + "/test.v1.Echo/StreamOut",
		Body: "",
	})
	if err != nil {
		t.Fatalf("v1alpha streaming ExecuteGRPC = %v", err)
	}
	if resp.Status != 0 || !resp.IsJSON || !strings.Contains(resp.Body, "first") || !strings.Contains(resp.Body, "second") {
		t.Fatalf("streaming response = %+v", resp)
	}

	res = Run(RunInput{Content: "GRPC " + alphaAddr + "/test.v1.Echo/StreamIn\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "streams requests from the client") {
		t.Fatalf("client streaming error = %+v", res.Error)
	}

	corruptSymbolAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			onSymbol: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{{0xff, 0xff, 0x01}}},
					},
				}
			},
		})
	})
	res = Run(RunInput{Content: "GRPC " + corruptSymbolAddr + "/test.v1.Echo/Unary\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "could not read") {
		t.Fatalf("corrupt descriptor = %+v", res.Error)
	}

	missingDepAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			onSymbol: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{mainRaw}},
					},
				}
			},
		})
	})
	res = Run(RunInput{Content: "GRPC " + missingDepAddr + "/test.v1.Echo/Unary\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "did not send the definition file dep.proto") {
		t.Fatalf("missing dep = %+v", res.Error)
	}

	corruptDepAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			onSymbol: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{mainRaw}},
					},
				}
			},
			onFile: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{{0xff, 0xff, 0x01}}},
					},
				}
			},
		})
	})
	res = Run(RunInput{Content: "GRPC " + corruptDepAddr + "/test.v1.Echo/Unary\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "could not read") {
		t.Fatalf("corrupt dep = %+v", res.Error)
	}

	incompleteFD := proto.Clone(mainFD).(*descriptorpb.FileDescriptorProto)
	incompleteFD.Dependency = nil
	incompleteRaw, _ := proto.Marshal(incompleteFD)
	incompleteAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			onSymbol: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{incompleteRaw}},
					},
				}
			},
		})
	})
	res = Run(RunInput{Content: "GRPC " + incompleteAddr + "/test.v1.Echo/Unary\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "incomplete") {
		t.Fatalf("incomplete descriptor = %+v", res.Error)
	}

	notServiceAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			onSymbol: func(string) *reflectv1.ServerReflectionResponse {
				return &reflectv1.ServerReflectionResponse{
					MessageResponse: &reflectv1.ServerReflectionResponse_FileDescriptorResponse{
						FileDescriptorResponse: &reflectv1.FileDescriptorResponse{FileDescriptorProto: [][]byte{depRaw}},
					},
				}
			},
		})
	})
	res = Run(RunInput{Content: "GRPC " + notServiceAddr + "/test.v1.Msg/Do\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "is not a service") {
		t.Fatalf("non-service symbol = %+v", res.Error)
	}

	internalErrAddr := startCustomGRPC(t, func(s *grpc.Server) {
		reflectv1.RegisterServerReflectionServer(s, &fakeV1Reflect{
			streamErr: status.Error(codes.Internal, "boom"),
		})
	})
	res = Run(RunInput{Content: "GRPC " + internalErrAddr + "/test.v1.Echo/Unary\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "Server reflection failed") {
		t.Fatalf("internal reflection error = %+v", res.Error)
	}

	res = Run(RunInput{Content: "GRPC " + alphaAddr + "/test.v1.Missing/Call\n", TimeoutSec: 3})
	if res.Error == nil || !strings.Contains(res.Error.Message, "does not know the service") {
		t.Fatalf("v1alpha unknown service = %+v", res.Error)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ExecuteGRPC(ctx, ResolvedRequest{URL: alphaAddr + "/test.v1.Echo/StreamOut"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled ExecuteGRPC = %v", err)
	}
}

type eofSendV1Stream struct {
	grpc.ClientStream
	recvErr error
}

func (s eofSendV1Stream) Send(*reflectv1.ServerReflectionRequest) error { return io.EOF }
func (s eofSendV1Stream) Recv() (*reflectv1.ServerReflectionResponse, error) {
	return nil, s.recvErr
}

type eofSendV1AlphaStream struct {
	grpc.ClientStream
	recvErr error
}

func (s eofSendV1AlphaStream) Send(*reflectv1alpha.ServerReflectionRequest) error { return io.EOF }
func (s eofSendV1AlphaStream) Recv() (*reflectv1alpha.ServerReflectionResponse, error) {
	return nil, s.recvErr
}

func TestGRPCEOFAndPathGuards(t *testing.T) {
	wantErr := status.Error(codes.Unimplemented, "no reflection")
	if _, err := (v1Stream{stream: eofSendV1Stream{recvErr: wantErr}}).fileContainingSymbol("pkg.Svc"); status.Code(err) != codes.Unimplemented {
		t.Fatalf("v1Stream roundTrip on Send EOF = %v, want codes.Unimplemented", err)
	}
	if _, err := (v1alphaStream{stream: eofSendV1AlphaStream{recvErr: wantErr}}).fileContainingSymbol("pkg.Svc"); status.Code(err) != codes.Unimplemented {
		t.Fatalf("v1alphaStream roundTrip on Send EOF = %v, want codes.Unimplemented", err)
	}

	re := classifyError(context.Background(), &net.OpError{Op: "dial", Net: "tcp", Err: nil}, ResolvedRequest{URL: "http://localhost:8080/a"}, 10)
	if re == nil || re.Kind != "network" {
		t.Fatalf("classifyError nil OpError.Err = %+v", re)
	}

	base := t.TempDir()
	realRoot := filepath.Join(base, "real")
	linkRoot := filepath.Join(base, "link")
	if err := os.MkdirAll(realRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realRoot, linkRoot); err != nil {
		t.Fatal(err)
	}
	missingNested := filepath.Join(linkRoot, "missing_dir", "missing.json")
	if !insideRoot(linkRoot, missingNested) {
		t.Fatalf("insideRoot(%q, %q) = false, want true", linkRoot, missingNested)
	}

	parsedPost := Parse("POST\n")
	if len(parsedPost.Requests) != 1 || parsedPost.Requests[0].Method != "POST" || parsedPost.Requests[0].URL != "" {
		t.Fatalf("Parse POST-only = %+v", parsedPost.Requests)
	}
	parsedDel := Parse("DELETE HTTP/1.1\n")
	if len(parsedDel.Requests) != 1 || parsedDel.Requests[0].Method != "DELETE" || parsedDel.Requests[0].URL != "" || parsedDel.Requests[0].HTTPVersion != "HTTP/1.1" {
		t.Fatalf("Parse DELETE HTTP/1.1 = %+v", parsedDel.Requests)
	}

	parent := t.TempDir()
	proj := filepath.Join(parent, "proj")
	sibling := filepath.Join(parent, "proj2", "sub")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(sibling, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(parent, PublicEnvFile), `{"dev":{"host":"http://parent"}}`)
	if got := findUpwards(sibling, proj, PublicEnvFile); got != "" {
		t.Fatalf("findUpwards escaped proj boundary via prefix: %q", got)
	}
}
