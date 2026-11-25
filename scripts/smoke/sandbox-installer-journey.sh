#!/bin/bash
# Linux Sandbox installer: Settings ▸ Execution downloads a signed runtime from a local server, resumes after a lost
# connection and after Cancel, refuses a corrupted or untrusted runtime, installs, and removes it again.
# The archive is a small stand-in with the real layout, signed with the key in $GOLENS_RUNTIME_SIGNING_KEY
# (default ~/.golens/runtime-signing-ed25519.key); the runtime goes to a scratch folder, never the shared one.
# REAL_RUNTIME=<folder with a golens-linux-runtime archive and manifest from scripts/runtime/build.sh> adds a phase that
# installs that runtime, opts a project in, and waits for the Linux machine to boot from it.
# Usage: scripts/smoke/sandbox-installer-journey.sh [path/to/GoLensApp]
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${1:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
KEY=${GOLENS_RUNTIME_SIGNING_KEY:-$HOME/.golens/runtime-signing-ed25519.key}
[ -f "$KEY" ] || { echo "missing signing key: $KEY"; exit 2; }

DOMAIN=dev.golens.test.sandboxinstaller
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-installer.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-installer-artifacts.XXXXXX")" && pwd -P)
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
SERVER_PID=
PORT=48793

cleanup() {
  [ -n "$APP_PID" ] && kill -TERM "$APP_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null
  sleep 1
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP="$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")"
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage "$HERE/driver.m" -o "$WORK/driver.dylib" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit "$HERE/quiet-launch.m" -o "$WORK/quiet.dylib" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

SIGN_TOOL=${GOLENS_SIGN_TOOL_DIR:-$REPO/scripts/runtime/sign}
[ -f "$SIGN_TOOL/main.go" ] || { echo "missing signing tool: $SIGN_TOOL"; exit 2; }
sign() { (cd "$SIGN_TOOL" && GOLENS_RUNTIME_SIGNING_KEY="$1" go run . sign "$2") >/dev/null; }

make_feed() { # folder archive-mutation
  local feed=$1 stage=$WORK/stage-$(basename "$1")
  mkdir -p "$feed" "$stage/goroot/bin"
  printf 'Linux version 6.12.0-golens-test\n' > "$stage/vmlinuz"
  head -c 24000000 /dev/urandom > "$stage/rootfs.img"
  printf '#!/bin/sh\n' > "$stage/golens-vm-agent"
  printf '#!/bin/sh\n' > "$stage/goroot/bin/go"
  printf 'go1.27.4\ntime 2026-11-01T00:00:00Z\n' > "$stage/goroot/VERSION"
  printf 'Test runtime notices\n' > "$stage/NOTICES.txt"
  printf '{"version":"2026.11.23"}\n' > "$stage/runtime.json"
  local archive=golens-linux-runtime-2026.11.23-arm64.tar.gz
  (cd "$stage" && COPYFILE_DISABLE=1 tar -czf "$feed/$archive" .)
  local size sum installed
  size=$(stat -f %z "$feed/$archive")
  sum=$(shasum -a 256 "$feed/$archive" | cut -d' ' -f1)
  installed=$(du -sk "$stage" | cut -f1)
  printf '{"version":"2026.11.23","arch":"arm64","archive":"%s","archiveSize":%s,"installedSize":%s,"sha256":"%s","minimumAppVersion":"1.0.0","agentProtocol":1,"components":{"kernel":"6.12.0","go":"1.27.4","alpine":"3.22.2"}}' \
    "$archive" "$size" $((installed * 1024)) "$sum" > "$feed/golens-linux-runtime.json"
  if [ "$2" = corrupt ]; then printf 'x' | dd of="$feed/$archive" bs=1 seek=1000 conv=notrunc 2>/dev/null; fi
}

make_feed "$WORK/good" none
sign "$KEY" "$WORK/good/golens-linux-runtime.json"
make_feed "$WORK/corrupt" corrupt
sign "$KEY" "$WORK/corrupt/golens-linux-runtime.json"
make_feed "$WORK/untrusted" none
(cd "$SIGN_TOOL" && go run . keygen "$WORK/other.key") >/dev/null
sign "$WORK/other.key" "$WORK/untrusted/golens-linux-runtime.json"
ARCHIVE_SIZE=$(stat -f %z "$WORK/good/"*.tar.gz)

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
wait_mark() { local i=0; while [ $i -lt $(($2 * 5)) ]; do grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0; kill -0 "$APP_PID" 2>/dev/null || return 1; sleep 0.2; i=$((i + 1)); done; return 1; }
after() { sed -n "/mark $1\$/,\$p" "$LOG" | grep -m1 "$2" | cut -c1-${3:-3000}; }

serve() { # folder extra-args...
  [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  local folder=$1; shift
  python3 "$HERE/range-http-server.py" "$folder" "$PORT" "$@" > "$ART/logs/server-$(basename "$folder").log" 2>&1 &
  SERVER_PID=$!
  sleep 1
}

launch() { # name runtime-dir steps
  LOG=$ART/logs/$1.log
  GOLENS_VM_RUNTIME_DIR="$2" GOLENS_RUNTIME_MANIFEST_URL="http://127.0.0.1:$PORT/golens-linux-runtime.json" \
    DRIVE="$3" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensSettingsPane container > "$LOG.app" 2>&1 &
  APP_PID=$!
}

finish() {
  local i=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  kill -0 "$APP_PID" 2>/dev/null && { kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; }
  APP_PID=
}

echo "GoLens Linux Sandbox installer journey — artifacts: $ART"

RT=$WORK/runtime
serve "$WORK/good" --rate 3000000
launch install "$RT" "wait:6;fakeactive;mark:ready;menu:GoLens/Settings…;wait:3;winsize:Settings|900;wait:1;winwaitlabel:Settings|Download;mark:s1-offer;winlabels:Settings;winshot:Settings|installer-offer;\
winpress:Settings|Download;wait:1.5;mark:s2-downloading;winlabels:Settings;winshot:Settings|installer-downloading;\
winwaitlabel:Settings|Retry;mark:s3-dropped;winlabels:Settings;waitfile:$WORK/server-up;winpress:Settings|Retry;wait:1;winwaitlabel:Settings|Remove…;mark:s4-installed;winlabels:Settings;\
lightmode;wait:0.8;winshot:Settings|installer-installed-light;darkmode;wait:0.8;winshot:Settings|installer-installed-dark;\
winpress:Settings|Remove…;wait:1;sheetpress:Remove;wait:3;winwaitlabel:Settings|Download;mark:s5-removed;winlabels:Settings;\
winpress:Settings|Download;wait:2;mark:s6-before-cancel;winpress:Settings|Cancel;wait:1;mark:s6-cancelled;winlabels:Settings;\
winpress:Settings|Download;wait:1;winwaitlabel:Settings|Remove…;mark:s7-reinstalled;winlabels:Settings;mark:done;quit"
wait_mark s2-downloading 60 && sleep 2 && kill -TERM "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null; SERVER_PID=
wait_mark s3-dropped 150
mv "$ART/logs/server-good.log" "$ART/logs/server-good-before-drop.log"
serve "$WORK/good" --rate 3000000
touch "$WORK/server-up"
wait_mark s4-installed 120
S4_FILES=$(ls "$RT" 2>/dev/null | tr '\n' ' ')
wait_mark s5-removed 60
S5_LEFT=$(ls "$RT" 2>/dev/null | tr '\n' ' ')
wait_mark done 180
finish
SERVER_LOG=$ART/logs/server-good.log
RANGES=$(grep -c "bytes=" "$SERVER_LOG")
check S1 "Settings ▸ Execution offers the Linux Sandbox with its download and disk size" \
  'after s1-offer "winlabels:" | grep -q "Not Installed" && after s1-offer "winlabels:" | grep -q "download ·"' "$(after s1-offer "winlabels:" 600 | grep -o "Linux Sandbox.*on disk" | cut -c1-200) — shots/installer-offer.png"
check S2 "Download shows progress and a Cancel button" \
  'after s2-downloading "winlabels:" | grep -q "Downloading" && after s2-downloading "winlabels:" | grep -q "Cancel"' "shots/installer-downloading.png"
check S3 "A lost connection stops the download with a reason and Retry" \
  'after s3-dropped "winlabels:" | grep -q "The Download Stopped" && after s3-dropped "winlabels:" | grep -q "continues where it stopped"' "$(after s3-dropped "winlabels:" 3000 | grep -o "The Download Stopped[^|]*" | head -1)"
check S4 "Retry resumes with a byte range, verifies and installs the runtime" \
  'after s4-installed "winlabels:" | grep -q "Installed" && after s4-installed "winlabels:" | grep -q "Version 2026.11.23" && [ "$RANGES" -ge 1 ]' "range requests: $RANGES; installed files: $S4_FILES — shots/installer-installed-light.png, shots/installer-installed-dark.png"
check S5 "Remove deletes the runtime and offers the download again" \
  'after s5-removed "winlabels:" | grep -q "Not Installed" && [ -z "$S5_LEFT" ]' "left in the runtime folder: ${S5_LEFT:-nothing}"
check S6 "Cancel stops the download, and Download continues from where it stopped" \
  'after s6-cancelled "winlabels:" | grep -q "Not Installed" && after s7-reinstalled "winlabels:" | grep -q "Installed" && [ "$(grep -c "bytes=" "$SERVER_LOG")" -ge 2 ]' "range requests in total: $(grep -c "bytes=" "$SERVER_LOG")"

serve "$WORK/corrupt"
launch corrupt "$WORK/runtime-corrupt" "wait:6;fakeactive;menu:GoLens/Settings…;wait:3;winwaitlabel:Settings|Download;winpress:Settings|Download;winwaitlabel:Settings|Retry;mark:c1;winlabels:Settings;winshot:Settings|installer-corrupt;mark:done;quit"
wait_mark done 120
finish
check S7 "A download changed by one byte is refused with the reason and nothing is installed" \
  'after c1 "winlabels:" | grep -q "doesn’t match its signed checksum" && [ ! -e "$WORK/runtime-corrupt/vmlinuz" ]' "shots/installer-corrupt.png"

serve "$WORK/untrusted"
launch untrusted "$WORK/runtime-untrusted" "wait:6;fakeactive;menu:GoLens/Settings…;wait:3;winwaitlabel:Settings|Retry;mark:u1;winlabels:Settings;mark:done;quit"
wait_mark done 90
finish
check S8 "A runtime signed by another key is not offered" \
  'after u1 "winlabels:" | grep -q "isn’t signed by GoLens" && ! after u1 "winlabels:" | grep -q "download ·"' ""

if [ -n "${REAL_RUNTIME:-}" ]; then
  mkdir -p "$WORK/real" "$WORK/proj"
  cp -c "$REAL_RUNTIME"/golens-linux-runtime-*.tar.gz "$WORK/real/" && cp "$REAL_RUNTIME/golens-linux-runtime.json" "$WORK/real/"
  sign "$KEY" "$WORK/real/golens-linux-runtime.json"
  printf 'module example.com/proj\n\ngo 1.22\n' > "$WORK/proj/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$WORK/proj/main.go"
  serve "$WORK/real"
  LOG=$ART/logs/real.log
  GOLENS_VM_RUNTIME_DIR="$WORK/real-runtime" GOLENS_RUNTIME_MANIFEST_URL="http://127.0.0.1:$PORT/golens-linux-runtime.json" \
    DRIVE="wait:10;fakeactive;menu:GoLens/Settings…;wait:3;winsize:Settings|900;wait:1;winwaitlabel:Settings|Download;winpress:Settings|Download;winwaitlabel:Settings|Remove…;mark:r1-installed;winlabels:Settings;\
wintoggle:Settings|Run “proj” in the Linux Sandbox;winwaitlabel:Settings|Running · ;wait:1;mark:r2-sandbox;winlabels:Settings;winshot:Settings|installer-real-running;\
wintoggle:Settings|Run “proj” in the Linux Sandbox;wait:3;mark:r3-host;winlabels:Settings;mark:done;quit" \
    DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensSettingsPane container -GoLensLastWorkspacePath "$WORK/proj" -GoLensLastFilePath "$WORK/proj/main.go" > "$LOG.app" 2>&1 &
  APP_PID=$!
  wait_mark done 360
  finish
  check S9 "The real runtime installs, and opting the open project in boots the Linux machine from it" \
    'after r1-installed "winlabels:" | grep -q "Installed" && after r2-sandbox "winlabels:" | grep -q "Running On | Linux Sandbox" && after r2-sandbox "winlabels:" | grep -q "Running · "' "$(after r2-sandbox "winlabels:" 3000 | grep -oE "Running · [^|]*|Includes \| [^|]*" | tr '\n' ' ') — shots/installer-real-running.png"
  check S10 "Turning the project back off returns GoLens to macOS" 'after r3-host "winlabels:" | grep -q "Running On | macOS"' ""
fi

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
[ $fail -eq 0 ] && echo "No failures." || echo "$fail failure(s)."
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
