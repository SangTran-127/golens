package vmexec

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"golens/core/bridge"
)

func waitNoStalls(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for StalledDials() > 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if StalledDials() > 0 {
		t.Fatal("stalled dials never finished")
	}
}

func TestDialWithTimeoutReturnsAfterTimeout(t *testing.T) {
	release := make(chan struct{})
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		<-release
		c, _ := net.Pipe()
		return c, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	start := time.Now()
	_, err := DialWithTimeout(context.Background(), DefaultPort, 100*time.Millisecond)
	if !errors.Is(err, ErrVMUnavailable) || !errors.Is(err, bridge.ErrConnectionTimeout) {
		t.Fatalf("err %v", err)
	}
	if elapsed := time.Since(start); elapsed > 300*time.Millisecond {
		t.Fatalf("took %v", elapsed)
	}
	if StalledDials() != 1 {
		t.Fatalf("stalled %d", StalledDials())
	}
	if _, err := DialWithTimeout(context.Background(), DefaultPort, time.Second); !errors.Is(err, ErrVMUnavailable) {
		t.Fatalf("second dial while stalled: %v", err)
	}
	close(release)
	waitNoStalls(t)
}

func TestDialWithTimeoutCancelDoesNotMarkStall(t *testing.T) {
	release := make(chan struct{})
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		<-release
		return nil, errors.New("late")
	})
	defer bridge.SetVsockConnDialer(nil)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	if _, err := DialWithTimeout(ctx, DefaultPort, time.Second); !errors.Is(err, context.Canceled) {
		t.Fatalf("err %v", err)
	}
	if StalledDials() != 0 {
		t.Fatalf("a cancelled dial must not block other dials, stalled %d", StalledDials())
	}
	close(release)
}

func TestDialWithTimeoutWrapsDialErrors(t *testing.T) {
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		return nil, bridge.ErrVMNotRunning
	})
	defer bridge.SetVsockConnDialer(nil)
	_, err := DialWithTimeout(context.Background(), DefaultPort, time.Second)
	if !errors.Is(err, ErrVMUnavailable) || !errors.Is(err, bridge.ErrVMNotRunning) {
		t.Fatalf("err %v", err)
	}
}

func TestCommandWithoutDialTimeoutKeepsRetry(t *testing.T) {
	attempts := 0
	bridge.SetVsockConnDialer(func(ctx context.Context, port uint32) (net.Conn, error) {
		attempts++
		if attempts < 3 {
			return nil, errors.New("guest agent not listening yet")
		}
		host, guest := net.Pipe()
		go func() {
			defer guest.Close()
			fc := NewFrameConn(guest)
			if _, _, err := fc.ReadFrame(); err != nil {
				return
			}
			go func() {
				for {
					if _, _, err := fc.ReadFrame(); err != nil {
						return
					}
				}
			}()
			_ = fc.WriteFrame(FrameExit, 0, []byte{0, 0, 0, 0})
		}()
		return host, nil
	})
	defer bridge.SetVsockConnDialer(nil)

	cmd := Command("go", "version")
	if err := cmd.Run(); err != nil {
		t.Fatalf("run: %v", err)
	}
	if attempts != 3 {
		t.Fatalf("attempts %d", attempts)
	}
}
