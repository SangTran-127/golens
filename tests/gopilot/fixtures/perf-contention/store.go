package main

import (
	"sync"
	"time"
)

type Store struct {
	mu     sync.Mutex
	counts map[int]int
}

func NewStore() *Store {
	return &Store{counts: make(map[int]int)}
}

func (s *Store) Add(key int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	time.Sleep(100 * time.Microsecond)
	s.counts[key]++
}

func (s *Store) Total() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	total := 0
	for _, c := range s.counts {
		total += c
	}
	return total
}

func Contend(workers, perWorker int) int {
	s := NewStore()
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				s.Add(w*perWorker + i)
			}
		}(w)
	}
	wg.Wait()
	return s.Total()
}
