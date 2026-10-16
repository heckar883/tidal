import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NowView: View {
    @Environment(Store.self) private var store
    @Namespace private var wellNS

    private var safeItems: [Candidate] {
        store.candidates.filter { $0.tier == .safe && !store.leftoverPaths.contains($0.path) }.sorted { $0.bytes > $1.bytes }
    }
    private var reviewItems: [Candidate] {
        store.candidates.filter { $0.tier == .review && !store.leftoverPaths.contains($0.path) }.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Hero()
                    ForEach(store.pendingUninstalls) { u in UninstallMoment(event: u) }
                    if !safeItems.isEmpty {
                        ItemSection(title: "Safe", subtitle: "Regenerates on its own", items: safeItems)
                    }
                    if !reviewItems.isEmpty {
                        ItemSection(title: "Review", subtitle: "Probably removable, but personal or costly to rebuild — your call", items: reviewItems)
                    }
                    if safeItems.isEmpty && reviewItems.isEmpty && store.pendingUninstalls.isEmpty {
                        CalmState()
                    }
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 36).padding(.top, 22)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.025),
                                         .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))

            CleanWell(ns: wellNS).padding(.bottom, 20)
        }
    }
}

// MARK: - Hero: the tide

struct Hero: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Available").sectionLabel()
                RollingBytes(bytes: store.volume.importantAvailable, size: 84, unitSize: 30)
                Text("of \(Fmt.bytes(store.volume.total)) on \(store.volume.name)" +
                     (store.volume.purgeable > 1_000_000_000 ? "  ·  \(Fmt.bytes(store.volume.purgeable)) macOS can reclaim itself" : ""))
                    .font(.system(size: 13)).foregroundStyle(Theme.mist)
                StatusLine().padding(.top, 12)
            }
            Spacer(minLength: 0)
            TideVessel(volume: store.volume, threshold: store.db.double(SettingKey.freeThresholdGB, default: 20) * 1e9)
                .frame(width: 430, height: 196)
        }
    }
}

struct StatusLine: View {
    @Environment(Store.self) private var store

    var body: some View {
        let selectedBytes = store.candidates.filter { store.selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        let review = store.candidates.filter { $0.tier == .review }.count
        HStack(spacing: 9) {
            if store.discovering {
                ProgressView().controlSize(.mini).tint(Theme.tide)
                Text("Looking through caches, logs and leftovers…")
            } else if store.autopilot {
                Image(systemName: "sparkles").foregroundStyle(Theme.tide)
                if store.freedSession > 0 {
                    Text("Autopilot moved \(Fmt.bytes(store.freedSession)) to holding.\(Text(review > 0 ? " \(review) item\(review == 1 ? " waits" : "s wait") for your review." : " Nothing needs you.").foregroundStyle(Theme.mist))")
                } else {
                    Text("Autopilot is on.\(Text(review > 0 ? " \(review) item\(review == 1 ? " waits" : "s wait") for your review." : " Nothing needs you right now.").foregroundStyle(Theme.mist))")
                }
            } else if selectedBytes > 0 {
                Image(systemName: "hand.point.up.left").foregroundStyle(Theme.tide)
                Text("Tidal would clean \(Fmt.bytes(selectedBytes)).\(Text(" Its picks are pre-selected — overrule anything.").foregroundStyle(Theme.mist))")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.tide)
                Text("Nothing to tidy right now.\(Text(" Tidal is watching quietly.").foregroundStyle(Theme.mist))")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Theme.ink)
        .contentTransition(.opacity)
        .animation(.smooth, value: store.discovering)
    }
}

/// The disk as a glass vessel. The water line is used space; it falls (and sloshes) as space is freed.
struct TideVessel: View {
    let volume: VolumeInfo
    let threshold: Double
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var water = Water()
    @State private var hover = false

    /// The water line eases toward the real level each frame; a real change sets off a slosh.
    final class Water {
        var level: Double?
        var sloshAt = Date.distantPast
        func advance(to target: Double, at now: Date, animated: Bool) -> Double {
            guard let l = level, animated else { level = target; return target }
            if abs(target - l) > 0.002 && now.timeIntervalSince(sloshAt) > 2 { sloshAt = now }
            let next = l + (target - l) * 0.06
            level = abs(target - next) < 0.0005 ? target : next
            return level!
        }
    }

    private var target: Double { volume.total > 0 ? Double(volume.total - volume.importantAvailable) / Double(volume.total) : 0 }
    private var purgeShare: Double { volume.total > 0 ? Double(volume.purgeable) / Double(volume.total) : 0 }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !store.windowVisible || reduceMotion)) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let level = water.advance(to: target, at: tl.date, animated: store.windowVisible && !reduceMotion)
                    let since = tl.date.timeIntervalSince(water.sloshAt)
                    let slosh = since < 4 ? exp(-since * 1.1) * 9 : 0
                    let amp = 1.6 + slosh
                    let inset: CGFloat = 10
                    let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                    let clip = Path(roundedRect: box, cornerRadius: 22, style: .continuous)
                    ctx.clip(to: clip)

                    func surface(_ lvl: Double, phase: Double, k: Double, a: Double) -> Path {
                        var p = Path()
                        let y0 = box.maxY - box.height * lvl
                        p.move(to: CGPoint(x: box.minX, y: box.maxY))
                        var x = box.minX
                        while x <= box.maxX + 2 {
                            let rel = Double((x - box.minX) / box.width)
                            let y = y0 + CGFloat(sin(rel * k + phase) * a + sin(rel * k * 2.3 + phase * 1.7) * a * 0.35)
                            p.addLine(to: CGPoint(x: x, y: y))
                            x += 4
                        }
                        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                        p.closeSubpath()
                        return p
                    }

                    // Purgeable: a lighter band macOS will reclaim on its own.
                    ctx.fill(surface(level, phase: t * 0.9 + 1, k: 9, a: amp * 0.8),
                             with: .linearGradient(Gradient(colors: [Theme.purgeableTop, Theme.purgeableTop.opacity(0.35)]),
                                                   startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
                    let used = max(0, level - purgeShare)
                    ctx.fill(surface(used, phase: t * 1.3, k: 7, a: amp),
                             with: .linearGradient(Gradient(colors: [Theme.tide.opacity(0.85), Theme.tideDeep.opacity(0.9), Color(red: 0.06, green: 0.16, blue: 0.38)]),
                                                   startPoint: CGPoint(x: 0, y: box.maxY - box.height * used), endPoint: CGPoint(x: 0, y: box.maxY)))
                    // Caustic light on the surface.
                    ctx.blendMode = .plusLighter
                    ctx.opacity = 0.22
                    ctx.stroke(surface(used, phase: t * 1.3, k: 7, a: amp).trimmedPath(from: 0, to: 0.36), with: .color(.white), lineWidth: 1)

                    // Threshold line: Autopilot steps in below this much free space.
                    ctx.opacity = 0.55
                    ctx.blendMode = .normal
                    let thrLevel = volume.total > 0 ? 1 - threshold / Double(volume.total) : 1
                    let ty = box.maxY - box.height * thrLevel
                    var dash = Path(); dash.move(to: CGPoint(x: box.minX, y: ty)); dash.addLine(to: CGPoint(x: box.maxX, y: ty))
                    ctx.stroke(dash, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
                }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("\(Int((1 - target) * 100))% free").font(Theme.figure(13, .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    if hover {
                        Text("dashed line · Autopilot steps in below \(Fmt.bytes(Int64(threshold)))")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.mist).transition(.opacity)
                    }
                }
                Spacer()
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Used").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.7))
                        Text(Fmt.bytes(volume.total - volume.importantAvailable)).font(Theme.figure(17, .semibold)).foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if volume.purgeable > 0 {
                        Text("incl. \(Fmt.bytes(volume.purgeable)) purgeable").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(24)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .onHover { h in withAnimation(.smooth) { hover = h } }
    }
}

extension Theme {
    static let purgeableTop = Color(red: 0.62, green: 0.88, blue: 0.95).opacity(0.38)
}

// MARK: - Sections and items

struct ItemSection: View {
    let title: String
    let subtitle: String
    let items: [Candidate]
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(Fmt.bytes(items.reduce(0) { $0 + $1.bytes })).font(Theme.figure(15)).foregroundStyle(Theme.mist)
                    .contentTransition(.numericText())
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.faint)
                Spacer()
                if title == "Safe" && !store.autopilot {
                    let all = items.allSatisfy { store.selected.contains($0.id) }
                    Button(all ? "Select None" : "Select All") {
                        withAnimation(.spring(response: 0.3)) {
                            if all { store.selected.subtract(items.map(\.id)) } else { store.selected.formUnion(items.map(\.id)) }
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.mist)
                }
                if title == "Safe" {
                    Button { store.discover() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(store.discovering ? 360 : 0))
                            .animation(store.discovering ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.discovering)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Look again")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 262, maximum: 360), spacing: 12)], spacing: 12) {
                ForEach(items) { c in ItemCard(item: c) }
            }
        }
    }
}

struct ItemCard: View {
    let item: Candidate
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    @State private var spin = false

    private var phase: ItemPhase { store.phases[item.id] ?? .ready }
    private var selected: Bool { store.selected.contains(item.id) }
    private var auto: Bool { store.autopilot && item.tier == .safe && (store.policies[item.category] ?? .ask) == .auto }

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.owner).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 5) {
                    Text(phase == .assessing ? "Assessing…" : item.ruleTitle)
                    if item.sharedBytes > 0 { Text("· \(Fmt.bytes(item.sharedBytes)) shared").foregroundStyle(Theme.faint) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.mist).lineLimit(1)
                .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Text(Fmt.bytes(item.bytes)).font(Theme.figure(15, .semibold)).foregroundStyle(Theme.ink)
                if phase == .ready || phase == .lifting {
                    if hover && !store.autopilot {
                        HStack(spacing: 6) {
                            Button { store.hold(item) } label: { Image(systemName: "hand.raised").font(.system(size: 10, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Hold back — keep this")
                            Button { store.reveal(item.path) } label: { Image(systemName: "folder").font(.system(size: 10, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Show in Finder")
                        }
                        .transition(.opacity)
                    } else {
                        TierPill(tier: item.tier, compact: true).transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(height: 70)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.color(item.category).opacity(selected ? 0.10 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? Theme.tide.opacity(0.75) : .white.opacity(hover ? 0.16 : 0.07), lineWidth: selected ? 1.2 : 0.6)
        }
        .overlay {
            if phase == .assessing && !reduceMotion {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(AngularGradient(colors: [.clear, Theme.tide.opacity(0.9), .clear, .clear], center: .center,
                                                  angle: .degrees(spin ? 360 : 0)), lineWidth: 1.3)
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .overlay(alignment: .topLeading) {
            if selected && !auto {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                    .symbolRenderingMode(.palette).foregroundStyle(.black, Theme.tide)
                    .offset(x: -5, y: -5).transition(.scale.combined(with: .opacity))
            }
        }
        .glassEffect(.regular.tint(Theme.color(item.category).opacity(0.04)).interactive(), in: .rect(cornerRadius: 20))
        .particleSource(item.id, in: store.particles)
        .scaleEffect(phase == .lifting ? 1.035 : phase == .gone ? 0.82 : phase == .arriving ? 0.94 : 1)
        .offset(x: phase == .arriving && !reduceMotion ? 24 : 0, y: phase == .lifting ? -5 : 0)
        .opacity(phase == .gone || phase == .arriving ? 0 : 1)
        .blur(radius: phase == .gone ? 8 : phase == .arriving ? 4 : 0)
        .shadow(color: Theme.tide.opacity(phase == .lifting ? 0.35 : 0), radius: 18, y: 8)
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hover = h } }
        .onTapGesture { if !auto && phase == .ready { store.toggle(item) } }
        .draggable(item.path) {
            HStack { ItemIcon(item: item); Text(item.owner).font(.system(size: 12, weight: .semibold)) }
                .padding(10).glassEffect(.regular, in: .capsule)
        }
        .contextMenu {
            Button("Clean Now") { store.clean([item], reason: "Manual clean") }
            Button(selected ? "Deselect" : "Select") { store.toggle(item) }
            Button("Hold Back") { store.hold(item) }
            Divider()
            Button("Show in Finder") { store.reveal(item.path) }
            Text(TidalPaths.pretty(item.path))
        }
        .help("\(TidalPaths.pretty(item.path))\nRule: \(item.ruleTitle)")
    }
}

struct ItemIcon: View {
    let item: Candidate
    var size: CGFloat = 34

    var body: some View {
        if let img = IconCache.icon(for: item) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: KindSymbol.symbol(item.kind))
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Theme.color(item.category))
                .frame(width: size, height: size)
                .background(Theme.color(item.category).opacity(0.13), in: .rect(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

// MARK: - Uninstall moment

struct UninstallMoment: View {
    let event: UninstallEvent
    @Environment(Store.self) private var store

    var total: Int64 { event.leftovers.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "app.dashed").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Theme.mist)
                    .frame(width: 52, height: 52).background(.white.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text("\(event.name) is gone. ").foregroundStyle(Theme.ink))\(Text("\(Fmt.bytes(total)) left behind.").foregroundStyle(Theme.tierColor(.review)))")
                        .font(.system(size: 17, weight: .semibold))
                    Text(event.autoCleaned > 0 ? "Caches and preferences (\(Fmt.bytes(event.autoCleaned))) already went to holding. These might hold your content."
                                               : event.confident ? "Found by its footprint. Some of these might hold your content."
                                                                 : "Matched by name, with lower confidence. Have a look before cleaning.")
                        .font(.system(size: 12)).foregroundStyle(Theme.mist)
                }
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Keep") { store.keepLeftovers(event) }.buttonStyle(.glass)
                        Button("Clean Leftovers") { store.cleanLeftovers(event) }.buttonStyle(.glassProminent).tint(Theme.tide)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(event.leftovers) { c in
                    HStack(spacing: 8) {
                        Image(systemName: c.tier == .safe ? "checkmark.circle" : "eye").font(.system(size: 10.5)).foregroundStyle(Theme.tierColor(c.tier))
                        Text(c.ruleTitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(Fmt.bytes(c.bytes)).font(Theme.figure(11)).foregroundStyle(Theme.mist)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.04), in: .capsule)
                    .particleSource(c.id, in: store.particles)
                    .help(TidalPaths.pretty(c.path))
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(Theme.tierColor(.review).opacity(0.05)), in: .rect(cornerRadius: 26))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct CalmState: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "water.waves").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Theme.tide.opacity(0.8))
            Text(store.discovering ? "Looking…" : "Still water").font(.system(size: 20, weight: .light)).foregroundStyle(Theme.ink)
            Text("Caches, logs and leftovers are under control. Tidal keeps watching from the menu bar —\nyou can close this window.")
                .multilineTextAlignment(.center).font(.system(size: 12.5)).foregroundStyle(Theme.mist)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

// MARK: - The clean well (Manual) ↔ the Autopilot line, one morphing glass shape

struct CleanWell: View {
    let ns: Namespace.ID
    @Environment(Store.self) private var store
    @State private var targeted = false

    var body: some View {
        let sel = store.candidates.filter { store.selected.contains($0.id) && !store.leftoverPaths.contains($0.path) }
        let bytes = sel.reduce(0) { $0 + $1.bytes }
        GlassEffectContainer(spacing: 14) {
            Group {
                if store.autopilot {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.tide)
                        Text("Autopilot cleans Safe items as they appear").foregroundStyle(Theme.ink)
                        Text("·").foregroundStyle(Theme.faint)
                        Text("Review items wait for you").foregroundStyle(Theme.mist)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 22).frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("well", in: ns)
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(targeted ? Theme.tide : Theme.mist)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(targeted ? "Release to clean" : "Drop items here to clean")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(sel.isEmpty ? "or select them above" : "\(sel.count) selected · \(Fmt.bytes(bytes))")
                                .font(.system(size: 11)).foregroundStyle(Theme.mist).contentTransition(.numericText())
                        }
                        .frame(minWidth: 170, alignment: .leading)
                        Button("Clean Selected") { store.cleanSelected() }
                            .buttonStyle(.glassProminent).tint(Theme.tide)
                            .disabled(sel.isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    .padding(.leading, 18).padding(.trailing, 8).frame(height: 56)
                    .glassEffect(.regular.tint(Theme.tide.opacity(targeted ? 0.25 : 0.0)).interactive(), in: .capsule)
                    .glassEffectID("well", in: ns)
                    .scaleEffect(targeted ? 1.05 : 1)
                    .dropDestination(for: String.self) { paths, _ in
                        let items = store.candidates.filter { paths.contains($0.path) }
                        store.clean(items, reason: "Dropped to clean")
                        return !items.isEmpty
                    } isTargeted: { t in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { targeted = t }; if t { Haptics.snap() } }
                }
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: store.autopilot)
    }
}
