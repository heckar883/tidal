import AppKit
import CoreServices
import SwiftUI

/// The always-on background service. Event-driven only: between FSEvents callbacks, workspace
/// notifications and scheduler wake-ups it is asleep. It never polls and never draws animation loops.
final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let db = Database.shared
    lazy var engine = Engine(db: db)
    lazy var indexer = SpaceIndexer(db: db)

    private var statusItem: NSStatusItem!
    private var homeStream: FSEventStreamRef?
    private var appStream: FSEventStreamRef?
    private let work = DispatchQueue(label: "tidal.agent.work", qos: .background)
    private var scheduler: NSBackgroundActivityScheduler?
    private var dirty = Set<String>()
    private var pendingUninstalls: [String: DispatchWorkItem] = [:]
    private var lastLowSpacePass = Date.distantPast
    private var card: UninstallPanel?
    private var busy = false { didSet { updateIcon() } }

    enum State: String { case idle, working, attention }
    private var state: State = .idle { didSet { updateIcon(); broadcastState() } }

    var autopilot: Bool { db.bool(SettingKey.autopilot, default: false) }
    var autoUninstall: Bool { db.bool(SettingKey.autoUninstall, default: true) }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        // Single instance: if another agent is alive, step aside.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: TidalID.agent)
            .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            db.set(SettingKey.agentPID, String(other.processIdentifier))
            exit(0)
        }
        db.set(SettingKey.agentPID, String(getpid()))
        db.set("agentFDA", Safety.hasFullDiskAccess() ? "1" : "0")
        setupStatusItem()
        startStreams()
        observeWorkspace()
        observeRequests()
        schedule()
        refreshAttention()
        work.async { self.reconcileApps() }
        if db.get("indexComplete") != "1" {
            // First index build: incremental and low priority; the map fills in as it goes.
            runIndex(dirty: nil)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        persistEventID()
        db.set(SettingKey.agentPID, "0")
    }

    // MARK: FSEvents

    private func startStreams() {
        let home = TidalPaths.home.path
        let since = UInt64(db.get(SettingKey.lastEventID) ?? "") ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)

        // Directory-level, coalesced, replayed from the journal after sleep, reboot or crash.
        homeStream = FSEventStreamCreate(nil, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<Agent>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.homeEvents(arr, flags: Array(UnsafeBufferPointer(start: flags, count: count)), lastID: ids[count - 1])
        }, &ctx, [home, "/Applications"] as CFArray, since, 30.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
        if let s = homeStream {
            FSEventStreamSetDispatchQueue(s, work)
            FSEventStreamStart(s)
        }

        // File-level, low latency: the Applications folders and the Trash, for uninstall detection.
        var actx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let watch = ["/Applications", home + "/Applications", home + "/.Trash"].filter { FileManager.default.fileExists(atPath: $0) }
        appStream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<Agent>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.bundleEvents(arr, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }, &actx, watch as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        if let s = appStream {
            FSEventStreamSetDispatchQueue(s, work)
            FSEventStreamStart(s)
        }
    }

    private func homeEvents(_ paths: [String], flags: [FSEventStreamEventFlags], lastID: FSEventStreamEventId) {
        let home = TidalPaths.home.path
        let support = TidalPaths.support.path
        for (p, f) in zip(paths, flags) {
            if p.hasPrefix(support) { continue } // our own index writes
            if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                dirty.insert(home)
            }
            if p.hasPrefix("/Applications") { dirty.insert("/Applications"); continue }
            guard p.hasPrefix(home + "/") else { continue }
            let first = p.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if !first.isEmpty { dirty.insert(home + "/" + first) }
        }
        db.set(SettingKey.lastEventID, String(lastID))
        db.set("dirty", dirty.sorted().joined(separator: "\n"))
        checkFreeSpace()
    }

    private func persistEventID() {
        if let s = homeStream { db.set(SettingKey.lastEventID, String(FSEventStreamGetLatestEventId(s))) }
    }

    private func checkFreeSpace() {
        let v = VolumeInfo.current()
        let threshold = Int64(db.double(SettingKey.freeThresholdGB, default: 20) * 1_000_000_000)
        guard v.importantAvailable < threshold, Date().timeIntervalSince(lastLowSpacePass) > 3600 else { return }
        lastLowSpacePass = Date()
        db.log("note", "Free space fell below \(Fmt.bytes(threshold))", "Starting a low-priority pass")
        runPass(reason: "Low free space")
    }

    // MARK: uninstall detection

    private func bundleEvents(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        let home = TidalPaths.home.path
        for (p, f) in zip(paths, flags) {
            guard p.hasSuffix(".app") else { continue }
            let inTrash = p.hasPrefix(home + "/.Trash/")
            let removed = f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
            let renamed = f & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            let created = f & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let exists = FileManager.default.fileExists(atPath: p)
            if !inTrash && exists && (created || renamed) && (p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/")) {
                // A new or updated app: learn its identity now so a later removal is recognised.
                work.async { self.learn(URL(fileURLWithPath: p)) }
            }
            if inTrash && exists && (renamed || created) {
                // The bundle is still intact in the Trash: read its identity directly.
                if let info = AppBundleInfo(url: URL(fileURLWithPath: p)) { considerUninstall(info, trashPath: p) }
            } else if !inTrash && !exists && (removed || renamed) {
                // Gone from Applications. Use what we learned earlier.
                if let known = db.knownApps().first(where: { $0.path == p }) {
                    let info = AppBundleInfo.synthetic(bundleID: known.id, name: known.name, path: p)
                    considerUninstall(info, trashPath: nil)
                }
            }
        }
    }

    private func learn(_ url: URL) {
        guard let info = AppBundleInfo(url: url) else { return }
        db.recordApp(bundleID: info.bundleID, name: info.name, path: info.path, version: info.version, team: info.team)
        engine.refreshFootprint(bundleID: info.bundleID, name: info.name, team: info.team)
    }

    /// Makes uninstall detection independent of live events: learns every installed app, then looks for apps that
    /// vanished or sit in the Trash while the agent wasn't watching (reboot, crash, no Full Disk Access for the Trash).
    private func reconcileApps() {
        let fm = FileManager.default
        let home = TidalPaths.home.path
        let roots = ["/Applications", home + "/Applications"]
        var present = Set<String>()
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                present.insert(path)
                if !db.knownApps().contains(where: { $0.path == path }) { learn(URL(fileURLWithPath: path)) }
            }
        }
        for (id, name, path, _) in db.knownApps() where roots.contains(where: { path.hasPrefix($0 + "/") }) && !present.contains(path) {
            considerUninstall(AppBundleInfo.synthetic(bundleID: id, name: name, path: path), trashPath: nil)
        }
        for name in (try? fm.contentsOfDirectory(atPath: home + "/.Trash")) ?? [] where name.hasSuffix(".app") {
            let p = home + "/.Trash/" + name
            if let info = AppBundleInfo(url: URL(fileURLWithPath: p)), !db.uninstalls().contains(where: { $0.bundleID == info.bundleID }) {
                considerUninstall(info, trashPath: p)
            }
        }
    }

    /// Updates, reinstalls and moves also remove a bundle, so wait out a grace period and confirm.
    private func considerUninstall(_ info: AppBundleInfo, trashPath: String?) {
        pendingUninstalls[info.bundleID]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.confirmUninstall(info, trashPath: trashPath) }
        pendingUninstalls[info.bundleID] = item
        work.asyncAfter(deadline: .now() + 12, execute: item)
    }

    private func confirmUninstall(_ info: AppBundleInfo, trashPath: String?) {
        pendingUninstalls[info.bundleID] = nil
        if let t = trashPath, !FileManager.default.fileExists(atPath: t) {
            // Dragged back out of the Trash, or emptied: only proceed if it is not installed anywhere.
            if stillInstalled(info) { return }
        }
        if stillInstalled(info) { return }
        if db.uninstalls().contains(where: { $0.bundleID == info.bundleID && Date().timeIntervalSince($0.at) < 600 }) { return }

        let known = db.appName(info.bundleID) != nil
        db.retireApp(info.bundleID)
        let team = info.team.isEmpty ? nil : info.team
        var leftovers = engine.footprint(bundleID: info.bundleID, name: info.name, team: team)
        guard !leftovers.isEmpty else {
            db.log("uninstall", "\(info.name) was removed", "Nothing was left behind")
            return
        }
        // Package-installed apps: everything goes to review, nothing is automatic.
        let fromPackage = installedByPackage(info.bundleID)
        if !autoUninstall && (fromPackage || !known) { leftovers = leftovers.map { var c = $0; c = c.retiered(.review); return c } }

        var autoCleaned: Int64 = 0
        var remaining = leftovers
        if autoUninstall || autopilot {
            // Everything this app owns goes to holding (restorable). Containers shared by team prefix are left for review,
            // because other apps from the same developer may still use them.
            let mine = leftovers.filter { c in
                autoUninstall ? !(c.path.contains("/Group Containers/") && !c.name.contains(info.bundleID)) : c.tier == .safe
            }
            let r = engine.clean(mine, reason: "\(info.name) uninstalled", uninstallContext: true)
            autoCleaned = r.freed
            let cleanedPaths = Set(r.held.map(\.original))
            remaining = leftovers.filter { !cleanedPaths.contains($0.path) }
        }
        let event = UninstallEvent(id: UUID().uuidString, bundleID: info.bundleID, name: info.name, at: Date(),
                                   autoCleaned: autoCleaned, leftovers: remaining,
                                   state: remaining.isEmpty ? "cleaned" : "pending", confident: known && !fromPackage)
        db.save(event)
        let total = leftovers.reduce(0) { $0 + $1.bytes }
        db.log("uninstall", "\(info.name) is gone", "\(Fmt.bytes(total)) left behind" + (autoCleaned > 0 ? ", \(Fmt.bytes(autoCleaned)) cleaned automatically" : ""), bytes: total)
        DistributedNotificationCenter.default().postNotificationName(TidalID.uninstall, object: nil, userInfo: ["id": event.id], deliverImmediately: true)
        notifyChanged("uninstall")
        DispatchQueue.main.async {
            self.refreshAttention()
            self.showCard(event, appIcon: trashPath.map { NSWorkspace.shared.icon(forFile: $0) })
        }
    }

    private func stillInstalled(_ info: AppBundleInfo) -> Bool {
        let home = TidalPaths.home.path
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: info.bundleID)
        if urls.contains(where: { !$0.path.hasPrefix(home + "/.Trash") && FileManager.default.fileExists(atPath: $0.path) }) { return true }
        let name = (info.path as NSString).lastPathComponent
        return ["/Applications/" + name, home + "/Applications/" + name].contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func installedByPackage(_ bundleID: String) -> Bool {
        let vendor = bundleID.split(separator: ".").prefix(2).joined(separator: ".")
        guard vendor.contains(".") else { return false }
        let receipts = (try? FileManager.default.contentsOfDirectory(atPath: "/var/db/receipts")) ?? []
        return receipts.contains { $0.hasPrefix(vendor) && $0.hasSuffix(".bom") }
    }

    // MARK: learning footprints on launch

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let url = app.bundleURL, url.pathExtension == "app",
                  !url.path.hasPrefix("/System/") else { return }
            self.work.async {
                guard let info = AppBundleInfo(url: url) else { return }
                self.db.recordApp(bundleID: info.bundleID, name: info.name, path: info.path, version: info.version, team: info.team)
                self.engine.refreshFootprint(bundleID: info.bundleID, name: info.name, team: info.team)
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.work.async { self?.db.set("agentFDA", Safety.hasFullDiskAccess() ? "1" : "0") }
        }
    }

    // MARK: scheduling

    private func schedule() {
        let s = NSBackgroundActivityScheduler(identifier: TidalID.agent + ".pass")
        s.repeats = true
        s.interval = 6 * 3600
        s.tolerance = 2 * 3600
        s.qualityOfService = .background
        s.schedule { [weak self] done in
            guard let self else { return done(.finished) }
            // macOS picks the moment: deferred on battery, Low Power Mode, thermal pressure or user activity.
            if s.shouldDefer { return done(.deferred) }
            self.work.async {
                self.passNow(reason: "Scheduled pass")
                let d = self.dirty
                self.dirty.removeAll()
                if !d.isEmpty { self.indexNow(dirty: d) }
                done(.finished)
            }
        }
        scheduler = s
    }

    func runPass(reason: String) { work.async { self.passNow(reason: reason) } }
    func runIndex(dirty: Set<String>?) { work.async { self.indexNow(dirty: dirty) } }

    private func passNow(reason: String) {
        DispatchQueue.main.async { self.state = .working }
        db.set("agentFDA", Safety.hasFullDiskAccess() ? "1" : "0")
        let r = engine.pass(reason: reason, autopilot: autopilot)
        db.set("lastPass", String(Date().timeIntervalSince1970))
        if r.clean.freed > 0 || !r.queued.isEmpty { notifyChanged("pass") }
        if r.found.isEmpty { db.log("scan", "\(reason): nothing to do", "") }
        DispatchQueue.main.async { self.refreshAttention() }
    }

    private func indexNow(dirty: Set<String>?) {
        DispatchQueue.main.async { self.state = .working }
        indexer.indexAll(dirty: dirty)
        notifyChanged("index")
        DispatchQueue.main.async { self.refreshAttention() }
    }

    // MARK: IPC

    private func observeRequests() {
        DistributedNotificationCenter.default().addObserver(forName: TidalID.request, object: nil, queue: .main) { [weak self] n in
            guard let self, let cmd = n.userInfo?["cmd"] as? String else { return }
            switch cmd {
            case "pass": self.runPass(reason: "Requested")
            case "index": self.runIndex(dirty: nil)
            case "settings": self.updateIcon()
            case "attention": self.refreshAttention()
            case "ping": self.broadcastState()
            case "quit": self.quit()
            default: break
            }
        }
    }

    private func notifyChanged(_ what: String) {
        DistributedNotificationCenter.default().postNotificationName(TidalID.changed, object: nil, userInfo: ["what": what], deliverImmediately: true)
    }

    private func broadcastState() {
        DistributedNotificationCenter.default().postNotificationName(TidalID.state, object: nil, userInfo: ["state": state.rawValue], deliverImmediately: true)
    }

    private func refreshAttention() {
        let pending = db.uninstalls().contains { $0.state == "pending" }
        state = pending ? .attention : .idle
    }

    // MARK: menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        switch state {
        case .idle: name = "drop"
        case .working: name = "drop.halffull"
        case .attention: name = "drop.fill"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = (NSImage(systemSymbolName: name, accessibilityDescription: "Tidal") ?? NSImage(systemSymbolName: "drop", accessibilityDescription: "Tidal"))?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        button.image = img
        button.toolTip = "Tidal — \(state == .idle ? "watching quietly" : state == .working ? "working" : "something needs a look")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let headline: String
        switch state {
        case .idle: headline = autopilot ? "Watching quietly · Autopilot" : "Watching quietly · Manual"
        case .working: headline = "Working in the background…"
        case .attention: headline = "Leftovers are waiting for review"
        }
        let h = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        let freed = Int64(db.get(SettingKey.freedTotal) ?? "0") ?? 0
        if freed > 0 {
            let f = NSMenuItem(title: "Freed so far: \(Fmt.bytes(freed))", action: nil, keyEquivalent: "")
            f.isEnabled = false
            menu.addItem(f)
        }
        let v = VolumeInfo.current()
        let free = NSMenuItem(title: "\(Fmt.bytes(v.importantAvailable)) available on \(v.name)", action: nil, keyEquivalent: "")
        free.isEnabled = false
        menu.addItem(free)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Tidal", action: #selector(openApp), keyEquivalent: "o").target = self
        let ap = NSMenuItem(title: "Autopilot", action: #selector(toggleAutopilot), keyEquivalent: "")
        ap.target = self
        ap.state = autopilot ? .on : .off
        menu.addItem(ap)
        menu.addItem(withTitle: "Run a Pass Now", action: #selector(passFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tidal Agent", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func openApp() { Agent.openInterface() }
    @objc func toggleAutopilot() {
        db.setBool(SettingKey.autopilot, !autopilot)
        db.log("note", autopilot ? "Autopilot turned on" : "Switched to Manual", "From the menu bar")
        notifyChanged("settings")
    }
    @objc func passFromMenu() { runPass(reason: "Manual pass") }
    /// Quitting must stick: take the job out of launchd first, otherwise it is restarted.
    @objc func quit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/app.tidal.mac.agent.launcher"]
        try? p.run() // launchd ends this process as part of the bootout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    static func openInterface(screen: String? = nil) {
        // Agent lives at Tidal.app/Contents/Library/LoginItems/TidalAgent.app
        var url = Bundle.main.bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        if url.pathExtension != "app" { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TidalID.app) ?? url }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let screen { cfg.arguments = ["--screen", screen] }
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    // MARK: uninstall moment

    private func showCard(_ event: UninstallEvent, appIcon: NSImage?) {
        card?.close()
        card = UninstallPanel(event: event, icon: appIcon) { [weak self] action in
            guard let self else { return }
            switch action {
            case .review: Agent.openInterface(screen: "now")
            case .keep:
                var e = event; e.state = "kept"; self.db.save(e)
                self.db.log("note", "Kept \(event.name)'s leftovers", "")
                self.notifyChanged("uninstall"); self.refreshAttention()
            case .clean:
                self.work.async {
                    let r = self.engine.clean(event.leftovers, reason: "\(event.name) leftovers", uninstallContext: true)
                    var e = event; e.state = "cleaned"; e.autoCleaned += r.freed; e.leftovers = []
                    self.db.save(e)
                    self.notifyChanged("uninstall")
                    DispatchQueue.main.async { self.refreshAttention() }
                }
            }
            self.card = nil
        }
        card?.present(near: statusItem.button?.window?.frame)
    }
}

extension Candidate {
    func retiered(_ t: Tier) -> Candidate {
        Candidate(path: path, name: name, owner: owner, ruleID: ruleID, ruleTitle: ruleTitle, tier: t, category: category,
                  kind: kind, bytes: bytes, modified: modified, sharedBytes: sharedBytes)
    }
}

extension AppBundleInfo {
    static func synthetic(bundleID: String, name: String, path: String) -> AppBundleInfo {
        AppBundleInfo(bundleID: bundleID, name: name, version: "", team: "", path: path)
    }
}
