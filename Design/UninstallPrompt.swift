import SwiftUI
import AppKit

// "X is gone. 1.4 GB left behind." Shown by the agent near the menu bar the moment an app
// lands in the Trash. Rings spread from the faded icon, then the leftovers rise as droplets.

struct UninstallPrompt: View {
    enum Action { case review, keep, clean }

    let event: UninstallEvent
    let icon: NSImage?
    var holdDays = 14
    let done: (Action?) -> Void

    @State private var appeared = false
    @State private var shown: Int64 = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int64 { event.leftovers.reduce(0) { $0 + $1.bytes } + event.autoCleaned }

    /// Leftovers grouped by what they are, biggest first; at most four droplets plus "n more".
    private var groups: [(String, Int64)] {
        let g = Dictionary(grouping: event.leftovers) { $0.ruleTitle }.map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }
        return g.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RippleRings(color: Theme.amber, rings: 3, duration: 2.8).frame(width: 96, height: 96)
                    Group {
                        if let icon {
                            Image.icon(icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "app.dashed").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Theme.mist)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .saturation(appeared ? 0 : 1)
                    .opacity(appeared ? 0.45 : 1)
                    .scaleEffect(appeared ? 0.88 : 1)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.name) is gone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        CountingBytes(value: Double(shown), size: 24, unitSize: 13, weight: .light, color: Theme.ink)
                        Text("left behind").font(.system(size: 12.5)).foregroundStyle(Theme.mist)
                    }
                    if event.autoCleaned > 0 {
                        Text("\(ByteText.full(event.autoCleaned)) of caches already drained to holding")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 0)
                Button { done(nil) } label: { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    .frame(width: 22, height: 22).contentShape(.circle)
                    .help("Decide later")
            }

            if !event.leftovers.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(Array(groups.prefix(4).enumerated()), id: \.offset) { i, g in
                        DropletChip(title: g.0, bytes: g.1, index: i)
                    }
                    if groups.count > 4 {
                        DropletChip(title: "\(groups.count - 4) more", bytes: groups.dropFirst(4).reduce(0) { $0 + $1.1 }, color: Theme.faint, index: 4)
                    }
                }
            }

            HStack(spacing: 8) {
                if !event.leftovers.isEmpty {
                    Button("Let it drain") { done(.clean) }.buttonStyle(.glassProminent).tint(Theme.tide)
                    Button("Review") { done(.review) }.buttonStyle(.glass)
                    Button("Keep") { done(.keep) }.buttonStyle(.borderless).foregroundStyle(Theme.mist).padding(.leading, 4)
                } else {
                    Button("Show") { done(.review) }.buttonStyle(.glass)
                }
                Spacer()
                Text("Undoable for \(holdDays) days").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(width: 400)
        .onAppear {
            if Motion.frozen { appeared = true; shown = total; return }
            withAnimation(.smooth(duration: 1.2).delay(0.2)) { appeared = true }
            withAnimation(.smooth(duration: reduceMotion ? 0.01 : 1.4).delay(0.3)) { shown = total }
        }
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0 && x + d.width > w { y += line + spacing; x = 0; line = 0 }
            x += d.width + spacing
            line = max(line, d.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, w), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + d.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(d))
            x += d.width + spacing
            line = max(line, d.height)
        }
    }
}
