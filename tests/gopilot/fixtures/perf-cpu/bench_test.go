package main

import "testing"

func BenchmarkBuildReport(b *testing.B) {
	data := make([]byte, 4096)
	for i := range data {
		data[i] = byte(i * 7)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		BuildReport(5000, data)
	}
}

func BenchmarkChecksum(b *testing.B) {
	data := make([]byte, 4096)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		checksum(data)
	}
}
