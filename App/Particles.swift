import SwiftUI
import Observation

/// Cleaning made visible: an item breaks into droplets that the tide carries off. On the Now
/// screen they drift into the water column and sink to the drain; elsewhere they flow into the
/// holding counter. The overlay only draws while droplets exist; otherwise its timeline is paused.
@MainActor
@Observable
final class ParticleSystem {
    struct Particle {
        var from: CGPoint
        var control: CGPoint
        var to: CGPoint
        var born: Date
        var life: Double
        var radius: CGFloat
        var color: Color
    }

    private(set) var particles: [Particle] = []
    /// Bumped when a wave of droplets lands, so the target can respond.
    private(set) var landed = 0
    /// The holding counter in the top bar.
    @ObservationIgnored var sink: CGRect = .zero
    /// The drain at the bottom of the water column, when it is on screen.
    @ObservationIgnored var drain: CGRect = .zero
    @ObservationIgnored var useDrain = false
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var reduceMotion = false

    var active: Bool { !particles.isEmpty }

    func burst(from rect: CGRect, color: Color, bytes: Int64) {
        let toDrain = useDrain && drain != .zero
        let target = toDrain ? CGPoint(x: drain.midX, y: drain.maxY - 6) : CGPoint(x: sink.midX, y: sink.midY)
        guard toDrain || sink != .zero else { return }
        if reduceMotion { landed += 1; return }
        let count = min(48, 12 + Int(log2(Double(max(bytes, 1)) / 1_048_576 + 1) * 5))
        let now = Date()
        for i in 0..<count {
            let from = CGPoint(x: CGFloat.random(in: rect.minX...max(rect.minX + 1, rect.maxX)),
                               y: CGFloat.random(in: rect.minY...max(rect.minY + 1, rect.maxY)))
            let control: CGPoint
            let to: CGPoint
            if toDrain {
                // Pulled sideways into the water, then down through the layers.
                let x = drain.minX + CGFloat.random(in: 0.2...0.8) * drain.width
                control = CGPoint(x: x + .random(in: -30...30), y: from.y + .random(in: -20...40))
                to = CGPoint(x: target.x + .random(in: -16...16), y: target.y)
            } else {
                control = CGPoint(x: (from.x + target.x) / 2 + .random(in: -120...120), y: min(from.y, target.y) - .random(in: 40...180))
                to = target
            }
            particles.append(Particle(from: from, control: control, to: to, born: now.addingTimeInterval(Double(i) * 0.014),
                                      life: .random(in: toDrain ? 1.1...1.7 : 0.75...1.25), radius: .random(in: 1.4...3.2), color: color))
        }
        let longest = (toDrain ? 1.7 : 1.25) + Double(count) * 0.014
        DispatchQueue.main.asyncAfter(deadline: .now() + longest * 0.8) { self.landed += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05) { self.prune() }
    }

    private func prune() {
        let now = Date()
        particles.removeAll { now.timeIntervalSince($0.born) > $0.life }
    }

    func position(_ p: Particle, at t: Double) -> CGPoint {
        // Slow start, like the tide taking hold, then a steady pull.
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let a = 1 - e
        return CGPoint(x: a * a * p.from.x + 2 * a * e * p.control.x + e * e * p.to.x,
                       y: a * a * p.from.y + 2 * a * e * p.control.y + e * e * p.to.y)
    }
}

struct ParticleOverlay: View {
    let system: ParticleSystem
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(paused: !system.active)) { tl in
            Canvas { ctx, _ in
                let now = tl.date
                if scheme == .dark { ctx.blendMode = .plusLighter }
                for p in system.particles {
                    let t = now.timeIntervalSince(p.born) / p.life
                    guard t >= 0, t <= 1 else { continue }
                    let pt = system.position(p, at: t)
                    let r = p.radius * (1 - CGFloat(t) * 0.5)
                    ctx.opacity = t < 0.1 ? t * 10 : 1 - pow(t, 3)
                    let glow = CGRect(x: pt.x - r * 3, y: pt.y - r * 3, width: r * 6, height: r * 6)
                    ctx.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [p.color.opacity(0.45), .clear]),
                                                                          center: pt, startRadius: 0, endRadius: r * 3))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                             with: .color(scheme == .dark ? .white.opacity(0.9) : p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

extension View {
    /// Registers this view's frame so droplets can launch from it.
    func particleSource(_ id: String, in system: ParticleSystem) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { system.frames[id] = $0 }
    }
}
