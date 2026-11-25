package lsp

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golens/core/bridge"
	"golens/core/cmd/golens-vm-agent/guestres"
	"golens/core/vmexec"
)

const (
	guestPressureOnPercent  = 85
	guestPressureOffPercent = 70
	guestPressureInterval   = "2"
	guestZramStatPath       = "/sys/block/zram0/mm_stat"
	guestLSPCgroup          = "/sys/fs/cgroup/golens/lsp"
)

var guestMemoryPressure atomic.Bool

func GuestMemoryPressure() bool { return guestMemoryPressure.Load() }

func guestPressureScript(statPath, meminfoPath, vmstatPath, cgroupDir, interval string) string {
	return fmt.Sprintf(`stat=%s
meminfo=%s
vmstat=%s
cg=%s
if [ ! -r "$stat" ]; then echo "cannot read $stat"; exit %d; fi
while :; do
	read orig compr used limit rest < "$stat"
	total=0
	while read key value unit; do
		if [ "$key" = MemTotal: ]; then total=$value; break; fi
	done < "$meminfo"
	balloon=0
	while read key value; do
		if [ "$key" = nr_balloon_pages ]; then balloon=$value; break; fi
	done < "$vmstat"
	cur=0
	swap=0
	if [ -r "$cg/memory.current" ]; then read cur < "$cg/memory.current"; fi
	if [ -r "$cg/memory.swap.current" ]; then read swap < "$cg/memory.swap.current"; fi
	echo "zram $used $limit $total $balloon $cur $swap"
	sleep %s || exit 1
done`, shellQuote(statPath), shellQuote(meminfoPath), shellQuote(vmstatPath), shellQuote(cgroupDir), guestReclaimUnsupported, interval)
}

type pressureTracker struct {
	mu     sync.Mutex
	buf    []byte
	on     bool
	set    func(bool)
	report func(string)
	sample func(guestres.MemorySample)
}

func (p *pressureTracker) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.buf = append(p.buf, b...)
	for {
		i := bytes.IndexByte(p.buf, '\n')
		if i < 0 {
			break
		}
		p.line(string(p.buf[:i]))
		p.buf = p.buf[i+1:]
	}
	return len(b), nil
}

func (p *pressureTracker) line(s string) {
	f := strings.Fields(s)
	if (len(f) != 3 && len(f) != 7) || f[0] != "zram" {
		if s = strings.TrimSpace(s); s != "" {
			p.report("guest memory watch: " + s)
		}
		return
	}
	used, err1 := strconv.ParseInt(f[1], 10, 64)
	limit, err2 := strconv.ParseInt(f[2], 10, 64)
	if err1 != nil || err2 != nil || used < 0 || limit < 0 {
		return
	}
	if len(f) == 7 && p.sample != nil {
		if sample, ok := parseGuestMemorySample(f[3:], used, limit); ok {
			p.sample(sample)
		}
	}
	if limit == 0 {
		return
	}
	percent := used * 100 / limit
	switch {
	case !p.on && percent >= guestPressureOnPercent:
		p.on = true
		p.set(true)
		p.report(fmt.Sprintf("guest swap pool %d%% full (%d of %d MiB): pausing background usage queries to gopls", percent, used>>20, limit>>20))
	case p.on && percent < guestPressureOffPercent:
		p.on = false
		p.set(false)
		p.report(fmt.Sprintf("guest swap pool %d%% full: resuming background usage queries", percent))
	}
}

var guestPressureWatch struct {
	mu      sync.Mutex
	running bool
}

func ensureGuestPressureWatcher() {
	guestPressureWatch.mu.Lock()
	defer guestPressureWatch.mu.Unlock()
	if guestPressureWatch.running {
		return
	}
	guestPressureWatch.running = true
	go superviseGuestPressure(isCurrentRemote, runGuestPressureWatch, bridge.Debug, guestReclaimRetry)
}

func superviseGuestPressure(stillRemote func() bool, run func() error, report func(string), retry time.Duration) {
	defer func() {
		guestMemoryPressure.Store(false)
		guestPressureWatch.mu.Lock()
		guestPressureWatch.running = false
		guestPressureWatch.mu.Unlock()
	}()
	last := ""
	for {
		err := run()
		guestMemoryPressure.Store(false)
		msg := "guest memory watch stopped"
		if err != nil {
			msg += ": " + err.Error()
		}
		if msg != last {
			report(msg)
			last = msg
		}
		if errors.Is(err, errGuestReclaimUnsupported) {
			return
		}
		time.Sleep(retry)
		if !stillRemote() {
			return
		}
	}
}

func runGuestPressureWatch() error {
	cmd := vmexec.CommandContext(context.Background(), "sh", "-c", guestPressureScript(guestZramStatPath, "/proc/meminfo", "/proc/vmstat", guestLSPCgroup, guestPressureInterval))
	cmd.Dir = "/"
	cmd.DialTimeout = 5 * time.Second
	out := &pressureTracker{set: guestMemoryPressure.Store, report: bridge.Debug, sample: recordGuestMemory}
	cmd.Stdout = out
	cmd.Stderr = out
	if err := cmd.Start(); err != nil {
		return err
	}
	err := cmd.Wait()
	var exit *vmexec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == guestReclaimUnsupported {
		return errGuestReclaimUnsupported
	}
	return err
}
