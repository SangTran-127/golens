#!/bin/bash
# Idle budget harness for the Services tab plan (B1 and B6): launches the app quietly on a project with a
# Dockerfile and compose.yaml and measures engine socket connections (lsof), child processes, Go goroutines
# (GetGoRuntimeDiagnostics), threads, CPU and RSS. A pass-through docker shim on PATH logs every docker
# process the app starts, so "opening a Dockerfile spawns no docker process" is an exact count.
# Usage: scripts/smoke/services-idle-check.sh [path/to/GoLensApp]
# Env: IDLE_SECONDS (default 600, the B1 budget), SETTLE_SECONDS (30), SAMPLE_SECONDS (10).
# Uses the isolated bundle id dev.golens.test.servicesidle, quiet.dylib and driver.dylib; never starts or stops Docker.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
pkill -9 -f "Containers/dev.golens.test.servicesidle/" 2>/dev/null || true

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${1:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
IDLE_SECONDS=${IDLE_SECONDS:-600}
SETTLE_SECONDS=${SETTLE_SECONDS:-30}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-10}

DOMAIN=dev.golens.test.servicesidle
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-servicesidle.XXXXXX")" && pwd -P)
ART=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-servicesidle-artifacts.XXXXXX")" && pwd -P)
mkdir -p "$ART/logs"
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
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP="$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")"
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage "$HERE/driver.m" -o "$WORK/driver.dylib" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit "$HERE/quiet-launch.m" -o "$WORK/quiet.dylib" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
cat > "$WORK/godiag.c" <<'EOF'
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

__attribute__((constructor)) static void startGoDiag(void) {
    const char *out = getenv("GODIAG_OUT");
    if (!out) return;
    const char *iv = getenv("GODIAG_INTERVAL");
    int interval = iv ? atoi(iv) : 5;
    if (interval < 1) interval = 5;
    char *path = strdup(out);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            sleep(interval);
            char *(*diag)(void) = (char *(*)(void))dlsym(RTLD_DEFAULT, "GetGoRuntimeDiagnostics");
            void (*release)(char *) = (void (*)(char *))dlsym(RTLD_DEFAULT, "FreeGoCString");
            if (!diag) continue;
            char *json = diag();
            FILE *f = fopen(path, "a");
            if (f) { fprintf(f, "%ld %s\n", (long)time(NULL), json ? json : "{}"); fclose(f); }
            if (json && release) release(json);
        }
    });
}
EOF
clang -dynamiclib "$WORK/godiag.c" -o "$WORK/godiag.dylib" 2>/dev/null || { echo "godiag build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" "$WORK/godiag.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" "$WORK/godiag.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1 || true

# ---- docker shim: logs each docker process the app starts, then runs the real CLI unchanged
REAL_DOCKER=
for c in $(command -v docker 2>/dev/null) /opt/homebrew/bin/docker /usr/local/bin/docker "$HOME/.orbstack/bin/docker" /Applications/Docker.app/Contents/Resources/bin/docker; do
  [ -x "$c" ] && { REAL_DOCKER=$c; break; }
done
SHIM_LOG=$WORK/docker-calls.log
: > "$SHIM_LOG"
if [ -n "$REAL_DOCKER" ]; then
  mkdir -p "$WORK/shim"
  printf '#!/bin/sh\necho "$(date +%%s) $*" >> "%s"\nexec "%s" "$@"\n' "$SHIM_LOG" "$REAL_DOCKER" > "$WORK/shim/docker"
  chmod +x "$WORK/shim/docker"
  export PATH="$WORK/shim:$PATH"
fi

# ---- engine sockets and the engine state, read without the docker CLI
CANDIDATES=()
case ${DOCKER_HOST:-} in unix://*) CANDIDATES+=("${DOCKER_HOST#unix://}") ;; esac
CTX=$(python3 -c 'import json,os,sys; p=os.path.join(os.environ.get("DOCKER_CONFIG") or os.path.expanduser("~/.docker"),"config.json"); print(json.load(open(p)).get("currentContext",""))' 2>/dev/null)
if [ -n "${DOCKER_CONTEXT:-}" ]; then CTX=$DOCKER_CONTEXT; fi
if [ -n "$CTX" ] && [ "$CTX" != default ]; then
  META="${DOCKER_CONFIG:-$HOME/.docker}/contexts/meta/$(printf '%s' "$CTX" | shasum -a 256 | cut -c1-64)/meta.json"
  H=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Endpoints"]["docker"]["Host"])' "$META" 2>/dev/null)
  case $H in unix://*) CANDIDATES+=("${H#unix://}") ;; esac
fi
CANDIDATES+=("$HOME/.orbstack/run/docker.sock" "$HOME/.docker/run/docker.sock" "$HOME/.colima/default/docker.sock" "$HOME/.config/colima/default/docker.sock" "$HOME/.rd/docker.sock" /var/run/docker.sock)
ENGINE_SOCKS=
ENGINE_STATE="not running: no socket answered /_ping (context ${CTX:-default})"
for s in "${CANDIDATES[@]}"; do
  [ -e "$s" ] || continue
  r=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$s")
  ENGINE_SOCKS="$ENGINE_SOCKS$s
$r
"
  if [ "$ENGINE_STATE" = "${ENGINE_STATE#running}" ] && v=$(curl -s -m 2 --unix-socket "$s" http://engine/version 2>/dev/null) && [ -n "$v" ]; then
    ENGINE_STATE="running at $s (Docker $(echo "$v" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Version","?"))' 2>/dev/null))"
  fi
done

engine_conns() { # pid: the app's unix sockets whose peer is an engine socket's listening side
  [ -z "$ENGINE_SOCKS" ] && { echo 0; return; }
  local devs
  devs=$(lsof -nP -U -F dn 2>/dev/null | ENGINE_SOCKS="$ENGINE_SOCKS" awk 'BEGIN { n = split(ENVIRON["ENGINE_SOCKS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 } /^d/ { d = substr($0, 2) } /^n/ { if (want[substr($0, 2)]) print d }')
  [ -z "$devs" ] && { echo 0; return; }
  lsof -nP -U -a -p "$1" -F n 2>/dev/null | sed -n 's/^n->//p' | grep -cxF -f <(echo "$devs")
}
socket_count() { lsof -nP -a -p "$1" -U -F f 2>/dev/null | grep -c '^f'; lsof -nP -a -p "$1" -i -F f 2>/dev/null | grep -c '^f'; }
thread_count() { ps -M -p "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }
cpu_seconds() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'; }
rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
goroutines() { tail -1 "$1" 2>/dev/null | sed -n 's/.*"goGoroutines":\([0-9]*\).*/\1/p'; }
tool_children() { # pid: docker, compose or kubectl processes below the app
  local k
  for k in $(descendants "$1"); do
    ps -o pid=,command= -p "$k" 2>/dev/null | grep -E '(^|/)(docker|docker-compose|kubectl)( |$)|/shim/docker' | grep -v grep
  done
}

calls_list() { cut -d' ' -f2- "$SHIM_LOG" | sed "s|$WORK/||g; s|.*config --services\$|compose config --services (Run Destination list at project open)|" | sort | uniq -c | sed 's/^ *//' | paste -sd';' -; }
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
wait_mark() { local i=0; while [ $i -lt $(($3 * 5)) ]; do grep -q "DRIVE mark $2\$" "$1" 2>/dev/null && return 0; kill -0 "$APP_PID" 2>/dev/null || return 1; sleep 0.2; i=$((i + 1)); done; return 1; }
launch() { # name file steps
  LOG=$ART/logs/$1.log
  DIAG=$ART/logs/$1.godiag
  GODIAG_OUT=$DIAG GODIAG_INTERVAL=$SAMPLE_SECONDS DRIVE="$3" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART \
    DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib:$WORK/godiag.dylib" \
    "$APP" -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$2" > "$ART/logs/$1.app.log" 2>&1 &
  APP_PID=$!
}
stop_app() {
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  APP_PID=
}

# ---- fixture: a Go module with a Dockerfile and compose.yaml at the root
P=$WORK/svc
mkdir -p "$P"
printf 'module example.com/svc\n\ngo 1.23\n' > "$P/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("svc") }\n' > "$P/main.go"
printf 'FROM golang:1.23 AS build\nWORKDIR /src\nCOPY . .\nRUN go build -o /out/app .\nFROM scratch\nCOPY --from=build /out/app /app\nENTRYPOINT ["/app"]\n' > "$P/Dockerfile"
printf 'services:\n  web:\n    build: .\n    ports:\n      - "8080:8080"\n' > "$P/compose.yaml"

echo "GoLens services idle check — $(basename "$BIN") — engine: $ENGINE_STATE — artifacts: $ART"

# ---- B1: Services tab never shown, a Go file open, idle
launch idle "$P/main.go" "wait:6;mark:ready;wait:$((SETTLE_SECONDS + IDLE_SECONDS + 60));mark:done"
wait_mark "$LOG" ready 60 || echo "  (idle launch did not reach ready)" >&2
sleep "$SETTLE_SECONDS"
G0=$(goroutines "$DIAG"); T0=$(thread_count "$APP_PID"); C0=$(cpu_seconds "$APP_PID"); R0=$(rss_kb "$APP_PID")
S0=$(socket_count "$APP_PID" | paste -sd+ - | bc); KIDS0=$(descendants "$APP_PID" | sort | tr '\n' ' ')
MAX_ENGINE=0; TOOL_SEEN=; ELAPSED=0
while [ $ELAPSED -lt "$IDLE_SECONDS" ]; do
  sleep "$SAMPLE_SECONDS"; ELAPSED=$((ELAPSED + SAMPLE_SECONDS))
  kill -0 "$APP_PID" 2>/dev/null || break
  n=$(engine_conns "$APP_PID"); [ "$n" -gt "$MAX_ENGINE" ] && MAX_ENGINE=$n
  t=$(tool_children "$APP_PID"); [ -n "$t" ] && TOOL_SEEN="$TOOL_SEEN $t"
done
G1=$(goroutines "$DIAG"); T1=$(thread_count "$APP_PID"); C1=$(cpu_seconds "$APP_PID"); R1=$(rss_kb "$APP_PID")
S1=$(socket_count "$APP_PID" | paste -sd+ - | bc); KIDS1=$(descendants "$APP_PID" | sort | tr '\n' ' ')
CPU_PCT=$(echo "scale=3; ($C1 - $C0) * 100 / $ELAPSED" | bc)
IDLE_CALLS=$(wc -l < "$SHIM_LOG" | tr -d ' ')
IDLE_CALL_LIST=$(calls_list)
stop_app
check B1a "Idle ${ELAPSED}s with the Services tab never shown: no engine socket connection" '[ "$MAX_ENGINE" = 0 ]' "max engine connections $MAX_ENGINE; engine $ENGINE_STATE"
check B1b "Project open and idle: no docker, compose or kubectl child process" '[ -z "$TOOL_SEEN" ] && [ "$IDLE_CALLS" = 0 ]' "docker calls $IDLE_CALLS${IDLE_CALL_LIST:+: $IDLE_CALL_LIST}${TOOL_SEEN:+; seen during idle:$TOOL_SEEN}"
check B1c "Idle: no added goroutines, threads, sockets or child processes" \
  '[ -n "$G0" ] && [ -n "$G1" ] && [ "$G1" -le "$G0" ] && [ "$T1" -le "$T0" ] && [ "$S1" -le "$S0" ] && [ "$KIDS1" = "$KIDS0" ]' \
  "goroutines $G0 -> $G1, threads $T0 -> $T1, sockets $S0 -> $S1, children [${KIDS0% }] -> [${KIDS1% }]"
check B1d "Idle: app CPU average at most 0.1%" '[ "$(echo "$CPU_PCT <= 0.1" | bc)" = 1 ]' "CPU ${CPU_PCT}% over ${ELAPSED}s; RSS ${R0} KB -> ${R1} KB"

# ---- Opening a Dockerfile: engine status without docker processes; B6 for the status check's connection
: > "$SHIM_LOG"
launch dockerfile "$P/Dockerfile" "wait:8;mark:ready;wait:6;mark:engine;deeplabels;wait:40;mark:done"
PEAK_TOOLS=0; TOOL_LINES=; i=0
while ! grep -q "DRIVE mark engine$" "$LOG" 2>/dev/null && [ $i -lt 150 ]; do
  kill -0 "$APP_PID" 2>/dev/null || break
  t=$(tool_children "$APP_PID")
  if [ -n "$t" ]; then n=$(echo "$t" | wc -l | tr -d ' '); [ "$n" -gt "$PEAK_TOOLS" ] && PEAK_TOOLS=$n; TOOL_LINES="$TOOL_LINES $t"; fi
  sleep 0.1; i=$((i + 1))
done
sleep 1
CONN_1S=$(engine_conns "$APP_PID")
sleep 30
CONN_31S=$(engine_conns "$APP_PID")
DF_CALLS=$(grep -vc ' config --services$' "$SHIM_LOG")
DF_CALL_LIST=$(calls_list)
DF_LABELS=$(grep -m1 "deeplabels:" "$LOG")
APP_VIEW=$(echo "$DF_LABELS" | grep -o 'Docker: [^|]*\|Docker Engine Isn’t Running\|Docker Isn’t Installed\|Docker Compose Isn’t Available' | sort -u | tr '\n' ';')
stop_app
check DF1 "Opening a Dockerfile starts no docker process (project-open Run Destination listing excluded)" '[ "$DF_CALLS" = 0 ]' \
  "docker calls added by the Dockerfile: $DF_CALLS; all calls this launch: ${DF_CALL_LIST:-none}; peak docker children seen $PEAK_TOOLS"
check DF2 "The app reports the engine state after opening the Dockerfile" '[ -n "$APP_VIEW" ]' "app shows: ${APP_VIEW:-nothing}; engine $ENGINE_STATE"
check B6a "Engine connections from the status check are closed within 31 s" '[ "$CONN_31S" = 0 ]' "at +1 s: $CONN_1S, at +31 s: $CONN_31S"
record B6b "Tab hidden, window closed, selection changed: connections closed" SKIP "needs the Services tab engine watch and log streams (not in this build)"

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
B1=PASS; grep -q "^B1.*	FAIL	" "$RESULTS" && B1=FAIL
B6=PASS; grep -q "^B6.*	FAIL	" "$RESULTS" && B6=FAIL
echo
echo "B1 $B1   B6 $B6 (status-check part; tab parts skipped)   engine: $ENGINE_STATE"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
