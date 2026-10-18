import SwiftUI
import AppKit

// MARK: - Sheet

@MainActor
@Observable
final class SystemCleanModel {
    var tasks: [SystemTask] = []
    var info: [SystemInfoRow] = []
    var picked = Set<String>()
    var scanning = true
    var running = false
    var result: String?

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let r = SystemCleaner.scan()
            Task { @MainActor in
                self.tasks = r.tasks
                self.info = r.info
                self.picked = Set(r.tasks.filter { !$0.review }.map(\.id))
                self.scanning = false
            }
        }
    }

    var pickedBytes: Int64 { tasks.filter { picked.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    func run(store: Store) {
        let chosen = tasks.filter { picked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let r = SystemCleaner.run(chosen)
            Task { @MainActor in
                self.running = false
                let ok = r.filter { $0.error == nil }
                let failed = r.filter { $0.error != nil }
                let freed = ok.reduce(0) { $0 + $1.freed }
                if freed > 0 {
                    store.db.log("purge", "System data cleaned: \(ok.filter { $0.freed > 0 }.map(\.task.title).prefix(3).joined(separator: ", "))", "Permanent — not kept in holding", bytes: freed)
                    let total = Int64(store.db.get(SettingKey.freedTotal) ?? "0") ?? 0
                    store.db.set(SettingKey.freedTotal, String(total + freed))
                }
                if let f = failed.first { store.db.log("refuse", "\(f.task.title) was not cleaned", f.error ?? "") }
                self.result = failed.isEmpty ? "\(Fmt.bytes(freed)) cleaned" : (ok.isEmpty ? "Nothing cleaned — \(failed[0].error ?? "")" : "\(Fmt.bytes(freed)) cleaned, \(failed.count) skipped")
                store.reloadFromDisk(nodesToo: false)
                store.volume = VolumeInfo.current()
                store.reindex()
                self.scan()
            }
        }
    }
}

struct SystemCleanSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = SystemCleanModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System data").font(.system(size: 20, weight: .semibold))
                    Text("Things inside macOS & system data that are safe to clear. Unlike everything else in Tidal, this is permanent — nothing goes to the holding area.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }

            if model.scanning {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Measuring system locations…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if model.tasks.isEmpty {
                Text("Nothing safe to clear right now.").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.tasks) { t in row(t) }
                    }
                }
                .frame(maxHeight: 300)
            }

            if !model.info.isEmpty && !model.scanning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Left alone on purpose").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.info) { i in
                        HStack(alignment: .firstTextBaseline) {
                            Text(i.title).font(.system(size: 12))
                            Text(i.detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                            Spacer()
                            Text(Fmt.bytes(i.bytes)).font(Theme.figure(11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                if let r = model.result { Text(r).font(.system(size: 12)).foregroundStyle(Theme.tide) }
                Spacer()
                if model.tasks.contains(where: { model.picked.contains($0.id) && $0.admin }) {
                    Label("Asks for your password once", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button {
                    model.run(store: store)
                } label: {
                    if model.running { ProgressView().controlSize(.small) }
                    else { Text(model.pickedBytes > 0 ? "Clean \(Fmt.bytes(model.pickedBytes))" : "Clean selected") }
                }
                .buttonStyle(.glassProminent).tint(Theme.tideDeep)
                .disabled(model.picked.isEmpty || model.running || model.scanning)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { model.scan() }
    }

    private func row(_ t: SystemTask) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { model.picked.contains(t.id) }, set: { on in
                if on { model.picked.insert(t.id) } else { model.picked.remove(t.id) }
            })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.title).font(.system(size: 13, weight: .medium))
                    if t.admin { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    if t.review { Text("REVIEW").font(.system(size: 8.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.tierColor(.review)) }
                }
                Text(t.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(t.sizeKnown ? Fmt.bytes(t.bytes) : "varies").font(Theme.figure(13)).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
