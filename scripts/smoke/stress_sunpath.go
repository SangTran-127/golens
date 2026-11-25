package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	fmt.Println("Running UNIX Domain Socket sun_path Length Limit Empirical Test...")

	tmpDir, err := os.MkdirTemp("", "sunpath_stress_")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create tmpDir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpDir)

	// Darwin kernel limits sockaddr_un.sun_path to 104 bytes (including null terminator).
	// That means the maximum path string length is 103 bytes.
	// Let us empirically verify boundary conditions: lengths 102, 103, 104, 105, 108.

	for _, targetLen := range []int{50, 80, 102, 103, 104, 105, 108, 120} {
		var sockPath string
		if len(tmpDir)+1 >= targetLen {
			sockPath = tmpDir[:targetLen]
		} else {
			filler := strings.Repeat("a", targetLen-len(tmpDir)-1)
			sockPath = filepath.Join(tmpDir, filler)
		}

		actualLen := len(sockPath)
		_ = os.Remove(sockPath)

		l, err := net.Listen("unix", sockPath)
		if err != nil {
			fmt.Printf("Length %3d: LISTEN FAILED (expected if >= 104): %v\n", actualLen, err)
			if actualLen < 104 {
				fmt.Printf("FAIL: Listen failed prematurely at length %d: %v\n", actualLen, err)
				os.Exit(1)
			}
		} else {
			_ = l.Close()
			_ = os.Remove(sockPath)
			fmt.Printf("Length %3d: LISTEN SUCCEEDED\n", actualLen)
			if actualLen >= 104 {
				fmt.Printf("WARNING: Listen succeeded at length %d >= 104\n", actualLen)
			}
		}
	}

	// Now check Darwin sockaddr_un C struct size
	var raw syscall.RawSockaddrUnix
	fmt.Printf("\nDarwin RawSockaddrUnix Path length in syscall: %d bytes\n", len(raw.Path))
	if len(raw.Path) != 104 {
		fmt.Printf("WARNING: Darwin RawSockaddrUnix Path is %d, expected 104\n", len(raw.Path))
	} else {
		fmt.Println("CONFIRMED: Darwin RawSockaddrUnix.Path is exactly 104 bytes.")
	}

	// Check container tmp path length in GoLens
	// In App Sandbox: $HOME/Library/Containers/dev.golens.app/Data/tmp
	home, _ := os.UserHomeDir()
	stdContainerTmp := filepath.Join(home, "Library/Containers/dev.golens.app/Data/tmp")
	stdSock := filepath.Join(stdContainerTmp, "vsock_2002.sock")
	fmt.Printf("\nStandard App Sandbox socket path: %s\n", stdSock)
	fmt.Printf("Standard App Sandbox socket length: %d bytes\n", len(stdSock))

	if len(stdSock) >= 104 {
		fmt.Printf("CRITICAL HAZARD: Standard container socket path (%d bytes) exceeds Darwin 104-byte limit!\n", len(stdSock))
	} else {
		headroom := 103 - len(stdSock)
		fmt.Printf("PASS: Standard container socket path fits with %d bytes of headroom for home directory.\n", headroom)
		if headroom < 15 {
			fmt.Printf("NOTE: High-depth home paths (> %d chars) risk hitting sun_path limit!\n", len(home)+headroom)
		}
	}

	fmt.Println("\nEMPIRICAL SUN_PATH VERIFICATION COMPLETE.")
}
