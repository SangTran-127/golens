package guestres

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

const (
	RootfsDevice = "/dev/vda"
	ErofsMount   = "/mnt/erofs"
	GuestPATH    = "/usr/local/go/bin:/root/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)

var RootfsBindDirs = []string{"/bin", "/lib", "/usr"}

var EtcBindDirs = []string{"ssl"}

var BinaryDirs = []string{"/usr/local/go/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"}

var GoTools = []string{"go", "gofmt", "gopls", "dlv"}

type Link struct {
	Path   string
	Target string
}

func SbinLinks(entries []string) []Link {
	links := make([]Link, 0, len(entries))
	for _, name := range entries {
		if name == "" || name == "init" || name == "." || name == ".." || strings.Contains(name, "/") {
			continue
		}
		links = append(links, Link{Path: "/sbin/" + name, Target: ErofsMount + "/sbin/" + name})
	}
	return links
}

func LocalBinLinks() []Link {
	links := make([]Link, 0, len(GoTools)+1)
	for _, tool := range GoTools {
		links = append(links, Link{Path: "/usr/local/bin/" + tool, Target: "/usr/local/go/bin/" + tool})
	}
	return append(links, Link{Path: "/usr/local/bin/golens-git-sign", Target: "/sbin/init"})
}

func ResolveIn(name string, exists func(string) bool) (string, bool) {
	if strings.HasPrefix(name, "/") {
		if exists(name) {
			return name, true
		}
		name = filepath.Base(name)
	}
	for _, dir := range BinaryDirs {
		if cand := filepath.Join(dir, name); exists(cand) {
			return cand, true
		}
	}
	return name, false
}

func TerminalShell(exists func(string) bool) (string, []string) {
	if exists("/bin/bash") {
		return "/bin/bash", []string{"--login", "-i"}
	}
	return "/bin/sh", []string{"-i"}
}

func WithRootShell(passwd []byte, shell string) []byte {
	root := "root:x:0:0:root:/root:" + shell
	lines := strings.Split(strings.TrimRight(string(passwd), "\n"), "\n")
	out := make([]string, 0, len(lines)+1)
	out = append(out, root)
	for _, line := range lines {
		if line == "" || strings.HasPrefix(line, "root:") {
			continue
		}
		out = append(out, line)
	}
	return []byte(strings.Join(out, "\n") + "\n")
}

func CopyTree(src, dst string, skip []string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		for _, s := range skip {
			if rel == s {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(target, info.Mode().Perm())
		case info.Mode()&fs.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			_ = os.Remove(target)
			return os.Symlink(link, target)
		case info.Mode().IsRegular():
			return copyFile(path, target, info.Mode().Perm())
		}
		return nil
	})
}

func copyFile(src, dst string, perm fs.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
