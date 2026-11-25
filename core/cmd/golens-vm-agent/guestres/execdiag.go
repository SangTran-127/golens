package guestres

import (
	"bufio"
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

type MemoryEvents struct {
	Low          uint64
	High         uint64
	Max          uint64
	OOM          uint64
	OOMKill      uint64
	OOMGroupKill uint64
}

func ParseMemoryEvents(raw []byte) MemoryEvents {
	var ev MemoryEvents
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			continue
		}
		v, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch fields[0] {
		case "low":
			ev.Low = v
		case "high":
			ev.High = v
		case "max":
			ev.Max = v
		case "oom":
			ev.OOM = v
		case "oom_kill":
			ev.OOMKill = v
		case "oom_group_kill":
			ev.OOMGroupKill = v
		}
	}
	return ev
}

func (e MemoryEvents) OOMKilled() bool {
	return e.OOMKill > 0 || e.OOMGroupKill > 0
}

func (e MemoryEvents) Summary() string {
	var parts []string
	if e.OOMKill > 0 {
		parts = append(parts, fmt.Sprintf("oom_kill=%d", e.OOMKill))
	}
	if e.OOMGroupKill > 0 {
		parts = append(parts, fmt.Sprintf("oom_group_kill=%d", e.OOMGroupKill))
	}
	if e.OOM > 0 {
		parts = append(parts, fmt.Sprintf("oom=%d", e.OOM))
	}
	if e.Max > 0 {
		parts = append(parts, fmt.Sprintf("max=%d", e.Max))
	}
	if e.High > 0 {
		parts = append(parts, fmt.Sprintf("high=%d", e.High))
	}
	return strings.Join(parts, ", ")
}

func formatCgroupSuffix(ev MemoryEvents, memoryMax uint64) string {
	var parts []string
	if memoryMax > 0 {
		parts = append(parts, fmt.Sprintf("memory.max=%d", memoryMax))
	}
	if sum := ev.Summary(); sum != "" {
		parts = append(parts, sum)
	}
	if len(parts) == 0 {
		return ""
	}
	return " [cgroup " + strings.Join(parts, ", ") + "]"
}

func errText(err error) string {
	if err == nil {
		return "unknown error"
	}
	s := strings.TrimSpace(err.Error())
	if s == "" {
		return "unknown error"
	}
	return s
}

func FormatCgroupSetupDiagnostic(argv0 string, err error) string {
	return fmt.Sprintf("golens-vm-agent: failed to prepare cgroup for %q: %s\n", argv0, errText(err))
}

func FormatPipeDiagnostic(argv0, pipeName string, err error) string {
	return fmt.Sprintf("golens-vm-agent: failed to open %s pipe for %q: %s\n", pipeName, argv0, errText(err))
}

func FormatStartDiagnostic(argv0 string, err error, ev MemoryEvents, memoryMax uint64) string {
	return fmt.Sprintf("golens-vm-agent: failed to start %q: %s%s\n", argv0, errText(err), formatCgroupSuffix(ev, memoryMax))
}

func FormatWaitDiagnostic(argv0 string, waitErr error, stderrBytes int64, ev MemoryEvents, memoryMax uint64) string {
	if stderrBytes > 0 {
		return ""
	}
	if ev.OOMKilled() {
		if waitErr != nil {
			return fmt.Sprintf("golens-vm-agent: process %q terminated by cgroup OOM killer (%s)%s\n", argv0, errText(waitErr), formatCgroupSuffix(ev, memoryMax))
		}
		return fmt.Sprintf("golens-vm-agent: process %q terminated by cgroup OOM killer%s\n", argv0, formatCgroupSuffix(ev, memoryMax))
	}
	if waitErr != nil {
		return fmt.Sprintf("golens-vm-agent: process %q exited without stderr: %s%s\n", argv0, errText(waitErr), formatCgroupSuffix(ev, memoryMax))
	}
	return ""
}
