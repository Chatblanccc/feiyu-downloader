import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.94, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.74, blue: 0.76, alpha: 1))!
gradient.draw(in: background, angle: -45)
let wing = NSBezierPath()
wing.move(to: NSPoint(x: 245, y: 580))
wing.curve(to: NSPoint(x: 785, y: 800), controlPoint1: NSPoint(x: 320, y: 845), controlPoint2: NSPoint(x: 620, y: 855))
wing.curve(to: NSPoint(x: 510, y: 470), controlPoint1: NSPoint(x: 745, y: 650), controlPoint2: NSPoint(x: 620, y: 540))
wing.line(to: NSPoint(x: 418, y: 555))
wing.curve(to: NSPoint(x: 245, y: 580), controlPoint1: NSPoint(x: 355, y: 612), controlPoint2: NSPoint(x: 300, y: 600))
wing.close()
NSColor.white.withAlphaComponent(0.97).setFill()
wing.fill()
let arrow = NSBezierPath()
arrow.lineWidth = 66
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 512, y: 610))
arrow.line(to: NSPoint(x: 512, y: 280))
arrow.move(to: NSPoint(x: 390, y: 395))
arrow.line(to: NSPoint(x: 512, y: 273))
arrow.line(to: NSPoint(x: 634, y: 395))
NSColor.white.setStroke()
arrow.stroke()
let baseline = NSBezierPath()
baseline.lineWidth = 48
baseline.lineCapStyle = .round
baseline.move(to: NSPoint(x: 342, y: 190))
baseline.line(to: NSPoint(x: 682, y: 190))
baseline.stroke()
image.unlockFocus()

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        representation.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try representation.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
