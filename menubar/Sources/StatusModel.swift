import Foundation
import SwiftUI

struct Bot: Decodable, Identifiable {
    let bot: String
    let status: String
    let task: String
    let startedAt: String

    var id: String { bot }

    enum CodingKeys: String, CodingKey {
        case bot
        case status
        case task
        case startedAt = "started_at"
    }

    init(bot: String, status: String, task: String, startedAt: String) {
        self.bot = bot
        self.status = status
        self.task = task
        self.startedAt = startedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bot = try container.decode(String.self, forKey: .bot)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
    }
}

struct FeedResponse: Decodable {
    let bots: [Bot]
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

    var onChange: (() -> Void)?

    private var poll: Timer?
    private var tick: Timer?
    private var task: URLSessionDataTask?
    private var panelOpen = false
    private var consecutiveNetworkErrors = 0
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
        refresh()
        reschedulePoll()

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        tick.tolerance = 0.2
        RunLoop.main.add(tick, forMode: .common)
        self.tick = tick
    }

    /// The open panel is fetched immediately and then every 5 seconds.
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
        guard http.statusCode == 200, let data else {
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
            bots = decoded.bots
            lastUpdated = Date()
            errorText = nil
        } catch {
            errorText = "That address didn't return a bot list. It should end with /status."
        }
        notify()
    }

    /// Closed panel: 15s, or 60s after repeated connection failures. Open panel: 5s.
    private func desiredPollInterval() -> TimeInterval {
        if panelOpen {
            return 5
        }
        if consecutiveNetworkErrors >= networkBackoffAfter {
            return 60
        }
        return 15
    }

    private func reschedulePoll() {
        let interval = desiredPollInterval()
        if let poll, poll.isValid, abs(poll.timeInterval - interval) < 0.01 {
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

    private func notify() {
        onChange?()
    }
}
