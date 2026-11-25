package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunText(t *testing.T) {
	var out bytes.Buffer
	if err := run(nil, strings.NewReader("a b\nc\n"), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "2 lines, 3 words\n" {
		t.Fatalf("out = %q", out.String())
	}
}

func TestRunRejectsUnknownFlag(t *testing.T) {
	if err := run([]string{"--nope"}, strings.NewReader(""), &bytes.Buffer{}); err == nil {
		t.Fatal("expected error")
	}
}
