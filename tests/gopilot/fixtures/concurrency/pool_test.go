package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

func blockUntilDone(ctx context.Context, _ Job) (string, error) {
	<-ctx.Done()
	return "", ctx.Err()
}

func TestRunProcessesAllJobsInOrder(t *testing.T) {
	p := &Pool{Workers: 4, Handle: Upper}
	jobs := []Job{{1, "a"}, {2, "b"}, {3, "c"}, {4, "d"}, {5, "e"}}
	results, err := p.Run(context.Background(), jobs)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range results {
		got = append(got, r.Output)
	}
	if !reflect.DeepEqual(got, []string{"A", "B", "C", "D", "E"}) {
		t.Fatalf("got %v", got)
	}
}

func TestErrorsKeepSentinelThroughWrapping(t *testing.T) {
	p := &Pool{Workers: 1, Handle: Upper}
	results, _ := p.Run(context.Background(), []Job{{1, ""}})
	if len(results) != 1 || !errors.Is(results[0].Err, ErrEmptyPayload) {
		t.Fatalf("results = %+v", results)
	}
	if results[0].Err.Error() != "job 1: empty payload" {
		t.Fatalf("message = %q", results[0].Err.Error())
	}
}

func TestFailFastStopsRemainingJobs(t *testing.T) {
	boom := errors.New("boom")
	handle := func(ctx context.Context, job Job) (string, error) {
		switch {
		case job.ID == 1:
			return "ok", nil
		case job.ID == 2:
			return "", boom
		}
		return blockUntilDone(ctx, job)
	}
	p := &Pool{Workers: 1, FailFast: true, Handle: handle}
	jobs := []Job{{1, "a"}, {2, "b"}, {3, "c"}, {4, "d"}, {5, "e"}}
	results, err := p.Run(context.Background(), jobs)
	if err != nil {
		t.Fatalf("parent context was not cancelled, got %v", err)
	}
	if len(results) < 2 || results[0].JobID != 1 || !errors.Is(results[1].Err, boom) {
		t.Fatalf("results = %+v", results)
	}
	for _, r := range results {
		if r.JobID >= 4 {
			t.Fatalf("job %d ran after cancellation", r.JobID)
		}
	}
}

func TestRunReportsParentCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p := &Pool{Workers: 2, Handle: Upper}
	_, err := p.Run(ctx, []Job{{1, "a"}, {2, "b"}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
}

func TestRunWithTimeoutReturnsDeadlineExceeded(t *testing.T) {
	p := &Pool{Workers: 2, Handle: blockUntilDone}
	start := time.Now()
	_, err := p.RunWithTimeout(context.Background(), []Job{{1, "a"}, {2, "b"}}, 20*time.Millisecond)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("timeout was not honoured")
	}
}

func TestProcessDeferOrderAndPanicRecovery(t *testing.T) {
	p := &Pool{Workers: 1, Handle: func(context.Context, Job) (string, error) { panic("bad") }}
	results, _ := p.Run(context.Background(), []Job{{7, "x"}})
	if len(results) != 1 || results[0].Err == nil {
		t.Fatalf("results = %+v", results)
	}
	if !reflect.DeepEqual(p.Events(), []string{"7:begin", "7:end"}) {
		t.Fatalf("events = %v", p.Events())
	}
}
