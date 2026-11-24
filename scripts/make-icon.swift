// Draws the app icon: three noise spectra and their sum on a night-blue square.
// Usage: swift scripts/make-icon.swift Hush/Assets.xcassets/AppIcon.appiconset/icon.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

let background = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1),
    CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])

// Core Graphics puts y = 0 at the bottom. x runs 0...1 across the icon.
func curve(_ height: (Double) -> Double) -> CGMutablePath {
    let path = CGMutablePath()
    for i in 0 ... 200 {
        let x = Double(i) / 200
        let point = CGPoint(x: 110 + 804 * x, y: 250 + 520 * height(x))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}
func bump(_ x: Double, at center: Double, width: Double) -> Double {
    exp(-pow((x - center) / width, 2))
}

// A deep rumble, a mid layer with a resonance, and a thin hiss.
let layers: [((Double) -> Double, CGColor)] = [
    ({ x in 0.86 * bump(x, at: 0.12, width: 0.30) }, CGColor(red: 0.71, green: 0.62, blue: 0.99, alpha: 1)),
    ({ x in 0.34 * bump(x, at: 0.5, width: 0.42) + 0.42 * bump(x, at: 0.56, width: 0.055) }, CGColor(red: 0.36, green: 0.84, blue: 0.78, alpha: 1)),
    ({ x in 0.50 * bump(x, at: 0.92, width: 0.26) }, CGColor(red: 0.98, green: 0.74, blue: 0.36, alpha: 1)),
]
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (height, color) in layers {
    let fill = curve(height)
    fill.addLine(to: CGPoint(x: 914, y: 250))
    fill.addLine(to: CGPoint(x: 110, y: 250))
    fill.closeSubpath()
    ctx.addPath(fill)
    ctx.setFillColor(color.copy(alpha: 0.16)!)
    ctx.fillPath()
    ctx.addPath(curve(height))
    ctx.setStrokeColor(color.copy(alpha: 0.9)!)
    ctx.setLineWidth(14)
    ctx.strokePath()
}

// Their sum, in white on top.
let sum = curve { x in 0.92 * layers.reduce(0) { $0 + $1.0(x) } + 0.08 }
ctx.addPath(sum)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.setLineWidth(30)
ctx.strokePath()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
