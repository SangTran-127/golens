#!/bin/sh
# Renders background.html to background.tiff (660x420 at 1x and 2x) with headless Google Chrome.
# Run after editing background.html, then commit background.tiff.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
work=$(mktemp -d "${TMPDIR:-/tmp}/golens-dmg-bg.XXXXXX")
trap 'rm -rf "$work"' EXIT
for scale in 1 2; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$work/profile" \
    --window-size=660,420 --force-device-scale-factor=$scale \
    --screenshot="$work/bg-$scale.png" "file://$here/background.html" >/dev/null 2>&1
done
tiffutil -cathidpicheck "$work/bg-1.png" "$work/bg-2.png" -out "$here/background.tiff" >/dev/null
echo "$here/background.tiff"
