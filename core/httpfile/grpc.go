package httpfile

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	reflectv1 "google.golang.org/grpc/reflection/grpc_reflection_v1"
	reflectv1alpha "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

type grpcError struct {
	message string
	detail  string
}

func (e *grpcError) Error() string { return e.message }

type GRPCTarget struct {
	Address string
	Service string
	Method  string
	TLS     bool
}

func ParseGRPCTarget(raw string) (GRPCTarget, error) {
	t := GRPCTarget{}
	s := strings.TrimSpace(raw)
	lower := strings.ToLower(s)
	switch {
	case strings.HasPrefix(lower, "grpcs://"), strings.HasPrefix(lower, "https://"):
		t.TLS = true
		s = s[strings.Index(s, "://")+3:]
	case strings.HasPrefix(lower, "grpc://"), strings.HasPrefix(lower, "http://"):
		s = s[strings.Index(s, "://")+3:]
	}
	slash := strings.Index(s, "/")
	if slash <= 0 {
		return t, &grpcError{message: "The gRPC address needs a method.", detail: "Write it as GRPC host:port/package.Service/Method, for example GRPC localhost:50051/helloworld.Greeter/SayHello."}
	}
	t.Address = s[:slash]
	path := strings.Trim(s[slash+1:], "/")
	cut := strings.LastIndex(path, "/")
	if cut <= 0 || cut == len(path)-1 {
		return t, &grpcError{message: "“" + path + "” is not a gRPC method.", detail: "Write it as package.Service/Method after the host, for example helloworld.Greeter/SayHello."}
	}
	t.Service = path[:cut]
	t.Method = path[cut+1:]
	if !strings.Contains(t.Address, ":") {
		if t.TLS {
			t.Address += ":443"
		} else {
			t.Address += ":80"
		}
	}
	return t, nil
}

func ExecuteGRPC(ctx context.Context, rr ResolvedRequest) (*Response, error) {
	target, err := ParseGRPCTarget(rr.URL)
	if err != nil {
		return nil, err
	}
	creds := insecure.NewCredentials()
	if target.TLS {
		creds = credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12})
	}
	conn, err := grpc.NewClient(target.Address, grpc.WithTransportCredentials(creds))
	if err != nil {
		return nil, &grpcError{message: "Could not open a connection to " + target.Address + ".", detail: err.Error()}
	}
	defer conn.Close()

	md := metadata.MD{}
	for _, h := range rr.Headers {
		md.Append(strings.ToLower(h.Name), h.Value)
	}
	ctx = metadata.NewOutgoingContext(ctx, md)

	method, err := resolveMethod(ctx, conn, target)
	if err != nil {
		return nil, err
	}
	if method.IsStreamingClient() {
		return nil, &grpcError{message: target.Method + " streams requests from the client.", detail: "Only unary and server-streaming methods can be called from an .http file."}
	}

	input := dynamicpb.NewMessage(method.Input())
	body := strings.TrimSpace(rr.Body)
	if body == "" {
		body = "{}"
	}
	if err := protojson.Unmarshal([]byte(body), input); err != nil {
		return nil, &grpcError{message: "The request body does not match " + string(method.Input().FullName()) + ".", detail: err.Error()}
	}

	fullMethod := "/" + target.Service + "/" + target.Method
	var header, trailer metadata.MD
	start := time.Now()
	var outputs []proto.Message
	var callErr error
	firstByte := int64(0)
	if method.IsStreamingServer() {
		desc := &grpc.StreamDesc{StreamName: target.Method, ServerStreams: true}
		stream, err := conn.NewStream(ctx, desc, fullMethod, grpc.Header(&header), grpc.Trailer(&trailer))
		if err == nil {
			err = stream.SendMsg(input)
		}
		if err == nil {
			err = stream.CloseSend()
		}
		for err == nil {
			out := dynamicpb.NewMessage(method.Output())
			if rerr := stream.RecvMsg(out); rerr != nil {
				if rerr != io.EOF {
					err = rerr
				}
				break
			}
			if firstByte == 0 {
				firstByte = time.Since(start).Milliseconds()
			}
			outputs = append(outputs, out)
		}
		callErr = err
	} else {
		out := dynamicpb.NewMessage(method.Output())
		callErr = conn.Invoke(ctx, fullMethod, input, out, grpc.Header(&header), grpc.Trailer(&trailer))
		if callErr == nil {
			outputs = append(outputs, out)
		}
	}
	total := time.Since(start).Milliseconds()
	if firstByte == 0 {
		firstByte = total
	}

	st, _ := status.FromError(callErr)
	if callErr != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if callErr != nil && st.Code() == codes.Unavailable {
		return nil, &grpcError{message: "Could not connect to " + target.Address + ".", detail: "Nothing answered there. Start your gRPC server, then run the request again. (" + st.Message() + ")"}
	}

	resp := &Response{
		Status:      int(st.Code()),
		StatusText:  st.Code().String(),
		Protocol:    "gRPC",
		Headers:     metadataHeaders(header, trailer),
		ContentType: "application/json",
		Timing:      Timing{FirstByteMs: firstByte, TotalMs: total},
	}
	marshal := protojson.MarshalOptions{Multiline: true, Indent: "  ", EmitUnpopulated: true}
	switch {
	case callErr != nil:
		payload := map[string]any{"code": st.Code().String(), "message": st.Message()}
		resp.Body = mustJSON(payload)
	case method.IsStreamingServer():
		parts := make([]string, 0, len(outputs))
		for _, o := range outputs {
			b, _ := marshal.Marshal(o)
			parts = append(parts, string(b))
		}
		resp.Body = "[" + strings.Join(parts, ",\n") + "]"
	case len(outputs) == 1:
		b, _ := marshal.Marshal(outputs[0])
		resp.Body = string(b)
	}
	resp.Size = len(resp.Body)
	resp.IsJSON, resp.PrettyBody = prettyJSON(resp.ContentType, []byte(resp.Body))
	return resp, nil
}

func mustJSON(v map[string]any) string {
	keys := make([]string, 0, len(v))
	for k := range v {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("{")
	for i, k := range keys {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, "%q:%q", k, fmt.Sprint(v[k]))
	}
	b.WriteString("}")
	return b.String()
}

func metadataHeaders(header, trailer metadata.MD) []Header {
	var out []Header
	for _, md := range []metadata.MD{header, trailer} {
		keys := make([]string, 0, len(md))
		for k := range md {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			for _, v := range md[k] {
				out = append(out, Header{Name: k, Value: v})
			}
		}
	}
	if out == nil {
		out = []Header{}
	}
	return out
}

type reflectionStream interface {
	fileContainingSymbol(symbol string) ([][]byte, error)
	fileByFilename(name string) ([][]byte, error)
}

type v1Stream struct {
	stream reflectv1.ServerReflection_ServerReflectionInfoClient
}

func (s v1Stream) roundTrip(req *reflectv1.ServerReflectionRequest) ([][]byte, error) {
	if err := s.stream.Send(req); err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	resp, err := s.stream.Recv()
	if err != nil {
		return nil, err
	}
	if e := resp.GetErrorResponse(); e != nil {
		return nil, status.Error(codes.Code(e.GetErrorCode()), e.GetErrorMessage())
	}
	return resp.GetFileDescriptorResponse().GetFileDescriptorProto(), nil
}

func (s v1Stream) fileContainingSymbol(symbol string) ([][]byte, error) {
	return s.roundTrip(&reflectv1.ServerReflectionRequest{MessageRequest: &reflectv1.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: symbol}})
}

func (s v1Stream) fileByFilename(name string) ([][]byte, error) {
	return s.roundTrip(&reflectv1.ServerReflectionRequest{MessageRequest: &reflectv1.ServerReflectionRequest_FileByFilename{FileByFilename: name}})
}

type v1alphaStream struct {
	stream reflectv1alpha.ServerReflection_ServerReflectionInfoClient
}

func (s v1alphaStream) roundTrip(req *reflectv1alpha.ServerReflectionRequest) ([][]byte, error) {
	if err := s.stream.Send(req); err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	resp, err := s.stream.Recv()
	if err != nil {
		return nil, err
	}
	if e := resp.GetErrorResponse(); e != nil {
		return nil, status.Error(codes.Code(e.GetErrorCode()), e.GetErrorMessage())
	}
	return resp.GetFileDescriptorResponse().GetFileDescriptorProto(), nil
}

func (s v1alphaStream) fileContainingSymbol(symbol string) ([][]byte, error) {
	return s.roundTrip(&reflectv1alpha.ServerReflectionRequest{MessageRequest: &reflectv1alpha.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: symbol}})
}

func (s v1alphaStream) fileByFilename(name string) ([][]byte, error) {
	return s.roundTrip(&reflectv1alpha.ServerReflectionRequest{MessageRequest: &reflectv1alpha.ServerReflectionRequest_FileByFilename{FileByFilename: name}})
}

func resolveMethod(ctx context.Context, conn *grpc.ClientConn, target GRPCTarget) (protoreflect.MethodDescriptor, error) {
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var rs reflectionStream
	var raws [][]byte
	var err error
	if s, serr := reflectv1.NewServerReflectionClient(conn).ServerReflectionInfo(streamCtx); serr == nil {
		rs = v1Stream{stream: s}
		raws, err = rs.fileContainingSymbol(target.Service)
	} else {
		err = serr
	}
	if status.Code(err) == codes.Unimplemented {
		s, serr := reflectv1alpha.NewServerReflectionClient(conn).ServerReflectionInfo(streamCtx)
		if serr != nil {
			err = serr
		} else {
			rs = v1alphaStream{stream: s}
			raws, err = rs.fileContainingSymbol(target.Service)
		}
	}
	if err != nil {
		switch status.Code(err) {
		case codes.Unimplemented:
			return nil, &grpcError{message: target.Address + " does not offer server reflection.", detail: "GoLens reads the service definition through gRPC server reflection. Register it in your server, for example reflection.Register(server) from google.golang.org/grpc/reflection."}
		case codes.NotFound:
			return nil, &grpcError{message: "The server does not know the service " + target.Service + ".", detail: "Check the package and service name. Server reflection reported: " + status.Convert(err).Message()}
		case codes.Unavailable:
			return nil, &grpcError{message: "Could not connect to " + target.Address + ".", detail: "Nothing answered there. Start your gRPC server, then run the request again."}
		case codes.DeadlineExceeded, codes.Canceled:
			return nil, ctx.Err()
		}
		return nil, &grpcError{message: "Server reflection failed for " + target.Service + ".", detail: status.Convert(err).Message()}
	}

	protos := map[string]*descriptorpb.FileDescriptorProto{}
	var queue []string
	add := func(list [][]byte) error {
		for _, raw := range list {
			fd := &descriptorpb.FileDescriptorProto{}
			if err := proto.Unmarshal(raw, fd); err != nil {
				return err
			}
			if _, ok := protos[fd.GetName()]; ok {
				continue
			}
			protos[fd.GetName()] = fd
			queue = append(queue, fd.GetDependency()...)
		}
		return nil
	}
	if err := add(raws); err != nil {
		return nil, &grpcError{message: "The server sent a service definition GoLens could not read.", detail: err.Error()}
	}
	for len(queue) > 0 {
		dep := queue[0]
		queue = queue[1:]
		if _, ok := protos[dep]; ok {
			continue
		}
		if _, err := protoregistry.GlobalFiles.FindFileByPath(dep); err == nil {
			continue
		}
		list, err := rs.fileByFilename(dep)
		if err != nil {
			return nil, &grpcError{message: "The server did not send the definition file " + dep + ".", detail: status.Convert(err).Message()}
		}
		if err := add(list); err != nil {
			return nil, &grpcError{message: "The server sent a service definition GoLens could not read.", detail: err.Error()}
		}
	}

	files := &protoregistry.Files{}
	pending := make([]*descriptorpb.FileDescriptorProto, 0, len(protos))
	for _, fd := range protos {
		pending = append(pending, fd)
	}
	resolver := chainResolver{local: files}
	for len(pending) > 0 {
		progressed := false
		var next []*descriptorpb.FileDescriptorProto
		for _, fd := range pending {
			desc, err := protodesc.NewFile(fd, resolver)
			if err != nil {
				next = append(next, fd)
				continue
			}
			if err := files.RegisterFile(desc); err != nil {
				next = append(next, fd)
				continue
			}
			progressed = true
		}
		if !progressed {
			_, err := protodesc.NewFile(next[0], resolver)
			return nil, &grpcError{message: "The service definition from the server is incomplete.", detail: fmt.Sprint(err)}
		}
		pending = next
	}

	d, err := resolver.FindDescriptorByName(protoreflect.FullName(target.Service))
	if err != nil {
		return nil, &grpcError{message: "The server does not know the service " + target.Service + ".", detail: "Check the package and service name."}
	}
	svc, ok := d.(protoreflect.ServiceDescriptor)
	if !ok {
		return nil, &grpcError{message: target.Service + " is not a service.", detail: "Write the full service name, for example helloworld.Greeter."}
	}
	m := svc.Methods().ByName(protoreflect.Name(target.Method))
	if m == nil {
		names := make([]string, 0, svc.Methods().Len())
		for i := 0; i < svc.Methods().Len(); i++ {
			names = append(names, string(svc.Methods().Get(i).Name()))
		}
		return nil, &grpcError{message: target.Service + " has no method " + target.Method + ".", detail: "Available methods: " + strings.Join(names, ", ") + "."}
	}
	return m, nil
}

type chainResolver struct {
	local *protoregistry.Files
}

func (c chainResolver) FindFileByPath(path string) (protoreflect.FileDescriptor, error) {
	if fd, err := c.local.FindFileByPath(path); err == nil {
		return fd, nil
	}
	return protoregistry.GlobalFiles.FindFileByPath(path)
}

func (c chainResolver) FindDescriptorByName(name protoreflect.FullName) (protoreflect.Descriptor, error) {
	if d, err := c.local.FindDescriptorByName(name); err == nil {
		return d, nil
	}
	return protoregistry.GlobalFiles.FindDescriptorByName(name)
}
