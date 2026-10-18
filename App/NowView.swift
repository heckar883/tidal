import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The dashboard. On the left the disk as a column of still water; on the right, in plain
/// words, what has settled since the last look. Nothing here is one big button: each item is
/// released on its own, by selection, or by dragging it into the water.
struct NowView: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            NowColumn()
                .frame(width: 300)
                .padding(.bottom, 26)
            NowFeed()
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 30).padding(.trailing, 20).padding(.top, 18)
    }
}

// MARK: - The column

struct NowColumn: View {
    @Environment(Store.self) private var store
    @State private var hovered: Stratum?
    @State private var hoverY: CGFloat = 0
    @State private var targeted = false

    private var volume: VolumeInfo { store.volume }
    private var threshold: Int64 { Int64(store.db.double(SettingKey.freeThresholdGB, default: 20) * 1e9) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sounding").sectionLabel()
                Spacer()
                Text(volume.name).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            GeometryReader { geo in
                let L = ColumnLayout(size: geo.size, freeShare: share, strata: StratumOrder.sorted(store.strata),
                                     thresholdShare: volume.total > 0 ? Double(threshold) / Double(volume.total) : nil)
                ZStack(alignment: .topLeading) {
                    SoundingColumn(total: volume.total, free: volume.available, strata: store.strata, threshold: threshold,
                                   scanning: store.scanning, live: store.windowVisible, highlighted: hovered?.id)
                    labels(L, size: geo.size)
                    floorTag(L, size: geo.size)
                    if let h = hovered { hoverCard(h).offset(x: 12, y: min(max(hoverY - 30, 8), geo.size.height - 70)) }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Theme.tide.opacity(targeted ? 0.9 : 0), lineWidth: 1.5)
                        .shadow(color: Theme.tide.opacity(targeted ? 0.5 : 0), radius: 12)
                }
                .overlay(alignment: .bottom) {
                    if targeted {
                        Text("Let it sink").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
                            .padding(.bottom, 20).transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let b = L.band(at: p.y)?.stratum
                        hoverY = p.y
                        if b?.id != hovered?.id { withAnimation(.smooth(duration: 0.2)) { hovered = b } }
                    case .ended: withAnimation(.smooth(duration: 0.2)) { hovered = nil }
                    }
                }
                .onTapGesture {
                    guard let h = hovered, !h.holding else { if hovered?.holding == true { store.place = .activity }; return }
                    store.mapRequest = h.id
                    withAnimation(.smooth) { store.place = .map }
                }
                .live { $0.dropDestination(for: String.self) { paths, _ in
                    let items = store.candidates.filter { paths.contains($0.path) }
                    store.clean(items, reason: "Dropped into the water")
                    return !items.isEmpty
                } isTargeted: { t in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { targeted = t }
                    if t { Haptics.snap() }
                } }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { r in
                    store.particles.drain = CGRect(x: r.minX + r.width * 0.3, y: r.maxY - 40, width: r.width * 0.4, height: 40)
                }
            }
        }
        .onAppear { store.particles.useDrain = true }
        .onDisappear { store.particles.useDrain = false }
    }

    private var share: Double { volume.total > 0 ? Double(volume.available) / Double(volume.total) : 0 }

    /// Each layer names itself when there is room.
    private func labels(_ L: ColumnLayout, size: CGSize) -> some View {
        ForEach(L.bands, id: \.stratum.id) { b in
            if b.bottom - b.top >= 30 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.stratum.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.85))
                    Text(ByteText.full(b.stratum.bytes)).font(Theme.figure(10.5, .regular)).foregroundStyle(Theme.mist)
                }
                .padding(.leading, 14)
                .offset(y: b.top + 9)
                .opacity(hovered == nil || hovered?.id == b.stratum.id ? 1 : 0.35)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 1.2), value: L.bands.map(\.top))
    }

    private func floorTag(_ L: ColumnLayout, size: CGSize) -> some View {
        let above = L.floor > 30
        return HStack(spacing: 5) {
            Image(systemName: above ? "arrow.up" : "arrow.down").font(.system(size: 8.5, weight: .bold))
            Text("\(ByteText.full(volume.available)) clear").font(Theme.figure(10.5, .semibold))
        }
        .foregroundStyle(Theme.tide)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.abyss.opacity(0.55), in: .capsule)
        .frame(width: size.width - 12, alignment: .trailing)
        .offset(y: above ? L.floor - 24 : L.floor + 6)
        .animation(.smooth(duration: 1.4), value: L.floor)
        .allowsHitTesting(false)
    }

    private func hoverCard(_ s: Stratum) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(s.holding ? Theme.tide : Theme.color(s.category)).frame(width: 7, height: 7)
                Text(s.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Text("\(ByteText.full(s.bytes)) · \(Int((Double(s.bytes) / Double(max(volume.total, 1)) * 100).rounded()))% of the disk")
                .font(Theme.figure(11, .regular)).foregroundStyle(Theme.mist)
            Text(s.holding ? "Drains in \(Int(store.holdDays)) days · click to see" : "Click to dive in")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - The feed

struct NowFeed: View {
    @Environment(Store.self) private var store
    @State private var sweeping = false

    private var safeItems: [Candidate] {
        store.visibleCandidates.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
    }
    private var reviewItems: [Candidate] {
        store.visibleCandidates.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Scroll {
                VStack(alignment: .leading, spacing: 34) {
                    NowHeader()
                    switch store.condition {
                    case .scanning: ScanningState()
                    case .clear: AllClearState()
                    case .error: ErrorState()
                    case .firstRun: EmptyView()
                    case .items:
                        ForEach(store.pendingUninstalls) { u in UninstallMoment(event: u) }
                        if !safeItems.isEmpty {
                            ItemSection(kind: .safe, items: safeItems)
                        }
                        if !reviewItems.isEmpty {
                            ItemSection(kind: .review, items: reviewItems)
                        }
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.trailing, 16)
                .overlay { if sweeping { TideSweep() } }
            }
            .live { $0.mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                                   .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)) }

            SelectionBar().padding(.bottom, 22)
        }
        .onChange(of: store.tideAt) {
            sweeping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { sweeping = false }
        }
    }
}

/// The outgoing tide: a soft band of light passes over the list as items are released.
struct TideSweep: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let t = min(1, tl.date.timeIntervalSince(start) / 1.4)
                    let e = 1 - pow(1 - t, 2)
                    let x = size.width * (1.15 - 1.5 * e)
                    let band = CGRect(x: x - 160, y: 0, width: 320, height: size.height)
                    ctx.opacity = sin(t * .pi)
                    ctx.fill(Path(band), with: .linearGradient(Gradient(colors: [.clear, Theme.tide.opacity(0.10), .clear]),
                                                               startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)))
                }
            }
            .allowsHitTesting(false)
            .onAppear { start = Date() }
        }
    }
}

struct NowHeader: View {
    @Environment(Store.self) private var store

    var body: some View {
        let v = store.volume
        VStack(alignment: .leading, spacing: 8) {
            Text("Available").sectionLabel()
            RollingBytes(bytes: v.importantAvailable, size: 76, unitSize: 28, duration: 1.4)
            HStack(spacing: 6) {
                Text("of \(ByteText.full(v.total))")
                if v.purgeable > 500_000_000 { dot; Text("\(ByteText.full(v.purgeable)) macOS can reclaim itself") }
                if store.heldBytes > 0 { dot; Text("\(ByteText.full(store.heldBytes)) waiting in holding") }
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.mist)
            StatusLine().padding(.top, 14)
        }
    }

    private var dot: some View { Text("·").foregroundStyle(Theme.faint) }
}

struct StatusLine: View {
    @Environment(Store.self) private var store

    var body: some View {
        let selectedBytes = store.candidates.filter { store.selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        let review = store.visibleCandidates.filter { $0.tier == .review }.count
        let waits = review > 0 ? " \(review) item\(review == 1 ? " waits" : "s wait") for your call." : " Nothing needs you."
        HStack(spacing: 9) {
            if store.scanning {
                AgentPulse(state: "working")
                Text("Sounding caches, logs and leftovers…")
            } else if store.autopilot {
                Image(systemName: "water.waves").foregroundStyle(Theme.tide)
                if store.freedSession > 0 {
                    Text("Autopilot drained \(ByteText.full(store.freedSession)) to holding.\(Text(waits).foregroundStyle(Theme.mist))")
                } else {
                    Text("Autopilot is on.\(Text(waits).foregroundStyle(Theme.mist))")
                }
            } else if selectedBytes > 0 {
                Image(systemName: "hand.point.up.left").foregroundStyle(Theme.tide)
                Text("Tidal would release \(ByteText.full(selectedBytes)).\(Text(" Its picks are pre-selected; overrule anything.").foregroundStyle(Theme.mist))")
            } else {
                Image(systemName: "water.waves").foregroundStyle(Theme.tide)
                Text("Still water.\(Text(" Tidal is watching quietly.").foregroundStyle(Theme.mist))")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Theme.ink)
        .contentTransition(.opacity)
        .animation(.smooth, value: store.scanning)
    }
}

// MARK: - Sections and rows

struct ItemSection: View {
    enum Kind { case safe, review }
    let kind: Kind
    let items: [Candidate]
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(kind == .safe ? "Safe to let go" : "Your call").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                RollingBytes(bytes: items.reduce(0) { $0 + $1.bytes }, size: 14, weight: .regular, color: Theme.mist, duration: 0.8)
                Spacer()
                if kind == .safe && !store.autopilot {
                    let all = items.allSatisfy { store.selected.contains($0.id) }
                    Button(all ? "Select None" : "Select All") {
                        withAnimation(.spring(response: 0.3)) {
                            if all { store.selected.subtract(items.map(\.id)) } else { store.selected.formUnion(items.map(\.id)) }
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.mist)
                }
                if kind == .safe {
                    Button { store.discover() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(store.discovering ? 360 : 0))
                            .animation(store.discovering ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.discovering)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Look again")
                }
            }
            Text(kind == .safe ? "Regenerates on its own. \(store.autopilot ? "Autopilot releases these as they settle." : "Pre-selected for you.")"
                               : "Probably removable, but personal or costly to rebuild.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                    ItemRow(item: c, last: i == items.count - 1)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)),
                                                removal: .opacity.combined(with: .offset(x: -60))))
                }
            }
        }
    }
}

struct ItemRow: View {
    let item: Candidate
    var last = false
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    private var phase: ItemPhase { store.phases[item.id] ?? .ready }
    private var selected: Bool { store.selected.contains(item.id) }
    private var auto: Bool { store.autopilot && item.tier == .safe && (store.policies[item.category] ?? .ask) == .auto }

    var body: some View {
        HStack(spacing: 12) {
            selector
            ItemIcon(item: item, size: 26)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.owner).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(phase == .assessing ? "Assessing…" : item.ruleTitle)
                    .font(.system(size: 12)).foregroundStyle(Theme.mist).lineLimit(1)
                    .contentTransition(.opacity)
                if item.sharedBytes > 0 { Text("\(ByteText.full(item.sharedBytes)) shared").font(.system(size: 11)).foregroundStyle(Theme.faint) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if hover && phase == .ready {
                HStack(spacing: 14) {
                    rowButton("Keep", "hand.raised") { store.hold(item) }
                    rowButton("Show", "folder") { store.reveal(item.path) }
                    rowButton("Release", "arrow.down.to.line") { store.clean([item], reason: "Released by hand") }
                }
                .transition(.opacity.combined(with: .offset(x: 6)))
            }
            Text(ByteText.full(item.bytes)).font(Theme.figure(13, .medium)).foregroundStyle(Theme.ink)
                .frame(minWidth: 70, alignment: .trailing)
            Circle().fill(Theme.tierColor(item.tier)).frame(width: 6, height: 6)
                .live { $0.help(item.tier == .safe ? "Safe: regenerates on its own" : "Review: your call") }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(phase == .lifting ? Theme.tide.opacity(0.10) : hover ? Theme.wash : .clear)
        }
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 76) }
        }
        .overlay(alignment: .bottom) {
            if phase == .assessing && !reduceMotion { AssessLine().frame(height: 1).padding(.leading, 76) }
        }
        .contentShape(.rect)
        .particleSource(item.id, in: store.particles)
        .offset(x: phase == .arriving && !reduceMotion ? 18 : phase == .lifting ? 5 : phase == .gone ? -48 : 0)
        .opacity(phase == .gone || phase == .arriving ? 0 : 1)
        .live { $0.blur(radius: phase == .gone ? 6 : 0) }
        .onHover { h in withAnimation(.smooth(duration: 0.18)) { hover = h } }
        .onTapGesture { if !auto && phase == .ready { store.toggle(item) } }
        .live { $0.draggable(item.path) {
            HStack { ItemIcon(item: item, size: 22); Text(item.owner).font(.system(size: 12, weight: .semibold)) }
                .padding(10).glassEffect(.regular, in: .capsule)
        } }
        .live { $0.contextMenu {
            Button("Release Now") { store.clean([item], reason: "Released by hand") }
            Button(selected ? "Deselect" : "Select") { store.toggle(item) }
            Button("Keep") { store.hold(item) }
            Divider()
            Button("Show in Finder") { store.reveal(item.path) }
            Text(TidalPaths.pretty(item.path))
        } }
        .live { $0.help("\(TidalPaths.pretty(item.path))\nRule: \(item.ruleTitle)") }
    }

    @ViewBuilder private var selector: some View {
        if auto {
            Image(systemName: "water.waves").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tide.opacity(0.8))
                .frame(width: 18).live { $0.help("Autopilot releases this on its own") }
        } else {
            ZStack {
                Circle().strokeBorder(selected ? Theme.tide : Theme.faint.opacity(0.8), lineWidth: 1.2)
                if selected { Circle().fill(Theme.tide).padding(3.5).transition(.scale) }
            }
            .frame(width: 16, height: 16)
            .frame(width: 18)
        }
    }

    private func rowButton(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon).font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.plain).foregroundStyle(title == "Release" ? Theme.tide : Theme.mist)
    }
}

/// A short glint that travels along the row's hairline while it is being assessed.
struct AssessLine: View {
    @State private var x: CGFloat = -0.3
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Theme.tide.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.3)
                .offset(x: g.size.width * x)
        }
        .clipped()
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { x = 1 } }
    }
}

struct ItemIcon: View {
    let item: Candidate
    var size: CGFloat = 34

    var body: some View {
        if let img = IconCache.icon(for: item) {
            Image.icon(img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: KindSymbol.symbol(item.kind))
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(Theme.color(item.category))
                .frame(width: size, height: size)
                .background(Theme.color(item.category).opacity(0.14), in: .rect(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

// MARK: - The release bar (Manual)

struct SelectionBar: View {
    @Environment(Store.self) private var store

    var body: some View {
        let sel = store.candidates.filter { store.selected.contains($0.id) && !store.leftoverPaths.contains($0.path) }
        let bytes = sel.reduce(0) { $0 + $1.bytes }
        Group {
            if !store.autopilot && !sel.isEmpty && store.condition == .items {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(sel.count) selected").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        Text("or drag any row into the water").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                    RollingBytes(bytes: bytes, size: 17, unitSize: 11, weight: .regular, duration: 0.6)
                    Button("Release") { store.cleanSelected() }
                        .buttonStyle(.glassProminent).tint(Theme.tide)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.leading, 18).padding(.trailing, 7).frame(height: 50)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: sel.isEmpty || store.autopilot)
    }
}

// MARK: - Uninstall moment

struct UninstallMoment: View {
    let event: UninstallEvent
    @Environment(Store.self) private var store

    var total: Int64 { event.leftovers.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RippleRings(color: Theme.amber, rings: 3, duration: 2.8).frame(width: 110, height: 110)
                    Group {
                        if let i = IconCache.appIcon(bundleID: event.bundleID) {
                            Image.icon(i).resizable().saturation(0).opacity(0.5)
                        } else {
                            Image(systemName: "app.dashed").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Theme.mist)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(event.name) is gone.").foregroundStyle(Theme.ink)
                        RollingBytes(bytes: total, size: 17, unitSize: 13, weight: .semibold, color: Theme.amber)
                        Text("left behind.").foregroundStyle(Theme.amber)
                    }
                    .font(.system(size: 17, weight: .semibold))
                    Text(event.autoCleaned > 0 ? "Caches and preferences (\(ByteText.full(event.autoCleaned))) already drained to holding. These might hold your content."
                                               : event.confident ? "Found by its footprint. Some of these might hold your content."
                                                                 : "Matched by name, with lower confidence. Have a look first.")
                        .font(.system(size: 12)).foregroundStyle(Theme.mist)
                }
                Spacer()
                Button("Keep") { store.keepLeftovers(event) }.buttonStyle(.borderless).foregroundStyle(Theme.mist)
                Button("Let it drain") { store.cleanLeftovers(event) }.buttonStyle(.glassProminent).tint(Theme.tide)
            }
            FlowRow(spacing: 6) {
                ForEach(Array(event.leftovers.enumerated()), id: \.element.id) { i, c in
                    DropletChip(title: c.ruleTitle, bytes: c.bytes, color: Theme.tierColor(c.tier), index: i)
                        .particleSource(c.id, in: store.particles)
                        .help(TidalPaths.pretty(c.path))
                }
            }
            .padding(.leading, 70)
        }
        .padding(.vertical, 18).padding(.horizontal, 18)
        .background(Theme.amber.opacity(0.05), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.amber.opacity(0.18), lineWidth: 0.6))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - States

struct AllClearState: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            StillPool(mood: .clear, live: store.windowVisible).frame(width: 240, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("All clear").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.ink)
                Text("Nothing has settled since your last look. Tidal keeps watching from the menu bar, so you can close this window.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
                if let d = store.lastDiscover {
                    Text("Last sounding \(d.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.top, 4)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.top, 10)
        .transition(.opacity)
    }
}

struct ScanningState: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            StillPool(mood: .filling, live: store.windowVisible).frame(width: 240, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sounding the disk…").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.ink)
                Text("Looking through caches, logs and leftovers. Nothing is touched while Tidal looks.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
                Text(store.indexProgress.isEmpty ? "Measuring ~/Library" : "Measuring \(store.indexProgress)")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.top, 4)
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.top, 10)
        .transition(.opacity)
    }
}

struct ErrorState: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            StillPool(mood: .clouded, live: store.windowVisible).frame(width: 240, height: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("The water's gone cloudy").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.ink)
                Text("Tidal's background agent isn't running, so it can't clean up on its own or catch apps you drag to the Trash. Everything you can see here still works by hand.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Start the Agent") { store.launchAgentDirectly() }.buttonStyle(.glassProminent).tint(Theme.amber)
                    Button("Login Items…") { store.openLoginItems() }.buttonStyle(.glass)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(.top, 10)
        .transition(.opacity)
    }
}
