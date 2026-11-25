package main

func countPrimes(limit int) int {
	count := 0
	for n := 2; n <= limit; n++ {
		if isPrime(n) {
			count++
		}
	}
	return count
}

func isPrime(n int) bool {
	if n < 2 {
		return false
	}
	for d := 2; d < n; d++ {
		if n%d == 0 {
			return false
		}
	}
	return true
}
