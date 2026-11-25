#!/bin/sh
# Rebuilds the app icon from the Icon Composer file design/app-icon/GoLens.icon (written by
# design/app-icon/build-icon-layers.py). Needs Xcode 26 (actool).
# Writes design/app-icon/Assets.car (the layered Liquid Glass icon macOS 26 renders in light, dark, clear and tinted)
# and desktop/Resources/GoLens.icns (16-1024 px, rendered from that icon for the in-app icon images).
# Run it after changing GoLens.icon and commit both outputs; `make build` only copies them.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/design/app-icon/GoLens.icon
xcode=${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

DEVELOPER_DIR=$xcode xcrun actool --compile "$work" --app-icon GoLens \
  --output-partial-info-plist "$work/partial.plist" --platform macosx \
  --minimum-deployment-target 14.0 --target-device mac "$src" >/dev/null
cp "$work/Assets.car" "$root/design/app-icon/Assets.car"

bundle=$work/Icon.app
mkdir -p "$bundle/Contents/Resources"
cp "$work/Assets.car" "$work/GoLens.icns" "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.golens.icon-render</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>GoLens</string>
<key>CFBundleIconName</key><string>GoLens</string>
</dict></plist>
PLIST
DEVELOPER_DIR=$xcode xcrun swiftc -O -o "$work/render" "$root/design/app-icon/render-icon.swift"
"$work/render" "$bundle" GoLens "$work/png" 16 32 64 128 256 512 1024
mkdir -p "$work/GoLens.iconset"
for base in 16 32 128 256 512; do
  cp "$work/png/$base.png" "$work/GoLens.iconset/icon_${base}x${base}.png"
  cp "$work/png/$((base * 2)).png" "$work/GoLens.iconset/icon_${base}x${base}@2x.png"
done
iconutil -c icns -o "$root/desktop/Resources/GoLens.icns" "$work/GoLens.iconset"
echo "Updated design/app-icon/Assets.car and desktop/Resources/GoLens.icns"
