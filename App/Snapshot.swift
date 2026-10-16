import AppKit
import SwiftUI

/// Design QA: with TIDAL_SNAPSHOT=<dir>, the app captures its own window on each screen and quits.
@MainActor
enum Snapshot {
    static func runIfRequested(_ store: Store) {
        guard let dir = ProcessInfo.processInfo.environment["TIDAL_SNAPSHOT"] else { return }
        let places: [Place] = [.now, .map, .activity]
        var delay = 7.0
        for p in places {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { store.place = p }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 3.5) { capture(to: "\(dir)/\(p.rawValue).png") }
            delay += 5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) { NSApp.terminate(nil) }
    }

    static func capture(to path: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
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
