package database

import (
	"context"
	"testing"
)

type interruptCounter struct {
	engineConn
	calls int
}

func (c *interruptCounter) interrupt(ds *dataSource, cancel context.CancelFunc) {
	c.calls++
	cancel()
}

func TestStopBeforeTheStatementRegistersStillInterruptsIt(t *testing.T) {
	s := &session{}
	if s.interrupt() {
		t.Fatal("interrupt reported a running statement before one started")
	}
	c := &interruptCounter{}
	ctx, cancel := context.WithCancel(context.Background())
	s.setRunning(c, cancel)
	if c.calls != 1 || ctx.Err() == nil {
		t.Fatalf("statement started after Stop was not interrupted: calls=%d err=%v", c.calls, ctx.Err())
	}
	s.setRunning(nil, nil)
	s.cancelled = false
	c2 := &interruptCounter{}
	_, cancel2 := context.WithCancel(context.Background())
	s.setRunning(c2, cancel2)
	if c2.calls != 0 {
		t.Fatal("a statement without a pending Stop was interrupted")
	}
}
