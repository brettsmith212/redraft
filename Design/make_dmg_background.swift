// Renders the background for Redraft's disk image: warm paper and a soft
// arrow from the app to Applications.
// Usage: swift Design/make_dmg_background.swift <folder>, then combine:
//   tiffutil -cathidpicheck <folder>/dmg-background.png <folder>/dmg-background@2x.png -out Design/dmg-background.tiff
// The icon positions here must match Tools/dmg_settings.py.
import AppKit

let width: CGFloat = 600, height: CGFloat = 400
let appCenter = NSPoint(x: 160, y: 190)        // from the top-left, like Finder
let applicationsCenter = NSPoint(x: 440, y: 190)
let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)  // points, so @2x stays sharp
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let flipY = { (y: CGFloat) in height - y }

    // Paper, with a whisper of vertical shading.
    NSGradient(colors: [color(0xF8F5EF), color(0xF1ECE2)])!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The arrow: a gently curved stroke with a rounded head.
    let y = flipY(appCenter.y)
    let start = NSPoint(x: appCenter.x + 88, y: y)
    let end = NSPoint(x: applicationsCenter.x - 92, y: y)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: NSPoint(x: start.x + 40, y: y + 16), controlPoint2: NSPoint(x: end.x - 40, y: y + 16))
    arrow.lineWidth = 3.5
    arrow.lineCapStyle = .round
    color(0xA8743A, 0.85).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 13, y: y + 11))
    head.line(to: end)
    head.line(to: NSPoint(x: end.x - 14, y: y - 9))
    head.lineWidth = 3.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: "\(folder)/dmg-background.png")
render(scale: 2, to: "\(folder)/dmg-background@2x.png")
print("Wrote \(folder)/dmg-background.png and @2x")
