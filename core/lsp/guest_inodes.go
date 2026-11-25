package lsp

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

const (
	guestInodeHeadroom      = 8192
	guestInodeCheckInterval = "0.5"
	guestInodeNrPath        = "/proc/sys/fs/inode-nr"
	guestDropCachesPath     = "/proc/sys/vm/drop_caches"
	guestReclaimUnsupported = 3
	guestReclaimRetry       = 5 * time.Second
	guestReclaimReportEvery = time.Minute
)

func guestInodeReclaimScript(headroom int, interval, inodeNr, dropCaches string) string {
	return fmt.Sprintf(`inodes=%s
drop=%s
if [ ! -r "$inodes" ] || [ ! -w "$drop" ]; then echo "cannot read $inodes or write $drop"; exit %d; fi
floor=0
while :; do
	read n _ < "$inodes"
	if [ "$n" -gt $((floor + %d)) ]; then
		echo 2 > "$drop"
		read floor _ < "$inodes"
		echo "drop $n $floor"
	fi
	sleep %s || exit 1
done`, shellQuote(inodeNr), shellQuote(dropCaches), guestReclaimUnsupported, headroom, interval)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

type reclaimLog struct {
	mu       sync.Mutex
	buf      []byte
	drops    int
	before   int
	after    int
	since    time.Time
	reported time.Time
	report   func(string)
	now      func() time.Time
}

func (l *reclaimLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.buf = append(l.buf, p...)
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		l.line(string(l.buf[:i]))
		l.buf = l.buf[i+1:]
	}
	return len(p), nil
}

func (l *reclaimLog) line(s string) {
	f := strings.Fields(s)
	if len(f) != 3 || f[0] != "drop" {
		if s = strings.TrimSpace(s); s != "" {
			l.report("guest inode reclaim: " + s)
		}
		return
	}
	now := l.now()
	if l.drops == 0 {
		l.since = now
	}
	l.drops++
	l.before, _ = strconv.Atoi(f[1])
	l.after, _ = strconv.Atoi(f[2])
	if l.reported.IsZero() || now.Sub(l.reported) >= guestReclaimReportEvery {
		l.report(fmt.Sprintf("guest inode reclaim: %d drops in %s, last %d -> %d inodes", l.drops, now.Sub(l.since).Round(time.Second), l.before, l.after))
		l.reported = now
		l.drops = 0
	}
}

var guestReclaim struct {
	mu      sync.Mutex
	running bool
}

func ensureGuestInodeReclaimer() {
	guestReclaim.mu.Lock()
	defer guestReclaim.mu.Unlock()
	if guestReclaim.running {
		return
	}
	guestReclaim.running = true
	go superviseGuestInodeReclaim(isCurrentRemote, runGuestInodeReclaim, bridge.Debug, guestReclaimRetry)
}

var errGuestReclaimUnsupported = errors.New("guest cannot drop caches")

func superviseGuestInodeReclaim(stillRemote func() bool, run func() error, report func(string), retry time.Duration) {
	defer func() {
		guestReclaim.mu.Lock()
		guestReclaim.running = false
		guestReclaim.mu.Unlock()
	}()
	last := ""
	for {
		err := run()
		msg := "guest inode reclaim stopped"
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

func runGuestInodeReclaim() error {
	cmd := vmexec.CommandContext(context.Background(), "sh", "-c", guestInodeReclaimScript(guestInodeHeadroom, guestInodeCheckInterval, guestInodeNrPath, guestDropCachesPath))
	cmd.Dir = "/"
	cmd.DialTimeout = 5 * time.Second
	out := &reclaimLog{report: bridge.Debug, now: time.Now}
	cmd.Stdout = out
	cmd.Stderr = out
	if err := cmd.Start(); err != nil {
		return err
	}
	bridge.Debug(fmt.Sprintf("guest inode reclaim running (drops dentries %d inodes above the post-drop floor, every %ss)", guestInodeHeadroom, guestInodeCheckInterval))
	err := cmd.Wait()
	var exit *vmexec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == guestReclaimUnsupported {
		return errGuestReclaimUnsupported
	}
	return err
}
