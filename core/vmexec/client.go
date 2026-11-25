package vmexec

import (
	"context"
	"time"

	"golens/core/bridge"
)

func Ping(ctx context.Context, port uint32) error {
	_, err := PingFlags(ctx, port)
	return err
}

func PingFlags(ctx context.Context, port uint32) (uint16, error) {
	conn, err := bridge.DialSandboxVsock(ctx, port)
	if err != nil {
		return 0, err
	}
	defer conn.Close()

	fc := NewFrameConn(conn)
	if err := fc.WriteFrame(FramePing, 0, nil); err != nil {
		return 0, err
	}

	header, _, err := fc.ReadFrame()
	if err != nil {
		return 0, err
	}
	if header.Type != FramePong {
		return 0, ErrUnexpectedFrame
	}
	return header.Flags, nil
}

var ErrUnexpectedFrame = &ExitError{code: -1, msg: "unexpected frame received"}

func CheckGuestAgent(ctx context.Context, port uint32, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	conn, err := bridge.DialSandboxVsockWithRetry(ctx, port, timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
