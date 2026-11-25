//go:build linux && arm64

package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golens/core/cmd/golens-vm-agent/guestres"
	"golens/core/cmd/golens-vm-agent/kerneltelemetry"
)

const (
	afVsock         = 40
	vmaddrCIDAny    = 0xFFFFFFFF
	protocolVersion = 0x01
	headerSize      = 8

	frameExecInit        uint8 = 0x01
	frameStdin           uint8 = 0x02
	frameStdinClose      uint8 = 0x03
	frameStdout          uint8 = 0x04
	frameStderr          uint8 = 0x05
	frameExit            uint8 = 0x06
	frameSignal          uint8 = 0x07
	frameResize          uint8 = 0x08
	frameError           uint8 = 0x09
	framePing            uint8 = 0x0A
	framePong            uint8 = 0x0B
	frameKernelTelemetry uint8 = 0x0C
	frameSignRequest     uint8 = 0x0D
	frameSignResponse    uint8 = 0x0E

	flagOOMKilled        uint16 = 0x0008
	flagSignRelayCapable uint16 = 0x0040
	flagSignError        uint16 = 0x0080

	maxSignPayloadSize = 1 << 20

	tiocgptn   = 0x80045430
	tiocsptlck = 0x40045431
	tiocswinsz = 0x5414
)

type sockaddrVM struct {
	Family    uint16
	Reserved1 uint16
	Port      uint32
	CID       uint32
	Flags     uint8
	Zero      [3]byte
}

type winsize struct {
	Row    uint16
	Col    uint16
	Xpixel uint16
	Ypixel uint16
}

type cgroupLimits struct {
	MemoryMax   uint64 `json:"memory_max,omitempty"`
	CPUQuotaUS  uint32 `json:"cpu_quota_us,omitempty"`
	CPUPeriodUS uint32 `json:"cpu_period_us,omitempty"`
}

type execInit struct {
	Argv                []string      `json:"argv"`
	Env                 []string      `json:"env"`
	Cwd                 string        `json:"cwd"`
	TTY                 bool          `json:"tty,omitempty"`
	Rosetta             bool          `json:"rosetta,omitempty"`
	Cgroup              *cgroupLimits `json:"cgroup,omitempty"`
	EnableTelemetry     bool          `json:"enable_telemetry,omitempty"`
	TelemetryIntervalMs uint32        `json:"telemetry_interval_ms,omitempty"`
	ReadOnlyWorkspace   bool          `json:"read_only_workspace,omitempty"`
	LoopbackOnlyNetwork bool          `json:"loopback_only_network,omitempty"`
	EnableCommitSigning bool          `json:"enable_commit_signing,omitempty"`
}

type signRelayResponse struct {
	flags   uint16
	payload []byte
}

var (
	runCounter       uint64
	activeLSPMu      sync.Mutex
	activeLSPPid     int
	signRelayCapable bool
)

const (
	cgroupRoot       = "/sys/fs/cgroup"
	golensCgroup     = "/sys/fs/cgroup/golens"
	lspCgroup        = "/sys/fs/cgroup/golens/lsp"
	guestGoTmpDir    = "/cache/gobuild/golens-tmp"
	guestXDGCacheDir = "/cache/gobuild/golens-xdg"
)

var guestCachePathKeys = map[string]bool{
	"GOCACHE":        true,
	"GOMODCACHE":     true,
	"GOTMPDIR":       true,
	"XDG_CACHE_HOME": true,
}

func enableCgroupControllers(dir string) {
	for _, controller := range []string{"+memory", "+cpu", "+pids"} {
		_ = os.WriteFile(filepath.Join(dir, "cgroup.subtree_control"), []byte(controller), 0644)
	}
}

func prepareCgroup(dir string, limits map[string]string) (*os.File, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(limits))
	for name := range limits {
		keys = append(keys, name)
	}
	slices.Sort(keys)
	for _, name := range keys {
		value := limits[name]
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0644); err != nil {
			if dir != lspCgroup {
				_ = os.Remove(dir)
			}
			return nil, fmt.Errorf("%s=%s: %w", name, value, err)
		}
	}
	f, err := os.Open(dir)
	if err != nil && dir != lspCgroup {
		_ = os.Remove(dir)
	}
	return f, err
}

func attachCgroup(attr *syscall.SysProcAttr, cg *os.File) {
	if cg == nil {
		return
	}
	attr.UseCgroupFD = true
	attr.CgroupFD = int(cg.Fd())
}

func guestMemTotal() uint64 {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	return guestres.ParseMemTotal(b)
}

func guestUsableMemory() uint64 {
	meminfo, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	vmstat, _ := os.ReadFile("/proc/vmstat")
	return guestres.UsableMemory(guestres.ParseMemTotal(meminfo), guestres.ParseBalloonPages(vmstat))
}

func main() {
	if filepath.Base(os.Args[0]) == "golens-git-sign" {
		os.Exit(runGitSignHelper(os.Args[1:]))
	}
	if os.Args[0] == guestres.SandboxExecName {
		os.Exit(runSandboxExec(os.Args[1:]))
	}
	if isInitProcess() {
		runInit()
	}
	debug.SetGCPercent(25)
	debug.SetMemoryLimit(32 << 20)
	setupFilesystemsAndEnv()
	raiseOpenFileLimit()
	setupZramSwap()
	go followGuestMemory(2 * time.Second)

	go serveVsock(2001, handleLSPConn)
	go serveVsock(2002, handleExecConn)
	go serveVsock(2003, handleTerminalConn)
	go serveVsock(2004, handlePortForwardConn)
	go serveVsock(2345, handleDAPConn)

	fmt.Println("[golens-vm-agent] READY on vsock ports 2001, 2002, 2003, 2004, 2345")
	select {}
}

func setupFilesystemsAndEnv() {
	for _, dir := range []string{
		"/dev", "/proc", "/sys", "/tmp", "/run", "/root", "/var/tmp",
		guestres.ErofsMount, "/bin", "/sbin", "/lib", "/usr",
		"/workspaces", "/cache/gomod", "/cache/gobuild", "/etc",
	} {
		_ = os.MkdirAll(dir, 0755)
	}

	_ = syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "")
	_ = os.MkdirAll("/dev/pts", 0755)
	_ = syscall.Mount("devpts", "/dev/pts", "devpts", 0, "ptmxmode=0666,mode=0620")
	_ = os.MkdirAll("/dev/shm", 0777)
	_ = syscall.Mount("tmpfs", "/dev/shm", "tmpfs", 0, "size=32m")
	_ = syscall.Mount("proc", "/proc", "proc", 0, "")
	_ = syscall.Mount("sysfs", "/sys", "sysfs", 0, "")
	_ = os.MkdirAll("/sys/fs/cgroup", 0755)
	_ = syscall.Mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, "")
	enableCgroupControllers(cgroupRoot)
	_ = os.MkdirAll(golensCgroup, 0755)
	enableCgroupControllers(golensCgroup)

	_ = os.WriteFile("/proc/sys/vm/vfs_cache_pressure", []byte("200\n"), 0644)
	_ = os.WriteFile("/proc/sys/vm/dirty_background_ratio", []byte("1\n"), 0644)
	_ = os.WriteFile("/proc/sys/vm/dirty_ratio", []byte("3\n"), 0644)
	_ = os.WriteFile("/proc/sys/vm/swappiness", []byte("10\n"), 0644)

	_ = syscall.Mount("tmpfs", "/tmp", "tmpfs", 0, "size=64m")
	_ = syscall.Mount("tmpfs", "/run", "tmpfs", 0, "size=16m")
	_ = syscall.Mount("tmpfs", "/root", "tmpfs", 0, "size=32m")
	_ = syscall.Mount("tmpfs", "/var/tmp", "tmpfs", 0, "size=32m")
	_ = syscall.Mount("tmpfs", "/etc", "tmpfs", 0, "size=16m")

	mountRootfsImage()

	_ = syscall.Mount("goroot", "/usr/local/go", "virtiofs", syscall.MS_RDONLY, "")
	if err := syscall.Mount("gomodcache", "/cache/gomod", "virtiofs", 0, ""); err != nil {
		_ = syscall.Mount("tmpfs", "/cache/gomod", "tmpfs", 0, "size=64m")
	}
	_ = syscall.Mount("workspaces", "/workspaces", "virtiofs", 0, "")

	if err := syscall.Mount("gobuildcache", "/cache/gobuild", "virtiofs", 0, ""); err != nil {
		_ = syscall.Mount("tmpfs", "/cache/gobuild", "tmpfs", 0, "size=50%")
	}
	_ = os.MkdirAll(guestGoTmpDir, 0755)
	_ = os.MkdirAll(guestXDGCacheDir, 0755)

	_ = os.MkdirAll("/mnt/rosetta", 0755)
	if err := syscall.Mount("rosetta", "/mnt/rosetta", "virtiofs", syscall.MS_RDONLY, ""); err == nil {
		_ = syscall.Mount("binfmt_misc", "/proc/sys/fs/binfmt_misc", "binfmt_misc", 0, "")
		reg := ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/mnt/rosetta/rosetta:OCF"
		_ = os.WriteFile("/proc/sys/fs/binfmt_misc/register", []byte(reg), 0644)
	}

	_ = syscall.Mount("tmpfs", "/usr/local/bin", "tmpfs", 0, "size=16m")
	for _, l := range guestres.LocalBinLinks() {
		_ = os.Remove(l.Path)
		_ = os.Symlink(l.Target, l.Path)
	}
	_ = os.MkdirAll("/run/golens-sign", 0700)

	shell, _ := guestres.TerminalShell(fileExists)
	passwd, _ := os.ReadFile(guestres.ErofsMount + "/etc/passwd")
	_ = os.WriteFile("/etc/passwd", guestres.WithRootShell(passwd, shell), 0644)
	if _, err := os.Stat("/etc/group"); err != nil {
		_ = os.WriteFile("/etc/group", []byte("root:x:0:\n"), 0644)
	}
	_ = os.WriteFile("/etc/hosts", []byte("127.0.0.1\tlocalhost\n::1\tlocalhost\n"), 0644)
	_ = os.WriteFile("/etc/resolv.conf", []byte("nameserver 8.8.8.8\nnameserver 1.1.1.1\n"), 0644)

	profile := `export PATH="` + guestres.GuestPATH + `"
export GOROOT="/usr/local/go"
export GOPATH="/root/go"
export GOCACHE="/cache/gobuild"
export GOMODCACHE="/cache/gomod"
export GOTMPDIR="` + guestGoTmpDir + `"
export XDG_CACHE_HOME="` + guestXDGCacheDir + `"
export HOME="/root"
export USER="root"
export TERM="xterm-256color"
`
	_ = os.WriteFile("/etc/profile", []byte(profile), 0644)
	_ = os.WriteFile("/root/.bashrc", []byte(profile+"export PS1='\\[\\033[1;36m\\]linux/arm64\\[\\033[0m\\]:\\[\\033[1;34m\\]\\w\\[\\033[0m\\]# '\n"), 0644)
	_ = os.WriteFile("/root/.bash_profile", []byte("[ -f /root/.bashrc ] && . /root/.bashrc\n"), 0644)
	_ = os.WriteFile("/root/.gitconfig", []byte("[safe]\n\tdirectory = *\n"), 0644)

	_ = os.Setenv("PATH", guestres.GuestPATH)
	_ = os.Setenv("GOROOT", "/usr/local/go")
	_ = os.Setenv("GOPATH", "/root/go")
	_ = os.Setenv("GOCACHE", "/cache/gobuild")
	_ = os.Setenv("GOMODCACHE", "/cache/gomod")
	_ = os.Setenv("GOTMPDIR", guestGoTmpDir)
	_ = os.Setenv("XDG_CACHE_HOME", guestXDGCacheDir)
	_ = os.Setenv("HOME", "/root")
	_ = os.Setenv("USER", "root")

	if err := bringLoopbackUp(); err != nil {
		fmt.Println("[golens-vm-agent] loopback not up: " + err.Error())
	}

	signRelayCapable = detectGitSignRelayCapable()
}

func mountRootfsImage() {
	if err := syscall.Mount(guestres.RootfsDevice, guestres.ErofsMount, "erofs", syscall.MS_RDONLY, ""); err != nil {
		fmt.Println("[golens-vm-agent] root filesystem image not mounted: " + err.Error())
		return
	}
	for _, dir := range guestres.RootfsBindDirs {
		if err := syscall.Mount(guestres.ErofsMount+dir, dir, "", syscall.MS_BIND, ""); err != nil {
			fmt.Printf("[golens-vm-agent] bind %s: %v\n", dir, err)
		}
	}
	if entries, err := os.ReadDir(guestres.ErofsMount + "/sbin"); err == nil {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		for _, l := range guestres.SbinLinks(names) {
			_ = os.Remove(l.Path)
			_ = os.Symlink(l.Target, l.Path)
		}
	}
	if err := guestres.CopyTree(guestres.ErofsMount+"/etc", "/etc", guestres.EtcBindDirs); err != nil {
		fmt.Println("[golens-vm-agent] copy /etc: " + err.Error())
	}
	for _, dir := range guestres.EtcBindDirs {
		target := "/etc/" + dir
		_ = os.MkdirAll(target, 0755)
		if err := syscall.Mount(guestres.ErofsMount+target, target, "", syscall.MS_BIND, ""); err != nil {
			fmt.Printf("[golens-vm-agent] bind %s: %v\n", target, err)
		}
	}
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func detectGitSignRelayCapable() bool {
	if _, err := os.Lstat("/usr/local/bin/golens-git-sign"); err != nil {
		return false
	}
	out, err := exec.Command(resolveBinary("git"), "--version").Output()
	if err != nil {
		return false
	}
	return parseGitVersionAtLeast234(string(out))
}

func parseGitVersionAtLeast234(raw string) bool {
	fields := strings.Fields(strings.TrimSpace(raw))
	for _, f := range fields {
		parts := strings.Split(f, ".")
		if len(parts) >= 2 {
			maj, err1 := strconv.Atoi(parts[0])
			min, err2 := strconv.Atoi(parts[1])
			if err1 == nil && err2 == nil {
				return maj > 2 || (maj == 2 && min >= 34)
			}
		}
	}
	return false
}

func runGitSignHelper(args []string) int {
	isSign := false
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-Y" && args[i+1] == "sign" {
			isSign = true
			break
		}
	}
	if !isSign || len(args) == 0 {
		fmt.Fprintln(os.Stderr, "golens-git-sign: only -Y sign is supported")
		return 1
	}
	sockPath := os.Getenv("GOLENS_SIGN_SOCK")
	if sockPath == "" {
		fmt.Fprintln(os.Stderr, "golens-git-sign: signing session socket is not available")
		return 1
	}
	bufFile := args[len(args)-1]
	fi, err := os.Stat(bufFile)
	if err != nil || fi.IsDir() {
		fmt.Fprintf(os.Stderr, "golens-git-sign: cannot stat buffer file: %v\n", err)
		return 1
	}
	if fi.Size() > maxSignPayloadSize {
		fmt.Fprintln(os.Stderr, "golens-git-sign: buffer exceeds 1 MB limit")
		return 1
	}
	payload, err := os.ReadFile(bufFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "golens-git-sign: cannot read buffer file: %v\n", err)
		return 1
	}
	conn, err := net.DialTimeout("unix", sockPath, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "golens-git-sign: failed to connect to signing relay: %v\n", err)
		return 1
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(35 * time.Second))
	if _, err := conn.Write(payload); err != nil {
		fmt.Fprintf(os.Stderr, "golens-git-sign: failed to send payload: %v\n", err)
		return 1
	}
	if uc, ok := conn.(*net.UnixConn); ok {
		_ = uc.CloseWrite()
	}
	resp, err := io.ReadAll(io.LimitReader(conn, maxSignPayloadSize+1))
	if err != nil || len(resp) == 0 {
		fmt.Fprintln(os.Stderr, "golens-git-sign: empty response from host signing relay")
		return 1
	}
	if resp[0] != 0 {
		fmt.Fprintln(os.Stderr, strings.TrimSpace(string(resp[1:])))
		return 1
	}
	sigFile := bufFile + ".sig"
	if err := os.WriteFile(sigFile, resp[1:], 0600); err != nil {
		fmt.Fprintf(os.Stderr, "golens-git-sign: failed to write signature file: %v\n", err)
		return 1
	}
	return 0
}

const zramDevice = "/dev/zram0"

var zramPoolBytes atomic.Uint64

func setupZramSwap() {
	z := guestres.ZramSwapFor(guestMemTotal())
	if err := enableZramSwap(z); err != nil {
		fmt.Println("[golens-vm-agent] zram swap not enabled: " + err.Error())
		return
	}
	zramPoolBytes.Store(z.MemLimit)
	fmt.Printf("[golens-vm-agent] zram swap %d MiB, compressed pool up to %d MiB\n", z.DiskSize>>20, z.MemLimit>>20)
}

func lspBudgetFor(memTotal uint64) guestres.LSPBudget {
	return guestres.LSPBudgetFor(memTotal).WithSwapPool(memTotal, zramPoolBytes.Load())
}

func followGuestMemory(interval time.Duration) {
	var applied uint64
	for {
		if memTotal := guestUsableMemory(); memTotal > 0 {
			if guestres.MemTotalMoved(applied, memTotal) {
				if applied > 0 {
					fmt.Printf("[golens-vm-agent] guest memory %d MiB: resizing the swap pool and the gopls budget\n", memTotal>>20)
				}
				resizeZramPool(memTotal)
				applied = memTotal
			}
			applyLSPLimits(lspBudgetFor(applied))
		}
		time.Sleep(interval)
	}
}

func resizeZramPool(memTotal uint64) {
	if zramPoolBytes.Load() == 0 {
		return
	}
	pool := guestres.ZramPoolFor(memTotal)
	if err := os.WriteFile("/sys/block/zram0/mem_limit", []byte(strconv.FormatUint(pool, 10)), 0644); err != nil {
		fmt.Println("[golens-vm-agent] zram pool resize failed: " + err.Error())
		return
	}
	zramPoolBytes.Store(pool)
}

func applyLSPLimits(budget guestres.LSPBudget) {
	current, err := readCgroupUint(lspCgroup, "memory.current")
	if err != nil {
		return
	}
	writeCgroupUint(lspCgroup, "memory.high", budget.CgroupHigh)
	writeCgroupUint(lspCgroup, "memory.max", guestres.LSPMaxFor(budget.CgroupMax, current))
}

func readCgroupUint(dir, name string) (uint64, error) {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(b))
	if s == "max" {
		return 1<<63 - 1, nil
	}
	return strconv.ParseUint(s, 10, 64)
}

func writeCgroupUint(dir, name string, v uint64) {
	if cur, err := readCgroupUint(dir, name); err == nil && cur == v {
		return
	}
	_ = os.WriteFile(filepath.Join(dir, name), []byte(strconv.FormatUint(v, 10)), 0644)
}

func enableZramSwap(z guestres.ZramSwap) error {
	sys := "/sys/block/zram0/"
	if _, err := os.Stat(sys + "disksize"); err != nil {
		return err
	}
	if err := os.WriteFile(sys+"disksize", []byte(strconv.FormatUint(z.DiskSize, 10)), 0644); err != nil {
		return fmt.Errorf("disksize: %w", err)
	}
	if err := os.WriteFile(sys+"mem_limit", []byte(strconv.FormatUint(z.MemLimit, 10)), 0644); err != nil {
		return fmt.Errorf("mem_limit: %w", err)
	}
	header := guestres.SwapHeader(os.Getpagesize(), z.DiskSize)
	if header == nil {
		return fmt.Errorf("device too small: %d bytes", z.DiskSize)
	}
	f, err := os.OpenFile(zramDevice, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	_, werr := f.WriteAt(header, 0)
	cerr := f.Close()
	if werr != nil {
		return fmt.Errorf("swap header: %w", werr)
	}
	if cerr != nil {
		return fmt.Errorf("swap header: %w", cerr)
	}
	path, err := syscall.BytePtrFromString(zramDevice)
	if err != nil {
		return err
	}
	const swapFlagPrefer, priority = 0x8000, 100
	if _, _, errno := syscall.Syscall(syscall.SYS_SWAPON, uintptr(unsafe.Pointer(path)), swapFlagPrefer|priority, 0); errno != 0 {
		return fmt.Errorf("swapon: %w", errno)
	}
	return nil
}

func raiseOpenFileLimit() {
	nrOpen, _ := os.ReadFile("/proc/sys/fs/nr_open")
	lim, err := guestres.RaiseNoFile(guestres.NoFileTarget(nrOpen))
	if err != nil {
		fmt.Println("[golens-vm-agent] RLIMIT_NOFILE unchanged: " + err.Error())
		return
	}
	fmt.Printf("[golens-vm-agent] RLIMIT_NOFILE %d/%d\n", lim.Cur, lim.Max)
}

func serveVsock(port uint32, handler func(*os.File)) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return
	}
	sa := sockaddrVM{
		Family: afVsock,
		Port:   port,
		CID:    vmaddrCIDAny,
	}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa))
	if errno != 0 {
		return
	}
	_, _, errno = syscall.Syscall(syscall.SYS_LISTEN, uintptr(fd), 128, 0)
	if errno != 0 {
		return
	}

	for {
		var rsa sockaddrVM
		rlen := uint32(unsafe.Sizeof(rsa))
		nfd, _, errno := syscall.Syscall6(
			syscall.SYS_ACCEPT4,
			uintptr(fd),
			uintptr(unsafe.Pointer(&rsa)),
			uintptr(unsafe.Pointer(&rlen)),
			syscall.SOCK_CLOEXEC,
			0,
			0,
		)
		if errno != 0 {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		f := os.NewFile(nfd, fmt.Sprintf("vsock-client-%d", port))
		go handler(f)
	}
}

func resolveBinary(name string) string {
	if p, ok := guestres.ResolveIn(name, fileExists); ok {
		return p
	}
	name = filepath.Base(name)
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	return name
}

func waitForWorkspaceDir(dir string) string {
	if dir == "" || dir == "." {
		return "/workspaces"
	}
	for i := 0; i < 25; i++ {
		if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
			return dir
		}
		time.Sleep(40 * time.Millisecond)
	}
	if strings.HasPrefix(dir, "/workspaces/") {
		parts := strings.SplitN(strings.TrimPrefix(dir, "/workspaces/"), "/", 2)
		root := "/workspaces/" + parts[0]
		if fi, err := os.Stat(root); err == nil && fi.IsDir() {
			return root
		}
	}
	return "/root"
}

func mergeGuestEnv(extra []string) []string {
	envMap := map[string]string{
		"PATH":                guestres.GuestPATH,
		"GOROOT":              "/usr/local/go",
		"GOPATH":              "/root/go",
		"GOCACHE":             "/cache/gobuild",
		"GOMODCACHE":          "/cache/gomod",
		"CGO_ENABLED":         "0",
		"HOME":                "/root",
		"USER":                "root",
		"TERM":                "xterm-256color",
		"COLORTERM":           "truecolor",
		"GIT_CONFIG_NOSYSTEM": "1",
		"GIT_TERMINAL_PROMPT": "0",
		"GOTMPDIR":            guestGoTmpDir,
		"XDG_CACHE_HOME":      guestXDGCacheDir,
	}
	for _, kv := range extra {
		if idx := strings.IndexByte(kv, '='); idx > 0 {
			k := kv[:idx]
			v := kv[idx+1:]
			if k == "PATH" || k == "GOROOT" || k == "HOME" || k == "GOLENS_SIGN_SOCK" {
				continue
			}
			if guestCachePathKeys[k] && !strings.HasPrefix(v, "/cache/") {
				continue
			}
			envMap[k] = v
		}
	}
	out := make([]string, 0, len(envMap))
	for k, v := range envMap {
		out = append(out, k+"="+v)
	}
	return out
}

func handleLSPConn(conn *os.File) {
	defer conn.Close()

	activeLSPMu.Lock()
	if activeLSPPid > 0 {
		_ = syscall.Kill(-activeLSPPid, syscall.SIGKILL)
		_ = syscall.Kill(activeLSPPid, syscall.SIGKILL)
		activeLSPPid = 0
	}
	activeLSPMu.Unlock()

	goplsBin := resolveBinary("gopls")
	budget := lspBudgetFor(guestUsableMemory())
	cmd := exec.Command(goplsBin, "serve")
	cmd.Dir = "/workspaces"
	cmd.Env = mergeGuestEnv([]string{guestres.GoMemLimitEnv(budget.GoMemLimit)})
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	cg, cgErr := prepareCgroup(lspCgroup, map[string]string{
		"memory.high": strconv.FormatUint(budget.CgroupHigh, 10),
		"memory.max":  strconv.FormatUint(budget.CgroupMax, 10),
	})
	if cgErr == nil {
		defer cg.Close()
		attachCgroup(cmd.SysProcAttr, cg)
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}

	pid := cmd.Process.Pid
	activeLSPMu.Lock()
	activeLSPPid = pid
	activeLSPMu.Unlock()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(stdin, conn)
		_ = stdin.Close()
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(conn, stdout)
		done <- struct{}{}
	}()

	<-done
	if cmd.Process != nil {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = cmd.Process.Kill()
	}
	_ = cmd.Wait()
	activeLSPMu.Lock()
	if activeLSPPid == pid {
		activeLSPPid = 0
	}
	activeLSPMu.Unlock()
}

type safeFrameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *safeFrameWriter) writeFrame(ftype uint8, flags uint16, payload []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var h [headerSize]byte
	h[0] = protocolVersion
	h[1] = ftype
	binary.BigEndian.PutUint16(h[2:4], flags)
	binary.BigEndian.PutUint32(h[4:8], uint32(len(payload)))
	if _, err := s.w.Write(h[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := s.w.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

func readFrame(r io.Reader) (uint8, uint16, []byte, error) {
	var h [headerSize]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return 0, 0, nil, err
	}
	if h[0] != protocolVersion {
		return 0, 0, nil, fmt.Errorf("bad version: 0x%02x", h[0])
	}
	ftype := h[1]
	flags := binary.BigEndian.Uint16(h[2:4])
	length := binary.BigEndian.Uint32(h[4:8])
	if length == 0 {
		return ftype, flags, nil, nil
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, 0, nil, err
	}
	return ftype, flags, payload, nil
}

func handleExecConn(conn *os.File) {
	defer conn.Close()
	fw := &safeFrameWriter{w: conn}

	ftype, _, payload, err := readFrame(conn)
	if err != nil {
		return
	}
	if ftype == framePing {
		var pongFlags uint16
		if signRelayCapable {
			pongFlags |= flagSignRelayCapable
		}
		_ = fw.writeFrame(framePong, pongFlags, nil)
		return
	}
	if ftype != frameExecInit {
		return
	}

	var init execInit
	if err := json.Unmarshal(payload, &init); err != nil || len(init.Argv) == 0 {
		_ = fw.writeFrame(frameError, 0, []byte("invalid ExecInit payload"))
		return
	}

	bin := resolveBinary(init.Argv[0])
	cwd := waitForWorkspaceDir(init.Cwd)

	for _, arg := range init.Argv[1:] {
		for _, pfx := range []string{"-coverprofile=", "-cpuprofile=", "-memprofile=", "-blockprofile=", "-mutexprofile="} {
			if strings.HasPrefix(arg, pfx) {
				p := strings.TrimPrefix(arg, pfx)
				if !strings.HasPrefix(p, "/") {
					p = filepath.Join(cwd, p)
				}
				_ = os.MkdirAll(filepath.Dir(p), 0755)
			}
		}
	}

	cmd := sandboxCommand(init, bin)
	cmd.Dir = cwd
	cmd.Env = mergeGuestEnv(init.Env)

	var signRespCh chan signRelayResponse
	var signDoneCh chan struct{}
	if init.EnableCommitSigning {
		signID := atomic.AddUint64(&runCounter, 1)
		sockPath := fmt.Sprintf("/run/golens-sign/sign-%d.sock", signID)
		_ = os.Remove(sockPath)
		if signLn, lerr := net.Listen("unix", sockPath); lerr == nil {
			_ = os.Chmod(sockPath, 0600)
			signRespCh = make(chan signRelayResponse, 1)
			signDoneCh = make(chan struct{})
			cmd.Env = append(cmd.Env, "GOLENS_SIGN_SOCK="+sockPath)
			defer func() {
				close(signDoneCh)
				_ = signLn.Close()
				_ = os.Remove(sockPath)
			}()
			go func() {
				for {
					uconn, aerr := signLn.Accept()
					if aerr != nil {
						return
					}
					func(c net.Conn) {
						defer c.Close()
						reqBytes, rerr := io.ReadAll(io.LimitReader(c, maxSignPayloadSize+1))
						if rerr != nil || len(reqBytes) > maxSignPayloadSize {
							_, _ = c.Write(append([]byte{1}, []byte("signing payload exceeds 1 MB limit")...))
							return
						}
						if werr := fw.writeFrame(frameSignRequest, 0, reqBytes); werr != nil {
							_, _ = c.Write(append([]byte{1}, []byte("failed to forward signing request to host")...))
							return
						}
						select {
						case resp := <-signRespCh:
							if resp.flags&flagSignError != 0 {
								_, _ = c.Write(append([]byte{1}, resp.payload...))
							} else {
								_, _ = c.Write(append([]byte{0}, resp.payload...))
							}
						case <-signDoneCh:
							_, _ = c.Write(append([]byte{1}, []byte("signing session closed")...))
						}
					}(uconn)
				}
			}()
		}
	}

	var cgDir string
	var reqMemMax uint64
	if init.Cgroup != nil && (init.Cgroup.MemoryMax > 0 || init.Cgroup.CPUQuotaUS > 0) {
		reqMemMax = init.Cgroup.MemoryMax
		id := atomic.AddUint64(&runCounter, 1)
		dir := fmt.Sprintf("%s/run-%d", golensCgroup, id)
		_ = os.MkdirAll(dir, 0755)
		_, swapErr := os.Stat(filepath.Join(dir, "memory.swap.max"))
		limits := guestres.RunCgroupLimits(init.Cgroup.MemoryMax, init.Cgroup.CPUQuotaUS, init.Cgroup.CPUPeriodUS, swapErr == nil)
		cg, err := prepareCgroup(dir, limits)
		if err != nil {
			_ = fw.writeFrame(frameStderr, 0, []byte(guestres.FormatCgroupSetupDiagnostic(init.Argv[0], err)))
			sendExitFrame(fw, 1, 0)
			return
		}
		defer cg.Close()
		defer func() { _ = os.Remove(dir) }()
		attachCgroup(cmd.SysProcAttr, cg)
		cgDir = dir
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		_ = fw.writeFrame(frameStderr, 0, []byte(guestres.FormatPipeDiagnostic(init.Argv[0], "stdin", err)))
		sendExitFrame(fw, 1, 0)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		_ = fw.writeFrame(frameStderr, 0, []byte(guestres.FormatPipeDiagnostic(init.Argv[0], "stdout", err)))
		sendExitFrame(fw, 1, 0)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = fw.writeFrame(frameStderr, 0, []byte(guestres.FormatPipeDiagnostic(init.Argv[0], "stderr", err)))
		sendExitFrame(fw, 1, 0)
		return
	}

	if err := cmd.Start(); err != nil {
		var ev guestres.MemoryEvents
		var exitFlags uint16
		if cgDir != "" {
			if evBytes, rerr := os.ReadFile(filepath.Join(cgDir, "memory.events")); rerr == nil {
				ev = guestres.ParseMemoryEvents(evBytes)
				if ev.OOMKilled() {
					exitFlags |= flagOOMKilled
				}
			}
		}
		_ = fw.writeFrame(frameStderr, 0, []byte(guestres.FormatStartDiagnostic(init.Argv[0], err, ev, reqMemMax)))
		sendExitFrame(fw, 1, exitFlags)
		return
	}

	stopTelemetry := make(chan struct{})
	if init.EnableTelemetry && cmd.Process != nil {
		interval := time.Duration(init.TelemetryIntervalMs) * time.Millisecond
		if interval < 200*time.Millisecond {
			interval = 1000 * time.Millisecond
		}
		go streamProcessTelemetry(cmd.Process.Pid, interval, stopTelemetry, fw)
	}

	go func() {
		for {
			ft, fl, pl, rerr := readFrame(conn)
			if rerr != nil {
				_ = stdin.Close()
				if cmd.Process != nil {
					_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				}
				return
			}
			switch ft {
			case frameStdin:
				if len(pl) > 0 {
					_, _ = stdin.Write(pl)
				}
			case frameStdinClose:
				_ = stdin.Close()
			case frameSignal:
				if len(pl) >= 4 && cmd.Process != nil {
					sig := syscall.Signal(binary.BigEndian.Uint32(pl[:4]))
					_ = syscall.Kill(-cmd.Process.Pid, sig)
				}
			case frameSignResponse:
				if signRespCh != nil {
					select {
					case signRespCh <- signRelayResponse{flags: fl, payload: pl}:
					default:
					}
				}
			}
		}
	}()

	var stderrBytes int64
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_ = streamPipeToFrames(stdout, frameStdout, fw)
	}()
	go func() {
		defer wg.Done()
		stderrBytes = streamPipeToFrames(stderr, frameStderr, fw)
	}()
	wg.Wait()

	exitCode := 0
	werr := cmd.Wait()
	if werr != nil {
		if exitErr, ok := werr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
			if exitCode < 0 {
				if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
					exitCode = 128 + int(ws.Signal())
				} else {
					exitCode = 1
				}
			}
		} else {
			exitCode = 1
		}
	}
	close(stopTelemetry)

	var exitFlags uint16
	var ev guestres.MemoryEvents
	if cgDir != "" {
		if evBytes, err := os.ReadFile(filepath.Join(cgDir, "memory.events")); err == nil {
			ev = guestres.ParseMemoryEvents(evBytes)
			if ev.OOMKilled() {
				exitFlags |= flagOOMKilled
			}
		}
		_ = os.Remove(cgDir)
	}
	if diag := guestres.FormatWaitDiagnostic(init.Argv[0], werr, stderrBytes, ev, reqMemMax); diag != "" {
		_ = fw.writeFrame(frameStderr, 0, []byte(diag))
	}

	sendExitFrame(fw, exitCode, exitFlags)
}

func streamPipeToFrames(r io.Reader, ftype uint8, fw *safeFrameWriter) int64 {
	var total int64
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			total += int64(n)
			_ = fw.writeFrame(ftype, 0, buf[:n])
		}
		if err != nil {
			return total
		}
	}
}

func sendExitFrame(fw *safeFrameWriter, code int, flags uint16) {
	var p [4]byte
	binary.BigEndian.PutUint32(p[:], uint32(int32(code)))
	_ = fw.writeFrame(frameExit, flags, p[:])
}

func openPTY() (*os.File, *os.File, error) {
	ptmx, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	var unlock int32 = 0
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), tiocsptlck, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		_ = ptmx.Close()
		return nil, nil, errno
	}
	var ptn uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), tiocgptn, uintptr(unsafe.Pointer(&ptn))); errno != 0 {
		_ = ptmx.Close()
		return nil, nil, errno
	}
	sname := fmt.Sprintf("/dev/pts/%d", ptn)
	pts, err := os.OpenFile(sname, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		_ = ptmx.Close()
		return nil, nil, err
	}
	return ptmx, pts, nil
}

func setPTYSize(ptmx *os.File, rows, cols uint16) {
	ws := winsize{Row: rows, Col: cols}
	_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), tiocswinsz, uintptr(unsafe.Pointer(&ws)))
}

func handleTerminalConn(conn *os.File) {
	defer conn.Close()
	fw := &safeFrameWriter{w: conn}

	ftype, _, payload, err := readFrame(conn)
	if err != nil || ftype != frameExecInit {
		return
	}

	var init execInit
	_ = json.Unmarshal(payload, &init)

	ptmx, pts, err := openPTY()
	if err != nil {
		_ = fw.writeFrame(frameError, 0, []byte("failed to allocate Linux PTY: "+err.Error()))
		sendExitFrame(fw, 1, 0)
		return
	}
	defer ptmx.Close()

	setPTYSize(ptmx, 24, 80)

	shell, shellArgs := guestres.TerminalShell(fileExists)

	cwd := waitForWorkspaceDir(init.Cwd)
	cmd := exec.Command(shell, shellArgs...)
	cmd.Dir = cwd
	cmd.Env = mergeGuestEnv(init.Env)
	cmd.Stdin = pts
	cmd.Stdout = pts
	cmd.Stderr = pts
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		Ctty:    0,
	}

	if err := cmd.Start(); err != nil {
		_ = pts.Close()
		_ = fw.writeFrame(frameError, 0, []byte("failed to start Linux shell: "+err.Error()))
		sendExitFrame(fw, 1, 0)
		return
	}
	_ = pts.Close()

	go func() {
		for {
			ft, _, pl, rerr := readFrame(conn)
			if rerr != nil {
				if cmd.Process != nil {
					_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGHUP)
				}
				return
			}
			switch ft {
			case frameStdin:
				if len(pl) > 0 {
					_, _ = ptmx.Write(pl)
				}
			case frameResize:
				if len(pl) >= 4 {
					rows := binary.BigEndian.Uint16(pl[0:2])
					cols := binary.BigEndian.Uint16(pl[2:4])
					if rows > 0 && cols > 0 {
						setPTYSize(ptmx, rows, cols)
					}
				}
			case frameSignal:
				if len(pl) >= 4 && cmd.Process != nil {
					sig := syscall.Signal(binary.BigEndian.Uint32(pl[:4]))
					_ = syscall.Kill(-cmd.Process.Pid, sig)
				}
			}
		}
	}()

	streamPipeToFrames(ptmx, frameStdout, fw)

	exitCode := 0
	if werr := cmd.Wait(); werr != nil {
		if exitErr, ok := werr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		}
	}
	sendExitFrame(fw, exitCode, 0)
}

func handlePortForwardConn(conn *os.File) {
	defer conn.Close()
	var mode [1]byte
	if _, err := io.ReadFull(conn, mode[:]); err != nil {
		return
	}
	switch mode[0] {
	case 0x01:
		if _, err := conn.Write([]byte{0x00}); err != nil {
			return
		}
		closed := make(chan struct{})
		go func() {
			_, _ = io.Copy(io.Discard, conn)
			close(closed)
		}()
		known := make(map[uint16]bool)
		ticker := time.NewTicker(1500 * time.Millisecond)
		defer ticker.Stop()
		for {
			current := scanListeningPorts()
			for p := range current {
				if !known[p] {
					known[p] = true
					pkt := []byte{0x01, byte(p >> 8), byte(p & 0xFF)}
					if _, err := conn.Write(pkt); err != nil {
						return
					}
				}
			}
			for p := range known {
				if !current[p] {
					delete(known, p)
					pkt := []byte{0x02, byte(p >> 8), byte(p & 0xFF)}
					if _, err := conn.Write(pkt); err != nil {
						return
					}
				}
			}
			select {
			case <-closed:
				return
			case <-ticker.C:
			}
		}
	case 0x02:
		var portBuf [2]byte
		if _, err := io.ReadFull(conn, portBuf[:]); err != nil {
			return
		}
		port := binary.BigEndian.Uint16(portBuf[:])
		target, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
		if err != nil {
			_, _ = conn.Write([]byte{0x01})
			return
		}
		defer target.Close()
		if _, err := conn.Write([]byte{0x00}); err != nil {
			return
		}
		done := make(chan struct{}, 2)
		go func() {
			_, _ = io.Copy(target, conn)
			done <- struct{}{}
		}()
		go func() {
			_, _ = io.Copy(conn, target)
			done <- struct{}{}
		}()
		<-done
	}
}

func scanListeningPorts() map[uint16]bool {
	ports := make(map[uint16]bool)
	for _, procFile := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		b, err := os.ReadFile(procFile)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(bytes.NewReader(b))
		first := true
		for sc.Scan() {
			if first {
				first = false
				continue
			}
			fields := strings.Fields(sc.Text())
			if len(fields) < 4 || fields[3] != "0A" {
				continue
			}
			parts := strings.Split(fields[1], ":")
			if len(parts) != 2 {
				continue
			}
			if p, err := strconv.ParseUint(parts[1], 16, 16); err == nil && p > 0 {
				ports[uint16(p)] = true
			}
		}
	}
	return ports
}

func handleDAPConn(conn *os.File) {
	defer conn.Close()

	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return
	}
	addr := l.Addr().String()
	_ = l.Close()

	dlvBin := resolveBinary("dlv")
	cmd := exec.Command(dlvBin, "dap", "--listen="+addr)
	cmd.Dir = "/workspaces"
	cmd.Env = mergeGuestEnv(nil)
	if err := cmd.Start(); err != nil {
		return
	}
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	var dapConn net.Conn
	for i := 0; i < 40; i++ {
		dapConn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if dapConn == nil {
		return
	}
	defer dapConn.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(dapConn, conn)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(conn, dapConn)
		done <- struct{}{}
	}()
	<-done
}

func streamProcessTelemetry(pid int, interval time.Duration, stop <-chan struct{}, fw *safeFrameWriter) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if payload, err := kerneltelemetry.CollectJSON("/proc", pid, time.Now()); err == nil {
				_ = fw.writeFrame(frameKernelTelemetry, 0, payload)
			}
		}
	}
}
