#!/bin/bash
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
MODE=${MODE:-vm}
WORKLOAD=${WORKLOAD:-mesh}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${BIN:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 2; }
WARM=${WARM:-45}

if [ "$MODE" = vm ]; then DOMAIN=dev.golens.test.typingstress; else DOMAIN=dev.golens.test.typingstress.local; fi
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
GUEST_CACHE="$CONTAINER_DIR/Library/Caches/com.golens.app/gobuild"
WS=$HOME/Documents/golens-stress-$WORKLOAD
rm -rf "$WS"
if [ "$WORKLOAD" = mesh ]; then
  python3 "$HERE/stress-mesh-gen.py" "$WS" 16 || { echo "generator failed"; exit 2; }
  HUB=core/entity.go; GENERIC=core/generic.go; IFACE_FILE=core/entity.go; LEAF=service/s9/service.go
else
  cp -R "${LMS_DIR:-$HOME/Documents/golens-typing-lms}" "$WS" || { echo "missing lms copy"; exit 2; }
  HUB=internal/models/user.go; GENERIC=internal/helpers/respond.go; IFACE_FILE=internal/storage/store.go; LEAF=internal/features/chat/service.go
fi
if [ -n "${GIT_REPO:-}" ]; then
  git -C "$WS" init -q && git -C "$WS" add -A && git -C "$WS" -c user.email=stress@example.invalid -c user.name=stress commit -qm base || { echo "git init failed"; exit 2; }
fi
PREFS=()
[ -n "${OWNER_PREFS:-}" ] && PREFS=(-GoLensShowGopilot '<true/>' -GoLensShowInlayHints '<false/>')
[ "${USAGE_COUNTS:-on}" = off ] && PREFS+=(-GoLensShowUsageCounts '<false/>')
if [ "$MODE" = vm ]; then
  mkdir -p "$CONTAINER_DIR/tmp"
  WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-stress.XXXXXX")" && pwd -P)
else
  WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/golens-stress-local.XXXXXX")" && pwd -P)
fi
OUT=${STRESS_OUT:-$WORK/out}
mkdir -p "$OUT"
APP_PID=
OWNED_PIDS=
SAMPLER_PID=
HOSTMON_PID=
LOGSTREAM_PID=

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  rm -f "$GUEST_CACHE/stress-guest.run"
  [ -n "$SAMPLER_PID" ] && kill -TERM "$SAMPLER_PID" 2>/dev/null
  [ -n "$HOSTMON_PID" ] && kill -TERM "$HOSTMON_PID" 2>/dev/null
  [ -n "$LOGSTREAM_PID" ] && kill -TERM "$LOGSTREAM_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  cp "$GUEST_CACHE/stress-guest.log" "$OUT/" 2>/dev/null
  rm -f "$GUEST_CACHE/stress-guest.log" "$GUEST_CACHE/stress-guest.sh"
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ -z "${KEEP_WORKLOAD:-}" ] && rm -rf "$WS"
  if [ -z "${STRESS_OUT:-}" ]; then echo "artifacts: (removed with the work dir; set STRESS_OUT to keep them)"; fi
  rm -rf "$WORK/app" "$WORK/driver.dylib" "$WORK/quiet.dylib"
  [ -z "${STRESS_OUT:-}" ] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [ "$MODE" = vm ]; then
  BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
  if [ -n "${VM_AGENT:-}" ]; then
    cp "$VM_AGENT" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/golens-vm-agent" || { echo "VM_AGENT copy failed"; exit 2; }
  fi
  if [ -n "${VM_GOPLS:-}" ]; then
    cp "$VM_GOPLS" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/goroot/bin/gopls" || { echo "VM_GOPLS copy failed"; exit 2; }
  fi
  mkdir -p "$GUEST_CACHE"
  cat > "$GUEST_CACHE/stress-guest.sh" <<'GUEST'
out=/cache/gobuild/stress-guest.log
cg=/sys/fs/cgroup/golens/lsp
: > $out
while [ -e /cache/gobuild/stress-guest.run ]; do
  procs=""
  for p in $(cat $cg/cgroup.procs 2>/dev/null); do
    procs="$procs $(cat /proc/$p/comm 2>/dev/null):$p:rss=$(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null):ticks=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)"
  done
  echo "ep=$(date +%s) up=$(cut -d' ' -f1 /proc/uptime) cur=$(cat $cg/memory.current 2>/dev/null) avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo) swap=$(awk 'NR>1{s+=$4} END{print s+0}' /proc/swaps) zram=[$(cat /sys/block/zram0/mm_stat 2>/dev/null)] events=[$(tr '\n' ' ' < $cg/memory.events 2>/dev/null)] $(grep oom_kill /proc/vmstat) procs=[$procs] total=$(awk '/MemTotal/{print $2}' /proc/meminfo) balloon=$(awk '/nr_balloon_pages/{print $2}' /proc/vmstat) high=$(cat $cg/memory.high 2>/dev/null) swapcur=$(cat $cg/memory.swap.current 2>/dev/null)" >> $out
  sleep 1
done
GUEST
  touch "$GUEST_CACHE/stress-guest.run"
else
  cat > "$WORK/local.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PLIST
  ENTITLEMENTS="$WORK/local.entitlements" BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
fi
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

ESC=$(printf '\342\216\213')
DEL=$(printf '\342\214\253')
PAUSE=$(printf '\342\217\270')
dels() { local s="" k; for k in $(seq 1 "$1"); do s="$s$DEL"; done; printf '%s' "$s"; }
open_file() { printf 'menu:File/Open Quickly…;wait:0.8;fr:%s;wait:0.6;postkey:36;wait:1.2;head;' "$1"; }
SLOW=code; FAST=codefast
case "${INPUT:-direct}" in keys) SLOW=keys; FAST=keysfast ;; ime) SLOW=imecode; FAST=imecode ;; esac
complete() { printf '%s:%s;wait:1.2;panel;%s:%s%s;' "$SLOW" "$1" "$SLOW" "$ESC" "$(dels ${#1})"; }

if [ "$WORKLOAD" = mesh ]; then
  LEAF_CARET='sum.Updated = x.UpdatedAt\n\t\t}\n\t}'
  BURST="\\nlimit := s.deps.Config.PageSize + len(items)${PAUSE}\\nlabel := fmt.Sprintf(\"%s-%d\", s.Name(), limit)\\nids := core.Map(items, func(x *d9.Report) core.ID { return x.ID })${PAUSE}\\n_ = label\\n_ = ids\\n"
  COMPLETIONS="$(complete 's.deps.Config.Ma')$(complete 'core.Wh')$(complete 's.repo.Li')$(complete 'd9.New')"
  AUTOIMPORT='code:id := uuid.NewStr;wait:1.6;panel;code:\t;wait:0.8;line;code:\n;'
  HUB_RENAME="caret:\tUpdatedAt;code:$(dels 9)ModifiedAt;"
  HUB_RENAME_BACK="caret:\tModifiedAt;code:$(dels 10)UpdatedAt;"
  SIG_CHANGE='caret:func Where[T any](in []T, keep func(T) bool;code:, limit int;'
  SIG_BACK="caret:keep func(T) bool, limit int;code:$(dels 11);"
  IFACE_ADD='caret:\tTouch(at time.Time);code:\nArchive() error;'
  IFACE_BACK="caret:Archive() error;code:$(dels 17);"
  HOVER='hover:Summary;wait:1.5;hover:Create;wait:1.5;'
  BIGSEL='func (s *Service) Name() string'
  RESUME='ids := core.Map'
else
  LEAF_CARET='func (s *Service) getToolDoneMessage(toolName string, err string) string {'
  BURST='\nlabel := fmt.Sprintf("%s-%s", toolName, err)⏸\nparts := strings.Split(label, "-")\ntotal := len(parts) + len(toolName)⏸\n_ = total\n'
  COMPLETIONS="$(complete 's.getToolD')$(complete 'strings.HasPre')$(complete 's.')"
  AUTOIMPORT='code:id := uuid.NewStr;wait:1.6;panel;code:\t;wait:0.8;line;code:\n;'
  HUB_RENAME="caret:\tFullName;code:$(dels 8)DisplayName;"
  HUB_RENAME_BACK="caret:\tDisplayName;code:$(dels 11)FullName;"
  SIG_CHANGE='caret:func Fail(c *gin.Context, status int, message string;code:, code string;'
  SIG_BACK="caret:message string, code string;code:$(dels 13);"
  METHOD='Stat(ctx context.Context, key string) error'
  IFACE_ADD="caret:type Store interface {;code:\\n$METHOD;"
  IFACE_BACK="caret:$METHOD;code:$(dels $((${#METHOD} + 2)));"
  HOVER='hover:getToolDoneMessage;wait:1.5;'
  BIGSEL='func (s *Service) getToolDoneMessage'
  RESUME='total := len(parts) + len(toolName)'
fi
TYPE_ROUND="$FAST:$BURST;$COMPLETIONS"
phase() { printf 'keystats:%s;hangmon:report;time:%s;' "$1" "$2"; }

GUESTMON=
[ "$MODE" = vm ] && GUESTMON='guestsh:( setsid sh /cache/gobuild/stress-guest.sh </dev/null >/dev/null 2>&1 & )'
T="wait:4;fakeactive;mark:ready;$GUESTMON;wait:$WARM;time:warm;head;caret:$LEAF_CARET;code:\\n// ;keylat:100;code:\\n;hangmon:on;keystats:reset;mark:sample-start;time:leaf;"
T="$T$TYPE_ROUND$TYPE_ROUND$(phase leaf leaf-done)"
if [ "${SCENARIO:-}" = input ]; then
  for verbs in "direct codefast code" "keys keysfast keys" "ime imecode imecode" "direct2 codefast code" "keys2 keysfast keys"; do
    read -r name fast slow <<<"$verbs"
    SLOW=$slow
    T="${T}caret:$RESUME;code:\\n;time:$name;$fast:$BURST;$(complete "${COMPLETION_PROBE:-s.}")$fast:$BURST;$(phase "$name" "$name-done")"
  done
  HUB_RENAME=
  T="${T}hangmon:report;mark:done;quit"
fi
if [ "${SCENARIO:-}" = switch ]; then
  SWITCHES=${SWITCHES:-60}
  FILES=$(cd "$WS" && find . -name '*.go' ! -name '*_test.go' ! -path "./$LEAF" | sed 's|^\./||' | sort | head -$((SWITCHES * 2)))
  T="${T}caret:$RESUME;code:\\n;time:typing-0;$TYPE_ROUND$(phase typing-0 opening-1)"
  n=0
  for f in $FILES; do
    n=$((n + 1))
    T="$T$(open_file "$f")"
    if [ $n = "$SWITCHES" ] || [ $n = $((SWITCHES * 2)) ]; then
      T="$T$(open_file "$LEAF")caret:$RESUME;code:\\n;time:typing-$n;$TYPE_ROUND$(phase "typing-$n" "opening-$n")"
    fi
  done
  if [ -n "${RESTART_VM:-}" ]; then
    T="${T}time:restart;menu:View/Command Palette…;wait:1;fieldp:Type a command…:reload;wait:0.8;mark:palette-reload;shot:palette-reload;fieldp:Type a command…:Restart Linux Machine;wait:0.5;postkey:36;wait:${RESTART_SETTLE:-90};"
    T="$T$(open_file "$LEAF")caret:$RESUME;code:\\n;time:after-restart;$TYPE_ROUND$(phase after-restart after-restart-done)"
  fi
  HUB_RENAME=
  T="${T}hangmon:report;mark:done;quit"
fi
if [ -n "$HUB_RENAME" ]; then
  for pair in "rename|$HUB|$HUB_RENAME|$HUB_RENAME_BACK" "signature|$GENERIC|$SIG_CHANGE|$SIG_BACK" "interface|$IFACE_FILE|$IFACE_ADD|$IFACE_BACK"; do
    IFS='|' read -r name file edit back <<<"$pair"
    T="$T$(open_file "$file")time:$name-edit;$edit$(open_file "$LEAF")caret:$RESUME;code:\\n;time:$name-typing;$TYPE_ROUND$TYPE_ROUND$(phase "$name" "$name-typed")"
    T="$T$(open_file "$file")$back$(open_file "$LEAF")caret:$RESUME;code:\\n;time:$name-revert;$TYPE_ROUND$(phase "$name-revert" "$name-reverted")"
  done
fi
[ -n "${SCENARIO:-}" ] || T="${T}time:hover;$HOVER$(phase hover hover-done)"
[ -n "${SCENARIO:-}" ] || T="${T}caret:$RESUME;code:\\n;time:autoimport;$AUTOIMPORT$(phase autoimport autoimport-done)"
[ -n "${SCENARIO:-}" ] || T="${T}time:bigedit;select:$BIGSEL;key:moveToEndOfDocumentAndModifySelection:;key:deleteBackward:;wait:1.5;undo;wait:1.5;redo;wait:1.5;undo;wait:1.5;caret:$RESUME;code:\\n;$FAST:$BURST;$(phase bigedit bigedit-done)"
[ -n "${SCENARIO:-}" ] || T="${T}time:save;save;wait:2;$FAST:$BURST;save;wait:2;$(phase save save-done)hangmon:report;mark:done;quit"

IDLE_TAIL=${IDLE_TAIL:-0}
[ "$IDLE_TAIL" -gt 0 ] && T="${T%quit}fakeinactive;wait:$IDLE_TAIL;mark:idle-done;quit"

LOG=$WORK/stress-$MODE.log
envs=(DRIVE="$T" DRIVE_OUT="$LOG" DRIVE_SHOTS="$WORK" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" GOLENS_MEASURE=1 GOLENS_LSP_TRACE=1 DRIVE_GUEST_CWD="$WS")
if [ "$MODE" = vm ]; then
  envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-vm}")
else
  envs+=(GOLENS_EXECUTION_MODE="${GOLENS_EXECUTION_MODE:-host}")
fi
[ -n "${GOLENS_VM_MEMORY_MB:-}" ] && envs+=(GOLENS_VM_MEMORY_MB="$GOLENS_VM_MEMORY_MB")
log stream --style compact --level debug --predicate "subsystem == \"$DOMAIN\"" > "$OUT/core-$MODE.log" 2>&1 &
LOGSTREAM_PID=$!
sleep 1
echo "GoLens typing stress journey — mode=$MODE — workload $WS — leaf $LEAF — out $OUT"
env "${envs[@]}" "$APP" -GoLensLastWorkspacePath "$WS" -GoLensLastFilePath "$WS/$LEAF" -GoLensShowConsole '<true/>' -NSAppSleepDisabled YES ${PREFS[@]+"${PREFS[@]}"} > "$OUT/app-$MODE.log" 2>&1 &
APP_PID=$!
python3 "$HERE/stress-host-sampler.py" "$APP_PID" > "$OUT/host-$MODE.log" 2>&1 &
HOSTMON_PID=$!

sampled=0
i=0
RESTART_EXTRA=0
[ -n "${RESTART_VM:-}" ] && RESTART_EXTRA=$((${RESTART_SETTLE:-90} + 120))
LIMIT=$((WARM + 900 + IDLE_TAIL + RESTART_EXTRA))
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $((LIMIT * 5)) ]; do
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  if [ $sampled = 1 ] && ! kill -0 "$SAMPLER_PID" 2>/dev/null; then sampled=2; fi
  if [ $sampled != 1 ] && grep -q 'DRIVE mark sample-start' "$LOG" 2>/dev/null && ! grep -q 'DRIVE mark done' "$LOG" 2>/dev/null; then
    sampled=1
    sample "$APP_PID" 20 2 -mayDie -file "$OUT/sample-$MODE-$(date +%s).txt" >/dev/null 2>&1 &
    SAMPLER_PID=$!
  fi
  sleep 0.2; i=$((i + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then echo "  (timeout; killing app)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
[ -n "$SAMPLER_PID" ] && wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=
kill -TERM "$HOSTMON_PID" 2>/dev/null; HOSTMON_PID=
kill -TERM "$LOGSTREAM_PID" 2>/dev/null; LOGSTREAM_PID=
cp "$LOG" "$OUT/" 2>/dev/null
cp "$GUEST_CACHE/stress-guest.log" "$OUT/" 2>/dev/null
python3 "$HERE/stress-report.py" "$OUT" "$MODE"
