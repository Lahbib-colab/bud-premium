import Cocoa

// Génère l'iconset de BUD : un squircle dégradé portant le visage du compagnon.
// Usage : budicon <dossier .iconset>

let accent = NSColor(calibratedRed: 0.22, green: 0.85, blue: 0.62, alpha: 1)
let accentDeep = NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.36, alpha: 1)

/// Le corps du compagnon, identique à squirclePath() de BudFace.swift.
/// Dupliqué parce que ce générateur se compile seul.
func budSquircle(size: CGFloat, ratio: CGFloat = 0.30) -> NSBezierPath {
    let h = size / 2, r = size * ratio, k = r / 3
    let p = NSBezierPath()
    p.move(to: NSPoint(x: -h + r, y: -h))
    p.line(to: NSPoint(x: h - r, y: -h))
    p.curve(to: NSPoint(x: h, y: -h + r),
            controlPoint1: NSPoint(x: h - k, y: -h),
            controlPoint2: NSPoint(x: h, y: -h + k))
    p.line(to: NSPoint(x: h, y: h - r))
    p.curve(to: NSPoint(x: h - r, y: h),
            controlPoint1: NSPoint(x: h, y: h - k),
            controlPoint2: NSPoint(x: h - k, y: h))
    p.line(to: NSPoint(x: -h + r, y: h))
    p.curve(to: NSPoint(x: -h, y: h - r),
            controlPoint1: NSPoint(x: -h + k, y: h),
            controlPoint2: NSPoint(x: -h, y: h - k))
    p.line(to: NSPoint(x: -h, y: -h + r))
    p.curve(to: NSPoint(x: -h + r, y: -h),
            controlPoint1: NSPoint(x: -h, y: -h + k),
            controlPoint2: NSPoint(x: -h + k, y: -h))
    p.close()
    return p
}

func squircle(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high

    let u = size / 1024.0
    let pad = 92 * u
    let body = NSRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let corner = body.width * 0.236

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40 * u
    shadow.shadowOffset = NSSize(width: 0, height: -18 * u)
    ctx.saveGraphicsState()
    shadow.set()
    let shape = squircle(body, corner)
    let night = NSGradient(colors: [NSColor(calibratedWhite: 0.17, alpha: 1),
                                    NSColor(calibratedWhite: 0.04, alpha: 1)])
    night?.draw(in: shape, angle: -90)
    ctx.restoreGraphicsState()

    ctx.saveGraphicsState()
    shape.addClip()

    // Halo d'accent
    let haloR = body.width * 0.40
    NSGradient(colors: [accent.withAlphaComponent(0.50), accent.withAlphaComponent(0.0)])?
        .draw(in: NSBezierPath(ovalIn: NSRect(x: body.midX - haloR, y: body.midY - haloR * 0.95,
                                              width: haloR * 2, height: haloR * 2)),
              relativeCenterPosition: NSPoint(x: 0, y: 0))

    // ── Le compagnon : même squircle que dans l'application ──
    ctx.saveGraphicsState()
    ctx.cgContext.translateBy(x: body.midX, y: body.midY - body.height * 0.01)
    let s = body.width * 0.60

    let shell = budSquircle(size: s, ratio: 0.30)
    NSColor.white.setFill()
    shell.fill()

    // Liseré interne, comme le style à plat
    ctx.saveGraphicsState()
    shell.addClip()
    let ring = budSquircle(size: s, ratio: 0.30)
    ring.lineWidth = s * 0.065
    NSColor(calibratedRed: 0.847, green: 0.886, blue: 0.910, alpha: 0.85).setStroke()
    ring.stroke()
    ctx.restoreGraphicsState()

    // Joues
    NSColor(calibratedRed: 1.00, green: 0.710, blue: 0.710, alpha: 1).setFill()
    for side in [CGFloat(-1), CGFloat(1)] {
        NSBezierPath(ovalIn: NSRect(x: side * s * 0.235 - s * 0.072,
                                    y: -s * 0.095 - s * 0.041,
                                    width: s * 0.144, height: s * 0.082)).fill()
    }

    // Yeux
    let ink = NSColor(calibratedRed: 0.137, green: 0.152, blue: 0.200, alpha: 1)
    let eyeR = s * 0.044
    for side in [CGFloat(-1), CGFloat(1)] {
        let cxE = side * s * 0.145, cyE = -s * 0.012
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: cxE - eyeR, y: cyE - eyeR,
                                    width: eyeR * 2, height: eyeR * 2)).fill()
        NSColor.white.withAlphaComponent(0.72).setFill()
        let g = eyeR * 0.26
        NSBezierPath(ovalIn: NSRect(x: cxE - eyeR * 0.30 - g, y: cyE + eyeR * 0.30 - g,
                                    width: g * 2, height: g * 1.5)).fill()
    }

    // Bouche en « O » et langue rose
    let my = -s * 0.125, mw = s * 0.042, mh = s * 0.056
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: -mw, y: my - mh, width: mw * 2, height: mh * 2)).fill()
    ctx.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: -mw * 0.78, y: my - mh * 0.80,
                                width: mw * 1.56, height: mh * 1.60)).addClip()
    NSColor(calibratedRed: 1.00, green: 0.557, blue: 0.620, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: -mw * 0.72, y: my - mh * 0.90,
                                width: mw * 1.44, height: mh * 1.04)).fill()
    ctx.restoreGraphicsState()

    ctx.restoreGraphicsState()

    // Verre sur la moitié haute
    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: body.minX, y: body.midY + body.height * 0.18))
    gloss.curve(to: NSPoint(x: body.maxX, y: body.midY + body.height * 0.32),
                controlPoint1: NSPoint(x: body.midX - body.width * 0.1, y: body.midY + body.height * 0.42),
                controlPoint2: NSPoint(x: body.midX + body.width * 0.1, y: body.midY + body.height * 0.12))
    gloss.line(to: NSPoint(x: body.maxX, y: body.maxY))
    gloss.line(to: NSPoint(x: body.minX, y: body.maxY))
    gloss.close()
    NSColor.white.withAlphaComponent(0.06).setFill()
    gloss.fill()
    ctx.restoreGraphicsState()

    accent.withAlphaComponent(0.28).setStroke()
    shape.lineWidth = 3 * u
    shape.stroke()

    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, _ px: Int, _ url: URL) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    renderIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: url) }
}

let args = CommandLine.arguments
guard args.count > 1 else { exit(1) }
let out = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (px, name) in sizes {
    writePNG(NSImage(), px, out.appendingPathComponent(name))
}
print("iconset écrit : \(out.path)")
