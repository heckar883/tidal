import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Small SQLite wrapper. The index is shared between the agent and the interface (WAL mode),
/// so nothing large ever needs to live in memory while idle.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static let shared = Database(url: TidalPaths.database)

    init(url: URL) {
        TidalPaths.ensure()
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-512;")
        exec("""
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS nodes(path TEXT PRIMARY KEY, parent TEXT, name TEXT, bytes INTEGER,
            category TEXT, owner TEXT, kind TEXT, depth INTEGER, scanned REAL, flags INTEGER, used REAL);
        CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent);
        CREATE TABLE IF NOT EXISTS apps(bundle_id TEXT PRIMARY KEY, name TEXT, path TEXT, version TEXT,
            team TEXT, first_seen REAL, last_seen REAL);
        CREATE TABLE IF NOT EXISTS footprint(bundle_id TEXT, path TEXT, PRIMARY KEY(bundle_id, path));
        CREATE TABLE IF NOT EXISTS activity(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT,
            title TEXT, detail TEXT, bytes INTEGER);
        CREATE TABLE IF NOT EXISTS held(id TEXT PRIMARY KEY, original TEXT, stored TEXT, name TEXT, owner TEXT,
            rule TEXT, category TEXT, bytes INTEGER, ts REAL, batch TEXT);
        CREATE TABLE IF NOT EXISTS queue(path TEXT PRIMARY KEY, json TEXT, ts REAL);
        CREATE TABLE IF NOT EXISTS uninstalls(id TEXT PRIMARY KEY, json TEXT, ts REAL);
        """)
    }

    // MARK: primitives

    @discardableResult
    func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN IMMEDIATE")
        body()
        exec("COMMIT")
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func query(_ sql: String, _ args: [Any?] = [], _ row: (Row) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        while sqlite3_step(stmt) == SQLITE_ROW { row(Row(stmt: stmt)) }
    }

    struct Row {
        let stmt: OpaquePointer?
        func string(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }

    private func bind(_ stmt: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    // MARK: kv

    func get(_ k: String) -> String? {
        var out: String?
        query("SELECT v FROM kv WHERE k=?", [k]) { out = $0.string(0) }
        return out
    }

    func set(_ k: String, _ v: String) { run("INSERT OR REPLACE INTO kv(k,v) VALUES(?,?)", [k, v]) }

    func bool(_ k: String, default d: Bool) -> Bool { get(k).map { $0 == "1" } ?? d }
    func setBool(_ k: String, _ v: Bool) { set(k, v ? "1" : "0") }
    func double(_ k: String, default d: Double) -> Double { get(k).flatMap(Double.init) ?? d }

    func policy(_ c: SpaceCategory) -> Policy {
        if let p = get(SettingKey.policy(c)).flatMap(Policy.init) { return p }
        switch c {
        case .apps, .system: return .auto
        case .developer: return .ask
        default: return .ask
        }
    }

    // MARK: activity

    func log(_ kind: String, _ title: String, _ detail: String = "", bytes: Int64 = 0) {
        run("INSERT INTO activity(ts,kind,title,detail,bytes) VALUES(?,?,?,?,?)",
            [Date().timeIntervalSince1970, kind, title, detail, bytes])
        // Human-readable mirror of the log.
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(kind.uppercased().padding(toLength: 9, withPad: " ", startingAt: 0)) \(title)\(detail.isEmpty ? "" : " — \(detail)")\(bytes > 0 ? " [\(Fmt.bytes(bytes))]" : "")\n"
        if let h = try? FileHandle(forWritingTo: TidalPaths.log) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: TidalPaths.log)
        }
    }

    func activity(limit: Int = 300) -> [ActivityEntry] {
        var out: [ActivityEntry] = []
        query("SELECT id,ts,kind,title,detail,bytes FROM activity ORDER BY id DESC LIMIT ?", [limit]) { r in
            out.append(ActivityEntry(id: r.int(0), at: Date(timeIntervalSince1970: r.double(1)), kind: r.string(2),
                                     title: r.string(3), detail: r.string(4), bytes: r.int(5)))
        }
        return out
    }

    // MARK: holding

    func addHeld(_ h: HeldItem) {
        run("INSERT OR REPLACE INTO held(id,original,stored,name,owner,rule,category,bytes,ts,batch) VALUES(?,?,?,?,?,?,?,?,?,?)",
            [h.id, h.original, h.stored, h.name, h.owner, h.ruleID, h.category.rawValue, h.bytes, h.heldAt.timeIntervalSince1970, h.batch])
    }

    func held() -> [HeldItem] {
        var out: [HeldItem] = []
        query("SELECT id,original,stored,name,owner,rule,category,bytes,ts,batch FROM held ORDER BY ts DESC") { r in
            out.append(HeldItem(id: r.string(0), original: r.string(1), stored: r.string(2), name: r.string(3),
                                owner: r.string(4), ruleID: r.string(5),
                                category: SpaceCategory(rawValue: r.string(6)) ?? .other, bytes: r.int(7),
                                heldAt: Date(timeIntervalSince1970: r.double(8)), batch: r.string(9)))
        }
        return out
    }

    func removeHeld(_ id: String) { run("DELETE FROM held WHERE id=?", [id]) }

    // MARK: review queue

    func enqueue(_ c: Candidate) {
        if let d = try? JSONEncoder().encode(c) {
            run("INSERT OR REPLACE INTO queue(path,json,ts) VALUES(?,?,?)", [c.path, String(decoding: d, as: UTF8.self), Date().timeIntervalSince1970])
        }
    }

    func dequeue(_ path: String) { run("DELETE FROM queue WHERE path=?", [path]) }

    func queue() -> [Candidate] {
        var out: [Candidate] = []
        query("SELECT json FROM queue ORDER BY ts DESC") { r in
            if let c = try? JSONDecoder().decode(Candidate.self, from: Data(r.string(0).utf8)) { out.append(c) }
        }
        return out
    }

    // MARK: uninstalls

    func save(_ u: UninstallEvent) {
        if let d = try? JSONEncoder().encode(u) {
            run("INSERT OR REPLACE INTO uninstalls(id,json,ts) VALUES(?,?,?)", [u.id, String(decoding: d, as: UTF8.self), u.at.timeIntervalSince1970])
        }
    }

    func uninstalls() -> [UninstallEvent] {
        var out: [UninstallEvent] = []
        query("SELECT json FROM uninstalls ORDER BY ts DESC LIMIT 50") { r in
            if let u = try? JSONDecoder().decode(UninstallEvent.self, from: Data(r.string(0).utf8)) { out.append(u) }
        }
        return out
    }

    // MARK: apps / footprints

    func recordApp(bundleID: String, name: String, path: String, version: String, team: String) {
        let now = Date().timeIntervalSince1970
        run("""
            INSERT INTO apps(bundle_id,name,path,version,team,first_seen,last_seen) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(bundle_id) DO UPDATE SET name=excluded.name, path=excluded.path, version=excluded.version,
            team=excluded.team, last_seen=excluded.last_seen
            """, [bundleID, name, path, version, team, now, now])
    }

    func appName(_ bundleID: String) -> String? {
        var out: String?
        query("SELECT name FROM apps WHERE bundle_id=?", [bundleID]) { out = $0.string(0) }
        return out
    }

    /// Keeps the name but forgets where the app lived, so a handled uninstall isn't processed again.
    func retireApp(_ bundleID: String) { run("UPDATE apps SET path='' WHERE bundle_id=?", [bundleID]) }

    func knownApps() -> [(id: String, name: String, path: String, lastSeen: Date)] {
        var out: [(String, String, String, Date)] = []
        query("SELECT bundle_id,name,path,last_seen FROM apps") { r in
            out.append((r.string(0), r.string(1), r.string(2), Date(timeIntervalSince1970: r.double(3))))
        }
        return out.map { (id: $0.0, name: $0.1, path: $0.2, lastSeen: $0.3) }
    }

    func setFootprint(_ bundleID: String, _ paths: [String]) {
        transaction {
            run("DELETE FROM footprint WHERE bundle_id=?", [bundleID])
            for p in paths { run("INSERT OR IGNORE INTO footprint(bundle_id,path) VALUES(?,?)", [bundleID, p]) }
        }
    }

    func footprint(_ bundleID: String) -> [String] {
        var out: [String] = []
        query("SELECT path FROM footprint WHERE bundle_id=?", [bundleID]) { out.append($0.string(0)) }
        return out
    }
}
