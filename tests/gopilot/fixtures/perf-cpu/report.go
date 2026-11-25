package main

import (
	"fmt"
	"strings"
)

type Report struct {
	Primes   int
	Checksum uint32
	Label    string
}

func BuildReport(limit int, data []byte) Report {
	return Report{
		Primes:   countPrimes(limit),
		Checksum: checksum(data),
		Label:    label(limit, len(data)),
	}
}

func label(limit, size int) string {
	return strings.TrimSpace(fmt.Sprintf("limit=%d size=%d", limit, size))
}

func checksum(data []byte) uint32 {
	var sum uint32 = 2166136261
	for _, b := range data {
		sum ^= uint32(b)
		sum *= 16777619
	}
	return sum
}
