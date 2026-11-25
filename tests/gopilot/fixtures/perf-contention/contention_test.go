package main

import "testing"

func TestContendCountsEveryAdd(t *testing.T) {
	if got := Contend(4, 5); got != 20 {
		t.Fatalf("Contend = %d", got)
	}
}

func TestHandoffSumsItems(t *testing.T) {
	if got := Handoff(4); got != 10 {
		t.Fatalf("Handoff = %d", got)
	}
}

func TestSpinIsDeterministic(t *testing.T) {
	if spin(10) != spin(10) || spin(10) == spin(11) {
		t.Fatal("spin is not a deterministic function of n")
	}
}
