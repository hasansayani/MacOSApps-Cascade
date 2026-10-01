// Renders the app icon (three cascaded windows) to a 1024px PNG.
import Cocoa

let out = CommandLine.arguments[1]
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)   // top-left origin

// Background squircle
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.55, alpha: 1))!.draw(in: bg, angle: 90)

let titleColors = [NSColor(calibratedRed: 0.55, green: 0.70, blue: 1.0, alpha: 1),
                   NSColor(calibratedRed: 0.40, green: 0.60, blue: 1.0, alpha: 1),
                   NSColor(calibratedRed: 0.26, green: 0.50, blue: 1.0, alpha: 1)]
for i in 0..<3 {
    let o = CGFloat(i) * 110
    let rect = NSRect(x: 215 + o, y: 230 + o, width: 380, height: 330)
    let win = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
    NSColor.white.setFill(); win.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    win.addClip()
    titleColors[i].setFill(); NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 70)).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 26 + CGFloat(j) * 38, y: rect.minY + 22, width: 26, height: 26)).fill()
    }
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
