RUNTIME_CACHE=${GOLENS_RUNTIME_CACHE:-$here/cache}
DOWNLOADS=$RUNTIME_CACHE/downloads
mkdir -p "$DOWNLOADS"

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

fetch_url() {
  url=$1
  dest=$DOWNLOADS/${2:-$(basename "$url")}
  if [ ! -s "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv -f "$dest.part" "$dest"
  fi
  echo "$dest"
}

fetch_pinned() {
  file=$(fetch_url "$1" "${3:-}")
  got=$(sha256_of "$file")
  if [ "$got" != "$2" ]; then
    rm -f "$file"
    echo "checksum mismatch for $1: expected $2, got $got" >&2
    exit 1
  fi
  echo "$file"
}

alpine_base_image() {
  image=golens-runtime-alpine:$ALPINE_VERSION
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker import --platform linux/arm64 "$DOWNLOADS/$(basename "$ALPINE_MINIROOTFS_URL")" "$image" >/dev/null
  fi
  echo "$image"
}
