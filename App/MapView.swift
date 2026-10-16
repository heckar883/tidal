import SwiftUI
import AppKit

struct MapScreen: View {
    @Environment(Store.self) private var store
    @AppStorage("map.grouping") private var groupingRaw = Grouping.folders.rawValue
    @AppStorage("map.style") private var styleRaw = MapStyle.bubbles.rawValue
    @State private var trail: [MapItem] = []
    @State private var hovered: MapItem?
    @State private var hoverPoint: CGPoint = .zero
    @State private var focused: MapItem?
    @State private var highlight: SpaceCategory?
    @State private var pendingDelete: MapItem?
    @State private var systemSheet = false
    @Namespace private var ns

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .folders }
    private var style: MapStyle { MapStyle(rawValue: styleRaw) ?? .bubbles }

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
                }), label: { _ in nil }, symbol: { $0.symbol }, help: { $0.title })
            }
            .padding(.horizontal, 28)

            ZStack(alignment: .topLeading) {
                if store.nodes.isEmpty {
                    SkeletonField(progress: store.indexProgress)
                } else {
                    switch style {
                    case .bubbles:
                        BubbleField(items: MapBuilder.visible(level), levelKey: levelKey, highlight: highlight,
                                    hovered: $hovered, hoverPoint: $hoverPoint, open: open, select: { focused = $0 },
                                    delete: { pendingDelete = $0 })
                    case .ribbons:
                        RibbonsView(items: MapBuilder.visible(level, limit: 16), hovered: $hovered, open: open, select: { focused = $0 })
                            .padding(.horizontal, 28)
                    case .strata:
                        StrataView(items: MapBuilder.visible(level, limit: 18), hovered: $hovered, open: open, select: { focused = $0 })
                            .padding(.horizontal, 28)
                    case .list:
                        MapList(items: level, open: open, select: { focused = $0 }).padding(.horizontal, 28)
                    }
                }

                if style == .bubbles, let h = hovered {
                    HoverCard(item: h).fixedSize()
                        .offset(x: hoverPoint.x + 18, y: hoverPoint.y + 18)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.18), value: hovered?.id)

            HStack(alignment: .bottom, spacing: 16) {
                FocusPanel(item: focused ?? current, levelTotal: level.reduce(0) { $0 + $1.bytes }, onClose: focused != nil ? { focused = nil } : nil,
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
        .onExitCommand {
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

    private func open(_ item: MapItem) {
        guard item.canOpen else { focused = item; return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { trail.append(item) }
        hovered = nil
        focused = nil
        Haptics.snap()
    }
}

// MARK: - Bubble field

/// Spring-physics bubble packing. The simulation sleeps as soon as everything settles,
/// so a still map costs nothing to keep on screen.
final class BubbleSim {
    struct Bubble {
        var item: MapItem
        var pos: CGPoint
        var vel: CGVector = .zero
        var r: CGFloat
        var target: CGFloat
        var alpha: Double = 1
        var dying = false
    }

    var bubbles: [Bubble] = []
    var size: CGSize = .zero
    var dragging: String?
    var dragPoint: CGPoint = .zero
    var settled = false
    var ghost: (center: CGPoint, r: CGFloat, color: Color, born: Date)?
    private var memory: [String: [String: CGPoint]] = [:] // level → positions (normalized)
    private var lastKey = ""

    func set(_ items: [MapItem], size: CGSize, key: String, bloomFrom: CGPoint?, reduceMotion: Bool) {
        guard size.width > 10 else { return }
        self.size = size
        if !lastKey.isEmpty { memory[lastKey] = normalizedPositions() }
        let remembered = memory[key] ?? [:]
        let keyChanged = key != lastKey
        lastKey = key
        let total = max(1, items.reduce(0) { $0 + Double($1.bytes) })
        let area = Double(size.width * size.height) * 0.42
        let maxR = min(size.width, size.height) * 0.36
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var next: [Bubble] = []
        for (i, item) in items.enumerated() {
            let r = min(maxR, max(9, CGFloat(sqrt(Double(item.bytes) / total * area / .pi))))
            if let old = bubbles.first(where: { $0.item.id == item.id && !$0.dying }) {
                var b = old
                b.item = item
                b.target = r
                next.append(b)
            } else {
                var pos: CGPoint
                if let n = remembered[item.id] {
                    pos = CGPoint(x: n.x * size.width, y: n.y * size.height)
                } else if let from = bloomFrom {
                    let a = Double(i) * 2.399963
                    let d = CGFloat(sqrt(Double(i) + 0.5)) * 9
                    pos = CGPoint(x: from.x + cos(a) * d, y: from.y + sin(a) * d)
                } else {
                    // Golden-angle spiral outward from the centre, biggest first.
                    let a = Double(i) * 2.399963
                    let d = CGFloat(sqrt(Double(i) + 0.3)) * min(size.width, size.height) * 0.075
                    pos = CGPoint(x: center.x + cos(a) * d * 1.25, y: center.y + sin(a) * d)
                }
                next.append(Bubble(item: item, pos: pos, r: reduceMotion || (!keyChanged && remembered[item.id] != nil) ? r : 0.5, target: r))
            }
        }
        // Items that left the level dissolve rather than vanish.
        for var b in bubbles where !next.contains(where: { $0.item.id == b.item.id }) && !b.dying && !keyChanged {
            b.dying = true
            b.target = 0
            next.append(b)
        }
        bubbles = next
        settled = false
        if reduceMotion { for _ in 0..<400 { step() }; for i in bubbles.indices { bubbles[i].r = bubbles[i].target } }
    }

    private func normalizedPositions() -> [String: CGPoint] {
        var d: [String: CGPoint] = [:]
        for b in bubbles where !b.dying { d[b.item.id] = CGPoint(x: b.pos.x / max(size.width, 1), y: b.pos.y / max(size.height, 1)) }
        return d
    }

    func resize(_ s: CGSize) {
        guard s != size, size.width > 0 else { size = s; return }
        let sx = s.width / size.width, sy = s.height / size.height
        for i in bubbles.indices { bubbles[i].pos.x *= sx; bubbles[i].pos.y *= sy }
        let scale = sqrt(sx * sy)
        for i in bubbles.indices { bubbles[i].target *= scale; bubbles[i].r *= scale }
        size = s
        settled = false
    }

    func step() {
        guard !bubbles.isEmpty, size.width > 0 else { settled = true; return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Each category gently gathers around its own anchor, so like-tinted blobs touch and merge.
        let cats = Array(Set(bubbles.map(\.item.category))).sorted { $0.rawValue < $1.rawValue }
        var anchors: [SpaceCategory: CGPoint] = [:]
        for (i, c) in cats.enumerated() {
            let a = Double(i) / Double(max(cats.count, 1)) * 2 * .pi - .pi / 2
            let rad = cats.count > 1 ? min(size.width, size.height) * 0.16 : 0
            anchors[c] = CGPoint(x: center.x + cos(a) * rad * 1.3, y: center.y + sin(a) * rad)
        }
        var energy: CGFloat = 0
        for i in bubbles.indices {
            bubbles[i].r += (bubbles[i].target - bubbles[i].r) * 0.14
            energy += abs(bubbles[i].target - bubbles[i].r)
            if bubbles[i].dying { bubbles[i].alpha = max(0, bubbles[i].alpha - 0.05) }
            let anchor = anchors[bubbles[i].item.category] ?? center
            bubbles[i].vel.dx += (center.x - bubbles[i].pos.x) * 0.0035 + (anchor.x - bubbles[i].pos.x) * 0.006
            bubbles[i].vel.dy += (center.y - bubbles[i].pos.y) * 0.0045 + (anchor.y - bubbles[i].pos.y) * 0.007
        }
        let pad: CGFloat = 5
        for i in bubbles.indices {
            for j in (i + 1)..<bubbles.count {
                let dx = bubbles[j].pos.x - bubbles[i].pos.x
                let dy = bubbles[j].pos.y - bubbles[i].pos.y
                let dist = max(0.01, sqrt(dx * dx + dy * dy))
                let same = bubbles[i].item.category == bubbles[j].item.category
                let minD = bubbles[i].r + bubbles[j].r + (same ? pad * 0.4 : pad * 2.2)
                if dist < minD {
                    let push = (minD - dist) * 0.45
                    let mi = bubbles[i].r * bubbles[i].r, mj = bubbles[j].r * bubbles[j].r
                    let wi = mj / (mi + mj), wj = mi / (mi + mj)
                    let nx = dx / dist, ny = dy / dist
                    bubbles[i].vel.dx -= nx * push * wi; bubbles[i].vel.dy -= ny * push * wi
                    bubbles[j].vel.dx += nx * push * wj; bubbles[j].vel.dy += ny * push * wj
                }
            }
        }
        for i in bubbles.indices {
            if bubbles[i].item.id == dragging {
                let target = dragPoint
                bubbles[i].vel = CGVector(dx: (target.x - bubbles[i].pos.x) * 0.35, dy: (target.y - bubbles[i].pos.y) * 0.35)
            }
            bubbles[i].vel.dx *= 0.84
            bubbles[i].vel.dy *= 0.84
            bubbles[i].pos.x += bubbles[i].vel.dx
            bubbles[i].pos.y += bubbles[i].vel.dy
            let r = bubbles[i].r
            bubbles[i].pos.x = min(max(bubbles[i].pos.x, r + 6), size.width - r - 6)
            bubbles[i].pos.y = min(max(bubbles[i].pos.y, r + 6), size.height - r - 6)
            energy += abs(bubbles[i].vel.dx) + abs(bubbles[i].vel.dy)
        }
        bubbles.removeAll { $0.dying && $0.alpha <= 0 }
        settled = dragging == nil && energy < 0.04 * CGFloat(bubbles.count) && ghost == nil
    }

    func hit(_ p: CGPoint) -> Bubble? {
        bubbles.filter { !$0.dying }.sorted { $0.r < $1.r }.first { b in
            let dx = p.x - b.pos.x, dy = p.y - b.pos.y
            return dx * dx + dy * dy <= b.r * b.r
        }
    }
}

struct BubbleField: View {
    let items: [MapItem]
    let levelKey: String
    let highlight: SpaceCategory?
    @Binding var hovered: MapItem?
    @Binding var hoverPoint: CGPoint
    let open: (MapItem) -> Void
    let select: (MapItem) -> Void
    let delete: (MapItem) -> Void

    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sim = BubbleSim()
    @State private var tick = 0
    @State private var size: CGSize = .zero
    @State private var origin: CGPoint = .zero
    @State private var dragStart: CGPoint?
    @State private var pendingBloom: CGPoint?

    var body: some View {
        TimelineView(.animation(paused: (sim.settled && tick >= 0) || !store.windowVisible)) { tl in
            Canvas(rendersAsynchronously: false) { ctx, sz in
                if !sim.settled { sim.step() }
                draw(&ctx, at: tl.date)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { r in
            origin = r.origin
            if size == .zero { size = r.size; sim.set(items, size: r.size, key: levelKey, bloomFrom: nil, reduceMotion: reduceMotion) }
            else if r.size != size { size = r.size; sim.resize(r.size) }
            wake()
        }
        .onChange(of: items) { _, new in
            sim.set(new, size: size, key: levelKey, bloomFrom: pendingBloom, reduceMotion: reduceMotion)
            pendingBloom = nil
            wake()
        }
        .onChange(of: highlight) { wake() }
        .onChange(of: hovered?.id) { wake() }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverPoint = p
                let h = sim.hit(p)?.item
                if h?.id != hovered?.id { hovered = h; NSCursor.pointingHand.set() }
            case .ended:
                hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil { dragStart = v.startLocation }
                    let moved = hypot(v.translation.width, v.translation.height) > 5
                    if moved, sim.dragging == nil, let b = sim.hit(v.startLocation) { sim.dragging = b.item.id }
                    if sim.dragging != nil { sim.dragPoint = v.location; hoverPoint = v.location; wake() }
                }
                .onEnded { v in
                    defer { dragStart = nil }
                    if sim.dragging != nil {
                        sim.dragging = nil
                        Haptics.snap()
                        wake()
                        return
                    }
                    if let hb = sim.bubbles.first(where: { $0.item.id == hovered?.id && !$0.dying }),
                       BubbleField.hasBadge(hb), hypot(v.location.x - BubbleField.badge(hb).x, v.location.y - BubbleField.badge(hb).y) <= 11,
                       !store.chosenTargets(for: hb.item).isEmpty {
                        delete(hb.item)
                        return
                    }
                    guard let b = sim.hit(v.location) else { return }
                    if b.item.canOpen {
                        sim.ghost = (b.pos, b.r, Theme.bubble(b.item.category), Date())
                        pendingBloom = b.pos
                        open(b.item)
                    } else {
                        select(b.item)
                    }
                    wake()
                }
        )
        .onAppear {
            // Clean actions launch particles from the blob on screen.
            store.particles.frames = store.particles.frames
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space map")
        .accessibilityChildren {
            ForEach(items) { i in Text("\(i.name), \(Fmt.bytes(i.bytes))") }
        }
    }

    private func wake() { sim.settled = false; tick += 1 }

    static func hasBadge(_ b: BubbleSim.Bubble) -> Bool { b.r >= 30 }
    static func badge(_ b: BubbleSim.Bubble) -> CGPoint { CGPoint(x: b.pos.x + (b.r - 13) * 0.707, y: b.pos.y - (b.r - 13) * 0.707) }

    private func draw(_ ctx: inout GraphicsContext, at now: Date) {
        let bubbles = sim.bubbles
        // Register on-screen frames so cleaning can launch particles from the right blob.
        for b in bubbles where !b.dying {
            if let p = b.item.path {
                store.particles.frames["bubble:" + p] = CGRect(x: origin.x + b.pos.x - b.r, y: origin.y + b.pos.y - b.r, width: b.r * 2, height: b.r * 2)
            }
        }

        // Shared-element zoom: the opened blob swells to fill the field and fades as its contents bloom.
        if let g = sim.ghost {
            let t = now.timeIntervalSince(g.born) / 0.55
            if t >= 1 { sim.ghost = nil } else {
                let e = 1 - pow(1 - t, 3)
                let maxR = hypot(sim.size.width, sim.size.height) / 1.6
                let r = g.r + (maxR - g.r) * e
                ctx.drawLayer { l in
                    l.opacity = 0.35 * (1 - t)
                    l.fill(Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: r * 2, height: r * 2)),
                           with: .radialGradient(Gradient(colors: [g.color.opacity(0.5), g.color.opacity(0.05)]), center: g.center, startRadius: 0, endRadius: r))
                }
            }
        }

        // Droplet layer per category: blur + threshold makes neighbours of the same tint merge at the edges.
        let cats = Set(bubbles.map(\.item.category))
        for cat in cats {
            let dim = highlight != nil && highlight != cat
            ctx.drawLayer { layer in
                layer.addFilter(.alphaThreshold(min: 0.5, color: Theme.bubble(cat).opacity(dim ? 0.05 : 0.30)))
                layer.addFilter(.blur(radius: 9))
                for b in bubbles where b.item.category == cat {
                    let r = b.r + 3
                    layer.opacity = b.alpha
                    layer.fill(Path(ellipseIn: CGRect(x: b.pos.x - r, y: b.pos.y - r, width: r * 2, height: r * 2)), with: .color(.black))
                }
            }
        }

        // Glass bodies.
        for b in bubbles {
            let dim = highlight != nil && highlight != b.item.category
            let isHover = hovered?.id == b.item.id
            let c = Theme.bubble(b.item.category)
            let r = b.r
            guard r > 1 else { continue }
            let rect = CGRect(x: b.pos.x - r, y: b.pos.y - r, width: r * 2, height: r * 2)
            let circle = Path(ellipseIn: rect)
            ctx.opacity = b.alpha * (dim ? 0.3 : 1)
            ctx.fill(circle, with: .radialGradient(Gradient(colors: [c.opacity(isHover ? 0.85 : 0.70), c.opacity(0.35), c.opacity(isHover ? 0.65 : 0.50)]),
                                                    center: CGPoint(x: b.pos.x - r * 0.25, y: b.pos.y - r * 0.3), startRadius: 0, endRadius: r * 1.15))
            // Rim: brighter at the top, like light catching glass.
            ctx.stroke(circle, with: .linearGradient(Gradient(colors: [.white.opacity(isHover ? 0.65 : 0.32), c.opacity(0.18), .white.opacity(0.06)]),
                                                     startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
                       style: b.item.dashed ? StrokeStyle(lineWidth: 1, dash: [3, 4]) : StrokeStyle(lineWidth: isHover ? 1.3 : 0.8))
            // Specular highlight.
            if r > 14 {
                // A crisp, small highlight reads as glass; a huge one reads as plastic.
                let hr = min(r, 70)
                let hl = CGRect(x: b.pos.x - r * 0.55 - hr * 0.1, y: b.pos.y - r * 0.86 + hr * 0.08, width: hr * 0.95, height: hr * 0.42)
                ctx.fill(Path(ellipseIn: hl), with: .linearGradient(Gradient(colors: [.white.opacity(r > 120 ? 0.07 : 0.15), .white.opacity(0)]),
                                                                      startPoint: CGPoint(x: hl.midX, y: hl.minY), endPoint: CGPoint(x: hl.midX, y: hl.maxY)))
            }
            if b.item.orphan {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 4, dy: 4)), with: .color(Theme.tierColor(.review).opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            drawLabel(&ctx, b, rect: rect, dim: dim)
            if isHover, BubbleField.hasBadge(b), !store.chosenTargets(for: b.item).isEmpty {
                // A small remove badge on the rim, only while the pointer is over the bubble.
                let p = BubbleField.badge(b)
                let br = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
                ctx.fill(Path(ellipseIn: br), with: .color(Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.92)))
                ctx.stroke(Path(ellipseIn: br), with: .color(.white.opacity(0.55)), lineWidth: 0.8)
                var x = Path()
                x.move(to: CGPoint(x: p.x - 3.2, y: p.y - 3.2)); x.addLine(to: CGPoint(x: p.x + 3.2, y: p.y + 3.2))
                x.move(to: CGPoint(x: p.x + 3.2, y: p.y - 3.2)); x.addLine(to: CGPoint(x: p.x - 3.2, y: p.y + 3.2))
                ctx.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
        ctx.opacity = 1
    }

    private func drawLabel(_ ctx: inout GraphicsContext, _ b: BubbleSim.Bubble, rect: CGRect, dim: Bool) {
        let r = b.r
        guard r > 22 else { return }
        var y = b.pos.y
        let showIcon = r > 40 && b.item.bundleID != nil
        if showIcon, let bid = b.item.bundleID, let img = IconCache.appIcon(bundleID: bid) {
            let s = min(44, r * 0.55)
            ctx.draw(Image(nsImage: img), in: CGRect(x: b.pos.x - s / 2, y: y - s / 2 - (r > 54 ? 14 : 8), width: s, height: s))
            y += s / 2 - 2
        }
        let nameSize = min(15, max(9, r / 5.0))
        let name = ctx.resolve(Text(b.item.name).font(.system(size: nameSize, weight: .semibold)).foregroundStyle(.white.opacity(0.94)))
        let size = ctx.resolve(Text(Fmt.bytes(b.item.bytes)).font(.system(size: nameSize * 0.86, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62)))
        let maxW = r * 1.6
        let ns = name.measure(in: CGSize(width: maxW, height: 40))
        if r > 26 && ns.width <= maxW * 1.05 {
            ctx.draw(name, in: CGRect(x: b.pos.x - min(ns.width, maxW) / 2, y: y - ns.height + (showIcon ? 6 : 0), width: min(ns.width, maxW), height: ns.height))
            ctx.draw(size, at: CGPoint(x: b.pos.x, y: y + (showIcon ? 6 : 0) + ns.height * 0.55), anchor: .center)
        } else {
            ctx.draw(size, at: CGPoint(x: b.pos.x, y: y), anchor: .center)
        }
        if b.item.locked && r > 34 {
            let lock = ctx.resolve(Image(systemName: "lock.fill"))
            ctx.opacity = 0.5
            ctx.draw(lock, in: CGRect(x: b.pos.x - 5, y: rect.maxY - min(26, r * 0.35), width: 10, height: 12))
            ctx.opacity = 1
        }
    }
}

// MARK: - Ribbons

struct RibbonsView: View {
    let items: [MapItem]
    @Binding var hovered: MapItem?
    let open: (MapItem) -> Void
    let select: (MapItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let maxB = max(1, items.map(\.bytes).max() ?? 1)
        let total = max(1, items.reduce(0) { $0 + $1.bytes })
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let isHover = hovered?.id == item.id
                    HStack(spacing: 16) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(Int((Double(item.bytes) / Double(total) * 100).rounded()))% · \(Fmt.bytes(item.bytes))")
                                .font(Theme.figure(11)).foregroundStyle(Theme.mist)
                        }
                        .frame(width: 190, alignment: .trailing)
                        GeometryReader { g in
                            let w = max(14, g.size.width * CGFloat(Double(item.bytes) / Double(maxB)))
                            RibbonShape(phase: Double(i) * 0.9)
                                .fill(LinearGradient(colors: [Theme.color(item.category).opacity(isHover ? 0.95 : 0.75),
                                                              Theme.color(item.category).opacity(0.22)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .overlay(RibbonShape(phase: Double(i) * 0.9).stroke(.white.opacity(isHover ? 0.4 : 0.14), lineWidth: 0.6))
                                .frame(width: appeared || reduceMotion ? w : 14)
                                .shadow(color: Theme.color(item.category).opacity(isHover ? 0.5 : 0.2), radius: isHover ? 14 : 6)
                                .overlay(alignment: .leading) {
                                    if item.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).padding(.leading, 10) }
                                }
                        }
                        .frame(height: 30)
                    }
                    .contentShape(.rect)
                    .onHover { h in withAnimation(.smooth(duration: 0.15)) { hovered = h ? item : (hovered?.id == item.id ? nil : hovered) } }
                    .onTapGesture { item.canOpen ? open(item) : select(item) }
                    .animation(.spring(response: 0.7, dampingFraction: 0.82).delay(Double(i) * 0.03), value: appeared)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: item.bytes)
                }
            }
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .onAppear { appeared = true }
    }
}

/// A band with a softly undulating edge and a rounded, tapering tail.
struct RibbonShape: Shape {
    var phase: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let h = r.height
        let steps = max(8, Int(r.width / 10))
        p.move(to: CGPoint(x: r.minX + h / 2, y: r.minY))
        for s in 0...steps {
            let x = r.minX + h / 2 + (r.width - h) * CGFloat(s) / CGFloat(steps)
            let taper = 1 - pow(Double(s) / Double(steps), 3) * 0.35
            let y = r.midY - h / 2 * CGFloat(taper) + CGFloat(sin(Double(s) * 0.5 + phase)) * 1.6
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addArc(center: CGPoint(x: r.maxX - h / 2, y: r.midY), radius: h / 2 * 0.65, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        for s in stride(from: steps, through: 0, by: -1) {
            let x = r.minX + h / 2 + (r.width - h) * CGFloat(s) / CGFloat(steps)
            let taper = 1 - pow(Double(s) / Double(steps), 3) * 0.35
            let y = r.midY + h / 2 * CGFloat(taper) + CGFloat(sin(Double(s) * 0.5 + phase + 1.3)) * 1.6
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addArc(center: CGPoint(x: r.minX + h / 2, y: r.midY), radius: h / 2, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Strata

struct StrataView: View {
    let items: [MapItem]
    @Binding var hovered: MapItem?
    let open: (MapItem) -> Void
    let select: (MapItem) -> Void

    var body: some View {
        GeometryReader { g in
            let layers = layout(height: g.size.height - 40)
            HStack(alignment: .top, spacing: 0) {
                Canvas { ctx, size in
                    for (i, l) in layers.enumerated() {
                        let c = Theme.color(l.item.category)
                        let isHover = hovered?.id == l.item.id
                        var p = Path()
                        let w = size.width
                        func edge(_ y: CGFloat, _ seed: Double) -> [CGPoint] {
                            stride(from: 0.0, through: Double(w), by: 12).map { x in
                                CGPoint(x: x, y: y + CGFloat(sin(x / 70 + seed) * 2.2 + sin(x / 23 + seed * 2) * 1.1))
                            }
                        }
                        let top = edge(l.y, Double(i) * 1.7), bottom = edge(l.y + l.h, Double(i + 1) * 1.7)
                        p.move(to: top[0]); top.forEach { p.addLine(to: $0) }
                        bottom.reversed().forEach { p.addLine(to: $0) }
                        p.closeSubpath()
                        ctx.fill(p, with: .linearGradient(Gradient(colors: [c.opacity(isHover ? 0.75 : 0.52), c.opacity(isHover ? 0.45 : 0.22)]),
                                                          startPoint: CGPoint(x: 0, y: l.y), endPoint: CGPoint(x: 0, y: l.y + l.h)))
                        var line = Path(); line.move(to: top[0]); top.forEach { line.addLine(to: $0) }
                        ctx.stroke(line, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
                        if l.item.locked && l.h > 16 {
                            ctx.opacity = 0.45
                            ctx.draw(ctx.resolve(Image(systemName: "lock.fill")), at: CGPoint(x: 16, y: l.y + l.h / 2))
                            ctx.opacity = 1
                        }
                    }
                }
                .frame(width: min(520, g.size.width * 0.55))
                .clipShape(.rect(cornerRadius: 26))
                .glassEffect(.clear, in: .rect(cornerRadius: 26))
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hovered = layers.first { p.y >= $0.y && p.y < $0.y + $0.h }?.item } else { hovered = nil }
                }
                .onTapGesture { p in if let l = layers.first(where: { p.y >= $0.y && p.y < $0.y + $0.h }) { l.item.canOpen ? open(l.item) : select(l.item) } }

                // Labels with leader lines, spaced so they never collide.
                ZStack(alignment: .topLeading) {
                    ForEach(labelPositions(layers)) { lp in
                        HStack(spacing: 10) {
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 26, height: 0.6)
                            CategoryDot(category: lp.item.category, size: 7)
                            Text(lp.item.name).font(.system(size: 12, weight: hovered?.id == lp.item.id ? .semibold : .regular)).foregroundStyle(Theme.ink)
                            Text(Fmt.bytes(lp.item.bytes)).font(Theme.figure(11.5)).foregroundStyle(Theme.mist)
                        }
                        .offset(y: lp.y - 8)
                        .onTapGesture { lp.item.canOpen ? open(lp.item) : select(lp.item) }
                    }
                }
                .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: items.map(\.bytes))
        }
    }

    struct Layer { let item: MapItem; let y: CGFloat; let h: CGFloat }
    struct LabelPos: Identifiable { var id: String { item.id }; let item: MapItem; var y: CGFloat }

    private func layout(height: CGFloat) -> [Layer] {
        let total = max(1, items.reduce(0) { $0 + Double($1.bytes) })
        let minH: CGFloat = 5
        var y: CGFloat = 0
        let usable = height - minH * CGFloat(items.count)
        return items.map { item in
            let h = minH + max(0, usable) * CGFloat(Double(item.bytes) / total)
            defer { y += h }
            return Layer(item: item, y: y, h: h)
        }
    }

    private func labelPositions(_ layers: [Layer]) -> [LabelPos] {
        var out: [LabelPos] = []
        var lastY: CGFloat = -100
        for l in layers {
            let y = max(l.y + l.h / 2, lastY + 20)
            out.append(LabelPos(item: l.item, y: y))
            lastY = y
        }
        return out
    }
}

// MARK: - List

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
                            if selection == o { Capsule().fill(.white.opacity(0.13)).matchedGeometryEffect(id: "sel", in: ns) }
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
                    Circle().stroke(.white.opacity(0.14), lineWidth: 2.2)
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

struct HoverCard: View {
    let item: MapItem
    @Environment(Store.self) private var store

    var body: some View {
        let cleanable = store.cleanable(in: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let b = item.bundleID, let img = IconCache.appIcon(bundleID: b) { Image(nsImage: img).resizable().frame(width: 22, height: 22) }
                else { CategoryDot(category: item.category) }
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            RollingBytes(bytes: item.bytes, size: 26, unitSize: 13, weight: .light)
            VStack(alignment: .leading, spacing: 4) {
                Label(item.category.title, systemImage: item.category.symbol)
                if let u = item.used { Label("Last used \(Fmt.relative(u))", systemImage: "clock") }
                if item.locked { Label("Protected — Tidal never touches this", systemImage: "lock.fill") }
                else if item.denied { Label("Couldn't read — needs Full Disk Access", systemImage: "eye.slash") }
                else if !cleanable.isEmpty {
                    Label("\(Fmt.bytes(cleanable.reduce(0) { $0 + $1.bytes })) safe to clean", systemImage: "drop")
                        .foregroundStyle(Theme.tide)
                }
                if let n = item.note { Text(n).foregroundStyle(Theme.faint).frame(maxWidth: 240, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
                if item.canOpen { Text("Click to open · drag to nudge").foregroundStyle(Theme.faint) }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.mist)
        }
        .padding(14)
        .frame(minWidth: 200, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct FocusPanel: View {
    let item: MapItem?
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
                RollingBytes(bytes: item.bytes, size: 22, unitSize: 12, weight: .light)
                if cb > 0 && !item.locked {
                    Button {
                        if let p = item.path {
                            let rect = store.particles.frames["bubble:" + p]
                            for c in cleanable { if let rect { store.particles.frames[c.id] = rect } }
                        }
                        store.clean(cleanable, reason: "Cleaned from the map")
                    } label: {
                        Label("Clean \(Fmt.bytes(cb))", systemImage: "drop")
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
                Text("Click a bubble to open it, or use its ✕ to remove it. Esc goes back.").foregroundStyle(Theme.faint)
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
                    Text(c.title).font(.system(size: 11, weight: .medium)).foregroundStyle(highlight == c ? Theme.ink : Theme.mist)
                    Text(Fmt.bytes(totals[c] ?? 0)).font(Theme.figure(10.5)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(highlight == c ? .white.opacity(0.08) : .clear, in: .capsule)
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
                        .fill(.white.opacity(shimmer ? 0.07 : 0.03))
                        .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 0.6))
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
