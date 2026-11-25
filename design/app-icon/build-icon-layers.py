#!/usr/bin/env python3
"""Rebuilds design/app-icon/GoLens.icon from the native 1024x1024 Boba Milk Tea Gopher master.

Layers, front to back:
  1. CupGlass.png   - Subtle translucent glass sheen along the tapered cup walls
  2. BobaGopher.png - Native 1024x1024 full-bleed 2D cel-shaded Pink Gopher inside iced boba cup
Backdrop fill uses Icon Composer's warm milk-tea automatic-gradient fill.

Run, then compile the icon:
  python3 design/app-icon/build-icon-layers.py
  scripts/make-app-icon.sh
"""
import os
import subprocess
import tempfile

import icon_tools as T

ICON = os.path.join(T.HERE, "GoLens.icon")
MASTER = os.path.join(T.HERE, "boba-master-1024.png")
WARM_MILK_TEA_FILL = {"automatic-gradient": "extended-srgb:0.89000,0.68000,0.44000,1.00000"}

SWIFT_GLASS = r"""
import AppKit

let outGlass = CommandLine.arguments[1]
let canvasSize = 1024

let glassRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let glassCtx = NSGraphicsContext(bitmapImageRep: glassRep)!
NSGraphicsContext.current = glassCtx

let leftSheen = NSBezierPath()
leftSheen.move(to: NSPoint(x: 204, y: 744))
leftSheen.line(to: NSPoint(x: 272, y: 196))
leftSheen.lineWidth = 18
leftSheen.lineCapStyle = .round
NSColor(calibratedWhite: 1.0, alpha: 0.22).setStroke()
leftSheen.stroke()

let rightGlint = NSBezierPath()
rightGlint.move(to: NSPoint(x: 822, y: 740))
rightGlint.line(to: NSPoint(x: 780, y: 360))
rightGlint.lineWidth = 8
rightGlint.lineCapStyle = .round
NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
rightGlint.stroke()

NSGraphicsContext.restoreGraphicsState()
try! glassRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outGlass))
"""


def main():
    if not os.path.isfile(MASTER):
        raise FileNotFoundError(f"Missing native 1024x1024 master at {MASTER}")
    with tempfile.TemporaryDirectory() as work:
        script = os.path.join(work, "prep_glass.swift")
        glass_png = os.path.join(work, "CupGlass.png")
        with open(script, "w") as fh:
            fh.write(SWIFT_GLASS)
        subprocess.run(["swift", script, glass_png], check=True)
        T.write_png_icon_bundle(
            ICON,
            WARM_MILK_TEA_FILL,
            [
                ("Cup Glass", [("Glass", glass_png)], True, 0.0, True, 0.35),
                ("Boba Milk Tea Gopher", [("BobaGopher", MASTER)], True, 0.14, False, 0.45),
            ],
        )
    print("Updated", os.path.relpath(ICON, T.ROOT))


if __name__ == "__main__":
    main()
