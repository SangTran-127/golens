package dap

import (
	"strings"
	"testing"

	"github.com/google/go-dap"
)

func frame(name, path string, line int) dap.StackFrame {
	return dap.StackFrame{Name: name, Source: &dap.Source{Path: path}, Line: line}
}

func TestThreadLabelsReadsDelvePprofLabels(t *testing.T) {
	cases := map[string]string{
		"[Go 18 worker:alpha] main.worker":                   "worker:alpha",
		"* [Go 7 job:42 worker:beta] main.worker (Thread 3)": "job:42 worker:beta",
		"[Go 1] main.main":                                   "",
		"Dummy":                                              "",
	}
	for name, want := range cases {
		if got := ThreadLabels(name); got != want {
			t.Errorf("ThreadLabels(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestGroupByStackMarksSystemGoroutinesAndKeepsLabels(t *testing.T) {
	worker := []dap.StackFrame{frame("runtime.gopark", "/go/src/runtime/proc.go", 435), frame("main.worker", "/w/main.go", 14), frame("runtime.goexit", "/go/src/runtime/asm.s", 1)}
	system := []dap.StackFrame{frame("runtime.gopark", "/go/src/runtime/proc.go", 435), frame("runtime.bgsweep", "/go/src/runtime/mgcsweep.go", 300)}
	threads := []dap.Thread{
		{Id: 18, Name: "[Go 18 worker:alpha] main.worker"},
		{Id: 19, Name: "[Go 19 worker:beta] main.worker"},
		{Id: 2, Name: "[Go 2] runtime.gopark"},
	}
	groups := GroupByStack(threads, map[int][]dap.StackFrame{18: worker, 19: worker, 2: system})
	if len(groups) != 2 {
		t.Fatalf("groups %+v", groups)
	}
	if groups[0].System || groups[0].Count != 2 || groups[0].Top != "main.worker" || groups[0].Labels[1] != "worker:beta" {
		t.Fatalf("worker group %+v", groups[0])
	}
	if !groups[1].System || groups[1].FrameLocations[1] != "/go/src/runtime/mgcsweep.go:300" {
		t.Fatalf("system group %+v", groups[1])
	}
}

func TestGoroutineDumpMergesIdenticalStacks(t *testing.T) {
	worker := []dap.StackFrame{frame("runtime.gopark", "/go/src/runtime/proc.go", 435), frame("main.worker", "/w/main.go", 14)}
	server := []dap.StackFrame{frame("main.serve", "/w/main.go", 30)}
	system := []dap.StackFrame{frame("runtime.gopark", "/go/src/runtime/proc.go", 435)}
	threads := []dap.Thread{
		{Id: 2, Name: "[Go 2] runtime.gopark"},
		{Id: 7, Name: "[Go 7] main.serve"},
		{Id: 18, Name: "[Go 18 worker:alpha] main.worker"},
		{Id: 19, Name: "[Go 19] main.worker"},
		{Id: 20, Name: "[Go 20 worker:alpha] main.worker"},
	}
	dump := FormatGoroutineDump(GroupByStack(threads, map[int][]dap.StackFrame{2: system, 7: server, 18: worker, 19: worker, 20: worker}), "/w/")
	for _, want := range []string{
		"Goroutine dump: 5 goroutines, 3 distinct stacks\n",
		"\n3 goroutines: 18 [worker:alpha], 19, 20 [worker:alpha]\n  runtime.gopark\n      /go/src/runtime/proc.go:435\n> main.worker\n      /w/main.go:14\n",
		"\n1 goroutine: 7\n> main.serve\n",
		"\n1 goroutine (system): 2\n",
	} {
		if !strings.Contains(dump, want) {
			t.Fatalf("dump lacks %q:\n%s", want, dump)
		}
	}
	if strings.Index(dump, "3 goroutines:") > strings.Index(dump, "1 goroutine: 7") || strings.Index(dump, "1 goroutine: 7") > strings.Index(dump, "(system)") {
		t.Fatalf("larger user groups come first and system goroutines last:\n%s", dump)
	}
	if strings.Count(dump, "main.worker") != 1 {
		t.Fatalf("identical stacks must be merged:\n%s", dump)
	}
}

func TestLaunchAndAttachAskDelveForPprofLabels(t *testing.T) {
	if labels, _ := launchArguments(RunConfig{}, "/w", "x")["showPprofLabels"].([]string); len(labels) != 1 || labels[0] != "*" {
		t.Fatalf("launch showPprofLabels %v", labels)
	}
	if labels, _ := attachArguments(RunConfig{AttachPID: 4})["showPprofLabels"].([]string); len(labels) != 1 || labels[0] != "*" {
		t.Fatalf("attach showPprofLabels %v", labels)
	}
}
