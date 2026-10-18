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

    var id: String { bot }

    var openURL: URL? {
        guard let url = url, let parsed = URL(string: url), let scheme = parsed.scheme, !scheme.isEmpty else {
            return nil
        }
        let blocked = ["javascript", "data", "file", "vbscript"]
        if blocked.contains(scheme.lowercased()) { return nil }
        return parsed
    }

    func isStale(now: Date, afterMinutes: Int) -> Bool {
        guard status == "working", let start = ISODate.date(from: startedAt) else { return false }
        return now.timeIntervalSince(start) >= Double(afterMinutes) * 60
    }

    enum CodingKeys: String, CodingKey {
        case bot
        case status
        case task
        case url
        case color
        case startedAt = "started_at"
    }

    init(bot: String, status: String, task: String, startedAt: String, url: String? = nil, color: String? = nil) {
        self.bot = bot
        self.status = status
        self.task = task
        self.startedAt = startedAt
        self.url = url
        self.color = color
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

    var onChange: (() -> Void)?

    private var poll: Timer?
    private var tick: Timer?
    private var task: URLSessionDataTask?
    private var panelOpen = false
    private var consecutiveNetworkErrors = 0
    private var knownStatus: [String: String] = [:]
    private var hasBaseline = false
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
        refresh()
        connectLive()
        reschedulePoll()

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
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
        guard let normalized = ConfigStore.normalize(draftURL) else {
            setupError = "Use a full address, starting with https://"
            notify()
            return
        }
        ConfigStore.write(feedURL: normalized)
        draftURL = normalized
        editingAddress = false
        setupError = nil
        refresh()
        connectLive()
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
                self.alertNote = granted ? nil : "Banners are off in System Settings. Chief Status will still play a sound."
                self.notify()
            }
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
        feedURL = raw

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
        request.setValue("ChiefStatus/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        task?.cancel()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.apply(data: data, response: response, error: error)
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
        bots = decoded.bots
        today = decoded.today
        if decoded.staleAfterMinutes > 0 {
            staleAfterMinutes = decoded.staleAfterMinutes
        }
        lastUpdated = Date()
        errorText = nil
    }

    private func noteTransitions(_ bots: [Bot]) {
        if hasBaseline, alertOnFailure {
            let fresh = bots.filter { bot in
                bot.status == "failed" && knownStatus[bot.bot] != "failed"
            }
            if !fresh.isEmpty {
                AlertCenter.announce(fresh)
            }
        }
        knownStatus = Dictionary(uniqueKeysWithValues: bots.map { ($0.bot, $0.status) })
        hasBaseline = true
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
        request.setValue("ChiefStatus/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
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

    private func notify() {
        onChange?()
    }
}

private enum AlertCenter {
    static func request(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            done(granted)
        }
    }

    static func announce(_ bots: [Bot]) {
        NSSound(named: NSSound.Name("Funk"))?.play()
        let content = UNMutableNotificationContent()
        content.title = "An agent failed"
        if bots.count == 1 {
            let task = bots[0].task.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = task.isEmpty ? "\(bots[0].bot) failed" : "\(bots[0].bot) failed: \(task)"
        } else {
            content.body = "\(bots.map(\.bot).joined(separator: ", ")) failed"
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

private extension FeedResponse {
    init(bots: [Bot], today: [FinishedJob], staleAfterMinutes: Int) {
        self.bots = bots
        self.today = today
        self.staleAfterMinutes = staleAfterMinutes
    }
}
