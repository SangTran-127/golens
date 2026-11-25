package bridge

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestCallbacksDefaultAndRestore(t *testing.T) {
	if HasStatus() {
		t.Fatal("expected HasStatus to start false")
	}
	if HasDebugEvent() {
		t.Fatal("expected HasDebugEvent to start false")
	}
	if ApplyEdit(1, "{}") {
		t.Fatal("expected default ApplyEdit to return false")
	}
	Log("noop")
	Stderr("noop")
	Debug("noop")
	Diagnostics("main.go", "{}")
	LSPResponse([]byte("{}"))
	DebugEvent("stopped", "{}")
	Status("runEvent", "{}")

	var statusCalls atomic.Int64
	restoreStatus := SetStatus(func(topic, payload string) {
		if topic == "runEvent" && payload == "ok" {
			statusCalls.Add(1)
		}
	})
	if !HasStatus() {
		t.Fatal("expected HasStatus true after SetStatus")
	}
	Status("runEvent", "ok")
	if statusCalls.Load() != 1 {
		t.Fatalf("status calls = %d, want 1", statusCalls.Load())
	}

	var wrappedCalls atomic.Int64
	unwrap := WrapStatus(func(topic, payload string, next func(string, string)) {
		wrappedCalls.Add(1)
		if next != nil {
			next(topic, payload)
		}
	})
	Status("runEvent", "ok")
	if wrappedCalls.Load() != 1 || statusCalls.Load() != 2 {
		t.Fatalf("wrapped=%d status=%d, want 1 and 2", wrappedCalls.Load(), statusCalls.Load())
	}
	unwrap()
	Status("runEvent", "ok")
	if wrappedCalls.Load() != 1 || statusCalls.Load() != 3 {
		t.Fatalf("after unwrap: wrapped=%d status=%d, want 1 and 3", wrappedCalls.Load(), statusCalls.Load())
	}
	restoreStatus()
	if HasStatus() {
		t.Fatal("expected HasStatus false after restore")
	}

	restoreDebugEv := SetDebugEvent(func(event, payload string) {})
	if !HasDebugEvent() {
		t.Fatal("expected HasDebugEvent true after SetDebugEvent")
	}
	restoreDebugEv()
	if HasDebugEvent() {
		t.Fatal("expected HasDebugEvent false after restore")
	}

	restoreApply := SetApplyEdit(func(token int64, edit string) bool { return token == 42 })
	if !ApplyEdit(42, "e") {
		t.Fatal("expected swapped ApplyEdit to accept token 42")
	}
	restoreApply()
	if ApplyEdit(42, "e") {
		t.Fatal("expected restored ApplyEdit to return false")
	}
}

func TestCallbacksConcurrentSwapAndEmitRace(t *testing.T) {
	t.Cleanup(SetLog(nil))
	t.Cleanup(SetStderr(nil))
	t.Cleanup(SetDebug(nil))
	t.Cleanup(SetDiagnostics(nil))
	t.Cleanup(SetLSPResponse(nil))
	t.Cleanup(SetDebugEvent(nil))
	t.Cleanup(SetApplyEdit(nil))
	t.Cleanup(SetStatus(nil))

	const workers = 8
	const iters = 200
	var wg sync.WaitGroup
	var total atomic.Int64

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				r1 := SetLog(func(string) { total.Add(1) })
				r2 := SetStderr(func(string) { total.Add(1) })
				r3 := SetDebug(func(string) { total.Add(1) })
				r4 := SetDiagnostics(func(string, string) { total.Add(1) })
				r5 := SetLSPResponse(func([]byte) { total.Add(1) })
				r6 := SetDebugEvent(func(string, string) { total.Add(1) })
				r7 := SetApplyEdit(func(int64, string) bool { total.Add(1); return true })
				r8 := SetStatus(func(string, string) { total.Add(1) })
				rw := WrapStatus(func(topic, payload string, next func(string, string)) {
					total.Add(1)
					if next != nil {
						next(topic, payload)
					}
				})
				Log("msg")
				Stderr("err")
				Debug("dbg")
				Diagnostics("a.go", "{}")
				LSPResponse([]byte("[]"))
				if HasDebugEvent() {
					DebugEvent("ev", "{}")
				}
				_ = ApplyEdit(int64(id+1), "edit")
				if HasStatus() {
					Status("topic", "payload")
				}
				rw()
				r8()
				r7()
				r6()
				r5()
				r4()
				r3()
				r2()
				r1()
			}
		}(w)
	}

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters*2; i++ {
				Log("msg")
				Stderr("err")
				Debug("dbg")
				Diagnostics("a.go", "{}")
				LSPResponse([]byte("{}"))
				DebugEvent("ev", "{}")
				_ = ApplyEdit(1, "{}")
				Status("topic", "{}")
				_ = HasStatus()
				_ = HasDebugEvent()
			}
		}()
	}

	wg.Wait()
	if total.Load() == 0 {
		t.Fatal("expected concurrent callbacks to execute")
	}
}
