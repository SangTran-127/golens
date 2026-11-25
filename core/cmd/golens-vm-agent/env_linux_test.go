package main

import (
	"slices"
	"testing"
)

func TestGuestEnvTurnsCgoOffUnlessTheRunAsksForIt(t *testing.T) {
	if env := mergeGuestEnv(nil); !slices.Contains(env, "CGO_ENABLED=0") {
		t.Fatalf("default guest env lacks CGO_ENABLED=0: %v", env)
	}
	env := mergeGuestEnv([]string{"CGO_ENABLED=1"})
	if !slices.Contains(env, "CGO_ENABLED=1") || slices.Contains(env, "CGO_ENABLED=0") {
		t.Fatalf("a run configuration could not turn cgo on: %v", env)
	}
}
