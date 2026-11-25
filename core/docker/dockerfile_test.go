package docker

import (
	"reflect"
	"testing"
)

func TestParseDockerfile(t *testing.T) {
	src := "# syntax=docker/dockerfile:1\n" +
		"ARG GO=1.22\n" +
		"from golang:${GO} as Build\n" +
		"RUN apk add \\\n" +
		"    # comment inside continuation\n" +
		"\n" +
		"    git make\n" +
		"RUN <<EOF\n" +
		"FROM not-a-stage\n" +
		"EOF\n" +
		"COPY <<-A <<B /dst/\n" +
		"\tbody a\n" +
		"\tA\n" +
		"body b\n" +
		"B\n" +
		"FROM scratch\n" +
		"COPY --from=build /app /app\r\n"
	df := parseDockerfile(src)
	var cmds []string
	for _, in := range df.insts {
		cmds = append(cmds, in.cmd)
	}
	if want := []string{"ARG", "FROM", "RUN", "RUN", "COPY", "FROM", "COPY"}; !reflect.DeepEqual(cmds, want) {
		t.Fatalf("instructions = %v, want %v", cmds, want)
	}
	run := df.insts[2]
	if run.args != "apk add git make" || run.line != 3 || run.endLine != 6 {
		t.Fatalf("continued RUN = %q lines %d..%d", run.args, run.line, run.endLine)
	}
	if l, c := run.pos(len("apk add ")); l != 6 || c != 4 {
		t.Fatalf("pos(git) = %d:%d, want 6:4", l, c)
	}
	if df.insts[3].endLine != 9 || df.insts[4].endLine != 14 {
		t.Fatalf("heredoc ends = %d, %d", df.insts[3].endLine, df.insts[4].endLine)
	}
	if len(df.stages) != 2 || df.stages[0].name != "Build" || df.stages[0].image != "golang:${GO}" {
		t.Fatalf("stages = %+v", df.stages)
	}
	if df.stages[1].insts[0].args != "--from=build /app /app" {
		t.Fatalf("CRLF not trimmed: %q", df.stages[1].insts[0].args)
	}
}

func TestEscapeDirective(t *testing.T) {
	df := parseDockerfile("# escape=`\nFROM mcr.microsoft.com/windows\nRUN dir C:\\ `\n  && echo ok\n")
	if len(df.insts) != 2 || df.insts[1].args != `dir C:\ && echo ok` {
		t.Fatalf("insts = %+v", df.insts)
	}
}

func TestStageChain(t *testing.T) {
	df := parseDockerfile("FROM alpine:3.20 AS base\nFROM base AS mid\nFROM MID\n")
	last := df.stages[2]
	if last.root() != df.stages[0] || len(last.chain()) != 3 {
		t.Fatalf("chain of %q broken", last.image)
	}
}

func TestTokenize(t *testing.T) {
	var got []string
	for _, w := range tokenize(`CGO_ENABLED=0 go build -ldflags="-s -w" -o '/a b' ./cmd&&echo;x`) {
		got = append(got, w.val)
	}
	want := []string{"CGO_ENABLED=0", "go", "build", "-ldflags=-s -w", "-o", "/a b", "./cmd", "&&", "echo", ";", "x"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("tokens = %q", got)
	}
}
