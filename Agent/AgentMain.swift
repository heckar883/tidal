import AppKit

@main
enum AgentMain {
    static let agent = Agent()

    static func main() {
        // Self-test against a fixture root: `TidalAgent --selftest` with TIDAL_HOME/TIDAL_SUPPORT set.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--index"), i + 1 < CommandLine.arguments.count {
            // Read-only: measure a tree and print what the indexer sees, without touching the shared index.
            let db = Database(url: URL(fileURLWithPath: NSTemporaryDirectory() + "tidal-index-debug.sqlite"))
            let ix = SpaceIndexer(db: db)
            let t = Date()
            let total = ix.scan(root: CommandLine.arguments[i + 1], maxDepth: 2, minEmit: 4 * 1_048_576)
            print("total", Fmt.bytes(total), "in", String(format: "%.1fs", Date().timeIntervalSince(t)))
            for n in ix.nodes().filter({ $0.depth == 2 }).sorted(by: { $0.bytes > $1.bytes }).prefix(15) { print(n.depth, n.flags, Fmt.bytes(n.bytes), n.path) }
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = agent
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
