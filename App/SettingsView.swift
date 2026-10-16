import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var threshold: Double = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Settings").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent).tint(Theme.tide).keyboardShortcut(.defaultAction)
            }

            section("Per category", "What Autopilot may do with Safe items it finds. Review items always wait for you.") {
                VStack(spacing: 6) {
                    ForEach([SpaceCategory.apps, .system, .developer, .personal, .other, .backups]) { c in
                        HStack {
                            CategoryDot(category: c)
                            Text(c.title).font(.system(size: 12.5))
                            Spacer()
                            Picker("", selection: Binding(get: { store.policies[c] ?? .ask }, set: { store.setPolicy(c, $0) })) {
                                ForEach(Policy.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 270)
                        }
                    }
                }
            }

            section("Uninstalling", "When you drag an app to the Trash, Tidal moves everything it left behind to the holding area — no need to turn on Autopilot.") {
                Toggle("Remove an app's leftovers automatically", isOn: Binding(
                    get: { store.db.bool(SettingKey.autoUninstall, default: true) },
                    set: { store.db.set(SettingKey.autoUninstall, $0 ? "1" : "0"); store.requestAgent("settings") }))
                    .toggleStyle(.switch)
            }

            section("Holding area", "How long cleaned items stay restorable before they're purged.") {
                Picker("", selection: Binding(get: { store.holdDays }, set: { store.setHoldDays($0) })) {
                    Text("7 days").tag(7.0); Text("14 days").tag(14.0); Text("30 days").tag(30.0)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 270)
            }

            section("Low space", "When available space drops below this, the agent starts a quiet pass.") {
                HStack {
                    Slider(value: $threshold, in: 5...100, step: 5) { _ in store.db.set(SettingKey.freeThresholdGB, String(threshold)) }
                    Text("\(Int(threshold)) GB").font(Theme.figure(12.5)).frame(width: 52, alignment: .trailing)
                }
            }

            section("Background agent", "A tiny service that sleeps until macOS reports a change. It never polls.") {
                VStack(alignment: .leading, spacing: 8) {
                    status(store.agentHealth == .running, store.agentHealth.title)
                    status(store.hasFDA, store.hasFDA ? "Full Disk Access granted to Tidal" : "Tidal has no Full Disk Access — reduced mode")
                    if store.agentHealth == .running {
                        status(store.agentFDA, store.agentFDA ? "Full Disk Access granted to Tidal Agent" : "Tidal Agent has no Full Disk Access")
                    }
                    HStack {
                        Button("Full Disk Access…") { store.openFullDiskAccess() }.buttonStyle(.glass)
                        Button("Login Items…") { store.openLoginItems() }.buttonStyle(.glass)
                        if store.agentHealth != .running { Button("Start Agent") { store.launchAgentDirectly() }.buttonStyle(.glass) }
                        Spacer()
                        Button("Rebuild Index") { store.reindex(); dismiss() }.buttonStyle(.glass)
                    }
                }
            }

            Text("Catalog v\(store.engine.catalog.version) · \(store.engine.catalog.rules.count) rules · Tidal only touches locations it has explicit rules for.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
        }
        .padding(26)
        .frame(width: 600)
        .onAppear { threshold = store.db.double(SettingKey.freeThresholdGB, default: 20); store.refreshAgentHealth() }
    }

    private func section<C: View>(_ title: String, _ sub: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.tide : .secondary)
            Text(text).font(.system(size: 12))
        }
    }
}
