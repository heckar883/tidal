import SwiftUI
import AppKit

@main
struct TidalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        Window("Tidal", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1020, minHeight: 680)
                .preferredColorScheme(Appearance.resolved(appearance).scheme)
                .onAppear { Appearance.resolved(appearance).apply() }
                .onChange(of: appearance) { _, v in Appearance.resolved(v).apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                Button("Now") { store.place = .now }.keyboardShortcut("1")
                Button("Map") { store.place = .map }.keyboardShortcut("2")
                Button("Activity") { store.place = .activity }.keyboardShortcut("3")
            }
            CommandMenu("Clean") {
                Button("Look Again") { store.discover() }.keyboardShortcut("r")
                Button("Clean Selected") { store.cleanSelected() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.autopilot || store.selected.isEmpty)
                Divider()
                Button(store.autopilot ? "Switch to Manual" : "Switch to Autopilot") { store.setAutopilot(!store.autopilot) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showSettings = true }.keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The interface only exists while its window is open: closing it frees all memory and GPU use.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }

    /// `TIDAL_APPEARANCE=light|dark` wins, so snapshot runs can capture both.
    static func resolved(_ stored: String) -> Appearance {
        if let e = ProcessInfo.processInfo.environment["TIDAL_APPEARANCE"], let a = Appearance(rawValue: e) { return a }
        return Appearance(rawValue: stored) ?? .system
    }

    func apply() {
        NSApp.appearance = self == .light ? NSAppearance(named: .aqua) : self == .dark ? NSAppearance(named: .darkAqua) : nil
    }
}
