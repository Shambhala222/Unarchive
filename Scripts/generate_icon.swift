import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    let inset: CGFloat = 72
    let box = rect.insetBy(dx: inset, dy: inset)
    let radius: CGFloat = 228

    let squircle = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.16, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.48, green: 0.08, blue: 0.10, alpha: 1).cgColor
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: box.midX, y: box.maxY),
            end: CGPoint(x: box.midX, y: box.minY),
            options: []
        )
    }

    let highlight = CGPath(
        roundedRect: CGRect(x: box.minX + 18, y: box.maxY - 210, width: box.width - 36, height: 180),
        cornerWidth: 90,
        cornerHeight: 90,
        transform: nil
    )
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.addPath(highlight)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.setLineWidth(6)
    ctx.addPath(squircle)
    ctx.strokePath()

    let archive = CGRect(x: 286, y: 250, width: 452, height: 470)
    let lid = CGRect(x: 250, y: 668, width: 524, height: 92)
    let bodyPath = CGPath(roundedRect: archive, cornerWidth: 36, cornerHeight: 36, transform: nil)
    let lidPath = CGPath(roundedRect: lid, cornerWidth: 28, cornerHeight: 28, transform: nil)

    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.86, alpha: 1).cgColor)
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.92, alpha: 1).cgColor)
    ctx.addPath(lidPath)
    ctx.fillPath()

    ctx.setStrokeColor(NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.38, alpha: 1).cgColor)
    ctx.setLineWidth(8)
    ctx.addPath(bodyPath)
    ctx.strokePath()
    ctx.addPath(lidPath)
    ctx.strokePath()

    let zipX = archive.midX
    ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.32, blue: 0.28, alpha: 1).cgColor)
    ctx.setLineWidth(10)
    ctx.move(to: CGPoint(x: zipX, y: archive.maxY - 12))
    ctx.addLine(to: CGPoint(x: zipX, y: archive.minY + 36))
    ctx.strokePath()

    for step in stride(from: archive.minY + 70, through: archive.maxY - 50, by: 34) {
        let tooth = CGRect(x: zipX - 16, y: step, width: 32, height: 14)
        ctx.setFillColor(NSColor(calibratedRed: 0.45, green: 0.42, blue: 0.38, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: tooth, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
    }

    let slider = CGRect(x: zipX - 38, y: archive.midY - 10, width: 76, height: 70)
    ctx.setFillColor(NSColor(calibratedRed: 0.78, green: 0.22, blue: 0.20, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: slider, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor(calibratedRed: 0.90, green: 0.34, blue: 0.28, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: slider.insetBy(dx: 10, dy: 28), cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()

    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Icon konnte nicht erzeugt werden.\n", stderr)
    exit(1)
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
try png.write(to: URL(fileURLWithPath: out))
