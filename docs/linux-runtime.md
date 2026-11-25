# Linux runtime build

The Linux machine mode boots a runtime that GoLens downloads on demand. `scripts/runtime/build.sh` builds it from pinned upstream sources in Docker (linux/arm64) on an Apple silicon Mac, so every file in it can be traced to a source and a license.

## Build

```sh
(cd scripts/runtime/sign && go run . keygen ~/secure/golens-runtime.key)
GOLENS_RUNTIME_SIGNING_KEY=~/secure/golens-runtime.key scripts/runtime/build.sh
```

The first command is run once and prints the public key the app embeds; keep the private key out of the repository. For a local unsigned test build use `GOLENS_RUNTIME_UNSIGNED=1 scripts/runtime/build.sh <output-dir>`.

| Variable | Meaning |
|----------|---------|
| `GOLENS_RUNTIME_VERSION` | Runtime version `YYYY.MM.DD[.n]`, default today |
| `GOLENS_RUNTIME_MIN_APP` | `minimumAppVersion` in the manifest, default `1.0.0` |
| `GOLENS_RUNTIME_SIGNING_KEY` | Private key file (base64 of the 32-byte Ed25519 seed) |
| `GOLENS_RUNTIME_UNSIGNED=1` | Skip the signature |
| `GOLENS_RUNTIME_REBUILD_KERNEL=1` | Ignore the cached kernel build |
| `GOLENS_RUNTIME_CACHE` | Download and build cache, default `scripts/runtime/cache` (gitignored) |

Output, default `build/runtime/<version>/`:

- `golens-linux-runtime-<version>-arm64.tar.gz`: `vmlinuz`, `rootfs.img`, `golens-vm-agent`, `goroot/`, `NOTICES.txt`, `runtime.json`
- `golens-linux-runtime.json`: the manifest; `golens-linux-runtime.json.sig`: base64 Ed25519 signature over its exact bytes
- `components.sha256`, `kernel.config`: build evidence, not published

## Inputs

All versions and SHA-256 sums live in `scripts/runtime/versions.sh`; Alpine packages are locked by file name and SHA-256 in `scripts/runtime/alpine-packages.lock`.

- Linux kernel from kernel.org, arm64 `defconfig` plus `scripts/runtime/kernel.config`. The build fails if any option of the fragment does not end up in the final configuration.
- Alpine minirootfs plus the packages in `scripts/runtime/packages.sh` (`ROOTFS_PACKAGES`), packed into an EROFS image. The builder container is the same minirootfs plus `BUILDER_PACKAGES`, imported with `docker import`, so no Docker Hub image is involved.
- Official Go linux-arm64 tarball for the version in `core/go.mod`, unpacked as `goroot/`.
- gopls built by `scripts/gopls/build.sh`, Delve built from its module; both module hashes (`h1:`, a SHA-256 tree hash) are checked before building.
- `golens-vm-agent` built from `core/cmd/golens-vm-agent` with the pinned Go toolchain.

Alpine keeps only the newest build of a package on its mirror. When a pinned `.apk` disappears, the build stops; run `scripts/runtime/lock-alpine.sh` to refresh the lock, review the diff and commit it.

## Reproducibility

Two builds of the same commit with the same version produce identical files and an identical archive. What is normalized:

- `SOURCE_DATE_EPOCH` in `versions.sh` is the build time for the kernel (`KBUILD_BUILD_TIMESTAMP`, with fixed user, host and build number), the EROFS image (`mkfs.erofs -T --all-time --all-root` and a fixed UUID) and every archive entry.
- The archive is GNU tar with sorted names, uid and gid 0, then `gzip -n`.
- Go binaries are built with `-trimpath -buildvcs=false` by the pinned toolchain inside the container.
- The kernel and root filesystem are built inside the container's own filesystem, never on a macOS bind mount.

`components.sha256` lists the checksum of each component and a tree hash of `goroot/`; compare it between two runs.

## Guest boot

The app shares a writable directory as the virtiofs root and attaches `rootfs.img` as `/dev/vda`. The agent, started as `/sbin/init`, mounts the image at `/mnt/erofs`, binds its `/bin`, `/lib` and `/usr` into the root, links each `/mnt/erofs/sbin` entry into `/sbin` except `init`, copies `/etc` into a tmpfs (binding `/etc/ssl` read-only) and then mounts the Go toolchain at `/usr/local/go`. Shells are `/bin/bash`, then `/bin/sh`.

The machine must also attach a virtio entropy device (`VZVirtioEntropyDeviceConfiguration`); the kernel has `CONFIG_HW_RANDOM_VIRTIO` built in. Apple silicon exposes no CPU random instruction to the guest, so without that device the kernel random pool takes about 50 seconds to initialize and every `getrandom` call blocks until then, including the one gopls makes while answering `initialize`.

## Signing tool

`scripts/runtime/sign` (Go standard library only):

- `keygen <path>` writes a new private key with mode 0600 and prints only the base64 public key.
- `public-key` prints the public key of `$GOLENS_RUNTIME_SIGNING_KEY`.
- `sign <manifest> [<signature>]` signs with `$GOLENS_RUNTIME_SIGNING_KEY`, default output `<manifest>.sig` (base64, no trailing newline).
- `verify -public-key <base64> <manifest> [<signature>]`.

## Publishing

Releases are built by `.github/workflows/release.yml` in the public repository `SangTran-127/golens`, from the source snapshot that `make release` pushes there (`scripts/release/public-snapshot.py`). Its `runtime` job runs `build.sh` on a linux/arm64 runner with the key from the `GOLENS_RUNTIME_SIGNING_KEY` secret, checks the signature against the public key built into the app (`LinuxRuntimeInstaller.trustedPublicKeys`), and runs `scripts/runtime/gpl-sources.py`. The release then carries the runtime archive, `golens-linux-runtime.json`, its `.sig`, and `golens-linux-runtime-<version>-sources.tar`.

`gpl-sources.py` collects the complete corresponding source of every copyleft component: the kernel tarball with `kernel.config` and these build scripts, and for each Alpine package whose license is GPL, LGPL, MPL or similar, the aports recipe (APKBUILD and patches) at the commit recorded in the binary package plus the upstream files it names, each checked against the recipe's SHA-512. It needs the downloads of a finished `build.sh` run in `GOLENS_RUNTIME_CACHE`.

The app reads the manifest from `https://github.com/SangTran-127/golens/releases/latest/download/golens-linux-runtime.json`; `GOLENS_RUNTIME_MANIFEST_URL` overrides it for tests. Keep a copy of the signing key outside this Mac: without it no later runtime can be signed for apps already installed.
