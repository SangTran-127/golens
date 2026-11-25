#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPYLEFT = re.compile(r"\b(L?GPL|AGPL|MPL|EPL|CDDL)", re.I)
AGENT = "golens-runtime-sources"


def shell_vars(path, names):
    script = f". {path}; " + " ".join(f'printf "%s\\0" "${n}";' for n in names)
    values = subprocess.run(["sh", "-c", script], capture_output=True, text=True, check=True).stdout.split("\0")
    return dict(zip(names, values))


def fetch(url, dest):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=300) as response, open(dest, "wb") as f:
        shutil.copyfileobj(response, f)


def github_tree(path, commit, dest):
    headers = {"User-Agent": AGENT, "Accept": "application/vnd.github+json"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    request = urllib.request.Request(f"https://api.github.com/repos/alpinelinux/aports/contents/{path}?ref={commit}", headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        entries = json.load(response)
    dest.mkdir(parents=True, exist_ok=True)
    for entry in entries:
        if entry["type"] == "dir":
            github_tree(entry["path"], commit, dest / entry["name"])
        elif entry["type"] == "file":
            fetch(entry["download_url"], dest / entry["name"])


def aports_recipe(repo, origin, commit, dest):
    try:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "aports.tar.gz"
            fetch(f"https://gitlab.alpinelinux.org/alpine/aports/-/archive/{commit}/aports-{commit}.tar.gz?path={repo}/{origin}", archive)
            with tarfile.open(archive) as tar:
                tar.extractall(tmp, filter="data")
            shutil.copytree(next(Path(tmp).glob(f"*/{repo}/{origin}")), dest)
    except OSError:
        shutil.rmtree(dest, ignore_errors=True)
        github_tree(f"{repo}/{origin}", commit, dest)


def sha(path, algorithm):
    h = hashlib.new(algorithm)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pkginfo(apk):
    fields = {}
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(apk.read_bytes())), ignore_zeros=True) as tar:
        member = tar.extractfile(".PKGINFO")
        for line in member.read().decode().splitlines():
            if " = " in line:
                key, value = line.split(" = ", 1)
                fields.setdefault(key, value)
    return fields


def apkbuild_sources(apkbuild_dir):
    script = ('srcdir=/nonexistent; builddir=/nonexistent; startdir="$PWD"; CARCH=aarch64; CTARGET=aarch64; '
              'CBUILD=aarch64; CHOST=aarch64; . ./APKBUILD >/dev/null 2>&1; '
              'printf "%s\\n" $source; printf "%s\\n" "--SUMS--"; printf "%s\\n" "$sha512sums"')
    env = {"PATH": "/usr/bin:/bin", "HOME": str(apkbuild_dir)}
    out = subprocess.run(["bash", "-c", script], cwd=apkbuild_dir, capture_output=True, text=True, env=env).stdout
    if "--SUMS--\n" not in out:
        sys.exit(f"could not read the source list of {apkbuild_dir}")
    sources, sums = out.split("--SUMS--\n", 1)
    checksums = {}
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2:
            checksums[parts[1]] = parts[0]
    entries = []
    for entry in sources.split():
        name, _, url = entry.partition("::")
        if not url:
            url, name = name, name.rsplit("/", 1)[-1]
        entries.append((name, url if "://" in url else None))
    return entries, checksums


def alpine_sources(downloads, branch, mirror_branch, out, index):
    lock = (HERE / "alpine-packages.lock").read_text().split("\n")
    origins = {}
    for line in lock:
        parts = line.split()
        if len(parts) != 3 or parts[0] != "rootfs":
            continue
        repo = parts[1].split("/", 1)[0]
        info = pkginfo(downloads / "alpine" / Path(parts[1]).name)
        if COPYLEFT.search(info.get("license", "")):
            origins.setdefault((repo, info["origin"], info["commit"]), set()).add(f"{info['pkgname']} {info['pkgver']} ({info['license']})")
    for (repo, origin, commit), packages in sorted(origins.items()):
        target = out / "alpine" / origin
        target.mkdir(parents=True)
        aports_recipe(repo, origin, commit, target / "aports")
        entries, checksums = apkbuild_sources(target / "aports")
        index.append(f"\n{origin} (aports {repo}/{origin} at {commit})")
        index.extend(f"  binary: {p}" for p in sorted(packages))
        for name, url in entries:
            if url is None:
                continue
            dest = target / name
            for candidate in (f"https://distfiles.alpinelinux.org/distfiles/{mirror_branch}/{name}", url):
                try:
                    fetch(candidate, dest)
                except OSError:
                    continue
                if name not in checksums or sha(dest, "sha512") == checksums[name]:
                    break
                dest.unlink()
            else:
                sys.exit(f"could not fetch {name} for {origin} with the checksum in its APKBUILD")
            index.append(f"  source: {name} ({url})")


def main():
    parser = argparse.ArgumentParser(description="Collect the complete corresponding source of the copyleft components in the Linux runtime.")
    parser.add_argument("output", help="archive to write, for example golens-linux-runtime-<version>-sources.tar")
    args = parser.parse_args()

    v = shell_vars(HERE / "versions.sh", ["KERNEL_URL", "KERNEL_SHA256", "ALPINE_BRANCH", "ALPINE_VERSION"])
    cache = Path(os.environ.get("GOLENS_RUNTIME_CACHE", HERE / "cache"))
    downloads = cache / "downloads"
    kernel = downloads / Path(v["KERNEL_URL"]).name
    if not kernel.is_file() or sha(kernel, "sha256") != v["KERNEL_SHA256"]:
        sys.exit(f"run scripts/runtime/build.sh first: {kernel} is missing or does not match versions.sh")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "sources"
        (root / "kernel").mkdir(parents=True)
        shutil.copy2(kernel, root / "kernel")
        shutil.copytree(HERE, root / "build", ignore=shutil.ignore_patterns("cache", "__pycache__"))
        index = [
            "Sources of the copyleft components in the GoLens Linux runtime",
            "",
            f"Linux kernel: kernel/{kernel.name} (SHA-256 {v['KERNEL_SHA256']}), built unmodified with",
            "build/kernel.config on top of arm64 defconfig by build/build-in-container.sh.",
            "",
            f"Alpine Linux {v['ALPINE_VERSION']} packages: each folder under alpine/ holds the aports build recipe",
            "(APKBUILD and patches) at the commit recorded in the binary package, and the upstream sources it names.",
        ]
        alpine_sources(downloads, v["ALPINE_BRANCH"], v["ALPINE_BRANCH"], root, index)
        (root / "SOURCES.txt").write_text("\n".join(index) + "\n")
        with tarfile.open(args.output, "w", format=tarfile.GNU_FORMAT) as tar:
            tar.add(root, arcname="golens-linux-runtime-sources", filter=lambda t: (setattr(t, "uid", 0), setattr(t, "gid", 0), setattr(t, "uname", ""), setattr(t, "gname", ""), t)[-1])
    print(f"wrote {args.output} ({os.path.getsize(args.output) // (1 << 20)} MB)")


if __name__ == "__main__":
    main()
