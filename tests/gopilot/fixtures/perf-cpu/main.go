package main

import "fmt"

func main() {
	data := make([]byte, 4096)
	for i := range data {
		data[i] = byte(i * 7)
	}
	r := BuildReport(20000, data)
	fmt.Println(r.Label, r.Primes, r.Checksum)
}
