#!/bin/sh
# Headless Chrome screenshots of preview.html sections into preview/. Never opens a window.
set -e
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
shot() { # view width height scale out
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$TMP" --force-device-scale-factor="$4" --window-size="$2,$3" \
    --screenshot="$PWD/preview/$5" "file://$PWD/preview.html?view=$1" >/dev/null 2>&1
}
shot grid-light 1180 1240 1 set-light-1x.png
shot grid-dark  1180 1240 1 set-dark-1x.png
shot grid-light 1180 1240 2 set-light-2x.png
shot grid-dark  1180 1240 2 set-dark-2x.png
shot sidebar    1100 900 2 sidebar-2x.png
shot sidebar    1100 900 1 sidebar-1x.png
shot hc         600 900 2 sidebar-increase-contrast-2x.png
shot gray       1180 900 2 grayscale-2x.png
shot zoom       1180 1100 1 zoom-64px.png
rm -rf "$TMP"
