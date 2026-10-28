// Draws the app icon, a white waveform on a warm rounded square, at every size an
// .iconset needs. build.sh runs it:  swift Tools/make-icon.swift <folder.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let top = NSColor(srgbRed: 1.00, green: 0.49, blue: 0.27, alpha: 1)
let bottom = NSColor(srgbRed: 0.87, green: 0.17, blue: 0.43, alpha: 1)

/// The rounded square of macOS icons: a superellipse rather than a rounded rectangle.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(cos(t)), 0.4), cos(t))
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(sin(t)), 0.4), sin(t))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)        // draw in 1024-point units at any size
    let scale = CGFloat(pixels) / 1024                     // shadows are measured in pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Apple's icon grid: an 824-point body centred on the 1024 canvas, lifted by a shadow.
    let shape = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(bottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let light = CGGradient(colorsSpace: space,
                           colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    glyph.draw(in: NSRect(x: 512 - glyph.size.width / 2, y: 512 - glyph.size.height / 2,
                          width: glyph.size.width, height: glyph.size.height))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for (points, factor) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let png = render(pixels: points * factor).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent(name))
}
