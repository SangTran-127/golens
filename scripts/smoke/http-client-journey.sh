#!/bin/bash
# HTTP client journey: open an .http file, pick an environment, run, chain, assert, gRPC, errors.
# Usage: scripts/smoke/http-client-journey.sh [path/to/GoLensApp] [light|dark] [--keep]
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.http/" 2>/dev/null || true
pkill -9 -f "golens-http" 2>/dev/null || true
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
APPEARANCE=light
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; light|dark) APPEARANCE=$a ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }

DOMAIN=dev.golens.test.http
HTTP_PORT=${HTTP_JOURNEY_PORT:-47380}
GRPC_PORT=$((HTTP_PORT + 1))
WORK=$(cd "$(mktemp -d -t golens-http)" && pwd -P)
ART=${HTTP_JOURNEY_ARTIFACTS:-$(cd "$(mktemp -d -t golens-http-artifacts)" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
APP_PID=
SERVER_PID=

for p in $HTTP_PORT $GRPC_PORT; do
  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $p is busy; set HTTP_JOURNEY_PORT"; exit 2; }
done

cleanup() {
  [ -n "$APP_PID" ] && kill -TERM "$APP_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null
  sleep 1
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill -KILL "$SERVER_PID" 2>/dev/null
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
INJECT="$WORK/quiet.dylib:$WORK/driver.dylib"
FA=$HERE/force-appearance.m
if [ -f "$FA" ] && clang -dynamiclib -framework AppKit -o "$WORK/force.dylib" "$FA" 2>/dev/null; then
  xattr -cr "$WORK/force.dylib" 2>/dev/null || true
  codesign --force --sign - "$WORK/force.dylib" >/dev/null 2>&1 || true
  INJECT="$WORK/force.dylib:$INJECT"
fi
defaults delete $DOMAIN >/dev/null 2>&1

P=$WORK/shop
mkdir -p "$P/api" "$P/server"
cp "$REPO/scripts/smoke/http-fixture/server.go" "$P/server/main.go"
printf 'module example.com/shop\n\ngo 1.26.0\n\nrequire google.golang.org/grpc v1.84.0\n' > "$P/go.mod"
(cd "$P" && GOFLAGS=-mod=mod go mod tidy >/dev/null 2>&1 && go build -o "$WORK/shop-server" ./server) || { echo "fixture server build failed"; exit 2; }
sed "s/47380/$HTTP_PORT/; s/47381/$GRPC_PORT/" "$REPO/scripts/smoke/http-fixture/http-client.env.json" > "$P/api/http-client.env.json"
cp "$REPO/scripts/smoke/http-fixture/http-client.private.env.json" "$REPO/scripts/smoke/http-fixture/users.http" "$P/api/"

HTTP_ADDR=127.0.0.1:$HTTP_PORT GRPC_ADDR=127.0.0.1:$GRPC_PORT "$WORK/shop-server" > "$ART/logs/server.log" 2>&1 &
SERVER_PID=$!
i=0; while ! lsof -nP -iTCP:$HTTP_PORT -sTCP:LISTEN >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done

LOG=$ART/logs/journey-$APPEARANCE.log
S=$APPEARANCE
STEPS="wait:10;fakeactive;mark:ready;\
caret:POST {{host}}/login;wait:2;shot:$S-1-editor;\
editorctx:POST {{host}}/login;\
menu:Tools/HTTP Client/Run HTTP Request;wait:2;mark:unresolved;shot:$S-2-unresolved;\
menu:Tools/HTTP Client/HTTP Environment/dev;wait:1;\
menu:Tools/HTTP Client/Run HTTP Request;wait:3;mark:login;shot:$S-3-login;\
caret:GET {{host}}/users;menu:Tools/HTTP Client/Run HTTP Request;wait:3;mark:users;shot:$S-4-users-body;\
axpress:Tests (2);wait:1;shot:$S-5-users-tests;\
menu:Tools/HTTP Client/Run All HTTP Requests in File;wait:8;mark:runall;shot:$S-6-run-all;\
caret:GRPC {{grpcHost}};menu:Tools/HTTP Client/Run HTTP Request;wait:3;axpress:Body;wait:1;shot:$S-7-grpc;\
waitfile:$WORK/server-stopped;\
caret:POST {{host}}/login;menu:Tools/HTTP Client/Run HTTP Request;wait:3;mark:refused;shot:$S-8-refused;\
mark:done;quit"
DRIVE="$STEPS" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots FORCE_APPEARANCE=$APPEARANCE DYLD_INSERT_LIBRARIES="$INJECT" \
  "$APP" -AppleInterfaceStyle "$([ $APPEARANCE = dark ] && echo Dark || echo Light)" -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$P/api/users.http" -GoLensShowConsole '<true/>' > "$ART/logs/app-$APPEARANCE.log" 2>&1 &
APP_PID=$!

i=0; while ! grep -q "DRIVE mark runall" "$LOG" 2>/dev/null && kill -0 $APP_PID 2>/dev/null && [ $i -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
sleep 8
kill -TERM "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=
touch "$WORK/server-stopped"
i=0; while kill -0 $APP_PID 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
kill -0 $APP_PID 2>/dev/null && { kill -TERM $APP_PID; sleep 1; kill -KILL $APP_PID 2>/dev/null; }
APP_PID=

FAIL=0
check() { if grep -q "$2" "$LOG"; then echo "PASS $1"; else echo "FAIL $1 (missing: $2)"; FAIL=1; fi; }
check "context menu offers Run HTTP Request" "editorctx.*Run HTTP Request | Run All HTTP Requests in File"
check "Run HTTP Request menu command ran" "menu Tools/HTTP Client/Run HTTP Request (key"
check "environment chosen from the Tools menu" "menu Tools/HTTP Client/HTTP Environment/dev (key"
check "journey reached the end" "DRIVE mark done"
echo "artifacts: $ART"
exit $FAIL
