package guestres

import (
	"strconv"
	"strings"
	"syscall"
)

const GuestNoFileTarget uint64 = 1 << 20

func NoFileTarget(nrOpen []byte) uint64 {
	v, err := strconv.ParseUint(strings.TrimSpace(string(nrOpen)), 10, 64)
	if err != nil || v == 0 {
		return GuestNoFileTarget
	}
	return min(v, GuestNoFileTarget)
}

func RaiseNoFile(target uint64) (syscall.Rlimit, error) {
	var cur syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &cur); err != nil {
		return cur, err
	}
	want := syscall.Rlimit{Cur: max(cur.Cur, target), Max: max(cur.Max, target)}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &want); err != nil {
		want = syscall.Rlimit{Cur: cur.Max, Max: cur.Max}
		if err2 := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &want); err2 != nil {
			return cur, err
		}
	}
	var got syscall.Rlimit
	err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &got)
	return got, err
}
