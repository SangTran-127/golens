package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	protocolVersion uint8  = 0x01
	frameExecInit   uint8  = 0x01
	frameStdout     uint8  = 0x04
	frameStderr     uint8  = 0x05
	frameExit       uint8  = 0x06
	headerSize      int    = 8
)

type execInit struct {
	Argv []string `json:"argv"`
	Env  []string `json:"env"`
	Cwd  string   `json:"cwd"`
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "Usage: vsock-bridge <socket_path> <host_workspace_dir>\n")
		os.Exit(1)
	}

	sockPath := os.Args[1]
	hostRoot, err := filepath.Abs(os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "bad host root: %v\n", err)
		os.Exit(1)
	}

	_ = os.Remove(sockPath)
	_ = os.MkdirAll(filepath.Dir(sockPath), 0o755)

	l, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to listen on %s: %v\n", sockPath, err)
		os.Exit(1)
	}
	defer l.Close()
	defer os.Remove(sockPath)

	for {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		go handleConn(conn, hostRoot)
	}
}

func handleConn(conn net.Conn, hostRoot string) {
	defer conn.Close()

	// Read FrameExecInit
	var hbuf [headerSize]byte
	if _, err := io.ReadFull(conn, hbuf[:]); err != nil {
		return
	}
	if hbuf[0] != protocolVersion || hbuf[1] != frameExecInit {
		return
	}
	length := binary.BigEndian.Uint32(hbuf[4:8])
	payload := make([]byte, length)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return
	}

	var init execInit
	if err := json.Unmarshal(payload, &init); err != nil {
		return
	}

	// Translate guest paths to host paths
	cwd := hostRoot
	if strings.HasPrefix(init.Cwd, "/workspaces/") {
		parts := strings.SplitN(strings.TrimPrefix(init.Cwd, "/workspaces/"), "/", 2)
		if len(parts) == 2 {
			cwd = filepath.Join(hostRoot, parts[1])
		}
	} else if init.Cwd != "" && init.Cwd != "." {
		cwd = init.Cwd
	}

	argv := make([]string, len(init.Argv))
	for i, arg := range init.Argv {
		if strings.HasPrefix(arg, "/workspaces/") {
			parts := strings.SplitN(strings.TrimPrefix(arg, "/workspaces/"), "/", 2)
			if len(parts) == 2 {
				argv[i] = filepath.Join(hostRoot, parts[1])
			} else {
				argv[i] = hostRoot
			}
		} else if strings.Contains(arg, "=/workspaces/") {
			eqIdx := strings.Index(arg, "=/workspaces/")
			prefix := arg[:eqIdx+1]
			guestPath := arg[eqIdx+1:]
			parts := strings.SplitN(strings.TrimPrefix(guestPath, "/workspaces/"), "/", 2)
			if len(parts) == 2 {
				argv[i] = prefix + filepath.Join(hostRoot, parts[1])
			} else {
				argv[i] = prefix + hostRoot
			}
		} else {
			argv[i] = arg
		}
	}

	if len(argv) == 0 {
		return
	}

	bin := argv[0]
	if p, err := exec.LookPath(bin); err == nil {
		bin = p
	} else if bin == "go" {
		for _, candidate := range []string{"/opt/homebrew/bin/go", "/usr/local/bin/go"} {
			if _, err := os.Stat(candidate); err == nil {
				bin = candidate
				break
			}
		}
	}

	// Ensure parent directories exist for flags like -coverprofile, -cpuprofile, etc.
	for _, arg := range argv[1:] {
		for _, flag := range []string{"-coverprofile=", "-cpuprofile=", "-memprofile=", "-blockprofile=", "-mutexprofile="} {
			if strings.HasPrefix(arg, flag) {
				filePath := strings.TrimPrefix(arg, flag)
				_ = os.MkdirAll(filepath.Dir(filePath), 0o755)
			}
		}
	}

	fmt.Fprintf(os.Stderr, "[vsock-bridge] running %s %s (dir %s)\n", bin, strings.Join(argv[1:], " "), cwd)
	cmd := exec.Command(bin, argv[1:]...)
	cmd.Dir = cwd
	cmd.Env = os.Environ()
	for _, e := range init.Env {
		if strings.HasPrefix(e, "GOCACHE=") || strings.HasPrefix(e, "GOMODCACHE=") ||
			strings.HasPrefix(e, "GOOS=") || strings.HasPrefix(e, "PATH=") ||
			strings.HasPrefix(e, "HOME=") {
			continue
		}
		cmd.Env = append(cmd.Env, e)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		sendExit(conn, 1)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		sendExit(conn, 1)
		return
	}

	if err := cmd.Start(); err != nil {
		sendFrame(conn, frameStderr, []byte(err.Error()+"\n"))
		sendExit(conn, 1)
		return
	}

	go streamFrames(conn, frameStdout, stdout)
	go streamFrames(conn, frameStderr, stderr)

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
		}
	}
	sendExit(conn, exitCode)
}

func streamFrames(conn net.Conn, ftype uint8, r io.Reader) {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			_ = sendFrame(conn, ftype, buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func sendFrame(conn net.Conn, ftype uint8, payload []byte) error {
	var h [headerSize]byte
	h[0] = protocolVersion
	h[1] = ftype
	binary.BigEndian.PutUint16(h[2:4], 0)
	binary.BigEndian.PutUint32(h[4:8], uint32(len(payload)))

	if _, err := conn.Write(h[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		_, err := conn.Write(payload)
		return err
	}
	return nil
}

func sendExit(conn net.Conn, code int) {
	var p [4]byte
	binary.BigEndian.PutUint32(p[:], uint32(code))
	_ = sendFrame(conn, frameExit, p[:])
}

func dummy() {
	_ = syscall.AF_UNIX
}
