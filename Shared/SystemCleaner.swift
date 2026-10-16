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
    let shell: String
}

struct SystemInfoRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let bytes: Int64
}

enum SystemCleaner {
    static var developerDir: String? {
        let d = "/Applications/Xcode.app/Contents/Developer"
        return FileManager.default.fileExists(atPath: d) ? d : nil
    }

    static func sh(_ cmd: String, env: [String: String] = [:]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var e = ProcessInfo.processInfo.environment
        if let d = developerDir { e["DEVELOPER_DIR"] = d }
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

    static func scan() -> (tasks: [SystemTask], info: [SystemInfoRow]) {
        Sizer.throttleIO()
        var tasks: [SystemTask] = []
        var info: [SystemInfoRow] = []

        if let c = userCacheDir() {
            let b = aged(c, days: 2, skipApple: true)
            if b > 1_000_000 {
                tasks.append(SystemTask(id: "varcache", title: "Temporary app caches", detail: "Per-user cache folders macOS keeps outside your Library. Apps rebuild them.",
                                        bytes: b, admin: false,
                                        shell: "find '\(c)' -mindepth 1 -maxdepth 1 -mtime +1 ! -name 'com.apple.*' -exec rm -rf {} + 2>/dev/null; true"))
            }
        }
        if let t = userTempDir() {
            let b = aged(t, days: 4, skipApple: false)
            if b > 1_000_000 {
                tasks.append(SystemTask(id: "vartmp", title: "Temporary files", detail: "Scratch files untouched for days.",
                                        bytes: b, admin: false,
                                        shell: "find '\(t)' -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} + 2>/dev/null; true"))
            }
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
                                        bytes: bytes, admin: false, shell: "'\(brew)' cleanup --prune=all -s 2>&1; true"))
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

        // Admin-level cleanup, one password prompt for all of them.
        let upd = Sizer.measure("/Library/Updates").bytes
        if upd > 1_000_000 {
            tasks.append(SystemTask(id: "updates", title: "Downloaded macOS updates", detail: "Leftover installers in /Library/Updates.",
                                    bytes: upd, admin: true,
                                    shell: "find /Library/Updates -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; true"))
        }
        let lc = aged("/Library/Caches", days: 2, skipApple: true)
        if lc > 1_000_000 {
            tasks.append(SystemTask(id: "libcaches", title: "System-wide app caches", detail: "Non-Apple caches in /Library/Caches.",
                                    bytes: lc, admin: true,
                                    shell: "find /Library/Caches -mindepth 1 -maxdepth 1 -mtime +1 ! -name 'com.apple.*' -exec rm -rf {} + 2>/dev/null; true"))
        }
        let diag = Sizer.measure("/private/var/db/diagnostics").bytes
        if diag > 50_000_000 {
            tasks.append(SystemTask(id: "oslogs", title: "System log archives", detail: "macOS's unified log history. Erasing it only removes troubleshooting history.",
                                    bytes: diag, admin: true, review: true, shell: "/usr/bin/log erase --all 2>&1; true"))
        }
        let (_, snaps) = sh("tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null")
        let snapCount = snaps.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        if snapCount > 0 {
            tasks.append(SystemTask(id: "snapshots", title: "Local Time Machine snapshots (\(snapCount))", detail: "Space-saving local backups macOS keeps on this disk. Your real Time Machine backups are untouched.",
                                    bytes: 0, admin: true, sizeKnown: false,
                                    shell: "tmutil thinlocalsnapshots /System/Volumes/Data 999999999999 4 2>&1; true"))
        }

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
    static func run(_ tasks: [SystemTask]) -> (ok: [SystemTask], failed: [(SystemTask, String)]) {
        var ok: [SystemTask] = []
        var failed: [(SystemTask, String)] = []
        for t in tasks where !t.admin {
            let (code, out) = sh(t.shell)
            if code == 0 { ok.append(t) } else { failed.append((t, out.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        let admin = tasks.filter(\.admin)
        if !admin.isEmpty {
            let script = admin.map(\.shell).joined(separator: "; ")
            let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let (code, out) = sh("/usr/bin/osascript -e 'do shell script \"\(escaped.replacingOccurrences(of: "'", with: "'\\''"))\" with administrator privileges with prompt \"Tidal wants to clean system data.\"' 2>&1")
            if code == 0 { ok += admin } else {
                let msg = out.contains("-128") ? "Cancelled" : out.trimmingCharacters(in: .whitespacesAndNewlines)
                failed += admin.map { ($0, msg) }
            }
        }
        return (ok, failed)
    }
}

