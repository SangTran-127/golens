"""Shared helpers for GoLens icon artwork.

Renders SVG or PNG layers, writes Icon Composer bundles, compiles them with actool and renders
the compiled icon to PNG the way AppKit draws it (Liquid Glass included).
"""
import json
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
XCODE = os.environ.get("XCODE_DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def render_svg(svg, out_png, size=1024):
    """Renders an SVG string to a transparent PNG of size x size pixels."""
    with tempfile.TemporaryDirectory() as work:
        page = os.path.join(work, "layer.html")
        with open(page, "w") as fh:
            fh.write('<html><body style="margin:0;background:transparent">' + svg + "</body></html>")
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--user-data-dir={os.path.join(work, 'profile')}", "--default-background-color=00000000",
                        f"--window-size={size},{size}", f"--screenshot={out_png}", "file://" + page],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write_icon_bundle(icon_dir, fill, groups):
    """Writes an Icon Composer bundle from SVG layer groups."""
    if os.path.isdir(icon_dir):
        shutil.rmtree(icon_dir)
    assets = os.path.join(icon_dir, "Assets")
    os.makedirs(assets)
    manifest_groups = []
    for name, layers, specular, shadow, glass in groups:
        entries = []
        for layer_name, svg in layers:
            render_svg(svg, os.path.join(assets, f"{layer_name}.png"))
            entries.append({"image-name": f"{layer_name}.png", "name": layer_name})
        manifest_groups.append({
            "layers": entries, "name": name,
            "shadow": {"kind": "neutral", "opacity": shadow}, "specular": specular,
            "translucency": {"enabled": glass, "value": 0.45},
        })
    manifest = {"fill": fill, "groups": manifest_groups,
                "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}}
    with open(os.path.join(icon_dir, "icon.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")


def write_png_icon_bundle(icon_dir, fill, png_groups):
    """Writes an Icon Composer bundle from pre-rendered 1024x1024 PNG layer files."""
    if os.path.isdir(icon_dir):
        shutil.rmtree(icon_dir)
    assets = os.path.join(icon_dir, "Assets")
    os.makedirs(assets)
    manifest_groups = []
    for item in png_groups:
        if len(item) == 5:
            name, layers, specular, shadow, glass = item
            translucency_val = 0.45
        else:
            name, layers, specular, shadow, glass, translucency_val = item
        entries = []
        for layer_name, src_png in layers:
            dst_png = os.path.join(assets, f"{layer_name}.png")
            shutil.copyfile(src_png, dst_png)
            entries.append({"image-name": f"{layer_name}.png", "name": layer_name})
        manifest_groups.append({
            "layers": entries, "name": name,
            "shadow": {"kind": "neutral", "opacity": shadow}, "specular": specular,
            "translucency": {"enabled": glass, "value": translucency_val},
        })
    manifest = {"fill": fill, "groups": manifest_groups,
                "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}}
    with open(os.path.join(icon_dir, "icon.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")


def compile_and_render(icon_dir, sizes, out_dir):
    """Compiles an .icon bundle with actool and writes <out_dir>/<px>.png for each size."""
    name = os.path.splitext(os.path.basename(icon_dir))[0]
    env = dict(os.environ, DEVELOPER_DIR=XCODE)
    with tempfile.TemporaryDirectory() as work:
        compiled = os.path.join(work, "compiled")
        os.makedirs(compiled)
        subprocess.run(["xcrun", "actool", "--compile", compiled, "--app-icon", name,
                        "--output-partial-info-plist", os.path.join(work, "partial.plist"), "--platform", "macosx",
                        "--minimum-deployment-target", "14.0", "--target-device", "mac", icon_dir],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        app = os.path.join(work, "Icon.app")
        resources = os.path.join(app, "Contents", "Resources")
        os.makedirs(resources)
        for f in os.listdir(compiled):
            shutil.move(os.path.join(compiled, f), resources)
        with open(os.path.join(app, "Contents", "Info.plist"), "w") as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                     '<key>CFBundleIdentifier</key><string>dev.golens.icon-render</string>'
                     '<key>CFBundlePackageType</key><string>APPL</string>'
                     f'<key>CFBundleIconFile</key><string>{name}</string>'
                     f'<key>CFBundleIconName</key><string>{name}</string></dict></plist>')
        renderer = os.path.join(work, "render-icon")
        subprocess.run(["xcrun", "swiftc", "-O", "-o", renderer, os.path.join(HERE, "render-icon.swift")],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run([renderer, app, name, out_dir] + [str(s) for s in sizes], check=True)
