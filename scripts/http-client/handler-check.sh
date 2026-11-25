#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp "$ROOT/scripts/http-client/handler-check.swift" "$OUT/main.swift"
swiftc -O -o "$OUT/handler-check" \
  "$OUT/main.swift" \
  "$ROOT/desktop/State/HTTPScriptRunner.swift" \
  "$ROOT/desktop/State/HTTPClientState.swift"
"$OUT/handler-check"
