package remote

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golens/core/docker"
)

const dialHelperEnv = "GOLENS_DOCKER_DIAL_HELPER"

func TestMain(m *testing.M) {
	if mode := os.Getenv(dialHelperEnv); mode != "" {
		os.Exit(runDialHelper(mode))
	}
	os.Exit(m.Run())
}

func runDialHelper(mode string) int {
	if f, err := os.OpenFile(os.Getenv("GOLENS_DOCKER_DIAL_LOG"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		fmt.Fprintf(f, "%d %s\n", os.Getpid(), strings.Join(os.Args[1:], " "))
		f.Close()
	}
	switch mode {
	case "hostkey":
		fmt.Fprint(os.Stderr, "Host key verification failed.\r\n")
		return 255
	case "nodocker":
		fmt.Fprint(os.Stderr, "bash: line 1: docker: command not found\n")
		return 127
	case "hang":
		signal.Ignore(syscall.SIGTERM)
		time.Sleep(time.Minute)
		return 0
	}
	conn, err := net.Dial("unix", os.Getenv("GOLENS_DOCKER_DIAL_SOCK"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	go func() {
		io.Copy(conn, os.Stdin)
		conn.(*net.UnixConn).CloseWrite()
	}()
	io.Copy(os.Stdout, conn)
	return 0
}

type dialFixture struct {
	t   *testing.T
	log string
}

func newDialFixture(t *testing.T, mode string) dialFixture {
	dir, err := os.MkdirTemp("/tmp", "gldd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "engine.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /_ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("API-Version", "1.47")
		w.Write([]byte("OK"))
	})
	mux.HandleFunc("GET /v1.47/containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"Id":"abc","Names":["/remote-web"],"State":"running"}]`))
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	f := dialFixture{t: t, log: filepath.Join(dir, "dial.log")}
	t.Setenv(dialHelperEnv, mode)
	t.Setenv("GOLENS_DOCKER_DIAL_SOCK", sock)
	t.Setenv("GOLENS_DOCKER_DIAL_LOG", f.log)
	oldTransport, oldDialer, oldWait := newDockerTransport, docker.SSHDialer, dialExitWait
	newDockerTransport = func(t Target) Transport {
		return Transport{Target: t, SSHPath: os.Args[0], DockerPath: "docker", ControlDir: filepath.Join(dir, "ctl")}
	}
	docker.SSHDialer = DialDockerSSH
	dialExitWait = 300 * time.Millisecond
	dockerTransports.Clear()
	t.Cleanup(func() {
		docker.CloseIdleConnections()
		newDockerTransport, docker.SSHDialer, dialExitWait = oldTransport, oldDialer, oldWait
		dockerTransports.Clear()
	})
	return f
}

func (f dialFixture) runs() (pids []int, args []string) {
	data, _ := os.ReadFile(f.log)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		pid, rest, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		n, _ := strconv.Atoi(pid)
		pids = append(pids, n)
		args = append(args, rest)
	}
	return pids, args
}

func processGone(pid int) bool {
	return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}

func (f dialFixture) waitGone(pids []int) {
	f.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for _, pid := range pids {
		for !processGone(pid) {
			if time.Now().After(deadline) {
				f.t.Fatalf("ssh stand-in %d is still running", pid)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

var remoteEndpoint = docker.Endpoint{Kind: docker.KindSSH, Host: "ssh://tester@fake.invalid:2222", Context: "fake", Source: "test"}

func TestDockerSSHDialListsContainersThroughDialStdio(t *testing.T) {
	f := newDialFixture(t, "proxy")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := docker.Connect(ctx, remoteEndpoint)
	if err != nil {
		t.Fatal(err)
	}
	var list []struct {
		ID string `json:"Id"`
	}
	if err := c.GetJSON(ctx, "/containers/json", nil, &list); err != nil || len(list) != 1 || list[0].ID != "abc" {
		t.Fatalf("containers over dial-stdio = %+v, %v", list, err)
	}
	pids, args := f.runs()
	if len(pids) == 0 {
		t.Fatal("no ssh process ran")
	}
	for _, want := range []string{"-o BatchMode=yes", "-o ControlMaster=auto", "-o ControlPersist=600", "-p 2222", "-T -- tester@fake.invalid docker system dial-stdio"} {
		if !strings.Contains(args[0], want) {
			t.Fatalf("ssh args %q lack %q", args[0], want)
		}
	}
	docker.CloseIdleConnections()
	f.waitGone(pids)
}

func TestDockerSSHConnCloseEndsTheProcess(t *testing.T) {
	f := newDialFixture(t, "proxy")
	conn, err := DialDockerSSH(context.Background(), remoteEndpoint.Host)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte("GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n")); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil || resp.Header.Get("API-Version") != "1.47" {
		t.Fatalf("ping over the raw connection = %v, %v", resp, err)
	}
	pid := conn.(*dialConn).cmd.Process.Pid
	if processGone(pid) {
		t.Fatal("the process should run while the connection is open")
	}
	conn.Close()
	if !processGone(pid) {
		t.Fatal("Close must not return before the process is gone")
	}
	pids, _ := f.runs()
	f.waitGone(pids)
}

func TestDockerSSHCloseKillsAProcessThatIgnoresTerm(t *testing.T) {
	f := newDialFixture(t, "hang")
	conn, err := DialDockerSSH(context.Background(), remoteEndpoint.Host)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for pids, _ := f.runs(); len(pids) == 0; pids, _ = f.runs() {
		if time.Now().After(deadline) {
			t.Fatal("stand-in never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	pid := conn.(*dialConn).cmd.Process.Pid
	start := time.Now()
	conn.Close()
	if !processGone(pid) || time.Since(start) > 2*time.Second {
		t.Fatalf("hung process gone=%v after %v", processGone(pid), time.Since(start))
	}
}

func TestDockerSSHFailuresBecomeIssues(t *testing.T) {
	cases := []struct {
		mode, code, fix, command, title string
	}{
		{"hostkey", CodeHostKeyUnknown, FixOpenTerminal, "ssh -p 2222 tester@fake.invalid exit", "Unknown Host Key"},
		{"nodocker", CodeDockerMissing, FixRetry, "", "Docker Isn’t Installed on tester@fake.invalid:2222"},
	}
	for _, tc := range cases {
		t.Run(tc.mode, func(t *testing.T) {
			f := newDialFixture(t, tc.mode)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_, err := docker.Connect(ctx, remoteEndpoint)
			var ee *docker.EngineError
			if !errors.As(err, &ee) || ee.Issue == nil {
				t.Fatalf("error = %#v", err)
			}
			i := ee.Issue
			if i.Code != tc.code || i.Fix != tc.fix || i.Command != tc.command || i.Title != tc.title || i.Message == "" || ee.Message != i.Message {
				t.Fatalf("issue = %+v", i)
			}
			if tc.mode == "nodocker" && !strings.Contains(i.Message, "Install Docker on tester@fake.invalid:2222") {
				t.Fatalf("message should suggest installing Docker there: %s", i.Message)
			}
			pids, _ := f.runs()
			f.waitGone(pids)
		})
	}
}

func TestDockerSSHTargetParsing(t *testing.T) {
	good := map[string]Target{
		"ssh://vps":                {Kind: KindSSH, Host: "vps"},
		"ssh://deploy@vps.example": {Kind: KindSSH, Host: "deploy@vps.example"},
		"ssh://root@10.0.0.2:2200": {Kind: KindSSH, Host: "root@10.0.0.2", Port: 2200},
		"ssh://me@[::1]:22/":       {Kind: KindSSH, Host: "me@::1", Port: 22},
	}
	for in, want := range good {
		if got, err := dockerSSHTarget(in); err != nil || got != want {
			t.Errorf("dockerSSHTarget(%q) = %+v, %v", in, got, err)
		}
	}
	for _, in := range []string{"ssh://", "tcp://vps", "ssh://me:pw@vps", "ssh://vps/var/run", "ssh://-oProxyCommand=x", "ssh://vps?x=1"} {
		if _, err := dockerSSHTarget(in); err == nil {
			t.Errorf("dockerSSHTarget(%q) should fail", in)
		}
	}
}
