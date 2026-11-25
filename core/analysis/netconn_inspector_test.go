package analysis

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSocketSafetyInspectorDetectsAndFixesAllCategories(t *testing.T) {
	src := `package networker

import (
	"net"
)

func connectAndRead(addr string) error {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	buf := make([]byte, 1024)
	_, err = conn.Read(buf)
	return err
}

func serveLoop(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		_ = conn.Close()
	}
}
`
	reqBytes, _ := json.Marshal(SocketSafetyInspectRequest{
		Content:  src,
		FilePath: "socket.go",
	})
	raw := InspectSocketSafety(string(reqBytes))
	var res SocketSafetyInspectResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal inspect result: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("unexpected inspect error: %s", res.Error)
	}
	if res.NetDialWithoutTimeoutCount != 1 {
		t.Fatalf("expected 1 net_dial_without_timeout, got %d", res.NetDialWithoutTimeoutCount)
	}
	if res.ConnReadWriteWithoutDeadlineCount != 1 {
		t.Fatalf("expected 1 conn_read_write_without_deadline, got %d", res.ConnReadWriteWithoutDeadlineCount)
	}
	if res.ListenerAcceptLoopWithoutBackoffCount != 1 {
		t.Fatalf("expected 1 listener_accept_loop_without_backoff_or_close, got %d", res.ListenerAcceptLoopWithoutBackoffCount)
	}

	fixReqBytes, _ := json.Marshal(SocketSafetyFixRequest{
		Content:  src,
		FilePath: "socket.go",
		All:      true,
	})
	fixRaw := ApplySocketSafetyFixes(string(fixReqBytes))
	var fixRes SocketSafetyFixResult
	if err := json.Unmarshal([]byte(fixRaw), &fixRes); err != nil {
		t.Fatalf("unmarshal fix result: %v", err)
	}
	if fixRes.Error != "" {
		t.Fatalf("unexpected fix error: %s", fixRes.Error)
	}
	if fixRes.FixedCount != 3 {
		t.Fatalf("expected 3 fixed issues, got %d", fixRes.FixedCount)
	}
	if !strings.Contains(fixRes.NewContent, `net.DialTimeout("tcp", addr, 10*time.Second)`) {
		t.Fatalf("expected DialTimeout replacement, got:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, `_ = conn.SetDeadline(time.Now().Add(30 * time.Second))`) {
		t.Fatalf("expected SetDeadline insertion, got:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, `time.Sleep(50 * time.Millisecond)`) {
		t.Fatalf("expected Sleep backoff insertion, got:\n%s", fixRes.NewContent)
	}

	recheckBytes, _ := json.Marshal(SocketSafetyInspectRequest{
		Content:  fixRes.NewContent,
		FilePath: "socket.go",
	})
	var recheck SocketSafetyInspectResult
	_ = json.Unmarshal([]byte(InspectSocketSafety(string(recheckBytes))), &recheck)
	if len(recheck.Issues) != 0 {
		t.Fatalf("expected 0 issues after Fix All, got %d: %+v", len(recheck.Issues), recheck.Issues)
	}
}
