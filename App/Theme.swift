import SwiftUI
import AppKit

// MARK: - Palette: dark-first, one restrained accent hue per category

enum Theme {
    static let abyss = Color(red: 0.020, green: 0.027, blue: 0.051)
    static let deep = Color(red: 0.035, green: 0.055, blue: 0.098)
    static let tide = Color(red: 0.36, green: 0.86, blue: 0.92)      // the one brand accent
    static let tideDeep = Color(red: 0.16, green: 0.46, blue: 0.86)
    static let ink = Color.white.opacity(0.92)
    static let mist = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.34)

    static func color(_ c: SpaceCategory) -> Color {
        switch c {
        case .apps: Color(red: 0.38, green: 0.66, blue: 1.00)
        case .personal: Color(red: 0.96, green: 0.71, blue: 0.43)
        case .libraries: Color(red: 0.95, green: 0.50, blue: 0.66)
        case .developer: Color(red: 0.66, green: 0.56, blue: 1.00)
        case .system: Color(red: 0.56, green: 0.62, blue: 0.72)
        case .backups: Color(red: 0.40, green: 0.84, blue: 0.69)
        case .purgeable: Color(red: 0.64, green: 0.90, blue: 0.95)
        case .other: Color(red: 0.47, green: 0.50, blue: 0.56)
        }
    }

    /// Map bubbles use only blues and near-blacks, one shade per category.
    static func bubble(_ c: SpaceCategory) -> Color {
        switch c {
        case .apps: Color(red: 0.22, green: 0.55, blue: 1.00)       // azure
        case .personal: Color(red: 0.10, green: 0.32, blue: 0.88)   // cobalt
        case .libraries: Color(red: 0.48, green: 0.74, blue: 1.00)  // sky
        case .developer: Color(red: 0.12, green: 0.18, blue: 0.58)  // navy
        case .system: Color(red: 0.16, green: 0.20, blue: 0.32)     // slate black
        case .backups: Color(red: 0.32, green: 0.46, blue: 0.68)    // steel
        case .purgeable: Color(red: 0.72, green: 0.87, blue: 1.00)  // ice
        case .other: Color(red: 0.07, green: 0.09, blue: 0.16)      // ink
        }
    }

    static func tierColor(_ t: Tier) -> Color {
        switch t {
        case .safe: tide
        case .review: Color(red: 0.96, green: 0.78, blue: 0.48)
        case .never: Color.white.opacity(0.5)
        }
    }

    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .thin).monospacedDigit() }
    static func figure(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w, design: .rounded).monospacedDigit() }
}

// MARK: - Background: layered depth, no decoration loops

struct AbyssBackground: View {
    var body: some View {
        ZStack {
            Theme.abyss
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.5], [0.42, 0.58], [1, 0.45],
                [0, 1], [0.6, 1], [1, 1],
            ], colors: [
                Color(red: 0.03, green: 0.07, blue: 0.13), Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.05, green: 0.05, blue: 0.12),
                Color(red: 0.02, green: 0.05, blue: 0.09), Color(red: 0.04, green: 0.10, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.09),
                Color(red: 0.02, green: 0.03, blue: 0.06), Color(red: 0.03, green: 0.07, blue: 0.11), Color(red: 0.02, green: 0.03, blue: 0.07),
            ])
            // A faint light from above, like looking up through water.
            RadialGradient(colors: [Theme.tide.opacity(0.10), .clear], center: .init(x: 0.5, y: -0.15), startRadius: 0, endRadius: 720)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Rolling numerals

struct RollingBytes: View {
    let bytes: Int64
    var size: CGFloat = 64
    var unitSize: CGFloat? = nil
    var weight: Font.Weight = .thin
    var color: Color = Theme.ink

    var body: some View {
        let (num, unit) = Fmt.split(bytes)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            Text(num)
                .font(.system(size: size, weight: weight).monospacedDigit())
                .contentTransition(.numericText(value: Double(bytes)))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: unitSize ?? size * 0.42, weight: .light))
                .foregroundStyle(color.opacity(0.55))
        }
        .animation(.snappy(duration: 0.6), value: bytes)
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
        Circle().fill(c.gradient).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(bubble ? 0.35 : 0), lineWidth: 0.6))
            .shadow(color: c.opacity(0.6), radius: 3)
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
}
