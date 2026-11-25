package fsutil

import (
	"context"
	"sync"
)

const maxPendingGitCancels = 1024

var (
	gitCallsMu       sync.Mutex
	gitCallsRunning  = map[int64]context.CancelFunc{}
	gitCallsCanceled = map[int64]struct{}{}
)

func BeginGitCall(parent context.Context, id int64) (context.Context, func()) {
	ctx, cancel := context.WithCancel(parent)
	if id == 0 {
		return ctx, cancel
	}
	gitCallsMu.Lock()
	if _, canceled := gitCallsCanceled[id]; canceled {
		delete(gitCallsCanceled, id)
		cancel()
	} else {
		gitCallsRunning[id] = cancel
	}
	gitCallsMu.Unlock()
	return ctx, func() {
		gitCallsMu.Lock()
		delete(gitCallsRunning, id)
		gitCallsMu.Unlock()
		cancel()
	}
}

func CancelGitCall(id int64) {
	if id == 0 {
		return
	}
	gitCallsMu.Lock()
	defer gitCallsMu.Unlock()
	if cancel, ok := gitCallsRunning[id]; ok {
		cancel()
		return
	}
	if len(gitCallsCanceled) >= maxPendingGitCancels {
		gitCallsCanceled = map[int64]struct{}{}
	}
	gitCallsCanceled[id] = struct{}{}
}

func RunningGitCalls() int {
	gitCallsMu.Lock()
	defer gitCallsMu.Unlock()
	return len(gitCallsRunning)
}
