#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/versions.sh"
. "$here/packages.sh"
. "$here/lib.sh"

usage() {
  echo "usage: scripts/runtime/build.sh [output-dir]" >&2
  echo "  GOLENS_RUNTIME_VERSION      runtime version, YYYY.MM.DD[.n] (default: today)" >&2
  echo "  GOLENS_RUNTIME_MIN_APP      minimumAppVersion in the manifest (default: 1.0.0)" >&2
  echo "  GOLENS_RUNTIME_SIGNING_KEY  private key file used to sign the manifest" >&2
  echo "  GOLENS_RUNTIME_UNSIGNED=1   skip the signature (local testing only)" >&2
  echo "  GOLENS_RUNTIME_REBUILD_KERNEL=1  ignore the cached kernel build" >&2
  exit 2
}
case ${1:-} in -h|--help) usage ;; esac

version=${GOLENS_RUNTIME_VERSION:-$(date +%Y.%m.%d)}
echo "$version" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$' || { echo "bad runtime version: $version" >&2; exit 2; }
min_app=${GOLENS_RUNTIME_MIN_APP:-1.0.0}
echo "$min_app" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || { echo "bad minimum app version: $min_app" >&2; exit 2; }
if [ -z "${GOLENS_RUNTIME_SIGNING_KEY:-}" ] && [ "${GOLENS_RUNTIME_UNSIGNED:-}" != 1 ]; then
  echo "set GOLENS_RUNTIME_SIGNING_KEY to the private key file, or GOLENS_RUNTIME_UNSIGNED=1 for an unsigned local build" >&2
  exit 2
fi
out=${1:-$repo/build/runtime/$version}
mkdir -p "$out"
out=$(cd "$out" && pwd)

protocol_hex=$(sed -nE 's/^[[:space:]]*protocolVersion[[:space:]]*=[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+)$/\1/p' "$repo/core/cmd/golens-vm-agent/main.go")
[ -n "$protocol_hex" ] || { echo "protocolVersion not found in core/cmd/golens-vm-agent/main.go" >&2; exit 1; }
agent_protocol=$(printf '%d' "$protocol_hex")

echo "Fetching pinned inputs into $DOWNLOADS"
fetch_pinned "$ALPINE_MINIROOTFS_URL" "$ALPINE_MINIROOTFS_SHA256" >/dev/null
fetch_pinned "$KERNEL_URL" "$KERNEL_SHA256" >/dev/null
fetch_pinned "$GO_URL" "$GO_SHA256" >/dev/null
while read -r set rel sum; do
  fetch_pinned "$ALPINE_PACKAGE_MIRROR/$ALPINE_BRANCH/$rel" "$sum" "alpine/$(basename "$rel")" >/dev/null || {
    echo "$rel is no longer on the mirror; run scripts/runtime/lock-alpine.sh to refresh the lock" >&2
    exit 1
  }
done < "$here/alpine-packages.lock"

base=$(alpine_base_image)
builder_key=$( { echo "$ALPINE_VERSION"; grep '^builder ' "$here/alpine-packages.lock"; } | shasum -a 256 | cut -c1-12)
builder=golens-runtime-builder:$builder_key
container=
cleanup() { [ -n "$container" ] && docker rm -f "$container" >/dev/null 2>&1; true; }
trap cleanup EXIT INT TERM
if ! docker image inspect "$builder" >/dev/null 2>&1; then
  echo "Creating the builder image $builder"
  container=golens-runtime-builder-$$
  files=$(awk '$1 == "builder" { n = split($2, p, "/"); printf "/downloads/alpine/%s ", p[n] }' "$here/alpine-packages.lock")
  docker run --name "$container" --platform linux/arm64 -v "$DOWNLOADS:/downloads:ro" "$base" \
    apk add --quiet --no-network --repositories-file /dev/null $files
  docker commit "$container" "$builder" >/dev/null
  docker rm "$container" >/dev/null
  container=
fi

mkdir -p "$RUNTIME_CACHE/gomod" "$RUNTIME_CACHE/kernel"
container=golens-runtime-build-$$
echo "Building runtime $version in $builder"
docker run --rm --name "$container" --platform linux/arm64 \
  -v "$repo:/repo:ro" -v "$DOWNLOADS:/downloads:ro" -v "$RUNTIME_CACHE/gomod:/gomod" \
  -v "$RUNTIME_CACHE/kernel:/kcache" -v "$out:/out" \
  -e RUNTIME_VERSION="$version" -e MIN_APP_VERSION="$min_app" -e AGENT_PROTOCOL="$agent_protocol" \
  -e KERNEL_REBUILD="${GOLENS_RUNTIME_REBUILD_KERNEL:-}" \
  "$builder" sh /repo/scripts/runtime/build-in-container.sh
container=

manifest=$out/golens-linux-runtime.json
if [ -n "${GOLENS_RUNTIME_SIGNING_KEY:-}" ]; then
  (cd "$here/sign" && GOTOOLCHAIN=local go run . sign "$manifest")
  (cd "$here/sign" && GOTOOLCHAIN=local go run . verify -public-key "$(GOTOOLCHAIN=local go run . public-key)" "$manifest") >/dev/null
else
  rm -f "$manifest.sig"
  echo "Unsigned build: $manifest.sig was not written"
fi
echo "Runtime $version written to $out"
ls -l "$out"
