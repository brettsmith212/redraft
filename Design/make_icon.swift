// Renders Redraft's app icon at 1024×1024.
// Usage: swift Design/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt tile centred on a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

// Soft drop shadow.
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0xF6F2EA).setFill()
shape.fill()
ctx.restoreGState()

// Warm paper gradient.
ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(0xFBF9F4), color(0xEFE9DD)])!.draw(in: tile, angle: -90)
// Faint inner edge.
color(0x2B2A26, 0.06).setStroke()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
edge.lineWidth = 3
edge.stroke()
ctx.restoreGState()

// "Text" lines: rounded ink bars, like a paragraph seen from a distance.
let ink = color(0x2B2A26)
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ alpha: CGFloat = 0.82) {
    ink.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 38), xRadius: 19, yRadius: 19).fill()
}
let left: CGFloat = 238
// Heading.
ink.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: left, y: 690, width: 330, height: 58), xRadius: 29, yRadius: 29).fill()
// Paragraph lines.
bar(left, 586, 548)
let wordX = left + 156, wordW: CGFloat = 154
bar(left, 500, 132); bar(wordX, 500, wordW)              // a word, then the word with alternates
bar(left + 444, 500, 104)
bar(left, 414, 470)
bar(left, 328, 392, 0.2)                                 // a ghosted line

// The alternate: an editor's-pen underline under the second word…
let amber = color(0xA8743A)
let x0 = wordX + 4, x1 = wordX + wordW - 2, y: CGFloat = 474
let pen = NSBezierPath()
pen.move(to: NSPoint(x: x0, y: y + 2))
let span = x1 - x0
pen.curve(to: NSPoint(x: x0 + span * 0.38, y: y - 3), controlPoint1: NSPoint(x: x0 + span * 0.13, y: y + 5), controlPoint2: NSPoint(x: x0 + span * 0.25, y: y - 6))
pen.curve(to: NSPoint(x: x0 + span * 0.76, y: y + 1), controlPoint1: NSPoint(x: x0 + span * 0.51, y: y), controlPoint2: NSPoint(x: x0 + span * 0.64, y: y + 6))
pen.curve(to: NSPoint(x: x1, y: y - 3), controlPoint1: NSPoint(x: x0 + span * 0.88, y: y - 3), controlPoint2: NSPoint(x: x0 + span * 0.96, y: y - 5))
pen.lineWidth = 15
pen.lineCapStyle = .round
amber.setStroke()
pen.stroke()

// …and its dots: one in place, the others waiting.
let dotY: CGFloat = 519
for (i, alpha) in [1.0, 0.38, 0.38].enumerated() {
    amber.withAlphaComponent(alpha).setFill()
    let d: CGFloat = i == 0 ? 28 : 24
    let cx = wordX + wordW + 34 + CGFloat(i) * 40
    NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: dotY - d / 2, width: d, height: d)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
