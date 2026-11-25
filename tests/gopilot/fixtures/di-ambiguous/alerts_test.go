package main

import "testing"

type recorder struct{ got []string }

func (r *recorder) Send(msg string) error {
	r.got = append(r.got, msg)
	return nil
}

func TestRaiseUsesNotifier(t *testing.T) {
	r := &recorder{}
	NewAlerts(r).Raise("x")
	if len(r.got) != 1 || r.got[0] != "x" {
		t.Fatalf("got %v", r.got)
	}
}

func TestBuildRejectsUnknownChannel(t *testing.T) {
	if _, err := build(Config{Channel: "pager"}); err == nil {
		t.Fatal("expected error")
	}
}
