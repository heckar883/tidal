import SwiftUI
import AppKit

enum Grouping: String, CaseIterable, Identifiable {
    case apps, folders, categories
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .folders: "folder"
        case .categories: "circle.grid.cross"
        }
    }
}

enum MapStyle: String, CaseIterable, Identifiable {
    case bubbles, ribbons, strata, list
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bubbles: "circle.circle"
        case .ribbons: "line.3.horizontal.decrease"
        case .strata: "square.stack.3d.down.forward"
        case .list: "list.bullet"
        }
    }
}

struct MapItem: Identifiable, Hashable {
    let id: String
    var name: String
    var bytes: Int64
    var category: SpaceCategory
    var children: [MapItem] = []
    var path: String? = nil
    var bundleID: String? = nil
    var used: Date? = nil
    var locked = false
    var denied = false
    var dashed = false
    var orphan = false
    var note: String? = nil

    var canOpen: Bool { children.count > 0 }
}

/// All three views are queries over the same index, so they always agree.
enum MapBuilder {
    static func build(_ g: Grouping, nodes: [IndexNode], volume: VolumeInfo, db: Database) -> [MapItem] {
        let byParent = Dictionary(grouping: nodes, by: \.parent)
        let home = TidalPaths.home.path

        func tree(_ n: IndexNode) -> MapItem {
            var kids = (byParent[n.path] ?? []).map(tree).sorted { $0.bytes > $1.bytes }
            let sum = kids.reduce(0) { $0 + $1.bytes }
            if !kids.isEmpty, n.bytes - sum > max(n.bytes / 50, 2_000_000) {
                kids.append(MapItem(id: n.path + "#rest", name: "Smaller items", bytes: n.bytes - sum, category: n.category,
                                    path: nil, note: "Everything under \(n.name) too small to show on its own."))
            }
            let protected = Safety.isProtected(n.path)
            return MapItem(id: n.path, name: display(n), bytes: n.bytes, category: n.category, children: kids, path: n.path,
                           bundleID: n.path.hasSuffix(".app") ? n.owner : nil, used: n.used, locked: protected,
                           denied: n.flags & IndexNode.denied != 0)
        }

        let homeTop = (byParent[home] ?? []).map(tree)
        let apps = (byParent["/Applications"] ?? []).map(tree).sorted { $0.bytes > $1.bytes }
        let homeTotal = homeTop.reduce(0) { $0 + $1.bytes }
        let appsTotal = apps.reduce(0) { $0 + $1.bytes }
        let systemBytes = max(0, volume.used - volume.purgeable - homeTotal - appsTotal)
        let system = MapItem(id: "#system", name: "macOS & system data", bytes: systemBytes, category: .system, locked: true,
                             note: "The sealed macOS volume, system data, local snapshots and anything Tidal can't read. Select it and choose Clean system data to clear the safe parts.")
        let purge = MapItem(id: "#purgeable", name: "Purgeable", bytes: volume.purgeable, category: .purgeable, locked: true, dashed: true,
                            note: "Space macOS reclaims by itself when it needs it. Shown separately, never counted as free.")
        let extras = [system, purge].filter { $0.bytes > 0 }

        switch g {
        case .folders:
            var top = homeTop
            if appsTotal > 0 {
                top.append(MapItem(id: "/Applications", name: "Applications", bytes: appsTotal, category: .apps, children: apps, path: "/Applications"))
            }
            return (top + extras).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }

        case .categories:
            var buckets: [SpaceCategory: [MapItem]] = [:]
            func split(_ item: MapItem) {
                var own = item
                var kept: [MapItem] = []
                for c in item.children {
                    if c.category != item.category { split(c); own.bytes -= c.bytes } else { kept.append(c) }
                }
                own.children = kept
                if own.bytes > 0 { buckets[own.category, default: []].append(own) }
            }
            for i in homeTop { split(i) }
            if appsTotal > 0 {
                buckets[.apps, default: []].append(MapItem(id: "/Applications", name: "Applications", bytes: appsTotal, category: .apps, children: apps, path: "/Applications"))
            }
            for e in extras { buckets[e.category, default: []].append(e) }
            return buckets.map { cat, items in
                let sorted = items.sorted { $0.bytes > $1.bytes }
                return MapItem(id: "cat:" + cat.rawValue, name: cat.title, bytes: sorted.reduce(0) { $0 + $1.bytes }, category: cat,
                               children: sorted.count == 1 && sorted[0].children.count > 0 ? sorted[0].children : sorted,
                               locked: cat == .system || cat == .purgeable, dashed: cat == .purgeable,
                               note: cat == .system ? system.note : cat == .purgeable ? purge.note : nil)
            }
            .filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }

        case .apps:
            // Every app with all of its data across the disk, as one entity.
            let library = nodes.filter { n in
                n.depth == 3 && !n.owner.isEmpty && n.path.hasPrefix(home + "/Library/")
            }
            var claimed = Set<String>()
            var entities: [MapItem] = []
            for a in apps {
                guard let bid = a.bundleID, !bid.isEmpty else { continue }
                let nameKey = a.name.lowercased()
                let data = library.filter { n in
                    let o = n.owner.lowercased()
                    return o == bid.lowercased() || o == nameKey || (n.parent.hasSuffix("Group Containers") && o.contains(bid.lowercased()))
                }
                data.forEach { claimed.insert($0.path) }
                var kids = [MapItem(id: a.id + "#bundle", name: "App", bytes: a.bytes, category: .apps, path: a.path, bundleID: bid, used: a.used)]
                kids += data.map { n in
                    MapItem(id: n.path, name: parentLabel(n.parent), bytes: n.bytes, category: .apps, path: n.path,
                            denied: n.flags & IndexNode.denied != 0)
                }
                let total = kids.reduce(0) { $0 + $1.bytes }
                entities.append(MapItem(id: "app:" + bid, name: a.name, bytes: total, category: .apps,
                                        children: kids.sorted { $0.bytes > $1.bytes }, path: a.path, bundleID: bid, used: a.used))
            }
            // Data whose app is not in /Applications: other locations, or left behind.
            let rest = Dictionary(grouping: library.filter { !claimed.contains($0.path) }) { n -> String in
                n.owner.hasPrefix("com.apple.") || n.owner.hasPrefix("group.com.apple.") ? "com.apple" : n.owner.lowercased()
            }
            for (key, ns) in rest {
                let total = ns.reduce(0) { $0 + $1.bytes }
                guard total > 8_000_000 else { continue }
                let owner = ns[0].owner
                let installed = key == "com.apple" || NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) != nil
                let name: String = key == "com.apple" ? "macOS apps" : (db.appName(owner) ?? prettyOwner(owner))
                entities.append(MapItem(id: "app:" + key, name: name, bytes: total, category: key == "com.apple" ? .system : .apps,
                                        children: ns.map { MapItem(id: $0.path, name: parentLabel($0.parent), bytes: $0.bytes, category: .apps, path: $0.path) }
                                            .sorted { $0.bytes > $1.bytes },
                                        bundleID: owner.contains(".") ? owner : nil,
                                        orphan: !installed && owner.contains("."),
                                        note: !installed && owner.contains(".") ? "Its app isn't installed — this was probably left behind." : nil))
            }
            return entities.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        }
    }

    static func display(_ n: IndexNode) -> String {
        if n.name == "Library" && n.parent == TidalPaths.home.path { return "Library" }
        if n.name == ".Trash" { return "Trash" }
        return n.name
    }

    static func parentLabel(_ parent: String) -> String {
        switch (parent as NSString).lastPathComponent {
        case "Caches": "Caches"
        case "Application Support": "Support files"
        case "Containers": "Container"
        case "Group Containers": "Shared container"
        case "Logs": "Logs"
        case "HTTPStorages": "Web storage"
        case "WebKit": "Web data"
        case "Saved Application State": "Window state"
        case "Preferences": "Preferences"
        case let s: s
        }
    }

    static func prettyOwner(_ o: String) -> String {
        guard o.contains(".") else { return o }
        let last = o.split(separator: ".").last.map(String.init) ?? o
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// Reduce a level to what a person can take in: the biggest items, plus one honest "the rest".
    static func visible(_ items: [MapItem], limit: Int = 34) -> [MapItem] {
        let sorted = items.sorted { $0.bytes > $1.bytes }
        guard sorted.count > limit else { return sorted }
        let head = Array(sorted.prefix(limit))
        let tail = sorted.dropFirst(limit)
        let rest = MapItem(id: "#more:" + (head.first?.id ?? ""), name: "\(tail.count) smaller items",
                           bytes: tail.reduce(0) { $0 + $1.bytes }, category: tail.first?.category ?? .other,
                           children: Array(tail))
        return head + [rest]
    }
}
