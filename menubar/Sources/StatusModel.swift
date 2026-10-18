import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct Bot: Decodable, Identifiable {
    let bot: String
    let status: String
    let task: String
    let startedAt: String
    let url: String?
    let color: String?
    /// True when this needs_input post is an approval. Older feeds omit it, which means false.
    let approval: Bool
    /// When the worker last accepted a post for this bot. Nil on an older feed, which still uses startedAt.
    let lastPostedAt: String?
    /// From the local links.json. Used only when the feed has no url for this bot.
    var localURL: String?
    /// Set by Clear on this Mac: the maybe-stale warning is hidden until then, unless the bot posts again first.
    var quietUntil: Date?

    func isQuieted(now: Date) -> Bool {
        guard let until = quietUntil else { return false }
        return now < until
    }

    var id: String { bot }

    var openURL: URL? {
        guard let url = url ?? localURL, let parsed = URL(string: url), let scheme = parsed.scheme, !scheme.isEmpty else {
            return nil
        }
        let blocked = ["javascript", "data", "file", "vbscript"]
        if blocked.contains(scheme.lowercased()) { return nil }
        return parsed
    }

    /// Clock for the 404 and stale? marks. last_posted_at wins when the feed sends it.
    /// An older feed leaves it out, and the app uses started_at, as in 1.4.
    func freshnessDate() -> Date? {
        if let posted = lastPostedAt {
            if let date = ISODate.date(from: posted) {
                return date
            }
        }
        return ISODate.date(from: startedAt)
    }

    /// Working or idle, and the last post is at least `afterMinutes` old. No alert goes with this.
    func isQuiet(now: Date, afterMinutes: Int) -> Bool {
        if status != "working" && status != "idle" { return false }
        if afterMinutes <= 0 { return false }
        guard let posted = freshnessDate() else { return false }
        return now.timeIntervalSince(posted) >= Double(afterMinutes) * 60
    }

    /// "no update in 12 min". The number is how long it has been, not the setting.
    func noUpdateLabel(now: Date) -> String {
        guard let posted = freshnessDate() else { return "no update" }
        let minutes = Int(now.timeIntervalSince(posted) / 60)
        let shown = minutes < 1 ? 1 : minutes
        return "no update in \(shown) min"
    }

    func isStale(now: Date, afterMinutes: Int) -> Bool {
        guard status == "working", let start = freshnessDate() else { return false }
        return now.timeIntervalSince(start) >= Double(afterMinutes) * 60
    }

    /// A working bot with no new post for StaleRule.fadeAfterMinutes.
    /// A feed that sends last_posted_at measures that from the last post, not the job start.
    func isFaded(now: Date, staleAfterMinutes: Int) -> Bool {
        if isQuieted(now: now) { return false }
        return isStale(now: now, afterMinutes: StaleRule.fadeMinutes(staleAfterMinutes: staleAfterMinutes))
    }

    /// When this bot last posted. Done and failed use the newest ended_at for it in today's list,
    /// because started_at keeps the working start. Anything else uses last_posted_at when the feed sends it.
    func lastPostDate(today: [FinishedJob]) -> Date? {
        if status == "done" || status == "failed" {
            var newest: Date?
            for job in today where job.bot == bot {
                guard let ended = ISODate.date(from: job.endedAt) else { continue }
                if newest == nil || ended > newest! {
                    newest = ended
                }
            }
            if let newest = newest {
                return newest
            }
        }
        return freshnessDate()
    }

    enum CodingKeys: String, CodingKey {
        case bot
        case status
        case task
        case url
        case color
        case approval
        case startedAt = "started_at"
        case lastPostedAt = "last_posted_at"
    }

    init(bot: String, status: String, task: String, startedAt: String, url: String? = nil, color: String? = nil, approval: Bool = false, lastPostedAt: String? = nil) {
        self.bot = bot
        self.status = status
        self.task = task
        self.startedAt = startedAt
        self.url = url
        self.color = color
        self.approval = approval
        self.lastPostedAt = lastPostedAt
        self.localURL = nil
        self.quietUntil = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bot = try container.decode(String.self, forKey: .bot)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        let rawURL = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        url = rawURL.isEmpty ? nil : rawURL
        let rawColor = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        color = rawColor.isEmpty ? nil : rawColor
        var flag = false
        if container.contains(.approval) {
            if let value = try? container.decode(Bool.self, forKey: .approval) {
                flag = value
            } else if let number = try? container.decode(Int.self, forKey: .approval) {
                flag = number != 0
            }
        }
        approval = flag
        let rawPosted = try container.decodeIfPresent(String.self, forKey: .lastPostedAt) ?? ""
        let trimmedPosted = rawPosted.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPostedAt = trimmedPosted.isEmpty ? nil : trimmedPosted
        localURL = nil
        quietUntil = nil
    }
}

struct FinishedJob: Decodable, Identifiable {
    let bot: String
    let task: String
    let startedAt: String
    let endedAt: String
    let durationMs: Int
    let result: String

    var id: String { "\(bot)|\(startedAt)|\(endedAt)|\(result)" }

    enum CodingKeys: String, CodingKey {
        case bot
        case task
        case result
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
    }
}

struct FeedResponse: Decodable {
    let bots: [Bot]
    let today: [FinishedJob]
    let staleAfterMinutes: Int

    enum CodingKeys: String, CodingKey {
        case bots
        case today
        case staleAfterMinutes = "stale_after_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = try container.decodeIfPresent([Bot].self, forKey: .bots) ?? []
        today = try container.decodeIfPresent([FinishedJob].self, forKey: .today) ?? []
        staleAfterMinutes = try container.decodeIfPresent(Int.self, forKey: .staleAfterMinutes) ?? 60
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private struct LiveMessage: Decodable {
    let type: String?
    let bots: [Bot]?
    let today: [FinishedJob]?
    let staleAfterMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case bots
        case today
        case staleAfterMinutes = "stale_after_minutes"
    }
}

enum PopoverMode {
    case setup
    case checking
    case message
    case list
}

enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        if let date = fractional.date(from: string) {
            return date
        }
        return plain.date(from: string)
    }
}

final class StatusModel: ObservableObject {
    @Published var bots: [Bot] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var now = Date()
    @Published var feedURL = ""
    @Published var draftURL = ""
    @Published var setupError: String?
    @Published var editingAddress = false
    @Published var alertOnFailure = false
    @Published var alertNote: String?
    @Published var today: [FinishedJob] = []
    @Published var todayExpanded = true
    @Published var staleAfterMinutes = 60
    @Published var appearance: AppearanceChoice = .system
    /// Working-cube colour. Default keeps today's orange. Warnings do not use this.
    @Published var iconColor = IconColorSetting.load()
    /// The post password is kept in memory only, so Settings can show and copy the bot prompt.
    /// It is not written to disk and it is never logged.
    @Published var postPassword = ""
    @Published var readToken = ""
    @Published var openAtLogin = false
    @Published var loginNote: String?
    @Published var copyNote: String?
    @Published var testNote: String?
    @Published var sendingTest = false
    /// Check for updates runs only when Settings asks. Nothing here is saved.
    @Published var checkingUpdate = false
    @Published var updateNote = ""
    @Published var updateAvailable = false
    @Published var updatePage: URL?
    /// Spoken line when a bot starts waiting. Off until Settings turns it on. Stored in UserDefaults, not config.plist.
    @Published var needsYouSound = false
    /// Sound-only repeat. Off until the user picks 2, 5, 10 or 15 minutes.
    @Published var needsYouReminderMinutes = 0
    /// Quiet label once the last post is this old. Default 10. Not an alert.
    @Published var quietAfterMinutes = QuietAfter.fallback

    /// What the feed sent. `bots` is this plus local links and local Clear.
    private var feedBots: [Bot] = []
    private var links: [String: String] = [:]
    /// Bot name → the clocks when Clear was clicked, and when. Memory only.
    /// A new post (started_at or last_posted_at) drops the entry; so does another fade window after the click.
    private var cleared: [String: (startedAt: String, postedAt: String, at: Date)] = [:]

    var onChange: (() -> Void)?
    /// Every second. The menu bar uses it so a bot can turn stale without a new post.
    var onTick: (() -> Void)?

    private var poll: Timer?
    private var tick: Timer?
    private var task: URLSessionDataTask?
    private var panelOpen = false
    private var consecutiveNetworkErrors = 0
    private var knownStatus: [String: String] = [:]
    private var hasBaseline = false
    private var reminderTimer: Timer?
    /// Spoken reminders already played in this waiting episode. A new bot that starts waiting resets it.
    private var reminderFired = 0
    /// When each bot last had its failure spoken. Memory only. 10 minutes per bot.
    private var failureSpokenAt: [String: Date] = [:]
    private let failureCooldown: TimeInterval = 10 * 60
    private let userAgent = "ChiefStatus/1.5.0"
    private var liveTask: URLSessionWebSocketTask?
    private var liveConnected = false
    private var reconnect: Timer?
    private var ping: Timer?
    private var liveToken = 0
    private var liveDrops = 0
    /// After this many failed connections in a row, the closed panel waits 60s between tries.
    private let networkBackoffAfter = 3
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    var mode: PopoverMode {
        if editingAddress || ConfigStore.needsSetup(feedURL.isEmpty ? nil : feedURL) {
            return .setup
        }
        if bots.isEmpty && lastUpdated == nil {
            return errorText == nil ? .checking : .message
        }
        return .list
    }

    var canCancelEdit: Bool {
        editingAddress && !ConfigStore.needsSetup(feedURL.isEmpty ? nil : feedURL)
    }

    func start() {
        ConfigStore.ensureDirectory()
        alertOnFailure = ConfigStore.readAlert()
        todayExpanded = ConfigStore.readTodayExpanded()
        appearance = AppearanceChoice.stored()
        iconColor = IconColorSetting.load()
        readToken = ReadTokenStore.read()
        LegacyLaunchAgent.removeIfPresent()
        openAtLogin = LoginItem.isEnabled()
        // Notification permission is not asked here. The failure banner asks only when that switch is turned on.
        needsYouSound = NeedsYouSettings.storedBool(NeedsYouSettings.soundKey, fallback: false)
        needsYouReminderMinutes = NeedsYouSettings.storedReminder()
        quietAfterMinutes = QuietAfter.stored()
        links = ConfigStore.readLinks()
        refresh()
        connectLive()
        reschedulePoll()

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.onTick?()
        }
        tick.tolerance = 0.2
        RunLoop.main.add(tick, forMode: .common)
        self.tick = tick
    }

    /// Opening the panel fetches once. The 5s poll runs only while the live socket is down.
    func setPanelOpen(_ open: Bool) {
        let changed = panelOpen != open
        panelOpen = open
        if open {
            refresh()
        }
        if changed {
            reschedulePoll()
        }
    }

    func beginEditingAddress() {
        if ConfigStore.needsSetup(feedURL.isEmpty ? nil : feedURL) {
            draftURL = ""
        } else {
            draftURL = feedURL
        }
        setupError = nil
        editingAddress = true
        notify()
    }

    func cancelEditing() {
        editingAddress = false
        setupError = nil
        notify()
    }

    func saveAddress() {
        commitReadToken(reconnect: false)
        guard let normalized = ConfigStore.normalize(draftURL) else {
            setupError = "Use a full address, starting with https://"
            notify()
            return
        }
        ConfigStore.write(feedURL: normalized)
        noteFeedAddress(normalized)
        draftURL = normalized
        editingAddress = false
        setupError = nil
        refresh()
        connectLive()
    }

    /// Writes the read token and, when it changed, reads the feed again with the new one.
    func commitReadToken(reconnect: Bool = true) {
        let trimmed = readToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != ReadTokenStore.read()
        readToken = trimmed
        ReadTokenStore.write(trimmed)
        if changed && reconnect {
            refresh()
            connectLive()
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
        } catch {
            openAtLogin = LoginItem.isEnabled()
            loginNote = "macOS didn't allow it. Use System Settings → General → Login Items."
            notify()
            return
        }
        if LoginItem.needsApproval() {
            openAtLogin = on
            loginNote = "Allow Chief Status in System Settings → General → Login Items."
        } else {
            openAtLogin = LoginItem.isEnabled()
            loginNote = nil
        }
        notify()
    }

    /// Fills the feed address, the in-memory post password, and the saved read token from a setup link.
    /// The URL is not logged. An empty token leaves a token already saved on this Mac alone.
    func applySetupURL(_ url: URL) {
        guard let parsed = SetupShare.parse(url) else { return }
        if !parsed.password.isEmpty {
            postPassword = parsed.password
        }
        let token = parsed.readToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            readToken = token
            commitReadToken(reconnect: false)
        }
        editingAddress = true
        if let normalized = ConfigStore.normalize(parsed.feed) {
            ConfigStore.write(feedURL: normalized)
            noteFeedAddress(normalized)
            draftURL = normalized
            setupError = nil
            notify()
            refresh()
            connectLive()
        } else if !parsed.feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setupError = "That setup link's feed address needs to start with https://"
            notify()
        } else {
            notify()
        }
    }

    /// Copies text the user asked to copy. The text is not logged.
    func copyText(_ text: String) {
        if text.isEmpty { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copyNote = "Copied"
        notify()
    }

    func sendTestPost() {
        if sendingTest { return }
        let raw = draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? feedURL : draftURL
        guard let normalized = ConfigStore.normalize(raw) else {
            editingAddress = true
            setupError = "Use a full address, starting with https://"
            notify()
            return
        }
        if postPassword.isEmpty {
            editingAddress = true
            draftURL = normalized
            setupError = "Add the post password, then send the test."
            notify()
            return
        }
        guard let url = URL(string: normalized) else {
            editingAddress = true
            setupError = "Use a full address, starting with https://"
            notify()
            return
        }
        ConfigStore.write(feedURL: normalized)
        noteFeedAddress(normalized)
        draftURL = normalized
        sendingTest = true
        setupError = nil
        copyNote = nil
        testNote = "Sending…"
        notify()

        let name = "ChiefStatusTest-\(Int(Date().timeIntervalSince1970))"
        let working = ["bot": name, "status": "working", "task": "test post"]
        postJSON(url: url, payload: working) { [weak self] status in
            guard let self = self else { return }
            if status == 200 {
                self.setupError = nil
                self.editingAddress = false
                self.testNote = "Removing the test…"
                self.notify()
                self.refresh()
                self.connectLive()
                self.finishTestPost(at: url, name: name)
            } else {
                self.sendingTest = false
                self.testNote = nil
                self.editingAddress = true
                if status == 0 {
                    self.setupError = "Couldn't reach the feed."
                } else if status == 401 {
                    self.setupError = "The post password was refused."
                } else {
                    self.setupError = "The feed didn't accept the test post."
                }
                self.notify()
            }
        }
    }

    /// The working test already landed. Post that bot as idle, then delete only that name.
    private func finishTestPost(at url: URL, name: String) {
        let idle = ["bot": name, "status": "idle", "task": ""]
        postJSON(url: url, payload: idle) { [weak self] _ in
            guard let self = self else { return }
            self.removeTestBot(feed: url, name: name) { removed in
                self.sendingTest = false
                if removed {
                    self.setupError = nil
                    self.editingAddress = false
                    self.testNote = "Test post sent, then removed."
                } else {
                    self.editingAddress = true
                    self.testNote = nil
                    self.setupError = "\(name) is still on the feed. Run ./worker/scripts/delete-bot.sh \(name)"
                }
                self.notify()
                self.refresh()
                self.connectLive()
            }
        }
    }

    func checkForUpdates() {
        if checkingUpdate { return }
        checkingUpdate = true
        updateNote = "Checking…"
        updateAvailable = false
        updatePage = nil
        notify()
        guard let endpoint = URL(string: "https://api.github.com/repos/pohstep/chief-status/releases/latest") else {
            checkingUpdate = false
            updateNote = "Couldn't check for updates. Try again when you're online."
            notify()
            return
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingUpdate = false
                self.applyUpdateCheck(data: data, response: response, error: error)
            }
        }
        task.resume()
    }

    private func applyUpdateCheck(data: Data?, response: URLResponse?, error: Error?) {
        let offline = "Couldn't check for updates. Try again when you're online."
        if error != nil || data == nil {
            updateNote = offline
            updateAvailable = false
            updatePage = nil
            notify()
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = data else {
            updateNote = offline
            updateAvailable = false
            updatePage = nil
            notify()
            return
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            updateNote = offline
            updateAvailable = false
            updatePage = nil
            notify()
            return
        }
        let remote = AppVersion.comparable(release.tagName)
        let local = AppVersion.comparable(AppVersion.current)
        if remote.isEmpty {
            updateNote = offline
            updateAvailable = false
            updatePage = nil
            notify()
            return
        }
        if remote == local {
            updateNote = "You're up to date"
            updateAvailable = false
            updatePage = nil
        } else {
            updateNote = "Version \(remote) is available"
            updateAvailable = true
            updatePage = AppVersion.releasePage(release.htmlURL)
        }
        notify()
    }

    private func postJSON(url: URL, payload: [String: String], done: @escaping (Int) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            done(0)
            return
        }
        send(authedRequest(url: url, method: "POST", body: body), done: done)
    }

    private func removeTestBot(feed: URL, name: String, done: @escaping (Bool) -> Void) {
        guard var components = URLComponents(url: feed, resolvingAgainstBaseURL: false) else {
            done(false)
            return
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        path += "/\(encoded)"
        components.path = path
        guard let target = components.url else {
            done(false)
            return
        }
        send(authedRequest(url: target, method: "DELETE", body: nil)) { status in
            done(status == 200 || status == 404)
        }
    }

    private func authedRequest(url: URL, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(postPassword)", forHTTPHeaderField: "Authorization")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Calls back on the main queue with the HTTP status, or 0 when the feed could not be reached.
    private func send(_ request: URLRequest, done: @escaping (Int) -> Void) {
        let task = session.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if error != nil || response == nil {
                    done(0)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                done(status)
            }
        }
        task.resume()
    }

    func setAlertOnFailure(_ on: Bool) {
        if !on {
            alertOnFailure = false
            alertNote = nil
            ConfigStore.setAlert(false)
            notify()
            return
        }
        AlertCenter.request { granted in
            DispatchQueue.main.async {
                self.alertOnFailure = true
                ConfigStore.setAlert(true)
                self.alertNote = granted ? nil : "Banners are off in System Settings. Chief Status will still speak the alert."
                self.notify()
            }
        }
    }

    func setAppearance(_ choice: AppearanceChoice) {
        appearance = choice
        choice.store()
        choice.apply()
        notify()
    }

    func setNeedsYouSound(_ on: Bool) {
        needsYouSound = on
        UserDefaults.standard.set(on, forKey: NeedsYouSettings.soundKey)
        if !on {
            reminderTimer?.invalidate()
            reminderTimer = nil
        } else {
            armNeedsYouReminder(waiting: bots.contains { $0.status == "needs_input" }, restartTimer: false)
        }
        notify()
    }

    func setNeedsYouReminder(_ minutes: Int) {
        let next = NeedsYouSettings.reminderChoices.contains(minutes) ? minutes : 0
        needsYouReminderMinutes = next
        UserDefaults.standard.set(next, forKey: NeedsYouSettings.reminderKey)
        reminderTimer?.invalidate()
        reminderTimer = nil
        armNeedsYouReminder(waiting: bots.contains { $0.status == "needs_input" }, restartTimer: true)
        notify()
    }

    func setQuietAfter(_ minutes: Int) {
        let next = QuietAfter.choices.contains(minutes) ? minutes : QuietAfter.fallback
        quietAfterMinutes = next
        UserDefaults.standard.set(next, forKey: QuietAfter.key)
        notify()
    }

    /// Opens the bot's chat. The feed link wins. links.json is the fallback. Returns false when there is no link.
    func openChat(named name: String) -> Bool {
        if let bot = bots.first(where: { $0.bot == name }) {
            if let url = bot.openURL {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        let links = ConfigStore.readLinks()
        if let raw = links[name] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = URL(string: trimmed), let scheme = parsed.scheme, !scheme.isEmpty {
                let blocked = ["javascript", "data", "file", "vbscript"]
                if !blocked.contains(scheme.lowercased()) {
                    NSWorkspace.shared.open(parsed)
                    return true
                }
            }
        }
        return false
    }

    func setIconColor(_ next: IconColorSetting) {
        let normalized = IconColorSetting(stored: IconColorSetting.normalize(next.stored))
        if normalized == iconColor { return }
        iconColor = normalized
        normalized.save()
        notify()
    }

    /// "Clear" on a maybe-stale card. Local only, nothing is posted: the bot stays working and the
    /// 404 warning is hidden for another fade window, or until the bot posts again and later goes quiet.
    func clearLocally(_ bot: Bot) {
        cleared[bot.bot] = (startedAt: bot.startedAt, postedAt: bot.lastPostedAt ?? "", at: Date())
        rebuildBots()
        notify()
    }

    /// For --render-preview only.
    func setSampleBots(_ sample: [Bot]) {
        feedBots = sample
        rebuildBots()
    }

    private func rebuildBots() {
        let window = Double(StaleRule.fadeMinutes(staleAfterMinutes: staleAfterMinutes)) * 60
        cleared = cleared.filter { name, entry in
            Date().timeIntervalSince(entry.at) < window
                && feedBots.contains { bot in
                    bot.bot == name
                        && bot.startedAt == entry.startedAt
                        && (bot.lastPostedAt ?? "") == entry.postedAt
                        && bot.status == "working"
                }
        }
        bots = feedBots.map { source in
            var bot = source
            if let entry = cleared[source.bot] {
                bot.quietUntil = entry.at.addingTimeInterval(window)
            }
            bot.localURL = links[source.bot]
            return bot
        }
    }

    func toggleToday() {
        todayExpanded.toggle()
        ConfigStore.setTodayExpanded(todayExpanded)
        notify()
    }

    func refresh() {
        ConfigStore.ensureDirectory()
        let raw = ConfigStore.readFeedURL() ?? ""
        noteFeedAddress(raw)
        links = ConfigStore.readLinks()

        guard !ConfigStore.needsSetup(raw) else {
            task?.cancel()
            bots = []
            errorText = nil
            lastUpdated = nil
            notify()
            return
        }

        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorText = "The feed address doesn't look like a web address."
            notify()
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        applyReadToken(&request)
        task?.cancel()
        let requested = raw
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.feedURL == requested else { return }
                self.apply(data: data, response: response, error: error)
            }
        }
        self.task = task
        task.resume()
    }

    private func apply(data: Data?, response: URLResponse?, error: Error?) {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }
        if error != nil || response == nil {
            noteNetworkFailure()
            errorText = "Couldn't reach the feed. Check the address, and that this Mac is online."
            notify()
            return
        }
        noteNetworkSuccess()
        guard let http = response as? HTTPURLResponse else {
            errorText = "Couldn't reach the feed."
            notify()
            return
        }
        if http.statusCode == 401 {
            errorText = "This feed is locked. Add its read token in Settings."
            notify()
            return
        }
        guard http.statusCode == 200, let data = data else {
            if http.statusCode == 404 {
                errorText = "The feed was not found. The address should end with /status."
            } else {
                errorText = "The feed replied with an error."
            }
            notify()
            return
        }
        do {
            let decoded = try JSONDecoder().decode(FeedResponse.self, from: data)
            applyFeed(decoded)
        } catch {
            errorText = "That address didn't return a bot list. It should end with /status."
        }
        notify()
    }

    private func applyFeed(_ decoded: FeedResponse) {
        noteTransitions(decoded.bots)
        feedBots = decoded.bots
        rebuildBots()
        today = decoded.today
        if decoded.staleAfterMinutes > 0 {
            staleAfterMinutes = decoded.staleAfterMinutes
        }
        lastUpdated = Date()
        errorText = nil
    }

    /// A different feed must not speak for bots that were already waiting on the previous one.
    private func noteFeedAddress(_ raw: String) {
        if raw != feedURL {
            knownStatus = [:]
            hasBaseline = false
            failureSpokenAt = [:]
            reminderFired = 0
            reminderTimer?.invalidate()
            reminderTimer = nil
            cleared = [:]
        }
        feedURL = raw
    }

    private func noteTransitions(_ bots: [Bot]) {
        var entered: [Bot] = []
        if hasBaseline {
            if alertOnFailure {
                let fresh = bots.filter { bot in
                    bot.status == "failed" && knownStatus[bot.bot] != "failed"
                }
                if !fresh.isEmpty {
                    announceFailures(fresh)
                }
            }
            for bot in bots where bot.status == "needs_input" {
                if knownStatus[bot.bot] != "needs_input" {
                    entered.append(bot)
                }
            }
            if needsYouSound && !entered.isEmpty {
                FailureSpeaker.shared.speak(entered.map { needsYouPhrase($0) })
            }
        }
        knownStatus = Dictionary(uniqueKeysWithValues: bots.map { ($0.bot, $0.status) })
        hasBaseline = true
        let waiting = bots.contains { $0.status == "needs_input" }
        if !waiting {
            reminderFired = 0
            armNeedsYouReminder(waiting: false, restartTimer: true)
        } else if !entered.isEmpty {
            reminderFired = 0
            armNeedsYouReminder(waiting: true, restartTimer: true)
        } else {
            armNeedsYouReminder(waiting: true, restartTimer: false)
        }
    }

    /// Banner for every new failure. The spoken line waits 10 minutes per bot.
    private func announceFailures(_ bots: [Bot]) {
        let now = Date()
        var speakable: [Bot] = []
        for bot in bots {
            var allowed = true
            if let last = failureSpokenAt[bot.bot] {
                if now.timeIntervalSince(last) < failureCooldown {
                    allowed = false
                }
            }
            if allowed {
                failureSpokenAt[bot.bot] = now
                speakable.append(bot)
            }
        }
        AlertCenter.announceFailures(bots, speak: speakable)
    }

    /// Sound only. Off, the sound toggle off, nobody waiting, or 3 reminders already spoken, stops the timer.
    /// restartTimer drops a running timer so a new waiter does not get a reminder seconds after the first line.
    private func armNeedsYouReminder(waiting: Bool, restartTimer: Bool) {
        if !waiting || !needsYouSound || needsYouReminderMinutes <= 0 || reminderFired >= NeedsYouSettings.reminderCap {
            reminderTimer?.invalidate()
            reminderTimer = nil
            return
        }
        if !restartTimer {
            if let timer = reminderTimer, timer.isValid {
                let wanted = TimeInterval(needsYouReminderMinutes * 60)
                if abs(timer.timeInterval - wanted) < 0.5 {
                    return
                }
            }
        }
        reminderTimer?.invalidate()
        let interval = TimeInterval(needsYouReminderMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.fireNeedsYouReminder()
        }
        timer.tolerance = min(30, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private func fireNeedsYouReminder() {
        if !needsYouSound || reminderFired >= NeedsYouSettings.reminderCap {
            armNeedsYouReminder(waiting: false, restartTimer: true)
            return
        }
        let waiting = bots
            .filter { $0.status == "needs_input" }
            .sorted { $0.bot.localizedCaseInsensitiveCompare($1.bot) == .orderedAscending }
        if waiting.isEmpty {
            reminderFired = 0
            armNeedsYouReminder(waiting: false, restartTimer: true)
            return
        }
        let line: String
        if waiting.count == 1 {
            line = needsYouPhrase(waiting[0])
        } else {
            line = waiting.map { needsYouPhrase($0) }.joined(separator: ". ")
        }
        FailureSpeaker.shared.speak([line])
        reminderFired += 1
        if reminderFired >= NeedsYouSettings.reminderCap {
            reminderTimer?.invalidate()
            reminderTimer = nil
        }
    }

    private func needsYouPhrase(_ bot: Bot) -> String {
        if bot.approval {
            return "\(bot.bot) needs your approval"
        }
        return "\(bot.bot) needs you"
    }

    /// While the live socket is up, it carries updates. The 15s poll is only the fallback.
    private func desiredPollInterval() -> TimeInterval? {
        if liveConnected { return nil }
        if panelOpen { return 5 }
        if consecutiveNetworkErrors >= networkBackoffAfter { return 60 }
        return 15
    }

    private func reschedulePoll() {
        guard let interval = desiredPollInterval() else {
            poll?.invalidate()
            poll = nil
            return
        }
        if let poll = poll, poll.isValid, abs(poll.timeInterval - interval) < 0.01 {
            return
        }
        poll?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = interval >= 60 ? 5 : 0.4
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func noteNetworkFailure() {
        consecutiveNetworkErrors += 1
        reschedulePoll()
    }

    private func noteNetworkSuccess() {
        let previous = consecutiveNetworkErrors
        consecutiveNetworkErrors = 0
        if previous > 0 {
            reschedulePoll()
        }
    }

    private func connectLive() {
        liveToken += 1
        let token = liveToken
        reconnect?.invalidate()
        reconnect = nil
        ping?.invalidate()
        ping = nil
        liveTask?.cancel(with: .goingAway, reason: nil)
        liveTask = nil
        liveConnected = false

        guard !ConfigStore.needsSetup(feedURL.isEmpty ? nil : feedURL),
              let url = ConfigStore.liveWebSocketURL(from: feedURL) else {
            reschedulePoll()
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        applyReadToken(&request)
        let socket = session.webSocketTask(with: request)
        liveTask = socket
        socket.resume()
        receiveLive(socket, token: token)
        let ping = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendLivePing()
        }
        RunLoop.main.add(ping, forMode: .common)
        self.ping = ping
        reschedulePoll()
    }

    private func sendLivePing() {
        liveTask?.send(.string("ping")) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.noteLiveDropped()
                } else if self?.liveConnected == false {
                    self?.liveConnected = true
                    self?.reschedulePoll()
                }
            }
        }
    }

    private func receiveLive(_ socket: URLSessionWebSocketTask, token: Int) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.liveToken == token, self.liveTask === socket else { return }
                switch result {
                case .success(let message):
                    self.liveConnected = true
                    self.liveDrops = 0
                    self.reschedulePoll()
                    self.consumeLive(message)
                    self.receiveLive(socket, token: token)
                case .failure:
                    self.noteLiveDropped()
                }
            }
        }
    }

    private func consumeLive(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return
        }
        if text == "pong" || text == "ping" || text.isEmpty { return }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LiveMessage.self, from: data),
              let bots = decoded.bots else {
            return
        }
        applyFeed(FeedResponse(bots: bots, today: decoded.today ?? [], staleAfterMinutes: decoded.staleAfterMinutes ?? staleAfterMinutes))
        notify()
    }

    private func noteLiveDropped() {
        guard liveTask != nil || liveConnected else { return }
        liveConnected = false
        liveTask?.cancel(with: .goingAway, reason: nil)
        liveTask = nil
        ping?.invalidate()
        ping = nil
        reschedulePoll()
        refresh()
        reconnect?.invalidate()
        liveDrops += 1
        let delay: TimeInterval = liveDrops <= 1 ? 2 : 15
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.connectLive()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnect = timer
    }

    /// Sends the saved read token when one is set. The token is not logged.
    private func applyReadToken(_ request: inout URLRequest) {
        let token = ReadTokenStore.read()
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func notify() {
        onChange?()
    }
}

private enum AlertCenter {
    static func request(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            done(granted)
        }
    }

    static func announceFailures(_ bots: [Bot], speak: [Bot]) {
        if !speak.isEmpty {
            FailureSpeaker.shared.speak(speak.map { "\($0.bot) task failed" })
        }
        let content = UNMutableNotificationContent()
        content.title = "An agent failed"
        if bots.count == 1 {
            let task = bots[0].task.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = task.isEmpty ? "\(bots[0].bot) failed" : "\(bots[0].bot) failed: \(task)"
        } else {
            content.body = "\(bots.map(\.bot).joined(separator: ", ")) failed"
        }
        content.sound = nil
        deliver(content, identifier: UUID().uuidString)
    }

    private static func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Speaks a line with the system voice (the same one `say` uses).
/// Failures and needs-you alerts share this queue, so they never talk over each other.
final class FailureSpeaker: NSObject, NSSpeechSynthesizerDelegate {
    static let shared = FailureSpeaker()

    private let synth = NSSpeechSynthesizer()
    private var queue: [String] = []
    private var speaking = false

    private override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ phrases: [String]) {
        for phrase in phrases where !queue.contains(phrase) {
            queue.append(phrase)
        }
        next()
    }

    private func next() {
        guard !speaking, !queue.isEmpty else { return }
        let phrase = queue.removeFirst()
        speaking = synth.startSpeaking(phrase)
        NSLog("ChiefStatus spoken alert start: \"%@\" (started: %@)", phrase, speaking ? "yes" : "no")
        if !speaking { next() }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        NSLog("ChiefStatus spoken alert finished (completed: %@)", finishedSpeaking ? "yes" : "no")
        speaking = false
        next()
    }
}

private extension FeedResponse {
    init(bots: [Bot], today: [FinishedJob], staleAfterMinutes: Int) {
        self.bots = bots
        self.today = today
        self.staleAfterMinutes = staleAfterMinutes
    }
}
