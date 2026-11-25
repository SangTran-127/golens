package main

import "testing"

func BenchmarkContention(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Contend(4, 10)
	}
}

func BenchmarkHandoff(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Handoff(20)
	}
}

func BenchmarkSpin(b *testing.B) {
	for i := 0; i < b.N; i++ {
		spin(2_000_000)
	}
}
