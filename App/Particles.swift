import SwiftUI
import Observation

/// Cleaning made visible: an item breaks into particles that flow into the freed-space counter.
/// The overlay only draws while particles exist; otherwise its timeline is paused.
@MainActor
@Observable
final class ParticleSystem {
    struct Particle {
        var from: CGPoint
        var control: CGPoint
        var born: Date
        var life: Double
        var radius: CGFloat
        var color: Color
    }

    private(set) var particles: [Particle] = []
    /// Bumped when a wave of particles lands, so the counter can pulse.
    private(set) var landed = 0
    @ObservationIgnored var sink: CGRect = .zero
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var reduceMotion = false

    var active: Bool { !particles.isEmpty }

    func burst(from rect: CGRect, color: Color, bytes: Int64) {
        guard sink != .zero else { return }
        if reduceMotion { landed += 1; return }
        let count = min(54, 14 + Int(log2(Double(max(bytes, 1)) / 1_048_576 + 1) * 5))
        let now = Date()
        let target = CGPoint(x: sink.midX, y: sink.midY)
        for i in 0..<count {
            let fx = CGFloat.random(in: rect.minX...max(rect.minX + 1, rect.maxX))
            let fy = CGFloat.random(in: rect.minY...max(rect.minY + 1, rect.maxY))
            let from = CGPoint(x: fx, y: fy)
            // Arc gently up and around, like a droplet carried by a current.
            let mid = CGPoint(x: (from.x + target.x) / 2 + .random(in: -120...120),
                              y: min(from.y, target.y) - .random(in: 40...180))
            particles.append(Particle(from: from, control: mid, born: now.addingTimeInterval(Double(i) * 0.012),
                                      life: .random(in: 0.75...1.25), radius: .random(in: 1.4...3.4), color: color))
        }
        let longest = 1.25 + Double(count) * 0.012
        DispatchQueue.main.asyncAfter(deadline: .now() + longest * 0.8) { self.landed += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05) { self.prune() }
    }

    private func prune() {
        let now = Date()
        particles.removeAll { now.timeIntervalSince($0.born) > $0.life }
    }

    func position(_ p: Particle, at t: Double) -> CGPoint {
        let target = CGPoint(x: sink.midX, y: sink.midY)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let a = 1 - e
        return CGPoint(x: a * a * p.from.x + 2 * a * e * p.control.x + e * e * target.x,
                       y: a * a * p.from.y + 2 * a * e * p.control.y + e * e * target.y)
    }
}

struct ParticleOverlay: View {
    let system: ParticleSystem

    var body: some View {
        TimelineView(.animation(paused: !system.active)) { tl in
            Canvas { ctx, _ in
                let now = tl.date
                ctx.blendMode = .plusLighter
                for p in system.particles {
                    let t = now.timeIntervalSince(p.born) / p.life
                    guard t >= 0, t <= 1 else { continue }
                    let pt = system.position(p, at: t)
                    let r = p.radius * (1 - CGFloat(t) * 0.55)
                    ctx.opacity = t < 0.1 ? t * 10 : 1 - pow(t, 4)
                    let glow = CGRect(x: pt.x - r * 3, y: pt.y - r * 3, width: r * 6, height: r * 6)
                    ctx.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [p.color.opacity(0.5), .clear]),
                                                                          center: pt, startRadius: 0, endRadius: r * 3))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.9)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

extension View {
    /// Registers this view's frame so particles can launch from it.
    func particleSource(_ id: String, in system: ParticleSystem) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { system.frames[id] = $0 }
    }
}
