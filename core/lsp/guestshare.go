package lsp

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"time"

	"golens/core/vmexec"
)

type guestProbeResult int

const (
	guestDirVisible guestProbeResult = iota
	guestDirMissing
	guestProbeUnavailable
)

var errWorkspaceNotVisible = errors.New("the project folder is not visible inside the Linux VM yet")

const (
	shareWaitBudget   = 15 * time.Second
	shareRetryInitial = 100 * time.Millisecond
	shareRetryMax     = 2 * time.Second
)

type shareWaiter struct {
	probe  func(ctx context.Context, dir string) guestProbeResult
	sleep  func(ctx context.Context, d time.Duration) bool
	now    func() time.Time
	budget time.Duration
}

var newShareWaiter = func() shareWaiter {
	return shareWaiter{probe: probeGuestDir, sleep: sleepCtx, now: time.Now, budget: shareWaitBudget}
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func probeGuestDir(ctx context.Context, dir string) guestProbeResult {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	cmd := vmexec.CommandContext(ctx, "ls", "-A", "--", dir)
	cmd.Dir = "/"
	cmd.DialTimeout = 2 * time.Second
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return guestDirVisible
	}
	var exitErr *vmexec.ExitError
	if !errors.As(err, &exitErr) {
		return guestProbeUnavailable
	}
	msg := stderr.String() + exitErr.Error()
	if strings.Contains(msg, "fork/exec") || strings.Contains(msg, "executable file not found") {
		return guestProbeUnavailable
	}
	return guestDirMissing
}

func (w shareWaiter) wait(ctx context.Context, slugs []string) (string, error) {
	if len(slugs) == 0 {
		return "", errWorkspaceNotVisible
	}
	deadline := w.now().Add(w.budget)
	delay := shareRetryInitial
	for {
		unavailable := 0
		for _, slug := range slugs {
			switch w.probe(ctx, vmexec.GuestWorkspacesRoot+"/"+slug) {
			case guestDirVisible:
				return slug, nil
			case guestProbeUnavailable:
				unavailable++
			}
		}
		if unavailable == len(slugs) {
			return slugs[0], nil
		}
		remaining := deadline.Sub(w.now())
		if remaining <= 0 {
			return "", errWorkspaceNotVisible
		}
		if !w.sleep(ctx, min(delay, remaining)) {
			return "", ctx.Err()
		}
		delay = min(delay*2, shareRetryMax)
	}
}
