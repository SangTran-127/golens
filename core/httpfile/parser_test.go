package httpfile

import (
	"strings"
	"testing"
)

const sample = `@base = /api

### Login
# @name login
POST {{host}}{{base}}/login HTTP/1.1
Content-Type: application/json
Accept: application/json

{
  "user": "{{user}}",
  "password": "secret"
}

> {%
  client.global.set("token", response.body.token);
  client.test("logged in", function() {
    client.assert(response.status === 200, "status");
  });
%}

###
GET {{host}}/users
    ?page=1
    &size=20
Authorization: Bearer {{token}}

### Upload
# @no-redirect
# @timeout 5
PUT https://example.com/upload
Content-Type: application/json

< ./payload.json

> ./check.js

### gRPC
GRPC localhost:50051/helloworld.Greeter/SayHello

{"name": "GoLens"}
`

func TestParseRequests(t *testing.T) {
	f := Parse(sample)
	if len(f.Requests) != 4 {
		t.Fatalf("want 4 requests, got %d", len(f.Requests))
	}
	login := f.Requests[0]
	if login.Name != "login" || login.Title != "Login" {
		t.Fatalf("name/title = %q/%q", login.Name, login.Title)
	}
	if login.Method != "POST" || login.URL != "{{host}}{{base}}/login" || login.HTTPVersion != "HTTP/1.1" {
		t.Fatalf("request line = %s %s %s", login.Method, login.URL, login.HTTPVersion)
	}
	if login.Line != 5 || login.StartLine != 3 {
		t.Fatalf("line=%d start=%d", login.Line, login.StartLine)
	}
	if len(login.Headers) != 2 || login.Headers[0].Name != "Content-Type" || login.Headers[1].Value != "application/json" {
		t.Fatalf("headers = %+v", login.Headers)
	}
	if len(login.Body) != 1 || !strings.HasPrefix(login.Body[0].Text, "{") || !strings.HasSuffix(login.Body[0].Text, "}") {
		t.Fatalf("body = %+v", login.Body)
	}
	if !strings.Contains(login.Handler, "client.global.set(\"token\"") || login.HandlerLine != 14 {
		t.Fatalf("handler = %q line %d", login.Handler, login.HandlerLine)
	}

	users := f.Requests[1]
	if users.Method != "GET" || users.URL != "{{host}}/users?page=1&size=20" {
		t.Fatalf("users = %s %s", users.Method, users.URL)
	}
	if users.Title != "GET {{host}}/users?page=1&size=20" || users.Name != "" {
		t.Fatalf("untitled request title=%q name=%q", users.Title, users.Name)
	}
	if len(users.Headers) != 1 || users.Headers[0].Value != "Bearer {{token}}" {
		t.Fatalf("users headers = %+v", users.Headers)
	}

	upload := f.Requests[2]
	if !upload.NoRedirect || upload.TimeoutSec != 5 {
		t.Fatalf("tags not applied: %+v", upload)
	}
	if len(upload.Body) != 1 || upload.Body[0].File != "./payload.json" || upload.Body[0].Substitute {
		t.Fatalf("include = %+v", upload.Body)
	}
	if upload.HandlerFile != "./check.js" {
		t.Fatalf("handler file = %q", upload.HandlerFile)
	}

	g := f.Requests[3]
	if !g.IsGRPC || g.URL != "localhost:50051/helloworld.Greeter/SayHello" || g.Body[0].Text != `{"name": "GoLens"}` {
		t.Fatalf("grpc = %+v", g)
	}

	if len(f.Variables) != 1 || f.Variables[0].Name != "base" || f.Variables[0].Value != "/api" {
		t.Fatalf("variables = %+v", f.Variables)
	}
}

func TestParseDefaultsAndEdgeCases(t *testing.T) {
	f := Parse("https://example.com\n")
	if len(f.Requests) != 1 || f.Requests[0].Method != "GET" || f.Requests[0].URL != "https://example.com" {
		t.Fatalf("bare url = %+v", f.Requests)
	}
	f = Parse("### only a title\n# just comments\n\n###\n")
	if len(f.Requests) != 0 {
		t.Fatalf("comment-only blocks should yield no request, got %+v", f.Requests)
	}
	f = Parse("POST /x\r\nContent-Type: text/plain\r\n\r\nhello\r\n\r\n\r\n")
	if len(f.Requests) != 1 || f.Requests[0].Body[0].Text != "hello" {
		t.Fatalf("crlf body = %+v", f.Requests)
	}
	f = Parse("POST /x\n{\"a\":1}\n")
	if len(f.Requests[0].Headers) != 0 || f.Requests[0].Body[0].Text != `{"a":1}` {
		t.Fatalf("body without blank line = %+v", f.Requests[0])
	}
	f = Parse("POST /x\n\n> {% client.global.set('a', 1) %}\n")
	if f.Requests[0].Handler != "client.global.set('a', 1)" {
		t.Fatalf("inline handler = %q", f.Requests[0].Handler)
	}
	f = Parse("// @name ping\nGET /ping\n")
	if f.Requests[0].Name != "ping" {
		t.Fatalf("slash name = %q", f.Requests[0].Name)
	}
	f = Parse("POST /x\n\n<@ ./tpl.json\n")
	if !f.Requests[0].Body[0].Substitute {
		t.Fatalf("<@ should substitute")
	}
}

func TestRequestAtLine(t *testing.T) {
	f := Parse(sample)
	cases := map[int]int{3: 0, 5: 0, 20: 0, 22: 1, 24: 1, 29: 2, 37: 3, 40: 3}
	for line, want := range cases {
		r, ok := RequestAtLine(f, line)
		if !ok || r.Index != want {
			t.Fatalf("line %d -> %d (%v), want %d", line, r.Index, ok, want)
		}
	}
}
