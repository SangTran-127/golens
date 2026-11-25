#!/bin/sh
# Wraps GoLens.app in a compressed disk image whose window shows the app, an arrow and an
# Applications shortcut on a designed background, so installing is one drag.
# Needs dmgbuild (pip install dmgbuild==1.6.7); the layout lives in scripts/release/dmg/settings.py and
# the background is rendered from scripts/release/dmg/background.html.
# Usage: make-dmg.sh <path/to/GoLens.app> <version> <output.dmg>
set -eu
app=$1
version=$2
out=$3
[ -d "$app" ] || { echo "missing app: $app" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
dmgbuild=${DMGBUILD:-dmgbuild}
command -v "$dmgbuild" >/dev/null 2>&1 || { echo "dmgbuild not found; install it with: pip install dmgbuild==1.6.7" >&2; exit 1; }

rm -f "$out"
"$dmgbuild" -s "$here/dmg/settings.py" -D app="$app" -D background="$here/dmg/background.tiff" "GoLens $version" "$out" >/dev/null
hdiutil verify -quiet "$out"
echo "$out"
