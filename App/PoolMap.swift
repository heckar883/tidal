import SwiftUI

/// The space map: one level of the disk as tidepools. Each pool's area is its size, and
/// the pools one level down already rest inside it, so you can see what a folder is made
/// of before you sink into it. The layout is computed, not simulated: nothing moves unless
/// the data, the hover or the level changes.
struct PoolMap: View {
    let items: [MapItem]
    let highlight: SpaceCategory?
    @Binding var hovered: MapItem?
    let open: (MapItem, UnitPoint) -> Void
    let dive: (MapItem, MapItem, UnitPoint) -> Void
    let select: (MapItem) -> Void
    let delete: (MapItem) -> Void

    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = Motion.frozen

    var body: some View {
        GeometryReader { g in
            let pools = PoolLayout.place(items, in: g.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(pools.enumerated()), id: \.element.item.id) { i, p in
                    let anchor = UnitPoint(x: p.center.x / max(g.size.width, 1), y: p.center.y / max(g.size.height, 1))
                    PoolView(pool: p, hover: hovered?.id == p.item.id,
                             dim: highlight != nil && highlight != p.item.category,
                             shown: shown, index: i,
                             open: { open(p.item, anchor) }, dive: { c in dive(p.item, c, anchor) }, select: select)
                        .frame(width: p.r * 2, height: p.r * 2)
                        .contentShape(.circle)
                        .position(p.center)
                        .onHover { h in
                            withAnimation(.smooth(duration: 0.15)) { hovered = h ? p.item : (hovered?.id == p.item.id ? nil : hovered) }
                        }
                        .live { v in
                            v.contextMenu {
                                if p.item.canOpen { Button("Open") { open(p.item, anchor) } }
                                if !store.chosenTargets(for: p.item).isEmpty { Button("Remove…") { delete(p.item) } }
                                if let path = p.item.path { Button("Show in Finder") { store.reveal(path) } }
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { r in
                            if let path = p.item.path { store.particles.frames["bubble:" + path] = r }
                        }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .animation(.spring(response: 0.7, dampingFraction: 0.86), value: items.map(\.bytes))
        }
        .onAppear {
            guard !shown else { return }
            if reduceMotion { shown = true } else { withAnimation(.spring(response: 0.8, dampingFraction: 0.82)) { shown = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space map")
    }
}

// MARK: - Layout

struct Pool {
    let item: MapItem
    let center: CGPoint
    let r: CGFloat
    /// Children resting inside, in the pool's own coordinates (0…2r).
    let inner: [(item: MapItem, center: CGPoint, r: CGFloat)]
}

enum PoolLayout {
    static func place(_ items: [MapItem], in size: CGSize) -> [Pool] {
        guard !items.isEmpty, size.width > 40, size.height > 40 else { return [] }
        let raw = radii(items.map(\.bytes), floor: 0.14)
        let gap = (raw.max() ?? 1) * 0.05
        let pts = CirclePack.pack(raw, gap: gap, aspect: size.width / size.height)
        let (centers, scale) = CirclePack.fit(pts, raw, into: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 6))
        return items.indices.map { i in
            let r = raw[i] * scale
            return Pool(item: items[i], center: centers[i], r: r, inner: inner(items[i], r: r))
        }
    }

    private static func inner(_ item: MapItem, r: CGFloat) -> [(item: MapItem, center: CGPoint, r: CGFloat)] {
        guard r >= 30, item.children.count > 0 else { return [] }
        // Only what would be visible at its true size; the remainder is the open water around it.
        let sorted = item.children.filter { !$0.id.hasSuffix("#rest") }.sorted { $0.bytes > $1.bytes }
        guard let top = sorted.first, top.bytes > 0 else { return [] }
        let total = Double(max(item.bytes, 1))
        let kids = Array(sorted.prefix(r > 90 ? 16 : 9).filter { sqrt(Double($0.bytes) / Double(top.bytes)) >= 0.12 })
        // One child filling the pool would just draw a ring inside a ring; leave the water clear.
        let kidSum = Double(kids.reduce(0) { $0 + $1.bytes })
        guard kids.count >= 3, Double(kids[0].bytes) / max(kidSum, 1) <= 0.6 else { return [] }
        let raw = kids.map { CGFloat(sqrt(Double($0.bytes))) }
        let gap = (raw.max() ?? 1) * 0.06
        let pts = CirclePack.pack(raw, gap: gap, aspect: 1)
        let cx = (pts.indices.map { pts[$0].x - raw[$0] }.min()! + pts.indices.map { pts[$0].x + raw[$0] }.max()!) / 2
        let cy = (pts.indices.map { pts[$0].y - raw[$0] }.min()! + pts.indices.map { pts[$0].y + raw[$0] }.max()!) / 2
        let R = pts.indices.map { hypot(pts[$0].x - cx, pts[$0].y - cy) + raw[$0] }.max() ?? 1
        // True to area where it fits: the children cover as much of the pool as they fill the folder.
        let share = Double(kids.reduce(0) { $0 + $1.bytes }) / total
        let fill = CGFloat(max(0.45, min(0.84, sqrt(share) * 0.95)))
        let s = r * fill / max(R, 0.001)
        return kids.indices.map { i in
            (kids[i], CGPoint(x: r + (pts[i].x - cx) * s, y: r + (pts[i].y - cy) * s), raw[i] * s)
        }
    }

    /// Area follows size; tiny items keep a floor so they stay findable.
    private static func radii(_ bytes: [Int64], floor: Double) -> [CGFloat] {
        let r = bytes.map { sqrt(Double(max($0, 1))) }
        let m = r.max() ?? 1
        return r.map { CGFloat(max($0, m * floor)) }
    }
}

enum CirclePack {
    /// Largest first; each circle rests against two already placed, as close to the middle
    /// as it can get. `aspect` > 1 lets the cluster spread wide to fill a wide field.
    static func pack(_ r: [CGFloat], gap: CGFloat, aspect: CGFloat) -> [CGPoint] {
        guard !r.isEmpty else { return [] }
        var p: [CGPoint] = [.zero]
        func cost(_ q: CGPoint) -> CGFloat { let x = q.x / aspect; return x * x + q.y * q.y }
        func fits(_ q: CGPoint, _ ri: CGFloat) -> Bool {
            for j in p.indices where hypot(q.x - p[j].x, q.y - p[j].y) < ri + r[j] + gap - 0.001 { return false }
            return true
        }
        for i in 1..<r.count {
            let ri = r[i]
            var best = CGPoint(x: (r[0] + ri + gap) * aspect, y: 0), bestCost = CGFloat.infinity
            func consider(_ q: CGPoint) {
                let c = cost(q)
                if c < bestCost, fits(q, ri) { best = q; bestCost = c }
            }
            for a in p.indices {
                let da = r[a] + ri + gap
                for k in 0..<16 {
                    let t = Double(k) / 16 * 2 * .pi
                    consider(CGPoint(x: p[a].x + da * cos(t), y: p[a].y + da * sin(t)))
                }
                for b in p.indices where b > a {
                    let db = r[b] + ri + gap
                    let dx = p[b].x - p[a].x, dy = p[b].y - p[a].y
                    let d = hypot(dx, dy)
                    guard d > 0, d <= da + db, d >= abs(da - db) else { continue }
                    let x = (da * da - db * db + d * d) / (2 * d)
                    let h = sqrt(max(0, da * da - x * x))
                    let mx = p[a].x + dx * x / d, my = p[a].y + dy * x / d
                    consider(CGPoint(x: mx - h * dy / d, y: my + h * dx / d))
                    consider(CGPoint(x: mx + h * dy / d, y: my - h * dx / d))
                }
            }
            p.append(best)
        }
        return p
    }

    /// Scales and centres a packed cluster into a rectangle.
    static func fit(_ p: [CGPoint], _ r: [CGFloat], into rect: CGRect) -> ([CGPoint], CGFloat) {
        let minX = p.indices.map { p[$0].x - r[$0] }.min() ?? 0, maxX = p.indices.map { p[$0].x + r[$0] }.max() ?? 1
        let minY = p.indices.map { p[$0].y - r[$0] }.min() ?? 0, maxY = p.indices.map { p[$0].y + r[$0] }.max() ?? 1
        let s = min(rect.width / max(maxX - minX, 0.001), rect.height / max(maxY - minY, 0.001))
        let ox = rect.midX - (minX + maxX) / 2 * s, oy = rect.midY - (minY + maxY) / 2 * s
        return (p.map { CGPoint(x: ox + $0.x * s, y: oy + $0.y * s) }, s)
    }
}

// MARK: - A pool

private struct PoolView: View {
    let pool: Pool
    let hover: Bool
    let dim: Bool
    let shown: Bool
    let index: Int
    let open: () -> Void
    let dive: (MapItem) -> Void
    let select: (MapItem) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var innerHover: String?

    private var item: MapItem { pool.item }
    private var dark: Bool { scheme == .dark }
    /// The category's sea tone, drifted a little per item so a level of one kind still has depth.
    private var tone: Color {
        let base = Theme.bubble(item.category)
        guard item.category != .system && item.category != .other && item.category != .purgeable else { return base }
        let h = item.id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let t = Double(h % 100) / 100
        return base.mix(with: t < 0.5 ? Theme.bubble(.developer) : Theme.bubble(.personal), by: abs(t - 0.5) * 0.7)
    }
    private var hollow: Bool { item.id.hasPrefix("#more") }

    var body: some View {
        let r = pool.r
        ZStack {
            // The water: deeper in the middle, catching light toward the rim.
            Circle()
                .fill(RadialGradient(colors: hollow ? [.clear, .clear] :
                                        [tone.opacity(dark ? 0.20 : 0.16), tone.opacity(dark ? 0.30 : 0.24), tone.opacity(dark ? 0.52 : 0.40)],
                                     center: .center, startRadius: 0, endRadius: r))

            ForEach(Array(pool.inner.enumerated()), id: \.element.item.id) { j, c in
                let on = innerHover == c.item.id
                Circle()
                    .fill(tone.opacity(on ? (dark ? 0.62 : 0.5) : hollow ? 0.14 : (dark ? 0.34 : 0.26)))
                    .overlay(Circle().strokeBorder(tone.opacity(dark ? 0.7 : 0.6), lineWidth: 0.6))
                    .frame(width: c.r * 2, height: c.r * 2)
                    .overlay {
                        if hover && c.r >= 24 {
                            Text(c.item.name)
                                .font(.system(size: min(12, max(9.5, c.r * 0.22)), weight: .medium))
                                .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: c.r * 1.7)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(shown ? 1 : 0.2)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.18 + Double(index) * 0.04 + Double(j) * 0.025), value: shown)
                    .position(c.center)
                    .contentShape(.circle)
                    .onHover { h in withAnimation(.smooth(duration: 0.15)) { innerHover = h ? c.item.id : (innerHover == c.item.id ? nil : innerHover) } }
                    .onTapGesture { dive(c.item) }
            }
            .opacity(hover ? 1 : 0.62)

            rim(r)

            if !hover || pool.inner.isEmpty { label(r).allowsHitTesting(false).transition(.opacity) }
        }
        .frame(width: r * 2, height: r * 2)
        .contentShape(.circle)
        .onTapGesture { item.canOpen ? open() : select(item) }
        .scaleEffect(shown ? 1 : 0.4)
        .opacity(shown ? (dim ? 0.38 : 1) : 0)
        .shadow(color: tone.opacity(hover && dark ? 0.35 : 0), radius: 18)
        .animation(.spring(response: 0.75, dampingFraction: 0.8).delay(shown && !Motion.frozen ? 0 : Double(index) * 0.045), value: shown)
        .accessibilityElement()
        .accessibilityLabel("\(item.name), \(ByteText.full(item.bytes))")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func rim(_ r: CGFloat) -> some View {
        let w: CGFloat = hover ? 1.4 : 0.9
        if item.dashed || hollow {
            Circle().strokeBorder(tone.opacity(hollow ? 0.5 : 0.85), style: StrokeStyle(lineWidth: w, dash: [3, 4]))
        } else {
            Circle().strokeBorder(
                LinearGradient(colors: [tone.opacity(hover ? 1 : 0.8), tone.opacity(hover ? 0.7 : 0.35)], startPoint: .top, endPoint: .bottom),
                lineWidth: w)
        }
    }

    @ViewBuilder private func label(_ r: CGFloat) -> some View {
        if r >= 32 {
            let big = r >= 70
            VStack(spacing: big ? 4 : 2) {
                if big, let b = item.bundleID, let img = IconCache.appIcon(bundleID: b) {
                    Image.icon(img).resizable().interpolation(.high).frame(width: min(40, r * 0.36), height: min(40, r * 0.36))
                }
                HStack(spacing: 4) {
                    if item.locked { Image(systemName: "lock.fill").font(.system(size: big ? 9 : 8)).foregroundStyle(Theme.mist) }
                    Text(item.name)
                        .font(.system(size: min(15, max(10.5, r * 0.13)), weight: .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: r * 1.6)
                Text(ByteText.full(item.bytes))
                    .font(Theme.figure(min(13, max(10, r * 0.11)), .regular))
                    .foregroundStyle(Theme.mist).lineLimit(1)
            }
            .shadow(color: dark ? .black.opacity(0.55) : .white.opacity(0.8), radius: 3)
            .shadow(color: dark ? .black.opacity(0.35) : .white.opacity(0.5), radius: 10)
        }
    }
}
