// Renders Resources/AppIcon.icns: a mini EdgeDeck dashboard on an ultra-wide screen.
// Run: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

let size: CGFloat = 1024
func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = UInt64(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}
func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Body: Apple's icon grid (824 pt squircle-ish tile in a 1024 canvas).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color("#0B0D14").setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [color("#262B3D"), color("#10121A"), color("#07080C")], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)
// Coloured glow behind the screen.
NSGradient(colors: [color("#5E9EFF", 0.55), color("#BF5AF2", 0.25), color("#BF5AF2", 0)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 430, options: [])
// Soft top sheen.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY + 120, width: body.width, height: body.height / 2 - 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Everything from here stays inside the tile (the screen's glow would spill out).
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()

// The Edge: a 3.5:1 screen with a thin bezel.
let screen = NSRect(x: 152, y: 400, width: 720, height: 206)
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = color("#5E9EFF", 0.7)
glow.shadowBlurRadius = 60
glow.set()
color("#030407").setFill()
rounded(screen.insetBy(dx: -14, dy: -14), 34).fill()
NSGraphicsContext.restoreGraphicsState()
color("#FFFFFF", 0.16).setStroke()
let bezel = rounded(screen.insetBy(dx: -14, dy: -14), 34)
bezel.lineWidth = 3
bezel.stroke()
color("#0E1016").setFill()
rounded(screen, 22).fill()

// Widget tiles, in EdgeDeck's accent colours (CPU blue, GPU purple, memory green,
// disk orange, notifications red, launcher yellow).
let pad: CGFloat = 14, gap: CGFloat = 12
let inner = screen.insetBy(dx: pad, dy: pad)
func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: String) -> NSRect {
    let r = NSRect(x: inner.minX + x, y: inner.minY + y, width: w, height: h)
    NSGradient(colors: [color(hex), color(hex, 0.72)])!.draw(in: rounded(r, 14), angle: -90)
    return r
}
let h = inner.height, half = (h - gap) / 2
// Columns left to right, all separated by `gap`.
let c1: CGFloat = 0, w1: CGFloat = 118
let c2 = c1 + w1 + gap, w2: CGFloat = 108
let c3 = c2 + w2 + gap, w3: CGFloat = 196
let c4 = c3 + w3 + gap, w4 = inner.width - c4
let keyW = (w4 - gap) / 2
tile(c1, 0, w1, h, "#5E9EFF")                           // tall stat tile
tile(c2, half + gap, w2, half, "#30D158")                // memory
tile(c2, 0, w2, half, "#FF9F0A")                         // disk
let notes = tile(c3, 0, w3, h, "#FF453A")                // notifications
let wide = tile(c4, half + gap, w4, half, "#BF5AF2")     // network sparkline
let key = tile(c4, 0, keyW, half, "#FFD60A")             // launcher keys
tile(c4 + keyW + gap, 0, keyW, half, "#FFD60A")

// Details: notification lines, a sparkline, a clock-ish tick.
NSColor.white.withAlphaComponent(0.85).setFill()
for (i, w) in [140.0, 110, 125].enumerated() {
    rounded(NSRect(x: notes.minX + 22, y: notes.maxY - 40 - CGFloat(i) * 44, width: w, height: 16), 8).fill()
}
let spark = NSBezierPath()
let pts: [CGFloat] = [0.3, 0.55, 0.4, 0.75, 0.5, 0.85, 0.6]
for (i, p) in pts.enumerated() {
    let pt = NSPoint(x: wide.minX + 18 + CGFloat(i) * (wide.width - 36) / CGFloat(pts.count - 1), y: wide.minY + 12 + p * (wide.height - 24))
    i == 0 ? spark.move(to: pt) : spark.line(to: pt)
}
spark.lineWidth = 7
spark.lineCapStyle = .round
spark.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.9).setStroke()
spark.stroke()

// Touch ripple on a launcher key.
let touch = NSPoint(x: key.midX, y: key.midY)
for (r, a) in [(22.0, 0.95), (40.0, 0.45), (58.0, 0.2)] {
    let ring = NSBezierPath(ovalIn: NSRect(x: touch.x - r, y: touch.y - r, width: r * 2, height: r * 2))
    if r == 22 {
        NSColor.white.withAlphaComponent(a).setFill()
        ring.fill()
    } else {
        ring.lineWidth = 5
        NSColor.white.withAlphaComponent(a).setStroke()
        ring.stroke()
    }
}

// Wordmark-free base: a subtle stand bar under the screen.
color("#FFFFFF", 0.10).setFill()
rounded(NSRect(x: 412, y: 330, width: 200, height: 14), 7).fill()

NSGraphicsContext.restoreGraphicsState()  // tile clip
ctx.flush()
NSGraphicsContext.restoreGraphicsState()

// Write an .iconset and convert it.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: size, height: size))
master.addRepresentation(rep)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
