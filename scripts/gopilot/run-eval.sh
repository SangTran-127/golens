#!/bin/bash
# Live eval: runs tests/gopilot/eval/prompts.json inside the real app (DEBUG build) and writes one results file.
# Usage: GOPILOT_DEV_ENV_FILE=/path/key.env scripts/gopilot/run-eval.sh [--runs N] [--out DIR] [--only ID,ID] [--probes N] [--prompts FILE] [path/to/debug/GoLensApp]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
RUNS=3
OUT=
ONLY=
PROBES=0
PROMPTS_FILE=$REPO/tests/gopilot/eval/prompts.json
BIN=$REPO/.build/debug/GoLensApp
while [ $# -gt 0 ]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --probes) PROBES=$2; shift 2 ;;
    --prompts) PROMPTS_FILE=$2; shift 2 ;;
    *) BIN=$1; shift ;;
  esac
done
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 2; }
[ -n "${GOPILOT_DEV_ENV_FILE:-}" ] && [ -r "$GOPILOT_DEV_ENV_FILE" ] || { echo "set GOPILOT_DEV_ENV_FILE"; exit 2; }
[ -n "$OUT" ] || OUT=$(mktemp -d -t golens-eval-out)
mkdir -p "$OUT"
DOMAIN=dev.golens.test.eval
SERVICE=app.golens.gopilot.provider.default
WORK=$(cd "$(mktemp -d -t golens-eval)" && pwd -P)
APP_PID=
descendants() { local k; for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done; }
cleanup() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null && kill -TERM "$APP_PID" 2>/dev/null
  sleep 1
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  defaults delete $DOMAIN >/dev/null 2>&1
  security delete-generic-password -s "$SERVICE" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/driver.dylib" "$REPO/scripts/smoke/driver.m" 2>/dev/null || { echo "driver failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$REPO/scripts/smoke/quiet-launch.m" 2>/dev/null || { echo "quiet failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
defaults delete $DOMAIN >/dev/null 2>&1
security delete-generic-password -s "$SERVICE" >/dev/null 2>&1

python3 -I - "$PROMPTS_FILE" "$WORK/groups.tsv" "$ONLY" <<'PYEOF'
import json, sys
prompts = json.load(open(sys.argv[1]))
only = set(filter(None, sys.argv[3].split(",")))
groups = {}
for p in prompts:
    if only and p["id"] not in only:
        continue
    key = (p["fixture"], p.get("profileKind") or "")
    groups.setdefault(key, []).append({"id": p["id"], "prompt": p["prompt"], "allowsExecution": bool(p.get("allowsExecution")), "followUps": p.get("followUps", []), "applyProposals": bool(p.get("applyProposals"))})
with open(sys.argv[2], "w") as out:
    for index, ((fixture, kind), items) in enumerate(sorted(groups.items())):
        path = sys.argv[2].replace("groups.tsv", f"prompts-{index}.json")
        json.dump(items, open(path, "w"))
        out.write(f"{index}\t{fixture}\t{kind or '-'}\t{len(items)}\n")
PYEOF

run_group() { # index fixture kind probes
  local index=$1 fixture=$2 kind=$3 probes=$4
  local dir=$WORK/$fixture-$index
  cp -R "$REPO/tests/gopilot/fixtures/$fixture" "$dir" || return 1
  rm -f "$dir/ground-truth.json"
  local profile=
  if [ -n "$kind" ] && [ -x "$dir/prepare.sh" ]; then
    profile=$WORK/profile-$index.pprof
    (cd "$dir" && ./prepare.sh "$dir" "$profile" "$kind" >/dev/null 2>&1)
    [ -s "$profile" ] || { echo "profile for $fixture/$kind not generated"; profile=; }
  fi
  local out=$OUT/group-$index.json
  local prompts=$WORK/prompts-$index.json
  [ "$probes" -gt 0 ] && echo "[]" > "$prompts"
  env GOPILOT_DEV_ENV_FILE="$GOPILOT_DEV_ENV_FILE" ${profile:+GOPILOT_DEV_PROFILE=$profile} \
    GOPILOT_EVAL_PROMPTS="$prompts" GOPILOT_EVAL_OUT="$out" GOPILOT_EVAL_RUNS="$RUNS" GOPILOT_EVAL_CANCEL_PROBES="$probes" \
    DRIVE="wait:5;fakeactive;wait:7200" DRIVE_OUT="$OUT/driver-$index.log" DRIVE_SHOTS="$OUT" DYLD_INSERT_LIBRARIES="$WORK/quiet.dylib:$WORK/driver.dylib" \
    "$APP" -GoLensLastWorkspacePath "$dir" -GoLensLastFilePath "$(ls "$dir"/*.go | head -1)" > "$OUT/app-$index.log" 2>&1 &
  APP_PID=$!
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $waited -lt 7200 ]; do sleep 2; waited=$((waited + 2)); done
  kill -0 "$APP_PID" 2>/dev/null && { echo "group $index timed out"; kill -TERM "$APP_PID"; sleep 2; kill -KILL "$APP_PID" 2>/dev/null; }
  APP_PID=
}

while IFS=$'\t' read -r index fixture kind count; do
  [ "$kind" = "-" ] && kind=""
  echo "group $index: $fixture ${kind:+($kind)} $count prompts x $RUNS"
  run_group "$index" "$fixture" "$kind" 0
done < "$WORK/groups.tsv"
if [ "$PROBES" -gt 0 ]; then
  echo "cancel probes: $PROBES"
  run_group 900 http-storage "" "$PROBES"
fi

python3 -I - "$OUT" <<'PYEOF'
import glob, json, sys
out = sys.argv[1]
runs, probes, model, started = [], [], "", ""
for path in sorted(glob.glob(out + "/group-*.json")):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    model = model or data.get("model", "")
    started = started or data.get("startedAt", "")
    runs.extend(data.get("runs", []))
    probes.extend(data.get("cancelProbesMs", []))
json.dump({"schema": 1, "model": model, "startedAt": started, "runs": runs, "cancelProbesMs": probes}, open(out + "/results.json", "w"), indent=1, sort_keys=True)
print(f"runs: {len(runs)}  cancel probes: {len(probes)}  results: {out}/results.json")
PYEOF
