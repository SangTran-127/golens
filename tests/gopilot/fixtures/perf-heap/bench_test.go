package main

import "testing"

func BenchmarkRenderRows(b *testing.B) {
	loadIndex(16, 256*1024)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		renderRows(100)
	}
}
