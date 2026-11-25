package benchlab

import (
	"fmt"
	"testing"
)

func makeItems(n int) []string {
	items := make([]string, n)
	for i := range items {
		items[i] = fmt.Sprintf("item-%d", i%(n/2))
	}
	return items
}

func BenchmarkDedupe(b *testing.B) {
	items := makeItems(2000)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Dedupe(items)
	}
}

func BenchmarkJoinSlow(b *testing.B) {
	parts := makeItems(500)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		JoinSlow(parts, ",")
	}
}

func BenchmarkJoinFast(b *testing.B) {
	parts := makeItems(500)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		JoinFast(parts, ",")
	}
}

func BenchmarkNoisy(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Wobble(i)
	}
}
