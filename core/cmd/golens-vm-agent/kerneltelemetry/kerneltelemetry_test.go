package kerneltelemetry

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseHexIPv4(t *testing.T) {
	valid := map[string]string{
		"0100007F": "127.0.0.1",
		"00000000": "0.0.0.0",
		"FFFFFFFF": "255.255.255.255",
		"0501A8C0": "192.168.1.5",
		"0A00000A": "10.0.0.10",
		"FE0110AC": "172.16.1.254",
		"0100a8c0": "192.168.0.1",
	}
	for hex, want := range valid {
		got, err := ParseHexIPv4(hex)
		if err != nil || got != want {
			t.Errorf("ParseHexIPv4(%q) = %q, %v; want %q", hex, got, err, want)
		}
	}
	for _, hex := range []string{"", "010000", "0100007F0", "GGGGGGGG", "01 00 7F", "0000000000000000000000000100007F"} {
		if got, err := ParseHexIPv4(hex); err == nil {
			t.Errorf("ParseHexIPv4(%q) = %q, want an error", hex, got)
		}
	}
}

func TestParseHexIPv6(t *testing.T) {
	valid := map[string]string{
		"00000000000000000000000000000000": "::",
		"00000000000000000000000001000000": "::1",
		"0000000000000000FFFF00000100007F": "127.0.0.1",
		"B80D0120000000000000000001000000": "2001:db8::1",
	}
	for hex, want := range valid {
		got, err := ParseHexIPv6(hex)
		if err != nil || got != want {
			t.Errorf("ParseHexIPv6(%q) = %q, %v; want %q", hex, got, err, want)
		}
	}
	for _, hex := range []string{"", "0100007F", "ZZ000000000000000000000001000000"} {
		if got, err := ParseHexIPv6(hex); err == nil {
			t.Errorf("ParseHexIPv6(%q) = %q, want an error", hex, got)
		}
	}
}

func TestParseHexPort(t *testing.T) {
	valid := map[string]int{"0000": 0, "0050": 80, "01BB": 443, "1F90": 8080, "1f90": 8080, "FFFF": 65535}
	for hex, want := range valid {
		got, err := ParseHexPort(hex)
		if err != nil || got != want {
			t.Errorf("ParseHexPort(%q) = %d, %v; want %d", hex, got, err, want)
		}
	}
	for _, hex := range []string{"", "10000", "ZZZZ", "-1", " 80 "} {
		if _, err := ParseHexPort(hex); err == nil {
			t.Errorf("ParseHexPort(%q) succeeded, want an error", hex)
		}
	}
}

func TestMapTCPState(t *testing.T) {
	cases := map[string]string{
		"01": "ESTABLISHED", "02": "SYN_SENT", "03": "SYN_RECV", "04": "FIN_WAIT1",
		"05": "FIN_WAIT2", "06": "TIME_WAIT", "07": "CLOSE", "08": "CLOSE_WAIT",
		"09": "LAST_ACK", "0A": "LISTEN", "0a": "LISTEN", "0B": "CLOSING",
		"00": "UNKNOWN", "FF": "UNKNOWN", "": "UNKNOWN",
	}
	for code, want := range cases {
		if got := MapTCPState(code); got != want {
			t.Errorf("MapTCPState(%q) = %q, want %q", code, got, want)
		}
	}
}

func TestParsePSIString(t *testing.T) {
	some, full, err := ParsePSIString("some avg10=1.25 avg60=0.50 avg300=0.10 total=12345\nfull avg10=0.20 avg60=0.05 avg300=0.01 total=456\n")
	if err != nil {
		t.Fatal(err)
	}
	if some == nil || *some != (PSIValues{1.25, 0.50, 0.10, 12345}) {
		t.Errorf("some = %+v", some)
	}
	if full == nil || *full != (PSIValues{0.20, 0.05, 0.01, 456}) {
		t.Errorf("full = %+v", full)
	}

	some, full, err = ParsePSIString("some total=18446744073709551615 avg300=3.0 avg10=1e-4 avg60=2.0 avg10=9.0")
	if err != nil || full != nil || some == nil || *some != (PSIValues{9.0, 2.0, 3.0, 18446744073709551615}) {
		t.Errorf("reordered keys: some = %+v, full = %+v, err = %v", some, full, err)
	}

	for _, input := range []string{"", "\n\n  \n", "random text", "some avg10", "some avg10=", "full avg60=notafloat"} {
		some, full, err := ParsePSIString(input)
		if err != nil || some != nil || full != nil {
			t.Errorf("ParsePSIString(%q) = %+v, %+v, %v; want nothing", input, some, full, err)
		}
	}
}

const tcpHeader = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

func TestParseTCPTable(t *testing.T) {
	table := tcpHeader + `   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 18374 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 0100007F:C822 01 00000100:00000200 00:00000000 00000000  1000        0 18379 1 0000000000000000 100 0 0 10 0
   2: 0501A8C0:0050 0100007F:1234 06 00000000:00000000 00:00000000 00000000  1000        0 99999 1 0000000000000000 100 0 0 10 0
`
	all, err := ParseTCPTable(strings.NewReader(table), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatalf("got %d sockets, want 3", len(all))
	}
	if s := all[0]; s.LocalAddress != "127.0.0.1" || s.LocalPort != 8080 || s.State != "LISTEN" || s.Inode != 18374 {
		t.Errorf("socket 0 = %+v", s)
	}
	if s := all[1]; s.RemoteAddress != "127.0.0.1" || s.RemotePort != 51234 || s.State != "ESTABLISHED" || s.TxQueue != 0x100 || s.RxQueue != 0x200 {
		t.Errorf("socket 1 = %+v", s)
	}

	filtered, _ := ParseTCPTable(strings.NewReader(table), map[uint64]bool{18374: true})
	if len(filtered) != 1 || filtered[0].Inode != 18374 {
		t.Errorf("filtered = %+v", filtered)
	}
	none, _ := ParseTCPTable(strings.NewReader(table), map[uint64]bool{})
	if none == nil || len(none) != 0 {
		t.Errorf("a process without sockets got %+v, want an empty list", none)
	}
}

func TestParseTCP6Table(t *testing.T) {
	table := tcpHeader + `   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5150 1 0000000000000000 100 0 0 10 0
   1: 0000000000000000FFFF00000100007F:1F90 0000000000000000FFFF00000100007F:D431 01 00000000:00000000 00:00000000 00000000     0        0 5151 1 0000000000000000 20 4 30 10 -1
`
	sockets, err := ParseTCPTable(strings.NewReader(table), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(sockets) != 2 {
		t.Fatalf("got %d sockets, want 2", len(sockets))
	}
	if s := sockets[0]; s.LocalAddress != "::" || s.LocalPort != 8080 || s.State != "LISTEN" {
		t.Errorf("listener = %+v", s)
	}
	if s := sockets[1]; s.LocalAddress != "127.0.0.1" || s.RemotePort != 54321 || s.State != "ESTABLISHED" {
		t.Errorf("mapped connection = %+v", s)
	}
}

func TestParseTCPTableSkipsMalformedRows(t *testing.T) {
	table := tcpHeader + `   0: corrupted_row_too_short
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 18374 1 0000000000000000 100 0 0 10 0
   2: missing_colon_in_addr 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 18375 1
   3: GGGGGGGG:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 18376 1
   4: 0100007F:ZZZZ 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 18377 1
   5: 0100007F:1F90 INVALIDHEX:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 18378 1
   6: 0100007F:1F90 00000000:YYYY 0A 00000000:00000000 00:00000000 00000000 1000 0 18379 1
   7: 0501A8C0:0050 0100007F:1234 06 bad_queue_format 00:00000000 00000000 1000 0 18382 1 0000000000000000 100 0 0 10 0
`
	sockets, err := ParseTCPTable(strings.NewReader(table), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(sockets) != 2 || sockets[0].Inode != 18374 || sockets[1].Inode != 18382 || sockets[1].TxQueue != 0 {
		t.Fatalf("sockets = %+v", sockets)
	}
	for _, input := range []string{"", tcpHeader} {
		if got, err := ParseTCPTable(strings.NewReader(input), nil); err != nil || len(got) != 0 {
			t.Errorf("ParseTCPTable(%q) = %+v, %v", input, got, err)
		}
	}
}

func TestClassifyFDKind(t *testing.T) {
	cases := map[string]string{
		"socket:[12345]":                  "socket",
		"pipe:[99999]":                    "pipe",
		"/dev/null":                       "character",
		"/dev/pts/1":                      "character",
		"anon_inode:[eventpoll]":          "anonInode",
		"anon_inode:[timerfd]":            "anonInode",
		"/workspaces/app/main.go":         "file",
		"/tmp/test (deleted)":             "file",
		"":                                "other",
		"memfd:test (deleted)":            "other",
		"socket:invalid_without_brackets": "other",
	}
	for target, want := range cases {
		if got := ClassifyFDKind(target); got != want {
			t.Errorf("ClassifyFDKind(%q) = %q, want %q", target, got, want)
		}
	}
}

func makeProcess(t *testing.T, root string, pid, ppid int, comm string, start int, fds map[string]string) {
	t.Helper()
	dir := filepath.Join(root, strconv.Itoa(pid))
	writeFile(t, filepath.Join(dir, "stat"), strconv.Itoa(pid)+" ("+comm+") S "+strconv.Itoa(ppid)+" 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 "+strconv.Itoa(start)+" 0 0")
	if err := os.MkdirAll(filepath.Join(dir, "fd"), 0o755); err != nil {
		t.Fatal(err)
	}
	for fd, target := range fds {
		if err := os.Symlink(target, filepath.Join(dir, "fd", fd)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestParseFDDirectory(t *testing.T) {
	root := t.TempDir()
	makeProcess(t, root, 10, 1, "app", 5, map[string]string{
		"0": "socket:[44556]",
		"1": "/dev/null",
		"2": "pipe:[11223]",
		"3": "/nonexistent/broken/symlink",
		"4": "anon_inode:[eventpoll]",
	})
	writeFile(t, filepath.Join(root, "10", "fd", "not_an_fd"), "garbage")
	writeFile(t, filepath.Join(root, "10", "limits"), "Limit                     Soft Limit           Hard Limit           Units\nMax processes             62843                62843                processes\nMax open files            4096                 524288               files\n")

	fds, inodes, err := ParseFDDirectory(filepath.Join(root, "10", "fd"))
	if err != nil {
		t.Fatal(err)
	}
	if fds.Count != 5 || len(fds.Entries) != 5 || fds.Limit != 4096 {
		t.Fatalf("fds = %+v", fds)
	}
	if !inodes[44556] || len(inodes) != 1 {
		t.Errorf("socket inodes = %v", inodes)
	}
	for _, entry := range fds.Entries {
		if entry.FD == 3 && entry.Kind != "file" {
			t.Errorf("broken symlink kind = %q, want file", entry.Kind)
		}
	}

	missing, _, err := ParseFDDirectory(filepath.Join(root, "999", "fd"))
	if err == nil || missing.Entries == nil {
		t.Errorf("missing directory = %+v, %v; want an error and an empty list", missing, err)
	}
}

func TestResolveTargetFollowsTheGoToolToTheProgram(t *testing.T) {
	root := t.TempDir()
	makeProcess(t, root, 100, 1, "go", 10, nil)
	makeProcess(t, root, 101, 100, "compile", 11, nil)
	makeProcess(t, root, 105, 100, "server", 20, nil)
	makeProcess(t, root, 106, 105, "sh", 30, nil)
	makeProcess(t, root, 200, 1, "other", 40, nil)

	if pid, name := ResolveTarget(root, 100); pid != 105 || name != "server" {
		t.Errorf("go run resolved to %d %q, want 105 server", pid, name)
	}
	if pid, name := ResolveTarget(root, 105); pid != 105 || name != "server" {
		t.Errorf("a direct program resolved to %d %q, want itself", pid, name)
	}
	makeProcess(t, root, 300, 1, "go", 50, nil)
	if pid, name := ResolveTarget(root, 300); pid != 300 || name != "go" {
		t.Errorf("a go tool without children resolved to %d %q, want itself", pid, name)
	}
	makeProcess(t, root, 301, 300, "compile", 51, nil)
	makeProcess(t, root, 302, 300, "link", 52, nil)
	if pid, name := ResolveTarget(root, 300); pid != 300 || name != "go" {
		t.Errorf("a go tool that is still building resolved to %d %q, want the go tool", pid, name)
	}
	makeProcess(t, root, 303, 300, "kerneldemo", 53, nil)
	if pid, name := ResolveTarget(root, 300); pid != 303 || name != "kerneldemo" {
		t.Errorf("a go tool that started the program resolved to %d %q, want 303 kerneldemo", pid, name)
	}
}

func TestCollectReadsFDsSocketsAndPressure(t *testing.T) {
	root := t.TempDir()
	makeProcess(t, root, 100, 1, "go", 10, nil)
	makeProcess(t, root, 105, 100, "my server", 20, map[string]string{
		"3": "/srv/data.db",
		"4": "socket:[5150]",
		"5": "socket:[18374]",
	})
	writeFile(t, filepath.Join(root, "105", "net", "tcp"), tcpHeader+
		"   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 18374 1 0000000000000000 100 0 0 10 0\n"+
		"   1: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777 1 0000000000000000 100 0 0 10 0\n")
	writeFile(t, filepath.Join(root, "105", "net", "tcp6"), tcpHeader+
		"   0: 00000000000000000000000000000000:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5150 1 0000000000000000 100 0 0 10 0\n")
	writeFile(t, filepath.Join(root, "pressure", "memory"), "some avg10=1.00 avg60=0.50 avg300=0.25 total=100\nfull avg10=0.10 avg60=0.05 avg300=0.02 total=10\n")
	writeFile(t, filepath.Join(root, "pressure", "cpu"), "some avg10=3.00 avg60=2.00 avg300=1.00 total=300\n")

	report, err := Collect(root, 100, time.Date(2026, 11, 17, 8, 0, 0, 500, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if report.PID != 105 || report.TargetName != "my server" || report.Timestamp != "2026-11-17T08:00:00Z" {
		t.Errorf("report identity = %d %q %q", report.PID, report.TargetName, report.Timestamp)
	}
	if report.OpenFDs.Count != 3 || report.OpenFDs.Limit != defaultFDLimit {
		t.Errorf("open fds = %+v", report.OpenFDs)
	}
	if len(report.TCPSockets) != 2 || report.TCPSockets[0].LocalPort != 8080 || report.TCPSockets[1].LocalAddress != "::" {
		t.Errorf("sockets = %+v", report.TCPSockets)
	}
	if report.PSI == nil {
		t.Fatal("pressure files present but the report has no psi")
	}
	if report.PSI.Memory.SomePressure.Avg10 != 1 || report.PSI.Memory.FullPressure == nil || report.PSI.CPU.SomePressure.TotalMicros != 300 || report.PSI.CPU.FullPressure != nil {
		t.Errorf("psi = %+v", report.PSI)
	}
	if report.PSI.IO.SomePressure != (PSIValues{}) || report.PSI.IO.FullPressure != nil {
		t.Errorf("missing io pressure = %+v", report.PSI.IO)
	}

	if _, err := Collect(root, 999, time.Now()); err == nil {
		t.Error("collecting a process that is gone succeeded")
	}
}

func TestCollectOmitsPressureWhenTheKernelHasNone(t *testing.T) {
	root := t.TempDir()
	makeProcess(t, root, 7, 1, "idle", 5, nil)
	report, err := Collect(root, 7, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if report.PSI != nil {
		t.Errorf("psi = %+v, want none when /proc/pressure is missing", report.PSI)
	}
}
