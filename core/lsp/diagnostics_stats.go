package lsp

import (
	"golens/core/bridge"
	"os/exec"
	"strconv"
	"strings"
)

type Client struct{}

var defaultClient = &Client{}

func GetClient() *Client {
	return defaultClient
}

func (c *Client) OpenBufferCount() int {
	return OpenBufferCount()
}

func (c *Client) GoplsProcessInfo() (pid int, rssBytes int64) {
	return GoplsProcessInfo()
}

func OpenBufferCount() int {
	return docs.count()
}

func GoplsProcessInfo() (pid int, rssBytes int64) {
	pid = ServerPID()
	if pid <= 0 {
		return 0, 0
	}
	return pid, processRSSBytes(pid)
}

func processRSSBytes(pid int) int64 {
	if pid <= 0 || pid == 2001 || bridge.IsSandboxed() {
		return 0
	}
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0
	}
	kib, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil || kib < 0 {
		return 0
	}
	return kib * 1024
}
