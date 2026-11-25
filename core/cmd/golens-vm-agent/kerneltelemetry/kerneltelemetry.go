package kerneltelemetry

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Report struct {
	PID        int32       `json:"pid"`
	TargetName string      `json:"targetName"`
	OpenFDs    OpenFDs     `json:"openFDs"`
	TCPSockets []TCPSocket `json:"tcpSockets"`
	PSI        *PSI        `json:"psi,omitempty"`
	Timestamp  string      `json:"timestamp"`
}

type OpenFDs struct {
	Count   int       `json:"count"`
	Limit   int       `json:"limit"`
	Entries []FDEntry `json:"entries"`
}

type FDEntry struct {
	FD     int    `json:"fd"`
	Target string `json:"target"`
	Kind   string `json:"kind"`
}

type TCPSocket struct {
	LocalAddress  string `json:"localAddress"`
	LocalPort     int    `json:"localPort"`
	RemoteAddress string `json:"remoteAddress"`
	RemotePort    int    `json:"remotePort"`
	State         string `json:"state"`
	Inode         uint64 `json:"inode"`
	RxQueue       uint64 `json:"rxQueue"`
	TxQueue       uint64 `json:"txQueue"`
}

type PSI struct {
	Memory PSIResource `json:"memory"`
	CPU    PSIResource `json:"cpu"`
	IO     PSIResource `json:"io"`
}

type PSIResource struct {
	SomePressure PSIValues  `json:"somePressure"`
	FullPressure *PSIValues `json:"fullPressure,omitempty"`
}

type PSIValues struct {
	Avg10       float64 `json:"avg10"`
	Avg60       float64 `json:"avg60"`
	Avg300      float64 `json:"avg300"`
	TotalMicros uint64  `json:"totalMicros"`
}

const defaultFDLimit = 1024

func FormatTimestamp(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

func ParseHexIPv4(hexStr string) (string, error) {
	if len(hexStr) != 8 {
		return "", fmt.Errorf("invalid hex IPv4 length: %s", hexStr)
	}
	val, err := strconv.ParseUint(hexStr, 16, 32)
	if err != nil {
		return "", err
	}
	return net.IPv4(byte(val), byte(val>>8), byte(val>>16), byte(val>>24)).String(), nil
}

func ParseHexIPv6(hexStr string) (string, error) {
	if len(hexStr) != 32 {
		return "", fmt.Errorf("invalid hex IPv6 length: %s", hexStr)
	}
	ip := make(net.IP, net.IPv6len)
	for i := range 4 {
		word, err := strconv.ParseUint(hexStr[i*8:i*8+8], 16, 32)
		if err != nil {
			return "", err
		}
		binary.LittleEndian.PutUint32(ip[i*4:], uint32(word))
	}
	return ip.String(), nil
}

func ParseHexAddress(hexStr string) (string, error) {
	if len(hexStr) == 32 {
		return ParseHexIPv6(hexStr)
	}
	return ParseHexIPv4(hexStr)
}

func ParseHexPort(hexStr string) (int, error) {
	port, err := strconv.ParseUint(hexStr, 16, 16)
	if err != nil {
		return 0, err
	}
	return int(port), nil
}

var tcpStates = map[string]string{
	"01": "ESTABLISHED",
	"02": "SYN_SENT",
	"03": "SYN_RECV",
	"04": "FIN_WAIT1",
	"05": "FIN_WAIT2",
	"06": "TIME_WAIT",
	"07": "CLOSE",
	"08": "CLOSE_WAIT",
	"09": "LAST_ACK",
	"0A": "LISTEN",
	"0B": "CLOSING",
}

func MapTCPState(code string) string {
	if state, ok := tcpStates[strings.ToUpper(code)]; ok {
		return state
	}
	return "UNKNOWN"
}

func ParsePSIString(content string) (some *PSIValues, full *PSIValues, err error) {
	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		parts := strings.Fields(scanner.Text())
		if len(parts) < 5 {
			continue
		}
		var parsed PSIValues
		for _, part := range parts[1:] {
			key, value, ok := strings.Cut(part, "=")
			if !ok {
				continue
			}
			switch key {
			case "avg10":
				parsed.Avg10, _ = strconv.ParseFloat(value, 64)
			case "avg60":
				parsed.Avg60, _ = strconv.ParseFloat(value, 64)
			case "avg300":
				parsed.Avg300, _ = strconv.ParseFloat(value, 64)
			case "total":
				parsed.TotalMicros, _ = strconv.ParseUint(value, 10, 64)
			}
		}
		switch parts[0] {
		case "some":
			some = &parsed
		case "full":
			full = &parsed
		}
	}
	return some, full, scanner.Err()
}

func ParseTCPTable(r io.Reader, socketInodes map[uint64]bool) ([]TCPSocket, error) {
	sockets := []TCPSocket{}
	scanner := bufio.NewScanner(r)
	isHeader := true
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if isHeader {
			isHeader = false
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}
		localHex, localPortHex, ok1 := strings.Cut(fields[1], ":")
		remHex, remPortHex, ok2 := strings.Cut(fields[2], ":")
		if !ok1 || !ok2 {
			continue
		}
		localIP, err := ParseHexAddress(localHex)
		if err != nil {
			continue
		}
		localPort, err := ParseHexPort(localPortHex)
		if err != nil {
			continue
		}
		remIP, err := ParseHexAddress(remHex)
		if err != nil {
			continue
		}
		remPort, err := ParseHexPort(remPortHex)
		if err != nil {
			continue
		}
		inode, _ := strconv.ParseUint(fields[9], 10, 64)
		if socketInodes != nil && !socketInodes[inode] {
			continue
		}
		var txQueue, rxQueue uint64
		if tx, rx, ok := strings.Cut(fields[4], ":"); ok {
			txQueue, _ = strconv.ParseUint(tx, 16, 64)
			rxQueue, _ = strconv.ParseUint(rx, 16, 64)
		}
		sockets = append(sockets, TCPSocket{
			LocalAddress:  localIP,
			LocalPort:     localPort,
			RemoteAddress: remIP,
			RemotePort:    remPort,
			State:         MapTCPState(fields[3]),
			Inode:         inode,
			RxQueue:       rxQueue,
			TxQueue:       txQueue,
		})
	}
	return sockets, scanner.Err()
}

func ClassifyFDKind(target string) string {
	switch {
	case strings.HasPrefix(target, "socket:["):
		return "socket"
	case strings.HasPrefix(target, "pipe:["):
		return "pipe"
	case strings.HasPrefix(target, "/dev/"):
		return "character"
	case strings.HasPrefix(target, "anon_inode:"):
		return "anonInode"
	case strings.HasPrefix(target, "/"):
		return "file"
	default:
		return "other"
	}
}

func ParseFDDirectory(fdPath string) (OpenFDs, map[uint64]bool, error) {
	socketInodes := map[uint64]bool{}
	entries, err := os.ReadDir(fdPath)
	if err != nil {
		return OpenFDs{Limit: defaultFDLimit, Entries: []FDEntry{}}, socketInodes, err
	}
	fdEntries := []FDEntry{}
	for _, entry := range entries {
		fdNum, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		target, err := os.Readlink(filepath.Join(fdPath, entry.Name()))
		if err != nil {
			continue
		}
		kind := ClassifyFDKind(target)
		if kind == "socket" {
			var inode uint64
			if n, _ := fmt.Sscanf(target, "socket:[%d]", &inode); n == 1 {
				socketInodes[inode] = true
			}
		}
		fdEntries = append(fdEntries, FDEntry{FD: fdNum, Target: target, Kind: kind})
	}
	return OpenFDs{
		Count:   len(fdEntries),
		Limit:   parseFDLimit(filepath.Join(filepath.Dir(fdPath), "limits")),
		Entries: fdEntries,
	}, socketInodes, nil
}

func parseFDLimit(limitsPath string) int {
	data, err := os.ReadFile(limitsPath)
	if err != nil {
		return defaultFDLimit
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		if !strings.HasPrefix(line, "Max open files") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 5 {
			if l, err := strconv.Atoi(fields[3]); err == nil && l > 0 {
				return l
			}
		}
		break
	}
	return defaultFDLimit
}

type procStat struct {
	comm      string
	ppid      int
	startTime uint64
}

func parseProcStat(data string) (procStat, bool) {
	open := strings.IndexByte(data, '(')
	closeIdx := strings.LastIndexByte(data, ')')
	if open < 0 || closeIdx < open {
		return procStat{}, false
	}
	fields := strings.Fields(data[closeIdx+1:])
	if len(fields) < 20 {
		return procStat{}, false
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return procStat{}, false
	}
	start, _ := strconv.ParseUint(fields[19], 10, 64)
	return procStat{comm: data[open+1 : closeIdx], ppid: ppid, startTime: start}, true
}

var buildTools = map[string]bool{
	"asm": true, "buildid": true, "cgo": true, "compile": true, "cover": true, "link": true, "pack": true, "vet": true,
	"ar": true, "cc": true, "c++": true, "gcc": true, "g++": true, "clang": true, "clang++": true,
}

func ResolveTarget(procRoot string, pid int) (int, string) {
	stats := map[int]procStat{}
	entries, _ := os.ReadDir(procRoot)
	for _, entry := range entries {
		n, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join(procRoot, entry.Name(), "stat"))
		if err != nil {
			continue
		}
		if st, ok := parseProcStat(string(data)); ok {
			stats[n] = st
		}
	}
	current := pid
	for stats[current].comm == "go" {
		next, newest := 0, uint64(0)
		for child, st := range stats {
			if st.ppid == current && !buildTools[st.comm] && (next == 0 || st.startTime > newest || (st.startTime == newest && child > next)) {
				next, newest = child, st.startTime
			}
		}
		if next == 0 {
			break
		}
		current = next
	}
	return current, stats[current].comm
}

func readPSI(path string) (PSIResource, bool) {
	var resource PSIResource
	data, err := os.ReadFile(path)
	if err != nil {
		return resource, false
	}
	some, full, _ := ParsePSIString(string(data))
	if some != nil {
		resource.SomePressure = *some
	}
	resource.FullPressure = full
	return resource, true
}

func ReadPressure(pressureDir string) *PSI {
	memory, okMemory := readPSI(filepath.Join(pressureDir, "memory"))
	cpu, okCPU := readPSI(filepath.Join(pressureDir, "cpu"))
	ioPressure, okIO := readPSI(filepath.Join(pressureDir, "io"))
	if !okMemory && !okCPU && !okIO {
		return nil
	}
	return &PSI{Memory: memory, CPU: cpu, IO: ioPressure}
}

func Collect(procRoot string, pid int, now time.Time) (Report, error) {
	target, name := ResolveTarget(procRoot, pid)
	procDir := filepath.Join(procRoot, strconv.Itoa(target))
	if _, err := os.Stat(procDir); err != nil {
		return Report{}, err
	}
	fds, socketInodes, _ := ParseFDDirectory(filepath.Join(procDir, "fd"))
	sockets := []TCPSocket{}
	for _, table := range []string{"tcp", "tcp6"} {
		f, err := os.Open(filepath.Join(procDir, "net", table))
		if err != nil {
			continue
		}
		parsed, _ := ParseTCPTable(f, socketInodes)
		_ = f.Close()
		sockets = append(sockets, parsed...)
	}
	return Report{
		PID:        int32(target),
		TargetName: name,
		OpenFDs:    fds,
		TCPSockets: sockets,
		PSI:        ReadPressure(filepath.Join(procRoot, "pressure")),
		Timestamp:  FormatTimestamp(now),
	}, nil
}

func CollectJSON(procRoot string, pid int, now time.Time) ([]byte, error) {
	report, err := Collect(procRoot, pid, now)
	if err != nil {
		return nil, err
	}
	return json.Marshal(report)
}
