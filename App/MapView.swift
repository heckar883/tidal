import SwiftUI
import AppKit

struct MapScreen: View {
    @Environment(Store.self) private var store
    @AppStorage("map.grouping") private var groupingRaw = Grouping.folders.rawValue
    @AppStorage("map.view") private var styleRaw = MapStyle.pools.rawValue
    @State private var trail: [MapItem] = []
    @State private var hovered: MapItem?
    @State private var zoom: UnitPoint = .center
    @State private var focused: MapItem?
    @State private var highlight: SpaceCategory?
    @State private var pendingDelete: MapItem?
    @State private var systemSheet = false
    @Namespace private var ns

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .folders }
    private var style: MapStyle { MapStyle(rawValue: styleRaw) ?? .pools }

    private var roots: [MapItem] { MapBuilder.build(grouping, nodes: store.nodes, volume: store.volume, db: store.db) }

    /// The current level, re-resolved from fresh data so sizes stay live as things are cleaned.
    private var level: [MapItem] {
        var items = roots
        for t in trail {
            guard let next = items.first(where: { $0.id == t.id }) ?? find(t.id, in: items) else { return t.children }
            items = next.children
        }
        return items
    }

    private func find(_ id: String, in items: [MapItem]) -> MapItem? {
        for i in items {
            if i.id == id { return i }
            if let f = find(id, in: i.children) { return f }
        }
        return nil
    }

    private var current: MapItem? { trail.last }
    private var levelKey: String { grouping.rawValue + "/" + trail.map(\.id).joined(separator: "/") }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Breadcrumb(trail: trail, total: roots.reduce(0) { $0 + $1.bytes }, ns: ns) { depth in
                    zoom = .center
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { trail = Array(trail.prefix(depth)) }
                    focused = nil
                    Haptics.snap()
                }
                Spacer()
                GlassSegments(options: Grouping.allCases, selection: Binding(get: { grouping }, set: { g in
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { groupingRaw = g.rawValue; trail = [] }
                    focused = nil
                    Haptics.snap()
                }), label: { $0.title }, symbol: { $0.symbol })
                GlassSegments(options: MapStyle.allCases, selection: Binding(get: { style }, set: { s in
                    withAnimation(.smooth) { styleRaw = s.rawValue }
                    hovered = nil
                }), label: { _ in nil }, symbol: { $0.symbol }, help: { $0.title })
            }
            .padding(.horizontal, 28)

            ZStack(alignment: .topLeading) {
                if store.nodes.isEmpty {
                    SkeletonField(progress: store.indexProgress)
                } else {
                    switch style {
                    case .pools:
                        PoolMap(items: MapBuilder.visible(level, limit: current?.id.hasPrefix("#more") == true ? .max : 16), highlight: highlight, hovered: $hovered,
                                open: { item, at in open(item, from: at) },
                                dive: { parent, child, at in
                                    zoom = at
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                                        trail.append(parent)
                                        if child.canOpen { trail.append(child) }
                                    }
                                    if !child.canOpen { focused = child }
                                    hovered = nil
                                    Haptics.snap()
                                },
                                select: { focused = $0 }, delete: { pendingDelete = $0 })
                            .id(levelKey)
                            .transition(.asymmetric(insertion: .scale(scale: 0.55, anchor: zoom).combined(with: .opacity),
                                                    removal: .scale(scale: 1.8, anchor: zoom).combined(with: .opacity)))
                            .padding(.horizontal, 28)
                    case .list:
                        MapList(items: level, open: { open($0) }, select: { focused = $0 }).padding(.horizontal, 28)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.6, dampingFraction: 0.88), value: levelKey)

            HStack(alignment: .bottom, spacing: 16) {
                FocusPanel(item: focused ?? hovered ?? current, style: style, levelTotal: level.reduce(0) { $0 + $1.bytes }, onClose: focused != nil ? { focused = nil } : nil,
                           onDelete: { pendingDelete = $0 }, onSystem: { systemSheet = true })
                Spacer()
                Legend(items: roots, grouping: grouping, highlight: $highlight)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
        .padding(.top, 14)
        .confirmationDialog(pendingDelete.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Remove \(Fmt.bytes(item.bytes))", role: .destructive) {
                let origin = item.path.flatMap { store.particles.frames["bubble:" + $0] }
                store.deleteChosen(item, origin: origin)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    if let i = trail.firstIndex(where: { $0.id == item.id }) { trail = Array(trail.prefix(i)) }
                }
                focused = nil; hovered = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.name) moves to Tidal's holding area for \(Int(store.holdDays)) days, then is deleted for good. Undo any time from Activity.")
        }
        .sheet(isPresented: $systemSheet) { SystemCleanSheet() }
        .onAppear(perform: consumeRequest)
        .onChange(of: store.mapRequest) { consumeRequest() }
        .onExitCommand {
            zoom = .center
            if !trail.isEmpty { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { _ = trail.removeLast() } }
        }
        .overlay(alignment: .topTrailing) {
            if store.indexing && !store.nodes.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(store.indexProgress.isEmpty ? "Updating the index…" : "Measuring \(store.indexProgress)")
                }
                .font(.system(size: 11)).foregroundStyle(Theme.mist)
                .padding(.horizontal, 12).padding(.vertical, 7).glassEffect(.regular, in: .capsule)
                .padding(.top, 62).padding(.trailing, 28)
            }
        }
    }

    /// A layer clicked on the Now column opens here, already inside it.
    private func consumeRequest() {
        guard let id = store.mapRequest else { return }
        store.mapRequest = nil
        groupingRaw = Grouping.categories.rawValue
        let cats = MapBuilder.build(.categories, nodes: store.nodes, volume: store.volume, db: store.db)
        if let item = cats.first(where: { $0.id == id }), item.canOpen { trail = [item] } else { trail = [] }
    }

    private func open(_ item: MapItem, from anchor: UnitPoint = .center) {
        guard item.canOpen else { focused = item; return }
        zoom = anchor
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { trail.append(item) }
        hovered = nil
        focused = nil
        Haptics.snap()
    }
}

struct MapList: View {
    let items: [MapItem]
    let open: (MapItem) -> Void
    let select: (MapItem) -> Void
    @State private var sort = [KeyPathComparator(\Row.bytes, order: .reverse)]
    @State private var selection: Row.ID?

    struct Row: Identifiable {
        let id: String
        let item: MapItem
        let name: String
        let bytes: Int64
        let share: Double
        let category: String
        let used: Date
        let status: String
    }

    var body: some View {
        let total = max(1, items.reduce(0) { $0 + Double($1.bytes) })
        let rows = items.map { i in
            Row(id: i.id, item: i, name: i.name, bytes: i.bytes, share: Double(i.bytes) / total, category: i.category.title,
                used: i.used ?? .distantPast,
                status: i.locked ? "Protected" : i.denied ? "Couldn't read" : i.orphan ? "Left behind" : i.canOpen ? "\(i.children.count) inside" : "")
        }.sorted(using: sort)
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { r in
                HStack(spacing: 8) {
                    CategoryDot(category: r.item.category, size: 7)
                    Text(r.name).font(.system(size: 12.5, weight: .medium))
                }
            }
            .width(min: 220, ideal: 320)
            TableColumn("Size", value: \.bytes) { r in Text(Fmt.bytes(r.bytes)).font(Theme.figure(12)).monospacedDigit() }.width(90)
            TableColumn("Share", value: \.share) { r in
                HStack(spacing: 6) {
                    Capsule().fill(Theme.color(r.item.category).opacity(0.7)).frame(width: max(2, 60 * r.share), height: 5)
                    Text("\(r.share * 100, specifier: "%.1f")%").font(Theme.figure(11)).foregroundStyle(Theme.mist)
                }
            }.width(120)
            TableColumn("Category", value: \.category) { r in Text(r.category).foregroundStyle(Theme.mist) }.width(120)
            TableColumn("Last used", value: \.used) { r in Text(r.used == .distantPast ? "—" : Fmt.relative(r.used)).foregroundStyle(Theme.mist) }.width(120)
            TableColumn("", value: \.status) { r in
                HStack(spacing: 4) {
                    if r.item.locked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                    Text(r.status)
                }.foregroundStyle(Theme.faint)
            }
        }
        .scrollContentBackground(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .contextMenu(forSelectionType: Row.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let r = rows.first(where: { $0.id == id }) { r.item.canOpen ? open(r.item) : select(r.item) }
        }
        .onChange(of: selection) { _, id in if let id, let r = rows.first(where: { $0.id == id }) { select(r.item) } }
    }
}

// MARK: - Chrome

struct GlassSegments<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String?
    let symbol: (T) -> String
    var help: ((T) -> String)? = nil
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                ForEach(options) { o in
                    Button { selection = o } label: {
                        HStack(spacing: 5) {
                            Image(systemName: symbol(o)).font(.system(size: 11, weight: .semibold))
                            if let l = label(o) { Text(l).font(.system(size: 12, weight: .semibold)) }
                        }
                        .foregroundStyle(selection == o ? Theme.ink : Theme.mist)
                        .padding(.horizontal, label(o) == nil ? 10 : 12).frame(height: 28)
                        .background {
                            if selection == o { Capsule().fill(Theme.washStrong).matchedGeometryEffect(id: "sel", in: ns) }
                        }
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help(help?(o) ?? label(o) ?? "")
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: selection)
    }
}

/// The path back. Each crumb carries a tiny gauge of its share of the parent: a morphing mini-map.
struct Breadcrumb: View {
    let trail: [MapItem]
    let total: Int64
    let ns: Namespace.ID
    let go: (Int) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                crumb(title: "Disk", share: 1, color: Theme.tide, depth: 0, id: "root")
                ForEach(Array(trail.enumerated()), id: \.element.id) { i, item in
                    Image(systemName: "chevron.compact.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                    let parentBytes = i == 0 ? total : trail[i - 1].bytes
                    crumb(title: item.name, share: Double(item.bytes) / Double(max(parentBytes, 1)),
                          color: Theme.color(item.category), depth: i + 1, id: item.id)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: trail.map(\.id))
    }

    private func crumb(title: String, share: Double, color: Color, depth: Int, id: String) -> some View {
        Button { go(depth) } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 2.2)
                    Circle().trim(from: 0, to: share).stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                Text(title).font(.system(size: 12, weight: depth == trail.count ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(depth == trail.count ? Theme.ink : Theme.mist)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(id, in: ns)
    }
}

struct FocusPanel: View {
    let item: MapItem?
    var style: MapStyle = .pools
    let levelTotal: Int64
    let onClose: (() -> Void)?
    var onDelete: ((MapItem) -> Void)? = nil
    var onSystem: (() -> Void)? = nil
    @Environment(Store.self) private var store

    var body: some View {
        if let item {
            let cleanable = store.cleanable(in: item)
            let cb = cleanable.reduce(0) { $0 + $1.bytes }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        CategoryDot(category: item.category, size: 7)
                        Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        if item.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.faint) }
                    }
                    Text(item.path.map(TidalPaths.pretty) ?? item.note ?? item.category.title)
                        .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle).frame(maxWidth: 280, alignment: .leading)
                }
                CountingBytes(value: Double(item.bytes), size: 22, unitSize: 12, weight: .light, color: Theme.ink)
                if cb > 0 && !item.locked {
                    Button {
                        if let p = item.path {
                            let rect = store.particles.frames["bubble:" + p]
                            for c in cleanable { if let rect { store.particles.frames[c.id] = rect } }
                        }
                        store.clean(cleanable, reason: "Cleaned from the map")
                    } label: {
                        Label("Release \(Fmt.bytes(cb))", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.glassProminent).tint(Theme.tide)
                    .help(cleanable.map { "\($0.tier.title): \($0.owner) — \($0.ruleTitle)" }.joined(separator: "\n"))
                }
                if item.id == "#system", let onSystem {
                    Button(action: onSystem) { Label("Clean system data…", systemImage: "gearshape.2") }
                        .buttonStyle(.glassProminent).tint(Theme.tideDeep)
                }
                if let onDelete, !store.chosenTargets(for: item).isEmpty {
                    Button { onDelete(item) } label: { Label("Remove", systemImage: "trash") }
                        .buttonStyle(.glass).help("Move \(item.name) to the holding area")
                }
                if let p = item.path {
                    Button { store.reveal(p) } label: { Image(systemName: "folder") }.buttonStyle(.glass).help("Show in Finder")
                }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap").foregroundStyle(Theme.faint)
                Text(style == .pools ? "Click a pool to sink in · Esc goes up"
                                     : "Double-click a row to open it. Esc comes back up.").foregroundStyle(Theme.faint)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

struct Legend: View {
    let items: [MapItem]
    let grouping: Grouping
    @Binding var highlight: SpaceCategory?

    var body: some View {
        let totals = Dictionary(grouping: items, by: \.category).mapValues { $0.reduce(0) { $0 + $1.bytes } }
        let cats = SpaceCategory.allCases.filter { (totals[$0] ?? 0) > 0 }
        HStack(spacing: 4) {
            ForEach(cats) { c in
                HStack(spacing: 6) {
                    CategoryDot(category: c, size: 8, bubble: true)
                    Text(c.title).font(.system(size: 11, weight: .medium)).foregroundStyle(highlight == c ? Theme.ink : Theme.mist).lineLimit(1).fixedSize()
                    Text(Fmt.bytes(totals[c] ?? 0)).font(Theme.figure(10.5)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(highlight == c ? Theme.washStrong : .clear, in: .capsule)
                .contentShape(.capsule)
                .onHover { h in withAnimation(.smooth(duration: 0.2)) { highlight = h ? c : nil } }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Only for the very first index build. Afterwards real data streams in.
struct SkeletonField: View {
    let progress: String
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<14, id: \.self) { i in
                    let a = Double(i) * 2.399963
                    let d = sqrt(Double(i) + 0.3) * min(g.size.width, g.size.height) * 0.09
                    let r = max(22, 110 - Double(i) * 7)
                    Circle()
                        .fill(Theme.ink.opacity(shimmer ? 0.07 : 0.03))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.6))
                        .frame(width: r * 2, height: r * 2)
                        .position(x: g.size.width / 2 + cos(a) * d * 1.3, y: g.size.height / 2 + sin(a) * d)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever().delay(Double(i) * 0.08), value: shimmer)
                }
                VStack(spacing: 8) {
                    Text("Building the index for the first time").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(progress.isEmpty ? "Low priority — the map fills in as each folder is measured." : "Measuring \(progress)")
                        .font(.system(size: 12)).foregroundStyle(Theme.mist)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .onAppear { shimmer = true }
    }
}

extension Store {
    /// Items the dry run found inside a map entity.
    func cleanable(in item: MapItem) -> [Candidate] {
        if item.locked { return [] }
        if item.id.hasPrefix("app:") {
            let ids = Set(item.children.compactMap(\.path))
            return candidates.filter { c in ids.contains(c.path) || ids.contains { c.path.hasPrefix($0 + "/") } }
        }
        if item.id.hasPrefix("cat:") { return candidates.filter { c in item.children.contains { ch in ch.path.map { c.path == $0 || c.path.hasPrefix($0 + "/") } ?? false } } }
        guard let p = item.path else { return [] }
        return candidates.filter { $0.path == p || $0.path.hasPrefix(p + "/") }
    }
}
