#!/bin/bash
# Kubernetes journey: the Kubernetes section of the Services tab.
# Fake API leg (always): pods, deployments and services from a local stand-in API server, one watch per expanded kind
# (B9) and none for collapsed kinds, a forbidden namespace with Choose Namespace…, an unreachable context with Retry,
# and every watch closed within 31 s of hiding the tab (B6).
# Cluster leg (only with KUBE_JOURNEY_CLUSTER=1 and when the kubeconfig's current context answers): everything happens
# in a temporary namespace golens-smoke-<timestamp> labelled golens.smoke=1, through a temporary copy of the kubeconfig
# whose current context is switched to golens-smoke-alt, a context that defaults to that namespace. The manifests it
# applies name that namespace, and Apply is never pressed unless the list shows the journey's own pod. Steps: Apply to
# Cluster… with its diff, logs, a CrashLoopBackOff pod with its previous logs, Details with Events, Port Forward…
# answered over HTTP, Open Shell, a bad image applied, Rollout Restart… canceled, Delete Pod… confirmed, Read-Only for
# This Context, Use as kubectl Default (switching the copy to golens-smoke-alt2), collapsing Pods and hiding the tab.
# The namespace is deleted on exit, even on failure, the kubeconfig copy is always removed, and the owner's kubeconfig
# is checked unchanged. Context names and server addresses are never printed.
# Usage: [KUBE_JOURNEY_CLUSTER=1] scripts/smoke/kubernetes-journey.sh [path/to/GoLensApp] [--keep]
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required for the fake API server"; exit 2; }

LOCK=/private/tmp/golens-smoke.lock
. "$(cd "$(dirname "$0")" && pwd)/smoke-lock.sh"
smoke_lock_acquire
DOMAIN=dev.golens.test.kubernetes
WORK=$(cd "$(mktemp -d -t golens-kube)" && pwd -P)
ART=${KUBE_JOURNEY_ARTIFACTS:-$(cd "$(mktemp -d -t golens-kube-artifacts)" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=
FAKE_PID=
NS=golens-smoke-$(date +%Y%m%d%H%M%S)
NS_CREATED=0
ALT=golens-smoke-alt
ALT2=golens-smoke-alt2
TMPCFG=$WORK/kubeconfig
KUBECTL=$(command -v kubectl 2>/dev/null || true)
for c in /opt/homebrew/bin/kubectl /usr/local/bin/kubectl "$HOME/.orbstack/bin/kubectl"; do [ -z "$KUBECTL" ] && [ -x "$c" ] && KUBECTL=$c; done
ORIG_CFGS=${KUBECONFIG:-$HOME/.kube/config}
CTX0=
SERVER0=

kc() { "$KUBECTL" --kubeconfig "$TMPCFG" "$@"; }
cfg_sums() { local IFS=:; for f in $ORIG_CFGS; do [ -f "$f" ] && shasum "$f"; done | shasum | cut -c1-12; }
redact() {
  local s
  s=$(cat)
  [ -n "$CTX0" ] && s=${s//"$CTX0"/[context]}
  [ -n "$SERVER0" ] && s=${s//"$SERVER0"/[server]}
  printf '%s' "$s"
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    for p in $(pgrep -P "$APP_PID" -f "kubectl" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.4; done
    kill -KILL "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  APP_PID=
}
cleanup() {
  [ "${BASH_SUBSHELL:-0}" = 0 ] || return
  stop_app
  if [ -n "$FAKE_PID" ] && kill -0 "$FAKE_PID" 2>/dev/null; then kill -TERM "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; fi
  FAKE_PID=
  if [ "$NS_CREATED" = 1 ]; then
    kc delete namespace "$NS" --wait=false >/dev/null 2>&1
    local phase
    phase=$(kc get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "Namespace cleanup: $NS is ${phase:-gone}"
    echo "${phase:-gone}" > "$ART/namespace-cleanup.txt"
  fi
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  rm -f "$TMPCFG"
  [ $KEEP = 1 ] && echo "kept fixtures (without the kubeconfig copy): $WORK" || rm -rf "$WORK"
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
defaults delete $DOMAIN >/dev/null 2>&1

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | redact)" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
skip() { record "$1" "$2" SKIP "$3"; }
both() { printf 'shot:light-%s;darkmode;wait:0.8;shot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
bothsheet() { printf 'sheetshot:light-%s;darkmode;wait:0.8;sheetshot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
bothpopover() { printf 'popovershot:light-%s;darkmode;wait:0.8;popovershot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

launch() { # name steps project file [env assignments...]
  local name=$1 steps=$2 project=$3 file=$4; shift 4
  defaults delete $DOMAIN >/dev/null 2>&1
  LOG=$ART/logs/$name.log
  APPLOG=$ART/logs/$name.app.log
  MARKS=$ART/logs/$name.marks
  : > "$MARKS"
  env "$@" DOCKER_HOST="unix://$WORK/no-docker.sock" DRIVE="$steps" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$INJECT" \
    "$APP" -AppleInterfaceStyle Light -GoLensLastWorkspacePath "$project" -GoLensLastFilePath "$file" -GoLensShowConsole '<true/>' -GoLensConsoleHeight 560 -GoLensEnablePreviewTab '<false/>' > "$APPLOG" 2>&1 &
  APP_PID=$!
}
follow() { # seconds hook
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
labels_after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG" | grep -m1 "deeplabels:"; }
popover_after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG" | grep -m1 "popoverlabels:"; }
found_after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG" | grep -m1 "^DRIVE axfind $2 -> [1-9]" >/dev/null; }
between() { sed -n "/DRIVE mark $1\$/,/DRIVE mark $2\$/p" "$LOG"; }
no_hook() { :; }

# ---- Leg 1: fake API server
FPORT=$(free_port)
CLOSED=$(free_port)
REQ=$ART/logs/fake-api.log
: > "$REQ"
python3 -I "$HERE/kube-fixture/fake-apiserver.py" "$FPORT" "$REQ" &
FAKE_PID=$!
for _ in $(seq 1 40); do grep -q READY "$REQ" 2>/dev/null && break; sleep 0.1; done
FAKECFG=$WORK/fake-kubeconfig
cat > "$FAKECFG" <<EOF
apiVersion: v1
kind: Config
current-context: golens-fake
clusters:
- name: fake
  cluster:
    server: http://127.0.0.1:$FPORT
- name: closed
  cluster:
    server: http://127.0.0.1:$CLOSED
users:
- name: smoke
  user:
    token: golens-smoke-token
contexts:
- name: golens-fake
  context:
    cluster: fake
    user: smoke
    namespace: api
- name: golens-unreachable
  context:
    cluster: closed
    user: smoke
    namespace: api
EOF
chmod 600 "$FAKECFG"
P1=$WORK/fakeproj
mkdir -p "$P1"
cp "$HERE/kube-fixture/project/deploy.yaml" "$P1/"
printf 'module example.com/fakeproj\n\ngo 1.22\n' > "$P1/go.mod"

open_watches() { # open_watches <ms>: the namespace/kind of every watch open at that time
  awk -v t="$1" '$1 <= t && $2 == "WATCH" { k = $4 "/" $5; if ($3 == "open") n[k]++; else n[k]-- } END { for (k in n) if (n[k] > 0) printf "%s(%d) ", k, n[k] }' "$REQ" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//'
}
T="wait:10;fakeactive;mark:ready;wait:2;menu:Tools/Kubernetes/Show Kubernetes;wait:5;mark:listed;axfind:api-7d9f8-a1, Running;axfind:api-7d9f8-b2, CrashLoopBackOff;$(both 20-fake-populated)"
T="${T}wait:1;mark:b9-pods;wait:2;rowexpand:Deployments;wait:3;mark:b9-two;wait:2;axfind:api, 1/2 ready;"
T="${T}rowcollapse:Pods;wait:3;mark:b9-collapsed;wait:2;rowexpand:Pods;wait:3;"
T="${T}menu:Tools/Kubernetes/Namespace/Other Namespace…;wait:1.5;fieldp:Namespace:locked;wait:1;sheetpress:Use Namespace;wait:5;mark:forbidden;deeplabels;$(both 21-forbidden)"
T="${T}menu:Tools/Kubernetes/Namespace/api;wait:4;mark:ns-back;axfind:api-7d9f8-a1, Running;"
T="${T}menu:Tools/Kubernetes/Context/golens-unreachable;wait:10;mark:unreachable;deeplabels;$(both 22-unreachable)"
T="${T}axpress:Retry;wait:4;mark:retried;deeplabels;"
T="${T}menu:Tools/Kubernetes/Context/golens-fake (kubectl default);wait:5;mark:ctx-back;axfind:api-7d9f8-a1, Running;"
T="${T}menu:View/Show Services;wait:2;mark:hidden;menu:View/Console;wait:33;mark:after-grace;wait:1;mark:done;quit"
launch fake "$T" "$P1" "$P1/go.mod" KUBECONFIG="$FAKECFG"
follow 300 no_hook
READY_MS=$(mark_ms ready)
EARLY=$(awk -v t="$READY_MS" '$1 <= t && $2 == "GET"' "$REQ" | wc -l | tr -d ' ')
check KB0 "Nothing reaches the cluster before Kubernetes is shown" '[ -n "$READY_MS" ] && [ "$EARLY" = 0 ]' "requests before the section was shown: $EARLY"
check KB1 "The section lists pods with their status, a crash looping pod included" \
  'found_after listed "api-7d9f8-a1, Running" && found_after listed "api-7d9f8-b2, CrashLoopBackOff"' "shots/light-20-fake-populated.png"
W1=$(open_watches "$(mark_ms b9-pods)"); W2=$(open_watches "$(mark_ms b9-two)"); W3=$(open_watches "$(mark_ms b9-collapsed)")
check KB2 "B9: one watch per expanded kind, none for collapsed kinds" \
  '[ "$W1" = "api/pods(1)" ] && [ "$W2" = "api/deployments(1) api/pods(1)" ] && [ "$W3" = "api/deployments(1)" ] && found_after b9-two "api, 1/2 ready"' \
  "Pods only: ${W1:-none}; Pods and Deployments: ${W2:-none}; Pods collapsed: ${W3:-none}"
FORB=$(labels_after forbidden)
check KB3 "Forbidden: the list says the account can’t list pods in “locked” and offers Choose Namespace…" \
  'echo "$FORB" | grep -q "Can’t List Pods" && echo "$FORB" | grep -q "Your account can’t list pods in “locked”." && echo "$FORB" | grep -q "Choose Namespace…"' \
  "$(echo "$FORB" | grep -o "Can’t List Pods\|Your account can’t list pods in “locked”.\|Choose Namespace…" | sort -u | tr '\n' ';') shots/light-21-forbidden.png"
check KB4 "Choosing the namespace back lists its pods again" 'found_after ns-back "api-7d9f8-a1, Running"' ""
UNR=$(labels_after unreachable)
check KB5 "Unreachable: Can’t Reach Cluster names the server and offers Retry" \
  'echo "$UNR" | grep -q "Can’t Reach Cluster" && echo "$UNR" | grep -q "127.0.0.1:$CLOSED" && echo "$UNR" | grep -q "Retry"' \
  "$(echo "$UNR" | grep -o "Can’t Reach Cluster\|GoLens can’t reach the cluster at [^|.]*\|Retry" | sort -u | tr '\n' ';') shots/light-22-unreachable.png"
check KB6 "Retry keeps the explained state" 'labels_after retried | grep -q "Can’t Reach Cluster"' ""
check KB7 "Switching back to the reachable context lists its pods" 'found_after ctx-back "api-7d9f8-a1, Running"' ""
HIDDEN=$(mark_ms hidden)
LAST_CLOSE=$(awk -v h="$HIDDEN" '$1 >= h && $2 == "WATCH" && $3 == "close" { t = $1 } END { print t }' "$REQ")
LEFT=$(open_watches "$(mark_ms after-grace)")
check KB8 "B6: hiding the tab closes every watch within 31 s" '[ -n "$LAST_CLOSE" ] && [ $((LAST_CLOSE - HIDDEN)) -le 31000 ] && [ -z "$LEFT" ]' \
  "last watch closed $(( ${LAST_CLOSE:-0} - ${HIDDEN:-0} )) ms after hiding; open after the grace: ${LEFT:-none}"
check KB9 "The fake API leg reached the end" 'grep -q "DRIVE mark done" "$LOG"' ""
kill -TERM "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=

# ---- Leg 2: the owner's cluster, inside a temporary namespace
REACHABLE=0
if [ "${KUBE_JOURNEY_CLUSTER:-0}" = 1 ] && [ -n "$KUBECTL" ] && "$KUBECTL" config view --raw > "$TMPCFG" 2>/dev/null && chmod 600 "$TMPCFG" \
  && CTX0=$(kc config current-context 2>/dev/null) && [ -n "$CTX0" ] && kc --request-timeout=8s get --raw /version >/dev/null 2>&1; then
  REACHABLE=1
fi
if [ $REACHABLE = 1 ]; then
  SERVER0=$(kc config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  CLUSTER0=$(kc config view --raw -o jsonpath="{.contexts[?(@.name==\"$CTX0\")].context.cluster}" 2>/dev/null)
  USER0=$(kc config view --raw -o jsonpath="{.contexts[?(@.name==\"$CTX0\")].context.user}" 2>/dev/null)
  SUMS_BEFORE=$(cfg_sums)
  read -r API_HOST API_PORT < <(python3 -c 'import sys, socket, urllib.parse as u; p = u.urlparse(sys.argv[1]); port = p.port or 443; print(socket.getaddrinfo(p.hostname, port)[0][4][0], port)' "$SERVER0" 2>/dev/null)
  kc create namespace "$NS" >/dev/null 2>&1 && NS_CREATED=1
  kc label namespace "$NS" golens.smoke=1 >/dev/null 2>&1
  kc config set-context "$ALT" --cluster="$CLUSTER0" --user="$USER0" --namespace="$NS" >/dev/null 2>&1
  kc config set-context "$ALT2" --cluster="$CLUSTER0" --user="$USER0" --namespace="$NS" >/dev/null 2>&1
  kc config use-context "$ALT" >/dev/null 2>&1
  in_namespace() { awk -v ns="$NS" '{ print } /^metadata:$/ { print "  namespace: " ns }' "$1"; }
  in_namespace "$HERE/kube-fixture/workloads.yaml" > "$WORK/workloads.yaml"
  SCOPE_READY=0
  if [ "$NS_CREATED" = 1 ] && [ "$(kc config current-context 2>/dev/null)" = "$ALT" ] \
    && [ "$(kc config view --minify -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null)" = "$NS" ]; then
    SCOPE_READY=1
    kc -n "$NS" apply -f "$WORK/workloads.yaml" >/dev/null 2>&1
  fi
  kc -n "$NS" rollout status deploy/echo --timeout=180s >/dev/null 2>&1
  for _ in $(seq 1 60); do
    [ "$(kc -n "$NS" get pods -l app=crash -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null && break
    sleep 3
  done
  ECHO_POD=$(kc -n "$NS" get pods -l app=echo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  CRASH_POD=$(kc -n "$NS" get pods -l app=crash -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  P2=$WORK/kubeproj
  mkdir -p "$P2"
  in_namespace "$HERE/kube-fixture/project/deploy.yaml" > "$P2/deploy.yaml"
  printf 'module example.com/kubeproj\n\ngo 1.22\n' > "$P2/go.mod"
  api_conns() { [ -n "${API_HOST:-}" ] && lsof -nP -a -p "$APP_PID" -iTCP@"$API_HOST":"$API_PORT" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo "?"; }
  SCOPE_ABORTED=0; REPLACEMENT=; SHELL_PROCS=; KUBECTL_EARLY=; CONNS_ON=; CONNS_PODS_COLLAPSED=; CONNS_AFTER=; FORWARD_HTTP=; FORWARD_PORT=; DEFAULT_CTX=; ECHO_GONE=; FORWARD_LEFT=
  real_hook() {
    case $1 in
      listed)
        KUBECTL_EARLY=$(pgrep -P "$APP_PID" -f kubectl 2>/dev/null | wc -l | tr -d ' '); CONNS_ON=$(api_conns)
        if [ -n "$ECHO_POD" ] && grep -q "^DRIVE axfind $ECHO_POD, Running -> [1-9]" "$LOG"; then
          touch "$WORK/scope-ok"
        else
          SCOPE_ABORTED=1
          stop_app
        fi ;;
      forwarding)
        sleep 2
        FORWARD_PID=$(pgrep -P "$APP_PID" -f "port-forward svc/web-svc" 2>/dev/null | head -1)
        [ -n "$FORWARD_PID" ] && FORWARD_PORT=$(ps -o command= -p "$FORWARD_PID" | grep -o '[0-9]*:80$' | cut -d: -f1)
        [ -n "$FORWARD_PORT" ] && FORWARD_HTTP=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://localhost:$FORWARD_PORT/") ;;
      shell)
        SHELL_PROCS=$(pgrep -P "$APP_PID" -f "exec -it $ECHO_POD" 2>/dev/null | wc -l | tr -d ' ')
        sleep 2
        sed -i '' 's#image: nginx:1.27-alpine#image: nginx:golens-smoke-does-not-exist#' "$P2/deploy.yaml" ;;
      deleted)
        if ! kc -n "$NS" get pod "$ECHO_POD" >/dev/null 2>&1 || [ -n "$(kc -n "$NS" get pod "$ECHO_POD" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]; then
          ECHO_GONE=1
        else
          ECHO_GONE=0
        fi
        REPLACEMENT=$(kc -n "$NS" get pods -l app=echo -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v "^${ECHO_POD}\$" | grep -c .) ;;
      default-set) DEFAULT_CTX=$(kc config current-context 2>/dev/null) ;;
      pods-collapsed) CONNS_PODS_COLLAPSED=$(api_conns) ;;
      after-grace)
        CONNS_AFTER=$(api_conns)
        FORWARD_LEFT=$(pgrep -P "$APP_PID" -f "port-forward" 2>/dev/null | wc -l | tr -d ' ') ;;
    esac
  }
  APPLY_LABEL="Apply deploy.yaml to context $ALT, namespace $NS"
  T="wait:10;fakeactive;mark:ready;wait:2;menu:Tools/Kubernetes/Show Kubernetes;wait:18;"
  T="${T}mark:pre-list;axfind:$ECHO_POD, Running;axfind:$CRASH_POD, CrashLoopBackOff;mark:listed;waitfile:$WORK/scope-ok;$(both 01-populated)"
  T="${T}menu:Tools/Kubernetes/Apply to Cluster…;wait:15;mark:apply-sheet;deeplabels;$(bothsheet 02-apply-diff)axpress:$APPLY_LABEL;wait:4;mark:apply-console;deeplabels;menu:View/Show Services;wait:40;"
  T="${T}rowexpand:Deployments;wait:3;mark:applied;axfind:web, 1/1 ready;deeplabels;"
  T="${T}rowclick:$ECHO_POD;wait:5;mark:echo-logs;deeplabels;$(both 03-logs)"
  T="${T}rowclick:$CRASH_POD;wait:4;mark:crash;deeplabels;$(both 04-crashloop)"
  T="${T}axpress:Show Previous Logs;wait:5;mark:previous;deeplabels;$(both 05-previous-logs)"
  T="${T}rowmenu:$CRASH_POD|Show Details;wait:6;mark:details;deeplabels;$(both 06-details-events)"
  T="${T}fieldp:Filter:we;wait:1.5;rowexpand:Kubernetes Services;wait:3;rowclick:web-svc;wait:2;menu:Tools/Kubernetes/Port Forward…;wait:2;mark:forward-popover;popoverlabels;$(bothpopover 07-port-forward)"
  T="${T}axpress:Forward;wait:6;mark:forwarding;axfind:→ 80, Forwarding;$(both 08-forwarding)fieldp:Filter:;wait:1.5;"
  T="${T}rowclick:$ECHO_POD;wait:1;menu:Tools/Kubernetes/Open Shell in Pod;wait:6;term:echo golens-shell-ok"$'\r'";wait:3;mark:shell;deeplabels;"
  T="${T}menu:View/Show Services;wait:3;menu:Tools/Kubernetes/Apply to Cluster…;wait:15;mark:apply-bad;deeplabels;axpress:$APPLY_LABEL;wait:4;menu:View/Show Services;wait:60;"
  T="${T}mark:badimage;axfind:ImagePullBackOff;axfind:ErrImagePull;$(both 09-imagepull)"
  T="${T}fieldp:Filter:we;wait:1.5;rowclick:web;wait:1;menu:Tools/Kubernetes/Rollout Restart…;wait:1.5;mark:restart-confirm;wininfo;$(bothsheet 10-restart-confirm)sheetpress:Cancel;wait:1;mark:restart-canceled;fieldp:Filter:;wait:1.5;"
  T="${T}rowclick:$ECHO_POD;wait:1;menu:Tools/Kubernetes/Delete Pod…;wait:1.5;mark:delete-confirm;wininfo;$(bothsheet 11-delete-confirm)sheetpress:Delete Pod;wait:20;mark:deleted;deeplabels;"
  T="${T}menu:Tools/Kubernetes/Read-Only for This Context;wait:1;fieldp:Filter:we;wait:1.5;rowclick:web;wait:1;mark:readonly;menustate:Tools/Kubernetes/Rollout Restart…;menustate:Tools/Kubernetes/Delete Pod…;fieldp:Filter:;wait:1.5;"
  T="${T}menu:Tools/Kubernetes/Apply to Cluster…;wait:12;mark:apply-readonly;deeplabels;$(bothsheet 12-apply-readonly)axpress:Cancel;wait:1;menu:Tools/Kubernetes/Read-Only for This Context;wait:1;"
  T="${T}menu:Tools/Kubernetes/Context/$ALT2;wait:6;menu:Tools/Kubernetes/Use as kubectl Default…;wait:1.5;mark:default-confirm;wininfo;sheetpress:Use as kubectl Default;wait:5;mark:default-set;"
  T="${T}rowcollapse:Pods;wait:3;mark:pods-collapsed;"
  T="${T}menu:View/Show Services;wait:2;mark:hidden;menu:View/Console;wait:33;mark:after-grace;wait:3;mark:done;quit"
  if [ $SCOPE_READY = 1 ] && [ -n "$ECHO_POD" ]; then
    launch real "$T" "$P2" "$P2/deploy.yaml" KUBECONFIG="$TMPCFG"
    follow 900 real_hook
  else
    LOG=$ART/logs/real.log
    : > "$LOG"
    SCOPE_ABORTED=1
  fi
  check KR0 "Cluster: the app opens in the smoke namespace and lists the journey's own pod before anything is applied" \
    '[ "$SCOPE_ABORTED" = 0 ]' "temporary context and namespace ready: $SCOPE_READY; aborted before Apply: $SCOPE_ABORTED"
  check KR1 "Cluster: the list shows the running and the crash looping pod with their status" \
    'found_after pre-list "$ECHO_POD, Running" && found_after pre-list "$CRASH_POD, CrashLoopBackOff"' "shots/light-01-populated.png"
  check KR2 "Cluster: listing and watching start no kubectl process" '[ "${KUBECTL_EARLY:-1}" = 0 ]' "kubectl children while listing: ${KUBECTL_EARLY:-?}"
  SHEET=$(labels_after apply-sheet)
  check KR3 "Cluster: Apply to Cluster… names the target and shows the new objects in the diff" \
    'echo "$SHEET" | grep -q "Namespace “${NS}”" && echo "$SHEET" | grep -q "2 objects change" && echo "$SHEET" | grep -q "Deployment “web” (New)"' \
    "$(echo "$SHEET" | grep -o "2 objects change\|Deployment “web” (New)\|Added line [0-9]*: kind: Deployment" | sort -u | tr '\n' ';') shots/light-02-apply-diff.png"
  check KR4 "Cluster: Apply runs kubectl apply as a console session and the deployment becomes ready" \
    'labels_after apply-console | grep -q "kubectl apply -f deploy.yaml" && found_after applied "web, 1/1 ready"' ""
  check KR5 "Cluster: selecting a pod follows its logs" 'labels_after echo-logs | grep -q "golens-smoke-echo line"' "shots/light-03-logs.png"
  check KR6 "Cluster: a crash looping pod explains itself and offers Show Previous Logs" \
    'labels_after crash | grep -q "Is Failing" && labels_after crash | grep -q "Show Previous Logs"' "shots/light-04-crashloop.png"
  check KR7 "Cluster: Show Previous Logs reads the crashed container’s output" \
    'labels_after previous | grep -q "golens-smoke-crash failing on purpose" && labels_after previous | grep -q "Previous Container"' "shots/light-05-previous-logs.png"
  DET=$(labels_after details)
  check KR8 "Cluster: Details list the container’s last termination and the BackOff event" \
    'echo "$DET" | grep -q "BackOff" && echo "$DET" | grep -q "Last Termination" && echo "$DET" | grep -q "Events"' \
    "$(echo "$DET" | grep -o "Warning, BackOff\|Last Termination, [^|]*" | head -2 | tr '\n' ';') shots/light-06-details-events.png"
  POP=$(popover_after forward-popover)
  check KR9 "Cluster: Port Forward… names the service, namespace and context" \
    'echo "$POP" | grep -q "svc/web-svc in “${NS}”" && echo "$POP" | grep -q "Forward"' "shots/light-07-port-forward.png"
  check KR10 "Cluster: the forward answers HTTP 200 and shows as a child row" '[ "${FORWARD_HTTP:-}" = 200 ] && found_after forwarding "→ 80, Forwarding"' "localhost:${FORWARD_PORT:-?} answered ${FORWARD_HTTP:-nothing} — shots/light-08-forwarding.png"
  check KR11 "Cluster: Open Shell opens a Terminal tab running kubectl exec in the pod" \
    'labels_after shell | grep -q "$ECHO_POD (pod)" && [ "${SHELL_PROCS:-0}" -ge 1 ]' "Terminal tab \"<pod> (pod)\", kubectl exec processes: ${SHELL_PROCS:-?}"
  check KR12 "Cluster: the bad image shows the change in the diff and the new pod fails to pull with the failure tone" \
    'labels_after apply-bad | grep -q "golens-smoke-does-not-exist" && { found_after badimage "ImagePullBackOff" || found_after badimage "ErrImagePull"; }' "$(sed -n '/DRIVE mark badimage$/,$p' "$LOG" | grep -m1 -o 'axfind [A-Za-z]* -> [1-9][^|]*' | cut -c1-90) — shots/light-09-imagepull.png"
  check KR13 "Cluster: Rollout Restart… names context and namespace, and Cancel restarts nothing" \
    'between restart-confirm restart-canceled | grep -q "Restart Deployment “web”?" && between restart-confirm restart-canceled | grep -q "namespace “${NS}”"' "shots/light-10-restart-confirm.png"
  check KR14 "Cluster: Delete Pod… confirmed deletes the pod and its controller replaces it" \
    'between delete-confirm deleted | grep -q "Delete Pod “${ECHO_POD}”?" && [ "${ECHO_GONE:-0}" = 1 ] && [ "${REPLACEMENT:-0}" -ge 1 ]' "deleted: ${ECHO_GONE:-?}, replacement pods: ${REPLACEMENT:-?} — shots/light-11-delete-confirm.png"
  check KR15 "Cluster: a read-only context disables Delete Pod… and Rollout Restart…, and the Apply sheet says why" \
    'grep -q "menustate Tools/Kubernetes/Rollout Restart… enabled=0" "$LOG" && grep -q "menustate Tools/Kubernetes/Delete Pod… enabled=0" "$LOG" && labels_after apply-readonly | grep -q "Is Read-Only"' "shots/light-12-apply-readonly.png"
  check KR16 "Cluster: Use as kubectl Default asks first and writes only the temporary kubeconfig copy" \
    '[ "$DEFAULT_CTX" = "$ALT2" ] && [ "$(cfg_sums)" = "$SUMS_BEFORE" ]' "temporary copy current-context: $( [ "$DEFAULT_CTX" = "$ALT2" ] && echo "$ALT2" || echo unchanged ); owner kubeconfig unchanged: $( [ "$(cfg_sums)" = "$SUMS_BEFORE" ] && echo yes || echo NO )"
  check KR17 "Cluster: watches share client-go's HTTP/2 connection, collapsing Pods keeps it for the other kinds, and hiding closes it within 31 s (B6, B9)" \
    '[ "${CONNS_ON:-0}" -ge 1 ] && [ "${CONNS_AFTER:-1}" = 0 ]' \
    "API server connections: shown ${CONNS_ON:-?}, Pods collapsed ${CONNS_PODS_COLLAPSED:-?}, 33 s after hiding ${CONNS_AFTER:-?}"
  check KR18 "Cluster: the journey reached the end" 'grep -q "DRIVE mark done" "$LOG"' "port-forward processes left when the app quit: ${FORWARD_LEFT:-?} (stopped with the app)"
else
  if [ "${KUBE_JOURNEY_CLUSTER:-0}" != 1 ]; then
    skip KR1 "Cluster leg" "Set KUBE_JOURNEY_CLUSTER=1 to run it against the kubeconfig's current context, inside a temporary namespace."
  else
    skip KR1 "Cluster leg" "No kubeconfig context answers (kubectl get --raw /version failed or kubectl is missing); start a cluster or fix the kubeconfig to run this leg."
  fi
fi

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
