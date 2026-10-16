import SwiftUI
import AppKit
import ServiceManagement
import Observation

enum Place: String, CaseIterable, Identifiable {
    case now, map, activity
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .now: "drop"
        case .map: "circle.hexagongrid"
        case .activity: "clock"
        }
    }
}

enum ItemPhase: Equatable { case arriving, assessing, ready, lifting, gone }

enum AgentHealth: Equatable {
    case running, needsApproval, notRunning, unknown
    var title: String {
        switch self {
        case .running: "Agent running"
        case .needsApproval: "Agent needs approval"
        case .notRunning: "Agent not running"
        case .unknown: "Agent status unknown"
        }
    }
}

@MainActor
@Observable
final class Store {
    // Navigation
    var place: Place = .now
    var showSettings = false

    // Disk
    var volume = VolumeInfo.current()

    // Now
    var candidates: [Candidate] = []
    var phases: [String: ItemPhase] = [:]
    var selected: Set<String> = []
    var discovering = false
    var lastDiscover: Date?

    // Activity
    var activity: [ActivityEntry] = []
    var held: [HeldItem] = []
    var uninstalls: [UninstallEvent] = []

    // Map
    var nodes: [IndexNode] = []
    var indexing = false
    var indexProgress = ""

    // Agent & permissions
    var autopilot = false
    var agentHealth: AgentHealth = .unknown
    var agentState = "idle"
    var hasFDA = true
    var agentFDA = true
    var freedTotal: Int64 = 0
    var freedSession: Int64 = 0
    var policies: [SpaceCategory: Policy] = [:]
    var holdDays: Double = 14
    var windowVisible = true
    var toast: String?

    let db = Database.shared
    let engine = Engine()
    let indexer = SpaceIndexer()
    let particles = ParticleSystem()
    private let work = DispatchQueue(label: "tidal.ui.work", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private var reloadPending = false

    init() {
        autopilot = db.bool(SettingKey.autopilot, default: false)
        holdDays = db.double(SettingKey.holdDays, default: 14)
        for c in SpaceCategory.allCases { policies[c] = db.policy(c) }
        // Assemble from the previous state, never from blank.
        if let json = db.get("lastCandidates"), let prev = try? JSONDecoder().decode([Candidate].self, from: Data(json.utf8)) {
            candidates = prev.filter { FileManager.default.fileExists(atPath: $0.path) }
            for c in candidates { phases[c.id] = .ready }
            selected = Set(candidates.filter { isPreselected($0) }.map(\.id))
        }
        reloadFromDisk()
        observe()
        Task { await self.bootstrap() }
    }

    // MARK: bootstrap

    private func bootstrap() async {
        registerAgent()
        hasFDA = Safety.hasFullDiskAccess()
        if nodes.isEmpty {
            if agentHealth == .running { requestAgent("index"); indexing = true } else { reindex() }
        }
        discover()
        if CommandLine.arguments.contains("--screen"), let i = CommandLine.arguments.firstIndex(of: "--screen"),
           i + 1 < CommandLine.arguments.count, let p = Place(rawValue: CommandLine.arguments[i + 1]) {
            place = p
        }
    }

    static let launcherLabel = "app.tidal.mac.agent.launcher"
    var launcherPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Store.launcherLabel).plist")
    }
    var agentBinary: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TidalAgent.app/Contents/MacOS/TidalAgent").path
    }

    /// The agent runs as a per-user launch agent: started at login, restarted if it crashes, and
    /// started as soon as the disk holding Tidal is mounted. Listed in System Settings → Login Items.
    func registerAgent() {
        if readOnly { refreshAgentHealth(); return }
        // Retire the SMAppService login item: it cannot launch from a non-boot volume with an ad-hoc signature.
        let legacy = SMAppService.loginItem(identifier: TidalID.agent)
        if legacy.status == .enabled || legacy.status == .requiresApproval { Task { try? await legacy.unregister() } }

        let plist: [String: Any] = [
            "Label": Store.launcherLabel,
            "ProgramArguments": [agentBinary],
            "RunAtLoad": true,
            // Restart after a crash, and keep retrying until the disk holding Tidal is mounted.
            // A clean exit (Quit) stays quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 30,
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let existing = try? Data(contentsOf: launcherPlist)
        let changed = existing != data
        if changed, let data {
            try? FileManager.default.createDirectory(at: launcherPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: launcherPlist)
        }
        let domain = "gui/\(getuid())"
        let loaded = launchctl(["print", "\(domain)/\(Store.launcherLabel)"]) == 0
        if changed && loaded { _ = launchctl(["bootout", "\(domain)/\(Store.launcherLabel)"]) }
        if changed || !loaded {
            if launchctl(["bootstrap", domain, launcherPlist.path]) != 0 {
                db.log("note", "Could not load the background agent", "Check System Settings → Login Items → Allow in the Background")
            }
        }
        refreshAgentHealth()
        if agentHealth != .running { _ = launchctl(["kickstart", "\(domain)/\(Store.launcherLabel)"]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.refreshAgentHealth()
            if self.agentHealth != .running { self.launchAgentDirectly() }
        }
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    func launchAgentDirectly() {
        // Prefer launchd so there is never a second, unmanaged instance.
        let domain = "gui/\(getuid())"
        if FileManager.default.fileExists(atPath: launcherPlist.path) {
            if launchctl(["print", "\(domain)/\(Store.launcherLabel)"]) != 0 { launchctl(["bootstrap", domain, launcherPlist.path]) }
            if launchctl(["kickstart", "\(domain)/\(Store.launcherLabel)"]) == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshAgentHealth() }
                return
            }
        }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TidalAgent.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refreshAgentHealth() }
        }
    }

    func refreshAgentHealth() {
        let pid = Int32(db.get(SettingKey.agentPID) ?? "0") ?? 0
        let alive = pid > 0 && kill(pid, 0) == 0
        if alive { agentHealth = .running }
        else if FileManager.default.fileExists(atPath: launcherPlist.path),
                SMAppService.statusForLegacyPlist(at: launcherPlist) == .requiresApproval { agentHealth = .needsApproval }
        else { agentHealth = .notRunning }
        agentFDA = db.get("agentFDA").map { $0 == "1" } ?? true
    }

    // MARK: IPC

    private func observe() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: TidalID.changed, object: nil, queue: .main) { [weak self] n in
            let what = n.userInfo?["what"] as? String
            MainActor.assumeIsolated { self?.scheduleReload(indexToo: what == "index") }
        })
        observers.append(dnc.addObserver(forName: TidalID.state, object: nil, queue: .main) { [weak self] n in
            let s = n.userInfo?["state"] as? String ?? "idle"
            MainActor.assumeIsolated {
                self?.agentState = s
                if s != "working" { self?.indexing = false }
            }
        })
        observers.append(dnc.addObserver(forName: TidalID.uninstall, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                withAnimation(.smooth) { self?.place = .now }
                self?.scheduleReload(indexToo: false)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hasFDA = Safety.hasFullDiskAccess()
                self?.refreshAgentHealth()
                self?.volume = VolumeInfo.current()
            }
        })
    }

    func requestAgent(_ cmd: String) {
        DistributedNotificationCenter.default().postNotificationName(TidalID.request, object: nil, userInfo: ["cmd": cmd], deliverImmediately: true)
    }

    private func broadcastChange(_ what: String) {
        DistributedNotificationCenter.default().postNotificationName(TidalID.changed, object: nil, userInfo: ["what": what, "from": "ui"], deliverImmediately: true)
    }

    private func scheduleReload(indexToo: Bool) {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.reloadPending = false
            self.reloadFromDisk(nodesToo: indexToo || self.nodes.isEmpty)
        }
    }

    func reloadFromDisk(nodesToo: Bool = true) {
        activity = db.activity()
        held = db.held()
        uninstalls = db.uninstalls()
        freedTotal = Int64(db.get(SettingKey.freedTotal) ?? "0") ?? 0
        autopilot = db.bool(SettingKey.autopilot, default: false)
        volume = VolumeInfo.current()
        // Review items the agent queued in the background join the stream.
        for q in db.queue() where !candidates.contains(where: { $0.path == q.path }) && FileManager.default.fileExists(atPath: q.path) {
            candidates.append(q)
            phases[q.id] = .ready
        }
        if nodesToo { nodes = indexer.nodes() }
        refreshAgentHealth()
    }

    // MARK: discovery (dry run)

    func isPreselected(_ c: Candidate) -> Bool {
        c.tier == .safe && (policies[c.category] ?? .ask) != .never
    }

    var pendingUninstalls: [UninstallEvent] { uninstalls.filter { $0.state == "pending" && !$0.leftovers.isEmpty } }
    var leftoverPaths: Set<String> { Set(pendingUninstalls.flatMap { $0.leftovers.map(\.path) }) }

    func discover() {
        guard !discovering else { return }
        discovering = true
        deferred.removeAll()
        let known = Set(candidates.map(\.id))
        let engine = self.engine
        work.async {
            let found = engine.discover { c in
                Task { @MainActor in
                    guard !self.candidates.contains(where: { $0.id == c.id }) else { return }
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
                        self.candidates.append(c)
                        self.phases[c.id] = .arriving
                    }
                    self.assess(c)
                }
            }
            Task { @MainActor in
                let foundIDs = Set(found.map(\.id))
                let queued = Set(self.db.queue().map(\.id))
                withAnimation(.smooth) {
                    // Drop what no longer exists or no longer qualifies; keep fresh sizes.
                    self.candidates = self.candidates.compactMap { old in
                        guard FileManager.default.fileExists(atPath: old.path) else { return nil }
                        if let f = found.first(where: { $0.id == old.id }) { return f }
                        return queued.contains(old.id) ? old : nil
                    }
                    for c in self.candidates where !known.contains(c.id) && self.isPreselected(c) { self.selected.insert(c.id) }
                    self.selected = self.selected.filter { id in self.candidates.contains { $0.id == id } }
                }
                for id in known where !foundIDs.contains(id) && !queued.contains(id) { self.phases[id] = nil }
                self.discovering = false
                self.lastDiscover = Date()
                if let d = try? JSONEncoder().encode(found) { self.db.set("lastCandidates", String(decoding: d, as: UTF8.self)) }
                if self.autopilot { self.runAutopilot() }
            }
        }
    }

    /// Visible assessment: each item arrives, is assessed, then settles with its tier.
    private func assess(_ c: Candidate) {
        let delay = Double(phases.values.filter { $0 == .assessing || $0 == .arriving }.count) * 0.09
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + delay) {
            withAnimation(.smooth(duration: 0.3)) { self.phases[c.id] = .assessing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    self.phases[c.id] = .ready
                    if self.isPreselected(c) { self.selected.insert(c.id) }
                }
            }
        }
    }

    // MARK: cleaning choreography: assess, lift, dissolve, count

    /// Items macOS or the safety check turned down; Autopilot leaves them alone until the next look.
    @ObservationIgnored var deferred: Set<String> = []

    var autopilotQueue: [Candidate] {
        candidates.filter { $0.tier == .safe && (policies[$0.category] ?? .ask) == .auto && !leftoverPaths.contains($0.path) && !deferred.contains($0.id) }
    }

    /// Design-QA snapshot runs are strictly read-only.
    var readOnly: Bool { ProcessInfo.processInfo.environment["TIDAL_SNAPSHOT"] != nil }

    func runAutopilot() {
        guard !readOnly else { return }
        let items = autopilotQueue
        guard !items.isEmpty else { return }
        clean(items, reason: "Autopilot")
    }

    /// `origins` are global frames of the items on screen, for the particle flight.
    func clean(_ items: [Candidate], reason: String, origins: [String: CGRect] = [:], uninstallContext: Bool = false, chosen: Bool = false) {
        let items = items.filter { phases[$0.id] != .lifting && phases[$0.id] != .gone }
        guard !items.isEmpty, !readOnly else { return }
        for (i, c) in items.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self.phases[c.id] = .lifting }
            }
        }
        let engine = self.engine
        work.async {
            let r = engine.clean(items, reason: reason, uninstallContext: uninstallContext, chosen: chosen)
            Task { @MainActor in
                let cleaned = Set(r.held.map(\.original))
                self.deferred.formUnion(r.refused.map { $0.0.id })
                let vanished = Set(r.refused.filter { $0.1 == "No longer exists" }.map { $0.0.id })
                for (i, c) in items.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.07) {
                        if cleaned.contains(c.path) {
                            if let rect = origins[c.id] ?? self.particles.frames[c.id] {
                                self.particles.burst(from: rect, color: Theme.color(c.category), bytes: c.bytes)
                            }
                            withAnimation(.smooth(duration: 0.45)) { self.phases[c.id] = .gone }
                        } else {
                            withAnimation(.spring) { self.phases[c.id] = .ready }
                        }
                    }
                }
                let tail = 0.25 + Double(items.count) * 0.07 + 0.55
                DispatchQueue.main.asyncAfter(deadline: .now() + tail) {
                    withAnimation(.smooth) {
                        self.candidates.removeAll { cleaned.contains($0.path) || vanished.contains($0.id) }
                        self.selected.subtract(cleaned)
                        self.freedSession += r.freed
                    }
                    for p in cleaned { self.phases[p] = nil }
                    self.reloadFromDisk(nodesToo: false)
                    self.nodes = self.nodes.map { n in
                        var n = n
                        for h in r.held where h.original == n.path || h.original.hasPrefix(n.path + "/") { n.bytes = max(0, n.bytes - h.bytes) }
                        return n
                    }.filter { n in !cleaned.contains(n.path) && !cleaned.contains { n.path.hasPrefix($0 + "/") } }
                    if let d = try? JSONEncoder().encode(self.candidates) { self.db.set("lastCandidates", String(decoding: d, as: UTF8.self)) }
                    self.broadcastChange("clean")
                    self.requestAgent("attention")
                }
                if r.freed > 0 { Haptics.clean() }
                let meaningful = r.refused.filter { $0.1 != "No longer exists" }
                if !meaningful.isEmpty && reason != "Autopilot" {
                    self.flash(meaningful.count == 1 ? "Skipped \(meaningful[0].0.owner): \(meaningful[0].1.lowercased())"
                                                     : "Skipped \(meaningful.count) items — see Activity")
                }
            }
        }
    }

    func cleanSelected(origins: [String: CGRect] = [:]) {
        clean(candidates.filter { selected.contains($0.id) && !leftoverPaths.contains($0.path) }, reason: "Manual clean", origins: origins)
    }

    /// Everything a map bubble stands for, as items the person chose by hand.
    func chosenTargets(for item: MapItem) -> [Candidate] {
        if item.locked || item.id.hasPrefix("cat:") || item.id.hasPrefix("#") { return [] }
        var paths: [(String, String, Int64)] = []
        if item.id.hasPrefix("app:") {
            paths = item.children.compactMap { c in c.path.map { ($0, c.name, c.bytes) } }
        } else if let p = item.path {
            paths = [(p, item.name, item.bytes)]
        }
        return paths.map { p, name, bytes in
            Candidate(path: p, name: (p as NSString).lastPathComponent, owner: item.name, ruleID: "user.choice",
                      ruleTitle: "Chosen on the map", tier: .review, category: item.category, kind: "chosen",
                      bytes: bytes, modified: nil)
        }
    }

    func deleteChosen(_ item: MapItem, origin: CGRect? = nil) {
        let targets = chosenTargets(for: item)
        guard !targets.isEmpty else { flash("\(item.name) can't be removed from here"); return }
        if let origin { for t in targets { particles.frames[t.id] = origin } }
        clean(targets, reason: "Removed from the map", origins: origin.map { o in Dictionary(uniqueKeysWithValues: targets.map { ($0.id, o) }) } ?? [:], chosen: true)
    }

    func hold(_ c: Candidate) {
        withAnimation(.smooth) {
            selected.remove(c.id)
            candidates.removeAll { $0.id == c.id }
        }
        db.dequeue(c.path)
        db.log("note", "Held back \(c.owner)", TidalPaths.pretty(c.path), bytes: c.bytes)
        Haptics.snap()
    }

    func toggle(_ c: Candidate) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
        }
        Haptics.snap()
    }

    // MARK: uninstall leftovers

    func cleanLeftovers(_ u: UninstallEvent, origins: [String: CGRect] = [:]) {
        clean(u.leftovers, reason: "\(u.name) leftovers", origins: origins, uninstallContext: true)
        var e = u; e.state = "cleaned"; e.leftovers = []
        db.save(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.reloadFromDisk(nodesToo: false); self.requestAgent("attention") }
    }

    func keepLeftovers(_ u: UninstallEvent) {
        var e = u; e.state = "kept"
        db.save(e)
        db.log("note", "Kept \(u.name)'s leftovers", "")
        withAnimation(.smooth) { reloadFromDisk(nodesToo: false) }
        requestAgent("attention")
    }

    // MARK: holding area

    func restore(_ h: HeldItem) {
        if let err = engine.restore(h) { flash("Couldn't restore \(h.name): \(err)"); return }
        Haptics.undo()
        withAnimation(.smooth) { reloadFromDisk(nodesToo: false) }
        freedSession = max(0, freedSession - h.bytes)
        broadcastChange("restore")
        discover()
    }

    func restoreBatch(_ batch: String) {
        for h in held where h.batch == batch { _ = engine.restore(h) }
        Haptics.undo()
        withAnimation(.smooth) { reloadFromDisk(nodesToo: false) }
        discover()
    }

    func emptyHolding() {
        let engine = self.engine
        work.async {
            let freed = engine.purge(expiredOnly: false)
            Task { @MainActor in
                withAnimation(.smooth) { self.reloadFromDisk(nodesToo: false) }
                self.flash("\(Fmt.bytes(freed)) reclaimed")
                self.broadcastChange("purge")
            }
        }
    }

    var heldBytes: Int64 { held.reduce(0) { $0 + $1.bytes } }

    // MARK: settings

    func setAutopilot(_ on: Bool) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { autopilot = on }
        db.setBool(SettingKey.autopilot, on)
        db.log("note", on ? "Autopilot turned on" : "Switched to Manual", "")
        requestAgent("settings")
        Haptics.snap()
        if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.runAutopilot() } }
    }

    func setPolicy(_ c: SpaceCategory, _ p: Policy) {
        policies[c] = p
        db.set(SettingKey.policy(c), p.rawValue)
        requestAgent("settings")
    }

    func setHoldDays(_ d: Double) {
        holdDays = d
        db.set(SettingKey.holdDays, String(d))
    }

    // MARK: index

    func reindex() {
        if agentHealth == .running { requestAgent("index"); indexing = true; return }
        guard !indexing else { return }
        indexing = true
        let indexer = self.indexer
        work.async {
            indexer.indexAll { root in
                Task { @MainActor in
                    self.indexProgress = TidalPaths.pretty(root)
                    self.nodes = indexer.nodes()
                }
            }
            Task { @MainActor in
                self.indexing = false
                self.indexProgress = ""
                withAnimation(.smooth) { self.nodes = indexer.nodes() }
            }
        }
    }

    // MARK: system settings deep links

    func openFullDiskAccess() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func flash(_ s: String) {
        withAnimation(.smooth) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { withAnimation(.smooth) { if self.toast == s { self.toast = nil } } }
    }

    func reveal(_ path: String) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
}
