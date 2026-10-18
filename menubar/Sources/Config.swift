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

    static func write(feedURL: String) {
        ensureDirectory()
        let dict = ["feedURL": feedURL]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func needsSetup(_ url: String?) -> Bool {
        guard let url else { return true }
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
