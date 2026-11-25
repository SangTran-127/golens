package docker

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func ownFindings(fs []Finding) []Finding {
	var out []Finding
	for _, f := range fs {
		if f.Source == sourceDockerfile {
			out = append(out, f)
		}
	}
	return out
}

func generateClean(t *testing.T, dir string, opts GenerateOptions) GenerateResult {
	t.Helper()
	res := Generate(dir, opts)
	if res.Error != "" {
		t.Fatalf("Generate error: %s", res.Error)
	}
	if err := os.WriteFile(filepath.Join(res.Dir, ".dockerignore"), []byte(res.Dockerignore), 0o644); err != nil {
		t.Fatal(err)
	}
	if f := ownFindings(Inspect(filepath.Join(res.Dir, "Dockerfile"), res.Dockerfile)); len(f) != 0 {
		t.Fatalf("generated Dockerfile has findings %+v\n%s", f, res.Dockerfile)
	}
	return res
}

func TestGenerateDockerfileHasNoFindings(t *testing.T) {
	cases := []struct {
		name     string
		files    map[string]string
		opts     GenerateOptions
		pkg      string
		base     string
		port     int
		contains []string
		absent   []string
	}{
		{
			name:  "plain",
			files: map[string]string{"go.mod": goModFile, "go.sum": "", "main.go": "package main\n\nimport \"net/http\"\n\nfunc main() { http.ListenAndServe(\":8080\", nil) }\n"},
			pkg:   ".", base: BaseDistrolessStatic, port: 8080,
			contains: []string{
				"FROM golang:1.22-alpine AS builder", "ENV CGO_ENABLED=0", "COPY go.mod go.sum ./", cacheMounts,
				`-trimpath -ldflags="-s -w"`, "FROM gcr.io/distroless/static-debian12:nonroot", "USER nonroot:nonroot", "EXPOSE 8080", "ENTRYPOINT [",
			},
		},
		{
			name: "cmd with multiple mains",
			files: map[string]string{
				"go.mod": goModFile, "go.sum": "",
				"cmd/api/main.go":    "package main\n\nimport \"net\"\n\nfunc main() { net.Listen(\"tcp\", \":9000\") }\n",
				"cmd/worker/main.go": mainGoFile, "internal/lib/lib.go": libGoFile,
			},
			opts: GenerateOptions{Package: "./cmd/worker"},
			pkg:  "cmd/worker", base: BaseDistrolessStatic, port: 9000,
			contains: []string{"-o /out/worker ./cmd/worker", `ENTRYPOINT ["/usr/local/bin/worker"]`},
		},
		{
			name:  "cgo",
			files: map[string]string{"go.mod": goModFile, "go.sum": "", "main.go": "package main\n\n// int one() { return 1; }\nimport \"C\"\n\nfunc main() { _ = C.one() }\n"},
			pkg:   ".", base: BaseDistrolessBase,
			contains: []string{"FROM golang:1.22-bookworm AS builder", "ENV CGO_ENABLED=1", "FROM gcr.io/distroless/base-debian12:nonroot"},
			absent:   []string{"EXPOSE"},
		},
		{
			name:  "no go.sum",
			files: map[string]string{"go.mod": "module m\n\ngo 1.21\ntoolchain go1.23.4\n", "main.go": mainGoFile},
			pkg:   ".", base: BaseDistrolessStatic,
			contains: []string{"FROM golang:1.23-alpine AS builder", "COPY go.mod ./\n"},
			absent:   []string{"go.sum"},
		},
		{
			name:  "alpine",
			files: map[string]string{"go.mod": goModFile, "go.sum": "", "main.go": mainGoFile},
			opts:  GenerateOptions{Base: BaseAlpine},
			pkg:   ".", base: BaseAlpine,
			contains: []string{"FROM " + alpineRuntimeTag, "USER 65532:65532"},
		},
		{
			name:  "scratch",
			files: map[string]string{"go.mod": goModFile, "go.sum": "", "main.go": mainGoFile},
			opts:  GenerateOptions{Base: BaseScratch, Port: new(int)},
			pkg:   ".", base: BaseScratch,
			contains: []string{"FROM scratch", "ca-certificates.crt", "USER 65532:65532"},
		},
		{
			name:  "cgo on alpine",
			files: map[string]string{"go.mod": goModFile + "\nrequire github.com/mattn/go-sqlite3 v1.14.22\n", "go.sum": "", "main.go": mainGoFile},
			opts:  GenerateOptions{Base: BaseAlpine},
			pkg:   ".", base: BaseAlpine,
			contains: []string{"FROM golang:1.22-alpine AS builder", "apk add --no-cache gcc musl-dev", "ENV CGO_ENABLED=1"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := generateClean(t, writeTree(t, tc.files), tc.opts)
			if res.Package != tc.pkg || res.Base != tc.base || res.Port != tc.port {
				t.Fatalf("package/base/port = %q/%q/%d, want %q/%q/%d", res.Package, res.Base, res.Port, tc.pkg, tc.base, tc.port)
			}
			for _, s := range tc.contains {
				if !strings.Contains(res.Dockerfile, s) {
					t.Errorf("missing %q in\n%s", s, res.Dockerfile)
				}
			}
			for _, s := range tc.absent {
				if strings.Contains(res.Dockerfile, s) {
					t.Errorf("unexpected %q in\n%s", s, res.Dockerfile)
				}
			}
			if strings.Index(res.Dockerfile, "go mod download") > strings.Index(res.Dockerfile, "COPY . .") {
				t.Errorf("go mod download must come before COPY . .")
			}
		})
	}
}

func TestGenerateDetectionsAndErrors(t *testing.T) {
	dir := writeTree(t, map[string]string{
		"go.mod": goModFile + "\nrequire example.com/dep v1.0.0\n", "cmd/b/main.go": mainGoFile, "cmd/a/main.go": mainGoFile, "main.go": mainGoFile,
		"lib/c.go": "package lib\n\n/*\n#include <stdio.h>\n*/\nimport \"C\"\n",
	})
	var res GenerateResult
	if err := json.Unmarshal([]byte(GenerateJSON(filepath.Join(dir, "cmd")+"/", "")), &res); err != nil {
		t.Fatal(err)
	}
	if res.Dir != dir || !reflect.DeepEqual(res.MainPackages, []string{".", "cmd/a", "cmd/b"}) || res.GoVersion != "1.22.3" {
		t.Fatalf("detections = %+v", res)
	}
	if !res.UsesCgo || res.CgoReason != `lib/c.go imports "C"` || res.Base != BaseDistrolessBase {
		t.Fatalf("cgo = %v %q %q", res.UsesCgo, res.CgoReason, res.Base)
	}
	if len(res.Warnings) == 0 || !strings.Contains(strings.Join(res.Warnings, " "), "go.sum") {
		t.Fatalf("warnings = %v", res.Warnings)
	}
	if r := Generate(dir, GenerateOptions{Package: "lib"}); r.Error == "" {
		t.Fatal("non-main package accepted")
	}
	if r := Generate(dir, GenerateOptions{Base: "ubuntu"}); r.Error == "" {
		t.Fatal("unknown base accepted")
	}
	if r := Generate(t.TempDir(), GenerateOptions{}); r.Error == "" {
		t.Fatal("folder without go.mod accepted")
	}
	if r := Generate(writeTree(t, map[string]string{"go.mod": goModFile, "lib.go": libGoFile}), GenerateOptions{}); r.Error == "" {
		t.Fatal("module without main package accepted")
	}
	if out := GenerateJSON(dir, "{"); !strings.Contains(out, `"error"`) {
		t.Fatalf("bad options JSON = %s", out)
	}
}

func TestPortsInFile(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want []int
	}{
		{"ListenAndServe literal", `http.ListenAndServe(":8080", nil)`, []int{8080}},
		{"ListenAndServeTLS host", `http.ListenAndServeTLS("0.0.0.0:8443", "c", "k", nil)`, []int{8443}},
		{"net.Listen", `net.Listen("tcp", ":9000")`, []int{9000}},
		{"server struct", `srv := &http.Server{Addr: ":7000"}; srv.ListenAndServe()`, []int{7000}},
		{"echo Start", `e := echo.New(); e.Start(":1323")`, []int{1323}},
		{"gin Run", `r := gin.Default(); r.Run(":8081")`, []int{8081}},
		{"fiber Listen", `app.Listen(":3000")`, []int{3000}},
		{"const", `const addr = ":5000"; http.ListenAndServe(addr, nil)`, []int{5000}},
		{"env default", `port := os.Getenv("PORT"); if port == "" { port = "8090" }; http.ListenAndServe(":"+port, nil)`, []int{8090}},
		{"cmp.Or", `addr := ":" + cmp.Or(os.Getenv("PORT"), "4000"); http.ListenAndServe(addr, nil)`, []int{4000}},
		{"getenv helper", `http.ListenAndServe(":"+getenv("PORT", "6000"), nil)`, []int{6000}},
		{"flag", `addr := flag.String("addr", ":8888", "listen address"); http.ListenAndServe(*addr, nil)`, []int{8888}},
		{"Sprintf int", `http.ListenAndServe(fmt.Sprintf(":%d", 9090), nil)`, []int{9090}},
		{"closure", `go func() { http.ListenAndServe(":7070", nil) }()`, []int{7070}},
		{"env only", `http.ListenAndServe(":"+os.Getenv("PORT"), nil)`, nil},
		{"unrelated Run", `cmd.Run(ctx)`, nil},
		{"invalid port", `http.ListenAndServe(":99999", nil)`, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := "package main\n\nfunc main() {\n" + strings.ReplaceAll(tc.src, "; ", "\n") + "\n}\n"
			f, err := parser.ParseFile(token.NewFileSet(), "main.go", src, 0)
			if err != nil {
				t.Fatal(err)
			}
			var got []int
			for _, h := range portsInFile(f) {
				got = append(got, h.port)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("ports = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPortsAtFileScope(t *testing.T) {
	dir := writeTree(t, map[string]string{
		"go.mod":         goModFile,
		"main.go":        "package main\n\nvar listenAddr = \":8000\"\n\nfunc main() { serve() }\n\nfunc serve() { http.ListenAndServe(listenAddr, nil) }\n",
		"main_test.go":   "package main\n\nfunc x() { http.ListenAndServe(\":1111\", nil) }\n",
		"vendor/v/v.go":  "package v\n\nfunc x() { http.ListenAndServe(\":2222\", nil) }\n",
		"cmd/b/main.go":  "package main\n\nfunc main() { net.Listen(\"tcp\", \"localhost:9001\") }\n",
		"other/notes.go": "package other\n",
	})
	got := detectPorts(dir)
	want := []DetectedPort{
		{Port: 9001, Package: "cmd/b", File: "cmd/b/main.go", Line: 3, Via: "net.Listen"},
		{Port: 8000, Package: ".", File: "main.go", Line: 7, Via: "http.ListenAndServe"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("detectPorts = %+v", got)
	}
	if p := defaultPort(got, "."); p != 8000 {
		t.Fatalf("defaultPort(.) = %d", p)
	}
	if p := defaultPort(got, "cmd/x"); p != 9001 {
		t.Fatalf("defaultPort(other) = %d", p)
	}
}
