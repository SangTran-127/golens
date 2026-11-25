import AppKit

// Renders the icon named in a compiled app bundle to PNG files, the way AppKit draws it.
// Usage: render-icon <bundle path> <icon name> <out dir> <px>...
let args = CommandLine.arguments
guard args.count >= 5, let bundle = Bundle(path: args[1]), let icon = bundle.image(forResource: args[2]) else {
    FileHandle.standardError.write("usage: render-icon <bundle> <icon name> <out dir> <px>...\n".data(using: .utf8)!)
    exit(2)
}
let out = args[3]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for px in args[4...].compactMap({ Int($0) }) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(px).png"))
}
