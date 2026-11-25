package main

/*
#include <stdlib.h>
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>

typedef void (*TerminalCallback)(const char* termId, const char* data, int length);
static TerminalCallback termCb = NULL;

static void registerTerminalCallback(TerminalCallback cb) {
    termCb = cb;
}

static void callTerminalCallback(const char* termId, const char* data, int length) {
    if (termCb != NULL) termCb(termId, data, length);
}

static int golens_openpty(int *amaster, int *aslave, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return openpty(amaster, aslave, NULL, NULL, &ws);
}

static int golens_resize_pty(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}
*/
import "C"

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golens/core/bridge"
	"golens/core/docker"
	"golens/core/lsp"
	"golens/core/vmexec"
)

const (
	maxTerminals      = 8
	terminalExitWait  = 2 * time.Second
	TerminalVsockPort = 2003
)

type terminalSession struct {
	id        string
	conn      net.Conn
	fc        *vmexec.FrameConn
	ptyMaster *os.File
	hostCmd   *exec.Cmd
	reader    chan struct{}
	exited    chan struct{}
	closed    bool
	mu        sync.Mutex
}

var (
	terminals   = make(map[string]*terminalSession)
	terminalsMu sync.Mutex
)

func emitTerminal(id string, data []byte) {
	cID := C.CString(id)
	defer C.free(unsafe.Pointer(cID))
	emitTerminalC(cID, data)
}

func emitTerminalC(cID *C.char, data []byte) {
	if len(data) == 0 {
		C.callTerminalCallback(cID, nil, 0)
		return
	}
	C.callTerminalCallback(cID, (*C.char)(unsafe.Pointer(&data[0])), C.int(len(data)))
}

// Ownership: the callback receives (data, length) valid only during the call and must copy it.
//
//export RegisterTerminalCallback
func RegisterTerminalCallback(cb C.TerminalCallback) {
	C.registerTerminalCallback(cb)
}

// Ownership: termId and cwd are copied; the session lives until CloseTerminal or ShutdownGoLensCore.
//
//export StartTerminal
func StartTerminal(termId *C.char, cwd *C.char) {
	id := C.GoString(termId)
	dir := C.GoString(cwd)
	go func() {
		if err := startTerminal(id, dir); err != nil {
			emitTerminal(id, []byte(fmt.Sprintf("Failed to launch terminal: %v\r\n", err)))
		}
	}()
}

func startTerminal(id, dir string) error {
	terminalsMu.Lock()
	if _, exists := terminals[id]; exists {
		terminalsMu.Unlock()
		return nil
	}
	if len(terminals) >= maxTerminals {
		terminalsMu.Unlock()
		return fmt.Errorf("at most %d terminal sessions can be open", maxTerminals)
	}
	terminalsMu.Unlock()

	workspaceRoot := lsp.GetActiveDir()
	if workspaceRoot == "" {
		workspaceRoot = dir
	}
	slug := vmexec.WorkspaceSlug(workspaceRoot)
	guestDir := vmexec.HostToGuestPath(workspaceRoot, dir)
	if guestDir == "" {
		guestDir = "/workspaces/" + slug
	}

	env := vmexec.DefaultVMEnv("arm64", map[string]string{
		"TERM":                "xterm-256color",
		"COLORTERM":           "truecolor",
		"CLICOLOR":            "1",
		"SHELL":               "/bin/bash",
		"USER":                "root",
		"HOME":                "/root",
		"PATH":                "/usr/local/go/bin:/root/go/bin:/usr/local/bin:/usr/bin:/bin",
		"GOROOT":              "/usr/local/go",
		"GOPATH":              "/root/go",
		"GOCACHE":             "/cache/gobuild",
		"GOMODCACHE":          "/cache/gomod",
		"GIT_CONFIG_NOSYSTEM": "1",
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := bridge.DialSandboxVsockWithRetry(ctx, TerminalVsockPort, 5*time.Second)
	if err != nil {
		if bridge.CanFallbackToHost(err) {
			return startHostTerminal(id, dir)
		}
		return fmt.Errorf("failed to connect to Linux Micro-VM terminal (vsock :%d): %w", TerminalVsockPort, err)
	}

	fc := vmexec.NewFrameConn(conn)
	init := vmexec.ExecInit{
		Argv: []string{"/bin/bash", "--login"},
		Env:  env,
		Cwd:  guestDir,
		TTY:  true,
	}
	if err := fc.SendExecInit(init); err != nil {
		_ = conn.Close()
		return fmt.Errorf("terminal init handshake failed: %w", err)
	}

	initResize := make([]byte, 8)
	binary.BigEndian.PutUint16(initResize[0:2], 24)
	binary.BigEndian.PutUint16(initResize[2:4], 80)
	_ = fc.WriteFrame(vmexec.FrameResize, 0, initResize)

	s := &terminalSession{
		id:     id,
		conn:   conn,
		fc:     fc,
		reader: make(chan struct{}),
		exited: make(chan struct{}),
	}
	terminalsMu.Lock()
	terminals[id] = s
	terminalsMu.Unlock()

	go func() {
		defer close(s.reader)
		cID := C.CString(id)
		defer C.free(unsafe.Pointer(cID))
		for {
			hdr, payload, err := fc.ReadFrame()
			if err != nil {
				s.handleExit(-1)
				return
			}
			switch hdr.Type {
			case vmexec.FrameStdout, vmexec.FrameStderr:
				if len(payload) > 0 {
					emitTerminalC(cID, payload)
				}
			case vmexec.FrameExit:
				var code int32 = -1
				if len(payload) >= 4 {
					code = int32(binary.BigEndian.Uint32(payload[:4]))
				}
				s.handleExit(code)
				return
			case vmexec.FrameError:
				if len(payload) > 0 {
					emitTerminalC(cID, append([]byte("\r\n"), payload...))
				}
			}
		}
	}()
	return nil
}

func startHostTerminal(id, dir string) error {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	} else if st, err := os.Stat(shell); err != nil || st.IsDir() {
		shell = "/bin/zsh"
	}
	return startHostPTY(id, dir, []string{shell, "-l"}, mergeHostTerminalEnv(shell))
}

func startTerminalCommand(id, dir string, argv []string) error {
	if len(argv) == 0 || argv[0] == "" {
		return fmt.Errorf("no command to run")
	}
	bin := docker.LookPath(argv[0])
	if bin == "" {
		return fmt.Errorf("%s was not found on PATH", argv[0])
	}
	terminalsMu.Lock()
	_, exists := terminals[id]
	full := len(terminals) >= maxTerminals
	terminalsMu.Unlock()
	if exists {
		return nil
	}
	if full {
		return fmt.Errorf("at most %d terminal sessions can be open", maxTerminals)
	}
	env := []string{}
	for _, kv := range mergeHostTerminalEnv(os.Getenv("SHELL")) {
		if !strings.HasPrefix(kv, "PATH=") {
			env = append(env, kv)
		}
	}
	for _, kv := range docker.Env() {
		if strings.HasPrefix(kv, "PATH=") {
			env = append(env, kv)
		}
	}
	return startHostPTY(id, dir, append([]string{bin}, argv[1:]...), env)
}

func startHostPTY(id, dir string, argv, env []string) error {
	var masterFD, slaveFD C.int
	if C.golens_openpty(&masterFD, &slaveFD, 24, 80) != 0 {
		return fmt.Errorf("openpty failed")
	}
	masterFile := os.NewFile(uintptr(masterFD), "golens-pty-master")
	slaveFile := os.NewFile(uintptr(slaveFD), "golens-pty-slave")
	if masterFile == nil || slaveFile == nil {
		if masterFile != nil {
			_ = masterFile.Close()
		} else {
			_ = syscall.Close(int(masterFD))
		}
		if slaveFile != nil {
			_ = slaveFile.Close()
		} else {
			_ = syscall.Close(int(slaveFD))
		}
		return fmt.Errorf("failed to wrap pty file descriptors")
	}

	cwd := dir
	if !hostDirExists(cwd) {
		if active := lsp.GetActiveDir(); hostDirExists(active) {
			cwd = active
		} else if home, err := os.UserHomeDir(); err == nil && hostDirExists(home) {
			cwd = home
		} else {
			cwd = ""
		}
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = env
	cmd.Stdin = slaveFile
	cmd.Stdout = slaveFile
	cmd.Stderr = slaveFile
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
	}

	if err := cmd.Start(); err != nil {
		_ = slaveFile.Close()
		_ = masterFile.Close()
		return err
	}
	_ = slaveFile.Close()

	s := &terminalSession{
		id:        id,
		ptyMaster: masterFile,
		hostCmd:   cmd,
		reader:    make(chan struct{}),
		exited:    make(chan struct{}),
	}
	terminalsMu.Lock()
	if _, exists := terminals[id]; exists {
		terminalsMu.Unlock()
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGHUP)
		}
		_ = masterFile.Close()
		_ = cmd.Wait()
		return nil
	}
	terminals[id] = s
	terminalsMu.Unlock()

	go func() {
		defer close(s.reader)
		cID := C.CString(id)
		defer C.free(unsafe.Pointer(cID))
		buf := make([]byte, 16*1024)
		for {
			n, readErr := masterFile.Read(buf)
			if n > 0 {
				emitTerminalC(cID, buf[:n])
			}
			if readErr != nil {
				break
			}
		}
		var code int32
		if waitErr := cmd.Wait(); waitErr != nil {
			if exitErr, ok := waitErr.(*exec.ExitError); ok {
				code = int32(exitErr.ExitCode())
			} else {
				code = -1
			}
		}
		_ = masterFile.Close()
		s.handleExit(code)
	}()
	return nil
}

func hostDirExists(path string) bool {
	if path == "" {
		return false
	}
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

func mergeHostTerminalEnv(shell string) []string {
	base := os.Environ()
	env := make([]string, 0, len(base)+4)
	hasShell := false
	for _, entry := range base {
		if strings.HasPrefix(entry, "TERM=") || strings.HasPrefix(entry, "COLORTERM=") || strings.HasPrefix(entry, "CLICOLOR=") {
			continue
		}
		if strings.HasPrefix(entry, "SHELL=") {
			hasShell = true
		}
		env = append(env, entry)
	}
	if !hasShell && shell != "" {
		env = append(env, "SHELL="+shell)
	}
	env = append(env, "TERM=xterm-256color", "COLORTERM=truecolor", "CLICOLOR=1")
	return env
}

func (s *terminalSession) handleExit(code int32) {
	s.mu.Lock()
	select {
	case <-s.exited:
	default:
		close(s.exited)
	}
	s.mu.Unlock()

	terminalsMu.Lock()
	open := terminals[s.id] == s
	if open {
		delete(terminals, s.id)
	}
	terminalsMu.Unlock()
	if open {
		b, _ := json.Marshal(map[string]any{"id": s.id, "code": code})
		bridge.Status("terminalExit", string(b))
	}
}

func writeTerminalBytes(termId string, data []byte) {
	terminalsMu.Lock()
	s, ok := terminals[termId]
	terminalsMu.Unlock()
	if !ok || s == nil || len(data) == 0 {
		return
	}
	if s.ptyMaster != nil {
		_, _ = s.ptyMaster.Write(data)
		return
	}
	if s.fc != nil {
		_ = s.fc.WriteFrame(vmexec.FrameStdin, 0, data)
	}
}

// Ownership: input (length bytes) is read only during the call.
//
//export WriteTerminal
func WriteTerminal(termId *C.char, input *C.char, length C.int) {
	if length <= 0 || input == nil {
		return
	}
	id := C.GoString(termId)
	data := unsafe.Slice((*byte)(unsafe.Pointer(input)), int(length))
	writeTerminalBytes(id, data)
}

func resizeTerminalInternal(termId string, rows, cols int) {
	if rows <= 0 || cols <= 0 {
		return
	}
	terminalsMu.Lock()
	s, ok := terminals[termId]
	terminalsMu.Unlock()
	if !ok || s == nil {
		return
	}
	if s.ptyMaster != nil {
		if rawConn, err := s.ptyMaster.SyscallConn(); err == nil {
			_ = rawConn.Control(func(fd uintptr) {
				C.golens_resize_pty(C.int(fd), C.ushort(rows), C.ushort(cols))
			})
		} else {
			C.golens_resize_pty(C.int(s.ptyMaster.Fd()), C.ushort(rows), C.ushort(cols))
		}
		return
	}
	if s.fc != nil {
		payload := make([]byte, 8)
		binary.BigEndian.PutUint16(payload[0:2], uint16(rows))
		binary.BigEndian.PutUint16(payload[2:4], uint16(cols))
		binary.BigEndian.PutUint16(payload[4:6], 0)
		binary.BigEndian.PutUint16(payload[6:8], 0)
		_ = s.fc.WriteFrame(vmexec.FrameResize, 0, payload)
	}
}

// Ownership: termId is copied.
//
//export ResizeTerminal
func ResizeTerminal(termId *C.char, rows, cols C.int) {
	resizeTerminalInternal(C.GoString(termId), int(rows), int(cols))
}

// Ownership: termId is copied; the shell is terminated and reaped before returning.
//
//export CloseTerminal
func CloseTerminal(termId *C.char) {
	closeTerminal(C.GoString(termId))
}

func closeTerminal(id string) {
	terminalsMu.Lock()
	s, ok := terminals[id]
	delete(terminals, id)
	terminalsMu.Unlock()
	if ok {
		s.stop()
	}
}

func (s *terminalSession) stop() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()

	if s.ptyMaster != nil {
		if s.hostCmd != nil && s.hostCmd.Process != nil && s.hostCmd.Process.Pid > 0 {
			_ = syscall.Kill(-s.hostCmd.Process.Pid, syscall.SIGHUP)
		}
		_ = s.ptyMaster.Close()
		select {
		case <-s.exited:
		case <-time.After(500 * time.Millisecond):
			if s.hostCmd != nil && s.hostCmd.Process != nil && s.hostCmd.Process.Pid > 0 {
				_ = syscall.Kill(-s.hostCmd.Process.Pid, syscall.SIGKILL)
			}
			select {
			case <-s.exited:
			case <-time.After(terminalExitWait):
			}
		}
		select {
		case <-s.reader:
		case <-time.After(500 * time.Millisecond):
		}
		return
	}

	defer func() {
		if s.conn != nil {
			_ = s.conn.Close()
		}
	}()

	sigPayload := make([]byte, 4)
	binary.BigEndian.PutUint32(sigPayload, uint32(syscall.SIGHUP))
	if s.conn != nil {
		_ = s.conn.SetWriteDeadline(time.Now().Add(250 * time.Millisecond))
	}
	if s.fc != nil {
		_ = s.fc.WriteFrame(vmexec.FrameSignal, 0, sigPayload)
	}
	if s.conn != nil {
		_ = s.conn.Close()
	}

	select {
	case <-s.exited:
	case <-time.After(terminalExitWait):
	}
	select {
	case <-s.reader:
	case <-time.After(500 * time.Millisecond):
	}
}

func closeAllTerminals() {
	terminalsMu.Lock()
	ids := make([]string, 0, len(terminals))
	for id := range terminals {
		ids = append(ids, id)
	}
	terminalsMu.Unlock()
	var wg sync.WaitGroup
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			closeTerminal(id)
		}(id)
	}
	wg.Wait()
}
