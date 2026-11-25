package docker

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"unicode/utf16"
)

const (
	goModFile  = "module example.com/app\n\ngo 1.22.3\n"
	mainGoFile = "package main\n\nfunc main() {}\n"
	libGoFile  = "package lib\n"
)

func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func byteOffset(t *testing.T, text string, line, col int) int {
	t.Helper()
	lines := strings.SplitAfter(text, "\n")
	if line >= len(lines) {
		t.Fatalf("edit line %d beyond %d lines", line, len(lines))
	}
	off := 0
	for _, l := range lines[:line] {
		off += len(l)
	}
	units := 0
	for i, r := range lines[line] {
		if units >= col {
			return off + i
		}
		units += utf16.RuneLen(r)
	}
	return off + len(strings.TrimSuffix(lines[line], "\n"))
}

func applyEdits(t *testing.T, text string, edits []Edit) string {
	t.Helper()
	type abs struct {
		start, end int
		text       string
	}
	var list []abs
	for _, e := range edits {
		list = append(list, abs{byteOffset(t, text, e.Line, e.Col), byteOffset(t, text, e.EndLine, e.EndCol), e.NewText})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].start > list[j].start })
	for _, e := range list {
		text = text[:e.start] + e.text + text[e.end:]
	}
	return text
}

func withCode(findings []Finding, code string) []Finding {
	var out []Finding
	for _, f := range findings {
		if f.Code == code && f.Source == sourceDockerfile {
			out = append(out, f)
		}
	}
	return out
}

func spanText(t *testing.T, text string, f Finding) string {
	t.Helper()
	return text[byteOffset(t, text, f.Line, f.Col):byteOffset(t, text, f.EndLine, f.EndCol)]
}

type ruleCase struct {
	name       string
	files      map[string]string
	dockerfile string
	want       int
	wantSpan   string
	fix        int
	wantFixed  string
	wantCreate *CreateFile
	noFix      bool
}

func runRuleCases(t *testing.T, code string, cases []ruleCase) {
	t.Helper()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeTree(t, tc.files)
			got := withCode(Inspect(filepath.Join(dir, "Dockerfile"), tc.dockerfile), code)
			if len(got) != tc.want {
				t.Fatalf("%s findings = %d, want %d: %+v", code, len(got), tc.want, got)
			}
			if tc.want == 0 {
				return
			}
			f := got[0]
			if tc.wantSpan != "" {
				if s := spanText(t, tc.dockerfile, f); s != tc.wantSpan {
					t.Fatalf("span = %q, want %q", s, tc.wantSpan)
				}
			}
			if tc.noFix {
				if len(f.Fixes) != 0 {
					t.Fatalf("unexpected fixes %+v", f.Fixes)
				}
				return
			}
			if tc.wantFixed == "" && tc.wantCreate == nil {
				return
			}
			if tc.fix >= len(f.Fixes) {
				t.Fatalf("fix %d missing: %+v", tc.fix, f.Fixes)
			}
			fix := f.Fixes[tc.fix]
			if tc.wantFixed != "" {
				if out := applyEdits(t, tc.dockerfile, fix.Edits); out != tc.wantFixed {
					t.Fatalf("fixed text:\n%s\nwant:\n%s", out, tc.wantFixed)
				}
			}
			if tc.wantCreate != nil {
				want := *tc.wantCreate
				want.Path = filepath.Join(dir, want.Path)
				if fix.CreateFile == nil || *fix.CreateFile != want {
					t.Fatalf("createFile = %+v, want %+v", fix.CreateFile, want)
				}
			}
		})
	}
}

func TestDF001GoVersion(t *testing.T) {
	mod := map[string]string{"go.mod": goModFile, "main.go": mainGoFile}
	runRuleCases(t, "DF001", []ruleCase{
		{
			name:       "older minor keeps suffix",
			files:      mod,
			dockerfile: "FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS build\n",
			want:       1, wantSpan: "1.21",
			wantFixed: "FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build\n",
		},
		{
			name:       "older patch",
			files:      mod,
			dockerfile: "FROM golang:1.22.1\n",
			want:       1, wantSpan: "1.22.1",
			wantFixed: "FROM golang:1.22.3\n",
		},
		{
			name:       "toolchain wins",
			files:      map[string]string{"go.mod": "module m\n\ngo 1.22\n\ntoolchain go1.23.4 // pinned\n"},
			dockerfile: "FROM golang:1.22.5-bookworm\n",
			want:       1,
			wantFixed:  "FROM golang:1.23.4-bookworm\n",
		},
		{name: "minor tag covers patch", files: mod, dockerfile: "FROM golang:1.22-alpine\n"},
		{name: "newer image", files: mod, dockerfile: "FROM golang:1.23\n"},
		{name: "no version in tag", files: mod, dockerfile: "FROM golang:alpine\n"},
		{name: "no module", files: map[string]string{}, dockerfile: "FROM golang:1.10\n"},
	})
}

const multiStage = "FROM golang:1.22 AS build\nWORKDIR /src\nCOPY . .\nRUN go build -o /app .\n\nFROM scratch\nCOPY --from=build /app /app\nUSER 65532:65532\n"

func TestDF002CgoDisabled(t *testing.T) {
	mod := map[string]string{"go.mod": goModFile, "main.go": mainGoFile}
	runRuleCases(t, "DF002", []ruleCase{
		{
			name: "debian builder to scratch", files: mod, dockerfile: multiStage,
			want: 1, wantSpan: "go build",
			wantFixed: strings.Replace(multiStage, "AS build\n", "AS build\nENV CGO_ENABLED=0\n", 1),
		},
		{
			name: "distroless static", files: mod,
			dockerfile: "FROM golang:1.22 AS build\nRUN go build -o /app .\nFROM gcr.io/distroless/static-debian12:nonroot\n",
			want:       1,
		},
		{name: "alpine builder", files: mod, dockerfile: strings.Replace(multiStage, "golang:1.22 ", "golang:1.22-alpine ", 1)},
		{name: "env set", files: mod, dockerfile: strings.Replace(multiStage, "WORKDIR /src", "ENV CGO_ENABLED=0 GOOS=linux", 1)},
		{name: "inline env", files: mod, dockerfile: strings.Replace(multiStage, "RUN go build", "RUN CGO_ENABLED=0 go build", 1)},
		{name: "debian final", files: mod, dockerfile: strings.Replace(multiStage, "FROM scratch", "FROM debian:12-slim", 1)},
		{name: "cgo module defers to DF003", files: map[string]string{"go.mod": goModFile, "main.go": "package main\n\nimport \"C\"\n\nfunc main() {}\n"}, dockerfile: multiStage},
	})
}

func TestDF003CgoOnStaticImage(t *testing.T) {
	runRuleCases(t, "DF003", []ruleCase{
		{
			name:       "import C",
			files:      map[string]string{"go.mod": goModFile, "main.go": mainGoFile, "db/db.go": "package db\n\n// #include <stdio.h>\nimport \"C\"\n"},
			dockerfile: multiStage, want: 1, wantSpan: "scratch", noFix: true,
		},
		{
			name:       "sqlite requirement",
			files:      map[string]string{"go.mod": goModFile + "\nrequire github.com/mattn/go-sqlite3 v1.14.22\n", "main.go": mainGoFile},
			dockerfile: multiStage, want: 1, noFix: true,
		},
		{
			name:       "cgo only in tests and vendor",
			files:      map[string]string{"go.mod": goModFile, "main.go": mainGoFile, "x_test.go": "package main\n\nimport \"C\"\n", "vendor/v/v.go": "package v\n\nimport \"C\"\n"},
			dockerfile: multiStage,
		},
		{
			name:       "glibc final image",
			files:      map[string]string{"go.mod": goModFile + "\nrequire github.com/mattn/go-sqlite3 v1.14.22\n", "main.go": mainGoFile},
			dockerfile: strings.Replace(multiStage, "FROM scratch", "FROM gcr.io/distroless/base-debian12", 1),
		},
	})
}

func TestDF004ModDownloadOrder(t *testing.T) {
	files := map[string]string{"go.mod": goModFile, "go.sum": "", "main.go": mainGoFile}
	df := "FROM golang:1.22-alpine AS build\nWORKDIR /src\n  COPY . .\nRUN go build -o /app .\n"
	runRuleCases(t, "DF004", []ruleCase{
		{
			name: "copy before download", files: files, dockerfile: df, want: 1, wantSpan: ". .",
			wantFixed: "FROM golang:1.22-alpine AS build\nWORKDIR /src\n  COPY go.mod go.sum ./\n  RUN go mod download\n  COPY . .\nRUN go build -o /app .\n",
		},
		{
			name: "no go.sum", files: map[string]string{"go.mod": goModFile, "main.go": mainGoFile}, dockerfile: df, want: 1,
			wantFixed: "FROM golang:1.22-alpine AS build\nWORKDIR /src\n  COPY go.mod ./\n  RUN go mod download\n  COPY . .\nRUN go build -o /app .\n",
		},
		{
			name: "download first", files: files,
			dockerfile: "FROM golang:1.22-alpine\nCOPY go.mod go.sum ./\nRUN go mod download\nCOPY . .\nRUN go build -o /app .\n",
		},
		{name: "no go build", files: files, dockerfile: "FROM nginx:1.27\nCOPY . .\n"},
		{name: "copy from stage", files: files, dockerfile: "FROM golang:1.22\nCOPY --from=src . .\nRUN go build .\n"},
	})
}

func TestDF005MainPackage(t *testing.T) {
	files := map[string]string{
		"go.mod":          goModFile,
		"cmd/api/main.go": mainGoFile,
		"cmd/cli/main.go": mainGoFile,
		"internal/x/x.go": libGoFile,
		"main_test.go":    "package main\n",
	}
	df := "FROM golang:1.22\nCOPY . .\nRUN go build -ldflags \"-s -w\" -o /app ./internal/x && echo ok\n"
	runRuleCases(t, "DF005", []ruleCase{
		{
			name: "library package", files: files, dockerfile: df, want: 1, wantSpan: "./internal/x",
			wantFixed: strings.Replace(df, "./internal/x", "./cmd/api", 1),
		},
		{
			name: "second suggestion", files: files, dockerfile: df, want: 1, fix: 1,
			wantFixed: strings.Replace(df, "./internal/x", "./cmd/cli", 1),
		},
		{name: "missing folder", files: files, dockerfile: "FROM golang:1.22\nRUN go build ./cmd/nope\n", want: 1, wantSpan: "./cmd/nope", wantFixed: "FROM golang:1.22\nRUN go build ./cmd/api\n"},
		{name: "main package", files: files, dockerfile: "FROM golang:1.22\nRUN go build -o /app ./cmd/api\n"},
		{name: "wildcard", files: files, dockerfile: "FROM golang:1.22\nRUN go build ./...\n"},
		{name: "output value not a package", files: files, dockerfile: "FROM golang:1.22\nRUN go build -o ./bin/app ./cmd/cli\n"},
		{name: "changes directory", files: files, dockerfile: "FROM golang:1.22\nRUN go build -C cmd -o /app ./api\n"},
		{name: "workdir moved", files: files, dockerfile: "FROM golang:1.22\nCOPY . .\nWORKDIR /src/cmd\nRUN go build ./api\n"},
	})
}

func TestDF006CacheMounts(t *testing.T) {
	runRuleCases(t, "DF006", []ruleCase{
		{
			name: "go build", files: map[string]string{}, dockerfile: "FROM golang:1.22\nRUN   go build -o /app .\n",
			want: 1, wantSpan: "go build",
			wantFixed: "FROM golang:1.22\nRUN   " + cacheMounts + " go build -o /app .\n",
		},
		{
			name: "continued download", files: map[string]string{}, dockerfile: "FROM golang:1.22\nRUN --network=host \\\n    go mod download\n",
			want: 1, wantSpan: "go mod download",
			wantFixed: "FROM golang:1.22\nRUN " + cacheMounts + " --network=host \\\n    go mod download\n",
		},
		{name: "has mount", files: map[string]string{}, dockerfile: "FROM golang:1.22\nRUN --mount=type=cache,target=/go/pkg/mod go mod download\n"},
		{name: "no go", files: map[string]string{}, dockerfile: "FROM alpine:3.20\nRUN echo go\n"},
	})
}

func TestDF007Dockerignore(t *testing.T) {
	df := "FROM golang:1.22\n"
	runRuleCases(t, "DF007", []ruleCase{
		{name: "missing", files: map[string]string{}, dockerfile: df, want: 1, wantSpan: "FROM", wantCreate: &CreateFile{Path: ".dockerignore", Content: defaultIgnore}},
		{name: "without git", files: map[string]string{".dockerignore": "bin/"}, dockerfile: df, want: 1, wantCreate: &CreateFile{Path: ".dockerignore", Content: "bin/\n.git\n"}},
		{name: "negated git", files: map[string]string{".dockerignore": ".git\n!.git\n"}, dockerfile: df, want: 1},
		{name: "git excluded", files: map[string]string{".dockerignore": "# vcs\n/.git/\n"}, dockerfile: df},
		{name: "glob", files: map[string]string{".dockerignore": ".*\n"}, dockerfile: df},
		{name: "dockerfile specific", files: map[string]string{"Dockerfile.dockerignore": "**/.git\n"}, dockerfile: df},
	})
}

func TestDF008User(t *testing.T) {
	noUser := strings.Replace(multiStage, "USER 65532:65532\n", "", 1)
	runRuleCases(t, "DF008", []ruleCase{
		{name: "scratch", files: map[string]string{}, dockerfile: noUser, want: 1, wantSpan: "scratch", wantFixed: multiStage},
		{
			name: "no trailing newline", files: map[string]string{},
			dockerfile: "FROM gcr.io/distroless/static-debian12\nCOPY app /app",
			want:       1, wantFixed: "FROM gcr.io/distroless/static-debian12\nCOPY app /app\nUSER 65532:65532",
		},
		{name: "debian no fix", files: map[string]string{}, dockerfile: "FROM debian:12\nCMD [\"sh\"]\n", want: 1, noFix: true},
		{name: "user set", files: map[string]string{}, dockerfile: multiStage},
		{name: "nonroot image", files: map[string]string{}, dockerfile: "FROM gcr.io/distroless/static-debian12:nonroot\n"},
		{name: "inherited user", files: map[string]string{}, dockerfile: "FROM alpine:3.20 AS base\nUSER app\nFROM base\n"},
	})
}

func TestDF009Tags(t *testing.T) {
	runRuleCases(t, "DF009", []ruleCase{
		{name: "untagged", files: map[string]string{}, dockerfile: "FROM alpine\n", want: 1, wantSpan: "alpine", noFix: true},
		{name: "latest", files: map[string]string{}, dockerfile: "FROM --platform=linux/amd64 golang:latest AS b\n", want: 1, wantSpan: "golang:latest"},
		{name: "registry port", files: map[string]string{}, dockerfile: "FROM localhost:5000/app\n", want: 1},
		{name: "tagged", files: map[string]string{}, dockerfile: "FROM alpine:3.20\n"},
		{name: "digest", files: map[string]string{}, dockerfile: "FROM alpine@sha256:abc\n"},
		{name: "arg", files: map[string]string{}, dockerfile: "ARG BASE=alpine\nFROM $BASE\n"},
		{name: "scratch and stage", files: map[string]string{}, dockerfile: "FROM alpine:3.20 AS base\nFROM base\nFROM scratch\n"},
	})
}

func TestInspectJSONNeverPanics(t *testing.T) {
	for _, in := range []string{"", "\\", "FROM", "FROM \\\n", "RUN <<EOF", "FROM a AS\nCOPY", "\x00\xff", "FROM golang:1.\nRUN go build -o"} {
		out := InspectJSON("/nonexistent/dir/Dockerfile", in)
		if !strings.HasPrefix(out, `{"findings":[`) {
			t.Fatalf("InspectJSON(%q) = %s", in, out)
		}
	}
}

func TestUTF16Columns(t *testing.T) {
	got := withCode(Inspect("", "FROM --platform=\U0001D11E alpine\n"), "DF009")
	if len(got) != 1 || got[0].Col != 19 || got[0].EndCol != 25 {
		t.Fatalf("span %+v, want col 19..25", got)
	}
}

func TestSubfolderDockerfileScansModuleRoot(t *testing.T) {
	cgoDir := writeTree(t, map[string]string{
		"go.mod":         goModFile,
		"cmd/api/main.go": mainGoFile,
		"pkg/cgo/cgo.go": "package cgo\n\nimport \"C\"\n",
		"internal/x/x.go": libGoFile,
	})
	dfPath := filepath.Join(cgoDir, "deploy", "Dockerfile")
	if got := withCode(Inspect(dfPath, multiStage), "DF003"); len(got) != 1 {
		t.Fatalf("subfolder Dockerfile DF003 = %d, want 1: %+v", len(got), got)
	}
	if got := withCode(Inspect(dfPath, multiStage), "DF002"); len(got) != 0 {
		t.Fatalf("subfolder Dockerfile DF002 should defer to DF003, got %+v", got)
	}

	plainDir := writeTree(t, map[string]string{
		"go.mod":          goModFile,
		"cmd/api/main.go": mainGoFile,
		"internal/x/x.go": libGoFile,
	})
	plainDF := filepath.Join(plainDir, "deploy", "Dockerfile")
	if got := withCode(Inspect(plainDF, "FROM golang:1.22\nCOPY . .\nRUN go build -o /app ./cmd/api\n"), "DF005"); len(got) != 0 {
		t.Fatalf("subfolder Dockerfile valid module main target DF005 = %+v, want 0", got)
	}
	nonMain := withCode(Inspect(plainDF, "FROM golang:1.22\nCOPY . .\nRUN go build -o /app ./internal/x\n"), "DF005")
	if len(nonMain) != 1 || !strings.Contains(nonMain[0].Message, "is not a main package") {
		t.Fatalf("subfolder Dockerfile non-main target DF005 = %+v", nonMain)
	}
}
