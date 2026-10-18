import Foundation
import Darwin

// MARK: - System data tasks

/// One thing that can be cleaned out of "macOS & system data". Every command is fixed text written here;
/// the only interpolated values are a UUID checked against a strict pattern and measured paths that are never executed.
struct SystemTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    var bytes: Int64
    var admin: Bool
    var review: Bool = false
    var sizeKnown = true
    /// Folders re-measured after the run, so the freed figure is what actually left the disk.
    var roots: [String] = []
    /// The command's own estimate is reliable when it exits cleanly (Homebrew reports exact sizes).
    var trusted = false
    let shell: String

    /// Safe to run unattended: no password, nothing a person would want to look at first.
    var unattended: Bool { !admin && !review }

    /// The same task with every destructive step turned into a listing.
    var dryShell: String {
        let d = shell.replacingOccurrences(of: "-exec rm -rf {} +", with: "-print")
            .replacingOccurrences(of: "cleanup --prune=all -s", with: "cleanup --prune=all -s -n")
        return d == shell ? "echo 'would run: \(id)'" : d
    }
}

struct TaskResult {
    let task: SystemTask
    let freed: Int64
    let error: String?
}

struct SystemInfoRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let bytes: Int64
}

enum SystemCleaner {
    /// Xcode's developer directory, wherever it lives; nil when only Command Line Tools exist (no simulators then).
    static let developerDir: String? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let d = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return d.hasSuffix("/Contents/Developer") && FileManager.default.fileExists(atPath: d) ? d : nil
    }()

    static func sh(_ cmd: String, env: [String: String] = [:]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var e = ProcessInfo.processInfo.environment
        if let d = developerDir { e["DEVELOPER_DIR"] = d }
        e["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        e["HOMEBREW_NO_ANALYTICS"] = "1"
        e["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func userCacheDir() -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s.isEmpty ? nil : "/" + s
    }

    static func userTempDir() -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s.isEmpty ? nil : "/" + s
    }

    /// Top-level entries old enough to remove, with their measured size.
    static func aged(_ dir: String, days: Double, skipApple: Bool) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let cutoff = Date().addingTimeInterval(-days * 86400)
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if skipApple && name.hasPrefix("com.apple.") { continue }
            let p = dir + "/" + name
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            let m = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if m > cutoff { continue }
            total += Sizer.measure(p).bytes
        }
        return total
    }

    /// Regular files under `dir` (any depth) not modified for `days`.
    static func agedFiles(_ dir: String, days: Double) -> Int64 {
        var total: Int64 = 0
        let cutoff = time_t(Date().addingTimeInterval(-days * 86400).timeIntervalSince1970)
        Sizer.walk(dir) { ent, info, st in
            guard info == FTS_F, let st, st.st_mtimespec.tv_sec < cutoff else { return }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    /// Rotated archives in /var/log: *.gz, *.bz2, *.asl, *.N older than a week.
    static func rotatedLogs(under root: String) -> Int64 {
        var total: Int64 = 0
        let cutoff = time_t(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
        Sizer.walk(root + "/private/var/log") { ent, info, st in
            guard info == FTS_F, let st, st.st_mtimespec.tv_sec < cutoff else { return }
            let n = (String(cString: ent.pointee.fts_path) as NSString).lastPathComponent
            if n.hasSuffix(".gz") || n.hasSuffix(".bz2") || n.hasSuffix(".asl") || (n.split(separator: ".").last.map { Int($0) != nil } ?? false) {
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }

    /// `admin: false` skips every location that needs a password; `info: false` skips the read-only report.
    /// The background agent uses both, so a pass never measures more than it is going to clean.
    static func scan(admin includeAdmin: Bool = true, info includeInfo: Bool = true) -> (tasks: [SystemTask], info: [SystemInfoRow]) {
        Sizer.throttleIO()
        var tasks: [SystemTask] = []
        var info: [SystemInfoRow] = []

        if let c = userCacheDir() {
            let b = aged(c, days: 2, skipApple: true)
            if b > 1_000_000 {
                tasks.append(SystemTask(id: "varcache", title: "Temporary app caches", detail: "Per-user cache folders macOS keeps outside your Library. Apps rebuild them.",
                                        bytes: b, admin: false, roots: [c],
                                        shell: "find '\(c)' -mindepth 1 -maxdepth 1 -mtime +1 ! -name 'com.apple.*' -exec rm -rf {} + 2>/dev/null; true"))
            }
        }
        if let t = userTempDir() {
            let b = aged(t, days: 4, skipApple: false)
            if b > 1_000_000 {
                tasks.append(SystemTask(id: "vartmp", title: "Temporary files", detail: "Scratch files untouched for days.",
                                        bytes: b, admin: false, roots: [t],
                                        shell: "find '\(t)' -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} + 2>/dev/null; true"))
            }
        }

        // iPhone and iPad firmware that Finder downloaded and never removes.
        let home = NSHomeDirectory()
        let fw = ["iPhone", "iPad", "iPod"].map { "\(home)/Library/iTunes/\($0) Software Updates" }.filter { FileManager.default.fileExists(atPath: $0) }
        var fwBytes: Int64 = 0
        for d in fw { for n in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".ipsw") { fwBytes += Sizer.measure(d + "/" + n).bytes } }
        if fwBytes > 1_000_000 {
            let finds = fw.map { "find '\($0)' -maxdepth 1 -name '*.ipsw' -mtime +7 -exec rm -rf {} +" }.joined(separator: "; ")
            tasks.append(SystemTask(id: "ipsw", title: "iPhone & iPad firmware", detail: "Old iOS and iPadOS installers Finder downloaded. Restoring a device downloads them again.",
                                    bytes: fwBytes, admin: false, roots: fw, shell: finds + " 2>/dev/null; true"))
        }

        // Homebrew: ask brew itself what it would remove.
        for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.isExecutableFile(atPath: brew) {
            let (_, out) = sh("'\(brew)' cleanup --prune=all -s -n 2>&1")
            var bytes: Int64 = 0
            if let r = out.range(of: #"approximately ([0-9.]+)\s?([KMGT]?B)"#, options: .regularExpression) {
                let parts = String(out[r]).replacingOccurrences(of: "approximately ", with: "").split(whereSeparator: { $0 == " " })
                let numText = parts.first.map(String.init) ?? ""
                let unit = (parts.count > 1 ? String(parts[1]) : String(numText.drop(while: { $0.isNumber || $0 == "." }))).uppercased()
                let num = Double(numText.prefix(while: { $0.isNumber || $0 == "." })) ?? 0
                let mult: Double = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
                bytes = Int64(num * mult)
            }
            if bytes > 1_000_000 {
                tasks.append(SystemTask(id: "brew", title: "Homebrew leftovers", detail: "Old package versions and downloads. Installed packages stay.",
                                        bytes: bytes, admin: false, trusted: true, shell: "'\(brew)' cleanup --prune=all -s 2>&1; true"))
            }
            break
        }

        // Simulators.
        let (_, unavailable) = sh("xcrun simctl list devices unavailable 2>/dev/null")
        if unavailable.contains("unavailable") && unavailable.contains("(") && unavailable.lowercased().contains("-- unavailable") {
            tasks.append(SystemTask(id: "simunavail", title: "Unavailable simulators", detail: "Simulator devices whose runtime is gone.",
                                    bytes: 0, admin: false, sizeKnown: false, shell: "xcrun simctl delete unavailable 2>&1; true"))
        }
        let (_, rtJSON) = sh("xcrun simctl runtime list -j 2>/dev/null")
        if let data = rtJSON.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (uuid, v) in obj {
                guard let d = v as? [String: Any], uuid.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil else { continue }
                let size = (d["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                let name = [d["platformIdentifier"] as? String, d["version"] as? String].compactMap { $0 }
                    .joined(separator: " ").replacingOccurrences(of: "com.apple.platform.", with: "")
                let nice = name.isEmpty ? (d["runtimeIdentifier"] as? String ?? "Simulator runtime") : name
                guard size > 100_000_000 else { continue }
                tasks.append(SystemTask(id: "rt." + uuid, title: "Simulator runtime — \(nice)", detail: "Re-downloadable from Xcode → Settings → Components.",
                                        bytes: size, admin: false, review: true, shell: "xcrun simctl runtime delete \(uuid) 2>&1; true"))
            }
        }

        guard includeAdmin else { return (tasks.sorted { $0.bytes > $1.bytes }, []) }

        // Admin-level cleanup, one password prompt for all of them.
        let upd = Sizer.measure("/Library/Updates").bytes
        if upd > 1_000_000 {
            tasks.append(SystemTask(id: "updates", title: "Downloaded macOS updates", detail: "Leftover installers in /Library/Updates.",
                                    bytes: upd, admin: true, roots: ["/Library/Updates"],
                                    shell: "find /Library/Updates -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; true"))
        }
        let lc = aged("/Library/Caches", days: 2, skipApple: true)
        if lc > 1_000_000 {
            tasks.append(SystemTask(id: "libcaches", title: "System-wide app caches", detail: "Non-Apple caches in /Library/Caches.",
                                    bytes: lc, admin: true, roots: ["/Library/Caches"],
                                    shell: "find /Library/Caches -mindepth 1 -maxdepth 1 -mtime +1 ! -name 'com.apple.*' -exec rm -rf {} + 2>/dev/null; true"))
        }
        let rotated = Self.rotatedLogs(under: "")
        if rotated > 1_000_000 {
            tasks.append(SystemTask(id: "rotlogs", title: "Rotated system logs", detail: "Compressed log archives in /var/log older than a week.",
                                    bytes: rotated, admin: true, roots: ["/private/var/log"],
                                    shell: "find /private/var/log -type f \\( -name '*.gz' -o -name '*.bz2' -o -name '*.asl' -o -name '*.[0-9]' \\) -mtime +7 -exec rm -rf {} + 2>/dev/null; true"))
        }
        let crash = Self.agedFiles("/Library/Logs/DiagnosticReports", days: 14)
        if crash > 1_000_000 {
            tasks.append(SystemTask(id: "syscrash", title: "System crash reports", detail: "Diagnostic reports in /Library/Logs older than two weeks.",
                                    bytes: crash, admin: true, roots: ["/Library/Logs/DiagnosticReports"],
                                    shell: "find /Library/Logs/DiagnosticReports -type f -mtime +14 -exec rm -rf {} + 2>/dev/null; true"))
        }
        let tmp = Self.agedFiles("/private/tmp", days: 3)
        if tmp > 1_000_000 {
            tasks.append(SystemTask(id: "systmp", title: "Old files in /tmp", detail: "Scratch files nothing has touched for days.",
                                    bytes: tmp, admin: true, roots: ["/private/tmp"],
                                    shell: "find /private/tmp -xdev -type f -mtime +3 -atime +3 ! -path '*/com.apple.*' -exec rm -rf {} + 2>/dev/null; true"))
        }
        let diag = Sizer.measure("/private/var/db/diagnostics").bytes
        if diag > 50_000_000 {
            tasks.append(SystemTask(id: "oslogs", title: "System log archives", detail: "macOS's unified log history. Erasing it only removes troubleshooting history.",
                                    bytes: diag, admin: true, review: true, roots: ["/private/var/db/diagnostics"], shell: "/usr/bin/log erase --all 2>&1; true"))
        }
        let (_, snaps) = sh("tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null")
        let snapCount = snaps.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        if snapCount > 0 {
            tasks.append(SystemTask(id: "snapshots", title: "Local Time Machine snapshots (\(snapCount))", detail: "Space-saving local backups macOS keeps on this disk. Your real Time Machine backups are untouched.",
                                    bytes: 0, admin: true, sizeKnown: false,
                                    shell: "tmutil thinlocalsnapshots /System/Volumes/Data 999999999999 4 2>&1; true"))
        }

        guard includeInfo else { return (tasks.sorted { $0.bytes > $1.bytes }, []) }

        // Things worth knowing about but not safe to remove.
        for (id, title, path, why) in [
            ("assets", "macOS-managed assets", "/System/Volumes/Data/System/Library/AssetsV2", "Dictionaries, voices, language and Apple Intelligence models. macOS adds and removes these itself."),
            ("libsupport", "Shared app support", "/Library/Application Support", "Installed by apps for every user. Remove an app to clear its part."),
            ("opt", "Homebrew & /opt", "/opt", "Installed command-line tools. Use `brew uninstall` for specific ones."),
        ] {
            let b = Sizer.measure(path).bytes
            if b > 100_000_000 { info.append(SystemInfoRow(id: id, title: title, detail: why, bytes: b)) }
        }
        return (tasks.sorted { $0.bytes > $1.bytes }, info.sorted { $0.bytes > $1.bytes })
    }

    /// Runs the picked tasks. Non-admin tasks run directly; admin tasks share one macOS password prompt.
    /// Each result's figure is what was measured leaving the disk, never what the command claimed.
    static func run(_ tasks: [SystemTask]) -> [TaskResult] {
        var out: [TaskResult] = []
        func before(_ t: SystemTask) -> Int64 { t.roots.reduce(0) { $0 + Sizer.measure($1).bytes } }
        func result(_ t: SystemTask, _ was: Int64, ok: Bool, message: String) -> TaskResult {
            guard ok else { return TaskResult(task: t, freed: 0, error: message.isEmpty ? "Failed" : message) }
            if !t.roots.isEmpty {
                let freed = max(0, was - before(t))
                return TaskResult(task: t, freed: freed, error: freed == 0 && t.bytes > 0 ? "Nothing could be removed" : nil)
            }
            return TaskResult(task: t, freed: t.trusted ? t.bytes : 0, error: nil)
        }
        for t in tasks where !t.admin {
            let was = before(t)
            let (code, text) = sh(t.shell)
            out.append(result(t, was, ok: code == 0, message: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let admin = tasks.filter(\.admin)
        if !admin.isEmpty {
            let was = admin.map(before)
            let script = admin.map(\.shell).joined(separator: "; ")
            let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let (code, text) = sh("/usr/bin/osascript -e 'do shell script \"\(escaped.replacingOccurrences(of: "'", with: "'\\''"))\" with administrator privileges with prompt \"Tidal wants to clean system data.\"' 2>&1")
            let msg = text.contains("-128") ? "Cancelled" : text.trimmingCharacters(in: .whitespacesAndNewlines)
            for (i, t) in admin.enumerated() { out.append(result(t, was[i], ok: code == 0, message: msg)) }
        }
        return out
    }

    /// What the background agent does by itself: only the password-free, nothing-to-review tasks.
    static func runUnattended() -> [TaskResult] {
        run(scan(admin: false, info: false).tasks.filter(\.unattended))
    }
}
