import AppKit
import Darwin
import Foundation
import ServiceManagement

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

/// The read token lives in this app's private preferences, not the Keychain.
/// An unsigned app would ask for Keychain access again after every update.
enum ReadTokenStore {
    static let defaultsKey = "readToken"

    static func read() -> String {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }
}

/// Open at login, the same switch Wordbit uses. macOS 13 ServiceManagement.
enum LoginItem {
    static func isEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    static func needsApproval() -> Bool {
        return SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ on: Bool) throws {
        LegacyLaunchAgent.removeIfPresent()
        let status = SMAppService.mainApp.status
        if on {
            if status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// install.sh used to write this LaunchAgent, which started the app even when the Settings switch was off.
/// The switch is the only login control now. This removes the old agent. It does not create a new one.
enum LegacyLaunchAgent {
    static let label = "com.chiefstatus.menubar"

    static func removeIfPresent() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if !FileManager.default.fileExists(atPath: plist.path) {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // disable, not bootout: bootout would quit the app if this agent is what launched it.
        process.arguments = ["disable", "gui/\(Darwin.getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)
    }
}

/// Version shown in Settings. The running app reads CFBundleShortVersionString.
/// A bare `ChiefStatus --render-preview` binary has no bundle, so that path uses 1.5.0.
enum AppVersion {
    static var current: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "1.5.0"
    }

    /// `v1.5.0` and `1.5.0` are the same version.
    static func comparable(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        return text
    }

    static func releasesPage() -> URL? {
        return URL(string: "https://github.com/pohstep/chief-status/releases/latest")
    }

    /// The release page from GitHub, or the public latest-release page.
    static func releasePage(_ raw: String?) -> URL? {
        if let raw = raw {
            if let url = URL(string: raw) {
                if let scheme = url.scheme?.lowercased() {
                    if scheme == "https" || scheme == "http" {
                        return url
                    }
                }
            }
        }
        return releasesPage()
    }
}

/// Feed address, post password, and optional read token carried by chiefstatus://setup and the bot prompt.
/// These strings are shown in Settings and copied to the clipboard. Do not log them.
enum SetupShare {
    static let guide = "https://github.com/pohstep/chief-status#set-up-the-feed"
    static let deployPage = "https://deploy.workers.cloudflare.com/?url=https://github.com/pohstep/chief-status/tree/main/worker"

    struct Link {
        var feed: String
        var password: String
        /// Empty when the link has no read token. Opening the link then leaves a saved token alone.
        var readToken: String
    }

    static func parse(_ url: URL) -> Link? {
        guard let scheme = url.scheme, scheme.lowercased() == "chiefstatus" else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host != "setup" { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var feed = ""
        var password = ""
        var readToken = ""
        let items = components.queryItems ?? []
        for item in items {
            let value = item.value ?? ""
            if item.name == "feed" {
                feed = value
            } else if item.name == "password" {
                password = value
            } else if item.name == "token" {
                readToken = value
            }
        }
        return Link(feed: feed, password: password, readToken: readToken)
    }

    static func link(feed: String, password: String, readToken: String = "") -> String? {
        guard let normalized = ConfigStore.normalize(feed), !password.isEmpty else { return nil }
        var items = [
            URLQueryItem(name: "feed", value: normalized),
            URLQueryItem(name: "password", value: password),
        ]
        let token = readToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        var components = URLComponents()
        components.scheme = "chiefstatus"
        components.host = "setup"
        components.queryItems = items
        return components.string
    }

    /// One paste for a bot. The address and the post password are filled in.
    /// Returns nil until both are present. Never log the result.
    static func botPrompt(feed: String, password: String) -> String? {
        guard let normalized = ConfigStore.normalize(feed), !password.isEmpty else { return nil }
        let address = shellEscape(normalized)
        let secret = shellEscape(password)
        let working = curl(address, secret, "working", "one short line about the job", ",\"color\":\"#3B82F6\"")
        let done = curl(address, secret, "done", "what finished", "")
        let failed = curl(address, secret, "failed", "what broke", "")
        let needs = curl(address, secret, "needs_input", "the question you need answered", "")
        let approval = curl(address, secret, "needs_input", "exactly what to approve", ",\"approval\":true")
        let idle = curl(address, secret, "idle", "", "")
        return """
Your name is Agent1.
Your colour is #3B82F6.

You cannot see your own colour. It is written here so you can pass it on. The panel fills your face with it. Change Agent1 and the colour to this bot's own.

When you start a real job that will take more than a minute or two, post to Chief Status with curl. Skip quick chat replies and lookups.

Start of job:
\(working)

Job finished:
\(done)

Job failed:
\(failed)

Waiting on me. The task line must say exactly what you need:
\(needs)

Waiting on my approval. The task line must say exactly what to approve:
\(approval)

Then always:
\(idle)

If you hand work to a background helper, post working while it runs, and done when it comes back.
Never put passwords or secrets in the task line.
"""
    }

    private static func curl(_ address: String, _ secret: String, _ status: String, _ task: String, _ extra: String) -> String {
        return "curl -sS -X POST \"\(address)\" -H \"Authorization: Bearer \(secret)\" -H \"Content-Type: application/json\" -d '{\"bot\":\"Agent1\",\"status\":\"\(status)\",\"task\":\"\(task)\"\(extra)}'"
    }

    /// Escape a value that will sit inside double quotes in a shell command.
    private static func shellEscape(_ value: String) -> String {
        var out = ""
        for character in value {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }
}

/// Menu bar icon colour. UserDefaults domain com.chiefstatus.menubar, key "iconColor".
/// "default" keeps today's orange working cube. A "#RRGGBB" value is a preset or a custom colour.
/// Missing and unreadable values are default, so existing users keep the current icon.
struct IconColorSetting: Equatable {
    var stored: String

    static let defaultsKey = "iconColor"
    static let defaultToken = "default"

    var isDefault: Bool { stored == IconColorSetting.defaultToken }

    var title: String {
        if isDefault { return "Default" }
        let match = IconSwatch.all.first { $0.hex == stored }
        if let match = match { return match.name }
        return "Custom"
    }

    /// Colour shown in the picker. Default shows today's orange, without saving it.
    var nsColor: NSColor {
        if isDefault { return ChiefPalette.orange }
        return IconColorSetting.color(hex: stored) ?? ChiefPalette.orange
    }

    /// Hex the picker already represents, so a no-op write does not leave Default.
    var pickerHex: String {
        return IconColorSetting.hex(from: nsColor)
    }

    static func load() -> IconColorSetting {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return IconColorSetting(stored: normalize(raw))
    }

    func save() {
        UserDefaults.standard.set(stored, forKey: IconColorSetting.defaultsKey)
    }

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == defaultToken {
            return defaultToken
        }
        if let hex = canonicalHex(trimmed) {
            return hex
        }
        return defaultToken
    }

    static func canonicalHex(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        if text.count != 6 { return nil }
        let digits = CharacterSet(charactersIn: "0123456789ABCDEF")
        if text.rangeOfCharacter(from: digits.inverted) != nil {
            return nil
        }
        return "#" + text
    }

    static func color(hex: String) -> NSColor? {
        guard let canonical = canonicalHex(hex) else { return nil }
        let text = String(canonical.dropFirst())
        guard let value = UInt32(text, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return "#F39C28"
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// True when two hex colours are the same, allowing for picker rounding.
    static func nearly(_ lhs: String, _ rhs: String, tolerance: CGFloat = 0.04) -> Bool {
        if lhs == rhs { return true }
        guard let left = color(hex: lhs), let right = color(hex: rhs) else { return false }
        let red = abs(left.redComponent - right.redComponent)
        let green = abs(left.greenComponent - right.greenComponent)
        let blue = abs(left.blueComponent - right.blueComponent)
        return red < tolerance && green < tolerance && blue < tolerance
    }

    private static func byte(_ channel: CGFloat) -> Int {
        let scaled = Int((channel * 255).rounded())
        if scaled < 0 { return 0 }
        if scaled > 255 { return 255 }
        return scaled
    }
}

/// The eleven icon presets, in Settings order. Default and Custom are separate.
struct IconSwatch: Equatable, Identifiable {
    var name: String
    var hex: String

    var id: String { hex }

    var nsColor: NSColor {
        return IconColorSetting.color(hex: hex) ?? ChiefPalette.orange
    }

    static let all: [IconSwatch] = [
        IconSwatch(name: "White", hex: "#FFFFFF"),
        IconSwatch(name: "Brown", hex: "#9A6D42"),
        IconSwatch(name: "Red", hex: "#E94347"),
        IconSwatch(name: "Deep orange", hex: "#E8663A"),
        IconSwatch(name: "Orange", hex: "#E9983A"),
        IconSwatch(name: "Green", hex: "#5ABF78"),
        IconSwatch(name: "Teal", hex: "#3BB5B0"),
        IconSwatch(name: "Blue", hex: "#3A86F4"),
        IconSwatch(name: "Purple", hex: "#8762F3"),
        IconSwatch(name: "Pink", hex: "#E85FA8"),
        IconSwatch(name: "Grey", hex: "#8E8E93"),
    ]
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

/// Needs-you sound. UserDefaults domain com.chiefstatus.menubar.
/// A missing sound key means off. A missing reminder means off.
enum NeedsYouSettings {
    static let soundKey = "needsYouSound"
    static let reminderKey = "needsYouReminderMinutes"
    static let reminderChoices = [0, 2, 5, 10, 15]
    /// Spoken reminders in one waiting episode, then silence until a new bot starts waiting.
    static let reminderCap = 3

    static func storedBool(_ key: String, fallback: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func storedReminder() -> Int {
        if UserDefaults.standard.object(forKey: reminderKey) == nil {
            return 0
        }
        let value = UserDefaults.standard.integer(forKey: reminderKey)
        if reminderChoices.contains(value) {
            return value
        }
        return 0
    }

    static func title(for minutes: Int) -> String {
        if minutes <= 0 { return "Off" }
        return "\(minutes) min"
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
