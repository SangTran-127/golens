package database

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCloseConsoleReleasesMultiConsoleSpoolsAndTriggersMemoryRelease(t *testing.T) {
	for releaseRequests.Load() != 0 {
		time.Sleep(5 * time.Millisecond)
	}
	var freeCalls atomic.Int32
	origFree := swapFreeOSMemory(func() {
		freeCalls.Add(1)
	})
	defer func() {
		for releaseRequests.Load() != 0 {
			time.Sleep(5 * time.Millisecond)
		}
		swapFreeOSMemory(origFree)
	}()

	e := newEnv(t)
	spoolState.limit = 16 << 10
	e.configure(sqliteDef("ds1", ordersDB(e, 3000)))

	r1 := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c1", Text: "SELECT id, note, amount FROM orders ORDER BY id", Mode: "all", PageSize: 200})
	r2 := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c2", Text: "SELECT id, note, amount FROM orders ORDER BY id", Mode: "all", PageSize: 200})
	r3 := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c3", Text: "SELECT id, note FROM orders ORDER BY id LIMIT 100", Mode: "all", PageSize: 200})

	for _, r := range []ExecuteResponse{r1, r2, r3} {
		if r.Error != nil || len(r.Statements) != 1 || r.Statements[0].ResultID == "" {
			t.Fatalf("unexpected execute response: %+v", r)
		}
	}

	if f := FetchAll(r1.Statements[0].ResultID); f.Error != nil || !f.Complete {
		t.Fatalf("FetchAll r1 failed: %+v", f)
	}
	if f := FetchAll(r2.Statements[0].ResultID); f.Error != nil || !f.Complete {
		t.Fatalf("FetchAll r2 failed: %+v", f)
	}

	before := GetStats()
	if before.OpenResults != 3 || (before.SpoolMemBytes == 0 && before.SpoolDiskBytes == 0) {
		t.Fatalf("expected 3 open results and active spool usage before CloseConsole, got %+v", before)
	}

	var wg sync.WaitGroup
	for _, cid := range []string{"c1", "c2"} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			res := CloseConsole(id, false)
			if !res.OK {
				t.Errorf("CloseConsole(%s) failed: %+v", id, res)
			}
		}(cid)
	}
	wg.Wait()

	mid := GetStats()
	if mid.OpenResults != 1 {
		t.Fatalf("expected 1 open result remaining for c3, got %+v", mid)
	}

	if res := CloseConsole("c3", false); !res.OK {
		t.Fatalf("CloseConsole(c3) failed: %+v", res)
	}

	after := GetStats()
	if after.OpenResults != 0 || after.SpoolMemBytes != 0 || after.SpoolDiskBytes != 0 {
		t.Fatalf("expected all results and spool bytes reclaimed to 0, got %+v", after)
	}

	deadline := time.Now().Add(2 * time.Second)
	for (releaseRequests.Load() != 0 || freeCalls.Load() == 0) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if freeCalls.Load() == 0 {
		t.Fatal("expected CloseConsole result cleanup to trigger releaseMemory")
	}
}

func TestCloseConsoleAfterExplicitCloseResultStillReleasesMemory(t *testing.T) {
	for releaseRequests.Load() != 0 {
		time.Sleep(5 * time.Millisecond)
	}
	var freeCalls atomic.Int32
	origFree := swapFreeOSMemory(func() {
		freeCalls.Add(1)
	})
	defer func() {
		for releaseRequests.Load() != 0 {
			time.Sleep(5 * time.Millisecond)
		}
		swapFreeOSMemory(origFree)
	}()

	e := newEnv(t)
	e.configure(sqliteDef("ds1", ordersDB(e, 3000)))

	res := e.exec(ExecuteRequest{DataSourceID: "ds1", ConsoleID: "c1", Text: "SELECT id, note FROM orders ORDER BY id", Mode: "all", PageSize: 200})
	if res.Error != nil || len(res.Statements) != 1 || res.Statements[0].ResultID == "" {
		t.Fatalf("unexpected execute response: %+v", res)
	}
	if f := FetchAll(res.Statements[0].ResultID); f.Error != nil || !f.Complete {
		t.Fatalf("FetchAll failed: %+v", f)
	}

	CloseResult(res.Statements[0].ResultID)
	deadline := time.Now().Add(2 * time.Second)
	for releaseRequests.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	freeCalls.Store(0)

	closed := CloseConsole("c1", false)
	if !closed.OK {
		t.Fatalf("CloseConsole(c1) failed: %+v", closed)
	}

	deadline = time.Now().Add(2 * time.Second)
	for (releaseRequests.Load() != 0 || freeCalls.Load() == 0) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if freeCalls.Load() == 0 {
		t.Fatal("expected CloseConsole on connected console to trigger releaseMemory even after explicit CloseResult")
	}
}
