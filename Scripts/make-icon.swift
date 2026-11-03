// Renders the Hive app icon (1024×1024 PNG) to the path given as first argument.
import AppKit

let outPath = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size: CGFloat = 1024
let accentLight = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.45, alpha: 1)
let accent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let accentDark = NSColor(calibratedRed: 0.72, green: 0.33, blue: 0.22, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Apple's macOS icon grid: 824pt body centered in 1024, ~185pt corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

// Background: near-black vertical gradient with a faint warm glow behind the symbol.
ctx.saveGState()
squircle.addClip()
NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.02, alpha: 1)])!
    .draw(in: body, angle: -90)
NSGradient(colors: [accent.withAlphaComponent(0.38), accent.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0, toCenter: NSPoint(x: 512, y: 512), radius: 360, options: [])

// Inner rim highlight.
NSColor(white: 1, alpha: 0.08).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
rim.lineWidth = 4
rim.stroke()
ctx.restoreGState()

// The sparkle symbol, filled with a warm gradient and a soft glow.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let symbolSize = symbol.size
let symbolRect = NSRect(x: 512 - symbolSize.width / 2, y: 512 - symbolSize.height / 2,
                        width: symbolSize.width, height: symbolSize.height)

// Gradient-filled sparkle: draw the gradient, then mask it with the symbol's alpha.
let tinted = NSImage(size: symbolSize, flipped: false) { rect in
    NSGradient(colors: [accentLight, accent, accentDark])!.draw(in: rect, angle: -60)
    symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    return true
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: accent.withAlphaComponent(0.75).cgColor)
tinted.draw(in: symbolRect)
ctx.restoreGState()
tinted.draw(in: symbolRect)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
