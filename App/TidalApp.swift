import SwiftUI
import AppKit

@main
struct TidalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        Window("Tidal", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1020, minHeight: 680)
                .preferredColorScheme(.dark)
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
