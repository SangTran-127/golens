package benchlab

import "testing"

func TestJoinVariantsAgree(t *testing.T) {
	cases := [][]string{nil, {}, {"a"}, {"a", "b"}, {"a", "", "c"}}
	for _, parts := range cases {
		if JoinSlow(parts, ",") != JoinFast(parts, ",") {
			t.Fatalf("variants differ for %q", parts)
		}
	}
	if got := JoinFast([]string{"a", "b", "c"}, "-"); got != "a-b-c" {
		t.Fatalf("got %q", got)
	}
}

func TestJitterStaysInRange(t *testing.T) {
	for i := 0; i < 1000; i++ {
		d := Jitter(i)
		if d < 50*1000 || d >= 450*1000 {
			t.Fatalf("Jitter(%d) = %v", i, d)
		}
	}
}
