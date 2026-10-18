import AppKit
import SwiftUI

/// A calm, non-blocking prompt near the menu bar: "X is gone. 1.4 GB left behind."
final class UninstallPanel {
    typealias Action = UninstallPrompt.Action

    private let panel: NSPanel
    private var dismissTimer: Timer?

    init(event: UninstallEvent, icon: NSImage?, holdDays: Int, onAction: @escaping (Action) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 408, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        var closeRef: (() -> Void)?
        let view = UninstallPrompt(event: event, icon: icon, holdDays: holdDays) { action in
            closeRef?()
            if let action { onAction(action) }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(4)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        closeRef = { [weak self] in self?.close() }
    }

    func present(near statusFrame: NSRect?) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let x = min(max((statusFrame?.midX ?? vf.maxX) - size.width + 40, vf.minX + 12), vf.maxX - size.width - 12)
        panel.setFrame(NSRect(x: x, y: vf.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
        // Leave quietly if ignored; the menu bar icon keeps the "needs a look" state.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        dismissTimer?.invalidate()
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
        })
    }
}
