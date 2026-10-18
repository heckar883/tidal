import SwiftUI

/// Everything Tidal did, in plain words, logged like soundings down a single line.
/// On the right, the holding pool: what has been released but can still come back.
struct ActivityScreen: View {
    @Environment(Store.self) private var store
    @State private var confirmEmpty = false

    private var days: [(Date, [ActivityEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.activity) { cal.startOfDay(for: $0.at) }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            Scroll {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Activity").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Every action, in plain words").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        Spacer()
                        Button { NSWorkspace.shared.open(TidalPaths.log) } label: { Label("Open Log File", systemImage: "doc.text") }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    TideChart(entries: store.activity)
                    if store.activity.isEmpty {
                        Text("Nothing has happened yet. Tidal sleeps until something changes.")
                            .font(.system(size: 13)).foregroundStyle(Theme.mist).padding(.top, 10)
                    }
                    ForEach(days, id: \.0) { day, entries in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).sectionLabel()
                                Spacer()
                                let freed = entries.filter { $0.kind == "clean" }.reduce(0) { $0 + $1.bytes }
                                if freed > 0 { Text("\(ByteText.full(freed)) released").font(Theme.figure(11, .regular)).foregroundStyle(Theme.faint) }
                            }
                            .padding(.bottom, 10)
                            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                                ActivityRow(entry: e, last: i == entries.count - 1)
                            }
                        }
                    }
                }
                .padding(.vertical, 22).padding(.leading, 36).padding(.trailing, 8)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity)

            HoldingPanel(confirmEmpty: $confirmEmpty)
                .frame(width: 380)
                .padding(.trailing, 28).padding(.vertical, 22)
        }
        .confirmationDialog("Empty the holding area?", isPresented: $confirmEmpty) {
            Button("Empty and Reclaim \(ByteText.full(store.heldBytes))", role: .destructive) { store.emptyHolding() }
        } message: {
            Text("Held items are deleted for good. This is the only step in Tidal that can't be undone.")
        }
    }
}

/// Fourteen days of releases as one soft tide line.
struct TideChart: View {
    let entries: [ActivityEntry]
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var series: [(Date, Int64)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: entries.filter { $0.kind == "clean" }) { cal.startOfDay(for: $0.at) }.mapValues { $0.reduce(0) { $0 + $1.bytes } }
        return (0..<14).reversed().map { d in
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            return (day, byDay[day] ?? 0)
        }
    }

    var body: some View {
        let s = series
        let total = s.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Last two weeks").sectionLabel()
                Spacer()
                RollingBytes(bytes: total, size: 15, unitSize: 11, weight: .medium)
                Text("released").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            GeometryReader { g in
                let maxV = Double(max(s.map(\.1).max() ?? 1, 1))
                let pts = s.enumerated().map { i, v in
                    CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(s.count - 1, 1)),
                            y: g.size.height - 4 - (g.size.height - 12) * CGFloat(sqrt(Double(v.1) / maxV)))
                }
                ZStack(alignment: .bottomLeading) {
                    TideCurve(points: pts, closed: true).fill(LinearGradient(colors: [Theme.tide.opacity(0.28), Theme.tide.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    TideCurve(points: pts, closed: false).trim(from: 0, to: drawn || reduceMotion || Motion.frozen ? 1 : 0)
                        .stroke(Theme.tide, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                        if s[i].1 > 0 {
                            Circle().fill(Theme.tide).frame(width: 4, height: 4).position(p)
                                .help("\(s[i].0.formatted(.dateTime.weekday().day())): \(ByteText.full(s[i].1))")
                        }
                    }
                }
                .mask(Rectangle().scaleEffect(x: drawn || reduceMotion || Motion.frozen ? 1 : 0, anchor: .leading))
            }
            .frame(height: 64)
            HStack {
                Text(s.first?.0.formatted(.dateTime.day().month()) ?? "")
                Spacer()
                Text("Today")
            }
            .font(.system(size: 10)).foregroundStyle(Theme.faint)
        }
        .onAppear { withAnimation(.smooth(duration: 1.4).delay(0.15)) { drawn = true } }
    }
}

struct TideCurve: Shape {
    let points: [CGPoint]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        if closed { p.move(to: CGPoint(x: first.x, y: rect.maxY)); p.addLine(to: first) } else { p.move(to: first) }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let mx = (a.x + b.x) / 2
            p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        }
        if closed { p.addLine(to: CGPoint(x: points.last!.x, y: rect.maxY)); p.closeSubpath() }
        return p
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    var last = false

    var tint: Color {
        switch entry.kind {
        case "clean": Theme.tide
        case "restore": Theme.color(.backups)
        case "purge": Theme.glow
        case "uninstall": Theme.amber
        default: Theme.faint
        }
    }

    /// Bigger releases leave a longer mark on the line.
    private var tick: CGFloat {
        guard entry.bytes > 0 else { return 4 }
        return min(22, 6 + CGFloat(log2(Double(entry.bytes) / 1_048_576 + 1)) * 1.6)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(Theme.figure(10.5, .regular)).foregroundStyle(Theme.faint)
                .frame(width: 60, alignment: .leading).padding(.top, 2)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity).padding(.top, last ? 0 : 0)
                Capsule().fill(tint).frame(width: tick, height: 2).offset(x: 0, y: 8)
                Circle().fill(tint).frame(width: 5, height: 5).offset(x: -2, y: 6.5)
            }
            .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: entry.kind == "clean" || entry.kind == "uninstall" ? .semibold : .regular))
                    .foregroundStyle(entry.kind == "refuse" || entry.kind == "scan" || entry.kind == "note" ? Theme.mist : Theme.ink)
                if !entry.detail.isEmpty { Text(entry.detail).font(.system(size: 11.5)).foregroundStyle(Theme.mist).lineLimit(2) }
            }
            .padding(.bottom, 16)
            Spacer(minLength: 12)
            if entry.bytes > 0 {
                Text(ByteText.full(entry.bytes)).font(Theme.figure(12.5, .semibold)).foregroundStyle(entry.kind == "clean" ? Theme.tide : Theme.ink)
            }
        }
    }
}

struct HoldingPanel: View {
    @Environment(Store.self) private var store
    @Binding var confirmEmpty: Bool

    private var batches: [(String, [HeldItem])] {
        Dictionary(grouping: store.held, by: \.batch).map { ($0.key, $0.value) }.sorted { ($0.1.first?.heldAt ?? .distantPast) > ($1.1.first?.heldAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Holding").sectionLabel()
                RollingBytes(bytes: store.heldBytes, size: 44, unitSize: 17)
                Text(store.held.isEmpty ? "Released items wait here before they're gone for good."
                                        : "\(store.held.count) item\(store.held.count == 1 ? "" : "s") · restorable for \(Int(store.holdDays)) days, then they drain away")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.mist)
            }
            if !store.held.isEmpty {
                Button { confirmEmpty = true } label: { Label("Drain Now", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.glass)
                    .help("Reclaim the space immediately")
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Scroll {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(batches, id: \.0) { batch, items in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text((items.first?.heldAt ?? Date()).formatted(.relative(presentation: .named))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                                Spacer()
                                if items.count > 1 {
                                    Button("Undo All") { store.restoreBatch(batch) }.buttonStyle(.plain)
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tide)
                                }
                            }
                            ForEach(items) { h in HeldRow(item: h) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct HeldRow: View {
    let item: HeldItem
    @Environment(Store.self) private var store
    @State private var hover = false

    var body: some View {
        let left = max(0, Int(ceil(store.holdDays - Date().timeIntervalSince(item.heldAt) / 86400)))
        HStack(spacing: 10) {
            CategoryDot(category: item.category, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.owner).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(TidalPaths.pretty(item.original)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hover {
                Button("Restore") { store.restore(item) }.buttonStyle(.glass).controlSize(.small).transition(.opacity)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteText.full(item.bytes)).font(Theme.figure(12)).foregroundStyle(Theme.ink)
                    Text("\(left)d left").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hover ? Theme.wash : .clear, in: .rect(cornerRadius: 12))
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}
