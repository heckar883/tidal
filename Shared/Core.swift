import Foundation

// MARK: - Identity

enum TidalID {
    static let app = "app.tidal.mac"
    static let agent = "app.tidal.mac.agent"
    /// Posted by the agent whenever the index, queue, holding area or log changed.
    static let changed = Notification.Name("app.tidal.mac.changed")
    /// Posted by the agent while a pass is running (userInfo: state = idle|working|attention).
    static let state = Notification.Name("app.tidal.mac.state")
    /// Posted by the interface to ask the agent for work (userInfo: cmd).
    static let request = Notification.Name("app.tidal.mac.request")
    /// Posted by the agent when an uninstall was detected (userInfo: id).
    static let uninstall = Notification.Name("app.tidal.mac.uninstall")
}

// MARK: - Tiers and categories

enum Tier: String, Codable, CaseIterable, Sendable {
    case safe, review, never
    var title: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .never: "Protected"
        }
    }
}

enum SpaceCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case apps, personal, libraries, developer, system, backups, purgeable, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Apps"
        case .personal: "Personal files"
        case .libraries: "Libraries"
        case .developer: "Developer"
        case .system: "System"
        case .backups: "Backups & snapshots"
        case .purgeable: "Purgeable"
        case .other: "Other"
        }
    }
    var symbol: String {
        switch self {
        case .apps: "square.stack.3d.up"
        case .personal: "folder"
        case .libraries: "photo.on.rectangle"
        case .developer: "hammer"
        case .system: "gearshape"
        case .backups: "clock.arrow.circlepath"
        case .purgeable: "sparkles"
        case .other: "circle.dashed"
        }
    }
}

/// Per-category automation policy (Autopilot honours this).
enum Policy: String, Codable, CaseIterable, Sendable {
    case auto, ask, never
    var title: String {
        switch self {
        case .auto: "Always auto"
        case .ask: "Always ask"
        case .never: "Never"
        }
    }
}

// MARK: - Rule catalog

struct Rule: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Path pattern. `~` is the home root. The last component may contain `*`/`?`.
    let pattern: String
    let tier: Tier
    let category: SpaceCategory
    let kind: String
    var minAgeDays: Double?
    var minSizeMB: Double?
    var extensions: [String]?
    var exclude: [String]?
    /// "Grows too large" trigger: a single item above this size starts a pass.
    var capMB: Double?
    var note: String?
}

struct Catalog: Codable, Sendable {
    let version: Int
    let signature: String?
    let rules: [Rule]

    static func load() -> Catalog {
        let candidates = [
            Bundle.main.url(forResource: "catalog", withExtension: "json"),
            ProcessInfo.processInfo.environment["TIDAL_CATALOG"].map { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let cat = try? JSONDecoder().decode(Catalog.self, from: data) {
                return cat
            }
        }
        return Catalog(version: 0, signature: nil, rules: [])
    }
}

// MARK: - Items

struct Candidate: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let owner: String
    let ruleID: String
    let ruleTitle: String
    let tier: Tier
    let category: SpaceCategory
    let kind: String
    let bytes: Int64
    let modified: Date?
    /// Set when hard links make the reclaimable size smaller than the visible size.
    var sharedBytes: Int64 = 0
}

struct HeldItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let original: String
    let stored: String
    let name: String
    let owner: String
    let ruleID: String
    let category: SpaceCategory
    let bytes: Int64
    let heldAt: Date
    let batch: String
}

struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    let at: Date
    let kind: String // clean, restore, purge, uninstall, refuse, scan, note
    let title: String
    let detail: String
    let bytes: Int64
}

struct UninstallEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bundleID: String
    let name: String
    let at: Date
    var autoCleaned: Int64
    var leftovers: [Candidate]
    var state: String // pending, kept, cleaned
    var confident: Bool
}

// MARK: - Paths

enum TidalPaths {
    /// Root used for every `~` in the catalog. Overridable for tests so nothing real is touched.
    static var home: URL = {
        if let h = ProcessInfo.processInfo.environment["TIDAL_HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static var support: URL = {
        if let s = ProcessInfo.processInfo.environment["TIDAL_SUPPORT"] { return URL(fileURLWithPath: s) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tidal", isDirectory: true)
    }()

    static var holding: URL { support.appendingPathComponent(".Holding", isDirectory: true) }
    static var database: URL { support.appendingPathComponent("index.sqlite") }
    static var log: URL { support.appendingPathComponent("activity.log") }

    static func ensure() {
        try? FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
    }

    static func expand(_ pattern: String) -> String {
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") { return home.path + "/" + pattern.dropFirst(2) }
        return pattern
    }

    static func pretty(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~/" + path.dropFirst(h.count + 1) }
        return path
    }
}

// MARK: - Settings (stored in the shared index)

enum SettingKey {
    static let autopilot = "autopilot"
    /// Apps dragged to the Trash are uninstalled completely, without waiting for Autopilot. On by default.
    static let autoUninstall = "autoUninstall"
    static let holdDays = "holdDays"
    static let freeThresholdGB = "freeThresholdGB"
    static let lastEventID = "lastEventID"
    static let agentPID = "agentPID"
    static let freedTotal = "freedTotal"
    static func policy(_ c: SpaceCategory) -> String { "policy.\(c.rawValue)" }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, b))
    }

    /// Split into number and unit so the numeral can be the hero.
    static func split(_ b: Int64) -> (String, String) {
        let s = bytes(b)
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (s, "")
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
