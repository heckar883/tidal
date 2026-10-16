import Foundation
import AppKit
import Darwin

// MARK: - Sizing

/// Allocated-size measurement in one pass with fts(3): no symlink following, no volume crossing,
/// hard links counted once. APFS clones cannot be detected cheaply, so they are flagged in the UI copy instead.
enum Sizer {
    struct Measure { var bytes: Int64 = 0; var shared: Int64 = 0; var denied = false; var newest: Date? }

    static func measure(_ path: String) -> Measure {
        var m = Measure()
        var seen = Set<UInt64>()
        var newest: Int = 0
        walk(path) { ent, info, st in
            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st else { return }
                let alloc = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 && info == FTS_F {
                    if !seen.insert(UInt64(st.st_ino)).inserted { m.shared += alloc; return }
                }
                m.bytes += alloc
                newest = max(newest, Int(st.st_mtimespec.tv_sec))
            case FTS_D:
                if let st { m.bytes += Int64(st.st_blocks) * 512 }
            case FTS_DNR, FTS_ERR, FTS_NS:
                m.denied = true
            default: break
            }
        }
        if newest > 0 { m.newest = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return m
    }

    /// Low-level walker shared by `measure` and the space indexer.
    static func walk(_ path: String, _ visit: (UnsafeMutablePointer<FTSENT>, Int32, stat?) -> Void) {
        guard let cpath = strdup(path) else { return }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            visit(ent, info, ent.pointee.fts_statp?.pointee)
        }
    }

    /// Lower this thread's disk priority so cleaning never slows the user's work.
    static func throttleIO() {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
    }
}

// MARK: - Volume

struct VolumeInfo: Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    var importantAvailable: Int64 = 0
    var name = "Macintosh HD"
    var used: Int64 { total - available }
    var purgeable: Int64 { max(0, importantAvailable - available) }

    static func current() -> VolumeInfo {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return VolumeInfo() }
        return VolumeInfo(total: Int64(v.volumeTotalCapacity ?? 0),
                          available: Int64(v.volumeAvailableCapacity ?? 0),
                          importantAvailable: v.volumeAvailableCapacityForImportantUsage ?? 0,
                          name: v.volumeLocalizedName ?? "Macintosh HD")
    }
}

// MARK: - Safety: the single choke point

enum Safety {
    /// Never touched, no matter what any rule says (relative to the home root, or absolute).
    static let protectedHome = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Public",
                                "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/Photos",
                                "Library/Keychains", "Library/Accounts", "Library/Calendars", "Library/Safari",
                                "Library/Application Support/Tidal"]
    static let protectedRoots = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple", "/Volumes"]
    static let quietWindow: TimeInterval = 15 * 60

    static func real(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    static func ruleMatches(_ rule: Rule, path: String) -> Bool {
        let pattern = TidalPaths.expand(rule.pattern)
        let pParent = (pattern as NSString).deletingLastPathComponent
        let pLast = (pattern as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard real(parent) == real(pParent) else { return false }
        guard fnmatch(pLast, name, 0) == 0 else { return false }
        if let ex = rule.exclude, ex.contains(where: { fnmatch($0, name, 0) == 0 }) { return false }
        if let exts = rule.extensions, !exts.contains((name as NSString).pathExtension.lowercased()) { return false }
        return true
    }

    /// First matching rule wins, so the catalog orders specific rules before general ones.
    static func rule(for path: String, in catalog: Catalog, uninstallContext: Bool = false) -> Rule? {
        catalog.rules.first { r in
            if r.kind == "leftover" && !uninstallContext { return false }
            return ruleMatches(r, path: path)
        }
    }

    static func isProtected(_ path: String) -> Bool {
        let r = real(path)
        let home = real(TidalPaths.home.path)
        if protectedRoots.contains(where: { r == $0 || r.hasPrefix($0 + "/") }) && !r.hasPrefix(home + "/") { return true }
        for p in protectedHome {
            let full = home + "/" + p
            if r == full || r.hasPrefix(full + "/") { return true }
        }
        return r == home
    }

    /// Returns nil when removal is allowed, or a human-readable refusal.
    static func refusal(for c: Candidate, catalog: Catalog, running: Set<String>, uninstallContext: Bool = false) -> String? {
        let path = c.path
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "Not an absolute path" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "No longer exists" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "Is a symbolic link" }
        guard let rule = rule(for: path, in: catalog, uninstallContext: uninstallContext) else { return "No rule allows this location" }
        if rule.tier == .never { return "Protected by rule \(rule.id)" }
        if rule.id != c.ruleID { return "Rule changed since the dry run" }
        if isProtected(path) { return "Inside a protected location" }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if !uninstallContext && Date().timeIntervalSince(mtime) < quietWindow { return "Modified in the last 15 minutes" }
        let lower = c.name.lowercased()
        if !uninstallContext, running.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") || c.owner == $0 }) {
            return "In use by a running app"
        }
        // The holding area must be on the same volume so a move is a rename, not a copy.
        var hs = stat()
        if stat(TidalPaths.holding.path, &hs) == 0, hs.st_dev != st.st_dev { return "On a different volume" }
        return nil
    }

    /// Folders that can never be removed as a whole, however the request arrives.
    static let unremovableHome = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Public", "Downloads", "Library",
                                  "Applications", ".Trash", "Library/Application Support", "Library/Caches", "Library/Preferences",
                                  "Library/Containers", "Library/Group Containers", "Library/Logs"]
    static let neverInside = ["Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/Photos", "Library/Keychains",
                              "Library/Accounts", "Library/Calendars", "Library/Safari", "Library/Application Support/Tidal",
                              "Library/Application Support/MobileSync"]

    /// For items the person picked by hand: broader than the catalog, still bounded.
    /// Returns nil when removal is allowed, or a human-readable refusal.
    static func userRefusal(for path: String, running: Set<String>) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "Not an absolute path" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "No longer exists" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "Is a symbolic link" }
        let r = real(path)
        let home = real(TidalPaths.home.path)
        if r == "/Applications" { return "That is the whole Applications folder" }
        let inApps = r.hasPrefix("/Applications/")
        guard r.hasPrefix(home + "/") || inApps else { return "Outside your home folder and Applications" }
        if r.hasPrefix(home + "/") {
            let rel = String(r.dropFirst(home.count + 1))
            if unremovableHome.contains(rel) { return "Too broad to remove as a whole — open it and pick what's inside" }
            if neverInside.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return "Protected: it holds personal data or Tidal itself" }
        }
        if r.hasSuffix(".app") || r.contains(".app/") {
            let bundle = r.components(separatedBy: ".app").first.map { $0 + ".app" } ?? r
            let busy = NSWorkspace.shared.runningApplications.contains { $0.bundleURL.map { real($0.path) == bundle } ?? false }
            if busy { return "The app is running — quit it first" }
        }
        let name = (r as NSString).lastPathComponent
        if running.contains(name) && !name.hasSuffix(".app") { return "In use by a running app" }
        var hs = stat()
        if stat(TidalPaths.holding.path, &hs) == 0, hs.st_dev != st.st_dev { return "On a different volume" }
        return nil
    }

    static func runningBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let b = app.bundleIdentifier { ids.insert(b) }
            if let n = app.localizedName { ids.insert(n) }
        }
        return ids
    }
}

// MARK: - Engine

final class Engine: @unchecked Sendable {
    let db: Database
    let catalog: Catalog
    private var ownerCache: [String: String] = [:]
    private let ownerLock = NSLock()

    init(db: Database = .shared, catalog: Catalog = .load()) {
        self.db = db
        self.catalog = catalog
        TidalPaths.ensure()
    }

    var holdDays: Double { db.double(SettingKey.holdDays, default: 14) }

    // MARK: owner names

    func ownerName(for name: String) -> String {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if let o = ownerCache[name] { return o }
        var result = name
        let base = Engine.ownerKey(name)
        if let n = db.appName(base) { result = n }
        else if base.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: base) {
            result = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else if base.hasPrefix("com.apple.") {
            result = "macOS · " + base.dropFirst("com.apple.".count)
        } else if base.contains("."), !base.contains(" "), !name.hasSuffix(".log"), !name.hasSuffix(".diag") {
            // Unresolved bundle identifier: show its last component, nicely.
            let last = base.split(separator: ".").last.map(String.init) ?? base
            result = last.prefix(1).uppercased() + last.dropFirst()
        }
        ownerCache[name] = result
        return result
    }

    /// Strips only the suffixes macOS adds to per-app items, never part of a bundle identifier.
    static func ownerKey(_ name: String) -> String {
        for ext in [".savedState", ".binarycookies", ".plist"] where name.hasSuffix(ext) { return String(name.dropLast(ext.count)) }
        return name
    }

    // MARK: dry run

    /// Expands every non-leftover rule into concrete items with their real allocated size.
    /// This is the dry run; exactly this list is what the user sees.
    func discover(onFound: ((Candidate) -> Void)? = nil) -> [Candidate] {
        Sizer.throttleIO()
        var out: [Candidate] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        for rule in catalog.rules where rule.tier != .never && rule.kind != "leftover" {
            let pattern = TidalPaths.expand(rule.pattern)
            let parent = (pattern as NSString).deletingLastPathComponent
            let last = (pattern as NSString).lastPathComponent
            let names: [String]
            if last.contains("*") || last.contains("?") {
                names = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
            } else {
                names = fm.fileExists(atPath: pattern) ? [last] : []
            }
            for name in names.sorted() {
                let path = parent + "/" + name
                guard !seenPaths.contains(path), name != ".DS_Store", name != ".localized" else { continue }
                // First matching rule wins: skip paths a more specific rule owns.
                guard let owning = Safety.rule(for: path, in: catalog), owning.id == rule.id else { continue }
                seenPaths.insert(path)
                if Safety.isProtected(path) { continue }
                let url = URL(fileURLWithPath: path)
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
                let modified = vals?.contentModificationDate
                // Same quiet window as the safety check, so the dry run is exactly what a clean would do.
                if let m = modified, Date().timeIntervalSince(m) < Safety.quietWindow { continue }
                if let minAge = rule.minAgeDays {
                    let ref = vals?.addedToDirectoryDate ?? modified ?? Date()
                    if Date().timeIntervalSince(ref) < minAge * 86400 { continue }
                }
                let m = Sizer.measure(path)
                if m.bytes < 64 * 1024 { continue } // not worth anyone's attention
                if let minMB = rule.minSizeMB, Double(m.bytes) < minMB * 1_048_576 { continue }
                let c = Candidate(path: path, name: name, owner: ownerName(for: name), ruleID: rule.id,
                                  ruleTitle: rule.title, tier: rule.tier, category: rule.category, kind: rule.kind,
                                  bytes: m.bytes, modified: m.newest ?? modified, sharedBytes: m.shared)
                out.append(c)
                onFound?(c)
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    // MARK: clean / restore / purge

    struct CleanResult { var freed: Int64 = 0; var held: [HeldItem] = []; var refused: [(Candidate, String)] = [] }

    func clean(_ items: [Candidate], reason: String, uninstallContext: Bool = false, chosen: Bool = false) -> CleanResult {
        var result = CleanResult()
        let running = Safety.runningBundleIDs()
        let batch = UUID().uuidString
        let fm = FileManager.default
        for c in items {
            let why = chosen ? Safety.userRefusal(for: c.path, running: running)
                             : Safety.refusal(for: c, catalog: catalog, running: running, uninstallContext: uninstallContext)
            if let why {
                result.refused.append((c, why))
                continue
            }
            let id = UUID().uuidString
            let slot = TidalPaths.holding.appendingPathComponent(id, isDirectory: true)
            let dest = slot.appendingPathComponent(c.name)
            do {
                try fm.createDirectory(at: slot, withIntermediateDirectories: true)
                try fm.moveItem(atPath: c.path, toPath: dest.path) // same volume: an instant rename
                let h = HeldItem(id: id, original: c.path, stored: dest.path, name: c.name, owner: c.owner,
                                 ruleID: c.ruleID, category: c.category, bytes: c.bytes - c.sharedBytes,
                                 heldAt: Date(), batch: batch)
                db.addHeld(h)
                db.dequeue(c.path)
                result.held.append(h)
                result.freed += h.bytes
            } catch {
                try? fm.removeItem(at: slot) // only ever our own empty slot
                result.refused.append((c, error.localizedDescription))
                db.log("refuse", c.name, "macOS refused the move: \(error.localizedDescription)")
            }
        }
        // One readable line per reason instead of one per item; vanished items need no mention.
        // Background passes stay quiet about routine skips (busy apps, fresh files); they simply try again later.
        let background = ["Autopilot", "Scheduled pass", "Low free space", "Requested"].contains(reason)
        let routine: Set<String> = ["No longer exists", "In use by a running app", "Modified in the last 15 minutes"]
        let grouped = Dictionary(grouping: result.refused.filter { $0.1 != "No longer exists" && !(background && routine.contains($0.1)) }, by: { $0.1 })
        for (why, list) in grouped.sorted(by: { $0.key < $1.key }) {
            let names = list.prefix(4).map { $0.0.owner }.joined(separator: ", ") + (list.count > 4 ? " and \(list.count - 4) more" : "")
            db.log("refuse", "Skipped \(list.count) item\(list.count == 1 ? "" : "s"): \(why.lowercased())", names)
        }
        if !result.held.isEmpty {
            let names = result.held.prefix(3).map(\.owner).joined(separator: ", ")
            let more = result.held.count > 3 ? " and \(result.held.count - 3) more" : ""
            db.log("clean", "\(reason): \(result.held.count) item\(result.held.count == 1 ? "" : "s") moved to holding",
                   names + more, bytes: result.freed)
        }
        return result
    }

    @discardableResult
    func restore(_ h: HeldItem) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: h.original) { return "Something already exists at the original path" }
        do {
            try fm.createDirectory(atPath: (h.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: h.stored, toPath: h.original)
            try? fm.removeItem(atPath: (h.stored as NSString).deletingLastPathComponent)
            db.removeHeld(h.id)
            db.log("restore", "\(h.name) restored", TidalPaths.pretty(h.original), bytes: h.bytes)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Permanently removes held items. This is the only place Tidal deletes anything.
    @discardableResult
    func purge(expiredOnly: Bool) -> Int64 {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-holdDays * 86400)
        let holdRoot = Safety.real(TidalPaths.holding.path)
        var freed: Int64 = 0
        var count = 0
        for h in db.held() where !expiredOnly || h.heldAt < cutoff {
            let slot = (h.stored as NSString).deletingLastPathComponent
            guard Safety.real(slot).hasPrefix(holdRoot + "/") else { continue }
            if (try? fm.removeItem(atPath: slot)) != nil || !fm.fileExists(atPath: slot) {
                db.removeHeld(h.id)
                freed += h.bytes
                count += 1
            }
        }
        if count > 0 {
            let total = Int64(db.get(SettingKey.freedTotal) ?? "0") ?? 0
            db.set(SettingKey.freedTotal, String(total + freed))
            db.log("purge", expiredOnly ? "Holding period ended for \(count) item\(count == 1 ? "" : "s")"
                                        : "Holding area emptied", "", bytes: freed)
        }
        return freed
    }

    // MARK: autopilot

    struct PassResult { var found: [Candidate] = []; var clean = CleanResult(); var queued: [Candidate] = [] }

    /// Dry run, then clean Safe items whose category policy is auto; queue Review items.
    func pass(reason: String, autopilot: Bool) -> PassResult {
        var r = PassResult()
        r.found = discover()
        let auto = r.found.filter { $0.tier == .safe && db.policy($0.category) == .auto }
        let review = r.found.filter { c in
            c.tier == .review || (c.tier == .safe && db.policy(c.category) == .ask)
        }.filter { db.policy($0.category) != .never }
        if autopilot && !auto.isEmpty { r.clean = clean(auto, reason: reason) }
        for c in review { db.enqueue(c) }
        r.queued = review
        purge(expiredOnly: true)
        return r
    }

    // MARK: footprints (uninstall tracking)

    static let footprintTemplates: [(String, Tier)] = [
        ("~/Library/Caches/{id}", .safe), ("~/Library/Caches/{name}", .safe),
        ("~/Library/Logs/{id}", .safe), ("~/Library/Logs/{name}", .safe),
        ("~/Library/Saved Application State/{id}.savedState", .safe),
        ("~/Library/HTTPStorages/{id}", .safe), ("~/Library/HTTPStorages/{id}.binarycookies", .safe),
        ("~/Library/WebKit/{id}", .safe), ("~/Library/Cookies/{id}.binarycookies", .safe),
        ("~/Library/Preferences/{id}.plist", .safe),
        ("~/Library/Application Support/{id}", .review), ("~/Library/Application Support/{name}", .review),
        ("~/Library/Containers/{id}", .review), ("~/Library/Application Scripts/{id}", .review),
        ("~/Library/LaunchAgents/{id}.plist", .review),
    ]

    /// Every known per-app location for a bundle identifier / name. Only existing paths are returned.
    func footprint(bundleID: String, name: String, team: String?) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        let fm = FileManager.default
        var paths: [(String, Tier)] = Self.footprintTemplates.map { tpl, tier in
            (TidalPaths.expand(tpl)
                .replacingOccurrences(of: "{id}", with: bundleID)
                .replacingOccurrences(of: "{name}", with: name), tier)
        }
        // Group containers: matched by team prefix or by identifier.
        let gc = TidalPaths.expand("~/Library/Group Containers")
        for g in (try? fm.contentsOfDirectory(atPath: gc)) ?? [] {
            if g.contains(bundleID) || (team.map { !$0.isEmpty && g.hasPrefix($0 + ".") } ?? false) {
                paths.append((gc + "/" + g, .review))
            }
        }
        for (p, tier) in paths where !seen.contains(p) && fm.fileExists(atPath: p) {
            seen.insert(p)
            guard let rule = Safety.rule(for: p, in: catalog, uninstallContext: true), rule.tier != .never else { continue }
            let m = Sizer.measure(p)
            // Large Application Support folders might hold user content: always review.
            let effective: Tier = (tier == .safe && m.bytes < 500 * 1_048_576) ? .safe : .review
            out.append(Candidate(path: p, name: (p as NSString).lastPathComponent, owner: name, ruleID: rule.id,
                                 ruleTitle: rule.title, tier: effective, category: .apps, kind: "leftover",
                                 bytes: m.bytes, modified: m.newest, sharedBytes: m.shared))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    func refreshFootprint(bundleID: String, name: String, team: String?) {
        db.setFootprint(bundleID, footprint(bundleID: bundleID, name: name, team: team).map(\.path))
    }
}

// MARK: - Bundle reading

struct AppBundleInfo: Sendable {
    let bundleID: String
    let name: String
    let version: String
    let team: String
    let path: String

    init(bundleID: String, name: String, version: String, team: String, path: String) {
        self.bundleID = bundleID; self.name = name; self.version = version; self.team = team; self.path = path
    }

    init?(url: URL) {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        bundleID = id
        name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        version = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        team = AppBundleInfo.teamID(url) ?? ""
        path = url.path
    }

    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
