#!/bin/sh
# Headless Chrome screenshots of design/symbol-icons/preview.html sections into preview/. Never opens a window.
set -e
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
shot() { # view width height scale out
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$TMP" --force-device-scale-factor="$4" --window-size="$2,$3" \
    --screenshot="$PWD/preview/$5" "file://$PWD/preview.html?view=$1" >/dev/null 2>&1
}
shot grid-light 1180 560 2 symbols-light-2x.png
shot grid-dark  1180 560 2 symbols-dark-2x.png
shot popups     1220 1260 2 popups-mock-2x.png
shot gray       1180 420 2 grayscale-2x.png
shot zoom       1180 520 2 zoom-64px.png
rm -rf "$TMP"
