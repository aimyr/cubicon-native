import AppKit
import Foundation

// Project artwork is drawn from vectors; no proprietary application icon is used.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = root.appendingPathComponent("build/artwork/AppIcon.iconset")
let destination = root.appendingPathComponent("native/Assets/AppIcon.icns")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.04, green: 0.075, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 208, yRadius: 208).fill()
    func face(_ coordinates: [(CGFloat, CGFloat)], color: NSColor) {
        let path = NSBezierPath(); path.move(to: NSPoint(x: coordinates[0].0, y: coordinates[0].1))
        for point in coordinates.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        path.close(); color.setFill(); path.fill()
        NSColor(calibratedRed: 0.025, green: 0.085, blue: 0.14, alpha: 1).setStroke()
        path.lineWidth = 12; path.lineJoinStyle = .round; path.stroke()
    }
    face([(512, 812), (770, 664), (512, 516), (254, 664)], color: NSColor(calibratedRed: 0.48, green: 0.94, blue: 0.95, alpha: 1))
    face([(254, 664), (512, 516), (512, 218), (254, 366)], color: NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.86, alpha: 1))
    face([(512, 516), (770, 664), (770, 366), (512, 218)], color: NSColor(calibratedRed: 0.09, green: 0.68, blue: 0.75, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: work.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: work.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", work.path, "-o", destination.path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print(destination.path)
