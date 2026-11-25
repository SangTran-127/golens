//go:build linux && arm64

package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"unsafe"

	"golens/core/cmd/golens-vm-agent/guestres"
)

const sandboxSetupExitCode = 125

func sandboxCommand(init execInit, bin string) *exec.Cmd {
	spec := guestres.SandboxSpec{
		ReadOnly:     init.ReadOnlyWorkspace,
		LoopbackOnly: init.LoopbackOnlyNetwork,
		Path:         bin,
		Argv:         init.Argv,
	}
	if !spec.Active() {
		cmd := exec.Command(bin, init.Argv[1:]...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		return cmd
	}
	self, err := os.Executable()
	if err != nil {
		self = "/sbin/init"
	}
	args := guestres.SandboxExecArgs(spec)
	cmd := &exec.Cmd{Path: self, Args: args}
	attr := &syscall.SysProcAttr{Setpgid: true}
	if spec.ReadOnly {
		attr.Cloneflags |= syscall.CLONE_NEWNS
	}
	if spec.LoopbackOnly {
		attr.Cloneflags |= syscall.CLONE_NEWNET
	}
	cmd.SysProcAttr = attr
	return cmd
}

func runSandboxExec(args []string) int {
	spec, err := guestres.ParseSandboxExecArgs(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "golens sandbox: %v\n", err)
		return sandboxSetupExitCode
	}
	if spec.ReadOnly {
		if err := remountReadOnly(guestres.SandboxReadOnlyPaths); err != nil {
			fmt.Fprintf(os.Stderr, "golens sandbox: could not make the workspace read-only: %v\n", err)
			return sandboxSetupExitCode
		}
	}
	if spec.LoopbackOnly {
		if err := bringLoopbackUp(); err != nil {
			fmt.Fprintf(os.Stderr, "golens sandbox: could not start the loopback network: %v\n", err)
			return sandboxSetupExitCode
		}
	}
	err = syscall.Exec(spec.Path, spec.Argv, os.Environ())
	fmt.Fprintf(os.Stderr, "golens sandbox: exec %s: %v\n", spec.Path, err)
	return sandboxSetupExitCode
}

func remountReadOnly(paths []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	if err := syscall.Mount("", "/", "", syscall.MS_REC|syscall.MS_PRIVATE, ""); err != nil {
		return fmt.Errorf("private mounts: %w", err)
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			continue
		}
		if err := syscall.Mount(p, p, "", syscall.MS_BIND|syscall.MS_REC, ""); err != nil {
			return fmt.Errorf("bind %s: %w", p, err)
		}
		if err := syscall.Mount("", p, "", syscall.MS_BIND|syscall.MS_REMOUNT|syscall.MS_RDONLY, ""); err != nil {
			return fmt.Errorf("remount %s read-only: %w", p, err)
		}
	}
	return syscall.Chdir(cwd)
}

func bringLoopbackUp() error {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var req struct {
		name  [syscall.IFNAMSIZ]byte
		flags uint16
		_     [22]byte
	}
	copy(req.name[:], "lo")
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCGIFFLAGS, uintptr(unsafe.Pointer(&req))); errno != 0 {
		return errno
	}
	req.flags |= syscall.IFF_UP
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCSIFFLAGS, uintptr(unsafe.Pointer(&req))); errno != 0 {
		return errno
	}
	return nil
}
