package goast

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSyntaxSelectionRanges_IdentifierToFile(t *testing.T) {
	src := `package demo

import "fmt"

// Greet formats a greeting.
func Greet(name string) string {
	msg := fmt.Sprintf("hello %s", name)
	return msg
}
`
	offset := strings.Index(src, "Sprintf") + 2
	raw := SyntaxSelectionRanges(src, offset)

	var spans []ByteSpan
	if err := json.Unmarshal([]byte(raw), &spans); err != nil {
		t.Fatalf("unmarshal spans: %v", err)
	}
	if len(spans) < 5 {
		t.Fatalf("expected at least 5 expanding spans, got %d: %+v", len(spans), spans)
	}

	var texts []string
	for i, sp := range spans {
		if sp.StartByte < 0 || sp.EndByte > len(src) || sp.StartByte >= sp.EndByte {
			t.Fatalf("invalid span[%d]: %+v", i, sp)
		}
		if i > 0 {
			prev := spans[i-1]
			if !(sp.StartByte <= prev.StartByte && sp.EndByte >= prev.EndByte &&
				(sp.EndByte-sp.StartByte) > (prev.EndByte-prev.StartByte)) {
				t.Fatalf("span[%d] %+v does not strictly enclose span[%d] %+v", i, sp, i-1, prev)
			}
		}
		texts = append(texts, src[sp.StartByte:sp.EndByte])
	}

	wantSubstrings := []string{
		"Sprintf",
		"fmt.Sprintf",
		`fmt.Sprintf("hello %s", name)`,
		`msg := fmt.Sprintf("hello %s", name)`,
		"return msg",
		"func Greet(name string) string",
		"package demo",
	}

	lastMatchedIdx := -1
	for _, want := range wantSubstrings {
		foundIdx := -1
		for idx := lastMatchedIdx + 1; idx < len(texts); idx++ {
			if texts[idx] == want || strings.Contains(texts[idx], want) {
				foundIdx = idx
				break
			}
		}
		if foundIdx == -1 {
			t.Fatalf("expected expanding progression to include %q in order, got spans:\n%s", want, strings.Join(texts, "\n---\n"))
		}
		lastMatchedIdx = foundIdx
	}
}

func TestSyntaxSelectionRanges_StringLiteralAndComment(t *testing.T) {
	src := `package demo

// important comment
func msg() string {
	return "hello world"
}
`
	strOffset := strings.Index(src, "world")
	var strSpans []ByteSpan
	if err := json.Unmarshal([]byte(SyntaxSelectionRanges(src, strOffset)), &strSpans); err != nil {
		t.Fatalf("unmarshal string spans: %v", err)
	}
	if len(strSpans) < 2 {
		t.Fatalf("expected at least 2 spans for string literal, got %d", len(strSpans))
	}
	if got := src[strSpans[0].StartByte:strSpans[0].EndByte]; got != "hello world" {
		t.Fatalf("expected inner string literal span %q, got %q", "hello world", got)
	}
	if got := src[strSpans[1].StartByte:strSpans[1].EndByte]; got != `"hello world"` {
		t.Fatalf("expected quoted string literal span %q, got %q", `"hello world"`, got)
	}

	commentOffset := strings.Index(src, "important")
	var commentSpans []ByteSpan
	if err := json.Unmarshal([]byte(SyntaxSelectionRanges(src, commentOffset)), &commentSpans); err != nil {
		t.Fatalf("unmarshal comment spans: %v", err)
	}
	if len(commentSpans) < 2 {
		t.Fatalf("expected at least 2 spans for comment, got %d", len(commentSpans))
	}
	if got := src[commentSpans[0].StartByte:commentSpans[0].EndByte]; got != "important comment" {
		t.Fatalf("expected inner comment span %q, got %q", "important comment", got)
	}
}
