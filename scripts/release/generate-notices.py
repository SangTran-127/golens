#!/usr/bin/env python3
"""Build the third-party notices that ship inside GoLens.app.

Reads the license files of every Go module linked into core/libgoagent.dylib,
the Go standard library, every resolved Swift package and the bundled artwork
listed in EXTRA. Identical license texts are kept once with the components
they cover. Writes desktop/Resources/Legal/ThirdPartyNotices.json for the
Acknowledgements window and THIRD_PARTY_NOTICES.txt at the repository root.

  scripts/release/generate-notices.py           write both files
  scripts/release/generate-notices.py --check   exit 1 when either file is stale
"""
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
JSON_OUT = REPO / "desktop/Resources/Legal/ThirdPartyNotices.json"
TEXT_OUT = REPO / "THIRD_PARTY_NOTICES.txt"
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|PATENTS)([.\-_].*)?$", re.IGNORECASE)

EXTRA = [
    {
        "name": "Go gopher",
        "version": "",
        "note": "The Go gopher was designed by Renée French and is licensed under the Creative Commons Attribution 4.0 License (https://creativecommons.org/licenses/by/4.0/). The GoLens mascot and app icons are original drawings based on her design.",
        "files": [],
    },
    {
        "name": "LobeHub provider icons",
        "version": "",
        "note": "",
        "files": ["desktop/Resources/ProviderIcons/LICENSE.md"],
    },
]


def run(args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


def license_files(directory):
    found = sorted(p for p in pathlib.Path(directory).iterdir() if p.is_file() and LICENSE_FILE.match(p.name))
    if not found:
        sys.exit(f"no license file in {directory}")
    return found


def go_components():
    listing = run(["go", "list", "-deps", "-f", "{{with .Module}}{{if not .Main}}{{.Path}}\t{{.Version}}\t{{.Dir}}{{end}}{{end}}", "."], REPO / "core")
    modules = sorted({tuple(line.split("\t")) for line in listing.splitlines() if line.strip()})
    goroot = run(["go", "env", "GOROOT"], REPO / "core").strip()
    version = run(["go", "env", "GOVERSION"], REPO / "core").strip()
    items = [{"name": "Go standard library and runtime", "version": version, "files": license_files(goroot)}]
    for path, ver, directory in modules:
        if not directory:
            sys.exit(f"module {path}@{ver} is not downloaded; run go mod download in core")
        items.append({"name": path, "version": ver, "files": license_files(directory)})
    return items


def swift_components():
    pins = json.loads((REPO / "Package.resolved").read_text())["pins"]
    items = []
    for pin in sorted(pins, key=lambda p: p["identity"]):
        state = pin["state"]
        version = state.get("version") or state["revision"][:12]
        checkout = REPO / ".build/checkouts" / pin["identity"]
        if not checkout.is_dir():
            sys.exit(f"missing {checkout}; run swift package resolve")
        items.append({"name": pin["location"].removeprefix("https://").removesuffix(".git"), "version": version, "files": license_files(checkout)})
    return items


def collect():
    components = swift_components() + go_components()
    extras = [dict(e, files=[REPO / f for f in e["files"]]) for e in EXTRA]
    texts = {}
    for item in components + extras:
        for path in item["files"]:
            body = "\n".join(line.rstrip() for line in path.read_text(errors="replace").strip().splitlines())
            label = f"{item['name']} {item['version']}".strip()
            if len(item["files"]) > 1:
                label += f" ({path.name})"
            texts.setdefault(body, []).append(label)
    sections = [{"title": "Components", "appliesTo": [], "text": "\n".join(
        [f"{i['name']} {i['version']}".strip() for i in components] + [e["name"] for e in extras])}]
    sections += [{"title": e["name"], "appliesTo": [], "text": e["note"]} for e in extras if e["note"]]
    sections += [{"title": users[0] if len(users) == 1 else f"{users[0]} and {len(users) - 1} more", "appliesTo": users, "text": body} for body, users in texts.items()]
    titles = [section["title"] for section in sections]
    if len(titles) != len(set(titles)):
        sys.exit("two notice sections share a title: " + ", ".join(sorted({t for t in titles if titles.count(t) > 1})))
    return sections


def render_text(sections):
    out = ["GoLens Third-Party Notices", "",
           "GoLens includes the open source software and artwork listed below. Each license text is printed once, followed by the components it applies to."]
    for section in sections:
        out += ["", "=" * 78, section["title"]]
        if section["appliesTo"]:
            out.append("Applies to: " + ", ".join(section["appliesTo"]))
        out += ["", section["text"]]
    return "\n".join(out) + "\n"


def main():
    sections = collect()
    outputs = {JSON_OUT: json.dumps(sections, ensure_ascii=False, indent=1) + "\n", TEXT_OUT: render_text(sections)}
    if "--check" in sys.argv[1:]:
        stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
        for path in stale:
            print(f"{path.relative_to(REPO)} is stale; run scripts/release/generate-notices.py")
        if not stale:
            print("third-party notices up to date")
        return 1 if stale else 0
    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {path.relative_to(REPO)} ({len(text)} bytes)")
    print(f"{len(sections[0]['text'].splitlines())} components, {sum(1 for x in sections if x['appliesTo'])} license texts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
