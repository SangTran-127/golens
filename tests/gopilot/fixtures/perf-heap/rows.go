package main

import (
	"fmt"
	"strings"
)

func renderRows(n int) int {
	total := 0
	for i := 0; i < n; i++ {
		scratch := make([]byte, 96*1024)
		scratch[0] = byte(i)
		line := fmt.Sprintf("row-%d-%s", i, strings.Repeat("x", 32))
		total += len(line) + int(scratch[0])
	}
	return total
}
