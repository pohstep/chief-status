import AppKit
import SwiftUI

enum Metrics {
    static let width: CGFloat = 328
    static let maxPanelHeight: CGFloat = 520
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 12
    static let headerHeight: CGFloat = 36
    static let footerGap: CGFloat = 8
    static let footerHeight: CGFloat = 36
    /// 520 − 12 − 36 − 44 − 12. The header and footer stay pinned above this.
    static let scrollMax: CGFloat = 416

    static func height(for model: StatusModel) -> CGFloat {
        let scroll = min(scrollMax, scrollContentHeight(for: model))
        let chrome = topInset + headerHeight + footerGap + footerHeight + bottomInset
        return min(maxPanelHeight, chrome + scroll)
    }

    static func scrollContentHeight(for model: StatusModel) -> CGFloat {
        switch model.mode {
        case .setup:
            return 236
        case .checking:
            return 48
        case .message:
            return 72
        case .list:
            return listHeight(for: model)
        }
    }

    /// Working cards, the team card, and Finished today. Matches the 518 pt example.
    static func listHeight(for model: StatusModel) -> CGFloat {
        let working = model.bots.filter { $0.status == "working" }
        let team = model.bots.filter { $0.status != "working" }
        var height: CGFloat = 0
        if !working.isEmpty {
            height += 24
            height += CGFloat(working.count) * 46
            if working.count > 1 {
                height += CGFloat(working.count - 1) * 6
            }
        }
        if !team.isEmpty {
            height += 8
            height += CGFloat(team.count) * 32
        }
        if model.bots.isEmpty && model.today.isEmpty {
            height += 32
        }
        height += 30
        if model.todayExpanded {
            let rows = model.today.isEmpty ? 1 : model.today.count
            height += CGFloat(rows) * 24
            height += 6
        }
        if model.errorText != nil {
            height += 32
        }
        return height
    }
}

struct StatusPopoverView: View {
    @ObservedObject var model: StatusModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: Metrics.headerHeight)

            scroll
                .frame(height: min(Metrics.scrollMax, Metrics.scrollContentHeight(for: model)))

            Color.clear.frame(height: Metrics.footerGap)
            footer
                .frame(height: Metrics.footerHeight)
        }
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Metrics.bottomInset)
        .frame(width: Metrics.width, height: Metrics.height(for: model), alignment: .top)
        .background(popoverBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Chief Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PanelTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
            summary
                .frame(height: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var summary: some View {
        let working = model.bots.filter { $0.status == "working" }.count
        let failed = model.bots.filter { $0.status == "failed" }.count
        let doneToday = model.today.filter { $0.result == "done" }.count
        return Group {
            if working == 0 && failed == 0 && doneToday == 0 {
                Text("All idle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PanelTheme.ink2)
            } else {
                HStack(spacing: 6) {
                    if working > 0 {
                        summaryPart(count: working, word: "working", color: PanelTheme.orange)
                    }
                    if working > 0 && (failed > 0 || doneToday > 0) {
                        summaryDot
                    }
                    if failed > 0 {
                        summaryPart(count: failed, word: "failed", color: PanelTheme.red)
                    }
                    if failed > 0 && doneToday > 0 {
                        summaryDot
                    }
                    if doneToday > 0 {
                        summaryPart(count: doneToday, word: "done today", color: PanelTheme.done)
                    }
                }
            }
        }
    }

    private var summaryDot: some View {
        Text("·")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PanelTheme.ink2)
    }

    private func summaryPart(count: Int, word: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(word)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PanelTheme.ink2)
        }
    }

    private var scroll: some View {
        let contentHeight = Metrics.scrollContentHeight(for: model)
        let scrolling = contentHeight > Metrics.scrollMax
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                switch model.mode {
                case .setup:
                    setup
                case .checking:
                    checking
                case .message:
                    message
                case .list:
                    list
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .mask(scrolling ? AnyView(scrollFade) : AnyView(Rectangle().fill(Color.black)))
    }

    private var scrollFade: some View {
        let fade = 12 / Metrics.scrollMax
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var workingBots: [Bot] {
        model.bots
            .filter { $0.status == "working" }
            .sorted { lhs, rhs in
                let left = ISODate.date(from: lhs.startedAt) ?? .distantFuture
                let right = ISODate.date(from: rhs.startedAt) ?? .distantFuture
                if left != right { return left < right }
                return lhs.bot.localizedCaseInsensitiveCompare(rhs.bot) == .orderedAscending
            }
    }

    private var teamBots: [Bot] {
        let rank = ["failed": 0, "done": 1, "idle": 2]
        return model.bots
            .filter { $0.status != "working" }
            .sorted { lhs, rhs in
                let left = rank[lhs.status] ?? 3
                let right = rank[rhs.status] ?? 3
                if left != right { return left < right }
                return lhs.bot.localizedCaseInsensitiveCompare(rhs.bot) == .orderedAscending
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.bots.isEmpty && model.today.isEmpty {
                Text("No bots yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelTheme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
            }
            if !workingBots.isEmpty {
                Text("WORKING NOW")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(PanelTheme.ink2)
                    .frame(height: 14, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .padding(.leading, 4)
                VStack(spacing: 6) {
                    ForEach(workingBots) { bot in
                        WorkingCard(bot: bot, now: model.now, staleAfterMinutes: model.staleAfterMinutes, reduceMotion: reduceMotion)
                            .frame(height: 46)
                    }
                }
            }
            if !teamBots.isEmpty {
                Color.clear.frame(height: 8)
                TeamCard(bots: teamBots, now: model.now)
            }
            FinishedCard(
                jobs: model.today,
                expanded: model.todayExpanded,
                bots: model.bots,
                onToggle: { model.toggleToday() }
            )
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32, alignment: .top)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.canCancelEdit ? "Paste a new feed address." : "Paste your feed address to begin.")
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            TextField(
                "Feed address",
                text: $model.draftURL,
                prompt: Text("https://your-worker.workers.dev/status")
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit { model.saveAddress() }
            Text(model.setupError ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(model.setupError == nil ? Color.clear : PanelTheme.redText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28, alignment: .top)
            HStack(spacing: 8) {
                Button("Save") { model.saveAddress() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if model.canCancelEdit {
                    Button("Cancel") { model.cancelEditing() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Toggle("Alert when a bot fails", isOn: Binding(
                get: { model.alertOnFailure },
                set: { model.setAlertOnFailure($0) }
            ))
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(model.alertNote ?? "Off unless you turn it on. A new failure plays a sound and shows a banner.")
                .font(.system(size: 11))
                .foregroundStyle(PanelTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking the feed…")
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink2)
        }
        .frame(height: 36, alignment: .leading)
    }

    private var message: some View {
        Text(model.errorText ?? "Couldn't reach the feed.")
            .font(.system(size: 12))
            .foregroundStyle(PanelTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(PanelTheme.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                Text(updatedLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.mode != .setup {
                    FooterButton(title: "Settings", systemImage: "gearshape", hoverFill: PanelTheme.hoverFill, ink: PanelTheme.ink, ink2: PanelTheme.ink2) {
                        model.beginEditingAddress()
                    }
                }
                FooterButton(title: "Quit", shortcut: "⌘Q", key: "q", hoverFill: PanelTheme.hoverFill, ink: PanelTheme.ink, ink2: PanelTheme.ink2) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
        }
    }

    private var updatedLabel: String {
        guard let date = model.lastUpdated else { return "Not updated yet" }
        if Calendar.current.isDateInToday(date) {
            return "Updated \(Formatters.time.string(from: date))"
        }
        return "Updated \(Formatters.dateAndTime.string(from: date))"
    }

    private var popoverBackground: some View {
        ZStack {
            PopoverMaterial()
            Rectangle().fill(PanelTheme.panelWash)
        }
    }
}

private struct WorkingCard: View {
    let bot: Bot
    let now: Date
    let staleAfterMinutes: Int
    let reduceMotion: Bool
    @State private var hovered = false

    var body: some View {
        Group {
            if bot.openURL != nil {
                Button(action: open) { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
        .onHover { hovered = $0 }
        .help(bot.openURL == nil ? "" : "Open this agent's chat")
    }

    private var card: some View {
        HStack(spacing: 10) {
            MiniFace(status: "working", size: 28, fill: BotAccent.nsColor(name: bot.bot, stored: bot.color))
            VStack(alignment: .leading, spacing: 0) {
                Text(bot.bot)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PanelTheme.ink)
                    .lineLimit(1)
                    .frame(height: 16, alignment: .leading)
                Text(taskLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PanelTheme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 15, alignment: .leading)
            }
            pill
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTheme.cardRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.cardShadow, radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.cardWash)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.orangeTint)
            RadialGradient(
                stops: [
                    .init(color: PanelTheme.orange.opacity(0.20), location: 0),
                    .init(color: PanelTheme.orange.opacity(0), location: 1),
                ],
                center: UnitPoint(x: 0, y: 0.5),
                startRadius: 0,
                endRadius: 90
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if hovered {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(PanelTheme.hoverFill)
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(PanelTheme.orange.opacity(0.35))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(PanelTheme.orange)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 1 : pulse)
            }
            .frame(width: 12, height: 12)
            Text(isStale ? "stale?" : elapsedText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(PanelTheme.orangeText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PanelTheme.orangeSoft)
        )
    }

    private var isStale: Bool {
        bot.isStale(now: now, afterMinutes: staleAfterMinutes)
    }

    private var pulse: Double {
        let wave = sin(now.timeIntervalSinceReferenceDate * 3)
        return 0.35 + 0.65 * (0.5 + 0.5 * wave)
    }

    private var taskLine: String {
        let trimmed = bot.task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Working" : trimmed
    }

    private var elapsedText: String {
        guard let start = ISODate.date(from: bot.startedAt) else { return "" }
        return elapsed(since: start, now: now)
    }

    private var accessibilityText: String {
        var label = "\(bot.bot), working, \(taskLine)"
        if isStale {
            label += ", stale"
        } else if !elapsedText.isEmpty {
            label += ", for \(elapsedText)"
        }
        if bot.openURL != nil { label += ", opens chat" }
        return label
    }

    private func open() {
        if let url = bot.openURL {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TeamCard: View {
    let bots: [Bot]
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                TeamRow(bot: bot, now: now, failedTint: bot.status == "failed")
                    .frame(height: 32)
                    .overlay(alignment: .bottom) {
                        if index < bots.count - 1 {
                            Rectangle()
                                .fill(PanelTheme.separator)
                                .frame(height: 1)
                                .padding(.leading, 9)
                        }
                    }
            }
        }
        .background(teamBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTheme.cardRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.cardShadow, radius: 10, y: 4)
    }

    private var teamBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.cardWash)
        }
    }
}

private struct TeamRow: View {
    let bot: Bot
    let now: Date
    let failedTint: Bool
    @State private var hovered = false

    var body: some View {
        Group {
            if bot.openURL != nil {
                Button(action: open) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .onHover { hovered = $0 }
    }

    private var row: some View {
        HStack(spacing: 8) {
            MiniFace(status: bot.status, size: 20, fill: BotAccent.nsColor(name: bot.bot, stored: bot.color))
            HStack(spacing: 4) {
                Text(bot.bot)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PanelTheme.ink)
                    .lineLimit(1)
                if bot.status == "done" {
                    DoneMark()
                }
            }
            .frame(width: 72, alignment: .leading)
            Text(bot.status == "idle" ? "" : taskLine)
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusText)
                .font(.system(size: bot.status == "idle" ? 11 : 11, weight: bot.status == "idle" ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(rowFill)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var rowFill: Color {
        if hovered { return PanelTheme.hoverFill }
        if failedTint { return PanelTheme.redTint }
        return Color.clear
    }

    private var taskLine: String {
        let trimmed = bot.task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch bot.status {
        case "failed": return "Failed"
        case "done": return "Done"
        default: return ""
        }
    }

    private var statusText: String {
        switch bot.status {
        case "failed":
            let since = elapsedText
            return since.isEmpty ? "Failed" : "Failed · \(since)"
        case "done":
            return "Done"
        default:
            return "Idle"
        }
    }

    private var statusColor: Color {
        switch bot.status {
        case "failed": return PanelTheme.redText
        case "done": return PanelTheme.greenText
        default: return PanelTheme.ink2
        }
    }

    private var elapsedText: String {
        guard let start = ISODate.date(from: bot.startedAt) else { return "" }
        return elapsed(since: start, now: now)
    }

    private var accessibilityText: String {
        var label = "\(bot.bot), \(bot.status)"
        if bot.status != "idle" { label += ", \(taskLine)" }
        if bot.status == "failed", !elapsedText.isEmpty { label += ", \(elapsedText)" }
        if bot.openURL != nil { label += ", opens chat" }
        return label
    }

    private func open() {
        if let url = bot.openURL {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct FinishedCard: View {
    let jobs: [FinishedJob]
    let expanded: Bool
    let bots: [Bot]
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PanelTheme.ink)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 12, height: 12)
                    Text("Finished today")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PanelTheme.ink)
                    if !jobs.isEmpty {
                        Text("\(jobs.count)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(PanelTheme.greenText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(PanelTheme.greenSoft)
                            )
                    }
                    Spacer(minLength: 0)
                    if !jobs.isEmpty {
                        Text(totalText)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(PanelTheme.ink2)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if jobs.isEmpty {
                    Text("Nothing finished yet today.")
                        .font(.system(size: 12))
                        .foregroundStyle(PanelTheme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 24)
                        .padding(.leading, 12)
                        .padding(.trailing, 10)
                } else {
                    ForEach(jobs) { job in
                        let match = bots.first { $0.bot == job.bot }
                        JobLine(job: job, url: match?.openURL, storedColor: match?.color)
                            .frame(height: 24)
                    }
                }
                Color.clear.frame(height: 6)
            }
        }
        .background(finishedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTheme.cardRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.cardShadow, radius: 10, y: 4)
    }

    private var totalText: String {
        let ms = jobs.reduce(0) { $0 + $1.durationMs }
        return "\(durationLabel(ms: ms)) total"
    }

    private var finishedBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.cardWash)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.greenTint)
        }
    }
}

private struct JobLine: View {
    let job: FinishedJob
    let url: URL?
    let storedColor: String?
    @State private var hovered = false

    var body: some View {
        Group {
            if url != nil {
                Button(action: open) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .onHover { hovered = $0 }
    }

    private var row: some View {
        HStack(spacing: 8) {
            MiniFace(status: job.result == "failed" ? "failed" : "done", size: 14, fill: BotAccent.nsColor(name: job.bot, stored: storedColor))
            HStack(spacing: 4) {
                Text(job.bot)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelTheme.ink)
                    .lineLimit(1)
                if job.result == "failed" {
                    Circle()
                        .fill(PanelTheme.red)
                        .frame(width: 6, height: 6)
                } else {
                    DoneMark()
                }
            }
            .frame(width: 70, alignment: .leading)
            Text(job.task.isEmpty ? (job.result == "failed" ? "Failed" : "Done") : job.task)
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(durationLabel(ms: job.durationMs))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(PanelTheme.ink2)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovered ? PanelTheme.hoverFill : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.bot), \(job.result), \(durationLabel(ms: job.durationMs))")
    }

    private func open() {
        if let url = url {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct FooterButton: View {
    var title: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    var key: KeyEquivalent? = nil
    var hoverFill: Color
    var ink: Color
    var ink2: Color
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium))
                }
            }
            .foregroundStyle(hovered ? ink : ink2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovered ? hoverFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(ShortcutModifier(key: key))
    }
}

private struct ShortcutModifier: ViewModifier {
    var key: KeyEquivalent?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key = key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// Glossy cube on a 32-unit grid. The fill is the bot's own colour.
/// Eyes are dark on a light face and light on a dark face. Status is not the fill.
private struct MiniFace: View {
    let status: String
    let size: CGFloat
    let fill: NSColor

    var body: some View {
        let unit = size / 32
        let top = Color(nsColor: BotAccent.mix(fill, with: .white, amount: 0.28))
        let base = Color(nsColor: fill)
        let edge = Color(nsColor: BotAccent.mix(fill, with: .black, amount: 0.22))
        let ink = BotAccent.featureInk(fill)
        let lightFace = BotAccent.isLight(fill)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8.5 * unit, style: .continuous)
                .fill(edge)
                .frame(width: size, height: size)
            RoundedRectangle(cornerRadius: 8.5 * unit, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: top, location: 0),
                            .init(color: base, location: 0.55),
                            .init(color: edge, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: 28.4 * unit)
            Capsule()
                .fill(lightFace ? Color.black.opacity(0.14) : Color.white.opacity(0.62))
                .frame(width: 14 * unit, height: 3.4 * unit)
                .offset(x: 6 * unit, y: 4 * unit)
            if size >= 20 {
                Circle()
                    .fill(lightFace ? Color.white.opacity(0.85) : Color.white.opacity(0.75))
                    .frame(width: 2.6 * unit, height: 2.6 * unit)
                    .offset(x: (24 - 1.3) * unit, y: (5.7 - 1.3) * unit)
            }
            features(unit, ink: ink, lightFace: lightFace)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func features(_ unit: CGFloat, ink: Color, lightFace: Bool) -> some View {
        switch status {
        case "working":
            eye(unit, cx: 11, cy: 15, radius: 2.7, catchlight: size >= 20, ink: ink, lightFace: lightFace)
            eye(unit, cx: 21, cy: 15, radius: 2.7, catchlight: size >= 20, ink: ink, lightFace: lightFace)
            smile(unit, start: 12.6, end: 19.4, y: 20.2, controlY: 24.6)
                .fill(ink)
        case "done":
            arc(unit, startX: 8.4, endX: 13.6, y: 16.2, controlY: 12.4, width: 2.2, ink: ink)
            arc(unit, startX: 18.4, endX: 23.6, y: 16.2, controlY: 12.4, width: 2.2, ink: ink)
            smile(unit, start: 11.6, end: 20.4, y: 19.6, controlY: 25.4)
                .fill(ink)
        case "failed":
            brow(unit, from: CGPoint(x: 8.6, y: 12.2), to: CGPoint(x: 13.2, y: 13.8), ink: ink)
            brow(unit, from: CGPoint(x: 23.4, y: 12.2), to: CGPoint(x: 18.8, y: 13.8), ink: ink)
            eye(unit, cx: 11, cy: 16.6, radius: 2.3, catchlight: false, ink: ink, lightFace: lightFace)
            eye(unit, cx: 21, cy: 16.6, radius: 2.3, catchlight: false, ink: ink, lightFace: lightFace)
            frown(unit, ink: ink)
        default:
            idleLine(unit, cx: 11, y: 16, width: 4.4, ink: ink)
            idleLine(unit, cx: 21, y: 16, width: 4.4, ink: ink)
            idleLine(unit, cx: 16, y: 21.4, width: 2.8, ink: ink)
        }
    }

    private func eye(_ unit: CGFloat, cx: CGFloat, cy: CGFloat, radius: CGFloat, catchlight: Bool, ink: Color, lightFace: Bool) -> some View {
        ZStack {
            Circle()
                .fill(ink)
                .frame(width: radius * 2 * unit, height: radius * 2 * unit)
            if catchlight {
                Circle()
                    .fill(lightFace ? Color.white : Color.black.opacity(0.35))
                    .frame(width: 1.6 * unit, height: 1.6 * unit)
                    .offset(x: 0.9 * unit, y: -0.9 * unit)
            }
        }
        .offset(x: (cx - radius) * unit, y: (cy - radius) * unit)
    }

    private func smile(_ unit: CGFloat, start: CGFloat, end: CGFloat, y: CGFloat, controlY: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: start * unit, y: y * unit))
            path.addQuadCurve(
                to: CGPoint(x: end * unit, y: y * unit),
                control: CGPoint(x: 16 * unit, y: controlY * unit)
            )
            path.closeSubpath()
        }
    }

    private func arc(_ unit: CGFloat, startX: CGFloat, endX: CGFloat, y: CGFloat, controlY: CGFloat, width: CGFloat, ink: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: startX * unit, y: y * unit))
            path.addQuadCurve(
                to: CGPoint(x: endX * unit, y: y * unit),
                control: CGPoint(x: ((startX + endX) / 2) * unit, y: controlY * unit)
            )
        }
        .stroke(ink, style: StrokeStyle(lineWidth: width * unit, lineCap: .round))
    }

    private func brow(_ unit: CGFloat, from: CGPoint, to: CGPoint, ink: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: from.x * unit, y: from.y * unit))
            path.addLine(to: CGPoint(x: to.x * unit, y: to.y * unit))
        }
        .stroke(ink, style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round))
    }

    private func frown(_ unit: CGFloat, ink: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 12.4 * unit, y: 23.4 * unit))
            path.addQuadCurve(
                to: CGPoint(x: 19.6 * unit, y: 23.4 * unit),
                control: CGPoint(x: 16 * unit, y: 20 * unit)
            )
        }
        .stroke(ink, style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round))
    }

    private func idleLine(_ unit: CGFloat, cx: CGFloat, y: CGFloat, width: CGFloat, ink: Color) -> some View {
        Capsule()
            .fill(ink)
            .frame(width: width * unit, height: 2 * unit)
            .offset(x: (cx - width / 2) * unit, y: (y - 1) * unit)
    }
}

private struct DoneMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(PanelTheme.greenText)
            .accessibilityHidden(true)
    }
}

enum BotAccent {
    /// Pleasant colours that stay off the status orange, red, and green.
    static let palette = [
        "#3B82F6", "#8B5CF6", "#EC4899", "#06B6D4", "#6366F1",
        "#A855F7", "#0EA5E9", "#D946EF", "#14B8A6", "#64748B",
    ]

    static func nsColor(name: String, stored: String?) -> NSColor {
        if let stored = stored, let parsed = PanelTheme.nsHexColor(stored) {
            return parsed
        }
        var hash: UInt32 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        let index = Int(hash % UInt32(palette.count))
        return PanelTheme.nsHexColor(palette[index]) ?? NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    }

    static func color(name: String, stored: String?) -> Color {
        Color(nsColor: nsColor(name: name, stored: stored))
    }

    /// True when dark features contrast better than light ones.
    static func isLight(_ color: NSColor) -> Bool {
        let luminance = relativeLuminance(color)
        let darkContrast = (luminance + 0.05) / 0.05
        let lightContrast = 1.05 / (luminance + 0.05)
        return darkContrast >= lightContrast
    }

    static func featureInk(_ color: NSColor) -> Color {
        if isLight(color) {
            return Color(nsColor: NSColor(srgbRed: 26.0 / 255.0, green: 20.0 / 255.0, blue: 16.0 / 255.0, alpha: 1))
        }
        return Color.white
    }

    static func mix(_ color: NSColor, with target: NSColor, amount: CGFloat) -> NSColor {
        let base = channels(color)
        let other = channels(target)
        let clamped = min(1, max(0, amount))
        return NSColor(
            srgbRed: base.0 + (other.0 - base.0) * clamped,
            green: base.1 + (other.1 - base.1) * clamped,
            blue: base.2 + (other.2 - base.2) * clamped,
            alpha: 1
        )
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = channels(color)
        func linear(_ channel: CGFloat) -> CGFloat {
            if channel <= 0.04045 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    private static func channels(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }
}

enum PanelTheme {
    static var ink: Color { dynamic("#16151B", "#F7F6FA") }
    static var ink2: Color { dynamic("#4A4855", "#D2CFDC") }
    static var faceInk: Color { dynamic("#1A1410", "#1A1410") }

    static var orange: Color { dynamic("#F39C28", "#F39C28") }
    static var red: Color { dynamic("#E5484D", "#E5484D") }
    static var done: Color { dynamic("#2EB866", "#3DD07A") }
    static var grey: Color { dynamic("#8E8E93", "#8E8E93") }

    static var orangeText: Color { dynamic("#743E00", "#FFC47A") }
    static var redText: Color { dynamic("#9A1B23", "#FFB4B6") }
    static var greenText: Color { dynamic("#125A31", "#7BE3A2") }

    static var panelWash: Color { dynamic("#FFFFFF", "#16161A", lightAlpha: 0.50, darkAlpha: 0.45) }
    static var cardWash: Color { dynamic("#FFFFFF", "#121216", lightAlpha: 0.72, darkAlpha: 0.70) }
    static var orangeTint: Color { dynamic("#F39C28", "#F39C28", lightAlpha: 0.10, darkAlpha: 0.14) }
    static var redTint: Color { dynamic("#E5484D", "#E5484D", lightAlpha: 0.10, darkAlpha: 0.14) }
    static var greenTint: Color { dynamic("#2EB866", "#3DD07A", lightAlpha: 0.06, darkAlpha: 0.06) }
    static var orangeSoft: Color { dynamic("#F39C28", "#F39C28", lightAlpha: 0.16, darkAlpha: 0.22) }
    static var greenSoft: Color { dynamic("#2EB866", "#3DD07A", lightAlpha: 0.16, darkAlpha: 0.22) }
    static var cardRim: Color { dynamic("#FFFFFF", "#FFFFFF", lightAlpha: 0.70, darkAlpha: 0.10) }
    static var separator: Color { dynamic("#16151B", "#FFFFFF", lightAlpha: 0.10, darkAlpha: 0.12) }
    static var cardShadow: Color { dynamic("#2B1E5C", "#000000", lightAlpha: 0.10, darkAlpha: 0.35) }
    static var hoverFill: Color { dynamic("#16151B", "#FFFFFF", lightAlpha: 0.07, darkAlpha: 0.10) }

    static func statusBase(_ status: String) -> Color {
        switch status {
        case "working": return orange
        case "failed": return red
        case "done": return done
        default: return grey
        }
    }

    static func statusTop(_ status: String) -> Color {
        switch status {
        case "working": return dynamic("#F6B56A", "#F6B56A")
        case "failed": return dynamic("#EC8285", "#EC8285")
        case "done": return dynamic("#6ACD93", "#73DC9D")
        default: return dynamic("#AEAEB2", "#AEAEB2")
        }
    }

    static func statusEdge(_ status: String) -> Color {
        switch status {
        case "working": return dynamic("#BE7A1F", "#BE7A1F")
        case "failed": return dynamic("#B3383C", "#B3383C")
        case "done": return dynamic("#24904F", "#30A25F")
        default: return dynamic("#6F6F73", "#6F6F73")
        }
    }

    static func nsHexColor(_ value: String) -> NSColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#") else { return nil }
        let hex = String(trimmed.dropFirst())
        guard let rgb = UInt32(hex, radix: 16), hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hexColor(_ value: String) -> Color? {
        guard let color = nsHexColor(value) else { return nil }
        return Color(nsColor: color)
    }

    static func dynamic(
        _ light: String,
        _ dark: String,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        let color = NSColor(name: nil, dynamicProvider: { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsHex(darkMode ? dark : light, alpha: darkMode ? darkAlpha : lightAlpha)
        })
        return Color(nsColor: color)
    }

    private static func nsHex(_ value: String, alpha: CGFloat) -> NSColor {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let rgb = UInt32(hex, radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private func elapsed(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let extra = minutes % 60
    if hours < 48 {
        if extra == 0 { return "\(hours)h" }
        return "\(hours)h \(extra)m"
    }
    return "\(hours / 24)d"
}

private func durationLabel(ms: Int) -> String {
    let seconds = max(0, ms / 1000)
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let extra = minutes % 60
    if extra == 0 { return "\(hours)h" }
    return "\(hours)h \(extra)m"
}
