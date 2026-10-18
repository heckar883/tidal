import SwiftUI
import AppKit

// Shared by the interface and the agent (menu bar popover, uninstall prompt).
// "Sounding": the disk as a column of still water. Free space is the clear water,
// used space settles below it in layers. One accent: glacier teal.

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A colour that follows the appearance it is drawn in.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        adaptive(light: NSColor(hex: light, alpha: alpha), dark: NSColor(hex: dark, alpha: alpha))
    }
    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }
}

// MARK: - Tokens

enum Theme {
    // Brand
    /// Glacier teal, #3FB8C9. Slightly deeper on light backgrounds so text stays legible.
    static let tide = Color.adaptive(light: 0x1A93A6, dark: 0x3FB8C9)
    /// The "alive" tint: the agent at work, droplets, the all-clear glow. Used sparingly.
    static let glow = Color.adaptive(light: 0x2BB493, dark: 0x6FE3C1)
    static let tideDeep = Color.adaptive(light: 0x0F6F82, dark: 0x1F7F95)
    static let amber = Color.adaptive(light: 0xB7741F, dark: 0xE9B46A)

    // Text
    static let ink = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.92), dark: NSColor(white: 1, alpha: 0.93))
    static let mist = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.60), dark: NSColor(white: 1, alpha: 0.60))
    static let faint = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.40), dark: NSColor(white: 1, alpha: 0.36))

    // Surfaces
    static let hairline = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.075))
    static let wash = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.04))
    static let washStrong = Color.adaptive(light: NSColor(hex: 0x0C1820, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let abyss = Color.adaptive(light: 0xF4F1EA, dark: 0x05090E)
    static let deep = Color.adaptive(light: 0xEAF1EF, dark: 0x08111A)
    /// Text drawn on top of the accent.
    static let onTide = Color.adaptive(light: 0xFFFFFF, dark: 0x04161B)

    // The water column
    static let waterTop = Color.adaptive(light: 0xDDF0F1, dark: 0x0E3442)
    static let waterMid = Color.adaptive(light: 0xC2E4E8, dark: 0x0A2330)
    static let waterLow = Color.adaptive(light: 0xA9D5DC, dark: 0x071720)
    static let bed = Color.adaptive(light: 0xD9CDB6, dark: 0x0A0F16)

    /// Sediment tones: water blues, sand, kelp and coral. No purple.
    static func color(_ c: SpaceCategory) -> Color {
        switch c {
        case .apps: .adaptive(light: 0x2F84C0, dark: 0x5AA8E0)
        case .personal: .adaptive(light: 0xB98A45, dark: 0xD9B07A)
        case .libraries: .adaptive(light: 0xC0675E, dark: 0xDE8E84)
        case .developer: .adaptive(light: 0x3B6A9E, dark: 0x6F9BD0)
        case .system: .adaptive(light: 0x6E7B88, dark: 0x8592A0)
        case .backups: .adaptive(light: 0x3E9A7C, dark: 0x67C2A2)
        case .purgeable: .adaptive(light: 0x4FA9B8, dark: 0xA6DCE5)
        case .other: .adaptive(light: 0x7C8691, dark: 0x6F7984)
        }
    }

    /// Map pools: one family of sea tones, told apart by depth rather than by hue,
    /// so the map reads as one body of water.
    static func bubble(_ c: SpaceCategory) -> Color {
        switch c {
        case .apps: .adaptive(light: 0x1F8EA6, dark: 0x45B3C6)
        case .developer: .adaptive(light: 0x2D6FA6, dark: 0x4E8FCB)
        case .personal: .adaptive(light: 0x2C9A7E, dark: 0x58C4A3)
        case .libraries: .adaptive(light: 0x3E7DB3, dark: 0x6AA2D6)
        case .backups: .adaptive(light: 0x2F9C93, dark: 0x6CCBBE)
        case .purgeable: .adaptive(light: 0x4FAAB8, dark: 0x9AD8E0)
        case .system: .adaptive(light: 0x6F8293, dark: 0x7D90A3)
        case .other: .adaptive(light: 0x8693A0, dark: 0x66778A)
        }
    }

    static func tierColor(_ t: Tier) -> Color {
        switch t {
        case .safe: tide
        case .review: amber
        case .never: faint
        }
    }

    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .thin).monospacedDigit() }
    static func figure(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w).monospacedDigit() }
}

// MARK: - Motion

enum Motion {
    /// Offscreen design snapshots render one frame, so entrance animations are shown settled.
    static let frozen = ProcessInfo.processInfo.environment["TIDAL_OFFSCREEN"] != nil
}

/// A vertical scroll view; offscreen snapshots can't draw scroll views, so they get a plain stack.
struct Scroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if Motion.frozen {
            Color.clear.overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

extension View {
    /// Interaction-only modifiers that offscreen snapshots can't draw.
    @ViewBuilder func live<V: View>(_ apply: (Self) -> V) -> some View {
        if Motion.frozen { self } else { apply(self) }
    }
}

// MARK: - Background: still water seen from above

struct WaterBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.abyss
            if scheme == .dark {
                LinearGradient(colors: [Color(hex: 0x0A1A24), Color(hex: 0x060C13), Color(hex: 0x04070B)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(hex: 0x3FB8C9, alpha: 0.07), .clear], center: .init(x: 0.28, y: -0.1), startRadius: 0, endRadius: 760)
            } else {
                LinearGradient(colors: [Color(hex: 0xF7F5F0), Color(hex: 0xEEF3F1), Color(hex: 0xE6EEEC)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(hex: 0x3FB8C9, alpha: 0.08), .clear], center: .init(x: 0.28, y: -0.1), startRadius: 0, endRadius: 760)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Counting numerals

/// Byte figures count through every value on their way, instead of swapping glyphs.
struct CountingBytes: View, Animatable {
    var value: Double
    var size: CGFloat
    var unitSize: CGFloat?
    var weight: Font.Weight
    var color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let (num, unit) = ByteText.split(Int64(max(0, value)))
        HStack(alignment: .firstTextBaseline, spacing: size * 0.09) {
            Text(num).font(.system(size: size, weight: weight).monospacedDigit()).foregroundStyle(color)
            Text(unit).font(.system(size: unitSize ?? size * 0.42, weight: weight == .thin ? .light : weight)).foregroundStyle(color.opacity(0.55))
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct RollingBytes: View {
    let bytes: Int64
    var size: CGFloat = 64
    var unitSize: CGFloat? = nil
    var weight: Font.Weight = .thin
    var color: Color = Theme.ink
    var duration: Double = 1.1

    var body: some View {
        // The final figure reserves the width, so counting never nudges the layout around it.
        ZStack(alignment: .leading) {
            CountingBytes(value: Double(bytes), size: size, unitSize: unitSize, weight: weight, color: color).hidden()
            CountingBytes(value: Double(bytes), size: size, unitSize: unitSize, weight: weight, color: color)
                .animation(.smooth(duration: duration), value: bytes)
        }
        .fixedSize()
            .accessibilityElement()
            .accessibilityLabel(ByteText.full(bytes))
    }
}

/// A cached formatter: counting numerals format every frame.
enum ByteText {
    nonisolated(unsafe) private static let f: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()
    static func full(_ b: Int64) -> String { f.string(fromByteCount: max(0, b)) }
    static func split(_ b: Int64) -> (String, String) {
        let s = full(b)
        guard let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
}

// MARK: - Small pieces

struct TierPill: View {
    let tier: Tier
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            if tier == .never { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
            Text(tier.title.uppercased()).font(.system(size: compact ? 8.5 : 9.5, weight: .bold)).tracking(0.8)
        }
        .foregroundStyle(Theme.tierColor(tier))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.tierColor(tier).opacity(0.12), in: .capsule)
    }
}

struct CategoryDot: View {
    let category: SpaceCategory
    var size: CGFloat = 8
    var bubble = false
    var body: some View {
        let c = bubble ? Theme.bubble(category) : Theme.color(category)
        Circle().fill(c).frame(width: size, height: size)
    }
}

/// The agent's state at a glance: still when idle, breathing only while it works.
struct AgentPulse: View {
    let state: String
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var color: Color {
        switch state {
        case "working": Theme.glow
        case "attention": Theme.amber
        case "off", "error": Theme.faint
        default: Theme.tide
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.5), lineWidth: 1).frame(width: 14, height: 14)
                .scaleEffect(breathe ? 1.6 : 0.6).opacity(breathe ? 0 : (state == "working" ? 1 : 0))
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .onAppear { if !reduceMotion && state == "working" { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true } } }
        .onChange(of: state) { _, s in
            if s == "working" && !reduceMotion { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true } }
            else { withAnimation(.smooth) { breathe = false } }
        }
    }
}

extension Image {
    /// App icons. Offscreen snapshots redraw them into a plain sRGB bitmap first: the renderer
    /// otherwise adopts the icon's colour space for the whole frame.
    static func icon(_ ns: NSImage, size: CGFloat = 64) -> Image {
        guard Motion.frozen else { return Image(nsImage: ns) }
        let px = Int(size * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Image(nsImage: ns) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ns.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return Image(nsImage: ns) }
        return Image(decorative: cg, scale: 2)
    }
}

/// App and folder icons, resolved once.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for c: Candidate) -> NSImage? {
        appIcon(bundleID: Engine.ownerKey(c.name)) ?? appIcon(bundleID: c.owner)
    }

    static func appIcon(bundleID: String) -> NSImage? {
        guard bundleID.contains(".") else { return nil }
        if let i = cache[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = i
        return i
    }

    static func file(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

enum KindSymbol {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "cache": "square.stack.3d.down.right"
        case "log": "text.alignleft"
        case "crash": "exclamationmark.bubble"
        case "installer": "shippingbox"
        case "trash": "trash"
        case "devcache", "build": "hammer"
        case "devicesupport": "iphone.gen3"
        case "archive": "archivebox"
        case "backup": "clock.arrow.circlepath"
        case "download": "arrow.down.circle"
        case "leftover": "app.dashed"
        default: "circle.dashed"
        }
    }
}

enum Haptics {
    static func snap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func clean() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func undo() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}

extension View {
    /// Section label: small caps, generous tracking.
    func sectionLabel() -> some View {
        self.font(.system(size: 10.5, weight: .semibold)).tracking(1.4).textCase(.uppercase).foregroundStyle(Theme.faint)
    }

    /// A hairline under a row.
    func hairlineBelow(inset: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, inset) }
    }
}
