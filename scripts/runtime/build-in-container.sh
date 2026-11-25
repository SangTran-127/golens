#!/bin/sh
set -eu
umask 022
export LC_ALL=C TZ=UTC
here=/repo/scripts/runtime
. "$here/versions.sh"
. "$here/packages.sh"
export SOURCE_DATE_EPOCH

work=/work
rt=$work/runtime
notes=$work/notices
mkdir -p "$rt" "$notes" "$work/tmp"
jobs=$(nproc)

step() { echo "== $*"; }

build_kernel() {
  key=$( { echo "$KERNEL_VERSION $SOURCE_DATE_EPOCH"; cat "$here/kernel.config"; gcc --version | head -1; ld --version | head -1; } | sha256sum | cut -c1-16)
  cached=/kcache/$KERNEL_VERSION-$key
  if [ -n "${KERNEL_REBUILD:-}" ] || [ ! -s "$cached/vmlinuz" ]; then
    step "kernel $KERNEL_VERSION: configure and build"
    tar -xJf "/downloads/linux-$KERNEL_VERSION.tar.xz" -C "$work"
    src=$work/linux-$KERNEL_VERSION
    export KBUILD_BUILD_USER=golens KBUILD_BUILD_HOST=golens KBUILD_BUILD_VERSION=1
    KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%a %b %e %H:%M:%S UTC %Y')
    export KBUILD_BUILD_TIMESTAMP
    make -C "$src" -s ARCH=arm64 defconfig
    "$src/scripts/kconfig/merge_config.sh" -m -O "$src" "$src/.config" "$here/kernel.config" >/dev/null
    make -C "$src" -s ARCH=arm64 olddefconfig
    missing=
    while IFS= read -r line; do
      case $line in
        CONFIG_*=*) grep -qxF "$line" "$src/.config" || missing="$missing $line" ;;
        "# CONFIG_"*" is not set")
          sym=${line#"# "}; sym=${sym%" is not set"}
          if grep -q "^$sym=" "$src/.config"; then missing="$missing $line"; fi ;;
      esac
    done < "$here/kernel.config"
    [ -z "$missing" ] || { echo "kernel options not applied:$missing" >&2; exit 1; }
    make -C "$src" -s ARCH=arm64 -j"$jobs" Image
    rm -rf "$cached.tmp"
    mkdir -p "$cached.tmp/licenses"
    cp "$src/arch/arm64/boot/Image" "$cached.tmp/vmlinuz"
    cp "$src/.config" "$cached.tmp/config"
    cp "$src/COPYING" "$src/LICENSES/preferred/GPL-2.0" "$src/LICENSES/exceptions/Linux-syscall-note" "$cached.tmp/licenses/"
    rm -rf "$cached" "$src"
    mv "$cached.tmp" "$cached"
  else
    step "kernel $KERNEL_VERSION: cached build $cached"
  fi
  cp "$cached/vmlinuz" "$rt/vmlinuz"
  cp "$cached/config" /out/kernel.config
  cp -R "$cached/licenses" "$notes/kernel"
}

build_rootfs() {
  step "rootfs: Alpine $ALPINE_VERSION"
  rootfs=$work/rootfs
  mkdir -p "$rootfs"
  tar -xzf "/downloads/$(basename "$ALPINE_MINIROOTFS_URL")" -C "$rootfs"
  base_world=$(cat "$rootfs/etc/apk/world")
  files=$(awk '$1 == "rootfs" { n = split($2, p, "/"); printf "/downloads/alpine/%s ", p[n] }' "$here/alpine-packages.lock")
  apk add --quiet --root "$rootfs" --no-network --repositories-file /dev/null --no-cache $files
  printf '%s\n' $base_world $ROOTFS_PACKAGES | sort -u > "$rootfs/etc/apk/world"
  rm -rf "$rootfs/var/cache/apk" "$rootfs/lib/apk/db/lock" "$rootfs/var/log/apk.log"
  mkdir -p "$rootfs/var/cache/apk" "$rootfs/usr/local/go" "$rootfs/usr/local/bin"
  [ -s "$rootfs/etc/ssl/certs/ca-certificates.crt" ] || { echo "rootfs has no CA bundle" >&2; exit 1; }
  for tool in bash sh git gcc make ip ssh; do
    chroot "$rootfs" /bin/sh -c "command -v $tool" >/dev/null || { echo "rootfs is missing $tool" >&2; exit 1; }
  done
  awk -F: '
    /^P:/ { name = substr($0, 3) }
    /^V:/ { ver = substr($0, 3) }
    /^L:/ { lic = substr($0, 3) }
    /^o:/ { origin = substr($0, 3) }
    /^$/ { if (name != "") printf "%-28s %-24s %-40s %s\n", name, ver, lic, origin; name = ver = lic = origin = "" }
    END { if (name != "") printf "%-28s %-24s %-40s %s\n", name, ver, lic, origin }
  ' "$rootfs/lib/apk/db/installed" | sort > "$notes/alpine-packages.txt"
  mkfs.erofs --quiet -zlz4hc,level=12 -T"$SOURCE_DATE_EPOCH" --all-time --all-root \
    -U 6f6c656e-7372-6f6f-7466-730000000001 -L golens-rootfs "$rt/rootfs.img" "$rootfs"
  rm -rf "$rootfs"
}

go_module_dir() {
  json=$(cd "$work/tmp" && go mod download -json "$1@$2")
  sum=$(echo "$json" | sed -n 's/^[[:space:]]*"Sum": "\(.*\)",$/\1/p')
  [ "$sum" = "$3" ] || { echo "$1@$2 hash $sum does not match the pinned $3" >&2; exit 1; }
  echo "$json" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p'
}

build_go() {
  step "Go $GO_VERSION, gopls $GOPLS_VERSION, Delve $DELVE_VERSION"
  mkdir -p "$work/toolchain"
  tar -xzf "/downloads/$(basename "$GO_URL")" -C "$work/toolchain"
  tar -xzf "/downloads/$(basename "$GO_URL")" -C "$work"
  mv "$work/go" "$rt/goroot"
  export GOROOT=$work/toolchain/go PATH=$work/toolchain/go/bin:$PATH
  export GOTOOLCHAIN=local GOMODCACHE=/gomod GOCACHE=$work/gocache GOPATH=$work/gopath TMPDIR=$work/tmp
  export GOOS=linux GOARCH=arm64 CGO_ENABLED=0
  [ "$(go env GOVERSION)" = "go$GO_VERSION" ] || { echo "unexpected toolchain $(go env GOVERSION)" >&2; exit 1; }
  [ "$(cat /repo/scripts/gopls/VERSION)" = "$GOPLS_VERSION" ] || { echo "scripts/gopls/VERSION is not $GOPLS_VERSION; update versions.sh" >&2; exit 1; }

  gopls_dir=$(go_module_dir "$GOPLS_MODULE" "$GOPLS_VERSION" "$GOPLS_H1")
  sh /repo/scripts/gopls/build.sh "$rt/goroot/bin/gopls"
  cp "$gopls_dir/LICENSE" "$notes/gopls.LICENSE"

  delve_dir=$(go_module_dir "$DELVE_MODULE" "v$DELVE_VERSION" "$DELVE_H1")
  cp -R "$delve_dir" "$work/delve"
  chmod -R u+w "$work/delve"
  (cd "$work/delve" && GOFLAGS=-mod=readonly go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$rt/goroot/bin/dlv" ./cmd/dlv)
  cp "$delve_dir/LICENSE" "$notes/delve.LICENSE"

  step "golens-vm-agent"
  (cd /repo/core && GOFLAGS=-mod=readonly go build -buildvcs=false -trimpath -ldflags="-s -w" -o "$rt/golens-vm-agent" ./cmd/golens-vm-agent)
}

module_licenses() {
  go version -m "$1" | awk '$1 == "dep" || $1 == "=>" { print $2, $3 }' | while read -r path ver; do
    escaped=$(echo "$path" | sed 's/[A-Z]/!&/g' | tr 'A-Z' 'a-z')
    dir=$GOMODCACHE/$escaped@$ver
    lic=
    for name in LICENSE LICENSE.md LICENSE.txt LICENCE COPYING; do
      [ -f "$dir/$name" ] && { lic=$dir/$name; break; }
    done
    [ -n "$lic" ] || { echo "no license file for $path $ver in $dir" >&2; exit 1; }
    printf '\n--- %s %s ---\n\n' "$path" "$ver"
    cat "$lic"
  done
}

write_notices() {
  step "NOTICES.txt"
  gopls_tag=$("$rt/goroot/bin/gopls" version | awk 'NR == 1 { sub(/^v/, "", $2); print $2 }')
  case $gopls_tag in "${GOPLS_VERSION#v}"-*|"${GOPLS_VERSION#v}") ;; *) echo "unexpected gopls version: $gopls_tag" >&2; exit 1 ;; esac
  "$rt/goroot/bin/dlv" version | grep -qx "Version: $DELVE_VERSION" || { echo "unexpected dlv version" >&2; exit 1; }
  {
    echo "GoLens Linux runtime $RUNTIME_VERSION (arm64): third-party notices"
    echo
    echo "This runtime is assembled by scripts/runtime/build.sh in the GoLens repository from the"
    echo "pinned upstream sources listed below. Every input is checked against the SHA-256 noted here."
    echo
    echo "================================================================================"
    echo "Linux kernel $KERNEL_VERSION (vmlinuz)"
    echo "================================================================================"
    echo "License: GPL-2.0 WITH Linux-syscall-note"
    echo "Source: $KERNEL_URL"
    echo "Source SHA-256: $KERNEL_SHA256"
    echo "Configuration: arm64 defconfig with this fragment applied (scripts/runtime/kernel.config):"
    echo
    sed 's/^/    /' "$here/kernel.config"
    echo
    echo "The kernel is built from unmodified upstream source: the tarball above plus this configuration"
    echo "is the complete corresponding source."
    echo
    cat "$notes/kernel/COPYING"
    echo
    cat "$notes/kernel/GPL-2.0"
    echo
    cat "$notes/kernel/Linux-syscall-note"
    echo
    echo "================================================================================"
    echo "Alpine Linux $ALPINE_VERSION packages (rootfs.img)"
    echo "================================================================================"
    echo "Base: $ALPINE_MINIROOTFS_URL"
    echo "Base SHA-256: $ALPINE_MINIROOTFS_SHA256"
    echo "Packages: $ALPINE_PACKAGE_MIRROR/$ALPINE_BRANCH (versions and SHA-256 in scripts/runtime/alpine-packages.lock)"
    echo "Package sources: https://gitlab.alpinelinux.org/alpine/aports/-/tree/${ALPINE_BRANCH#v}-stable"
    echo "Licenses are the SPDX expressions from each package's apk metadata."
    echo
    printf '%-28s %-24s %-40s %s\n' PACKAGE VERSION LICENSE ORIGIN
    cat "$notes/alpine-packages.txt"
    echo
    echo "================================================================================"
    echo "Go $GO_VERSION (goroot)"
    echo "================================================================================"
    echo "Source: $GO_URL"
    echo "SHA-256: $GO_SHA256"
    echo
    cat "$rt/goroot/LICENSE"
    echo
    echo "================================================================================"
    echo "gopls $gopls_tag (goroot/bin/gopls)"
    echo "================================================================================"
    echo "Built from $GOPLS_MODULE $GOPLS_VERSION ($GOPLS_H1) with scripts/gopls/low-memory.patch."
    echo
    cat "$notes/gopls.LICENSE"
    module_licenses "$rt/goroot/bin/gopls"
    echo
    echo "================================================================================"
    echo "Delve $DELVE_VERSION (goroot/bin/dlv)"
    echo "================================================================================"
    echo "Built from $DELVE_MODULE v$DELVE_VERSION ($DELVE_H1)."
    echo
    cat "$notes/delve.LICENSE"
    module_licenses "$rt/goroot/bin/dlv"
  } > "$rt/NOTICES.txt"
}

json_runtime() {
  printf '{\n  "version": "%s",\n  "arch": "arm64",\n' "$RUNTIME_VERSION"
  [ -z "${archive:-}" ] || printf '  "archive": "%s",\n  "archiveSize": %s,\n' "$archive" "$archive_size"
  printf '  "installedSize": %s,\n' "$installed_size"
  [ -z "${archive:-}" ] || printf '  "sha256": "%s",\n' "$archive_sha"
  printf '  "minimumAppVersion": "%s",\n  "agentProtocol": %s,\n' "$MIN_APP_VERSION" "$AGENT_PROTOCOL"
  printf '  "components": {\n'
  printf '    "kernel": "%s",\n    "alpine": "%s",\n    "go": "%s",\n    "gopls": "%s",\n    "delve": "%s"\n' \
    "$KERNEL_VERSION" "$ALPINE_VERSION" "$GO_VERSION" "$gopls_tag" "$DELVE_VERSION"
  printf '  }\n}\n'
}

tree_size() {
  find "$rt" -type f -exec stat -c %s {} + | awk '{ s += $1 } END { print s + 0 }'
}

write_archive() {
  step "archive"
  rm -f "$rt/runtime.json"
  installed_size=0
  while :; do
    json_runtime > "$rt/runtime.json"
    size=$(tree_size)
    [ "$size" = "$installed_size" ] && break
    installed_size=$size
  done
  archive=golens-linux-runtime-$RUNTIME_VERSION-arm64.tar.gz
  tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner --format=gnu \
    -C "$rt" -cf - vmlinuz rootfs.img golens-vm-agent goroot NOTICES.txt runtime.json | gzip -9n > "/out/$archive.tmp"
  mv -f "/out/$archive.tmp" "/out/$archive"
  archive_size=$(stat -c %s "/out/$archive")
  archive_sha=$(sha256sum "/out/$archive" | cut -d' ' -f1)
  json_runtime > /out/golens-linux-runtime.json
  (
    cd "$rt"
    sha256sum vmlinuz rootfs.img golens-vm-agent goroot/bin/gopls goroot/bin/dlv NOTICES.txt runtime.json
    echo "$(find goroot -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)  goroot/"
  ) > /out/components.sha256
}

rm -f /out/golens-linux-runtime-*-arm64.tar.gz /out/golens-linux-runtime.json /out/golens-linux-runtime.json.sig
build_kernel
build_rootfs
build_go
write_notices
write_archive
cat /out/components.sha256
