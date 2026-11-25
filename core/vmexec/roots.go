package vmexec

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

const (
	GuestWorkspacesRoot = "/workspaces"
	GuestGoroot         = "/usr/local/go"
	GuestModCache       = "/cache/gomod"
)

type ShareRoots struct {
	VMRuntime string `json:"vmRuntime"`
	Goroot    string `json:"goroot"`
	ModCache  string `json:"modCache"`
}

var (
	executablePath = os.Executable
	userHomeDir    = os.UserHomeDir
	realHomeDir    = func() string {
		if u, err := user.Current(); err == nil && u.HomeDir != "" {
			return u.HomeDir
		}
		return ""
	}
	pathExists = func(p string) bool {
		_, err := os.Stat(p)
		return err == nil
	}
)

func HostShareRoots() ShareRoots {
	runtime := hostVMRuntimeDir()
	return ShareRoots{
		VMRuntime: runtime,
		Goroot:    filepath.Join(runtime, "goroot"),
		ModCache:  hostModCacheDir(),
	}
}

func RealHomeDir() string {
	real := realHomeDir()
	if real != "" {
		if idx := strings.Index(real, "/Library/Containers/"); idx > 0 {
			return real[:idx]
		}
		return real
	}
	if home, err := userHomeDir(); err == nil && home != "" {
		if idx := strings.Index(home, "/Library/Containers/"); idx > 0 {
			return home[:idx]
		}
		return home
	}
	return ""
}

func hostVMRuntimeDir() string {
	if exe, err := executablePath(); err == nil && exe != "" {
		exeDir := filepath.Dir(exe)
		for _, cand := range []string{
			filepath.Join(exeDir, "..", "Resources", "VMRuntime"),
			filepath.Join(exeDir, "VMRuntime"),
		} {
			if pathExists(filepath.Join(cand, "vmlinuz")) {
				return filepath.Clean(cand)
			}
		}
	}
	appSupport := ""
	if home, err := userHomeDir(); err == nil && home != "" {
		appSupport = filepath.Join(home, "Library", "Application Support", "GoLens", "VMRuntime")
		if pathExists(filepath.Join(appSupport, "vmlinuz")) {
			return appSupport
		}
	}
	if real := realHomeDir(); real != "" {
		fallback := filepath.Join(real, "Library", "Application Support", "GoLens", "VMRuntime")
		if pathExists(filepath.Join(fallback, "vmlinuz")) {
			return fallback
		}
	}
	if appSupport != "" {
		return appSupport
	}
	return filepath.Join(os.TempDir(), "GoLens", "VMRuntime")
}

func hostModCacheDir() string {
	real := realHomeDir()
	if real == "" {
		if home, err := userHomeDir(); err == nil {
			if idx := strings.Index(home, "/Library/Containers/"); idx > 0 {
				real = home[:idx]
			} else {
				real = home
			}
		}
	}
	if real != "" {
		realMod := filepath.Join(real, "go", "pkg", "mod")
		if pathExists(realMod) {
			return realMod
		}
	}
	if home, err := userHomeDir(); err == nil && home != "" {
		return filepath.Join(home, "Library", "Caches", "com.golens.app", "gomod")
	}
	return filepath.Join(os.TempDir(), "com.golens.app", "gomod")
}
