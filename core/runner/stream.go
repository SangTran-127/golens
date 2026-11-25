package runner

import (
	"errors"
	"io"
	"os"
	"sync"
)

type StreamOptions struct {
	Stderr io.Reader
	OnStop func()
	OnExit func(state string)
}

type errorReader struct {
	r   io.Reader
	mu  *sync.Mutex
	err *error
}

func (e errorReader) Read(p []byte) (int, error) {
	n, err := e.r.Read(p)
	if err != nil && !errors.Is(err, io.EOF) {
		e.mu.Lock()
		if *e.err == nil {
			*e.err = err
		}
		e.mu.Unlock()
	}
	return n, err
}

func StartStream(key, title, dir string, r io.ReadCloser, opts StreamOptions) int64 {
	toStop := reserveRunSlot(key)
	for _, old := range toStop {
		old.stop()
	}
	run := &processRun{
		id:    newTaskID(),
		key:   key,
		title: title,
		dir:   dir,
		done:  make(chan struct{}),
		onStop: func() {
			_ = r.Close()
			if c, ok := opts.Stderr.(io.Closer); ok {
				_ = c.Close()
			}
			if opts.OnStop != nil {
				opts.OnStop()
			}
		},
	}
	programMu.Lock()
	programs[run.id] = run
	latestRunID = run.id
	programMu.Unlock()
	emitRunStarted(run)

	go func() {
		defer close(run.done)
		var mu sync.Mutex
		var readErr error
		output := &runOutputBatcher{id: run.id}
		var wg sync.WaitGroup
		wg.Go(func() {
			streamLines(errorReader{r: r, mu: &mu, err: &readErr}, func(line string) { output.add(line, false) })
		})
		if opts.Stderr != nil {
			wg.Go(func() {
				streamLines(errorReader{r: opts.Stderr, mu: &mu, err: &readErr}, func(line string) { output.add(line, true) })
			})
		}
		wg.Wait()
		_ = r.Close()
		state, errText := "exited", ""
		switch {
		case run.stopped.Load():
			state = "stopped"
		case readErr != nil && !errors.Is(readErr, os.ErrClosed):
			state, errText = "failed", readErr.Error()
			output.add(errText, true)
		}
		output.flush()
		forgetRun(run.id)
		emitRunExited(run, state, errText)
		if opts.OnExit != nil {
			opts.OnExit(state)
		}
	}()
	return run.id
}

func reserveRunSlot(key string) []*processRun {
	programMu.Lock()
	defer programMu.Unlock()
	var toStop []*processRun
	for id, r := range programs {
		if r.key == key {
			toStop = append(toStop, r)
			delete(programs, id)
		}
	}
	for len(programs) >= maxConcurrentPrograms {
		var oldestID int64
		for id := range programs {
			if oldestID == 0 || id < oldestID {
				oldestID = id
			}
		}
		toStop = append(toStop, programs[oldestID])
		delete(programs, oldestID)
	}
	return toStop
}

func forgetRun(id int64) {
	programMu.Lock()
	defer programMu.Unlock()
	delete(programs, id)
	if latestRunID == id {
		latestRunID = 0
		for other := range programs {
			latestRunID = max(latestRunID, other)
		}
	}
}
