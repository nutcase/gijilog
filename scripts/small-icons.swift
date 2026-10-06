import AppKit

// Writes Resources/AppIcon-16.png and AppIcon-32.png: swift scripts/small-icons.swift Resources
// Small app icons drawn for their pixel grid: the full artwork shrunk to 16 or 32 pixels turns its two bubbles,
// three lines and check mark into blur. These keep the shapes and colors and drop what cannot be seen.
func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
}
let navyTop = color(0x24475E), navyBottom = color(0x12354A), teal = color(0x5AAEB8), cream = color(0xF7F3EC)
let ink = color(0x1B3F54), check = color(0x3E97A3)

func icon(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    // Top-left origin, in units of the 16-pixel grid.
    cg.translateBy(x: 0, y: s)
    cg.scaleBy(x: s / 16, y: -s / 16)
    // The whole square is the tile; macOS rounds its corners.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [navyTop, navyBottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 16), options: [])
    func bubble(_ rect: CGRect, radius: CGFloat, tail: [CGPoint], fill: CGColor) {
        cg.setFillColor(fill)
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.fillPath()
        cg.move(to: tail[0])
        for point in tail.dropFirst() { cg.addLine(to: point) }
        cg.closePath()
        cg.fillPath()
    }
    if size >= 32 {
        // Back bubble, teal, upper left; front bubble, cream, with two lines and a check.
        bubble(CGRect(x: 1.5, y: 2.5, width: 7.5, height: 6), radius: 2.5,
               tail: [CGPoint(x: 2.5, y: 7), CGPoint(x: 1.5, y: 10.5), CGPoint(x: 5, y: 8.5)], fill: teal)
        bubble(CGRect(x: 4, y: 4.5, width: 10.5, height: 8.5), radius: 2.75,
               tail: [CGPoint(x: 11, y: 12.5), CGPoint(x: 14, y: 14.5), CGPoint(x: 13.5, y: 11)], fill: cream)
        cg.setFillColor(ink)
        cg.fill(CGRect(x: 6, y: 6.5, width: 6.5, height: 1))
        cg.fill(CGRect(x: 6, y: 8.5, width: 6.5, height: 1))
        cg.setStrokeColor(check)
        cg.setLineWidth(1)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.move(to: CGPoint(x: 9.25, y: 10.75))
        cg.addLine(to: CGPoint(x: 10.25, y: 11.75))
        cg.addLine(to: CGPoint(x: 12.25, y: 9.75))
        cg.strokePath()
    } else {
        // At 16 pixels: the cream bubble with two lines, the teal one only as its corner behind.
        bubble(CGRect(x: 1, y: 2, width: 7, height: 6), radius: 2, tail: [CGPoint(x: 2, y: 7), CGPoint(x: 1, y: 10), CGPoint(x: 4, y: 8)], fill: teal)
        bubble(CGRect(x: 4, y: 4, width: 11, height: 9), radius: 2.5,
               tail: [CGPoint(x: 11, y: 12.5), CGPoint(x: 14, y: 15), CGPoint(x: 14, y: 11)], fill: cream)
        cg.setFillColor(ink)
        cg.fill(CGRect(x: 6, y: 6, width: 7, height: 1))
        cg.fill(CGRect(x: 6, y: 9, width: 5, height: 1))
    }
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32] { try! icon(size).write(to: out.appendingPathComponent("AppIcon-\(size).png")) }
