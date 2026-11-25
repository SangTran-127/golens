package guestres

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func noOrbStackPath(t *testing.T, what, s string) {
	t.Helper()
	if strings.Contains(s, "/nix") || strings.Contains(s, "wormhole") || strings.Contains(s, "orb") {
		t.Errorf("%s uses an OrbStack path: %s", what, s)
	}
}

func TestGuestPathsUseStandardLocations(t *testing.T) {
	noOrbStackPath(t, "GuestPATH", GuestPATH)
	for _, dir := range append(append([]string{}, BinaryDirs...), RootfsBindDirs...) {
		noOrbStackPath(t, "dir", dir)
	}
	for _, l := range LocalBinLinks() {
		noOrbStackPath(t, "link", l.Path+" -> "+l.Target)
	}
	path := strings.Split(GuestPATH, ":")
	if path[0] != "/usr/local/go/bin" {
		t.Errorf("GuestPATH should start with the Go toolchain, got %s", path[0])
	}
	for _, dir := range BinaryDirs {
		if !slices.Contains(path, dir) {
			t.Errorf("GuestPATH misses %s", dir)
		}
	}
}

func TestSbinLinksKeepTheAgentAsInit(t *testing.T) {
	links := SbinLinks([]string{"init", "ip", "apk", "", "..", "a/b", "ifconfig"})
	want := []Link{
		{Path: "/sbin/ip", Target: "/mnt/erofs/sbin/ip"},
		{Path: "/sbin/apk", Target: "/mnt/erofs/sbin/apk"},
		{Path: "/sbin/ifconfig", Target: "/mnt/erofs/sbin/ifconfig"},
	}
	if !slices.Equal(links, want) {
		t.Fatalf("SbinLinks = %v, want %v", links, want)
	}
}

func TestLocalBinLinks(t *testing.T) {
	links := LocalBinLinks()
	if !slices.Contains(links, Link{Path: "/usr/local/bin/golens-git-sign", Target: "/sbin/init"}) {
		t.Errorf("missing the git signing helper link: %v", links)
	}
	for _, tool := range GoTools {
		if !slices.Contains(links, Link{Path: "/usr/local/bin/" + tool, Target: "/usr/local/go/bin/" + tool}) {
			t.Errorf("missing %s: %v", tool, links)
		}
	}
}

func TestResolveIn(t *testing.T) {
	present := map[string]bool{"/usr/local/go/bin/go": true, "/usr/bin/git": true, "/sbin/ip": true, "/bin/sh": true, "/usr/bin/go": true}
	exists := func(p string) bool { return present[p] }
	cases := []struct {
		name, want string
		ok         bool
	}{
		{"go", "/usr/local/go/bin/go", true},
		{"git", "/usr/bin/git", true},
		{"ip", "/sbin/ip", true},
		{"/bin/sh", "/bin/sh", true},
		{"/nix/orb/sys/bin/git", "/usr/bin/git", true},
		{"zsh", "zsh", false},
	}
	for _, c := range cases {
		got, ok := ResolveIn(c.name, exists)
		if got != c.want || ok != c.ok {
			t.Errorf("ResolveIn(%q) = %q, %v; want %q, %v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestTerminalShell(t *testing.T) {
	shell, args := TerminalShell(func(p string) bool { return p == "/bin/bash" })
	if shell != "/bin/bash" || !slices.Equal(args, []string{"--login", "-i"}) {
		t.Errorf("with bash: %s %v", shell, args)
	}
	shell, args = TerminalShell(func(string) bool { return false })
	if shell != "/bin/sh" || !slices.Equal(args, []string{"-i"}) {
		t.Errorf("without bash: %s %v", shell, args)
	}
}

func TestWithRootShell(t *testing.T) {
	in := "root:x:0:0:root:/root:/bin/sh\nbin:x:1:1:bin:/bin:/sbin/nologin\nnobody:x:65534:65534:nobody:/:/sbin/nologin\n"
	want := "root:x:0:0:root:/root:/bin/bash\nbin:x:1:1:bin:/bin:/sbin/nologin\nnobody:x:65534:65534:nobody:/:/sbin/nologin\n"
	if got := string(WithRootShell([]byte(in), "/bin/bash")); got != want {
		t.Errorf("WithRootShell =\n%s\nwant\n%s", got, want)
	}
	if got := string(WithRootShell(nil, "/bin/sh")); got != "root:x:0:0:root:/root:/bin/sh\n" {
		t.Errorf("empty passwd: %q", got)
	}
}

func TestCopyTree(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(src, "profile.d"), 0o755))
	must(os.MkdirAll(filepath.Join(src, "ssl", "certs"), 0o755))
	must(os.WriteFile(filepath.Join(src, "os-release"), []byte("ID=alpine\n"), 0o644))
	must(os.WriteFile(filepath.Join(src, "profile.d", "locale.sh"), []byte("export LANG=C.UTF-8\n"), 0o755))
	must(os.WriteFile(filepath.Join(src, "ssl", "certs", "ca-certificates.crt"), []byte("pem"), 0o644))
	must(os.Symlink("/proc/mounts", filepath.Join(src, "mtab")))
	must(os.WriteFile(filepath.Join(dst, "hosts"), []byte("keep"), 0o644))

	must(CopyTree(src, dst, EtcBindDirs))

	if b, err := os.ReadFile(filepath.Join(dst, "os-release")); err != nil || string(b) != "ID=alpine\n" {
		t.Errorf("os-release = %q, %v", b, err)
	}
	if info, err := os.Stat(filepath.Join(dst, "profile.d", "locale.sh")); err != nil || info.Mode().Perm() != 0o755 {
		t.Errorf("locale.sh mode: %v, %v", info, err)
	}
	if link, err := os.Readlink(filepath.Join(dst, "mtab")); err != nil || link != "/proc/mounts" {
		t.Errorf("mtab link = %q, %v", link, err)
	}
	if _, err := os.Stat(filepath.Join(dst, "ssl")); !os.IsNotExist(err) {
		t.Errorf("ssl should be skipped, stat err = %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "hosts")); string(b) != "keep" {
		t.Errorf("existing file changed: %q", b)
	}
}
