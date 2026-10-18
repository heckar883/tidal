import SwiftUI

// The water pieces every surface shares: the sounding column, a still pool, ripples.
// Every animation here is driven by a TimelineView that pauses when `live` is false,
// so a hidden window or a closed popover draws nothing.

// MARK: - Sounding column

/// One settled layer of used space.
struct Stratum: Identifiable, Hashable {
    let id: String
    let name: String
    let bytes: Int64
    let category: SpaceCategory
    var dashed = false
    /// The holding area: drawn in the accent, resting at the drain.
    var holding = false
}

/// The order layers settle in: what macOS can reclaim floats on top, the system rests on the bed.
enum StratumOrder {
    static let rank: [SpaceCategory] = [.purgeable, .developer, .apps, .libraries, .personal, .backups, .other, .system]
    static func sorted(_ s: [Stratum]) -> [Stratum] {
        func r(_ x: Stratum) -> Int { x.holding ? 99 : rank.firstIndex(of: x.category) ?? 9 }
        return s.sorted { (r($0), -$0.bytes) < (r($1), -$1.bytes) }
    }
}

struct ColumnLayout {
    struct Band { let stratum: Stratum; let top: CGFloat; let bottom: CGFloat }
    let floor: CGFloat
    let bands: [Band]
    let threshold: CGFloat?

    /// `freeShare` is the share of the disk that is clear water, measured from the surface.
    init(size: CGSize, freeShare: Double, strata: [Stratum], thresholdShare: Double?) {
        let h = size.height
        floor = h * CGFloat(min(max(freeShare, 0), 1))
        let used = max(1, h - floor)
        let sum = max(1, strata.reduce(0) { $0 + Double($1.bytes) })
        var y = floor
        var out: [Band] = []
        // Holding is small next to the disk but is what the person acts on, so it never vanishes.
        let holdMin: CGFloat = strata.contains { $0.holding } ? min(10, used * 0.03) : 0
        for s in strata {
            var bh = (used - holdMin) * CGFloat(Double(s.bytes) / sum)
            if s.holding { bh = max(bh, holdMin) }
            out.append(Band(stratum: s, top: y, bottom: y + bh))
            y += bh
        }
        bands = out
        threshold = thresholdShare.map { h * CGFloat(min(max($0, 0), 1)) }
    }

    func band(at y: CGFloat) -> Band? { bands.first { y >= $0.top && y < $0.bottom } }
}

struct SoundingColumn: View {
    var total: Int64
    var free: Int64
    var strata: [Stratum]
    var threshold: Int64? = nil
    var scanning = false
    var live = true
    var compact = false
    var highlighted: String? = nil
    var cornerRadius: CGFloat = 26

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level = Level()

    /// The floor eases toward its real depth each frame, so freed space visibly settles.
    final class Level {
        var value: Double?
        func advance(to target: Double, animated: Bool) -> Double {
            guard let v = value, animated else { value = target; return target }
            let next = v + (target - v) * 0.045
            value = abs(target - next) < 0.0004 ? target : next
            return value!
        }
        var settled: Bool = false
    }

    private var freeShare: Double { total > 0 ? Double(free) / Double(total) : 0 }
    private var ordered: [Stratum] {
        strata.isEmpty ? [Stratum(id: "used", name: "Used", bytes: max(1, total - free), category: .other)] : StratumOrder.sorted(strata)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: compact ? 1 / 24 : 1 / 30, paused: !live || reduceMotion)) { tl in
            Canvas { ctx, size in
                draw(&ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.ink.opacity(scheme == .dark ? 0.16 : 0.10), Theme.ink.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .accessibilityElement()
        .accessibilityLabel("Disk: \(ByteText.full(free)) free of \(ByteText.full(total))")
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let animated = live && !reduceMotion
        let share = level.advance(to: freeShare, animated: animated)
        let thr = threshold.map { total > 0 ? Double($0) / Double(total) : 0 }
        let L = ColumnLayout(size: size, freeShare: share, strata: ordered, thresholdShare: thr)
        let dark = scheme == .dark
        let w = size.width
        let amp: CGFloat = compact ? 0.8 : 1.6
        let drift = animated ? t : 0

        func edge(_ y: CGFloat, seed: Double, a: CGFloat) -> [CGPoint] {
            stride(from: CGFloat(-4), through: w + 4, by: compact ? 6 : 5).map { x in
                let r = Double(x / max(w, 1))
                return CGPoint(x: x, y: y + CGFloat(sin(r * 6.3 + seed + drift * 0.22) * Double(a) + sin(r * 13.1 + seed * 2 - drift * 0.31) * Double(a) * 0.45))
            }
        }

        // Clear water: from the surface to the floor.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Theme.waterTop, Theme.waterMid, Theme.waterLow]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        if !compact {
            // Caustic light, faint and slow, only in the clear water.
            ctx.drawLayer { l in
                l.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: max(L.floor, 0))))
                l.blendMode = dark ? .plusLighter : .normal
                for i in 0..<3 {
                    var p = Path()
                    let pts = edge(18 + CGFloat(i) * 22, seed: Double(i) * 1.9, a: 3.5)
                    p.addLines(pts)
                    l.stroke(p, with: .color((dark ? Color.white : Color(hex: 0xFFFFFF)).opacity(dark ? 0.035 : 0.5)), lineWidth: 1)
                }
            }
        }

        // Settled layers.
        for (i, b) in L.bands.enumerated() {
            let c = b.stratum.holding ? Theme.tide : Theme.color(b.stratum.category)
            let hi = highlighted == nil || highlighted == b.stratum.id
            var p = Path()
            let topEdge = edge(b.top, seed: Double(i) * 2.7 + 0.4, a: i == 0 ? amp * 1.2 : amp)
            p.move(to: CGPoint(x: -4, y: size.height + 4))
            for pt in topEdge { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: w + 4, y: size.height + 4))
            p.closeSubpath()
            let base = dark ? 0.20 : 0.30
            ctx.fill(p, with: .linearGradient(Gradient(colors: [c.opacity((base + 0.12) * (hi ? 1 : 0.45)), c.opacity(base * (hi ? 1 : 0.45))]),
                                              startPoint: CGPoint(x: 0, y: b.top), endPoint: CGPoint(x: 0, y: b.bottom)))
            // Bed beneath each layer darkens with depth.
            let depth = Double(b.top / max(size.height, 1))
            ctx.fill(p, with: .color(Theme.bed.opacity(dark ? depth * 0.55 : depth * 0.22)))
            var line = Path(); line.addLines(topEdge)
            if b.stratum.holding && b.bottom - b.top > 3 {
                // Held items: fine diagonal hatching, waiting at the drain.
                ctx.drawLayer { l in
                    l.clip(to: p)
                    var x = -size.height
                    while x < w {
                        var d = Path(); d.move(to: CGPoint(x: x, y: size.height)); d.addLine(to: CGPoint(x: x + size.height * 0.6, y: b.top - 4))
                        l.stroke(d, with: .color(c.opacity(dark ? 0.22 : 0.3)), lineWidth: 0.6)
                        x += 7
                    }
                }
            }
            if b.stratum.dashed {
                ctx.stroke(line, with: .color(c.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
            } else {
                ctx.stroke(line, with: .color(c.opacity(dark ? 0.45 : 0.6) .opacity(hi ? 1 : 0.4)), lineWidth: 0.7)
            }
            // Suspended sediment: a few motes per layer, drifting very slowly.
            if !compact && b.bottom - b.top > 14 {
                let n = min(28, Int((b.bottom - b.top) * w / 2400))
                for k in 0..<n {
                    let s = Double(k) * 12.9898 + Double(i) * 78.233
                    let fx = (sin(s) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let fy = (sin(s * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1)
                    let x = (abs(fx) * Double(w) + drift * (2 + abs(fy) * 3)).truncatingRemainder(dividingBy: Double(w))
                    let y = Double(b.top) + 5 + abs(fy) * Double(b.bottom - b.top - 10)
                    let r = 0.7 + abs(fx) * 1.1
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(c.opacity(dark ? 0.35 : 0.5)))
                }
            }
        }

        // The floor: where clear water meets what has settled.
        if L.floor > 1 {
            var f = Path(); f.addLines(edge(L.floor, seed: 0.4, a: amp * 1.2))
            ctx.stroke(f, with: .color(Theme.tide.opacity(0.9)), lineWidth: compact ? 1 : 1.2)
            if dark {
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 6))
                    l.stroke(f, with: .color(Theme.tide.opacity(0.45)), lineWidth: 3)
                }
            }
        }

        // Surface.
        var s = Path(); s.addLines(edge(0.8, seed: 3.1, a: compact ? 0.4 : 0.8))
        ctx.stroke(s, with: .color(Theme.ink.opacity(dark ? 0.22 : 0.18)), lineWidth: 1)

        // Where Autopilot steps in.
        if let ty = L.threshold, !compact, ty > 4, ty < size.height - 4 {
            var d = Path(); d.move(to: CGPoint(x: w - 34, y: ty)); d.addLine(to: CGPoint(x: w - 8, y: ty))
            ctx.stroke(d, with: .color(Theme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        // Sounding: a slow sweep of light while Tidal measures.
        if scanning && animated {
            let period = 2.8
            let p = (t.truncatingRemainder(dividingBy: period)) / period
            let y = CGFloat(p) * (size.height + 60) - 30
            let band = CGRect(x: 0, y: y - 30, width: w, height: 60)
            ctx.fill(Path(band), with: .linearGradient(Gradient(colors: [.clear, Theme.glow.opacity(dark ? 0.16 : 0.22), .clear]),
                                                       startPoint: CGPoint(x: 0, y: band.minY), endPoint: CGPoint(x: 0, y: band.maxY)))
            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(line, with: .color(Theme.glow.opacity(0.5)), lineWidth: 0.6)
        }

        // The drain, at the bed.
        if !compact {
            let dc = CGPoint(x: w / 2, y: size.height - 3)
            ctx.fill(Path(ellipseIn: CGRect(x: dc.x - 22, y: dc.y - 3, width: 44, height: 6)),
                     with: .radialGradient(Gradient(colors: [Theme.abyss.opacity(dark ? 0.9 : 0.4), .clear]), center: dc, startRadius: 0, endRadius: 22))
        }
    }
}

// MARK: - Still pool (all clear, error)

struct StillPool: View {
    enum Mood { case clear, clouded, filling }
    var mood: Mood = .clear
    var live = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { mood == .clouded ? Theme.amber : Theme.glow }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || reduceMotion)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let dark = scheme == .dark
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                let c = CGPoint(x: rect.midX, y: rect.midY)
                let pool = Path(ellipseIn: rect)
                ctx.fill(pool, with: .radialGradient(Gradient(colors: [tint.opacity(dark ? 0.20 : 0.26), Theme.waterMid.opacity(dark ? 0.75 : 0.9), Theme.waterLow.opacity(dark ? 0.5 : 0.8)]),
                                                     center: CGPoint(x: c.x, y: c.y - rect.height * 0.12), startRadius: 0, endRadius: rect.width * 0.55))
                ctx.stroke(pool, with: .linearGradient(Gradient(colors: [Theme.ink.opacity(dark ? 0.18 : 0.14), Theme.ink.opacity(0.02)]),
                                                       startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)), lineWidth: 0.8)
                ctx.clip(to: pool)
                if mood == .clouded {
                    // Murk drifting through the water.
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 18))
                        for i in 0..<5 {
                            let a = t * 0.12 + Double(i) * 1.26
                            let p = CGPoint(x: c.x + cos(a) * rect.width * 0.22, y: c.y + sin(a * 1.3) * rect.height * 0.22)
                            let r = rect.height * (0.18 + 0.04 * Double(i % 3))
                            l.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.6, width: r * 2, height: r * 1.2)), with: .color(Theme.amber.opacity(dark ? 0.22 : 0.18)))
                        }
                    }
                }
                if mood == .filling {
                    let p = (t.truncatingRemainder(dividingBy: 3.2)) / 3.2
                    let y = rect.minY + CGFloat(p) * rect.height
                    ctx.fill(Path(CGRect(x: rect.minX, y: y - 18, width: rect.width, height: 36)),
                             with: .linearGradient(Gradient(colors: [.clear, Theme.glow.opacity(0.22), .clear]), startPoint: CGPoint(x: 0, y: y - 18), endPoint: CGPoint(x: 0, y: y + 18)))
                }
                // One slow ripple at a time.
                let period = mood == .clear ? 6.0 : 4.5
                for k in 0..<2 {
                    let ph = ((t + Double(k) * period / 2).truncatingRemainder(dividingBy: period)) / period
                    let rx = rect.width * 0.08 + rect.width * 0.5 * ph
                    let ry = rx * rect.height / rect.width
                    let ring = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                    ctx.stroke(ring, with: .color(tint.opacity((1 - ph) * (dark ? 0.45 : 0.55))), lineWidth: 1)
                }
                // Light on the surface.
                let hl = CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.08, width: rect.width * 0.45, height: rect.height * 0.16)
                ctx.fill(Path(ellipseIn: hl), with: .linearGradient(Gradient(colors: [Color.white.opacity(dark ? 0.08 : 0.5), .clear]),
                                                                    startPoint: CGPoint(x: 0, y: hl.minY), endPoint: CGPoint(x: 0, y: hl.maxY)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Ripple rings (uninstall)

/// A few rings spread out from an app's icon, then the water stills.
struct RippleRings: View {
    var color: Color = Theme.amber
    var rings = 3
    var duration = 2.6
    @State private var start = Date()
    @State private var done = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: done || reduceMotion)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSince(start)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                for i in 0..<rings {
                    let p = (t - Double(i) * 0.38) / (duration - 0.8)
                    guard p > 0, p < 1 else { continue }
                    let e = 1 - pow(1 - p, 2.4)
                    let r = maxR * (0.3 + 0.7 * e)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(color.opacity((1 - p) * 0.6)), lineWidth: 1.2 - p * 0.6)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { done = true }
        }
    }
}

// MARK: - Droplet chips (leftovers rising)

/// Leftovers rise out of the water one by one, like small droplets.
struct DropletChip: View {
    let title: String
    let bytes: Int64
    var color: Color = Theme.amber
    var index = 0
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(ByteText.full(bytes)).font(Theme.figure(10.5)).foregroundStyle(Theme.mist)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.wash, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .offset(y: risen ? 0 : 14)
        .opacity(risen ? 1 : 0)
        .blur(radius: risen ? 0 : 3)
        .onAppear {
            if reduceMotion || Motion.frozen { risen = true; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.35 + Double(index) * 0.09)) { risen = true }
        }
    }
}
