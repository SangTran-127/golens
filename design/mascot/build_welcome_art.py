#!/usr/bin/env python3
"""Builds GoLens Welcome Art Concept 2 assets into desktop/Resources/WelcomeArt/ (< 400 KB total).

Generates:
  - 5 circular 2D Cel-Shaded Diorama Medallions (272x272 @2x indexed-RGBA PNG)
  - 4 Calm Studio Canvas vector PDFs (440x480 pt, light/dark + high contrast variants)
"""
import binascii
import os
import struct
import subprocess
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PREVIEW_DIR = os.path.join(HERE, "preview")
OUT_DIR = os.path.join(ROOT, "desktop", "Resources", "WelcomeArt")

MEDALLIONS = [
    ("welcome-medallion-default", "duckoo-adventure-badges.png", 352, 404, 316, 316),
    ("welcome-medallion-tet", "duckoo-diorama-badges.png", 292, 48, 296, 296),
    ("welcome-medallion-noel", "duckoo-diorama-badges.png", 196, 428, 296, 296),
    ("welcome-medallion-halloween", "duckoo-diorama-badges.png", 865, 422, 306, 306),
    ("welcome-medallion-hacker", "duckoo-adventure-badges.png", 708, 403, 316, 316),
]

SWIFT_HELPER = r"""
import AppKit
import CoreGraphics

let mode = CommandLine.arguments[1]

if mode == "crop-rgba" {
    let srcPath = CommandLine.arguments[2]
    let x = CGFloat(Double(CommandLine.arguments[3])!)
    let y = CGFloat(Double(CommandLine.arguments[4])!)
    let w = CGFloat(Double(CommandLine.arguments[5])!)
    let h = CGFloat(Double(CommandLine.arguments[6])!)
    let outSize = Int(CommandLine.arguments[7])!
    let outRawPath = CommandLine.arguments[8]

    let img = NSImage(contentsOfFile: srcPath)!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outSize, pixelsHigh: outSize,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: outSize * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let inset: CGFloat = 1.0
    let clipPath = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: CGFloat(outSize) - inset * 2, height: CGFloat(outSize) - inset * 2))
    clipPath.addClip()
    img.draw(in: NSRect(x: 0, y: 0, width: outSize, height: outSize),
             from: NSRect(x: x, y: img.size.height - y - h, width: w, height: h),
             operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    let data = Data(bytes: rep.bitmapData!, count: outSize * outSize * 4)
    try! data.write(to: URL(fileURLWithPath: outRawPath))
} else if mode == "pdfs" {
    let outDir = CommandLine.arguments[2]
    func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    func blend(_ baseHex: UInt32, _ tintHex: UInt32, _ frac: CGFloat) -> CGColor {
        let br = CGFloat((baseHex >> 16) & 0xFF) / 255.0
        let bg = CGFloat((baseHex >> 8) & 0xFF) / 255.0
        let bb = CGFloat(baseHex & 0xFF) / 255.0
        let tr = CGFloat((tintHex >> 16) & 0xFF) / 255.0
        let tg = CGFloat((tintHex >> 8) & 0xFF) / 255.0
        let tb = CGFloat(tintHex & 0xFF) / 255.0
        return CGColor(
            srgbRed: br + (tr - br) * frac,
            green: bg + (tg - bg) * frac,
            blue: bb + (tb - bb) * frac,
            alpha: 1.0
        )
    }

    struct Spec {
        let name: String
        let bgHex: UInt32
        let glowHex: UInt32
        let glowAlpha: CGFloat
        let horizonFillAlpha: CGFloat
        let horizonStrokeAlpha: CGFloat
    }

    let specs = [
        Spec(name: "welcome-canvas-light", bgHex: 0xF4F6F9, glowHex: 0x009AC7, glowAlpha: 0.09, horizonFillAlpha: 0.06, horizonStrokeAlpha: 0.18),
        Spec(name: "welcome-canvas-dark", bgHex: 0x1B2028, glowHex: 0x4CC9EB, glowAlpha: 0.11, horizonFillAlpha: 0.09, horizonStrokeAlpha: 0.24),
        Spec(name: "welcome-canvas-light-hc", bgHex: 0xF8FAFC, glowHex: 0x005A70, glowAlpha: 0.0, horizonFillAlpha: 0.08, horizonStrokeAlpha: 0.36),
        Spec(name: "welcome-canvas-dark-hc", bgHex: 0x12161C, glowHex: 0x6EE7FF, glowAlpha: 0.0, horizonFillAlpha: 0.11, horizonStrokeAlpha: 0.42),
    ]

    for s in specs {
        var box = CGRect(x: 0, y: 0, width: 440, height: 480)
        let pdfURL = URL(fileURLWithPath: outDir).appendingPathComponent("\(s.name).pdf")
        guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil) else { fatalError("PDF create failed") }
        ctx.beginPDFPage(nil)

        ctx.setFillColor(color(s.bgHex, 1.0))
        ctx.fill(box)

        if s.glowAlpha > 0 {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradColors = [blend(s.bgHex, s.glowHex, s.glowAlpha), color(s.bgHex, 1.0)] as CFArray
            let locs: [CGFloat] = [0.0, 1.0]
            if let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: locs) {
                let center = CGPoint(x: 220, y: 356)
                ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: 230, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }

        // CoreGraphics PDF uses bottom-left origin (y=0 bottom, y=480 top).
        let horizonPath = CGMutablePath()
        horizonPath.move(to: CGPoint(x: -20, y: 42))
        horizonPath.addQuadCurve(to: CGPoint(x: 460, y: 42), control: CGPoint(x: 220, y: 80))
        horizonPath.addLine(to: CGPoint(x: 460, y: -10))
        horizonPath.addLine(to: CGPoint(x: -20, y: -10))
        horizonPath.closeSubpath()
        ctx.addPath(horizonPath)
        ctx.setFillColor(blend(s.bgHex, s.glowHex, s.horizonFillAlpha))
        ctx.fillPath()

        let strokePath = CGMutablePath()
        strokePath.move(to: CGPoint(x: -20, y: 42))
        strokePath.addQuadCurve(to: CGPoint(x: 460, y: 42), control: CGPoint(x: 220, y: 80))
        ctx.addPath(strokePath)
        ctx.setStrokeColor(blend(s.bgHex, s.glowHex, s.horizonStrokeAlpha))
        ctx.setLineWidth(1.25)
        ctx.strokePath()

        ctx.setFillColor(blend(s.bgHex, s.glowHex, s.horizonStrokeAlpha))
        ctx.fillEllipse(in: CGRect(x: 31.5, y: 61.5, width: 5, height: 5))
        ctx.fillEllipse(in: CGRect(x: 403.5, y: 61.5, width: 5, height: 5))

        ctx.endPDFPage()
        ctx.closePDF()
    }
}
"""


def write_indexed_rgba_png(raw_bytes, width, height, out_png):
    """Median-cut 256-color RGBA palette encoder (transparent index 0 + 255 RGBA entries)."""
    pixels = [raw_bytes[i:i + 4] for i in range(0, len(raw_bytes), 4)]
    opaque = []
    rim = []
    for p in pixels:
        r, g, b, a = p[0], p[1], p[2], p[3]
        if a < 16:
            continue
        if a < 240:
            rim.append((r, g, b, a))
        else:
            opaque.append((r, g, b, 255))

    def split_buckets(sample_pts, max_colors):
        if not sample_pts or max_colors <= 0:
            return []
        buckets = [sample_pts]
        while len(buckets) < max_colors:
            best_idx = -1
            best_range = -1
            best_ch = 0
            for idx, bkt in enumerate(buckets):
                if len(bkt) < 2:
                    continue
                for ch in range(4):
                    vals = [p[ch] for p in bkt]
                    rng = max(vals) - min(vals)
                    if rng > best_range:
                        best_range = rng
                        best_idx = idx
                        best_ch = ch
            if best_idx < 0 or best_range <= 2:
                break
            bkt = sorted(buckets.pop(best_idx), key=lambda p: p[best_ch])
            mid = len(bkt) // 2
            buckets.append(bkt[:mid])
            buckets.append(bkt[mid:])
        out = []
        for bkt in buckets:
            n = len(bkt)
            out.append((
                sum(p[0] for p in bkt) // n,
                sum(p[1] for p in bkt) // n,
                sum(p[2] for p in bkt) // n,
                sum(p[3] for p in bkt) // n,
            ))
        return out

    # Downsample opaque pixels for fast median cut
    step = max(1, len(opaque) // 18000)
    palette = [(0, 0, 0, 0)]
    palette.extend(split_buckets(opaque[::step], 240))
    if rim:
        rim_step = max(1, len(rim) // 2000)
        palette.extend(split_buckets(rim[::rim_step], 256 - len(palette)))
    while len(palette) < 256:
        palette.append((0, 0, 0, 0))

    # Build fast quantized lookup key (5-bit RGB + 4-bit A -> nearest palette entry)
    cache = {}
    indexed = bytearray(width * height)
    for idx, p in enumerate(pixels):
        r, g, b, a = p[0], p[1], p[2], p[3]
        if a < 16:
            indexed[idx] = 0
            continue
        key = ((r >> 2) << 18) | ((g >> 2) << 12) | ((b >> 2) << 6) | (a >> 3)
        hit = cache.get(key)
        if hit is None:
            best_i = 1
            best_d = 1 << 30
            for pi in range(1, len(palette)):
                pr, pg, pb, pa = palette[pi]
                if pa == 0:
                    continue
                dr = r - pr
                dg = g - pg
                db = b - pb
                da = (a - pa) * 2
                d = dr * dr + dg * dg + db * db + da * da
                if d < best_d:
                    best_d = d
                    best_i = pi
            cache[key] = best_i
            hit = best_i
        indexed[idx] = hit

    # PNG scanlines with filter 0
    raw_scan = bytearray()
    for y in range(height):
        raw_scan.append(0)
        raw_scan.extend(indexed[y * width:(y + 1) * width])

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", binascii.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    plte = bytes(c for r, g, b, _ in palette for c in (r, g, b))
    trns = bytes(a for _, _, _, a in palette)
    idat = zlib.compress(bytes(raw_scan), 9)
    with open(out_png, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", ihdr))
        fh.write(chunk(b"PLTE", plte))
        fh.write(chunk(b"tRNS", trns))
        fh.write(chunk(b"IDAT", idat))
        fh.write(chunk(b"IEND", b""))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        swift_file = os.path.join(work, "welcome_art.swift")
        with open(swift_file, "w") as fh:
            fh.write(SWIFT_HELPER)
        subprocess.run(["swift", swift_file, "pdfs", OUT_DIR], check=True)
        size_px = 272
        for name, sheet, x, y, w, h in MEDALLIONS:
            raw_path = os.path.join(work, f"{name}.rgba")
            src = os.path.join(PREVIEW_DIR, sheet)
            subprocess.run(
                ["swift", swift_file, "crop-rgba", src, str(x), str(y), str(w), str(h), str(size_px), raw_path],
                check=True,
            )
            with open(raw_path, "rb") as fh:
                raw = fh.read()
            out_png = os.path.join(OUT_DIR, f"{name}.png")
            write_indexed_rgba_png(raw, size_px, size_px, out_png)
            print(f"Wrote {os.path.relpath(out_png, ROOT)} ({os.path.getsize(out_png) / 1024:.1f} KB)")

    total_kb = sum(os.path.getsize(os.path.join(OUT_DIR, f)) for f in os.listdir(OUT_DIR)) / 1024.0
    print(f"Total desktop/Resources/WelcomeArt size: {total_kb:.1f} KB")
    if total_kb >= 400.0:
        raise SystemExit(f"Size budget exceeded: {total_kb:.1f} KB >= 400 KB")


if __name__ == "__main__":
    main()
