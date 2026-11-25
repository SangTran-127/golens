package docker

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"
)

var engineGen struct {
	sync.Mutex
	ctx    context.Context
	cancel context.CancelFunc
}

func generation() context.Context {
	engineGen.Lock()
	defer engineGen.Unlock()
	if engineGen.ctx == nil {
		engineGen.ctx, engineGen.cancel = context.WithCancel(context.Background())
	}
	return engineGen.ctx
}

func endGeneration() {
	engineGen.Lock()
	cancel := engineGen.cancel
	engineGen.ctx, engineGen.cancel = nil, nil
	engineGen.Unlock()
	if cancel != nil {
		cancel()
	}
}

func withGeneration(parent context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	stop := context.AfterFunc(generation(), cancel)
	return ctx, func() {
		stop()
		cancel()
	}
}

func UseContext(name string) ActionResult {
	name = strings.TrimSpace(name)
	if name == "" {
		return ActionResult{Error: "Choose a Docker context."}
	}
	if !knownContext(name) {
		return ActionResult{Error: fmt.Sprintf("There’s no Docker context named “%s”.", name)}
	}
	if name == CurrentContext() {
		chosenContext.Lock()
		chosenContext.name = name
		chosenContext.Unlock()
		return ActionResult{OK: true}
	}
	chosenContext.Lock()
	chosenContext.name = name
	chosenContext.Unlock()
	closeEngineConnections()
	return ActionResult{OK: true}
}

func closeEngineConnections() {
	clientCache.Lock()
	clientCache.c = nil
	clientCache.Unlock()
	endGeneration()
	watchState.Lock()
	w := watchState.w
	watchState.Unlock()
	if w != nil {
		select {
		case w.widen <- struct{}{}:
		default:
		}
	}
	waitStreamsClosed(time.Second)
	CloseIdleConnections()
}

func waitStreamsClosed(limit time.Duration) {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) && openLogStreams()+openStatsStreams() > 0 {
		time.Sleep(10 * time.Millisecond)
	}
}

func cliContextEnv(env []string) []string {
	name := chosenContextName()
	if name == "" {
		return env
	}
	out := env[:0]
	for _, kv := range env {
		if strings.HasPrefix(kv, "DOCKER_CONTEXT=") || (name != defaultContextName && strings.HasPrefix(kv, "DOCKER_HOST=")) {
			continue
		}
		out = append(out, kv)
	}
	return append(out, "DOCKER_CONTEXT="+name)
}

func CLIContextArgs() []string {
	if name := chosenContextName(); name != "" {
		return []string{"--context", name}
	}
	return nil
}
