import SwiftUI
import AppKit

// The menu bar popover. Built by the agent only when it is opened and released when it closes.

struct PopoverData {
    var volume: VolumeInfo
    var held: Int64
    var freedTotal: Int64
    var autopilot: Bool
    var state: String // idle, working, attention, error
    var recent: [ActivityEntry]
    var pending: UninstallEvent?

    static func load(_ db: Database, state: String) -> PopoverData {
        let held = db.held().reduce(0) { $0 + $1.bytes }
        let pending = db.uninstalls().first { $0.state == "pending" && !$0.leftovers.isEmpty }
        let recent = db.activity(limit: 40).filter { $0.kind != "scan" }.prefix(4)
        return PopoverData(volume: .current(), held: held, freedTotal: Int64(db.get(SettingKey.freedTotal) ?? "0") ?? 0,
                           autopilot: db.bool(SettingKey.autopilot, default: false), state: state,
                           recent: Array(recent), pending: pending)
    }
}

struct PopoverActions {
    var open: () -> Void = {}
    var setAutopilot: (Bool) -> Void = { _ in }
    var runPass: () -> Void = {}
    var keep: (UninstallEvent) -> Void = { _ in }
    var drain: (UninstallEvent) -> Void = { _ in }
    var review: () -> Void = {}
    var quit: () -> Void = {}
}

struct PopoverView: View {
    @State var data: PopoverData
    var actions: PopoverActions
    var live = true

    private var stateLine: String {
        switch data.state {
        case "working": "Working quietly…"
        case "attention": "Something needs a look"
        case "error": "Agent stopped"
        default: data.autopilot ? "Watching · Autopilot" : "Watching · Manual"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                AgentPulse(state: data.state)
                Text("Tidal").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(stateLine).font(.system(size: 11.5)).foregroundStyle(Theme.mist)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            HStack(alignment: .center, spacing: 16) {
                SoundingColumn(total: data.volume.total, free: data.volume.available,
                               strata: [Stratum(id: "purge", name: "Purgeable", bytes: data.volume.purgeable, category: .purgeable, dashed: true),
                                        Stratum(id: "used", name: "Used", bytes: max(1, data.volume.used - data.volume.purgeable - data.held), category: .apps),
                                        Stratum(id: "holding", name: "Holding", bytes: data.held, category: .other, holding: true)]
                                   .filter { $0.bytes > 0 },
                               scanning: data.state == "working", live: live, compact: true, cornerRadius: 12)
                    .frame(width: 46, height: 92)
                VStack(alignment: .leading, spacing: 3) {
                    RollingBytes(bytes: data.volume.importantAvailable, size: 34, unitSize: 15)
                    Text("clear on \(data.volume.name)").font(.system(size: 12)).foregroundStyle(Theme.mist)
                    HStack(spacing: 5) {
                        Text("of \(ByteText.full(data.volume.total))")
                        if data.held > 0 {
                            Text("·")
                            Text("\(ByteText.full(data.held)) in holding")
                        } else if data.freedTotal > 0 {
                            Text("·")
                            Text("\(ByteText.full(data.freedTotal)) reclaimed")
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)

            if let u = data.pending {
                Divider().overlay(Theme.hairline)
                PendingUninstallRow(event: u, keep: { actions.keep(u); data.pending = nil },
                                    drain: { actions.drain(u); data.pending = nil }, review: actions.review)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.amber.opacity(0.06))
            }

            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 0) {
                Text("Recently").sectionLabel().padding(.bottom, 6)
                if data.recent.isEmpty {
                    Text("Nothing yet. Tidal sleeps until something changes.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.mist).padding(.vertical, 6)
                }
                ForEach(data.recent) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.at.formatted(date: .omitted, time: .shortened)).font(Theme.figure(10.5, .regular)).foregroundStyle(Theme.faint)
                            .frame(width: 52, alignment: .leading)
                        Text(e.title).font(.system(size: 11.5)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        if e.bytes > 0 { Text(ByteText.full(e.bytes)).font(Theme.figure(11)).foregroundStyle(e.kind == "clean" ? Theme.tide : Theme.mist) }
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { data.autopilot }, set: { v in
                    withAnimation(.smooth) { data.autopilot = v }
                    actions.setAutopilot(v)
                })) {
                    Text("Autopilot").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.tide)
                Spacer()
                Button(action: actions.runPass) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Look for clutter now")
                Menu {
                    Button("Run a Pass Now", action: actions.runPass)
                    Divider()
                    Button("Quit Tidal Agent", action: actions.quit)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button("Open Tidal", action: actions.open).buttonStyle(.glassProminent).tint(Theme.tide).controlSize(.small)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.mist)
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .frame(width: 340)
    }
}

struct PendingUninstallRow: View {
    let event: UninstallEvent
    var keep: () -> Void
    var drain: () -> Void
    var review: () -> Void
    private var total: Int64 { event.leftovers.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RippleRings(color: Theme.amber, rings: 2, duration: 2.2).frame(width: 46, height: 46)
                Image(systemName: "app.dashed").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.amber)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(event.name) is gone").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(ByteText.full(total)) left behind").font(.system(size: 11)).foregroundStyle(Theme.mist)
            }
            Spacer()
            Button("Keep", action: keep).buttonStyle(.borderless).foregroundStyle(Theme.mist).font(.system(size: 11.5))
            Button("Let it drain", action: drain).buttonStyle(.glass).controlSize(.small)
        }
        .contentShape(.rect)
        .onTapGesture(perform: review)
    }
}
