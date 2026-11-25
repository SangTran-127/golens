package bridge

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestExecutionModeAndHostBypass(t *testing.T) {
	prev := ExecutionMode()
	t.Cleanup(func() { SetExecutionMode(prev) })

	SetVsockDialer(func(port uint32) (int, error) {
		t.Fatal("low-level vsock dialer should not be invoked in host mode")
		return -1, nil
	})
	t.Cleanup(func() { SetVsockDialer(nil) })

	SetExecutionMode("host")
	if !IsHostMode() {
		t.Fatal("expected IsHostMode() == true")
	}
	if ExecutionMode() != "host" {
		t.Fatalf("expected host mode, got %q", ExecutionMode())
	}

	_, err := DialSandboxVsock(context.Background(), 2002)
	if !errors.Is(err, ErrVMNotRunning) {
		t.Fatalf("expected ErrVMNotRunning in host mode, got %v", err)
	}
	if !CanFallbackToHost(err) {
		t.Fatal("expected CanFallbackToHost(err) == true in host mode")
	}

	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()
	SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return c1, nil
	})
	defer SetVsockConnDialer(nil)

	conn, err := DialSandboxVsock(context.Background(), 2002)
	if err != nil || conn != c1 {
		t.Fatalf("expected SetVsockConnDialer to take precedence over host mode, got conn=%v err=%v", conn, err)
	}

	SetExecutionMode("vm")
	if IsHostMode() {
		t.Fatal("expected IsHostMode() == false in vm mode")
	}
}
