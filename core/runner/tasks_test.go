package runner

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/bridge"
)

type taskRecorder struct {
	mu      sync.Mutex
	started map[int64]string
	lines   map[int64][]string
	plain   []string
	results map[int64][]TestResult
	done    chan TestResult
}

func recordTasks(t *testing.T) *taskRecorder {
	t.Helper()
	r := &taskRecorder{started: map[int64]string{}, lines: map[int64][]string{}, results: map[int64][]TestResult{}, done: make(chan TestResult, 8)}
	oldTest := TestEvent
	t.Cleanup(func() { TestEvent = oldTest })
	logFn := func(msg string) {
		r.mu.Lock()
		r.plain = append(r.plain, msg)
		r.mu.Unlock()
	}
	t.Cleanup(bridge.SetLog(logFn))
	t.Cleanup(bridge.SetStderr(logFn))
	t.Cleanup(bridge.SetStatus(func(topic, payload string) {
		r.mu.Lock()
		defer r.mu.Unlock()
		switch topic {
		case "taskStarted":
			var ev taskStartedEvent
			_ = json.Unmarshal([]byte(payload), &ev)
			r.started[ev.ID] = ev.Dir
		case "runEvent", "taskLog":
			var ev struct {
				ID    int64           `json:"id"`
				State string          `json:"state"`
				Dir   string          `json:"dir"`
				Lines []runOutputLine `json:"lines"`
			}
			_ = json.Unmarshal([]byte(payload), &ev)
			if ev.State == "started" {
				r.started[ev.ID] = ev.Dir
			}
			for _, l := range ev.Lines {
				r.lines[ev.ID] = append(r.lines[ev.ID], l.Text)
			}
		}
	}))
	TestEvent = func(s string) {
		var res TestResult
		_ = json.Unmarshal([]byte(s), &res)
		r.mu.Lock()
		r.results[res.Run] = append(r.results[res.Run], res)
		r.mu.Unlock()
		if res.Kind == "done" {
			r.done <- res
		}
	}
	return r
}

func (r *taskRecorder) linesOf(id int64) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return strings.Join(r.lines[id], "\n")
}

func TestProgramExitLineCarriesItsRunID(t *testing.T) {
	r := recordTasks(t)
	dir := t.TempDir()
	cmd := exec.Command("/bin/sh", "-c", "echo program-output")
	cmd.Dir = dir
	run := startProgramWithMeta(cmd, "task-test", "task-test", dir)
	select {
	case <-run.done:
	case <-time.After(10 * time.Second):
		t.Fatal("program did not finish")
	}
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(r.linesOf(run.id), "Process exited successfully.") && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	got := r.linesOf(run.id)
	if !strings.Contains(got, "program-output") || !strings.Contains(got, "Process exited successfully.") {
		t.Fatalf("run %d lines %q", run.id, got)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.started[run.id] != dir {
		t.Fatalf("run %d started in %q, want %q", run.id, r.started[run.id], dir)
	}
	for _, line := range r.plain {
		if strings.HasPrefix(line, "Process ") {
			t.Fatalf("exit line logged without a task id: %q", line)
		}
	}
}

func writeTestModule(t *testing.T, name, marker string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module "+name+"\n\ngo 1.22\n"), 0o644)
	src := "package " + name + "\n\nimport (\n\t\"fmt\"\n\t\"testing\"\n\t\"time\"\n)\n\nfunc TestMarker(t *testing.T) {\n\tfmt.Println(\"" + marker + "\")\n\ttime.Sleep(2 * time.Second)\n}\n"
	_ = os.WriteFile(filepath.Join(dir, name+"_test.go"), []byte(src), 0o644)
	return dir
}

func TestConcurrentTestRunsKeepTheirOwnOutputAndResult(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go not installed")
	}
	r := recordTasks(t)
	a := writeTestModule(t, "alpha", "marker-from-alpha")
	b := writeTestModule(t, "beta", "marker-from-beta")
	idA := RunTestsJSON(a, "", nil)
	idB := RunTestsJSON(b, "", nil)
	if idA == 0 || idB == 0 || idA == idB {
		t.Fatalf("task ids %d and %d", idA, idB)
	}
	results := map[int64]TestResult{}
	for len(results) < 2 {
		select {
		case res := <-r.done:
			results[res.Run] = res
		case <-time.After(120 * time.Second):
			t.Fatalf("only %d of 2 runs finished: %+v", len(results), results)
		}
	}
	for id, dir := range map[int64]string{idA: a, idB: b} {
		if results[id].Status != "pass" || results[id].Passed != 1 {
			t.Fatalf("run %d in %s finished %+v", id, dir, results[id])
		}
		r.mu.Lock()
		startedDir := r.started[id]
		r.mu.Unlock()
		if startedDir != dir {
			t.Fatalf("run %d started in %q, want %q", id, startedDir, dir)
		}
	}
	linesA, linesB := r.linesOf(idA), r.linesOf(idB)
	if !strings.Contains(linesA, "marker-from-alpha") || strings.Contains(linesA, "marker-from-beta") {
		t.Fatalf("alpha run lines %q", linesA)
	}
	if !strings.Contains(linesB, "marker-from-beta") || strings.Contains(linesB, "marker-from-alpha") {
		t.Fatalf("beta run lines %q", linesB)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, line := range r.plain {
		if strings.Contains(line, "marker-from-") {
			t.Fatalf("test output logged without a task id: %q", line)
		}
	}
}

func TestTaskIDsAreSharedAcrossProgramsAndTests(t *testing.T) {
	recordTasks(t)
	dir := t.TempDir()
	cmd := exec.Command("/bin/sh", "-c", "true")
	cmd.Dir = dir
	program := startProgramWithMeta(cmd, "task-id-test", "task-id-test", dir)
	<-program.done
	test := &processRun{id: newTaskID(), done: make(chan struct{})}
	if test.id <= program.id {
		t.Fatalf("test task id %d not after program id %d", test.id, program.id)
	}
}
