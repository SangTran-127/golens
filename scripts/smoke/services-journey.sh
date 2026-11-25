#!/bin/bash
# Services journey: the Services bottom tab on a Compose project with api.go active.
# Engine-down leg: the tab explains that the engine isn't running and offers Open <provider> and Retry.
# Fake-engine leg (always): list, logs, masked details, an external stop, the exit banner and Start, merged project logs,
# Remove Container… and Compose Down… confirmations, images, Open Shell, Open in Browser and service actions offered
# (never pressed, so no browser opens), and the B3, B4 and B6 budgets.
# Real-engine leg (only when a Docker engine answers): Compose Up from the Tools menu, logs, details, Rebuild and Restart,
# Stop Service and Start Service, the stats line and its stream closing, Networks, Clean Up (Cancel, then only a dangling
# image labelled golens.smoke=1), switching to temporary golens-smoke-* contexts (a local one and an unreachable ssh one)
# and back, Compose Down. The journey never prunes without the label, never prunes build cache, removes its contexts on
# exit and never changes the Docker CLI's current context.
# Usage: scripts/smoke/services-journey.sh [path/to/GoLensApp] [--keep]
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
export GOLENS_MEASURE=1
export GOLENS_SMOKE_PRUNE_LABEL=golens.smoke=1
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
command -v go >/dev/null || { echo "go is required to build the fake engine"; exit 2; }

LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire
DOMAIN=dev.golens.test.services
WORK=$(cd "$(mktemp -d -t golens-services)" && pwd -P)
SOCKDIR=$(cd "$(mktemp -d /tmp/glsvc.XXXXXX)" && pwd -P)
ART=${SERVICES_JOURNEY_ARTIFACTS:-$(cd "$(mktemp -d -t golens-services-artifacts)" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
FAKE_PID=
SMOKE_CTXS=
SMOKE_IMAGE=golens-smoke-dangling-$$

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
  if [ -n "$FAKE_PID" ] && kill -0 "$FAKE_PID" 2>/dev/null; then kill -TERM "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; fi
  FAKE_PID=
  for c in $SMOKE_CTXS; do "$REAL_DOCKER" context rm -f "$c" >/dev/null 2>&1; done
  if [ -n "${REAL_DOCKER:-}" ]; then
    "$REAL_DOCKER" image rm -f "$SMOKE_IMAGE:latest" >/dev/null 2>&1
    "$REAL_DOCKER" image prune -f --filter label=golens.smoke=1 >/dev/null 2>&1
  fi
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
  rm -rf "$SOCKDIR"
  smoke_lock_release
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
INJECT="$WORK/quiet.dylib:$WORK/driver.dylib"
(cd "$HERE/services-fixture/fake-engine" && GOFLAGS= go build -o "$WORK/fake-engine" main.go) || { echo "fake engine build failed"; exit 2; }
defaults delete $DOMAIN >/dev/null 2>&1

P=$WORK/svcdemo
mkdir -p "$P"
cp "$HERE/services-fixture/project/"* "$P/"

REAL_DOCKER=
for c in $(command -v docker 2>/dev/null) /opt/homebrew/bin/docker /usr/local/bin/docker "$HOME/.orbstack/bin/docker" /Applications/Docker.app/Contents/Resources/bin/docker; do
  [ -x "$c" ] && { REAL_DOCKER=$c; break; }
done
SHIM_LOG=$WORK/docker-calls.log
: > "$SHIM_LOG"
SHIM_PATH=$PATH
if [ -n "$REAL_DOCKER" ]; then
  mkdir -p "$WORK/shim"
  printf '#!/bin/sh\necho "$(date +%%s) $* ctx=${DOCKER_CONTEXT:-}" >> "%s"\nexec "%s" "$@"\n' "$SHIM_LOG" "$REAL_DOCKER" > "$WORK/shim/docker"
  chmod +x "$WORK/shim/docker"
  SHIM_PATH="$WORK/shim:$PATH"
fi

ENGINE_UP=0
if [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" version --format '{{.Server.Version}}' >/dev/null 2>&1; then ENGINE_UP=1; fi

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
skip() { record "$1" "$2" SKIP "$3"; }
both() { printf 'shot:light-%s;darkmode;wait:0.8;shot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
bothsheet() { printf 'sheetshot:light-%s;darkmode;wait:0.8;sheetshot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

launch() { # name steps [env assignments...]
  local name=$1 steps=$2; shift 2
  defaults delete $DOMAIN >/dev/null 2>&1
  LOG=$ART/logs/$name.log
  APPLOG=$ART/logs/$name.app.log
  MARKS=$ART/logs/$name.marks
  : > "$MARKS"
  env PATH="$SHIM_PATH" "$@" DRIVE="$steps" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$INJECT" \
    "$APP" -AppleInterfaceStyle Light -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$P/api.go" -GoLensShowConsole '<true/>' -GoLensConsoleHeight 560 -GoLensEnablePreviewTab '<false/>' > "$APPLOG" 2>&1 &
  APP_PID=$!
}
follow() { # seconds hook: records the wall time of each mark and runs hook <mark> on it
  local limit=$(($1 * 4)) hook=$2 i=0 seen=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $limit ]; do
    local n
    n=$(grep -c "^DRIVE mark " "$LOG" 2>/dev/null || true)
    while [ "${n:-0}" -gt $seen ]; do
      seen=$((seen + 1))
      local m
      m=$(grep "^DRIVE mark " "$LOG" | sed -n "${seen}p" | sed 's/^DRIVE mark //')
      printf '%s\t%s\n' "$m" "$(now_ms)" >> "$MARKS"
      $hook "$m"
    done
    sleep 0.25
    i=$((i + 1))
  done
  stop_app
}
mark_ms() { awk -F'\t' -v m="$1" '$1 == m { print $2; exit }' "$MARKS"; }
between() { sed -n "/DRIVE mark $1\$/,/DRIVE mark $2\$/p" "$LOG"; }
labels_after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG" | grep -m1 "deeplabels:"; }
found_after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG" | grep -m1 "^DRIVE axfind $2 -> [1-9]" >/dev/null; }
image_row() { sed -n "/DRIVE mark images\$/,\$p" "$LOG" | grep -m1 "^DRIVE axfind svcdemo-api:latest"; }
no_hook() { :; }

# ---- Leg 1: engine down
if [ $ENGINE_UP = 1 ]; then DOWN_ENV="DOCKER_HOST=unix://$SOCKDIR/missing.sock"; else DOWN_ENV="GOLENS_SERVICES_JOURNEY=down"; fi
T="wait:10;fakeactive;mark:ready;deeplabels;menu:View/Show Services;wait:4;mark:down;deeplabels;$(both 01-engine-down)"
T="${T}axpress:Retry;wait:4;mark:retried;deeplabels;mark:done;quit"
: > "$SHIM_LOG"
launch down "$T" "$DOWN_ENV"
follow 120 no_hook
DOWN=$(labels_after down)
check SV1 "The Services tab is offered in a project with compose.yaml" 'labels_after ready | grep -q "Services"' ""
check SV2 "Engine down: the tab says Docker Engine Isn’t Running and offers Retry" 'echo "$DOWN" | grep -q "Docker Engine Isn’t Running" && echo "$DOWN" | grep -q "Retry"' "$(echo "$DOWN" | grep -o 'Docker Engine Isn’t Running[^|]*\|Open [A-Za-z]*\|Retry' | sort -u | tr '\n' ' ')shots/light-01-engine-down.png"
if [ $ENGINE_UP = 0 ] && [ -d /Applications/OrbStack.app ] && grep -q '"currentContext": *"orbstack"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null; then
  check SV3 "Engine down with the OrbStack context: Open OrbStack is offered (not pressed)" 'echo "$DOWN" | grep -q "Open OrbStack"' ""
else
  skip SV3 "Open <provider> is offered" "the context's provider app is not installed or the down state is simulated"
fi
check SV4 "Retry keeps the explained state and starts no docker process" 'labels_after retried | grep -q "Docker Engine Isn’t Running" && ! grep -q " ps\| inspect\| logs\| events" "$SHIM_LOG"' "docker calls: $(cut -d' ' -f2- "$SHIM_LOG" | sort | uniq -c | tr '\n' ';')"

# ---- Leg 2: fake engine
SOCK=$SOCKDIR/d.sock
REQ=$ART/logs/fake-requests.log
"$WORK/fake-engine" -socket "$SOCK" -project "$P" -requests "$REQ" &
FAKE_PID=$!
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.1; done
fake_hook() {
  case $1 in
    b4-start) sleep 0.5; kill -USR1 "$FAKE_PID" 2>/dev/null ;;
    hidden) sleep 1.5; FAKE_AT_1S=$(fake_conns) ;;
    after-grace) FAKE_AT_31S=$(fake_conns); lsof -nP -a -p "$APP_PID" -U > "$ART/logs/after-grace-lsof.txt" 2>&1 ;;
  esac
}
fake_conns() { # the app's unix sockets whose peer is the fake engine's socket
  local devs
  devs=$(lsof -nP -U -F dn 2>/dev/null | awk -v sock="$SOCK" '/^d/ { d = substr($0, 2) } /^n/ { if (substr($0, 2) == sock) print d }')
  [ -z "$devs" ] && { echo 0; return; }
  lsof -nP -U -a -p "$APP_PID" -F n 2>/dev/null | sed -n 's/^n->//p' | grep -cxF -f <(echo "$devs")
}
FAKE_AT_1S=; FAKE_AT_31S=
T="wait:10;fakeactive;mark:ready;menu:View/Show Services;wait:4;mark:listed;axfind:api, Running;axfind:redis, Exited (1);axfind:This Project;axfind:scratch, Running;$(both 02-populated)"
T="${T}rowclick:api;wait:2;mark:api-logs;deeplabels;"
T="${T}menu:Tools/Containers & Compose/Show Details;wait:2;mark:details;deeplabels;$(both 03-details-masked)"
T="${T}axpress:Show Value of DATABASE_URL;wait:0.8;mark:revealed;deeplabels;"
T="${T}mark:api-menu;rowmenu:api;menustate:Tools/Containers & Compose/Open in Browser;menustate:Tools/Containers & Compose/Rebuild and Restart;mark:api-menu-end;"
T="${T}menu:Tools/Containers & Compose/Show Logs;wait:2;mark:logs;$(both 04-logs)"
T="${T}mark:b4-start;waitlabel:Exited with Code 0;mark:b4-done;deeplabels;$(both 05-exit-banner)"
T="${T}axpress:Start;wait:3;mark:restarted;axfind:api, Running;"
T="${T}rowclick:This Project;wait:3;mark:project-logs;deeplabels;$(both 06-project-logs)"
T="${T}rowclick:redis;wait:1;rowmenu:redis|Remove Container…;wait:1.2;mark:remove-confirm;wininfo;$(bothsheet 07-remove-confirm)sheetpress:Cancel;wait:1;axexists:redis;mark:remove-canceled;"
T="${T}menu:View/Navigator;wait:0.8;rowexpand:Images;wait:2.5;mark:images;axfind:svcdemo-api:latest;$(both 08-images)menu:View/Navigator;wait:0.8;"
T="${T}menu:Tools/Containers & Compose/Compose Down…;wait:1.2;mark:compose-down;wininfo;$(bothsheet 09-compose-down)sheetpress:Cancel;wait:0.8;"
T="${T}mark:console-switch;axpress:Console;wait:3;axpress:Services;wait:2;mark:services-back;"
T="${T}rowclick:api;wait:2;mark:sel-switch;rowclick:scratch;wait:2;mark:sel-b;"
T="${T}mark:pre-shell;rowclick:api;wait:1;menu:Tools/Containers & Compose/Open Shell;wait:3;mark:shell;deeplabels;"
T="${T}menu:View/Show Services;wait:2;mark:hidden;menu:View/Console;wait:33;mark:after-grace;wait:2;"
T="${T}menu:View/Console;wait:4;mark:reshown;axfind:api, Running;mark:done;quit"
: > "$SHIM_LOG"
launch fake "$T" DOCKER_HOST="unix://$SOCK"
follow 420 fake_hook
check SV5 "Show Services lists This Project’s services with their state and the other containers" \
  'found_after listed "api, Running" && found_after listed "redis, Exited (1)" && found_after listed "This Project" && found_after listed "scratch, Running"' "shots/light-02-populated.png"
check SV6 "Selecting a container shows its logs" 'labels_after api-logs | grep -q "listening on :8080"' ""
DETAILS=$(labels_after details)
check SV7 "Details list the published port and mask environment values" \
  'echo "$DETAILS" | grep -q "DATABASE_URL, hidden value" && ! echo "$DETAILS" | grep -q "s3cret" && echo "$DETAILS" | grep -q "localhost:8080"' "shots/light-03-details-masked.png"
check SV8 "Show Value reveals one environment value" 'labels_after revealed | grep -q "DATABASE_URL, postgres://app:s3cret@db/app"' ""
API_MENU=$(between api-menu api-menu-end)
check SV30 "A running service with a published port offers Open in Browser in Details, the row menu and the Tools menu" \
  'echo "$DETAILS" | grep -q "Open in Browser: localhost:8080" && echo "$API_MENU" | grep -q "rowmenu item Open in Browser enabled=1" && echo "$API_MENU" | grep -q "menustate Tools/Containers & Compose/Open in Browser enabled=1"' \
  "$(echo "$API_MENU" | grep -o 'rowmenu item [A-Za-z ]*enabled=[01]' | tr '\n' ';')"
check SV31 "This Project services offer Rebuild and Restart and Stop Service, and a stopped one offers Start Service" \
  'echo "$API_MENU" | grep -q "rowmenu item Rebuild and Restart enabled=1" && echo "$API_MENU" | grep -q "rowmenu item Stop Service enabled=1" && echo "$API_MENU" | grep -q "menustate Tools/Containers & Compose/Rebuild and Restart enabled=1" && grep -q "rowmenu item Start Service enabled=1" "$LOG"' ""
EXT_MS=$(awk '/EXTERNAL stop/ { print $1; exit }' "$REQ" 2>/dev/null)
APPLIED=$(grep "services batch applied at" "$APPLOG" | sed -E 's/.*applied at ([0-9.]+) reset 0 upserts ([0-9]+).*/\1 \2/' | awk -v t="$EXT_MS" '$2 > 0 && $1 * 1000 >= t { printf "%d", $1 * 1000 - t; exit }')
check SV9 "B4: an external stop reaches the row within 500 ms" '[ -n "$APPLIED" ] && [ "$APPLIED" -le 500 ] && grep -q "waitlabel .Exited with Code 0. -> 1" "$LOG"' "event to row update ${APPLIED:-?} ms (fake engine event to the applied batch)"
check SV10 "A stopped container shows the exit banner and Start brings it back" 'labels_after b4-done | grep -q "“svcdemo-api-1” Exited with Code 0" && found_after restarted "api, Running"' "shots/light-05-exit-banner.png"
check SV11 "This Project merges its services’ logs with a service prefix" 'labels_after project-logs | grep -q "api | listening on :8080" && labels_after project-logs | grep -q "redis | "' "shots/light-06-project-logs.png"
check SV12 "Remove Container… asks with the exact name and Cancel keeps the container" \
  'between remove-confirm remove-canceled | grep -q "Remove Container “svcdemo-redis-1”?" && between remove-confirm remove-canceled | grep -q "axexists redis -> 1"' "shots/light-07-remove-confirm.png"
check SV13 "Images list the project image as In Use" 'image_row | grep -q "svcdemo-api:latest, In Use"' "shots/light-08-images.png"
check SV14 "Compose Down… names the project and Cancel runs nothing" 'between compose-down console-switch | grep -q "Stop and Remove the “svcdemo” Compose Project?" && ! grep -q "compose" "$SHIM_LOG"' "shots/light-09-compose-down.png"
SWITCH_A=$(mark_ms console-switch); SWITCH_B=$(mark_ms services-back)
EVENTS_DURING=$(awk -v a="$SWITCH_A" -v b="$SWITCH_B" '$1 >= a && $1 <= b && $2 == "GET" && $3 ~ /\/events$/' "$REQ" | wc -l | tr -d ' ')
check SV15 "Switching to the Console tab and back within 30 s keeps the engine connection" '[ "$EVENTS_DURING" = 0 ]' "new /events requests while switching: $EVENTS_DURING"
SEL_SWITCH=$(mark_ms sel-switch)
API_END=$(awk -v b="$SEL_SWITCH" '$1 >= b - 300 && $2 == "END" && $4 ~ /a1a1.*\/logs$/ { print $1; exit }' "$REQ")
check SV16 "B6: changing the selection closes the previous log stream within 1 s" '[ -n "$API_END" ] && [ $((API_END - SEL_SWITCH + 300)) -le 1000 ]' "api log stream ended at most $(( ${API_END:-0} - ${SEL_SWITCH:-0} + 300 )) ms after the new selection was clicked (mark polling is 250 ms)"
PRE_SHELL_S=$(( $(mark_ms pre-shell) / 1000 ))
EARLY_CALLS=$(awk -v t="$PRE_SHELL_S" '$1 <= t' "$SHIM_LOG" | cut -d' ' -f2- | tr '\n' ';')
check SV17 "Listing, events, logs, details and actions start no docker process" '[ -z "$EARLY_CALLS" ]' "docker calls before Open Shell: ${EARLY_CALLS:-none}"
check SV18 "Open Shell opens a Terminal tab that runs docker exec in the container" 'labels_after shell | grep -q "svcdemo-api-1 (container)" && grep -q "exec -it a1a1" "$SHIM_LOG"' "$(grep 'exec -it' "$SHIM_LOG" | head -1 | cut -c1-80)"
HIDDEN=$(mark_ms hidden)
EVENTS_END=$(awk -v h="$HIDDEN" '$1 >= h && $2 == "END" && $4 ~ /\/events$/ { print $1; exit }' "$REQ")
ALL_CLOSED=$(awk -v h="$HIDDEN" '$1 >= h && $2 == "CONN" && $4 == "open=0" { print $1; exit }' "$REQ")
check SV19 "B6: hiding the panel closes every engine connection within 31 s" '[ -n "$ALL_CLOSED" ] && [ $((ALL_CLOSED - HIDDEN)) -le 31000 ] && [ "${FAKE_AT_31S:-1}" = 0 ]' "events ended $(( ${EVENTS_END:-0} - ${HIDDEN:-0} )) ms and the last connection $(( ${ALL_CLOSED:-0} - ${HIDDEN:-0} )) ms after hiding; app connections at +1 s: ${FAKE_AT_1S:-?}, at +33 s: ${FAKE_AT_31S:-?}"
check SV20 "Showing the panel again reconnects and lists the containers" 'found_after reshown "api, Running"' ""
check SV21 "Environment values never reach the app log" '! grep -q "s3cret" "$APPLOG"' ""
FIRST=$(grep "services first list" "$APPLOG" | sed -E 's/.*first list ([0-9.]+) ms.*/\1/' | tr '\n' ' ')
FIRST_MAX=$(echo "$FIRST" | tr ' ' '\n' | sort -n | tail -1)
check SV22 "B3: show to first rows within 150 ms" '[ -n "$FIRST_MAX" ] && awk "BEGIN{exit !($FIRST_MAX <= 150.0)}"' "samples ms: $FIRST(fake engine, store applied)"
check SV23 "The fake-engine leg reached the end" 'grep -q "DRIVE mark done" "$LOG"' ""
kill -TERM "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=

# ---- Leg 3: real engine
if [ $ENGINE_UP = 1 ]; then
  CTX0=$("$REAL_DOCKER" context show 2>/dev/null)
  CTX0_HOST=$("$REAL_DOCKER" context inspect "$CTX0" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  LOCAL_CTX=golens-smoke-$$-local
  BAD_CTX=golens-smoke-$$-unreachable
  CTX_STEPS=
  if [ -n "$CTX0" ] && [ "${CTX0_HOST#unix://}" != "$CTX0_HOST" ] \
    && "$REAL_DOCKER" context create "$LOCAL_CTX" --docker "host=$CTX0_HOST" >/dev/null 2>&1; then
    SMOKE_CTXS="$LOCAL_CTX"
    "$REAL_DOCKER" context create "$BAD_CTX" --docker "host=ssh://golens-smoke@127.0.0.1:1" >/dev/null 2>&1 && SMOKE_CTXS="$SMOKE_CTXS $BAD_CTX"
    CTX_STEPS="menu:Tools/Containers & Compose/Docker Context/$LOCAL_CTX;wait:6;menu:View/Show Services;wait:2;mark:ctx-switched;axfind:api, Running;$(both 16-context)"
    CTX_STEPS="${CTX_STEPS}rowclick:api;wait:1;menu:Tools/Containers & Compose/Open Shell;wait:3;menu:View/Show Services;wait:2;rowmenu:api|Stop Service;wait:12;menu:View/Show Services;wait:2;"
    CTX_STEPS="${CTX_STEPS}rowmenu:api|Start Service;wait:12;menu:View/Show Services;wait:2;mark:ctx-sessions;axfind:api, Running;"
    CTX_STEPS="${CTX_STEPS}menu:Tools/Containers & Compose/Docker Context/$BAD_CTX;wait:16;menu:View/Show Services;wait:1;mark:ctx-bad;deeplabels;$(both 17-engine-issue)"
    CTX_STEPS="${CTX_STEPS}menu:Tools/Containers & Compose/Docker Context/$CTX0;wait:8;menu:View/Show Services;wait:2;mark:ctx-back;axfind:api, Running;"
  fi
  mkdir -p "$WORK/dangling" && echo "untagged $$" > "$WORK/dangling/marker"
  printf 'FROM scratch\nLABEL golens.smoke=1\nCOPY marker /marker\n' > "$WORK/dangling/Dockerfile"
  DANGLING_ID=$("$REAL_DOCKER" build -q "$WORK/dangling" 2>/dev/null)
  echo "tagged $$" > "$WORK/dangling/marker"
  KEPT_ID=$("$REAL_DOCKER" build -q -t "$SMOKE_IMAGE:latest" "$WORK/dangling" 2>/dev/null)
  OTHER_DANGLING=$("$REAL_DOCKER" images -q --no-trunc -f dangling=true | grep -v "^${DANGLING_ID:-none}$" | sort | tr '\n' ' ')
  REAL_SOCK=${CTX0_HOST#unix://}
  STATS_ON=; STATS_HIDDEN=; CLEANUP_BLOCKED=0
  real_conns() { SOCK=$REAL_SOCK fake_conns; }
  real_hook() {
    case $1 in
      b4-start) "$REAL_DOCKER" stop svcdemo-api-1 >/dev/null 2>&1 & ;;
      stats-on) STATS_ON=$(real_conns) ;;
      stats-hidden) STATS_HIDDEN=$(real_conns) ;;
      cleanup-done)
        DANGLING_GONE=0; "$REAL_DOCKER" image inspect "$DANGLING_ID" >/dev/null 2>&1 || DANGLING_GONE=1
        KEPT_LEFT=0; "$REAL_DOCKER" image inspect "$KEPT_ID" >/dev/null 2>&1 && KEPT_LEFT=1
        OTHER_AFTER=$("$REAL_DOCKER" images -q --no-trunc -f dangling=true | sort | tr '\n' ' ') ;;
      cleanup-canceled) KEPT_AFTER_CANCEL=0; "$REAL_DOCKER" image inspect "$DANGLING_ID" >/dev/null 2>&1 && KEPT_AFTER_CANCEL=1 ;;
      cleanup-open)
        UNUSED_VOLUMES=$("$REAL_DOCKER" volume ls -q -f dangling=true | wc -l | tr -d ' ')
        ("$REAL_DOCKER" system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null | tr '\n' ';' > "$WORK/df.txt") & ;;
      cleanup-selected)
        for _ in 1 2 3 4 5 6 7 8 9 10; do labels_after cleanup-selected >/dev/null && break; sleep 0.3; done
        if labels_after cleanup-selected | grep -q "Only objects labelled “golens.smoke=1” are removed."; then
          touch "$WORK/cleanup-go"
        else
          CLEANUP_BLOCKED=1
          stop_app
        fi ;;
    esac
  }
  T="wait:10;fakeactive;mark:ready;menu:View/Show Services;wait:3;menu:Tools/Containers & Compose/Compose Up;wait:5;menu:View/Show Services;"
  T="${T}wait:120;mark:up;axfind:api, Running;axfind:redis, Running;$(both 10-real-populated)"
  T="${T}rowclick:api;wait:3;mark:real-logs;deeplabels;menu:Tools/Containers & Compose/Show Details;wait:2;mark:real-details;deeplabels;$(both 11-real-details)"
  T="${T}menu:Tools/Containers & Compose/Show Logs;wait:1;mark:b4-start;waitlabel:Exited with Code;mark:b4-done;axpress:Start;wait:5;"
  T="${T}wait:10;mark:svc-stop;rowmenu:api|Stop Service;wait:12;menu:View/Show Services;wait:2;mark:svc-stopped;axfind:api, Exited;"
  T="${T}rowmenu:api|Start Service;wait:12;menu:View/Show Services;wait:2;mark:svc-started;axfind:api, Running;"
  T="${T}rowmenu:api|Rebuild and Restart;wait:90;menu:View/Show Services;wait:3;mark:rebuilt;axfind:api, Running;"
  T="${T}rowclick:This Project;wait:3;mark:real-project;deeplabels;"
  T="${T}rowclick:api;wait:1;menu:Tools/Containers & Compose/Show Details;wait:4;mark:stats-on;deeplabels;$(both 13-stats)"
  T="${T}menu:View/Console;wait:1;mark:stats-hidden;menu:View/Console;wait:2;menu:View/Show Services;wait:3;"
  T="${T}rowexpand:Networks;wait:3;mark:networks;axfind:svcdemo_default;axfind:bridge;$(both 14-networks)"
  T="${T}fieldp:Filter:brid;wait:1.5;rowmenu:bridge;fieldp:Filter:;wait:1;mark:networks-end;"
  T="${T}menu:Tools/Containers & Compose/Clean Up…;wait:5;mark:cleanup-open;deeplabels;$(bothsheet 15-cleanup)axpress:Cancel;wait:1.5;mark:cleanup-canceled;"
  T="${T}menu:Tools/Containers & Compose/Clean Up…;wait:5;axpress:Stopped Containers;axpress:Unused Networks;axpress:Build Cache;wait:0.5;mark:cleanup-selected;deeplabels;"
  T="${T}waitfile:$WORK/cleanup-go;axpress:Clean Up;wait:3;mark:cleanup-done;deeplabels;menu:View/Show Services;wait:2;"
  T="${T}${CTX_STEPS}"
  T="${T}menu:Tools/Containers & Compose/Compose Down…;wait:1.2;sheetpress:Compose Down;wait:20;menu:View/Show Services;wait:3;mark:real-down;axfind:Not Running;$(both 12-real-down)mark:done;quit"
  launch real "$T"
  follow 900 real_hook
  check SV24 "Real engine: Compose Up from the Tools menu with api.go active starts both services" 'found_after up "api, Running" && found_after up "redis, Running"' "shots/light-10-real-populated.png"
  check SV25 "Real engine: logs show the server's start line" 'labels_after real-logs | grep -q "listening on :8080"' ""
  check SV26 "Real engine: details mask the environment" 'labels_after real-details | grep -q "DATABASE_URL, hidden value"' "shots/light-11-real-details.png"
  check SV27 "Real engine: docker stop in a terminal updates the row and Start brings it back" 'grep -q "waitlabel .Exited with Code. -> 1" "$LOG"' ""
  check SV28 "Real engine: This Project merges its services' logs" 'labels_after real-project | grep -q "api | "' ""
  check SV32 "Real engine: Stop Service and Start Service run docker compose for that service" \
    'grep -q "compose -f compose.yaml stop api" "$SHIM_LOG" && found_after svc-stopped "api, Exited" && grep -q "compose -f compose.yaml start api" "$SHIM_LOG" && found_after svc-started "api, Running"' ""
  check SV33 "Real engine: Rebuild and Restart rebuilds the service and leaves it running" \
    'grep -q "compose -f compose.yaml up -d --build api" "$SHIM_LOG" && found_after rebuilt "api, Running"' "$(grep -- '--build' "$SHIM_LOG" | head -1 | cut -c1-80)"
  check SV29 "Real engine: Compose Down… confirmed leaves This Project Not Running" 'found_after real-down "Not Running"' "shots/light-12-real-down.png"
  check SV34 "Real engine: a selected running container shows CPU and memory, and hiding the tab closes the stats stream" \
    'labels_after stats-on | grep -q "Usage, CPU [0-9]*% · Memory" && [ -n "$STATS_ON" ] && [ -n "$STATS_HIDDEN" ] && [ "$STATS_HIDDEN" -lt "$STATS_ON" ]' \
    "$(labels_after stats-on | grep -o "Usage, CPU[^|]*" | head -1); engine connections with stats ${STATS_ON:-?}, 1 s after hiding ${STATS_HIDDEN:-?} — shots/light-13-stats.png"
  check SV35 "Real engine: Networks list the project network in use and offer no Remove for the built-in bridge" \
    'found_after networks "svcdemo_default" && found_after networks "bridge" && between networks networks-end | grep -q "rowmenu item Remove Network… enabled=0"' "shots/light-14-networks.png"
  CLEAN_OPEN=$(labels_after cleanup-open)
  check SV36 "Real engine: Clean Up lists every category with its size and counts the unused volumes like docker" \
    'echo "$CLEAN_OPEN" | grep -q "Stopped Containers" && echo "$CLEAN_OPEN" | grep -q "Dangling Images" && echo "$CLEAN_OPEN" | grep -q "Build Cache" && { echo "$CLEAN_OPEN" | grep -qE "Unused Volumes, $UNUSED_VOLUMES( ·| \||$)" || { [ "$UNUSED_VOLUMES" = 0 ] && echo "$CLEAN_OPEN" | grep -q "Unused Volumes, Nothing to remove"; }; }' \
    "$(echo "$CLEAN_OPEN" | grep -oE "(Stopped Containers|Dangling Images|Unused Volumes|Unused Networks|Build Cache), [^|]*" | tr '\n' ';') docker volume ls dangling: ${UNUSED_VOLUMES:-?}; docker system df: $(cat "$WORK/df.txt" 2>/dev/null) — shots/light-15-cleanup.png"
  check SV37 "Real engine: Cancel closes Clean Up without removing anything" \
    'between cleanup-open cleanup-canceled | grep -q "axpress Cancel -> .* ok=1" && [ "${KEPT_AFTER_CANCEL:-0}" = 1 ]' "labelled dangling image still present after Cancel: ${KEPT_AFTER_CANCEL:-?}"
  check SV38 "Real engine: Clean Up with only dangling images removes the labelled dangling image and nothing else" \
    '[ "$CLEANUP_BLOCKED" = 0 ] && labels_after cleanup-open | grep -q "Only objects labelled “golens.smoke=1” are removed." && [ "${DANGLING_GONE:-0}" = 1 ] && [ "${KEPT_LEFT:-0}" = 1 ] && [ -z "$(comm -23 <(echo $OTHER_DANGLING | tr " " "\n" | sort) <(echo $OTHER_AFTER | tr " " "\n" | sort))" ] && ! labels_after cleanup-done | grep -q "Only objects labelled"' \
    "dangling ${DANGLING_ID:0:19} removed=${DANGLING_GONE:-?}, tagged image kept=${KEPT_LEFT:-?}, other dangling images before: $(echo $OTHER_DANGLING | wc -w | tr -d ' '), after: $(echo $OTHER_AFTER | wc -w | tr -d ' '); notice: $(labels_after cleanup-done | grep -o "Removed [^|]*" | head -1)"
  if [ -n "$CTX_STEPS" ]; then
    check SV39 "Real engine: switching to a second local context lists the same containers, and CLI sessions follow it" \
      'found_after ctx-switched "api, Running" && grep -q "\-\-context $LOCAL_CTX exec -it" "$SHIM_LOG" && grep -q "compose -f compose.yaml stop api ctx=$LOCAL_CTX" "$SHIM_LOG" && found_after ctx-sessions "api, Running"' \
      "$(grep -E "\-\-context $LOCAL_CTX|ctx=$LOCAL_CTX" "$SHIM_LOG" | cut -d' ' -f2- | head -3 | tr '\n' ';') — shots/light-16-context.png"
    check SV40 "Real engine: an unreachable ssh context explains the failure, and the context menu above it switches back" \
      'labels_after ctx-bad | grep -q "Retry" && labels_after ctx-bad | grep -q "$BAD_CTX" && found_after ctx-back "api, Running"' \
      "$(labels_after ctx-bad | tr '|' '\n' | grep -iE "couldn|can.t|isn.t|ssh" | head -2 | tr '\n' ' ') — shots/light-17-engine-issue.png"
    check SV41 "Real engine: the Docker CLI's own current context never changed" '[ "$("$REAL_DOCKER" context show 2>/dev/null)" = "$CTX0" ]' "current: $CTX0"
  else
    skip SV39 "Real engine: context switching" "The CLI's current context is not a local unix socket, or the temporary context could not be created."
  fi
  "$REAL_DOCKER" compose -f "$P/compose.yaml" down -v >/dev/null 2>&1 || true
else
  skip SV24 "Real engine: Compose Up, logs, details, docker stop, Compose Down" "No Docker engine is running; start OrbStack or Docker Desktop to run this leg."
fi

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
