#!/usr/bin/env python3
"""Builds the seasonal app icons (desktop/Resources/AppIcons/golens-icon-<season>.png)
from the unified 2D Cel-Shaded Mascot Icons sheets (no geometric Vector Rig).

Run: python3 design/app-icon/build-seasonal-icons.py [--preview DIR]
"""
import argparse
import os
import subprocess
import tempfile

import icon_tools as T

OUT = os.path.join(T.ROOT, "desktop", "Resources", "AppIcons")
HERITAGE_SHEET = os.path.join(T.ROOT, "design", "mascot", "preview", "artist-mascot-icons.png")
FESTIVAL_SHEET = os.path.join(T.ROOT, "design", "mascot", "preview", "duckoo-festival-icons.png")

SEASON_CROPS = {
    "hacker":    (HERITAGE_SHEET, 304, 92, 232, 232, "extended-srgb:0.04000,0.05500,0.07500,1.00000"),
    "halloween": (HERITAGE_SHEET, 572, 92, 232, 232, "extended-srgb:0.17000,0.10000,0.30000,1.00000"),
    "noel":      (HERITAGE_SHEET, 840, 92, 232, 232, "extended-srgb:0.05000,0.30000,0.22000,1.00000"),
    "tet":       (HERITAGE_SHEET, 1106, 92, 232, 232, "extended-srgb:0.68000,0.09000,0.10000,1.00000"),
}

CROP_SWIFT = r"""
import AppKit
let sheetPath = CommandLine.arguments[1]
let x = CGFloat(Double(CommandLine.arguments[2])!)
let y = CGFloat(Double(CommandLine.arguments[3])!)
let w = CGFloat(Double(CommandLine.arguments[4])!)
let h = CGFloat(Double(CommandLine.arguments[5])!)
let outPath = CommandLine.arguments[6]
let img = NSImage(contentsOfFile: sheetPath)!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
ctx.imageInterpolation = .high
NSGraphicsContext.current = ctx
let path = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
path.addClip()
img.draw(in: NSRect(x: 64, y: 64, width: 896, height: 896),
         from: NSRect(x: x, y: img.size.height - y - h, width: w, height: h),
         operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
"""


def build(season, spec, preview):
    sheet, x, y, w, h, fill = spec
    with tempfile.TemporaryDirectory() as work:
        script = os.path.join(work, "crop.swift")
        layer_png = os.path.join(work, f"{season}.png")
        with open(script, "w") as fh:
            fh.write(CROP_SWIFT)
        subprocess.run(["swift", script, sheet, str(x), str(y), str(w), str(h), layer_png], check=True)
        icon = os.path.join(work, f"golens-icon-{season}.icon")
        T.write_png_icon_bundle(
            icon,
            {"automatic-gradient": fill},
            [(season.title(), [(season, layer_png)], True, 0.2, False)],
        )
        rendered = os.path.join(work, "out")
        T.compile_and_render(icon, [512], rendered)
        dest = os.path.join(preview or OUT, f"golens-icon-{season}.png")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(os.path.join(rendered, "512.png"), "rb") as src, open(dest, "wb") as dst:
            dst.write(src.read())
        print("wrote", os.path.relpath(dest, T.ROOT) if dest.startswith(T.ROOT) else dest)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="write PNGs here instead of desktop/Resources/AppIcons")
    a = ap.parse_args()
    for season, spec in SEASON_CROPS.items():
        build(season, spec, a.preview)


if __name__ == "__main__":
    main()
