package main

import "testing"

func TestCountPrimes(t *testing.T) {
	cases := map[int]int{1: 0, 2: 1, 10: 4, 100: 25, 1000: 168}
	for limit, want := range cases {
		if got := countPrimes(limit); got != want {
			t.Fatalf("countPrimes(%d) = %d, want %d", limit, got, want)
		}
	}
}

func TestChecksumIsStable(t *testing.T) {
	if got := checksum([]byte("abc")); got != 440920331 {
		t.Fatalf("checksum = %d", got)
	}
}

func TestLabel(t *testing.T) {
	if got := label(10, 3); got != "limit=10 size=3" {
		t.Fatalf("label = %q", got)
	}
}
