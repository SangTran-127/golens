#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: scripts/gopls/build.sh <output path>}
version=$(cat "$here/VERSION")
tag=$version-golens.2
work=$(mktemp -d "${TMPDIR:-/tmp}/golens-gopls.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT INT TERM

src=$(cd "$work" && go mod download -json "golang.org/x/tools/gopls@$version" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')
[ -d "$src" ] || { echo "gopls $version is not in the module cache and could not be downloaded" >&2; exit 1; }
cp -R "$src/." "$work/gopls"
chmod -R u+w "$work/gopls"
patch -s -d "$work/gopls" -p1 < "$here/low-memory.patch"
(cd "$work/gopls" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS=-mod=readonly go build -buildvcs=false -trimpath \
  -ldflags="-s -w -X main.version=$tag" -o "$work/gopls.bin" .)

mkdir -p "$(dirname "$out")"
if cmp -s "$work/gopls.bin" "$out"; then
  echo "gopls $tag unchanged: $out"
else
  cp "$work/gopls.bin" "$out.tmp"
  chmod 755 "$out.tmp"
  mv -f "$out.tmp" "$out"
  echo "gopls $tag installed: $out"
fi
