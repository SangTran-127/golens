#!/bin/bash
# Issue capsule journey: type incomplete Go code right under a method signature while gopls reports
# diagnostics, so the lens row of the edited line draws its issue capsule on every keystroke. A driver
# thread keeps creating and freeing monospaced system fonts the whole time (fontchurn), which makes AppKit
# return nil from monospacedSystemFont on the main thread; the app must keep drawing without terminating.
# Usage: scripts/smoke/issue-capsule-journey.sh [path/to/GoLensApp] [--keep]
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire
DOMAIN=dev.golens.test.issuecapsule
WORK=$(cd "$(mktemp -d -t golens-issuecapsule)" && pwd -P)
ART=${ISSUE_CAPSULE_ARTIFACTS:-$WORK/artifacts}
mkdir -p "$ART/shots"
LOG=$ART/drive.log
APP_PID=
PASS=0
FAIL=0

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.4; done
    kill -KILL "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  APP_PID=
}
cleanup() {
  stop_app
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  if [ $KEEP = 1 ]; then echo "kept: $WORK"; else rm -rf "$WORK"; fi
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

P=$WORK/chat
mkdir -p "$P"
cat > "$P/go.mod" <<'EOF'
module example.com/chat

go 1.22
EOF
cat > "$P/service.go" <<'EOF'
package chat

import "context"

type Store interface {
	Count(ctx context.Context, sessionID, tenantID string) (int64, error)
}

type Service struct {
	store Store
}

func (s *Service) CountSessionUserMessages(ctx context.Context, sessionID, tenantID string) (int64, error) {
	return s.store.Count(ctx, sessionID, tenantID)
}

func (s *Service) Limit(ctx context.Context, sessionID, tenantID string) bool {
	n, err := s.CountSessionUserMessages(ctx, sessionID, tenantID)
	return err == nil && n < 50
}
EOF

SIG='func (s *Service) CountSessionUserMessages(ctx context.Context, sessionID, tenantID string) (int64, error) {'
TYPED='total := s.store.Count(ctx,'
STEPS="wait:4;fakeactive;mark:ready;wait:12;fontchurn:on;caret:$SIG;\
code:\\n$TYPED;wait:6;shot:capsule-1;issueclick:$TYPED;wait:1;key:cancelOperation:;\
code: sessionID;wait:5;code:\\nif total > ;wait:5;shot:capsule-2;\
code:\\n;keylat:120;wait:4;issueclick:$TYPED;wait:1;key:cancelOperation:;\
fontchurn:report;mark:done;quit"

echo "GoLens issue capsule journey — fixture $P — artifacts $ART"
DRIVE="$STEPS" DRIVE_OUT="$LOG" DRIVE_SHOTS="$ART/shots" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
  "$APP" -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$P/service.go" > "$ART/app.log" 2>&1 &
APP_PID=$!

i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$APP_PID" 2>/dev/null; then echo "  (timeout; stopping the app)"; stop_app; fi
wait "$APP_PID" 2>/dev/null
STATUS=$?
APP_PID=

check() {
  if eval "$2"; then echo "PASS $1"; PASS=$((PASS + 1)); else echo "FAIL $1"; FAIL=$((FAIL + 1)); fi
}
check "IC1 the app reaches the end of the journey (exit $STATUS)" "grep -q 'DRIVE mark done' '$LOG'"
check "IC2 no NSInvalidArgumentException while drawing" "! grep -q 'NSInvalidArgumentException' '$ART/app.log'"
check "IC3 the edited line draws its issue capsule" "grep -q 'DRIVE issueclick total := .* at ' '$LOG'"
check "IC4 the font churn was active" "grep -Eq 'DRIVE fontchurn calls=[1-9][0-9]* ' '$LOG'"
grep -E 'DRIVE (fontchurn calls|keylat|issueclick)' "$LOG" | sed 's/^DRIVE /  /' | cut -c1-220
[ $FAIL = 0 ] || grep -E 'Terminating|NSInvalidArgumentException' "$ART/app.log" | head -3
echo "issue capsule journey: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
