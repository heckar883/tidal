import SwiftUI

struct ActivityScreen: View {
    @Environment(Store.self) private var store
    @State private var confirmEmpty = false

    private var days: [(Date, [ActivityEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.activity) { cal.startOfDay(for: $0.at) }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            // Timeline
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Activity").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Every action, in plain words").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        Spacer()
                        Button { NSWorkspace.shared.open(TidalPaths.log) } label: { Label("Open Log File", systemImage: "doc.text") }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    if store.activity.isEmpty {
                        Text("Nothing has happened yet.").font(.system(size: 13)).foregroundStyle(Theme.mist).padding(.top, 30)
                    }
                    ForEach(days, id: \.0) { day, entries in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).sectionLabel().padding(.bottom, 8)
                            ForEach(entries) { e in ActivityRow(entry: e) }
                        }
                    }
                }
                .padding(.vertical, 22).padding(.leading, 36).padding(.trailing, 8)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity)

            HoldingPanel(confirmEmpty: $confirmEmpty)
                .frame(width: 400)
                .padding(.trailing, 28).padding(.vertical, 22)
        }
        .confirmationDialog("Empty the holding area?", isPresented: $confirmEmpty) {
            Button("Empty and Reclaim \(Fmt.bytes(store.heldBytes))", role: .destructive) { store.emptyHolding() }
        } message: {
            Text("Held items are deleted for good. This is the only step in Tidal that can't be undone.")
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    @Environment(Store.self) private var store

    var symbol: (String, Color) {
        switch entry.kind {
        case "clean": ("drop.fill", Theme.tide)
        case "restore": ("arrow.uturn.backward", Theme.color(.backups))
        case "purge": ("sparkles", Theme.color(.purgeable))
        case "uninstall": ("app.dashed", Theme.tierColor(.review))
        case "refuse": ("hand.raised", Theme.faint)
        case "scan": ("magnifyingglass", Theme.faint)
        default: ("circle.fill", Theme.faint)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: symbol.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(symbol.1)
                    .frame(width: 26, height: 26).background(symbol.1.opacity(0.12), in: .circle)
                Rectangle().fill(.white.opacity(0.06)).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: entry.kind == "clean" || entry.kind == "uninstall" ? .semibold : .regular))
                    .foregroundStyle(entry.kind == "refuse" || entry.kind == "scan" ? Theme.mist : Theme.ink)
                if !entry.detail.isEmpty { Text(entry.detail).font(.system(size: 11.5)).foregroundStyle(Theme.mist).lineLimit(2) }
            }
            .padding(.bottom, 14)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if entry.bytes > 0 { Text(Fmt.bytes(entry.bytes)).font(Theme.figure(13, .semibold)).foregroundStyle(entry.kind == "clean" ? Theme.tide : Theme.ink) }
                Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
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
                Text("Holding area").sectionLabel()
                RollingBytes(bytes: store.heldBytes, size: 46, unitSize: 18)
                Text(store.held.isEmpty ? "Cleaned items wait here before they're gone for good."
                                        : "\(store.held.count) item\(store.held.count == 1 ? "" : "s") · restorable for \(Int(store.holdDays)) days, then purged automatically")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.mist)
            }
            if !store.held.isEmpty {
                Button { confirmEmpty = true } label: { Label("Empty Now", systemImage: "sparkles") }
                    .buttonStyle(.glass)
                    .help("Reclaim the space immediately")
            }
            Divider().overlay(.white.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(batches, id: \.0) { batch, items in
                        VStack(alignment: .leading, spacing: 6) {
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
                    Text(Fmt.bytes(item.bytes)).font(Theme.figure(12)).foregroundStyle(Theme.ink)
                    Text("\(left)d left").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(hover ? 0.05 : 0.0), in: .rect(cornerRadius: 12))
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}
