import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @State private var threshold: Double = 20
    @State private var autoUninstall = true
    @State private var autoSystem = true
    @State private var updater = Updater()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Settings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent).tint(Theme.tide).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)

            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("General") }

                Section {
                    ForEach([SpaceCategory.apps, .system, .developer, .personal, .other, .backups]) { c in
                        Picker(selection: Binding(get: { store.policies[c] ?? .ask }, set: { store.setPolicy(c, $0) })) {
                            ForEach(Policy.allCases, id: \.self) { Text($0.title).tag($0) }
                        } label: {
                            HStack(spacing: 8) { CategoryDot(category: c); Text(c.title) }
                        }
                    }
                } header: { Text("Autopilot") } footer: {
                    Text("What Autopilot may release on its own, per kind of space. Items that need your call always wait for you.")
                }

                Section {
                    Toggle("Remove an app's leftovers automatically", isOn: Binding(get: { autoUninstall }, set: { v in
                        autoUninstall = v
                        store.db.set(SettingKey.autoUninstall, v ? "1" : "0")
                        store.requestAgent("settings")
                    }))
                } header: { Text("Uninstalling") } footer: {
                    Text("When you drag an app to the Trash, Tidal drains what it left behind to holding, even with Autopilot off.")
                }

                Section {
                    Toggle("Clean system data automatically", isOn: Binding(get: { autoSystem }, set: { v in
                        autoSystem = v
                        store.db.set(SettingKey.autoSystem, v ? "1" : "0")
                        store.requestAgent("settings")
                    }))
                } header: { Text("System data") } footer: {
                    Text("With Autopilot on, Tidal clears temporary folders, Homebrew leftovers and old iPhone firmware about once a day. Unlike everything else, this is permanent. Anything that needs your password or a look first stays in the System data sheet.")
                }

                Section {
                    Picker("Keep released items for", selection: Binding(get: { store.holdDays }, set: { store.setHoldDays($0) })) {
                        Text("7 days").tag(7.0); Text("14 days").tag(14.0); Text("30 days").tag(30.0)
                    }
                    LabeledContent("Step in below") {
                        HStack {
                            Slider(value: $threshold, in: 5...100, step: 5) { _ in store.db.set(SettingKey.freeThresholdGB, String(threshold)) }
                                .frame(width: 200)
                            Text("\(Int(threshold)) GB free").font(Theme.figure(12)).frame(width: 74, alignment: .trailing)
                        }
                    }
                } header: { Text("Holding and low space") } footer: {
                    Text("Released items stay restorable, then drain away. Below the free-space mark, the agent starts a quiet pass.")
                }

                Section {
                    LabeledContent("Tidal \(Updater.current)") {
                        HStack(spacing: 10) {
                            switch updater.state {
                            case .idle: EmptyView()
                            case .checking: ProgressView().controlSize(.small)
                            case .current: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.tide)
                            case .failed(let m): Text(m).foregroundStyle(.secondary)
                            case .available(let v, let url):
                                Button("Download \(v)") { NSWorkspace.shared.open(url) }.buttonStyle(.glassProminent).tint(Theme.tide)
                            }
                            Button("Check for Updates") { updater.check() }.disabled(updater.state == .checking)
                        }
                    }
                } header: { Text("Updates") } footer: {
                    Text("Checks GitHub only when you ask. Downloading opens the newest Tidal.zip; replace the app in Applications and open it.")
                }

                Section {
                    status(store.agentHealth == .running, store.agentHealth.title)
                    status(store.hasFDA, store.hasFDA ? "Full Disk Access granted to Tidal" : "Tidal has no Full Disk Access (reduced mode)")
                    if store.agentHealth == .running {
                        status(store.agentFDA, store.agentFDA ? "Full Disk Access granted to Tidal Agent" : "Tidal Agent has no Full Disk Access")
                    }
                    HStack {
                        Button("Full Disk Access…") { store.openFullDiskAccess() }
                        Button("Login Items…") { store.openLoginItems() }
                        if store.agentHealth != .running { Button("Start Agent") { store.launchAgentDirectly() } }
                        Spacer()
                        Button("Rebuild Index") { store.reindex(); dismiss() }
                    }
                } header: { Text("Background agent") } footer: {
                    Text("A tiny service that sleeps until macOS reports a change. It never polls. Catalog v\(store.engine.catalog.version), \(store.engine.catalog.rules.count) rules: Tidal only touches locations it has an explicit rule for.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                Text("Made by").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if let url = Bundle.main.url(forResource: "0vyx-logo", withExtension: "png"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(height: 13)
                }
                Text("0vyx").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 620, height: 780)
        .onAppear {
            threshold = store.db.double(SettingKey.freeThresholdGB, default: 20)
            autoUninstall = store.db.bool(SettingKey.autoUninstall, default: true)
            autoSystem = store.db.bool(SettingKey.autoSystem, default: true)
            store.refreshAgentHealth()
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.tide : .secondary)
            Text(text)
        }
    }
}
