import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    NSColor(red: 0.075, green: 0.105, blue: 0.14, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), xRadius: 190, yRadius: 190).fill()
    let blocks: [(CGRect, NSColor)] = [
        (CGRect(x: 208, y: 208, width: 348, height: 608), NSColor(red: 0.58, green: 0.81, blue: 0.67, alpha: 1)),
        (CGRect(x: 582, y: 482, width: 234, height: 334), NSColor(red: 0.34, green: 0.57, blue: 0.84, alpha: 1)),
        (CGRect(x: 582, y: 208, width: 234, height: 248), NSColor(red: 0.63, green: 0.46, blue: 0.82, alpha: 1))
    ]
    for (rect, color) in blocks { color.setFill(); NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill() }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: output.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: output.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
