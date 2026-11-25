package benchlab

import "time"

func Jitter(i int) time.Duration {
	x := uint32(i)*2654435761 + 12345
	x ^= x >> 15
	return time.Duration(50+x%400) * time.Microsecond
}

func Wobble(i int) {
	time.Sleep(Jitter(i))
}
