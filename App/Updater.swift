import SwiftUI

/// Asks GitHub for the newest release when the person taps Check. Never runs by itself, so idle stays idle.
@MainActor
@Observable
final class Updater {
    enum State: Equatable { case idle, checking, current, available(String, URL), failed(String) }

    var state: State = .idle
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let api = URL(string: "https://api.github.com/repos/heckar883/tidal/releases/latest")!
    static let page = URL(string: "https://github.com/heckar883/tidal/releases/latest")!

    func check() {
        state = .checking
        var req = URLRequest(url: Self.api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = o["tag_name"] as? String else { throw URLError(.badServerResponse) }
                let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let asset = (o["assets"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Tidal.zip" }
                let url = (asset?["browser_download_url"] as? String).flatMap(URL.init) ?? Self.page
                state = Self.newer(v, than: Self.current) ? .available(v, url) : .current
            } catch {
                state = .failed("Couldn't reach GitHub")
            }
        }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
