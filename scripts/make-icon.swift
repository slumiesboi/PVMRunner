// Renders the PVMRunner app icon at 1024x1024 and writes every macOS AppIcon size.
//   swift scripts/make-icon.swift <output.appiconset>
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(in ctx: CGContext) {
    // Coordinates are on the 1024 grid with the origin at the bottom left.
    // macOS icon grid: the tile is 824pt with a ~185pt corner radius, inset 100pt.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)

    // Tile drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x3B2FB8))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile body: violet to deep blue diagonal
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x7C5CFF), color(0x4338CA), color(0x0B3B8C)], [0, 0.5, 1]),
                           start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY),
                           options: [])
    // Soft glow in the upper left and a top sheen
    ctx.drawRadialGradient(gradient([color(0xA5B4FC, 0.55), color(0xA5B4FC, 0)], [0, 1]),
                           startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY + 60), options: [])
    ctx.restoreGState()

    // Inner edge highlight
    ctx.saveGState()
    ctx.addPath(roundedRect(tile.insetBy(dx: 3, dy: 3), 182))
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // Back window: the imported bundle, offset up and right
    let back = CGRect(x: 292, y: 372, width: 520, height: 380)
    ctx.saveGState()
    ctx.addPath(roundedRect(back, 54))
    ctx.setFillColor(color(0xFFFFFF, 0.28))
    ctx.fillPath()
    ctx.addPath(roundedRect(back.insetBy(dx: 2, dy: 2), 52))
    ctx.setStrokeColor(color(0xFFFFFF, 0.35))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Front window: the running VM
    let front = CGRect(x: 212, y: 262, width: 560, height: 420)
    let frontPath = roundedRect(front, 58)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: color(0x0A0F3C, 0.45))
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xE8ECFF)], [0, 1]),
                           start: CGPoint(x: 0, y: front.maxY), end: CGPoint(x: 0, y: front.minY), options: [])
    // Title bar
    let titleBar = CGRect(x: front.minX, y: front.maxY - 84, width: front.width, height: 84)
    ctx.setFillColor(color(0xDCE1F7))
    ctx.fill(titleBar)
    ctx.setFillColor(color(0xC7CDEB))
    ctx.fill(CGRect(x: front.minX, y: titleBar.minY - 2, width: front.width, height: 2))
    ctx.restoreGState()

    // Traffic lights
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let center = CGPoint(x: front.minX + 58 + CGFloat(index) * 46, y: titleBar.midY)
        ctx.addEllipse(in: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30))
        ctx.setFillColor(color(hex))
        ctx.fillPath()
    }

    // Play button in the content area
    let content = CGRect(x: front.minX, y: front.minY, width: front.width, height: front.height - 84)
    let disc = CGRect(x: content.midX - 112, y: content.midY - 112, width: 224, height: 224)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x312E81, 0.35))
    ctx.addEllipse(in: disc)
    ctx.setFillColor(color(0x4F46E5))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x8B7BFF), color(0x4338CA)], [0, 1]),
                           start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    ctx.restoreGState()

    // Triangle, nudged right so it looks optically centered
    let r: CGFloat = 70
    let c = CGPoint(x: disc.midX + 12, y: disc.midY)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: c.x + r, y: c.y))
    triangle.addLine(to: CGPoint(x: c.x - r * 0.5, y: c.y + r * 0.866))
    triangle.addLine(to: CGPoint(x: c.x - r * 0.5, y: c.y - r * 0.866))
    triangle.closeSubpath()
    ctx.addPath(triangle)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(22)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.drawPath(using: .fillStroke)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: pixels).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(output.path)")
