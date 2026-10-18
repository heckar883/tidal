import SwiftUI
import AppKit

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Namespace private var glass

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .top) {
            WaterBackground()

            if store.condition == .firstRun {
                FirstRunView().transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    TopBar(ns: glass).padding(.top, 10).padding(.horizontal, 16)
                    Banners().padding(.horizontal, 24).padding(.top, 10)
                    ZStack {
                        switch store.place {
                        case .now: NowView().transition(placeTransition)
                        case .map: MapScreen().transition(placeTransition)
                        case .activity: ActivityScreen().transition(placeTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.88), value: store.place)
                }
                .transition(.opacity)
            }

            ParticleOverlay(system: store.particles)

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 22)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .coordinateSpace(.named("root"))
        .ignoresSafeArea()
        .sheet(isPresented: $store.showSettings) { SettingsView().environment(store) }
        .onAppear { store.particles.reduceMotion = reduceMotion; Snapshot.runIfRequested(store) }
        .onChange(of: reduceMotion) { _, v in store.particles.reduceMotion = v }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            if let w = n.object as? NSWindow, w.isVisible { store.windowVisible = w.occlusionState.contains(.visible) && !w.isMiniaturized }
        }
        .onChange(of: activeState) { _, s in
            // Draw only while the window can be seen; every loop pauses when it can't.
            if s == .key || s == .active { store.windowVisible = true }
        }
    }

    private var placeTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                              removal: .opacity.combined(with: .offset(y: -6)))
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(Store.self) private var store
    let ns: Namespace.ID

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Color.clear.frame(width: 68, height: 1) // traffic lights
                Wordmark()
                Spacer()
                HoldingCounter()
                ModeSwitch(ns: ns)
                Button { store.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Settings")
            }
            PlaceTabs(ns: ns)
        }
        .frame(height: 44)
    }
}

struct Wordmark: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 7) {
            AgentPulse(state: store.agentHealth == .running ? (store.scanning ? "working" : store.agentState) : "off")
            Text("Tidal").font(.system(size: 15, weight: .semibold)).tracking(0.2).foregroundStyle(Theme.ink)
        }
        .help(store.agentHealth.title)
    }
}

struct PlaceTabs: View {
    @Environment(Store.self) private var store
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Place.allCases) { p in
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { store.place = p }
                    Haptics.snap()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.symbol).font(.system(size: 11, weight: .semibold))
                        Text(p.title).font(.system(size: 12.5, weight: .semibold))
                        if p == .now, !store.pendingUninstalls.isEmpty {
                            Circle().fill(Theme.amber).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(store.place == p ? Theme.ink : Theme.mist)
                    .padding(.horizontal, 15).frame(height: 30)
                    .background {
                        if store.place == p {
                            Capsule().fill(Theme.washStrong)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

/// What is waiting in holding; flows into Activity. Droplets land here when the column isn't on screen.
struct HoldingCounter: View {
    @Environment(Store.self) private var store
    @State private var bump = false

    var body: some View {
        let holding = store.heldBytes
        let shown = holding > 0 ? holding : store.freedTotal
        HStack(spacing: 8) {
            Image(systemName: holding > 0 ? "tray.full" : "arrow.down.to.line.compact").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tide)
            RollingBytes(bytes: shown, size: 13.5, unitSize: 10.5, weight: .semibold)
            Text(holding > 0 ? "in holding" : "reclaimed").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .onTapGesture { withAnimation(.smooth) { store.place = .activity } }
        .padding(.horizontal, 14).frame(height: 34)
        .glassEffect(.regular.tint(Theme.tide.opacity(bump ? 0.3 : 0)), in: .capsule)
        .scaleEffect(bump ? 1.06 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { store.particles.sink = $0 }
        .onChange(of: store.particles.landed) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { bump = false } }
        }
        .help(holding > 0 ? "Released items wait in holding and stay restorable for \(Int(store.holdDays)) days. The space returns when they drain, or empty it now in Activity."
                          : "Space Tidal has reclaimed so far.")
    }
}

/// One control switches mode; the screens stay the same.
struct ModeSwitch: View {
    @Environment(Store.self) private var store
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            segment("Manual", symbol: "hand.point.up.left", on: !store.autopilot) { store.setAutopilot(false) }
            segment("Autopilot", symbol: "water.waves", on: store.autopilot) { store.setAutopilot(true) }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .help(store.autopilot ? "Autopilot releases Safe items on its own. Your-call items wait for you."
                              : "Manual: Tidal pre-selects what it would release. You decide.")
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? (title == "Autopilot" ? Theme.onTide : Theme.ink) : Theme.mist)
            .padding(.horizontal, 12).frame(height: 28)
            .background {
                if on {
                    Capsule().fill(title == "Autopilot" ? AnyShapeStyle(Theme.tide) : AnyShapeStyle(Theme.washStrong))
                        .matchedGeometryEffect(id: "mode", in: ns)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Banners

struct Banners: View {
    @Environment(Store.self) private var store
    @AppStorage("fdaDismissed") private var fdaDismissed = false

    var body: some View {
        VStack(spacing: 8) {
            if !store.hasFDA && !fdaDismissed && store.forced == nil {
                banner(symbol: "lock.shield", tint: Theme.tide,
                       title: "Reduced mode",
                       text: "Without Full Disk Access, Tidal can't see the Trash, Mail, Messages or device backups. Those areas are marked as unread instead of being undercounted.",
                       action: "Grant Access", run: store.openFullDiskAccess,
                       dismiss: { withAnimation(.smooth) { fdaDismissed = true } })
            }
            if store.agentHealth == .needsApproval && store.forced == nil {
                banner(symbol: "person.badge.clock", tint: Theme.amber,
                       title: "Allow the agent",
                       text: "Turn on Tidal in Login Items so it keeps watching quietly after this window closes.",
                       action: "Open Login Items", run: store.openLoginItems, dismiss: nil)
            }
        }
        .animation(.smooth, value: store.hasFDA)
    }

    private func banner(symbol: String, tint: Color, title: String, text: String, action: String,
                        run: @escaping () -> Void, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.mist).lineLimit(2)
            }
            Spacer()
            Button(action, action: run).buttonStyle(.glass).controlSize(.regular)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Not now")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(tint.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 0.6))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - First run

struct FirstRunView: View {
    @Environment(Store.self) private var store
    @State private var autopilot = true
    @State private var shown = false

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            SoundingColumn(total: store.volume.total, free: store.volume.available,
                           strata: store.nodes.isEmpty ? [] : store.strata, scanning: true, live: store.windowVisible)
                .frame(width: 260)
                .padding(.vertical, 60)
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 20)

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Tidal").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.ink)
                    Text("Tidal keeps your disk clear on its own, and sleeps until something changes.")
                        .font(.system(size: 14)).foregroundStyle(Theme.mist)
                }
                VStack(alignment: .leading, spacing: 14) {
                    point("arrow.down.to.line", "Caches, logs and leftovers drain to a holding area first. Nothing is deleted for 14 days.")
                    point("trash", "Drag an app to the Trash and Tidal finds what it left behind.")
                    point("moon.zzz", "Near-zero CPU and memory while idle. No polling, no accounts, no telemetry.")
                }
                .opacity(shown ? 1 : 0)

                VStack(alignment: .leading, spacing: 0) {
                    Text("How should Tidal work?").sectionLabel().padding(.bottom, 8)
                    choice(true, "Autopilot", "Release safe items as they settle. Anything personal waits for you.")
                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 32)
                    choice(false, "Manual", "Tidal pre-selects what it would release. You decide.")
                }

                HStack(spacing: 12) {
                    Image(systemName: store.hasFDA ? "checkmark.circle.fill" : "lock.shield").foregroundStyle(store.hasFDA ? Theme.tide : Theme.amber)
                    Text(store.hasFDA ? "Full Disk Access granted" : "Full Disk Access lets Tidal see the Trash and app containers.")
                        .font(.system(size: 12)).foregroundStyle(Theme.mist)
                    if !store.hasFDA { Button("Grant…") { store.openFullDiskAccess() }.buttonStyle(.glass).controlSize(.small) }
                }

                HStack(spacing: 14) {
                    Button { store.finishOnboarding(autopilot: autopilot) } label: { Text("Begin").frame(minWidth: 80) }
                        .buttonStyle(.glassProminent).tint(Theme.tide).controlSize(.large).keyboardShortcut(.defaultAction)
                    HStack(spacing: 7) {
                        AgentPulse(state: "working")
                        Text(store.indexProgress.isEmpty ? "Sounding your disk…" : "Measuring \(store.indexProgress)")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 12)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if Motion.frozen { shown = true } else { withAnimation(.smooth(duration: 1.0).delay(0.15)) { shown = true } } }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tide).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button { withAnimation(.spring(response: 0.3)) { autopilot = value } } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(autopilot == value ? Theme.tide : Theme.faint, lineWidth: 1.2)
                    if autopilot == value { Circle().fill(Theme.tide).padding(4) }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.mist)
                }
                Spacer()
            }
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
