package database

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("GOLENS_FAKE_SSH") == "1" {
		fakeSSHMain(os.Args[1:])
		return
	}
	os.Exit(m.Run())
}

func fakeSSHMain(args []string) {
	if log := os.Getenv("FAKE_SSH_LOG"); log != "" {
		f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintln(f, strings.Join(args, " "))
			f.Close()
		}
	}
	var spec string
	for i, a := range args {
		if a == "-L" && i+1 < len(args) {
			spec = args[i+1]
		}
	}
	parts := strings.Split(spec, ":")
	if len(parts) != 4 {
		fmt.Fprintln(os.Stderr, "Bad local forwarding specification")
		os.Exit(255)
	}
	listen := parts[0] + ":" + parts[1]
	target := net.JoinHostPort(parts[2], parts[3])
	mode := os.Getenv("FAKE_SSH_MODE")
	if mode == "busy-once" {
		b, _ := os.ReadFile(os.Getenv("FAKE_SSH_LOG"))
		if strings.Count(string(b), "\n") <= 1 {
			mode = "busy"
		}
	}
	switch mode {
	case "busy":
		fmt.Fprintf(os.Stderr, "bind [%s]: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: %s\nCould not request local forwarding.\n", listen, parts[1])
		os.Exit(255)
	case "hostkey":
		fmt.Fprintln(os.Stderr, "Host key verification failed.")
		os.Exit(255)
	case "auth":
		fmt.Fprintln(os.Stderr, "me@bastion: Permission denied (publickey).")
		os.Exit(255)
	case "hang":
		time.Sleep(time.Hour)
		os.Exit(0)
	}
	l, err := net.Listen("tcp", listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "bind [%s]: Address already in use\n", listen)
		os.Exit(255)
	}
	if mode == "crash" {
		go func() {
			time.Sleep(300 * time.Millisecond)
			os.Exit(255)
		}()
	}
	for {
		c, err := l.Accept()
		if err != nil {
			os.Exit(0)
		}
		go func(c net.Conn) {
			defer c.Close()
			up, err := net.Dial("tcp", target)
			if err != nil {
				return
			}
			defer up.Close()
			go func() { _, _ = io.Copy(up, c) }()
			_, _ = io.Copy(c, up)
		}(c)
	}
}

type fakeSSH struct {
	log string
}

func useFakeSSH(t *testing.T, mode string) *fakeSSH {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "ssh")
	body := fmt.Sprintf("#!/bin/sh\nGOLENS_FAKE_SSH=1 exec %q \"$@\"\n", exe)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	f := &fakeSSH{log: filepath.Join(dir, "calls.log")}
	t.Setenv("FAKE_SSH_MODE", mode)
	t.Setenv("FAKE_SSH_LOG", f.log)
	prevPath, prevStart := sshPath, tunnelStartTimeout
	sshPath = script
	t.Cleanup(func() {
		StopAllTunnels()
		sshPath, tunnelStartTimeout = prevPath, prevStart
	})
	return f
}

func (f *fakeSSH) calls(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile(f.log)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func echoServer(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

func tunnelDef(id string, port int) Definition {
	return Definition{ID: id, Name: id, Engine: EnginePostgres, Host: "127.0.0.1", Port: port, User: "u", Password: "none",
		SSH: SSH{Destination: "me@bastion", Port: 2222}}
}

func processGone(pid int) bool { return processGoneWithin(pid, 5*time.Second) }

func processGoneWithin(pid int, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func requireEcho(t *testing.T, port int) {
	t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("echo through the tunnel = %q, %v", buf, err)
	}
}

func TestTunnelStartsSharesAndStopsWithLastConnection(t *testing.T) {
	fake := useFakeSSH(t, "ok")
	def := tunnelDef("ds-tunnel", echoServer(t))
	first, err := tunnels.acquire(t.Context(), def)
	if err != nil {
		t.Fatal(err)
	}
	requireEcho(t, first.port)
	second, err := tunnels.acquire(t.Context(), def)
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatal("a second connection to the same data source started another tunnel")
	}
	calls := fake.calls(t)
	if len(calls) != 1 {
		t.Fatalf("ssh ran %d times, want 1", len(calls))
	}
	want := fmt.Sprintf("-N -L 127.0.0.1:%d:127.0.0.1:%d -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -p 2222 me@bastion", first.port, def.Port)
	if calls[0] != want {
		t.Fatalf("ssh arguments\n got %s\nwant %s", calls[0], want)
	}
	stats := GetStats()
	if len(stats.Tunnels) != 1 || stats.Tunnels[0].PID != first.pid || stats.Tunnels[0].DataSourceID != "ds-tunnel" || stats.Tunnels[0].LocalPort != first.port {
		t.Fatalf("stats tunnels = %+v, pid %d", stats.Tunnels, first.pid)
	}
	pid := first.pid
	tunnels.release(first)
	if processGoneWithin(pid, 300*time.Millisecond) {
		t.Fatal("the tunnel stopped while a connection still used it")
	}
	tunnels.release(second)
	if !processGone(pid) {
		t.Fatalf("ssh %d still runs after the last connection closed", pid)
	}
	if n := len(GetStats().Tunnels); n != 0 {
		t.Fatalf("stats still list %d tunnels", n)
	}
}

func TestTunnelRetriesWhenTheLocalPortIsTaken(t *testing.T) {
	fake := useFakeSSH(t, "busy-once")
	tun, err := tunnels.acquire(t.Context(), tunnelDef("ds-retry", echoServer(t)))
	if err != nil {
		t.Fatal(err)
	}
	defer tunnels.release(tun)
	if n := len(fake.calls(t)); n != 2 {
		t.Fatalf("ssh ran %d times, want 2", n)
	}
	requireEcho(t, tun.port)
}

func TestTunnelForwardFailureGivesUpAfterThreeTries(t *testing.T) {
	fake := useFakeSSH(t, "busy")
	_, err := tunnels.acquire(t.Context(), tunnelDef("ds-busy", echoServer(t)))
	if err == nil || !strings.Contains(err.Error(), "could not open the local port") {
		t.Fatalf("err = %v", err)
	}
	if n := len(fake.calls(t)); n != tunnelAttempts {
		t.Fatalf("ssh ran %d times, want %d", n, tunnelAttempts)
	}
}

func TestTunnelExplainsSSHFailures(t *testing.T) {
	cases := map[string]string{
		"hostkey": "Connect once with “ssh me@bastion” in Terminal",
		"auth":    "doesn’t support SSH passwords",
	}
	for mode, want := range cases {
		t.Run(mode, func(t *testing.T) {
			useFakeSSH(t, mode)
			ds := &dataSource{id: "ds-" + mode, def: tunnelDef("ds-"+mode, echoServer(t))}
			_, err := dial(t.Context(), dialOptions{def: ds.def})
			if err == nil {
				t.Fatal("dial succeeded")
			}
			e := ds.connectError(err)
			if e.Kind != "connect" || !strings.Contains(e.Message, want) {
				t.Fatalf("error = %+v", e)
			}
		})
	}
}

func TestTunnelStartTimesOut(t *testing.T) {
	useFakeSSH(t, "hang")
	tunnelStartTimeout = 500 * time.Millisecond
	start := time.Now()
	_, err := tunnels.acquire(t.Context(), tunnelDef("ds-hang", echoServer(t)))
	if err == nil || !strings.Contains(err.Error(), "didn’t open the tunnel") {
		t.Fatalf("err = %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("timeout took %v", time.Since(start))
	}
	if n := len(GetStats().Tunnels); n != 0 {
		t.Fatalf("a timed out tunnel is still listed: %d", n)
	}
}

func TestTunnelRestartsAfterSSHExits(t *testing.T) {
	useFakeSSH(t, "crash")
	def := tunnelDef("ds-crash", echoServer(t))
	first, err := tunnels.acquire(t.Context(), def)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-first.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the fake ssh did not exit")
	}
	if first.alive() {
		t.Fatal("an exited tunnel reports alive")
	}
	second, err := tunnels.acquire(t.Context(), def)
	if err != nil {
		t.Fatal(err)
	}
	if second == first || second.pid == first.pid {
		t.Fatal("no new ssh started after the first one exited")
	}
	tunnels.release(first)
	tunnels.release(second)
}

func TestTunnelStoppedOnDisconnectAndShutdown(t *testing.T) {
	useFakeSSH(t, "ok")
	root := t.TempDir()
	port := echoServer(t)
	a, b := tunnelDef("ds-a", port), tunnelDef("ds-b", port)
	file := fmt.Sprintf(`{"version":1,"dataSources":[%s,%s]}`, mustJSON(t, a), mustJSON(t, b))
	if res := Configure(root, file); len(res.Issues) != 0 {
		t.Fatalf("issues = %+v", res.Issues)
	}
	ta, err := tunnels.acquire(t.Context(), a)
	if err != nil {
		t.Fatal(err)
	}
	tb, err := tunnels.acquire(t.Context(), b)
	if err != nil {
		t.Fatal(err)
	}
	Disconnect("ds-a")
	if !processGone(ta.pid) {
		t.Fatal("Disconnect left the tunnel running")
	}
	if processGoneWithin(tb.pid, 300*time.Millisecond) {
		t.Fatal("Disconnect stopped another data source's tunnel")
	}
	ShutdownWorkspace(root)
	if !processGone(tb.pid) {
		t.Fatal("ShutdownWorkspace left a tunnel running")
	}
	tunnels.release(ta)
	tunnels.release(tb)
	if n := len(GetStats().Tunnels); n != 0 {
		t.Fatalf("stats still list %d tunnels", n)
	}
}

func TestTunnelExitsWhenGoLensGoesAway(t *testing.T) {
	useFakeSSH(t, "ok")
	tun, err := tunnels.acquire(t.Context(), tunnelDef("ds-orphan", echoServer(t)))
	if err != nil {
		t.Fatal(err)
	}
	_ = tun.stdin.Close()
	if !processGone(tun.pid) {
		t.Fatal("ssh outlived the pipe that ties it to GoLens")
	}
	tunnels.release(tun)
}

func TestValidateSSH(t *testing.T) {
	base := tunnelDef("ds-v", 5432)
	cases := []struct {
		mutate func(*Definition)
		field  string
	}{
		{func(d *Definition) {}, ""},
		{func(d *Definition) { d.SSH = SSH{Destination: "bastion-alias"} }, ""},
		{func(d *Definition) { d.SSH = SSH{Destination: "-oProxyCommand=evil"} }, "ssh.destination"},
		{func(d *Definition) { d.SSH = SSH{Destination: "me@host name"} }, "ssh.destination"},
		{func(d *Definition) { d.SSH = SSH{Port: 22} }, "ssh.destination"},
		{func(d *Definition) { d.SSH.Port = 70000 }, "ssh.port"},
		{func(d *Definition) { d.Engine, d.SQLitePath = EngineSQLite, "a.db" }, "ssh.destination"},
	}
	for i, c := range cases {
		d := base
		c.mutate(&d)
		issues := validate([]Definition{d})
		if c.field == "" && len(issues) != 0 {
			t.Errorf("case %d: unexpected issues %+v", i, issues)
		}
		if c.field != "" && (len(issues) != 1 || issues[0].Field != c.field) {
			t.Errorf("case %d: issues %+v, want field %s", i, issues, c.field)
		}
	}
}

func TestForwardSpecBracketsIPv6(t *testing.T) {
	if got := forwardSpec(5000, "::1", 5432); got != "127.0.0.1:5000:[::1]:5432" {
		t.Fatal(got)
	}
	if got := forwardSpec(5000, "db.internal", 3306); got != "127.0.0.1:5000:db.internal:3306" {
		t.Fatal(got)
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
