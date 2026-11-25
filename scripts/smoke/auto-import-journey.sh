#!/bin/bash
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${BIN:-$REPO/.build/release/GoLensApp}
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 2; }
CYCLES=${CYCLES:-6}
WARM=${WARM:-45}
STEADY=${STEADY:-150}
DOMAIN=dev.golens.test.autoimport
CONTAINER_DIR="$HOME/Library/Containers/$DOMAIN/Data"
GOBUILD="$CONTAINER_DIR/Library/Caches/com.golens.app/gobuild"
mkdir -p "$CONTAINER_DIR/tmp"
WORK=$(cd "$(mktemp -d "$CONTAINER_DIR/tmp/golens-autoimport.XXXXXX")" && pwd -P)
OUT=${AUTOIMPORT_OUT:-$WORK/out}
mkdir -p "$OUT"
APP_PID=
OWNED_PIDS=
SAMPLER_PID=
LOGSTREAM_PID=
FIXTURE=

make_fixture() {
  rm -rf "$1"; mkdir -p "$1/store" "$1/chat"
  cat > "$1/go.mod" <<'EOF'
module example.com/autoimport

go 1.25.0

require (
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.22.0
)

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	go.uber.org/atomic v1.11.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)
EOF
  cat > "$1/go.sum" <<'EOF'
github.com/cespare/xxhash/v2 v2.3.0 h1:UL815xU9SqsFlibzuggzjXhog7bL6oX9BbNZnL2UFvs=
github.com/cespare/xxhash/v2 v2.3.0/go.mod h1:VGX0DQ3Q6kWi7AoAeZDth3/j3BFtOZR5XLFGgcrjCOs=
github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
github.com/redis/go-redis/v9 v9.22.0 h1:laDvpYXTJtZLloinw1fA5Kqd6HAEH2XKxOkG/PDq2F0=
github.com/redis/go-redis/v9 v9.22.0/go.mod h1:y2g0Wj8rQvuK0ELM+oxSudcLtC09JScs98I/X9gRWY4=
go.uber.org/atomic v1.11.0 h1:ZvwS0R+56ePWxUNi+Atn9dWONBPp/AUETXlHW0DxSjE=
go.uber.org/atomic v1.11.0/go.mod h1:LUxbIzbOniOlMKjJjyPfpl4v+PKK2cNJn91OQbhoJI0=
golang.org/x/sys v0.47.0 h1:o7XGOvZQCADBQQ4Y7VNq2dRWQR7JmOUW8Kxx4ZsNgWs=
golang.org/x/sys v0.47.0/go.mod h1:4GL1E5IUh+htKOUEOaiffhrAeqysfVGipDYzABqnCmw=
EOF
  cat > "$1/main.go" <<'EOF'
package main

import (
	"context"
	"fmt"

	"example.com/autoimport/chat"
	"example.com/autoimport/store"
)

func main() {
	fmt.Println(chat.Stats(context.Background(), store.New("localhost:6379"), "{}"))
}
EOF
  cat > "$1/store/store.go" <<'EOF'
package store

import (
	"context"

	"github.com/redis/go-redis/v9"
)

type Store struct {
	rdb *redis.Client
}

func New(addr string) *Store {
	return &Store{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}

func (s *Store) Get(ctx context.Context, key string) (string, error) {
	return s.rdb.Get(ctx, key).Result()
}
EOF
  cat > "$1/chat/stats_tool.go" <<'EOF'
package chat

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"example.com/autoimport/store"
	"github.com/google/uuid"
)

type ToolResult struct {
	ToolCallID string
	Error      string
	Content    string
}

func Stats(ctx context.Context, s *store.Store, raw string) ToolResult {
	fail := func(err error) ToolResult { return ToolResult{ToolCallID: raw, Error: err.Error()} }
	var params struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(raw), &params); err != nil {
		return fail(fmt.Errorf("invalid parameters: %w", err))
	}
	id, err := uuid.Parse(params.ID)
	if err != nil {
		return fail(fmt.Errorf("invalid ID"))
	}
	v, err := s.Get(ctx, id.String())
	if err != nil {
		return fail(err)
	}
	return ToolResult{ToolCallID: raw, Content: fmt.Sprint(v, math.Round(1.5))}
}
EOF
}

if [ -n "${AUTOIMPORT_DIR:-}" ]; then
  WS=$AUTOIMPORT_DIR
  FILE=${AUTOIMPORT_FILE:-internal/features/chat/stats_tool.go}
else
  FIXTURE=$HOME/Documents/golens-autoimport
  make_fixture "$FIXTURE"
  WS=$FIXTURE
  FILE=chat/stats_tool.go
fi
[ -f "$WS/$FILE" ] || { echo "missing workload file: $WS/$FILE"; exit 2; }
cp "$WS/$FILE" "$WORK/original.go"

descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }

cleanup() {
  [ -n "$SAMPLER_PID" ] && kill -TERM "$SAMPLER_PID" 2>/dev/null
  [ -n "$LOGSTREAM_PID" ] && kill -TERM "$LOGSTREAM_PID" 2>/dev/null
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  for k in $OWNED_PIDS; do kill -TERM "$k" 2>/dev/null; done
  sleep 1
  for k in $OWNED_PIDS $APP_PID; do kill -KILL "$k" 2>/dev/null; done
  cp "$WORK/original.go" "$WS/$FILE"
  cp "$WS"/guest-*.txt "$OUT/" 2>/dev/null
  rm -f "$WS"/guest-*.txt
  [ -n "$FIXTURE" ] && rm -rf "$FIXTURE"
  defaults delete $DOMAIN >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ -z "${AUTOIMPORT_OUT:-}" ] && echo "artifacts: (removed with the work dir; set AUTOIMPORT_OUT to keep them)"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
if [ -n "${VM_AGENT:-}" ]; then
  cp "$VM_AGENT" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/golens-vm-agent" || { echo "VM_AGENT copy failed"; exit 2; }
fi
if [ -n "${VM_GOPLS:-}" ]; then
  cp "$VM_GOPLS" "$CONTAINER_DIR/Library/Application Support/GoLens/VMRuntime/goroot/bin/gopls" || { echo "VM_GOPLS copy failed"; exit 2; }
fi
[ "${FRESH_INDEX:-0}" = 1 ] && rm -rf "$GOBUILD/golens-xdg/goimports"
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1

ESC=$(printf '\342\216\213')
DEL=$(printf '\342\214\253')
EOL=$(printf '\342\207\245')
JSON_ERRORS_FMT='"encoding/json"\n\t"errors"\n\t"fmt"'
MATH_STRINGS='"math"\n\t"strings"\n'
BARE="code:\\nerr;panelwait:bare;wait:1;panel;code:$ESC$DEL$DEL$DEL;code:\\nstr;panelwait:bare;wait:1;panel;code:$ESC$DEL$DEL$DEL;code:\\nredis;panelwait:bare;wait:1;panel;code:$ESC$DEL$DEL$DEL$DEL$DEL;code:\\ncobr;panelwait:bare;wait:1;panel;code:$ESC$DEL$DEL$DEL$DEL;"
PICK="code:$ESC;clearline;"
T="wait:4;fakeactive;mark:ready;wait:$WARM;time:warm;mark:warm;\
caret:Error: err.Error()} };\
time:sel-errors;code:\\n_ = errors.Jo;panelwait:sel;wait:1;panel;code:\\t;wait:2;line;find:$JSON_ERRORS_FMT;${PICK}mark:sel-errors-done;\
time:sel-strings;code:\\n_ = strings.Tri;panelwait:sel;wait:1;panel;code:\\t;wait:2;line;find:$MATH_STRINGS;${PICK}mark:sel-strings-done;\
time:sel-redis;code:\\n_ = redis.NewCl;panelwait:sel;wait:1;panel;code:\\t;wait:2;line;find:\"github.com/redis/go-redis/v9\";${PICK}mark:sel-redis-done;\
keylat:150;hangmon:on;mark:bare-start;"
for i in $(seq 1 "$CYCLES"); do T="${T}time:bare-$i;$BARE"; done
T="${T}hangmon:report;mark:bare-done;text;wait:20;mark:restart;restartls;wait:$WARM;mark:restarted;\
time:sel-bytes;code:\\n_ = bytes.Equa;panelwait:sel;wait:1;panel;code:\\t;wait:2;line;find:\"bytes\";${PICK}mark:sel-bytes-done;\
time:sel-redis2;code:\\n_ = redis.NewCl;panelwait:sel;wait:1;panel;code:\\t;wait:2;line;find:\"github.com/redis/go-redis/v9\";${PICK}mark:sel-redis2-done;\
hangmon:on;"
for i in $(seq 1 "$CYCLES"); do T="${T}time:bare-r$i;$BARE"; done
if [ "${GOLENS_EXECUTION_MODE:-host}" = "vm" ]; then
  IDLE="guestsh:sh -c 'i=0\\nwhile [ \$i -lt $((STEADY * 2)) ]\\ndo read n _ < /proc/sys/fs/inode-nr\\nread up _ < /proc/uptime\\nread -r cpu < /proc/stat\\necho \"\$up \$n \$cpu\" >> guest-idle.txt\\ni=\$((i+1))\\nsleep 0.5\\ndone';"
else
  IDLE=""
fi
T="${T}hangmon:report;keylat:150;text;mark:steady;${IDLE}wait:$((STEADY + 5));mark:steady-done;mark:done;quit"
[ -n "${DRIVE_STEPS:-}" ] && T=$DRIVE_STEPS

LOG=$WORK/autoimport.log
envs=(DRIVE="$T" DRIVE_GUEST_CWD="$WS" DRIVE_OUT="$LOG" DRIVE_SHOTS="$OUT" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" GOLENS_MEASURE=1 GOLENS_LSP_TRACE=1)
envs+=(GOLENS_VM_MEMORY_MB="${GOLENS_VM_MEMORY_MB:-512}")
PRE_VMS=" $(pgrep -f com.apple.Virtualization.VirtualMachine | tr '\n' ' ') "
log stream --style compact --level debug --predicate "subsystem == \"$DOMAIN\"" > "$OUT/core.log" 2>&1 &
LOGSTREAM_PID=$!
sleep 1
echo "GoLens auto-import journey: workload $WS/$FILE, cycles $CYCLES, fresh index ${FRESH_INDEX:-0}, out $OUT"
env "${envs[@]}" "$APP" -GoLensLastWorkspacePath "$WS" -GoLensLastFilePath "$WS/$FILE" -GoLensShowConsole '<true/>' > "$OUT/app.log" 2>&1 &
APP_PID=$!

sample_fds() {
  local vm= k phase n mod peak=0
  printf 'epoch\tphase\ttotal\tgomod\n' > "$OUT/fd.tsv"
  while kill -0 "$APP_PID" 2>/dev/null; do
    [ -n "$vm" ] && ! kill -0 "$vm" 2>/dev/null && { echo "$(date +%s) exited $vm" >> "$OUT/vm.pid"; PRE_VMS="$PRE_VMS$vm "; vm=; }
    if [ -z "$vm" ]; then
      for k in $(pgrep -f com.apple.Virtualization.VirtualMachine); do
        case "$PRE_VMS" in *" $k "*) ;; *) vm=$k ;; esac
      done
      [ -n "$vm" ] && echo "$(date +%s) started $vm" >> "$OUT/vm.pid"
    fi
    if [ -n "$vm" ]; then
      lsof -n -P -p "$vm" -Fn 2>/dev/null > "$WORK/lsof.txt"
      n=$(grep -c '^n' "$WORK/lsof.txt")
      mod=$(grep -c "^n$HOME/go/pkg/mod" "$WORK/lsof.txt")
      if [ "$n" -gt "$peak" ]; then peak=$n; cp "$WORK/lsof.txt" "$OUT/peak-lsof.txt"; fi
      phase=$(grep -E '^DRIVE (mark|time) ' "$LOG" 2>/dev/null | tail -1 | awk '{print $3}')
      printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${phase:-boot}" "$n" "$mod" >> "$OUT/fd.tsv"
    fi
    sleep 2
  done
}
sample_fds &
SAMPLER_PID=$!

i=0
LIMIT=$((WARM * 2 + STEADY + CYCLES * 50 + 240))
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt $((LIMIT * 5)) ]; do
  OWNED_PIDS="$OWNED_PIDS $(descendants "$APP_PID" | tr '\n' ' ')"
  sleep 0.2; i=$((i + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then echo "  (timeout; killing app)" >&2; kill -TERM "$APP_PID"; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; fi
sleep 3
kill -TERM "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=
LAST_VM=$(awk '$2=="started" {p=$3} END {print p}' "$OUT/vm.pid" 2>/dev/null)
j=0; while [ -n "$LAST_VM" ] && kill -0 "$LAST_VM" 2>/dev/null && [ $j -lt 20 ]; do sleep 0.5; j=$((j + 1)); done
if [ -n "$LAST_VM" ] && kill -0 "$LAST_VM" 2>/dev/null; then echo "  vm process $LAST_VM still running 10 s after the app quit"; else echo "  vm process ${LAST_VM:-none} exited with the app"; fi
kill -TERM "$LOGSTREAM_PID" 2>/dev/null; LOGSTREAM_PID=
cp "$LOG" "$OUT/" 2>/dev/null; LOG=$OUT/autoimport.log
cp "$WS"/guest-*.txt "$OUT/" 2>/dev/null; rm -f "$WS"/guest-*.txt

grep -E "^DRIVE (panel|line|keylat|hangmon|restartls|mark done)|' -> (present|absent)$" "$LOG" | sed 's/^DRIVE /  /' | cut -c1-400
grep -cE 'request timed out' "$OUT/core.log" | sed 's/^/  gopls request timeouts: /'
for kind in sel bare; do
  grep -E "^DRIVE panelwait $kind " "$LOG" | awk -v k="$kind" '$4=="timeout" {t++; next} {print $4}' | sort -n | awk -v k="$kind" -v total="$(grep -cE "^DRIVE panelwait $kind " "$LOG")" '{a[NR]=$1} END {if (NR) printf "  panel after last key, %s: shown %d of %d, p50 %s ms, p90 %s ms, max %s ms\n", k, NR, total, a[int((NR+1)/2)], a[int(NR*0.9+0.99)], a[NR]; else printf "  panel after last key, %s: shown 0 of %d\n", k, total}'
done
awk '/^DRIVE TEXT<<</ {buf=""; on=1; next} on && /^>>>/ {last=buf; on=0; next} on {buf=buf $0 "\n"} END {printf "%s", last}' "$LOG" > "$OUT/final.go"
awk '/^import \(/ {on=1} on {print} on && /^\)/ {exit}' "$OUT/final.go" > "$OUT/imports.txt"
{ echo "package p"; echo; cat "$OUT/imports.txt"; } > "$OUT/imports.go"
IMPORT_STATUS=0
if [ ! -s "$OUT/imports.txt" ]; then echo "  final import block: no text dump"; IMPORT_STATUS=1
elif [ -z "$(gofmt -l "$OUT/imports.go")" ]; then echo "  final import block, gofmt-clean:"
else echo "  final import block, NOT gofmt-clean:"; IMPORT_STATUS=1; fi
sed 's/^/    /' "$OUT/imports.txt"
[ -f "$OUT/guest-idle.txt" ] && awk 'NR==1 {u0=$1; for (i=4;i<=NF;i++) a[i]=$i} {n=$2; if (NR==1||n<mn) mn=n; if (n>mx) mx=n; if (NR>1 && p>8192 && n<p/2) d++; p=n; u1=$1; for (i=4;i<=NF;i++) b[i]=$i; c=NF} END {t=0; for (i=4;i<=c;i++) t+=b[i]-a[i]; id=(b[7]-a[7])+(b[8]-a[8]); printf "  guest idle: %d samples over %.0f s, inode-nr min %d max %d, drops %d, guest cpu busy %.2f%% of all cores\n", NR, u1-u0, mn, mx, d+0, t ? 100*(t-id)/t : 0}' "$OUT/guest-idle.txt"
awk -F'\t' 'NR>1 {if ($3>mx) mx=$3; if ($4>mm) mm=$4; last=$3; lastm=$4} END {printf "  vm fds: samples=%d peak=%d peak-gomod=%d last=%d last-gomod=%d\n", NR-1, mx, mm, last, lastm}' "$OUT/fd.tsv"
awk -F'\t' 'NR>1 {if (!($2 in pk) || $3>pk[$2]) pk[$2]=$3; if (!($2 in seen)) {seen[$2]=1; order[++n]=$2}} END {for (i=1;i<=n;i++) printf "    %-18s max %d\n", order[i], pk[order[i]]}' "$OUT/fd.tsv"
exit $IMPORT_STATUS
