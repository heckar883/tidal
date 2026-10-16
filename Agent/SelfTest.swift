import Foundation

/// Exercises the dry run, the safety choke point, the holding area and footprints against a fixture.
/// Refuses to run unless TIDAL_HOME points somewhere other than the real home folder.
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
        if !ok { failures += 1 }
    }

    static func run() {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        guard ProcessInfo.processInfo.environment["TIDAL_HOME"] != nil, TidalPaths.home.path != realHome,
              TidalPaths.support.path.hasPrefix(TidalPaths.home.path) else {
            print("selftest: set TIDAL_HOME and TIDAL_SUPPORT (inside it) to a fixture directory"); exit(2)
        }
        let fm = FileManager.default
        let h = TidalPaths.home.path
        let old = Date().addingTimeInterval(-40 * 86400)
        func make(_ rel: String, bytes: Int = 300_000, age: Date? = old) {
            let p = h + "/" + rel
            try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: p, contents: Data(count: bytes))
            if let age {
                try? fm.setAttributes([.modificationDate: age], ofItemAtPath: p)
                try? fm.setAttributes([.modificationDate: age], ofItemAtPath: (p as NSString).deletingLastPathComponent)
            }
        }
        make("Library/Caches/com.example.foo/blob.bin")
        make("Library/Caches/com.example.fresh/blob.bin", age: nil)
        make("Library/Caches/com.apple.Something/blob.bin", bytes: 60_000_000)
        make("Library/Logs/ExampleApp/log.txt")
        make("Library/Developer/Xcode/DerivedData/Proj-abc/build.o", bytes: 2_000_000)
        make("Documents/secret.txt")
        make("Library/Application Support/com.example.foo/data.db")
        make("Library/Preferences/com.example.foo.plist", bytes: 70_000)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: h + "/Library/Developer/Xcode/DerivedData/Proj-abc")
        try? fm.createSymbolicLink(atPath: h + "/Library/Caches/sneaky", withDestinationPath: h + "/Documents")
        TidalPaths.ensure()

        let db = Database.shared
        let engine = Engine(db: db)
        print("catalog v\(engine.catalog.version), \(engine.catalog.rules.count) rules")
        check(!engine.catalog.rules.isEmpty, "catalog loaded")

        print("dry run")
        let found = engine.discover()
        for c in found { print("    \(c.tier.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(Fmt.bytes(c.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(TidalPaths.pretty(c.path))  [\(c.ruleID)]") }
        let paths = Set(found.map { TidalPaths.pretty($0.path) })
        check(paths.contains("~/Library/Caches/com.example.foo"), "app cache found as Safe")
        check(found.first { $0.name == "com.apple.Something" }?.tier == .review, "Apple cache offered as Review")
        check(paths.contains("~/Library/Developer/Xcode/DerivedData/Proj-abc"), "derived data found")
        check(!paths.contains { $0.hasPrefix("~/Documents") }, "Documents never listed")
        check(!paths.contains { $0.hasSuffix("sneaky") }, "symlink not listed")
        check(!paths.contains { $0.contains("Application Support") }, "Application Support not touched outside uninstall")
        check(!paths.contains { $0.contains("com.example.fresh") }, "recently modified item left out of the dry run")

        print("safety")
        let forged = Candidate(path: h + "/Documents/secret.txt", name: "secret.txt", owner: "", ruleID: "caches.user",
                               ruleTitle: "", tier: .safe, category: .apps, kind: "cache", bytes: 1, modified: nil)
        check(Safety.refusal(for: forged, catalog: engine.catalog, running: []) != nil, "forged Documents path refused")
        let link = Candidate(path: h + "/Library/Caches/sneaky", name: "sneaky", owner: "", ruleID: "caches.user",
                             ruleTitle: "", tier: .safe, category: .apps, kind: "cache", bytes: 1, modified: nil)
        check(Safety.refusal(for: link, catalog: engine.catalog, running: [])?.contains("symbolic") == true, "symlink refused")
        let fresh = Candidate(path: h + "/Library/Caches/com.example.fresh", name: "com.example.fresh", owner: "", ruleID: "caches.user",
                              ruleTitle: "", tier: .safe, category: .apps, kind: "cache", bytes: 1, modified: nil)
        check(Safety.refusal(for: fresh, catalog: engine.catalog, running: [])?.contains("15 minutes") == true, "recently modified refused")
        let inUse = found.first { $0.name == "com.example.foo" }!
        check(Safety.refusal(for: inUse, catalog: engine.catalog, running: ["com.example.foo"])?.contains("running") == true, "in-use refused")

        print("clean → holding → restore")
        let safe = found.filter { $0.tier == .safe }
        let r = engine.clean(safe, reason: "Self-test")
        check(r.held.count >= 2, "\(r.held.count) items moved to holding, \(Fmt.bytes(r.freed)) freed")
        check(!fm.fileExists(atPath: h + "/Library/Caches/com.example.foo"), "original location vacated")
        check(fm.fileExists(atPath: h + "/Documents/secret.txt"), "documents untouched")
        if let item = db.held().first(where: { $0.name == "com.example.foo" }) {
            check(engine.restore(item) == nil, "restore succeeded")
            check(fm.fileExists(atPath: h + "/Library/Caches/com.example.foo/blob.bin"), "restored to exact original path")
        } else { check(false, "held item recorded") }
        for item in db.held() { engine.restore(item) }
        check(db.held().isEmpty, "everything restorable")

        print("uninstall footprint")
        let fp = engine.footprint(bundleID: "com.example.foo", name: "ExampleApp", team: nil)
        for c in fp { print("    \(c.tier.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(TidalPaths.pretty(c.path))  [\(c.ruleID)]") }
        check(fp.contains { $0.path.hasSuffix("Application Support/com.example.foo") && $0.tier == .review }, "Application Support → review")
        check(fp.contains { $0.path.hasSuffix("com.example.foo.plist") && $0.tier == .safe }, "preferences → safe")
        check(fp.contains { $0.path.hasSuffix("Logs/ExampleApp") }, "logs matched by app name")
        let ur = engine.clean(fp, reason: "ExampleApp uninstalled", uninstallContext: true)
        check(ur.refused.isEmpty, "all leftovers moved (\(ur.refused.map { $0.1 }))")

        print("remove by hand (map bubble)")
        make("Library/Application Support/BigGame/save.dat", bytes: 500_000)
        make("Documents/Projects/old.zip", bytes: 400_000)
        func chosen(_ rel: String) -> Candidate {
            Candidate(path: h + "/" + rel, name: (rel as NSString).lastPathComponent, owner: "x", ruleID: "user.choice", ruleTitle: "", tier: .review,
                      category: .apps, kind: "chosen", bytes: 500_000, modified: nil)
        }
        check(Safety.userRefusal(for: h + "/Documents", running: []) != nil, "whole Documents folder refused")
        check(Safety.userRefusal(for: h, running: []) != nil, "home folder refused")
        check(Safety.userRefusal(for: h + "/Library", running: []) != nil, "Library refused")
        check(Safety.userRefusal(for: "/System/Library", running: []) != nil, "system path refused")
        check(Safety.userRefusal(for: h + "/Library/Mail", running: []) != nil, "Mail refused")
        check(Safety.userRefusal(for: h + "/Library/Caches/sneaky", running: []) != nil, "symlink refused")
        check(Safety.userRefusal(for: h + "/Library/Application Support/BigGame", running: []) == nil, "app data folder allowed")
        let man = engine.clean([chosen("Library/Application Support/BigGame"), chosen("Documents/Projects/old.zip"), chosen("Documents")],
                               reason: "Self-test", chosen: true)
        check(man.held.count == 2 && man.refused.count == 1, "chosen items held, Documents refused")
        check(!fm.fileExists(atPath: h + "/Library/Application Support/BigGame"), "chosen folder moved out")
        for item in db.held() where item.ruleID == "user.choice" { _ = engine.restore(item) }
        check(fm.fileExists(atPath: h + "/Library/Application Support/BigGame/save.dat"), "chosen folder restores exactly")

        print("system data scan")
        let scan = SystemCleaner.scan()
        for t in scan.tasks { print("    \(t.admin ? "admin" : "user ") \(Fmt.bytes(t.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(t.title)") }
        check(scan.tasks.allSatisfy { !$0.shell.isEmpty }, "scan produced \(scan.tasks.count) tasks")

        print("purge")
        let before = db.held().count
        let purged = engine.purge(expiredOnly: false)
        check(db.held().isEmpty && before > 0, "holding area emptied, \(Fmt.bytes(purged)) reclaimed")

        print("index")
        let ix = SpaceIndexer(db: db)
        ix.indexAll(dirty: Set([h + "/Library", h + "/Documents"]))
        let nodes = ix.nodes()
        check(nodes.contains { $0.path == h + "/Library" && $0.category == .apps }, "Library indexed")
        check(nodes.contains { $0.path == h + "/Documents" && $0.category == .personal }, "Documents categorised personal")
        check(nodes.contains { $0.path.hasSuffix("Library/Developer") && $0.category == .developer }, "Developer categorised")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
