import AppKit
import CoreGraphics

// Renders Tidal's icon layers (for the Liquid Glass .icon) and a flattened fallback .icns source.
// usage: MakeIcon <outdir>

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ name: String, size: Int = 1024, _ draw: (CGContext, CGFloat) -> Void) {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1) // top-left origin
    draw(ctx, CGFloat(size))
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r, g, b, a])!
}

/// A droplet: round bottom, tapering to a soft point at the top.
func dropPath(_ s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let cx = s / 2, cy = s * 0.585, r = s * 0.255
    p.move(to: CGPoint(x: cx, y: s * 0.165))
    p.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * 0.25, y: s * 0.30), control2: CGPoint(x: cx + r, y: cy - r * 0.75))
    p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
    p.addCurve(to: CGPoint(x: cx, y: s * 0.165), control1: CGPoint(x: cx - r, y: cy - r * 0.75), control2: CGPoint(x: cx - r * 0.25, y: s * 0.30))
    p.closeSubpath()
    return p
}

func wavePath(_ s: CGFloat, y: CGFloat, amp: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: s))
    p.addLine(to: CGPoint(x: 0, y: y))
    var x: CGFloat = 0
    while x <= s {
        p.addLine(to: CGPoint(x: x, y: y + sin(x / s * .pi * 2.2 + 0.6) * amp))
        x += 4
    }
    p.addLine(to: CGPoint(x: s, y: s))
    p.closeSubpath()
    return p
}

// Layer 1: the droplet body.
render("drop.png") { ctx, s in
    ctx.addPath(dropPath(s)); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [p3(0.80, 0.98, 1.0), p3(0.42, 0.86, 0.95), p3(0.20, 0.58, 0.95)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: s * 0.35, y: s * 0.16), end: CGPoint(x: s * 0.62, y: s * 0.84), options: [])
}

// Layer 2: the tide line inside the drop.
render("tide.png") { ctx, s in
    ctx.addPath(dropPath(s)); ctx.clip()
    ctx.addPath(wavePath(s, y: s * 0.60, amp: s * 0.022)); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [p3(0.10, 0.36, 0.86), p3(0.05, 0.16, 0.52)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s * 0.58), end: CGPoint(x: 0, y: s * 0.86), options: [])
}

// Flattened fallback: squircle, background, drop, tide (for .icns and older surfaces).
render("flat.png") { ctx, s in
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let sq = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: p3(0, 0, 0, 0.45))
    ctx.addPath(sq); ctx.setFillColor(p3(0.03, 0.06, 0.12)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(sq); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [p3(0.07, 0.16, 0.28), p3(0.02, 0.04, 0.09)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [p3(0.36, 0.86, 0.92, 0.35), p3(0.36, 0.86, 0.92, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s * 0.5), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s * 0.5), endRadius: s * 0.42, options: [])
    // scale artwork into the squircle
    ctx.translateBy(x: s / 2, y: s / 2); ctx.scaleBy(x: 0.86, y: 0.86); ctx.translateBy(x: -s / 2, y: -s / 2)
    ctx.saveGState()
    ctx.addPath(dropPath(s)); ctx.clip()
    let dg = CGGradient(colorsSpace: nil, colors: [p3(0.80, 0.98, 1.0), p3(0.42, 0.86, 0.95), p3(0.20, 0.58, 0.95)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(dg, start: CGPoint(x: s * 0.35, y: s * 0.16), end: CGPoint(x: s * 0.62, y: s * 0.84), options: [])
    ctx.addPath(wavePath(s, y: s * 0.60, amp: s * 0.022)); ctx.clip()
    let tg = CGGradient(colorsSpace: nil, colors: [p3(0.10, 0.36, 0.86), p3(0.05, 0.16, 0.52)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(tg, start: CGPoint(x: 0, y: s * 0.58), end: CGPoint(x: 0, y: s * 0.86), options: [])
    ctx.restoreGState()
    // specular highlight
    ctx.addPath(dropPath(s)); ctx.clip()
    let hl = CGGradient(colorsSpace: nil, colors: [p3(1, 1, 1, 0.55), p3(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: s * 0.42, y: s * 0.40), startRadius: 0, endCenter: CGPoint(x: s * 0.42, y: s * 0.40), endRadius: s * 0.13, options: [])
    ctx.restoreGState()
}
print("ok")
