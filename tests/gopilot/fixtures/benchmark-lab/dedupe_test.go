package benchlab

import (
	"reflect"
	"testing"
)

func TestDedupePinsBehaviour(t *testing.T) {
	cases := []struct {
		name string
		in   []string
		want []string
	}{
		{"nil input", nil, []string{}},
		{"empty input", []string{}, []string{}},
		{"no duplicates", []string{"a", "b", "c"}, []string{"a", "b", "c"}},
		{"keeps first occurrence order", []string{"b", "a", "b", "c", "a"}, []string{"b", "a", "c"}},
		{"empty string is a value", []string{"", "a", ""}, []string{"", "a"}},
		{"case sensitive", []string{"A", "a", "A"}, []string{"A", "a"}},
		{"all equal", []string{"x", "x", "x"}, []string{"x"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Dedupe(c.in)
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("Dedupe(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestDedupeDoesNotModifyInput(t *testing.T) {
	in := []string{"a", "a", "b"}
	Dedupe(in)
	if !reflect.DeepEqual(in, []string{"a", "a", "b"}) {
		t.Fatalf("input changed: %q", in)
	}
}

func TestDedupeReturnsNonNilEmptySlice(t *testing.T) {
	if got := Dedupe(nil); got == nil {
		t.Fatal("Dedupe(nil) returned nil")
	}
}
