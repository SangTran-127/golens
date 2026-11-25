#!/bin/sh
# Adapted from apple-design-brain bundle-app.sh (MIT, derived from bama's template build.sh and Info.plist.in).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$root/.build/release/GoLensApp}
out=${2:-$root/build}
id=${BUNDLE_ID:-dev.golens.app}
version=${GOLENS_VERSION:-1.0.0}
build=${GOLENS_BUILD:-1}
name=GoLens
exe=$(basename "$bin")
dylib=$root/core/libgoagent.dylib
lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$bin" ] || { echo "missing executable: $bin (run make build)" >&2; exit 1; }
[ -f "$dylib" ] || { echo "missing $dylib (run make build)" >&2; exit 1; }

app=$out/$name.app
if [ "$id" = "dev.golens.app" ] && [ "$out" = "$root/build" ]; then
  is_canonical=${GOLENS_CANONICAL_BUILD:-1}
else
  is_canonical=0
fi
mkdir -p "$out"
if [ "$id" != "dev.golens.app" ] || [ "$is_canonical" != "1" ] || [ "$out" != "$root/build" ]; then
  touch "$out/.metadata_never_index" 2>/dev/null || true
fi
if [ -d "$HOME/Library/Containers/$id/Data" ]; then
  xattr -d com.apple.quarantine "$HOME/Library/Containers/$id" "$HOME/Library/Containers/$id/Data" "$HOME/Library/Containers/$id/Data/tmp" 2>/dev/null || true
fi
xattr -d com.apple.quarantine "$out" 2>/dev/null || true
[ -d "$app" ] && { [ -x "$lsreg" ] && "$lsreg" -u "$app" 2>/dev/null || true; }
[ -d "$app" ] && chmod -R u+w "$app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"

update_keys=
if [ -n "${GOLENS_UPDATE_FEED_URL:-}" ]; then
  update_keys="<key>SUFeedURL</key><string>$GOLENS_UPDATE_FEED_URL</string><key>SUPublicEDKey</key><string>$(cat "$root/scripts/release/update-public-key")</string>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleExecutable</key><string>$exe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>GoLens</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 SangTran-127</string>
$update_keys
</dict></plist>
PLIST
plutil -lint -s "$app/Contents/Info.plist"

cp "$bin" "$app/Contents/MacOS/$exe"
for b in "$(dirname "$bin")"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
cp "$root/desktop/Resources/GoLens.icns" "$app/Contents/Resources/AppIcon.icns"
# The layered Icon Composer icon (design/app-icon, rebuilt by scripts/make-app-icon.sh).
cp "$root/design/app-icon/Assets.car" "$app/Contents/Resources/Assets.car"
cp "$dylib" "$app/Contents/Frameworks/"
if [ -d "$(dirname "$bin")/Sparkle.framework" ]; then
  ditto "$(dirname "$bin")/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
fi
install_name_tool -delete_rpath "$root/core" "$app/Contents/MacOS/$exe" 2>/dev/null || true
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$exe" 2>/dev/null || true

chmod -R u+w "$app"
xattr -cr "$app"

sign_identity=${SIGN_IDENTITY:-}
if [ -z "$sign_identity" ]; then
  sign_identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"GoLens Local Signing"/ {print $2; exit}')
fi
sign_identity=${sign_identity:--}
release_signing=${RELEASE_SIGNING:-0}
if [ -n "${ENTITLEMENTS_FILE:-}" ]; then
  entitlements="$ENTITLEMENTS_FILE"
elif [ -n "${ENTITLEMENTS:-}" ]; then
  entitlements="$ENTITLEMENTS"
elif [ "$release_signing" = "1" ] && [ "$sign_identity" != "-" ]; then
  entitlements="$root/desktop/Resources/GoLens-Release.entitlements"
else
  entitlements="$root/desktop/Resources/GoLens.entitlements"
fi

codesign_flags="--options runtime"
if [ "$release_signing" = "1" ] && [ "$sign_identity" != "-" ]; then
  codesign_flags="--options runtime --timestamp"
fi

codesign --force --sign "$sign_identity" $codesign_flags "$app/Contents/Frameworks/libgoagent.dylib"
sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle_fw" ]; then
  for item in "$sparkle_fw/Versions/B/XPCServices/Installer.xpc" "$sparkle_fw/Versions/B/XPCServices/Downloader.xpc" "$sparkle_fw/Versions/B/Autoupdate" "$sparkle_fw/Versions/B/Updater.app"; do
    [ -e "$item" ] && codesign --force --sign "$sign_identity" $codesign_flags --preserve-metadata=entitlements "$item"
  done
  codesign --force --sign "$sign_identity" $codesign_flags "$sparkle_fw"
fi
if [ -f "$entitlements" ]; then
  codesign --force --sign "$sign_identity" $codesign_flags --entitlements "$entitlements" "$app/Contents/MacOS/$exe"
  codesign --force --sign "$sign_identity" $codesign_flags --entitlements "$entitlements" "$app"
else
  codesign --force --sign "$sign_identity" $codesign_flags "$app/Contents/MacOS/$exe"
  codesign --force --sign "$sign_identity" $codesign_flags "$app"
fi
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
codesign --verify --deep --strict "$app"

if [ "$id" != "dev.golens.app" ] || [ "$is_canonical" != "1" ] || [ "$out" != "$root/build" ]; then
  touch "$out/.metadata_never_index" 2>/dev/null || true
  [ -x "$lsreg" ] && "$lsreg" -u "$app" 2>/dev/null || true
else
  extra_dirs=
  [ -f "$HOME/.golens/stale-app-dirs" ] && extra_dirs=$(sed "s#^~#$HOME#" "$HOME/.golens/stale-app-dirs")
  printf '%s\n%s\n' "$HOME/Documents/GoLens-QA" "$extra_dirs" | while IFS= read -r stale_dir; do
    [ -n "$stale_dir" ] || continue
    if [ -d "$stale_dir" ]; then
      touch "$stale_dir/.metadata_never_index" 2>/dev/null || true
      find "$stale_dir" -name "GoLens*.app" -maxdepth 5 2>/dev/null | while IFS= read -r stale_app; do
        [ -z "$stale_app" ] && continue
        [ -x "$lsreg" ] && "$lsreg" -u "$stale_app" 2>/dev/null || true
        rm -rf "$stale_app" 2>/dev/null || true
      done
    fi
  done
  [ -x "$lsreg" ] && "$lsreg" -f "$app" 2>/dev/null || true
  mdimport "$app" 2>/dev/null || true
fi

echo "$app"
