//go:build linux

package kerneltelemetry

import (
	"net"
	"os"
	"testing"
	"time"
)

func TestCollectSeesThisProcessListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	report, err := Collect("/proc", os.Getpid(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if report.PID != int32(os.Getpid()) || report.TargetName == "" {
		t.Errorf("report identity = %d %q", report.PID, report.TargetName)
	}
	if report.OpenFDs.Count == 0 || report.OpenFDs.Count != len(report.OpenFDs.Entries) || report.OpenFDs.Limit <= 0 {
		t.Errorf("open fds = count %d, entries %d, limit %d", report.OpenFDs.Count, len(report.OpenFDs.Entries), report.OpenFDs.Limit)
	}
	found := false
	for _, s := range report.TCPSockets {
		if s.LocalPort == port && s.State == "LISTEN" {
			found = true
		}
	}
	if !found {
		t.Errorf("listener on port %d missing from %+v", port, report.TCPSockets)
	}
}
