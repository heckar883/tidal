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
            AbyssBackground()

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
            // Draw at full rate only while focused; animation loops pause when the window is in the background.
            if s == .key || s == .active { store.windowVisible = true }
        }
    }

    private var placeTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .offset(y: 8)),
                                              removal: .opacity.combined(with: .scale(scale: 1.01)))
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
                FreedCounter()
                ModeSwitch(ns: ns)
                Button { store.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium)).frame(width: 34, height: 34)
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
            AgentPulse(state: store.agentHealth == .running ? store.agentState : "off")
            Text("Tidal").font(.system(size: 15, weight: .semibold)).tracking(0.3).foregroundStyle(Theme.ink)
        }
        .help(store.agentHealth.title)
    }
}

/// The agent's state at a glance: still when idle, breathing while it works.
struct AgentPulse: View {
    let state: String
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var color: Color {
        switch state {
        case "working": Theme.tide
        case "attention": Theme.tierColor(.review)
        case "off": Theme.faint
        default: Theme.tide.opacity(0.75)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25)).frame(width: 14, height: 14)
                .scaleEffect(breathe && state == "working" ? 1.5 : 1).opacity(breathe && state == "working" ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .onAppear { if !reduceMotion { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true } } }
    }
}

struct PlaceTabs: View {
    @Environment(Store.self) private var store
    let ns: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 2) {
                ForEach(Place.allCases) { p in
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { store.place = p }
                        Haptics.snap()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.symbol).font(.system(size: 11.5, weight: .semibold))
                            Text(p.title).font(.system(size: 12.5, weight: .semibold))
                            if p == .now, !store.pendingUninstalls.isEmpty {
                                Circle().fill(Theme.tierColor(.review)).frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(store.place == p ? Theme.ink : Theme.mist)
                        .padding(.horizontal, 15).frame(height: 32)
                        .background {
                            if store.place == p {
                                Capsule().fill(.white.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
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
}

struct FreedCounter: View {
    @Environment(Store.self) private var store
    @State private var bump = false

    var body: some View {
        // Honest numbers: cleaned items sit in holding until it is emptied; only then is space back.
        let holding = store.heldBytes
        let shown = holding > 0 ? holding : store.freedTotal
        HStack(spacing: 8) {
            Image(systemName: holding > 0 ? "tray.full" : "arrow.down.to.line.compact").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tide)
            RollingBytes(bytes: shown, size: 14, unitSize: 11, weight: .semibold)
            Text(holding > 0 ? "in holding" : "reclaimed").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .onTapGesture { withAnimation(.smooth) { store.place = .activity } }
        .padding(.horizontal, 14).frame(height: 34)
        .glassEffect(.regular.tint(Theme.tide.opacity(bump ? 0.35 : 0.06)), in: .capsule)
        .scaleEffect(bump ? 1.07 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { store.particles.sink = $0 }
        .onChange(of: store.particles.landed) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { bump = false } }
        }
        .help(holding > 0 ? "Cleaned items wait in the holding area and stay restorable for \(Int(store.holdDays)) days. The space returns when they're purged — or empty it now in Activity."
                          : "Space Tidal has reclaimed so far.")
    }
}

/// One control switches mode with a morph; the screens stay the same.
struct ModeSwitch: View {
    @Environment(Store.self) private var store
    let ns: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 0) {
                segment("Manual", symbol: "hand.point.up.left", on: !store.autopilot) { store.setAutopilot(false) }
                segment("Autopilot", symbol: "sparkles", on: store.autopilot) { store.setAutopilot(true) }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .help(store.autopilot ? "Autopilot cleans Safe items on its own. Review items wait for you."
                              : "Manual: Tidal pre-selects what it would clean. You decide.")
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? (title == "Autopilot" ? Color.black.opacity(0.85) : Theme.ink) : Theme.mist)
            .padding(.horizontal, 12).frame(height: 28)
            .background {
                if on {
                    Capsule().fill(title == "Autopilot" ? AnyShapeStyle(Theme.tide.gradient) : AnyShapeStyle(.white.opacity(0.13)))
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
            if !store.hasFDA && !fdaDismissed {
                banner(symbol: "lock.shield", tint: Theme.tide,
                       title: "Reduced mode",
                       text: "Without Full Disk Access, Tidal can't see the Trash, Mail, Messages or device backups. Those areas are marked as unread instead of being undercounted.",
                       action: "Grant Access", run: store.openFullDiskAccess,
                       dismiss: { withAnimation(.smooth) { fdaDismissed = true } })
            }
            if store.agentHealth == .needsApproval {
                banner(symbol: "person.badge.clock", tint: Theme.tierColor(.review),
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
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint).frame(width: 24)
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
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassEffect(.regular.tint(tint.opacity(0.05)), in: .rect(cornerRadius: 18))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
