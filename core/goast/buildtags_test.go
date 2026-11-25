package goast

import (
	"encoding/json"
	"runtime"
	"strings"
	"testing"

	"golens/core/bridge"
)

func checkTarget(t *testing.T, filePath, content, goos, goarch, tagsCSV string) BuildTargetStatus {
	t.Helper()
	raw, err := CheckBuildTarget(filePath, content, goos, goarch, tagsCSV)
	if err != nil {
		t.Fatalf("CheckBuildTarget returned error: %v", err)
	}
	var st BuildTargetStatus
	if uerr := json.Unmarshal([]byte(raw), &st); uerr != nil {
		t.Fatalf("failed to unmarshal %q: %v", raw, uerr)
	}
	return st
}

func TestCheckBuildTargetGoBuildLinux(t *testing.T) {
	src := "//go:build linux\n\npackage main\n"
	st := checkTarget(t, "/workspace/epoll.go", src, "darwin", "arm64", "")
	if !st.Excluded {
		t.Fatalf("expected epoll.go to be excluded on darwin/arm64, got %+v", st)
	}
	if !strings.Contains(st.Reason, "Excluded by build constraint (//go:build linux) for target darwin/arm64") {
		t.Fatalf("unexpected reason: %q", st.Reason)
	}

	stLinux := checkTarget(t, "/workspace/epoll.go", src, "linux", "amd64", "")
	if stLinux.Excluded {
		t.Fatalf("expected epoll.go to be included on linux/amd64, got %+v", stLinux)
	}
}

func TestCheckBuildTargetGoBuildDarwinAndIntegration(t *testing.T) {
	src := "//go:build darwin && integration\n\npackage main\n"
	stWithoutTag := checkTarget(t, "/workspace/db_test.go", src, "darwin", "arm64", "")
	if !stWithoutTag.Excluded {
		t.Fatalf("expected exclusion when integration tag is absent: %+v", stWithoutTag)
	}
	if !strings.Contains(stWithoutTag.Reason, "//go:build darwin && integration") {
		t.Fatalf("unexpected reason: %q", stWithoutTag.Reason)
	}

	stWithTag := checkTarget(t, "/workspace/db_test.go", src, "darwin", "arm64", "integration,e2e")
	if stWithTag.Excluded {
		t.Fatalf("expected inclusion when integration tag is active: %+v", stWithTag)
	}
	if stWithTag.Tags != "integration,e2e" {
		t.Fatalf("expected tags 'integration,e2e', got %q", stWithTag.Tags)
	}
}

func TestCheckBuildTargetFilenameSuffixes(t *testing.T) {
	src := "package sys\n"

	stWin := checkTarget(t, "/workspace/sys_windows.go", src, "darwin", "arm64", "")
	if !stWin.Excluded || !strings.Contains(stWin.Reason, "Excluded by filename suffix (sys_windows.go) for target darwin/arm64") {
		t.Fatalf("expected sys_windows.go excluded on darwin/arm64, got %+v", stWin)
	}

	stWinIncluded := checkTarget(t, "/workspace/sys_windows.go", src, "windows", "amd64", "")
	if stWinIncluded.Excluded {
		t.Fatalf("expected sys_windows.go included on windows/amd64, got %+v", stWinIncluded)
	}

	stDarwinArm := checkTarget(t, "/workspace/simd_darwin_arm64.go", src, "darwin", "arm64", "")
	if stDarwinArm.Excluded {
		t.Fatalf("expected simd_darwin_arm64.go included on darwin/arm64, got %+v", stDarwinArm)
	}

	stDarwinAmd := checkTarget(t, "/workspace/simd_darwin_arm64.go", src, "darwin", "amd64", "")
	if !stDarwinAmd.Excluded || !strings.Contains(stDarwinAmd.Reason, "Excluded by filename suffix (simd_darwin_arm64.go) for target darwin/amd64") {
		t.Fatalf("expected simd_darwin_arm64.go excluded on darwin/amd64, got %+v", stDarwinAmd)
	}
}

func TestCheckBuildTargetNormalIncludedAndUnix(t *testing.T) {
	src := "//go:build unix && go1.22\n\npackage main\n"
	st := checkTarget(t, "/workspace/main.go", src, "darwin", "arm64", "")
	if st.Excluded {
		t.Fatalf("expected unix && go1.22 file included on darwin/arm64, got %+v", st)
	}

	normal := checkTarget(t, "/workspace/service.go", "package main\nfunc main() {}\n", "linux", "amd64", "")
	if normal.Excluded {
		t.Fatalf("expected normal file included, got %+v", normal)
	}
}

func TestCheckBuildTargetDefaultsMatchExecutionMode(t *testing.T) {
	prevMode := bridge.ExecutionMode()
	t.Cleanup(func() { bridge.SetExecutionMode(prevMode) })

	bridge.SetExecutionMode("host")
	hostDefault := checkTarget(t, "/workspace/host_check.go", "//go:build "+runtime.GOOS+"\n\npackage main\n", "", "", "")
	if hostDefault.Excluded || hostDefault.GOOS != runtime.GOOS {
		t.Fatalf("expected host mode default target %s to include matching file, got %+v", runtime.GOOS, hostDefault)
	}
	if runtime.GOOS == "darwin" {
		linuxFile := checkTarget(t, "/workspace/linux_only.go", "//go:build linux\n\npackage main\n", "", "", "")
		if !linuxFile.Excluded || linuxFile.GOOS != "darwin" {
			t.Fatalf("expected linux-only file excluded on host darwin default, got %+v", linuxFile)
		}
	}

	bridge.SetExecutionMode("vm")
	darwin := checkTarget(t, "/workspace/darwin_only.go", "//go:build darwin\n\npackage main\n", "", "", "")
	if !darwin.Excluded || darwin.GOOS != "linux" {
		t.Fatalf("expected VM mode default target to be linux and exclude darwin-only file, got %+v", darwin)
	}
	linux := checkTarget(t, "/workspace/linux_only.go", "//go:build linux\n\npackage main\n", "", "", "")
	if linux.Excluded {
		t.Fatalf("expected linux-only file included in VM mode default target, got %+v", linux)
	}
}
