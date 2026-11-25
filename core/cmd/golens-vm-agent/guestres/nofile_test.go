package guestres

import (
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestNoFileTargetHonoursKernelCeiling(t *testing.T) {
	cases := []struct {
		in   string
		want uint64
	}{
		{"1048576\n", 1 << 20},
		{"65536\n", 65536},
		{"4194304", 1 << 20},
		{"", GuestNoFileTarget},
		{"garbage", GuestNoFileTarget},
	}
	for _, c := range cases {
		if got := NoFileTarget([]byte(c.in)); got != c.want {
			t.Errorf("NoFileTarget(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestRaiseNoFileIsInheritedByChildren(t *testing.T) {
	var orig syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &orig); err != nil {
		t.Skip(err)
	}
	if orig.Max < 5000 {
		t.Skipf("hard limit %d too low", orig.Max)
	}
	t.Cleanup(func() { _ = syscall.Setrlimit(syscall.RLIMIT_NOFILE, &orig) })
	low := syscall.Rlimit{Cur: 4000, Max: orig.Max}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &low); err != nil {
		t.Skip(err)
	}
	got, err := RaiseNoFile(5000)
	if err != nil {
		t.Fatal(err)
	}
	if got.Cur != 5000 || got.Max != orig.Max {
		t.Fatalf("RaiseNoFile = %+v, want cur 5000 max %d", got, orig.Max)
	}
	out, err := exec.Command("/bin/sh", "-c", "ulimit -n").Output()
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64); n != 5000 {
		t.Fatalf("child sees RLIMIT_NOFILE %q, want 5000", strings.TrimSpace(string(out)))
	}
}
