package main

import "time"

func Handoff(items int) int {
	ch := make(chan int)
	go func() {
		defer close(ch)
		for i := 1; i <= items; i++ {
			time.Sleep(2 * time.Millisecond)
			ch <- i
		}
	}()
	sum := 0
	for v := range ch {
		sum += v
	}
	return sum
}

func spin(n int) uint64 {
	var x uint64 = 88172645463325252
	for i := 0; i < n; i++ {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
	}
	return x
}
