#!/bin/bash
# Linux VM journey: the real app in the optional Linux machine mode (no vsock bridge), on a module under ~/Documents.
# Covers the VM lifecycle and mounts, go through vmexec, Settings > Execution, the terminal, Run, port forwarding,
# Debug, Rosetta 2 (linux/amd64), cgroup memory and CPU limits, Profiler > Kernel, escape analysis, disassembly and
# pausing when idle. Each phase is a separate launch so a failure stays local.
# Usage: scripts/smoke/linux-vm-journey.sh [phase ...]   phases: env server debug amd64 limits pause (default: all); LINUXVM_PORT (8080)
# It boots the installed runtime (~/Library/Application Support/GoLens/VMRuntime, or GOLENS_VM_RUNTIME_DIR).
# VM_AGENT=path boots a scratch copy of that runtime with this guest agent instead.
# It refuses to start while another Linux machine runs. LINUXVM_OUT=dir keeps logs and screenshots there.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
PHASES=${*:-env server debug amd64 limits pause}
PORT=${LINUXVM_PORT:-8080}
DOMAIN=dev.golens.test.linuxvm
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
FIX=$HOME/Documents/golens-linuxvm
LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"

if pgrep -f com.apple.Virtualization.VirtualMachine >/dev/null; then
  echo "another Linux machine is running; this journey would replace the VMRootfs folder it boots from"; exit 2
fi
smoke_lock_acquire
pkill -9 -f "Containers/$DOMAIN/" 2>/dev/null || true
rm -rf "$CONTAINER_DIR/Library/Preferences" 2>/dev/null || true
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-linuxvm.XXXXXX")" && pwd -P)
ART=${LINUXVM_OUT:-$WORK/art}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
APP_PID=
OWNED_PIDS=
SAMPLER_PID=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$SAMPLER_PID" ] && kill -TERM "$SAMPLER_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$FIX"
  [ -z "${LINUXVM_OUT:-}" ] && echo "artifacts were in $ART (removed)"
  rm -rf "$WORK"
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.virtualization" || { echo "missing virtualization entitlement"; exit 2; }
VMR=${GOLENS_VM_RUNTIME_DIR:-$HOME/Library/Application Support/GoLens/VMRuntime}
[ -f "$VMR/vmlinuz" ] || { echo "no Linux runtime in $VMR (install it from Settings > Execution)"; exit 2; }
if [ -n "${VM_AGENT:-}" ]; then
  RT="$WORK/vmruntime"
  mkdir -p "$RT"
  cp -c "$VMR/vmlinuz" "$VMR/rootfs.img" "$VMR/NOTICES.txt" "$RT/" && cp -cR "$VMR/goroot" "$RT/goroot" && cp "$VM_AGENT" "$RT/golens-vm-agent" || { echo "VM_AGENT runtime copy failed"; exit 2; }
  VMR=$RT
fi
export GOLENS_VM_RUNTIME_DIR="$VMR"
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; printf '%-5s %-4s %s\n      %s\n' "$3" "$1" "$2" "$4"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
listening() { lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1; }
wait_listen() { local i=0; while [ $i -lt $(($2 * 5)) ]; do listening "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
wait_free() { local i=0; while [ $i -lt $(($2 * 10)) ]; do listening "$1" || return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
seg() { sed -n "/DRIVE mark $1\$/,/DRIVE mark $2\$/p" "$LOG"; }
vz_pid() { pgrep -n -f com.apple.Virtualization.VirtualMachine; }
forget_window_frames() { defaults read $DOMAIN 2>/dev/null | sed -n 's/^ *"\(NSWindow Frame [^"]*\)" = .*/\1/p' | while IFS= read -r key; do defaults delete $DOMAIN "$key" >/dev/null 2>&1; done; }

make_fixture() {
  rm -rf "$FIX"; mkdir -p "$FIX/cmd/envcheck" "$FIX/cmd/server" "$FIX/cmd/debugme" "$FIX/cmd/oom" "$FIX/cmd/cpu" "$FIX/.vmcheck"
  printf 'module example.com/linuxvm\n\ngo 1.22\n' > "$FIX/go.mod"
  cat > "$FIX/cmd/envcheck/main.go" <<'EOF'
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func moduleRoot() string {
	dir, _ := os.Getwd()
	for d := dir; d != "/"; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
			return d
		}
	}
	return dir
}

func main() {
	var b strings.Builder
	fmt.Fprintf(&b, "runtime=%s/%s\n", runtime.GOOS, runtime.GOARCH)
	for _, args := range [][]string{{"go", "version"}, {"go", "env", "GOOS", "GOARCH", "GOROOT", "GOCACHE", "GOMODCACHE"}, {"uname", "-m"}, {"uname", "-r"}} {
		out, err := exec.Command(args[0], args[1:]...).CombinedOutput()
		fmt.Fprintf(&b, "$ %s\n%s", strings.Join(args, " "), out)
		if err != nil {
			fmt.Fprintf(&b, "error: %v\n", err)
		}
	}
	wd, _ := os.Getwd()
	fmt.Fprintf(&b, "cwd=%s\n", wd)
	root := moduleRoot()
	if exe, err := os.Executable(); err == nil {
		if src, err := os.Open(exe); err == nil {
			if dst, err := os.Create(filepath.Join(root, ".vmcheck", "envcheck-"+runtime.GOARCH+".bin")); err == nil {
				_, _ = io.Copy(dst, src)
				dst.Close()
			}
			src.Close()
		}
	}
	_ = os.WriteFile(filepath.Join(root, ".vmcheck", "envcheck-"+runtime.GOARCH+".txt"), []byte(b.String()), 0o644)
	fmt.Print(b.String())
}
EOF
  cat > "$FIX/cmd/server/main.go" <<EOF
package main

import (
	"fmt"
	"net/http"
	"os"
	"runtime"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if f, err := os.OpenFile("../../.vmcheck/requests.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
			fmt.Fprintf(f, "%s %s from %s\n", r.Method, r.URL.Path, r.RemoteAddr)
			f.Close()
		}
		fmt.Fprintf(w, "golens-vm-server %s/%s pid=%d\n", runtime.GOOS, runtime.GOARCH, os.Getpid())
	})
	fmt.Println("listening on :$PORT")
	if err := http.ListenAndServe(":$PORT", nil); err != nil {
		fmt.Println(err)
	}
}
EOF
  cat > "$FIX/cmd/debugme/main.go" <<'EOF'
package main

import "fmt"

type point struct{ x, y int }

//go:noinline
func newPoint(x, y int) *point {
	return &point{x: x, y: y}
}

func total(xs []int) int {
	sum := 0
	for _, x := range xs {
		sum += x
	}
	return sum
}

func main() {
	done := make(chan struct{})
	go func() { <-done }()
	p := newPoint(1, 2)
	fmt.Println(total([]int{1, 2, 3, 4}), p.x+p.y)
	close(done)
}
EOF
  cat > "$FIX/cmd/oom/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	raw, _ := os.ReadFile("/proc/self/cgroup")
	dir := "/sys/fs/cgroup" + strings.TrimPrefix(strings.TrimSpace(string(raw)), "0::")
	for _, name := range []string{"memory.max", "memory.swap.max"} {
		v, err := os.ReadFile(filepath.Join(dir, name))
		fmt.Printf("%s %s=%s err=%v\n", dir, name, strings.TrimSpace(string(v)), err)
	}
	var keep [][]byte
	for mb := 32; mb <= 1024; mb += 32 {
		chunk := make([]byte, 32<<20)
		for i := 0; i < len(chunk); i += 4096 {
			chunk[i] = 1
		}
		keep = append(keep, chunk)
		fmt.Printf("allocated %d MB\n", mb)
		time.Sleep(50 * time.Millisecond)
	}
	fmt.Println("survived", len(keep))
}
EOF
  cat > "$FIX/cmd/cpu/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func moduleRoot() string {
	dir, _ := os.Getwd()
	for d := dir; d != "/"; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
			return d
		}
	}
	return dir
}

func cgroupDir() string {
	raw, _ := os.ReadFile("/proc/self/cgroup")
	line := strings.TrimSpace(string(raw))
	return "/sys/fs/cgroup" + strings.TrimPrefix(line, "0::")
}

func main() {
	dir := cgroupDir()
	before, _ := os.ReadFile(filepath.Join(dir, "cpu.stat"))
	start := time.Now()
	stop := make(chan struct{})
	for i := 0; i < 2; i++ {
		go func() {
			n := 0
			for {
				select {
				case <-stop:
					return
				default:
					n++
				}
			}
		}()
	}
	time.Sleep(4 * time.Second)
	close(stop)
	wall := time.Since(start)
	limit, _ := os.ReadFile(filepath.Join(dir, "cpu.max"))
	after, _ := os.ReadFile(filepath.Join(dir, "cpu.stat"))
	out := fmt.Sprintf("cgroup=%s\ncpu.max=%swall_ms=%d\n--- cpu.stat before\n%s--- cpu.stat after\n%s", dir, limit, wall.Milliseconds(), before, after)
	_ = os.WriteFile(filepath.Join(moduleRoot(), ".vmcheck", "cpu.txt"), []byte(out), 0o644)
	fmt.Print(out)
}
EOF
  (cd "$FIX" && git init -q && git add -A && git -c user.name=smoke -c user.email=smoke@example.com commit -qm init)
}

launch() { # name activeFile steps [extra env...]
  LOG=$ART/logs/$1.log
  local file=$2 steps=$3; shift 3
  env DRIVE_GUEST_CWD="$FIX" DRIVE="$steps" DRIVE_OUT="$LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    GOLENS_EXECUTION_MODE=vm GOLENS_MEASURE=1 "$@" \
    "$APP" -GoLensLastWorkspacePath "$FIX" -GoLensLastFilePath "$FIX/$file" -GoLensShowConsole '<true/>' > "$ART/logs/$(basename "$LOG" .log).app.log" 2>&1 &
  APP_PID=$!
}

wait_mark() {
  local i=0
  while [ $i -lt $(($2 * 5)) ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    kill -0 "$APP_PID" 2>/dev/null || { echo "app exited before mark $1"; return 1; }
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

finish() {
  local i=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=; OWNED_PIDS=
  sleep 2
}

host_git_sampler() { # records git processes started by the app on the host
  : > "$ART/logs/host-git.txt"
  while kill -0 "$1" 2>/dev/null; do
    ps -A -o ppid=,pid=,comm= | awk -v app="$1" '$1 == app && $3 ~ /git/' >> "$ART/logs/host-git.txt"
    sleep 0.2
  done
}

echo "GoLens Linux VM journey — phases: $PHASES — artifacts $ART"

for phase in $PHASES; do
  make_fixture
  case $phase in
  env)
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:6;mark:booted;\
guestsh:cat /proc/mounts > .vmcheck/mounts.txt && pwd > .vmcheck/guest-pwd.txt && uname -r > .vmcheck/uname.txt;wait:2;\
guestsh:grep -E 'MemTotal|MemAvailable' /proc/meminfo > .vmcheck/meminfo.txt && grep balloon /proc/vmstat >> .vmcheck/meminfo.txt;wait:2;\
menu:Product/Run;waitfile:$FIX/.vmcheck/envcheck-arm64.txt;wait:3;mark:ran;deeplabels;shot:env-01-run-console;\
axpress:Terminal;wait:6;term:stty size > .vmcheck/term-size-1.txt && pwd > .vmcheck/term-pwd.txt && printf '\\033[31mRED-ANSI\\033[0m golens-terminal-ok\\n'"$'\r'";wait:3;\
shot:env-02-terminal-ansi;winsize:|620|1500;wait:3;term:stty size > .vmcheck/term-size-2.txt && printf '\\033[32mGREEN-ANSI\\033[0m after resize\\n'"$'\r'";wait:4;shot:env-02b-terminal-after-resize;mark:term;\
menu:GoLens/Settings…;wait:3;winsize:Settings|1150;wait:1;winpress:Settings|Execution;wait:3;lightmode;wait:1;mark:settings;winlabels:Settings;winshot:Settings|env-03-execution-light;\
winwheel:Settings|-600;wait:1;winshot:Settings|env-04-execution-light-bottom;winpress:Settings|Installed Go Versions;wait:2;mark:goversions;winlabels:Settings;winshot:Settings|env-05-go-versions-light;\
darkmode;wait:1;winshot:Settings|env-06-go-versions-dark;winpress:Settings|Back;wait:1.5;winshot:Settings|env-07-execution-dark;winwheel:Settings|-600;wait:1;winshot:Settings|env-08-execution-dark-bottom;lightmode;winclose:Settings;wait:1;\
mark:done;quit"
    launch env cmd/envcheck/main.go "$STEPS"
    wait_mark booted 120
    ( host_git_sampler "$APP_PID" ) & SAMPLER_PID=$!
    TCP_DURING=
    if wait_mark ran 180; then TCP_DURING=$(lsof -nP -a -p "$APP_PID" -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2); fi
    wait_mark done 180; finish 20
    kill -TERM "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=
    cp -R "$FIX/.vmcheck" "$ART/env-vmcheck" 2>/dev/null
    E=$FIX/.vmcheck
    check VM1 "The Linux machine boots and Settings shows it running" 'grep -q "DRIVE mark booted" "$LOG"' "$(seg settings goversions | grep -o 'Running · [^|]*' | head -1)"
    LSL=$(grep 'status languageServer' "$ART/logs/env.app.log" 2>/dev/null)
    check VM10 "gopls in the guest answers initialize and reaches Ready without a restart" \
      'echo "$LSL" | grep -q "\"state\":\"ready\"" && ! echo "$LSL" | grep -q "\"state\":\"crashed\""' \
      "$(echo "$LSL" | sed 's/.*"state":"\([a-z]*\)".*/\1/' | tr '\n' ' ')$(echo "$LSL" | grep -o '"detail":"[^"]*timed out[^"]*"' | head -1)"
    check VM2 "The workspace, build cache and module cache are mounted in the guest" \
      'grep -q " /workspaces virtiofs" "$E/mounts.txt" && grep -q " /cache/gobuild virtiofs" "$E/mounts.txt" && grep -q " /cache/gomod virtiofs" "$E/mounts.txt" && grep -q "^/workspaces/golens-linuxvm-" "$E/guest-pwd.txt"' \
      "$(grep -E ' /workspaces | /cache/gobuild | /cache/gomod | /usr/local/go ' "$E/mounts.txt" 2>/dev/null | awk '{print $2" "$3" "$4}' | tr '\n' ';') pwd=$(cat "$E/guest-pwd.txt" 2>/dev/null)"
    check VM3 "Run goes through vmexec: go version and go env report linux/arm64 in the guest" \
      'grep -q "runtime=linux/arm64" "$E/envcheck-arm64.txt" && grep -q "go version go1.* linux/arm64" "$E/envcheck-arm64.txt" && grep -q "^/cache/gobuild" "$E/envcheck-arm64.txt" && grep -q "^/cache/gomod" "$E/envcheck-arm64.txt"' \
      "$(tr '\n' ' ' < "$E/envcheck-arm64.txt" 2>/dev/null | cut -c1-260)"
    check VM4 "The app opens no listening TCP socket on the Mac while the program runs" '[ -z "$TCP_DURING" ]' "listeners: ${TCP_DURING:-none}"
    check VM5 "The terminal runs in the guest workspace, shows ANSI color and follows a resize" \
      'grep -q "^/workspaces/golens-linuxvm-" "$E/term-pwd.txt" && [ -s "$E/term-size-1.txt" ] && [ -s "$E/term-size-2.txt" ] && ! cmp -s "$E/term-size-1.txt" "$E/term-size-2.txt"' \
      "pwd=$(cat "$E/term-pwd.txt" 2>/dev/null) size before=$(cat "$E/term-size-1.txt" 2>/dev/null) after=$(cat "$E/term-size-2.txt" 2>/dev/null) — shots/env-02-terminal-ansi.png"
    SL=$(seg settings goversions | grep -m1 'winlabels')
    check VM6 "Settings > Execution shows the Linux machine, resources, network and storage sections" \
      'echo "$SL" | grep -q "Linux Machine" && echo "$SL" | grep -q "Resources" && echo "$SL" | grep -q "Privacy & Network" && echo "$SL" | grep -q "Storage" && echo "$SL" | grep -q "Go Toolchain"' \
      "shots/env-03..08 — $(echo "$SL" | cut -c1-200)"
    GL=$(seg goversions done | grep -m1 'winlabels')
    GUEST_GO=$(sed -n 's/.*go version go\([0-9.]*\) .*/\1/p' "$E/envcheck-arm64.txt" 2>/dev/null | head -1)
    check VM7 "Installed Go Versions shows the Go version the guest really runs" '[ -n "$GUEST_GO" ] && echo "$GL" | grep -q "Go $GUEST_GO" && ! echo "$GL" | grep -qi squashfs' "guest go$GUEST_GO — $(echo "$GL" | grep -o 'Linux Machine Toolchain[^|]*|[^|]*|[^|]*' | head -1)"
    check VM9 "The memory balloon takes back most of the 2 GB guest (balloon_inflate pages over 1 GB)" 'awk "/^balloon_inflate/{found=1; exit !(\$2 > 262144)} END{if(!found) exit 1}" "$E/meminfo.txt"' "$(tr '\n' ' ' < "$E/meminfo.txt" 2>/dev/null)"
    check VM8 "No git process ran on the Mac for the app once the VM was up" '[ ! -s "$ART/logs/host-git.txt" ]' "$(wc -l < "$ART/logs/host-git.txt" | tr -d ' ') host git samples"
    ;;
  server)
    if listening $PORT; then record SV0 "Port $PORT is free on the Mac" FAIL "port $PORT is busy; server phase skipped"; continue; fi
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:4;menu:Product/Run;mark:run;waitfile:$WORK/curl-done;\
axpress:Profiler;wait:1;axpress:Kernel;wait:4;mark:kernel;deeplabels;shot:server-01-kernel-light;darkmode;wait:1;shot:server-02-kernel-dark;lightmode;\
menu:Product/Stop;mark:stopped;wait:3;mark:done;quit"
    forget_window_frames
    defaults write $DOMAIN GoLensConsoleHeight -float 480
    launch server cmd/server/main.go "$STEPS"
    UP=0; FREE=0; BODY=
    if wait_mark run 120 && wait_listen $PORT 60; then
      UP=1
      BODY=$(curl -sS -v --max-time 8 "http://127.0.0.1:$PORT/" 2>"$ART/logs/curl-1.txt")
      for i in 2 3 4; do curl -sS -v --http0.9 --max-time 8 -o "$ART/logs/body-$i.bin" "http://127.0.0.1:$PORT/" 2>"$ART/logs/curl-$i.txt"; done
    fi
    touch "$WORK/curl-done"
    if wait_mark stopped 60; then wait_free $PORT 2 && FREE=1; fi
    wait_mark done 30; finish 15
    check PF1 "A server listening on :$PORT in the guest answers on http://127.0.0.1:$PORT on the Mac" '[ $UP = 1 ] && echo "$BODY" | grep -q "golens-vm-server linux/arm64"' "body: ${BODY:-none}; requests seen by the guest server: $(wc -l < "$FIX/.vmcheck/requests.txt" 2>/dev/null | tr -d ' ')"
    cp "$FIX/.vmcheck/requests.txt" "$ART/logs/server-requests.txt" 2>/dev/null
    check PF2 "Stop frees 127.0.0.1:$PORT on the Mac within 2 s" '[ $FREE = 1 ]' "free=$FREE"
    KL=$(seg kernel stopped | grep -m1 deeplabels)
    TEL=$(grep -m1 'kernelTelemetry .*"state":"LISTEN"' "$ART/logs/server.app.log" | grep -o '"tcpSockets":\[[^]]*\]' | cut -c1-200)
    check PK1 "Profiler > Kernel shows the program's PID, open file descriptors and its TCP listener" 'echo "$KL" | grep -q "Active TCP Sockets" && echo "$KL" | grep -Eq "[0-9]+ / [0-9]+ FDs" && [ -n "$TEL" ]' "$(echo "$KL" | tr '|' '\n' | grep -E 'PID|TCP Socket|FDs' | tr '\n' '|') telemetry: $TEL — shots/server-01/02"
    check PK2 "Profiler > Kernel shows Pressure Stall Information from the guest kernel" 'echo "$KL" | grep -q "Pressure Stall Information" && echo "$KL" | grep -Eq "avg10: [0-9]+\.[0-9]{2}"' "$(echo "$KL" | grep -oE 'avg10: [0-9.]+' | head -2 | tr '\n' ' ')"
    check PK3 "Profiler > Kernel brackets the IPv6 listener address and names the program, not the go tool" 'echo "$KL" | grep -Fq "[::]:$PORT" && ! echo "$KL" | grep -Eq "(^|\|)(go|compile|link)\|PID "' "$(echo "$KL" | tr '|' '\n' | grep -E 'PID|\]:' | head -3 | tr '\n' '|')"
    ;;
  debug)
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:4;\
axpress:Console;wait:0.5;menu:View/Escape Analysis;waitlabel:Escape analysis for main.go:;mark:escape;deeplabels;shot:debug-01-escape;menu:View/Escape Analysis;wait:1;\
caret:func total;menu:Tools/Code Analysis/Compiler Optimization & Live Disassembly…;wait:12;waitlabel:MOVD;mark:disasm;deeplabels;sheetshot:debug-02-disassembly;sheetpress:Done;wait:1;axpress:Close Compiler Optimization Sheet;wait:1;\
guestsh:go build -o /tmp/vmcheck-debugme ./cmd/debugme && go tool objdump -s newPoint /tmp/vmcheck-debugme > .vmcheck/objdump.txt 2>&1;wait:8;\
bpclick:return sum;wait:0.5;menu:Product/Debug;wait:30;mark:paused;deeplabels;shot:debug-03-paused;\
fieldl:golens-linuxvm|Evaluate or add watch|sum*2;wait:3;mark:evaluated;wintable:golens-linuxvm;shot:debug-04-evaluate;menu:Product/Stop;wait:3;mark:done;quit"
    launch debug cmd/debugme/main.go "$STEPS"
    wait_mark done 240; finish 15
    cp "$FIX/.vmcheck/objdump.txt" "$ART/logs/guest-objdump.txt" 2>/dev/null
    ES=$(seg escape disasm | grep -m1 deeplabels)
    check IN1 "Escape analysis runs in the guest and reports the heap escape" 'echo "$ES" | grep -q "Escape analysis for main.go:" && ! echo "$ES" | grep -q "0 heap escape"' "$(echo "$ES" | grep -o 'Escape analysis for main.go:[^|]*' | head -1)"
    DS=$(seg disasm paused | grep -m1 deeplabels)
    check IN2 "Disassembly shows arm64 instructions for newPoint" 'echo "$DS" | grep -Eq "MOVD|CMP|RET"' "$(echo "$DS" | grep -oE '(MOVD|ADD|CMP|RET)[^|]{0,40}' | head -3 | tr '\n' ' ') — shots/debug-02-disassembly*.png"
    DP=$(seg paused evaluated | grep -m1 deeplabels)
    check DB1 "Debug stops at the breakpoint with locals, goroutines and the call stack" 'echo "$DP" | grep -q "main.total" && echo "$DP" | grep -q "sum" && echo "$DP" | grep -qi "goroutine"' "$(echo "$DP" | grep -oE 'main\.total[^|]{0,40}|sum[^|]{0,20}|Goroutine[^|]{0,40}' | head -4 | tr '\n' ' ') — shots/debug-03-paused.png"
    DE=$(seg evaluated done | grep -m1 wintable)
    check DB2 "Evaluate sum*2 in the paused frame returns 20" 'echo "$DE" | grep -q "sum\*2" && echo "$DE" | grep -q "20"' "$(echo "$DE" | grep -oE 'sum\*2[^|]{0,30}' | head -2 | tr '\n' ' ') — shots/debug-04-evaluate.png"
    ;;
  amd64)
    mkdir -p "$FIX/.golens"
    printf '[{"name":"envcheck amd64","envVars":{},"buildFlags":"","args":"","workingDirectory":"cmd/envcheck","architecture":"amd64"}]' > "$FIX/.golens/run.json"
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:4;menu:Product/Run;waitfile:$FIX/.vmcheck/envcheck-amd64.txt;wait:2;mark:ran;deeplabels;shot:amd64-01-run;mark:done;quit"
    launch amd64 cmd/envcheck/main.go "$STEPS"
    wait_mark done 240; finish 15
    cp -R "$FIX/.vmcheck" "$ART/amd64-vmcheck" 2>/dev/null
    FILE_OUT=$(file "$FIX/.vmcheck/envcheck-amd64.bin" 2>/dev/null)
    check RS1 "An amd64 run configuration builds an ELF x86-64 program and runs it under Rosetta 2 in the guest" \
      'grep -q "runtime=linux/amd64" "$FIX/.vmcheck/envcheck-amd64.txt" && echo "$FILE_OUT" | grep -q "ELF 64-bit LSB executable, x86-64"' \
      "$(echo "$FILE_OUT" | cut -d: -f2 | cut -c1-80) / $(head -1 "$FIX/.vmcheck/envcheck-amd64.txt" 2>/dev/null)"
    ;;
  limits)
    mkdir -p "$FIX/.golens"
    printf '[{"name":"oom 128","envVars":{},"buildFlags":"","args":"","workingDirectory":"cmd/oom","memoryLimit":"128MB"}]' > "$FIX/.golens/run.json"
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:4;menu:Product/Run;waitlabel:Increase Memory Limit…;wait:2;mark:oom;deeplabels;shot:limits-01-oom-light;darkmode;wait:1;shot:limits-02-oom-dark;lightmode;mark:done;quit"
    launch oom cmd/oom/main.go "$STEPS"
    wait_mark done 240; finish 15
    OL=$(seg oom done | grep -m1 deeplabels)
    check CG1 "A 128 MB memory limit ends the program with OOMKilled and a banner with recovery actions" 'echo "$OL" | grep -q "Increase Memory Limit…" && echo "$OL" | grep -q "Profile Heap"' "$(echo "$OL" | grep -oE '[^|]*(memory|Memory)[^|]*' | head -3 | tr '\n' ' ' | cut -c1-300) — shots/limits-01/02"
    make_fixture; mkdir -p "$FIX/.golens"
    printf '[{"name":"cpu half","envVars":{},"buildFlags":"","args":"","workingDirectory":"cmd/cpu","cpuQuota":"0.5"}]' > "$FIX/.golens/run.json"
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:4;menu:Product/Run;waitfile:$FIX/.vmcheck/cpu.txt;wait:2;mark:done;quit"
    launch cpu cmd/cpu/main.go "$STEPS"
    wait_mark done 240; finish 15
    cp "$FIX/.vmcheck/cpu.txt" "$ART/cpu.txt" 2>/dev/null
    CPU=$FIX/.vmcheck/cpu.txt
    USAGE=$(awk '/--- cpu.stat before/{s=1} /--- cpu.stat after/{s=2} $1=="usage_usec"{if(s==1)b=$2; if(s==2)a=$2} END{print a-b}' "$CPU" 2>/dev/null)
    WALL=$(sed -n 's/^wall_ms=//p' "$CPU" 2>/dev/null)
    RATIO=$(awk -v u="${USAGE:-0}" -v w="${WALL:-1}" 'BEGIN{printf "%.2f", u/1000/w}')
    check CG2 "A 0.5 vCPU quota holds a 2-thread busy loop to about half a core" 'grep -q "^cpu.max=50000 100000" "$CPU" && awk -v r="$RATIO" "BEGIN{exit !(r > 0.3 && r < 0.65)}"' "cpu.max=$(sed -n 's/^cpu.max=//p' "$CPU" 2>/dev/null) cores used=$RATIO over ${WALL} ms; nr_throttled=$(awk '/--- cpu.stat after/{s=1} s&&$1=="nr_throttled"{print $2}' "$CPU" 2>/dev/null)"
    ;;
  pause)
    STEPS="wait:4;fakeactive;mark:ready;wait:15;wait:6;fakeinactive;mark:idle;waitfile:$WORK/pause-sampled;waitfile:$WORK/pause-sampled;waitfile:$WORK/pause-sampled;waitfile:$WORK/pause-sampled;waitfile:$WORK/pause-sampled;\
menu:GoLens/Settings…;wait:3;winpress:Settings|Execution;wait:2;mark:paused-settings;winlabels:Settings;winshot:Settings|pause-01-paused;winclose:Settings;fakeactive;wait:6;mark:resumed;\
guestsh:echo resumed > .vmcheck/resumed.txt;wait:4;mark:done;quit"
    launch pause cmd/envcheck/main.go "$STEPS" GOLENS_VM_MEMORY_MB=512
    PAUSED_CPU=; RUNNING_CPU=; VZ=
    if wait_mark idle 120; then
      VZ=$(vz_pid)
      RUNNING_CPU=$(ps -o %cpu= -p "$VZ" 2>/dev/null | tr -d ' ')
      sleep 335
      PAUSED_CPU=$(for s in 1 2 3 4 5; do ps -o %cpu= -p "$VZ" 2>/dev/null | tr -d ' '; sleep 1; done | tr '\n' ' ')
    fi
    touch "$WORK/pause-sampled"
    wait_mark done 120; finish 15
    PL=$(seg paused-settings resumed | grep -m1 winlabels)
    check PZ1 "After 5 idle minutes the machine pauses: Settings says Paused and the VM process uses 0% CPU" 'echo "$PL" | grep -q "Paused · 0% CPU" && [ -z "$(echo "$PAUSED_CPU" | tr " " "\n" | grep -v "^0.0$" | grep -v "^$")" ]' "VZ pid $VZ cpu while idle-but-running=$RUNNING_CPU, after pause: $PAUSED_CPU — shots/pause-01-paused.png"
    check PZ2 "The machine resumes when the app is used again" '[ "$(cat "$FIX/.vmcheck/resumed.txt" 2>/dev/null)" = resumed ]' "resumed.txt=$(cat "$FIX/.vmcheck/resumed.txt" 2>/dev/null)"
    ;;
  esac
done

echo
PASS=$(grep -c $'\tPASS\t' "$RESULTS"); FAIL=$(grep -c $'\tFAIL\t' "$RESULTS")
echo "linux-vm-journey: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
