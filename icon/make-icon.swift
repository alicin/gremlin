// Draws Gremlin's app icon, a holographic paw sticker, and writes AppIcon.icns. Run from the repo root:
// swift icon/make-icon.swift
// The paw is drawn here rather than taken from SF Symbols, whose license rules out app icons.
import AppKit

let size: CGFloat = 1024
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], alpha: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.enumerated().map { color($1, alpha?[$0] ?? 1) } as CFArray, locations: nil)!
}

func newContext() -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Apple's icon grid: an 824 px square with continuous corners, centred on the 1024 px canvas. Core Animation draws
// the same corner curve macOS uses. With a border, it's just the tile's edge.
func tile(border: CGColor? = nil) -> CGImage {
    let shape = CALayer()
    shape.frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    shape.cornerRadius = 185.4
    shape.cornerCurve = .continuous
    if let border {
        shape.borderColor = border
        shape.borderWidth = 4
    } else {
        shape.backgroundColor = color(0xffffff)
    }
    let layer = CALayer()
    layer.frame = canvas
    layer.addSublayer(shape)
    let context = newContext()
    layer.render(in: context)
    return context.makeImage()!
}

func paw(scale: CGFloat, tilt: CGFloat, lift: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    path.move(to: p(0, 34))
    path.addCurve(to: p(170, -140), control1: p(72, 34), control2: p(162, -58))
    path.addCurve(to: p(88, -234), control1: p(180, -206), control2: p(136, -238))
    path.addCurve(to: p(0, -222), control1: p(52, -232), control2: p(28, -222))
    path.addCurve(to: p(-88, -234), control1: p(-28, -222), control2: p(-52, -232))
    path.addCurve(to: p(-170, -140), control1: p(-136, -238), control2: p(-180, -206))
    path.addCurve(to: p(0, 34), control1: p(-162, -58), control2: p(-72, 34))
    path.closeSubpath()
    let toes: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, tilt: CGFloat)] = [
        (-186, 70, 96, 130, 30), (-70, 160, 108, 146, 8), (70, 160, 108, 146, -8), (186, 70, 96, 130, -30),
    ]
    for toe in toes {
        let place = CGAffineTransform(translationX: toe.x, y: toe.y).rotated(by: toe.tilt * .pi / 180)
        path.addEllipse(in: CGRect(x: -toe.width / 2, y: -toe.height / 2, width: toe.width, height: toe.height), transform: place)
    }
    var place = CGAffineTransform(translationX: size / 2, y: size / 2 - 10 + lift)
        .rotated(by: tilt * .pi / 180).scaledBy(x: scale, y: scale)
    return path.copy(using: &place)!
}

// Core Graphics has no conic gradient, so the holographic sweep is a fan of thin wedges.
func holo(_ context: CGContext, center: CGPoint, _ stops: [UInt32]) {
    let steps = 360
    func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat(hex >> shift & 0xff) / 255 }
    for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps) * CGFloat(stops.count - 1)
        let index = min(Int(t), stops.count - 2)
        let mix = t - CGFloat(index)
        let (a, b) = (stops[index], stops[index + 1])
        context.setFillColor(CGColor(srgbRed: channel(a, 16) * (1 - mix) + channel(b, 16) * mix,
                                     green: channel(a, 8) * (1 - mix) + channel(b, 8) * mix,
                                     blue: channel(a, 0) * (1 - mix) + channel(b, 0) * mix, alpha: 1))
        context.move(to: center)
        context.addArc(center: center, radius: size, startAngle: CGFloat(step) / CGFloat(steps) * 2 * .pi,
                       endAngle: CGFloat(step + 1) / CGFloat(steps) * 2 * .pi + 0.01, clockwise: false)
        context.closePath()
        context.fillPath()
    }
}

func render() -> CGImage {
    let context = newContext()
    let shape = tile()
    let everywhere: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.draw(shape, in: canvas)
    context.restoreGState()

    context.saveGState()
    context.clip(to: canvas, mask: shape)
    // Dark indigo, the glass panel's tint, so the sticker's colors stand out.
    context.drawLinearGradient(gradient([0x2c2554, 0x14102a]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: everywhere)
    context.restoreGState()
    // A faint rim keeps the tile's edge visible on a dark Dock.
    context.draw(tile(border: color(0xffffff, 0.14)), in: canvas)

    let sticker = paw(scale: 0.9, tilt: -10, lift: 6)
    let backing = CGMutablePath()
    backing.addPath(sticker.copy(strokingWithWidth: 56, lineCap: .round, lineJoin: .round, miterLimit: 10))
    backing.addPath(sticker)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: color(0x000000, 0.25))
    context.addPath(backing)
    context.setFillColor(color(0xffffff))
    context.fillPath(using: .winding)
    context.restoreGState()

    context.saveGState()
    context.addPath(sticker)
    context.clip()
    holo(context, center: CGPoint(x: 470, y: 560), [0xff5fb8, 0xffd25f, 0x5fffb0, 0x5fc8ff, 0xa45fff, 0xff5fb8])
    context.drawLinearGradient(gradient([0xffffff, 0xffffff, 0xffffff], alpha: [0, 0.45, 0]),
                               start: CGPoint(x: 260, y: 300), end: CGPoint(x: 760, y: 800), options: everywhere)
    context.restoreGState()

    return context.makeImage()!
}

func write(_ image: CGImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = render()
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(image, pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(image, pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
write(image, pixels: 1024, to: root.appendingPathComponent("icon/AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote AppIcon.icns and icon/AppIcon.png" : "iconutil failed")
