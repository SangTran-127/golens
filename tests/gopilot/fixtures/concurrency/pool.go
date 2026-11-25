package main

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

type Job struct {
	ID      int
	Payload string
}

type Result struct {
	JobID  int
	Output string
	Err    error
}

type Handler func(ctx context.Context, job Job) (string, error)

type Pool struct {
	Workers  int
	FailFast bool
	Handle   Handler

	mu     sync.Mutex
	events []string
}

func (p *Pool) Run(parent context.Context, jobs []Job) ([]Result, error) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	in := make(chan Job)
	out := make(chan Result)

	go feed(ctx, jobs, in)

	var wg sync.WaitGroup
	for i := 0; i < max(p.Workers, 1); i++ {
		wg.Add(1)
		go p.worker(ctx, in, out, &wg)
	}
	go func() {
		wg.Wait()
		close(out)
	}()

	var results []Result
	for r := range out {
		results = append(results, r)
		if r.Err != nil && p.FailFast {
			cancel()
		}
	}
	sort.Slice(results, func(a, b int) bool { return results[a].JobID < results[b].JobID })
	return results, parent.Err()
}

func feed(ctx context.Context, jobs []Job, in chan<- Job) {
	defer close(in)
	for _, j := range jobs {
		select {
		case in <- j:
		case <-ctx.Done():
			return
		}
	}
}

func (p *Pool) worker(ctx context.Context, in <-chan Job, out chan<- Result, wg *sync.WaitGroup) {
	defer wg.Done()
	for job := range in {
		if ctx.Err() != nil {
			return
		}
		res := p.process(ctx, job)
		select {
		case out <- res:
		case <-ctx.Done():
			return
		}
	}
}

func (p *Pool) process(ctx context.Context, job Job) (res Result) {
	p.trace(job.ID, "begin")
	defer p.trace(job.ID, "end")
	defer func() {
		if r := recover(); r != nil {
			res = Result{JobID: job.ID, Err: fmt.Errorf("job %d: panic: %v", job.ID, r)}
		}
	}()
	out, err := p.Handle(ctx, job)
	if err != nil {
		return Result{JobID: job.ID, Err: fmt.Errorf("job %d: %w", job.ID, err)}
	}
	return Result{JobID: job.ID, Output: out}
}

func (p *Pool) trace(id int, stage string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.events = append(p.events, fmt.Sprintf("%d:%s", id, stage))
}

func (p *Pool) Events() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.events...)
}

func (p *Pool) RunWithTimeout(ctx context.Context, jobs []Job, d time.Duration) ([]Result, error) {
	ctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()

	done := make(chan []Result)
	go func() {
		res, _ := p.Run(ctx, jobs)
		done <- res
	}()

	select {
	case res := <-done:
		return res, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
