package main

import (
	"context"
	"errors"
	"fmt"
)

func main() {
	pool := &Pool{Workers: 3, Handle: Upper}
	jobs := []Job{{1, "alpha"}, {2, "beta"}, {3, ""}, {4, "delta"}}
	results, err := pool.Run(context.Background(), jobs)
	if err != nil {
		fmt.Println("run:", err)
		return
	}
	for _, r := range results {
		switch {
		case errors.Is(r.Err, ErrEmptyPayload):
			fmt.Printf("job %d skipped: %v\n", r.JobID, r.Err)
		case r.Err != nil:
			fmt.Printf("job %d failed: %v\n", r.JobID, r.Err)
		default:
			fmt.Printf("job %d -> %s\n", r.JobID, r.Output)
		}
	}
}
