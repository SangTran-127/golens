#!/bin/bash
set -u
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.docs/" 2>/dev/null || true
pkill -9 -f "golens-docs\." 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${1:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; smoke_lock_release; exit 2; }

DOMAIN=dev.golens.test.docs
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
rm -rf "$CONTAINER_DIR/Library/Preferences" 2>/dev/null || true
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-docs.XXXXXX")" && pwd -P)
  ART=${DOCS_ARTIFACTS:-$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-docs-artifacts.XXXXXX")" && pwd -P)}
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-docs.XXXXXX")" && pwd -P)
  ART=${DOCS_ARTIFACTS:-$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-docs-artifacts.XXXXXX")" && pwd -P)}
fi
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
OWNED_PIDS=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  defaults delete $DOMAIN >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
! codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.app-sandbox" || { echo "unexpected app-sandbox entitlement"; exit 2; }
codesign -d --entitlements - "$WORK/app/GoLens.app" 2>&1 | grep -q "com.apple.security.cs.disable-library-validation" || { echo "missing disable-library-validation entitlement"; exit 2; }

APP="$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")"
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage "$HERE/driver.m" -o "$WORK/driver.dylib" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit "$HERE/quiet-launch.m" -o "$WORK/quiet.dylib" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1 || true

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }

launch_ws() {
  LOG=$ART/logs/$1.log
  shift
  local ws=$1; local file=$2; local steps=$3; shift 3
  DRIVE_GUEST_CWD="$ws" DRIVE="$steps" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$ws" -GoLensLastFilePath "$file" -GoLensShowConsole '<false/>' "$@" > "$ART/logs/$(basename "$LOG" .log).app.log" 2>&1 &
  APP_PID=$!
}

launch_unbound() {
  LOG=$ART/logs/$1.log
  shift
  local steps=$1; shift 1
  DRIVE="$steps" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -ApplePersistenceIgnoreState '<true/>' -GoLensLastWorkspacePath "" -GoLensLastFilePath "" -GoLensShowConsole '<false/>' "$@" > "$ART/logs/$(basename "$LOG" .log).app.log" 2>&1 &
  APP_PID=$!
}

wait_mark() {
  local i=0
  while [ $i -lt $(($2 * 5)) ]; do
    grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && return 0
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      wait "$APP_PID" 2>/dev/null
      echo "app exited before mark $1 with status $? (last step: $(grep '^DRIVE' "$LOG" | tail -1 | cut -c1-120))" | tee -a "$LOG"
      return 1
    fi
    OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

finish() {
  local i=0
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $(($1 * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

between() { sed -n "/mark $1\$/,/mark $2\$/p" "$LOG" 2>/dev/null; }
line() { grep -m1 "$1" "$LOG" 2>/dev/null; }
shot_ok() { [ -s "$ART/shots/$1.png" ] && sips -g pixelWidth "$ART/shots/$1.png" >/dev/null 2>&1; }

# Fixtures
DEP=$WORK/localdep
mkdir -p "$DEP/helper"
printf 'module example.com/localdep\n\ngo 1.22\n' > "$DEP/go.mod"
cat > "$DEP/helper/helper.go" <<'EOF'
package helper

// FormatGreeting builds a greeting string for name.
func FormatGreeting(name string) string {
	return "hi " + name
}
EOF

PROJA=$WORK/docsproja
mkdir -p "$PROJA/calc"
cat > "$PROJA/go.mod" <<'EOF'
module example.com/docsproja

go 1.22

require example.com/localdep v0.0.0

replace example.com/localdep => ../localdep
EOF
cat > "$PROJA/calc/calc.go" <<'EOF'
// Package calc provides workspace arithmetic helpers.
package calc

// Service runs calculations cleanly.
type Service struct {
	// Name identifies this service instance.
	Name string
}

// NewService constructs a named Service.
func NewService(name string) *Service {
	return &Service{Name: name}
}

// helperRate computes the internal multiplier.
func helperRate(n int) int {
	return n * 2
}
EOF
cat > "$PROJA/calc/linux_only.go" <<'EOF'
//go:build linux

package calc

// LinuxFastPath returns the Linux acceleration mode.
func LinuxFastPath() string {
	return "linux-io"
}
EOF
mkdir -p "$PROJA/onlydoc"
cat > "$PROJA/onlydoc/doc.go" <<'EOF'
// Package onlydoc documents package behavior without exported symbols.
package onlydoc
EOF

PROJB=$WORK/docsprojb
mkdir -p "$PROJB/bpkg"
printf 'module example.com/docsprojb\n\ngo 1.22\n' > "$PROJB/go.mod"
cat > "$PROJB/bpkg/bpkg.go" <<'EOF'
package bpkg

// BuildToken formats a workspace B token.
func BuildToken(id int) string {
	return "B"
}
EOF
cat > "$PROJB/main.go" <<'EOF'
package main

import "example.com/docsprojb/bpkg"

func main() {
	_ = bpkg.BuildToken(1)
}
EOF

echo "GoLens Documentation Browser User Journey — $(basename "$BIN") — artifacts: $ART"

# Session 1: Unbound View ▸ Documentation Browser (no project open) + Light & Dark
launch_unbound docs-unbound "wait:4;fakeactive;lightmode;wait:0.5;menustate:View/Documentation Browser;menu:View/Documentation Browser;wait:2;windows;mark:u-light;winlabels:Documentation Browser;winshot:Documentation Browser|docs-unbound-light;darkmode;wait:0.6;mark:u-dark;winshot:Documentation Browser|docs-unbound-dark;mark:done;quit" \
  -AppleInterfaceStyle Light
wait_mark done 60; finish 15

check DR1 "View > Documentation Browser is enabled with no project open and opens an unbound window with Open Project prompt" \
  'line "menustate View/Documentation Browser enabled=1" >/dev/null && between u-light u-dark | grep -q "No Project Open" && between u-light u-dark | grep -q "Open Project" && shot_ok docs-unbound-light && shot_ok docs-unbound-dark' \
  "$(line 'menustate View/Documentation Browser' | cut -c1-100); shots/docs-unbound-{light,dark}.png"

# Session 2: Full Journey B, C, D on Project A + Local Dependency + Project B
J="wait:8;fakeactive;lightmode;wait:0.5;mark:start;"
# Cold-open View > Documentation Browser focuses Search field immediately
J="${J}menu:View/Documentation Browser;wait:4;winkey:Documentation — docsproja;focus;mark:a-cold;fr:Service;wait:2;mark:a-typed;wintable:Documentation — docsproja;winpress:Documentation — docsproja|Clear Filter;winpress:Documentation — docsproja|Done;winclose:Documentation — docsproja;wait:1;winkey:docsproja;"
# First use go.mod lens to open localdep docs
J="${J}lensclick:require example.com/localdep|Open Documentation,Docs|0;wait:5;mark:b-mod;windows;winlabels:Documentation — docsproja;"
J="${J}winpress:Documentation — docsproja|example.com/localdep/helper;wait:3;mark:b-dep;winlabels:Documentation — docsproja;"
# Search for Service in Documentation Browser
J="${J}fieldl:Documentation — docsproja|Search Documentation|Service|noreturn;wait:2;mark:b-search;wintable:Documentation — docsproja;winshot:Documentation — docsproja|docs-search-light;darkmode;wait:0.6;winshot:Documentation — docsproja|docs-search-dark;lightmode;wait:0.5;"
J="${J}winpress:Documentation — docsproja|Service;wait:2.5;mark:b-calc;winlabels:Documentation — docsproja;"
# Back then forward/calc, then Open Source into editor
J="${J}axclick:Back;wait:2;mark:b-back;winlabels:Documentation — docsproja;"
J="${J}axclick:Forward;wait:2;winpress:Documentation — docsproja|Open Source;wait:2;mark:b-src;wineditor:docsproja;"
# Type unsaved buffer edit in calc.go, toggle Include Unexported, verify helperRate & Refresh
J="${J}winkey:docsproja;caret:// Service runs calculations cleanly.;typefast: Extra detail.;edited;wait:0.5;mark:c-edited;"
J="${J}menu:View/Documentation Browser;wait:3;mark:c-stale;winlabels:Documentation — docsproja;"
J="${J}winpress:Documentation — docsproja|Refresh;wait:3;axstate:Refresh;mark:c-refreshed;winlabels:Documentation — docsproja;"
J="${J}winpress:Documentation — docsproja|Include Unexported;wait:3;mark:c-unexported;winlabels:Documentation — docsproja;winshot:Documentation — docsproja|docs-pkg-light;darkmode;wait:0.6;winshot:Documentation — docsproja|docs-pkg-dark;lightmode;wait:0.5;"
# Package without symbols: Open Source opens doc.go rather than directory
J="${J}winpress:Documentation — docsproja|example.com/docsproja/onlydoc;wait:2.5;winpress:Documentation — docsproja|Open Source;wait:2;mark:c-onlydoc;wineditor:docsproja;menu:View/Documentation Browser;wait:2;"
# Verify linux_only excluded symbol via search
J="${J}fieldl:Documentation — docsproja|Search Documentation|LinuxFastPath|noreturn;wait:2;mark:d-excl;wintable:Documentation — docsproja;winpress:Documentation — docsproja|Done;wait:1;"
# Journey D: Open Project B while Project A Browser stays open; Quick Documentation -> Open in Documentation Browser
J="${J}stubpanel:$PROJB;menu:File/Open Project…;wait:8;winkey:docsprojb;rowclick:main.go;wait:5;winkey:docsprojb;caret:bpkg.BuildToken;wait:1;menu:View/Quick Documentation;wait:4;mark:d-qd;wininfo;axpress:Open in Documentation Browser;wait:4;mark:d-b-open;windows;winlabels:Documentation — docsprojb;winlabels:Documentation — docsproja;winshot:Documentation — docsprojb|docs-projb-light;darkmode;wait:0.6;winshot:Documentation — docsprojb|docs-projb-dark;mark:done;quit"

launch_ws docs-main "$PROJA" "$PROJA/go.mod" "$J" -AppleInterfaceStyle Light
wait_mark done 180; finish 15

check DR2 "Cold open focuses Search and go.mod Open Documentation lens navigates to local replacement dependency" \
  'between start a-cold | grep -q "firstResponder=NSTextView" && between a-typed b-mod | grep -q "Service, example.com/docsproja/calc" && between b-mod b-dep | grep -q "example.com/localdep" && between b-dep b-search | grep -q "FormatGreeting"' \
  "$(between start a-cold | grep -m1 'firstResponder='); $(between b-dep b-search | grep -m1 'winlabels:' | cut -c1-120)"

check DR3 "Search finds workspace symbols and Back/Forward + Open Source navigate cleanly while keeping browser page reachable" \
  'between b-search b-calc | grep -q "Service" && between b-calc b-back | grep -q "NewService" && between b-back b-src | grep -q "FormatGreeting" && between b-src c-edited | grep -q "calc.go" && shot_ok docs-search-light && shot_ok docs-search-dark' \
  "$(between b-src c-edited | grep -m1 'wineditor:' | cut -c1-120); shots/docs-search-{light,dark}.png"

check DR4 "Live editor edit refreshes cleanly, re-enables Refresh, exposes unexported symbols, and opens doc.go for symbol-free package" \
  'between c-stale c-refreshed | grep -qE "Source has changed|unsaved buffer" && between c-stale c-refreshed | grep -q "axstate Refresh -> 1" && between c-refreshed c-unexported | grep -q "Extra detail" && between c-unexported c-onlydoc | grep -q "helperRate" && between c-onlydoc d-excl | grep -q "onlydoc/doc.go" && shot_ok docs-pkg-light && shot_ok docs-pkg-dark' \
  "$(between c-onlydoc d-excl | grep -m1 'wineditor:' | cut -c1-120); shots/docs-pkg-{light,dark}.png"

check DR5 "Excluded build-target symbol appears in search with Excluded badge for non-active target" \
  'between d-excl d-qd | grep -q "LinuxFastPath" && between d-excl d-qd | grep -q "Excluded"' \
  "$(between d-excl d-qd | grep -m1 'wintable:' | cut -c1-140)"

check DR6 "Quick Documentation Open in Documentation Browser opens Workspace B Browser without detaching Workspace A Browser" \
  'between d-b-open done | grep -q "Documentation — docsprojb" && between d-b-open done | grep -q "BuildToken" && between d-b-open done | grep -q "Documentation — docsproja" && between d-b-open done | grep -q "Package onlydoc" && shot_ok docs-projb-light && shot_ok docs-projb-dark' \
  "shots/docs-projb-{light,dark}.png"

FAIL=0
ran=0
echo ""
while IFS=$'\t' read -r id name status detail; do
  ran=$((ran + 1))
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$name" "$detail"
  [ "$status" = FAIL ] && FAIL=1
done < "$RESULTS"
ELAPSED=$(( $(date +%s) - START ))
echo "Artifacts: $ART (${ELAPSED}s)"
if [ ! -s "$RESULTS" ] || [ "$ran" -eq 0 ]; then
  echo "No checks recorded in $RESULTS."
  exit 1
fi
exit $FAIL
