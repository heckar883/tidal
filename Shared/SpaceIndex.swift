import Foundation
import Darwin

struct IndexNode: Hashable, Sendable {
    var path: String
    var parent: String
    var name: String
    var bytes: Int64
    var category: SpaceCategory
    var owner: String
    var kind: String
    var depth: Int
    var flags: Int // 1 = could not read, 2 = package, 4 = file
    var used: Date?

    static let denied = 1, package = 2, file = 4
}

/// Assigns every byte to exactly one leaf category.
enum Categorizer {
    private static let table: [(String, SpaceCategory)] = [
        ("Library/Mail", .libraries), ("Library/Messages", .libraries),
        ("Library/Containers/com.apple.Notes", .libraries), ("Library/Group Containers/group.com.apple.notes", .libraries),
        ("Library/Group Containers/group.com.apple.VoiceMemos.shared", .libraries),
        ("Library/Application Support/MobileSync", .backups),
        ("Library/Developer", .developer), ("Library/Android", .developer),
        ("Library/Containers/com.docker.docker", .developer), ("Library/Containers/com.utmapp.UTM", .developer),
        ("Library/Caches/Homebrew", .developer), ("Library/Caches/pip", .developer), ("Library/Caches/Yarn", .developer),
        ("Library/Caches/CocoaPods", .developer), ("Library/Caches/org.swift.swiftpm", .developer),
        ("Library/Caches/ms-playwright", .developer), ("Library/Caches/node-gyp", .developer),
        ("Library/Mobile Documents", .personal),
        (".npm", .developer), (".gradle", .developer), (".cargo", .developer), (".rustup", .developer),
        (".docker", .developer), (".orbstack", .developer), (".colima", .developer), (".swiftly", .developer),
        (".m2", .developer), (".pub-cache", .developer), (".conda", .developer), (".nvm", .developer),
        (".bun", .developer), (".pyenv", .developer), (".cache", .developer), (".android", .developer),
        ("go", .developer), ("miniconda3", .developer), ("anaconda3", .developer), ("VirtualBox VMs", .developer),
        ("Developer", .developer), ("Parallels", .developer),
        ("Documents", .personal), ("Desktop", .personal), ("Downloads", .personal), ("Movies", .personal),
        ("Music", .personal), ("Pictures", .personal), ("Public", .personal),
        (".Trash", .other), ("Library", .apps), ("Applications", .apps),
    ]

    static func category(for path: String) -> SpaceCategory {
        if path == "/Applications" || path.hasPrefix("/Applications/") { return .apps }
        let home = TidalPaths.home.path
        guard path.hasPrefix(home + "/") else { return .other }
        let rel = String(path.dropFirst(home.count + 1))
        if rel.hasSuffix(".photoslibrary") || rel.contains(".photoslibrary/") { return .libraries }
        if rel.hasPrefix("Music/Music") || rel.hasPrefix("Music/iTunes") || rel.hasPrefix("Movies/TV") { return .libraries }
        for (prefix, cat) in table where rel == prefix || rel.hasPrefix(prefix + "/") { return cat }
        if rel.hasPrefix(".") { return .developer }
        return .other
    }

    /// Owner key: a bundle identifier when one can be seen in the path, otherwise a folder name.
    static let perAppParents: Set<String> = ["Caches", "Application Support", "Containers", "Logs", "HTTPStorages",
                                             "WebKit", "Saved Application State", "Preferences", "Group Containers",
                                             "Application Scripts", "Cookies"]

    static func owner(for path: String) -> String {
        let home = TidalPaths.home.path
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let parts = rel.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "Library", perAppParents.contains(parts[1]) {
            var o = parts[2]
            for ext in [".savedState", ".binarycookies", ".plist"] where o.hasSuffix(ext) { o = String(o.dropLast(ext.count)) }
            return o
        }
        return ""
    }

    static let packageExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle",
                                                 "framework", "sparsebundle", "sparseimage", "utm", "pvm", "vmwarevm",
                                                 "xcarchive", "fcpbundle", "logicx", "imovielibrary", "band", "plugin",
                                                 "kext", "lrlibrary", "lrdata", "dmg", "savedState"]
}

/// Builds the space index. One low-priority pass per root; partial results stream out as each
/// top-level folder completes so the map can fill in immediately.
final class SpaceIndexer: @unchecked Sendable {
    let db: Database
    init(db: Database = .shared) { self.db = db }

    private struct Frame { var path: String; var bytes: Int64 = 0; var denied = false; var package: Bool; var level: Int }

    func scan(root: String, maxDepth: Int, minEmit: Int64 = 1_048_576, skip: Set<String> = [],
              batch: (([IndexNode]) -> Void)? = nil) -> Int64 {
        Sizer.throttleIO()
        var nodes: [IndexNode] = []
        var stack: [Frame] = []
        var seen = Set<UInt64>()
        var total: Int64 = 0
        let rootDepthOffset = 1

        func flush() {
            guard !nodes.isEmpty else { return }
            let chunk = nodes
            nodes.removeAll(keepingCapacity: true)
            db.transaction { for n in chunk { self.store(n) } }
            batch?(chunk)
        }

        /// Pops every open frame at `level` or deeper, folding sizes into the parent and emitting nodes.
        func closeFrames(atOrBelow level: Int, path: String, denied: Bool) {
            while let top = stack.last, top.level >= level {
                if top.level == level && top.path != path && top.level > 0 { break }
                stack.removeLast()
                let isDenied = top.denied || (denied && top.path == path)
                if !stack.isEmpty {
                    stack[stack.count - 1].bytes += top.bytes
                    if isDenied { stack[stack.count - 1].denied = true }
                } else { total = top.bytes }
                if top.level > 0 && (top.bytes >= minEmit || top.level == 1 || isDenied) {
                    nodes.append(makeNode(path: top.path, bytes: top.bytes, depth: top.level + rootDepthOffset,
                                          flags: (isDenied ? IndexNode.denied : 0) | (top.package ? IndexNode.package : 0)))
                    if top.level == 1 { flush() }
                }
                if top.path == path { break }
            }
        }

        Sizer.walk(root) { ent, info, st in
            let level = Int(ent.pointee.fts_level)
            switch info {
            case FTS_D:
                let insidePackage = stack.last?.package ?? false
                if level <= maxDepth && !insidePackage {
                    let path = String(cString: ent.pointee.fts_path)
                    if level > 0 && skip.contains(path) {
                        fts_set(nil, ent, FTS_SKIP)
                        return
                    }
                    let ext = (path as NSString).pathExtension
                    stack.append(Frame(path: path, package: Categorizer.packageExtensions.contains(ext), level: level))
                }
                if let st, !stack.isEmpty { stack[stack.count - 1].bytes += Int64(st.st_blocks) * 512 }
            case FTS_DP:
                closeFrames(atOrBelow: level, path: String(cString: ent.pointee.fts_path), denied: false)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st, !stack.isEmpty else { return }
                var alloc = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 && info == FTS_F, !seen.insert(UInt64(st.st_ino)).inserted { alloc = 0 }
                stack[stack.count - 1].bytes += alloc
                // Very large single files become their own blob.
                if alloc >= 200 * 1_048_576 && level <= maxDepth && !(stack.last?.package ?? false) {
                    nodes.append(makeNode(path: String(cString: ent.pointee.fts_path), bytes: alloc, depth: level + rootDepthOffset, flags: IndexNode.file))
                }
            case FTS_DNR, FTS_ERR:
                // An unreadable directory ends with DNR instead of DP: close its frame here.
                let path = String(cString: ent.pointee.fts_path)
                if stack.last?.path == path { closeFrames(atOrBelow: level, path: path, denied: true) }
                else {
                    if !stack.isEmpty { stack[stack.count - 1].denied = true }
                    if level <= maxDepth && level > 0 { nodes.append(makeNode(path: path, bytes: 0, depth: level + rootDepthOffset, flags: IndexNode.denied)) }
                }
            default: break
            }
        }
        flush()
        return total
    }

    private func makeNode(path: String, bytes: Int64, depth: Int, flags: Int) -> IndexNode {
        let parent = (path as NSString).deletingLastPathComponent
        var name = (path as NSString).lastPathComponent
        var owner = Categorizer.owner(for: path)
        var used: Date?
        if path.hasSuffix(".app"), let info = AppBundleInfo(url: URL(fileURLWithPath: path)) {
            owner = info.bundleID
            name = info.name
            db.recordApp(bundleID: info.bundleID, name: info.name, path: path, version: info.version, team: info.team)
            if let item = MDItemCreate(nil, path as CFString),
               let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { used = d }
        }
        return IndexNode(path: path, parent: parent, name: name, bytes: bytes, category: Categorizer.category(for: path),
                         owner: owner, kind: "", depth: depth, flags: flags, used: used)
    }

    private func store(_ n: IndexNode) {
        db.run("INSERT OR REPLACE INTO nodes(path,parent,name,bytes,category,owner,kind,depth,scanned,flags,used) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
               [n.path, n.parent, n.name, n.bytes, n.category.rawValue, n.owner, n.kind, n.depth,
                Date().timeIntervalSince1970, n.flags, n.used?.timeIntervalSince1970])
    }

    /// Removes stale rows for a subtree before it is rescanned.
    func clear(under root: String) {
        db.run("DELETE FROM nodes WHERE path=? OR path LIKE ?", [root, root + "/%"])
    }

    /// Full index of the places that matter. Home children are rescanned individually so a change
    /// in one folder never forces a walk of the whole disk.
    func indexAll(dirty: Set<String>? = nil, progress: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        let home = TidalPaths.home.path
        var roots: [(String, Int)] = []
        if dirty == nil || dirty!.contains("/Applications") { roots.append(("/Applications", 1)) }
        let homeKids = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).filter { $0 != ".DS_Store" && $0 != ".localized" }
        for k in homeKids.sorted() {
            let p = home + "/" + k
            if let dirty, !dirty.contains(p) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                let m = Sizer.measure(p)
                if m.bytes > 1_048_576 { db.transaction { store(makeNode(path: p, bytes: m.bytes, depth: 1, flags: IndexNode.file)) } }
                continue
            }
            roots.append((p, k == "Library" ? 3 : 2))
        }
        for (root, depth) in roots {
            progress?(root)
            if root == "/Applications" {
                clear(under: root)
                for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
                    let p = root + "/" + name
                    let m = Sizer.measure(p)
                    db.transaction { store(makeNode(path: p, bytes: m.bytes, depth: 1, flags: m.denied ? IndexNode.denied : IndexNode.package)) }
                }
            } else {
                clear(under: root)
                // The root itself is depth 1 relative to home; its children start at fts level 1.
                // Tidal's own holding area is not "your" Library usage; it's shown in Activity.
                let size = scan(root: root, maxDepth: depth - 1, minEmit: 4 * 1_048_576, skip: [TidalPaths.support.path])
                let m = IndexNode(path: root, parent: home, name: (root as NSString).lastPathComponent, bytes: size,
                                  category: Categorizer.category(for: root), owner: "", kind: "", depth: 1,
                                  flags: Safety.isReadable(root) ? 0 : IndexNode.denied, used: nil)
                db.transaction { store(m) }
            }
            db.set("indexedAt", String(Date().timeIntervalSince1970))
            DistributedNotificationCenter.default().postNotificationName(TidalID.changed, object: nil, userInfo: ["what": "index"], deliverImmediately: true)
        }
        db.set("indexComplete", "1")
    }

    func nodes() -> [IndexNode] {
        var out: [IndexNode] = []
        db.query("SELECT path,parent,name,bytes,category,owner,kind,depth,flags,used FROM nodes") { r in
            out.append(IndexNode(path: r.string(0), parent: r.string(1), name: r.string(2), bytes: r.int(3),
                                 category: SpaceCategory(rawValue: r.string(4)) ?? .other, owner: r.string(5),
                                 kind: r.string(6), depth: Int(r.int(7)), flags: Int(r.int(8)),
                                 used: r.isNull(9) ? nil : Date(timeIntervalSince1970: r.double(9))))
        }
        return out
    }
}

extension Safety {
    static func isReadable(_ path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Full Disk Access cannot be queried directly; reading a TCC-protected location is the honest test.
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["Library/Safari", "Library/Mail", "Library/Messages", ".Trash"] {
            let full = home + "/" + p
            if FileManager.default.fileExists(atPath: full) { return isReadable(full) }
        }
        return isReadable("/Library/Application Support/com.apple.TCC")
    }
}
