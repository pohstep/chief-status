import AppKit
import Foundation

enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Chief Status", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.plist")
    }

    static var path: String {
        fileURL.path
    }

    /// Optional chat links, kept on this Mac only: {"Agent1": "https://example.com/agent1"}.
    /// A url sent by the bot in the feed wins over this file.
    static var linksURL: URL {
        directory.appendingPathComponent("links.json")
    }

    static func readLinks() -> [String: String] {
        guard let data = try? Data(contentsOf: linksURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var links: [String: String] = [:]
        for (name, value) in object {
            guard let text = value as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                links[name] = trimmed
            }
        }
        return links
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func readFeedURL() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        guard let feed = plist["feedURL"] as? String else { return nil }
        let trimmed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    static func write(_ dict: [String: Any]) {
        ensureDirectory()
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func write(feedURL: String) {
        var dict = read()
        dict["feedURL"] = feedURL
        write(dict)
    }

    /// Missing means off. Alerts are opt-in.
    static func readAlert() -> Bool {
        read()["alertOnFailure"] as? Bool ?? false
    }

    static func setAlert(_ on: Bool) {
        var dict = read()
        dict["alertOnFailure"] = on
        write(dict)
    }

    /// Missing means open. The panel remembers a collapse.
    static func readTodayExpanded() -> Bool {
        if let value = read()["todayExpanded"] as? Bool {
            return value
        }
        return true
    }

    static func setTodayExpanded(_ on: Bool) {
        var dict = read()
        dict["todayExpanded"] = on
        write(dict)
    }

    static func liveWebSocketURL(from feed: String) -> URL? {
        guard var components = URLComponents(string: feed) else { return nil }
        var path = components.path
        if path.lowercased().hasSuffix("/status") {
            path += "/live"
        } else {
            while path.hasSuffix("/") { path.removeLast() }
            path += "/status/live"
        }
        components.path = path
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }
        return components.url
    }

    static func needsSetup(_ url: String?) -> Bool {
        guard let url = url else { return true }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.contains("REPLACE-ME")
    }

    /// Accepts a worker root or a full /status address and returns the /status URL.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        var url = trimmed
        while url.hasSuffix("/") {
            url.removeLast()
        }
        if !url.lowercased().hasSuffix("/status") {
            url += "/status"
        }
        return url
    }
}

/// Settings → Appearance. Stored in UserDefaults (com.chiefstatus.menubar, key "appearance").
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func stored() -> AppearanceChoice {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return AppearanceChoice(rawValue: raw) ?? .system
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: AppearanceChoice.defaultsKey)
    }

    /// The popover and its frosted materials follow the app's appearance.
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

/// When a working bot starts to look stale. The worker's STALE_MINUTES (default 60) is the second step.
enum StaleRule {
    /// No new post for this long turns a working card black with a 404 face and "maybe stale".
    static let fadeAfterMinutes = 30

    /// The fade always comes before "stale?". If STALE_MINUTES is set lower than 30, the fade moves to one minute before it.
    static func fadeMinutes(staleAfterMinutes: Int) -> Int {
        max(1, min(fadeAfterMinutes, staleAfterMinutes - 1))
    }
}
