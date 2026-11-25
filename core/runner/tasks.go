package runner

import (
	"encoding/json"
	"sync/atomic"

	"golens/core/bridge"
)

var lastTaskID atomic.Int64

func newTaskID() int64 {
	return lastTaskID.Add(1)
}

type taskStartedEvent struct {
	ID   int64  `json:"id"`
	Kind string `json:"kind"`
	Dir  string `json:"dir"`
}

func emitTaskStarted(id int64, kind, dir string) {
	if !bridge.HasStatus() {
		return
	}
	if b, err := json.Marshal(taskStartedEvent{ID: id, Kind: kind, Dir: dir}); err == nil {
		bridge.Status("taskStarted", string(b))
	}
}

func emitTaskLog(id int64, lines []runOutputLine) {
	if !bridge.HasStatus() || len(lines) == 0 {
		return
	}
	if b, err := json.Marshal(runOutputEvent{ID: id, Lines: lines}); err == nil {
		bridge.Status("taskLog", string(b))
	}
}

func TaskLog(id int64, text string, stderr bool) {
	emitTaskLog(id, []runOutputLine{{Text: text, Stderr: stderr}})
}
