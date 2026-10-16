import AppKit
import SwiftUI

/// A calm, non-blocking card near the menu bar: "X is gone. 1.4 GB left behind. Review?"
final class UninstallPanel {
    enum Action { case review, keep, clean }

    private let panel: NSPanel
    private var dismissTimer: Timer?

    init(event: UninstallEvent, icon: NSImage?, onAction: @escaping (Action) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 168),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        var closeRef: (() -> Void)?
        let view = UninstallCardView(event: event, icon: icon) { action in
            closeRef?()
            if let action { onAction(action) }
        }
        panel.contentView = NSHostingView(rootView: view)
        closeRef = { [weak self] in self?.close() }
    }

    func present(near statusFrame: NSRect?) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let w: CGFloat = 380, h: CGFloat = 168
        let x = min(max((statusFrame?.midX ?? vf.maxX) - w + 40, vf.minX + 12), vf.maxX - w - 12)
        panel.setFrame(NSRect(x: x, y: vf.maxY - h - 8, width: w, height: h), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
        // Leave quietly if ignored; the menu bar icon keeps the "needs a look" state.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        dismissTimer?.invalidate()
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

private struct UninstallCardView: View {
    let event: UninstallEvent
    let icon: NSImage?
    let done: (UninstallPanel.Action?) -> Void

    @State private var shown: Int64 = 0
    @State private var appeared = false
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int64 { event.leftovers.reduce(0) { $0 + $1.bytes } + event.autoCleaned }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                            .opacity(appeared ? 0.35 : 1)
                            .scaleEffect(appeared ? 0.86 : 1)
                            .saturation(appeared ? 0 : 1)
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 30, weight: .light)).frame(width: 44, height: 44)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.name) is gone").font(.system(size: 15, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.bytes(shown))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(shown)))
                        Text("left behind").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if event.autoCleaned > 0 {
                        Text("\(Fmt.bytes(event.autoCleaned)) of caches already moved to holding")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { done(nil) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).glassEffect(.regular.interactive(), in: .circle)
            }
            .overlay(alignment: .leading) { particles.allowsHitTesting(false) }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !event.leftovers.isEmpty {
                        Button("Review") { done(.review) }.buttonStyle(.glassProminent).tint(Color(red: 0.25, green: 0.78, blue: 0.85))
                        Button("Clean now") { done(.clean) }.buttonStyle(.glass)
                        Button("Keep") { done(.keep) }.buttonStyle(.glass)
                    } else {
                        Button("Show") { done(.review) }.buttonStyle(.glass)
                    }
                    Spacer()
                    Text("Undoable for 14 days").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(4)
        .offset(y: appeared ? 0 : -24)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            start = Date()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { appeared = true }
            // Count up in steps as the leftovers "flow in".
            let steps = reduceMotion ? 1 : 18
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.06) {
                    withAnimation(.snappy) { shown = total * Int64(i) / Int64(steps) }
                }
            }
        }
    }

    /// Particles drift from the app icon toward the size figure.
    @ViewBuilder private var particles: some View {
        if !reduceMotion {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSince(start) - 0.2
                    guard t > 0, t < 1.8 else { return }
                    for i in 0..<26 {
                        let seed = Double(i) * 12.9898
                        let delay = (sin(seed) * 0.5 + 0.5) * 0.7
                        let p = min(1, max(0, (t - delay) / 0.9))
                        guard p > 0, p < 1 else { continue }
                        let ease = 1 - pow(1 - p, 3)
                        let from = CGPoint(x: 22 + cos(seed) * 10, y: size.height / 2 + sin(seed * 1.7) * 12)
                        let to = CGPoint(x: 96, y: size.height / 2 + 2)
                        let lift = sin(p * .pi) * (18 + 10 * sin(seed))
                        let pt = CGPoint(x: from.x + (to.x - from.x) * ease, y: from.y + (to.y - from.y) * ease - lift)
                        let r = 2.2 * (1 - p * 0.6)
                        ctx.opacity = 1 - p * 0.7
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Color(red: 0.45, green: 0.9, blue: 0.95)))
                    }
                }
            }
            .frame(width: 140)
        }
    }
}
