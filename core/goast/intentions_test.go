package goast

import (
	"strings"
	"testing"
)

func TestIntention_WrapErr_AssignStmt(t *testing.T) {
	src := `package kv

type KVStore struct{}

func (k *KVStore) Load(key string) (string, int, error) {
	data, err := load(key)
	return data, 0, nil
}
`
	offset := strings.Index(src, "data, err := load(key)")
	listReply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/kv.go",
		Src:    src,
		Offset: offset,
		Action: "list",
	})
	if listReply.Error != "" {
		t.Fatalf("unexpected error in list: %s", listReply.Error)
	}
	foundWrapErr := false
	for _, item := range listReply.Available {
		if item.ID == "wrap_err" && item.Title == "Handle Error with if err != nil" {
			foundWrapErr = true
		}
	}
	if !foundWrapErr {
		t.Fatalf("expected wrap_err in available intentions, got %+v", listReply.Available)
	}

	reply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/kv.go",
		Src:    src,
		Offset: offset,
		Action: "wrap_err",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error in wrap_err: %s", reply.Error)
	}
	edits := reply.EditsByPath["/proj/kv.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit, got %d", len(edits))
	}
	wantInsert := "if err != nil {\n\t\treturn \"\", 0, err\n\t}"
	if !strings.Contains(edits[0].NewText, wantInsert) {
		t.Fatalf("expected edit NewText to contain %q, got %q", wantInsert, edits[0].NewText)
	}

	updated := applyEditsToText(src, edits)
	wantCode := `package kv

type KVStore struct{}

func (k *KVStore) Load(key string) (string, int, error) {
	data, err := load(key)
	if err != nil {
		return "", 0, err
	}
	return data, 0, nil
}
`
	if updated != wantCode {
		t.Fatalf("unexpected updated source:\ngot:\n%s\nwant:\n%s", updated, wantCode)
	}
}

func TestIntention_WrapErr_ExprStmt(t *testing.T) {
	src := `package kv

type KVStore struct{}

func (k *KVStore) Reset() error {
	k.Close()
	return nil
}
`
	offset := strings.Index(src, "k.Close()")
	reply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/kv.go",
		Src:    src,
		Offset: offset,
		Action: "wrap_err",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	edits := reply.EditsByPath["/proj/kv.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit, got %d", len(edits))
	}
	wantRewrite := "if err := k.Close(); err != nil {\n\t\treturn err\n\t}"
	if edits[0].NewText != wantRewrite {
		t.Fatalf("expected NewText %q, got %q", wantRewrite, edits[0].NewText)
	}

	updated := applyEditsToText(src, edits)
	wantCode := `package kv

type KVStore struct{}

func (k *KVStore) Reset() error {
	if err := k.Close(); err != nil {
		return err
	}
	return nil
}
`
	if updated != wantCode {
		t.Fatalf("unexpected updated source:\ngot:\n%s\nwant:\n%s", updated, wantCode)
	}
}

func TestIntention_WrapErr_ZeroValueTypesAndVoid(t *testing.T) {
	src := `package kv

type Reader interface {
	Read() error
}

type Config struct {
	Host string
}

func Process() (*Config, []byte, map[string]int, bool, Reader, Config, error) {
	parseErr := validate()
	return nil, nil, nil, true, nil, Config{}, nil
}

func FireAndForget() {
	err := notify()
}
`
	offset := strings.Index(src, "parseErr := validate()")
	reply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/kv.go",
		Src:    src,
		Offset: offset,
		Action: "wrap_err",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	updated := applyEditsToText(src, reply.EditsByPath["/proj/kv.go"])
	wantReturn := "return nil, nil, nil, false, nil, Config{}, parseErr"
	if !strings.Contains(updated, wantReturn) {
		t.Fatalf("expected %q in updated code:\n%s", wantReturn, updated)
	}

	voidOffset := strings.Index(src, "err := notify()")
	voidReply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/kv.go",
		Src:    src,
		Offset: voidOffset,
		Action: "wrap_err",
	})
	if voidReply.Error != "" {
		t.Fatalf("unexpected error on void func: %s", voidReply.Error)
	}
	voidUpdated := applyEditsToText(src, voidReply.EditsByPath["/proj/kv.go"])
	if !strings.Contains(voidUpdated, "if err != nil {\n\t\treturn\n\t}") {
		t.Fatalf("expected bare return in void func, got:\n%s", voidUpdated)
	}
}

func TestIntention_ToggleString(t *testing.T) {
	src := `package main

func greet() string {
	msg := "hello\nworld"
	return msg
}
`
	offset := strings.Index(src, `"hello\nworld"`) + 2
	reply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/main.go",
		Src:    src,
		Offset: offset,
		Action: "toggle_string",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	edits := reply.EditsByPath["/proj/main.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit, got %d", len(edits))
	}
	if edits[0].NewText != "`hello\nworld`" {
		t.Fatalf("expected raw string with newline, got %q", edits[0].NewText)
	}

	rawSrc := applyEditsToText(src, edits)
	rawOffset := strings.Index(rawSrc, "`hello\nworld`") + 2
	backReply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/main.go",
		Src:    rawSrc,
		Offset: rawOffset,
		Action: "toggle_string",
	})
	if backReply.Error != "" {
		t.Fatalf("unexpected error toggling back: %s", backReply.Error)
	}
	restored := applyEditsToText(rawSrc, backReply.EditsByPath["/proj/main.go"])
	if restored != src {
		t.Fatalf("round-trip mismatch:\ngot:\n%s\nwant:\n%s", restored, src)
	}
}

func TestIntention_ToggleVarAssign(t *testing.T) {
	src := `package main

func compute() int {
	count := 42
	return count
}
`
	offset := strings.Index(src, "count := 42")
	reply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/main.go",
		Src:    src,
		Offset: offset,
		Action: "toggle_var_assign",
	})
	if reply.Error != "" {
		t.Fatalf("unexpected error: %s", reply.Error)
	}
	edits := reply.EditsByPath["/proj/main.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit, got %d", len(edits))
	}
	if edits[0].NewText != "var count = 42" {
		t.Fatalf("expected %q, got %q", "var count = 42", edits[0].NewText)
	}

	varSrc := applyEditsToText(src, edits)
	varOffset := strings.Index(varSrc, "var count = 42")
	backReply := ApplyGoIntention(IntentionReq{
		Path:   "/proj/main.go",
		Src:    varSrc,
		Offset: varOffset,
		Action: "toggle_var_assign",
	})
	if backReply.Error != "" {
		t.Fatalf("unexpected error toggling back: %s", backReply.Error)
	}
	backEdits := backReply.EditsByPath["/proj/main.go"]
	if len(backEdits) != 1 || backEdits[0].NewText != "count := 42" {
		t.Fatalf("expected %q, got %+v", "count := 42", backEdits)
	}
	restored := applyEditsToText(varSrc, backEdits)
	if restored != src {
		t.Fatalf("round-trip mismatch:\ngot:\n%s\nwant:\n%s", restored, src)
	}
}
