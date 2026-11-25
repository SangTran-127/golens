#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.sh"
. "$here/packages.sh"
. "$here/lib.sh"

fetch_pinned "$ALPINE_MINIROOTFS_URL" "$ALPINE_MINIROOTFS_SHA256" >/dev/null
base=$(alpine_base_image)

list_urls() {
  docker run --rm --platform linux/arm64 "$base" sh -c 'apk update >/dev/null && apk fetch -R --simulate --url "$@" | sort -u' sh "$@"
}

out=$here/alpine-packages.lock
tmp=$out.tmp
: > "$tmp"
for set in rootfs builder; do
  if [ "$set" = rootfs ]; then pkgs=$ROOTFS_PACKAGES; else pkgs=$BUILDER_PACKAGES; fi
  for url in $(list_urls $pkgs); do
    rel=${url#"$ALPINE_PACKAGE_MIRROR/$ALPINE_BRANCH/"}
    file=$(fetch_url "$url" "alpine/$(basename "$url")")
    printf '%s %s %s\n' "$set" "$rel" "$(sha256_of "$file")" >> "$tmp"
  done
done
mv -f "$tmp" "$out"
echo "wrote $out ($(wc -l < "$out" | tr -d ' ') packages)"
