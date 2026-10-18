import AppKit
import SwiftUI

/// Design QA: with TIDAL_SNAPSHOT=<dir>, the app captures each screen and quits. Strictly read-only.
///   TIDAL_APPEARANCE=light|dark   which appearance (file suffix)
///   TIDAL_STATE=firstrun|scanning|empty|error   capture only the main window in that state
@MainActor
enum Snapshot {
    private static var aux: NSWindow?
    private static var auxView: (AnyView, NSSize)?
    private static var started = false
    private static weak var store: Store?
    /// When the screen is locked, window captures come back blank; render the views instead.
    static let offscreen = Motion.frozen

    static func runIfRequested(_ store: Store) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TIDAL_SNAPSHOT"], !started else { return }
        started = true
        Snapshot.store = store
        let suffix = "-" + (env["TIDAL_APPEARANCE"] ?? "dark")
        let defaults = UserDefaults.standard
        let savedStyle = defaults.string(forKey: "map.view")
        if let w = mainWindow {
            w.setContentSize(NSSize(width: 1240, height: 800))
            w.center()
        }

        var t = 6.0
        func at(_ delay: Double, _ run: @escaping () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: run)
        }

        if let state = env["TIDAL_STATE"] {
            at(0) { capture(mainWindow, to: "\(dir)/state-\(state)\(suffix).png") }
            at(1) { NSApp.terminate(nil) }
            return
        }

        at(0) { store.place = .now }
        at(3) { capture(mainWindow, to: "\(dir)/now\(suffix).png") }

        let fake = sampleUninstall()
        at(0.5) { withAnimation(.smooth) { store.uninstalls.append(fake) } }
        at(3.5) { capture(mainWindow, to: "\(dir)/now-uninstall\(suffix).png") }
        at(0.2) { store.uninstalls.removeAll { $0.id == fake.id } }

        at(0.3) { defaults.set(MapStyle.pools.rawValue, forKey: "map.view"); store.place = .map }
        at(3.5) { capture(mainWindow, to: "\(dir)/map\(suffix).png") }
        let savedGrouping = defaults.string(forKey: "map.grouping")
        at(0.2) { defaults.set(Grouping.apps.rawValue, forKey: "map.grouping") }
        at(3.5) { capture(mainWindow, to: "\(dir)/map-apps\(suffix).png") }
        at(0.2) { defaults.set(Grouping.categories.rawValue, forKey: "map.grouping") }
        at(3.5) { capture(mainWindow, to: "\(dir)/map-categories\(suffix).png") }
        at(0.2) { if let savedGrouping { defaults.set(savedGrouping, forKey: "map.grouping") } else { defaults.removeObject(forKey: "map.grouping") } }
        at(0.2) {
            if let savedStyle { defaults.set(savedStyle, forKey: "map.view") } else { defaults.removeObject(forKey: "map.view") }
            store.place = .activity
        }
        at(3.5) { capture(mainWindow, to: "\(dir)/activity\(suffix).png") }

        at(0.3) { show(SettingsView().environment(store), size: NSSize(width: 620, height: 720), backdrop: false) }
        at(2.5) { capture(aux, to: "\(dir)/settings\(suffix).png"); closeAux() }

        at(0.3) {
            let data = PopoverData.load(store.db, state: store.agentState)
            show(Desk(alignment: .topTrailing) {
                PopoverView(data: data, actions: PopoverActions())
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            }, size: NSSize(width: 560, height: 560), backdrop: true)
        }
        at(2.5) { capture(aux, to: "\(dir)/popover\(suffix).png"); closeAux() }

        at(0.3) {
            show(Desk(alignment: .topTrailing) {
                UninstallPrompt(event: fake, icon: NSWorkspace.shared.icon(for: .applicationBundle)) { _ in }
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
            }, size: NSSize(width: 560, height: 330), backdrop: true)
        }
        at(3.4) { capture(aux, to: "\(dir)/uninstall\(suffix).png"); closeAux() }

        at(1) { NSApp.terminate(nil) }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 900 && $0 !== aux } }

    /// A stand-in for the desktop under the menu bar, so floating surfaces are shown in place.
    private struct Desk<Content: View>: View {
        var alignment: Alignment
        @ViewBuilder var content: Content
        var body: some View {
            ZStack(alignment: alignment) {
                WaterBackground()
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Spacer()
                        Image(systemName: "drop.fill").font(.system(size: 13, weight: .medium))
                        Image(systemName: "wifi").font(.system(size: 12))
                        Text("Sat 10:42").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(height: 26)
                    .background(.bar)
                    Spacer()
                }
                content.padding(.top, 34).padding(.trailing, 40).padding(.leading, 40)
            }
        }
    }

    private static func show<V: View>(_ view: V, size: NSSize, backdrop: Bool) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        w.center()
        w.orderFrontRegardless()
        aux = w
        auxView = (AnyView(view), size)
    }

    private static func closeAux() { aux?.orderOut(nil); aux = nil; auxView = nil }

    private static func render(_ view: AnyView, size: NSSize, to path: String) {
        let dark = (ProcessInfo.processInfo.environment["TIDAL_APPEARANCE"] ?? "dark") == "dark"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 2
            guard let cg = r.cgImage else { return }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    static func sampleUninstall() -> UninstallEvent {
        let base = TidalPaths.home.path + "/Library"
        func c(_ sub: String, _ title: String, _ tier: Tier, _ mb: Int64) -> Candidate {
            Candidate(path: "\(base)/\(sub)/com.example.sketchbook", name: "com.example.sketchbook", owner: "Sketchbook", ruleID: "snap",
                      ruleTitle: title, tier: tier, category: .apps, kind: "leftover", bytes: mb * 1_048_576, modified: nil)
        }
        return UninstallEvent(id: "snapshot-sample", bundleID: "com.example.sketchbook", name: "Sketchbook", at: Date(),
                              autoCleaned: 212 * 1_048_576,
                              leftovers: [c("Application Support", "Support files", .review, 1240), c("Containers", "Container", .review, 318),
                                          c("Caches", "App caches", .safe, 96), c("Logs", "App logs", .safe, 12)],
                              state: "pending", confident: true)
    }

    static func capture(_ w: NSWindow?, to path: String) {
        if offscreen {
            if w === aux, let (v, size) = auxView { render(v, size: size, to: path) }
            else if let store { render(AnyView(RootView().environment(store).coordinateSpace(.named("root"))), size: NSSize(width: 1240, height: 800), to: path) }
            return
        }
        guard let w else { return }
        let id = CGWindowID(w.windowNumber)
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var image: CGImage?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            image = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                       CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?.takeRetainedValue()
        }
        if image == nil, let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
