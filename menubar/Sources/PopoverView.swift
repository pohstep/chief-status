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
            return 640
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
        let needs = model.bots.filter { $0.status == "needs_input" }
        let workingAll = model.bots.filter { $0.status == "working" }
        let quiet = workingAll.filter { bot in
            bot.isQuiet(now: model.now, afterMinutes: model.quietAfterMinutes)
                && !bot.isFaded(now: model.now, staleAfterMinutes: model.staleAfterMinutes)
        }
        let working = workingAll.filter { bot in
            !quiet.contains(where: { $0.id == bot.id })
        }
        let team = model.bots.filter { $0.status != "working" && $0.status != "needs_input" }
        var height: CGFloat = 0
        if !needs.isEmpty {
            height += 24
            height += CGFloat(needs.count) * 46
            if needs.count > 1 {
                height += CGFloat(needs.count - 1) * 6
            }
        }
        if !working.isEmpty {
            height += 24
            height += CGFloat(working.count) * 46
            if working.count > 1 {
                height += CGFloat(working.count - 1) * 6
            }
        }
        if !quiet.isEmpty {
            height += 8
            height += CGFloat(quiet.count) * 32
        }
        if !team.isEmpty {
            height += 8
            height += CGFloat(team.count) * 32
        }
        if model.bots.isEmpty && model.today.isEmpty {
            height += 110
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
        let needs = model.bots.filter { $0.status == "needs_input" }.count
        let allWorking = model.bots.filter { $0.status == "working" }
        let stale = allWorking.filter { $0.isFaded(now: model.now, staleAfterMinutes: model.staleAfterMinutes) }.count
        let quietWorking = allWorking.filter { bot in
            bot.isQuiet(now: model.now, afterMinutes: model.quietAfterMinutes)
                && !bot.isFaded(now: model.now, staleAfterMinutes: model.staleAfterMinutes)
        }.count
        let working = allWorking.count - stale - quietWorking
        let quietIdle = model.bots.filter { bot in
            bot.status == "idle" && bot.isQuiet(now: model.now, afterMinutes: model.quietAfterMinutes)
        }.count
        let failed = model.bots.filter { $0.status == "failed" }.count
        let doneToday = model.today.filter { $0.result == "done" }.count
        return Group {
            if needs == 0 && working == 0 && stale == 0 && failed == 0 && doneToday == 0 {
                if quietWorking == 0 && quietIdle == 0 {
                    Text("All idle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PanelTheme.ink2)
                } else {
                    Text("")
                        .accessibilityHidden(true)
                }
            } else {
                HStack(spacing: 6) {
                    if needs > 0 {
                        summaryPart(count: needs, word: needs == 1 ? "needs you" : "need you", color: PanelTheme.indigo)
                    }
                    if needs > 0 && (working > 0 || stale > 0 || failed > 0 || doneToday > 0) {
                        summaryDot
                    }
                    if working > 0 {
                        summaryPart(count: working, word: "working", color: PanelTheme.orange)
                    }
                    if working > 0 && (stale > 0 || failed > 0 || doneToday > 0) {
                        summaryDot
                    }
                    if stale > 0 {
                        summaryPart(count: stale, word: "maybe stale", color: Color(nsColor: PanelTheme.lostFace), rim: true)
                    }
                    if stale > 0 && (failed > 0 || doneToday > 0) {
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    private var summaryDot: some View {
        Text("·")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PanelTheme.ink2)
    }

    private func summaryPart(count: Int, word: String, color: Color, rim: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.white.opacity(rim ? 0.6 : 0), lineWidth: 1))
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

    /// Fresh cards first, longest-running first. Maybe-stale cards drop below them.
    /// A quiet working bot that has not yet faded leaves this list for a plain row.
    private var workingBots: [Bot] {
        let now = model.now
        let staleAfter = model.staleAfterMinutes
        let quietAfter = model.quietAfterMinutes
        return model.bots
            .filter { bot in
                if bot.status != "working" { return false }
                if bot.isQuiet(now: now, afterMinutes: quietAfter) && !bot.isFaded(now: now, staleAfterMinutes: staleAfter) {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let leftFaded = lhs.isFaded(now: now, staleAfterMinutes: staleAfter)
                let rightFaded = rhs.isFaded(now: now, staleAfterMinutes: staleAfter)
                if leftFaded != rightFaded { return !leftFaded }
                let left = ISODate.date(from: lhs.startedAt) ?? .distantFuture
                let right = ISODate.date(from: rhs.startedAt) ?? .distantFuture
                if left != right { return left < right }
                return lhs.bot.localizedCaseInsensitiveCompare(rhs.bot) == .orderedAscending
            }
    }

    /// Waiting on you, longest waiting first. Always at the very top.
    private var needsBots: [Bot] {
        model.bots
            .filter { $0.status == "needs_input" }
            .sorted { lhs, rhs in
                let left = ISODate.date(from: lhs.startedAt) ?? .distantFuture
                let right = ISODate.date(from: rhs.startedAt) ?? .distantFuture
                if left != right { return left < right }
                return lhs.bot.localizedCaseInsensitiveCompare(rhs.bot) == .orderedAscending
            }
    }

    /// Working, last post older than the quiet setting, and not yet a black 404 card. Longest quiet first.
    private var quietWorkingBots: [Bot] {
        let now = model.now
        let staleAfter = model.staleAfterMinutes
        let quietAfter = model.quietAfterMinutes
        return model.bots
            .filter { bot in
                bot.status == "working"
                    && bot.isQuiet(now: now, afterMinutes: quietAfter)
                    && !bot.isFaded(now: now, staleAfterMinutes: staleAfter)
            }
            .sorted { lhs, rhs in
                let left = lhs.freshnessDate() ?? .distantFuture
                let right = rhs.freshnessDate() ?? .distantFuture
                if left != right { return left < right }
                return lhs.bot.localizedCaseInsensitiveCompare(rhs.bot) == .orderedAscending
            }
    }

    private var teamBots: [Bot] {
        let rank = ["failed": 0, "done": 1, "idle": 2]
        return model.bots
            .filter { $0.status != "working" && $0.status != "needs_input" }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("No bots yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(PanelTheme.ink2)
                    setupHelp
                    if let note = model.testNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(PanelTheme.ink2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            if !needsBots.isEmpty {
                Text("NEEDS YOU")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(PanelTheme.ink2)
                    .frame(height: 14, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .padding(.leading, 4)
                VStack(spacing: 6) {
                    ForEach(needsBots) { bot in
                        NeedsCard(bot: bot, now: model.now)
                            .frame(height: 46)
                    }
                }
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
                        WorkingCard(bot: bot, now: model.now, staleAfterMinutes: model.staleAfterMinutes, reduceMotion: reduceMotion, onClear: { model.clearLocally(bot) })
                            .frame(height: 46)
                    }
                }
            }
            if !quietWorkingBots.isEmpty {
                Color.clear.frame(height: 8)
                QuietCard(bots: quietWorkingBots, now: model.now)
            }
            if !teamBots.isEmpty {
                Color.clear.frame(height: 8)
                TeamCard(bots: teamBots, today: model.today, now: model.now, quietAfterMinutes: model.quietAfterMinutes)
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
            if model.canCancelEdit {
                Text("Paste a new feed address.")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelTheme.ink2)
            }
            setupHelp
            Group {
                TextField(
                    "Feed address",
                    text: $model.draftURL,
                    prompt: Text("https://your-worker.workers.dev/status")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { model.saveAddress() }
                TextField(
                    "Post password",
                    text: $model.postPassword,
                    prompt: Text("The password bots use to post")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                Text("Shown here so you can copy the bot prompt. Not saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                SecureField(
                    "Read token (optional)",
                    text: $model.readToken,
                    prompt: Text("Read token (optional)")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { model.commitReadToken() }
                Text("Only if your feed is locked. Saved on this Mac and sent when the app reads the feed.")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = SetupShare.botPrompt(feed: shareFeed, password: model.postPassword) {
                Text("Bot prompt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelTheme.ink)
                TextEditor(text: .constant(prompt))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 120)
                if let link = SetupShare.link(feed: shareFeed, password: model.postPassword, readToken: model.readToken) {
                    Text("Setup link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PanelTheme.ink)
                    Text(link)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PanelTheme.ink2)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    if !model.readToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This link includes the read token. Opening it on this Mac saves the token.")
                            .font(.system(size: 11))
                            .foregroundStyle(PanelTheme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Copy prompt") { model.copyText(prompt) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Copy link") { model.copyText(link) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } else {
                Text("Add the feed address and the post password to see the bot prompt.")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.setupError ?? model.copyNote ?? model.testNote ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(model.setupError == nil ? PanelTheme.ink2 : PanelTheme.redText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 40, alignment: .top)
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
            Group {
                Toggle("Open at login", isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                ))
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
                if let note = model.loginNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Alert when a bot fails", isOn: Binding(
                    get: { model.alertOnFailure },
                    set: { model.setAlertOnFailure($0) }
                ))
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("Appearance")
                        .font(.system(size: 12))
                        .foregroundStyle(PanelTheme.ink)
                    Picker("Appearance", selection: Binding(
                        get: { model.appearance },
                        set: { model.setAppearance($0) }
                    )) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 180)
                }
                .frame(height: 24)
                Text(model.alertNote ?? "Off unless you turn it on. A new failure is spoken aloud and shows a banner.")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                iconColour
                NeedsYouSettingsSection(model: model)
                QuietAfterRow(model: model)
                AboutSection(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private var iconColour: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Icon colour")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelTheme.ink)
                Spacer(minLength: 8)
                defaultIconButton
            }
            swatchRow(Array(IconSwatch.all.prefix(6)))
            swatchRow(Array(IconSwatch.all.suffix(5)))
            ColorPicker("Custom", selection: customIconColor, supportsOpacity: false)
                .font(.system(size: 12))
            Text("\(model.iconColor.title). The working, stale 404 and needs-you ? cubes use this. Idle grey and failed red stay as they are.")
                .font(.system(size: 11))
                .foregroundStyle(PanelTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultIconButton: some View {
        Group {
            if model.iconColor.isDefault {
                Button("Default") { model.setIconColor(IconColorSetting(stored: IconColorSetting.defaultToken)) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Default") { model.setIconColor(IconColorSetting(stored: IconColorSetting.defaultToken)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func swatchRow(_ swatches: [IconSwatch]) -> some View {
        HStack(spacing: 6) {
            ForEach(swatches) { swatch in
                swatchButton(swatch)
            }
        }
    }

    private func swatchButton(_ swatch: IconSwatch) -> some View {
        let selected = model.iconColor.stored == swatch.hex
        return Button(action: { model.setIconColor(IconColorSetting(stored: swatch.hex)) }) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: swatch.nsColor))
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? PanelTheme.ink : Color.clear, lineWidth: 2)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private var customIconColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.iconColor.nsColor) },
            set: { newValue in
                let hex = IconColorSetting.hex(from: NSColor(newValue))
                if IconColorSetting.nearly(hex, model.iconColor.pickerHex) { return }
                model.setIconColor(IconColorSetting(stored: hex))
            }
        )
    }

    /// Address used to fill the prompt. The draft wins while Settings is open.
    private var shareFeed: String {
        let draft = model.draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        return model.feedURL
    }

    private var setupHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page = URL(string: SetupShare.guide) {
                Link("No feed yet? Set one up", destination: page)
                    .font(.system(size: 12, weight: .semibold))
            }
            Button(model.sendingTest ? "Sending…" : "Send a test post") { model.sendTestPost() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.sendingTest)
            Button("Deploy to Cloudflare") { openDeployPage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func openDeployPage() {
        if let page = URL(string: SetupShare.deployPage) {
            NSWorkspace.shared.open(page)
        }
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
    var onClear: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        Group {
            if isFaded {
                // A maybe-stale card always shows "Check on it" and "Clear". The rest of the card does nothing,
                // so a click never opens the chat without that choice.
                card
            } else if bot.openURL != nil {
                Button(action: open) { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
        .onHover { hovered = $0 }
        .help(isFaded ? "" : (bot.openURL == nil ? "" : "Open this agent's chat"))
        .contextMenu {
            if bot.openURL != nil {
                Button("Check on it") { open() }
            }
            if isFaded {
                Button("Clear the warning") { onClear() }
            }
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            MiniFace(status: isFaded ? "lost" : "working", size: 28, fill: BotAccent.nsColor(name: bot.bot, stored: bot.color))
            VStack(alignment: .leading, spacing: 0) {
                Text(bot.bot)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFaded ? PanelTheme.lostInk : PanelTheme.ink)
                    .lineLimit(1)
                    .frame(height: 16, alignment: .leading)
                Text(taskLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFaded ? PanelTheme.lostInk2 : PanelTheme.ink2)
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
                .strokeBorder(isFaded ? PanelTheme.lostRim : PanelTheme.cardRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.cardShadow, radius: 10, y: 4)
        .accessibilityElement(children: isFaded ? .contain : .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isFaded {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(PanelTheme.lostCard)
                if hovered {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                }
            }
        } else {
            freshBackground
        }
    }

    private var freshBackground: some View {
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

    @ViewBuilder
    private var pill: some View {
        if isFaded {
            VStack(alignment: .trailing, spacing: 3) {
                lostLabel
                lostActions
            }
        } else {
            freshPill
        }
    }

    /// Black card label: a hollow ring (no pulse) and "maybe stale · 34m", then "stale? · 1h 5m" at STALE_MINUTES.
    private var lostLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .strokeBorder(PanelTheme.lostInk2, lineWidth: 1.3)
                .frame(width: 7, height: 7)
            Text(isStale ? "stale? · \(quietElapsed)" : "maybe stale · \(quietElapsed)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(PanelTheme.lostInk)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 13)
    }

    /// Always shown on a maybe-stale card, small and inline.
    private var lostActions: some View {
        HStack(spacing: 4) {
            Button {
                open()
            } label: {
                Text("Check on it")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(bot.openURL == nil ? PanelTheme.lostInk2.opacity(0.5) : PanelTheme.lostInk)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.18)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(bot.openURL == nil)
            .help(bot.openURL == nil ? "No chat link for this bot. Add one in links.json." : "Open this agent's chat")
            Button {
                onClear()
            } label: {
                Text("Clear")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PanelTheme.lostInk)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.18)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the warning on this Mac. Nothing is posted; it comes back if the bot stays quiet")
        }
        .fixedSize()
    }

    private var freshPill: some View {
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
            Text(freshPillText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(PanelTheme.orangeText)
                .lineLimit(1)
                .fixedSize()
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

    private var isFaded: Bool {
        bot.isFaded(now: now, staleAfterMinutes: staleAfterMinutes)
    }

    /// Cleared on this Mac: normal working look, but say how old the last post is.
    private var isQuieted: Bool {
        bot.isQuieted(now: now)
    }

    private var freshPillText: String {
        if isQuieted, let start = bot.freshnessDate() {
            return "last update \(ago(since: start, now: now))"
        }
        return isStale ? "stale?" : elapsedText
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

    /// How long the job has been running. The 404 clock is quietElapsed, from the last post.
    private var elapsedText: String {
        guard let start = ISODate.date(from: bot.startedAt) else { return "" }
        return elapsed(since: start, now: now)
    }

    private var quietElapsed: String {
        guard let start = bot.freshnessDate() else { return "" }
        return elapsed(since: start, now: now)
    }

    private var accessibilityText: String {
        var label = "\(bot.bot), working, \(taskLine)"
        if isFaded, let start = bot.freshnessDate() {
            label += ", last update \(spokenAgo(since: start, now: now))"
            label += isStale ? ", stale" : ", maybe stale"
        } else if isQuieted, let start = bot.freshnessDate() {
            label += ", last update \(spokenAgo(since: start, now: now)), warning cleared"
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

/// A bot waiting on you. Its own indigo card at the very top. It never goes stale, but shows how long it has waited.
private struct NeedsCard: View {
    let bot: Bot
    let now: Date
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
            MiniFace(status: "needs_input", size: 28, fill: BotAccent.nsColor(name: bot.bot, stored: bot.color))
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
            HStack(spacing: 5) {
                Circle()
                    .fill(PanelTheme.indigo)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PanelTheme.indigoText)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(PanelTheme.indigoSoft)
            )
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTheme.indigoRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.indigo.opacity(0.25), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.cardWash)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.indigoTint)
            RadialGradient(
                stops: [
                    .init(color: PanelTheme.indigo.opacity(0.24), location: 0),
                    .init(color: PanelTheme.indigo.opacity(0), location: 1),
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

    private var since: Date? { ISODate.date(from: bot.startedAt) }

    private var label: String {
        let word = bot.approval ? "approve" : "needs you"
        guard let since = since else { return word }
        return "\(word) · \(ago(since: since, now: now))"
    }

    private var taskLine: String {
        let trimmed = bot.task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Waiting for you" : trimmed
    }

    private var accessibilityText: String {
        let waiting = bot.approval ? "needs your approval" : "needs you"
        var text = "\(bot.bot), \(waiting), \(taskLine)"
        if let since = since { text += ", since \(spokenAgo(since: since, now: now))" }
        if bot.openURL != nil { text += ", opens chat" }
        return text
    }

    private func open() {
        if let url = bot.openURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A working bot whose last post is past the quiet setting, and not yet a 404 card.
/// Face and label only. No pulse, no sound.
private struct QuietCard: View {
    let bots: [Bot]
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                QuietRow(bot: bot, now: now)
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
        .background(quietBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PanelTheme.cardRim, lineWidth: 1)
        )
        .shadow(color: PanelTheme.cardShadow, radius: 10, y: 4)
    }

    private var quietBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanelTheme.cardWash)
        }
    }
}

private struct QuietRow: View {
    let bot: Bot
    let now: Date
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
        .help(bot.openURL == nil ? "" : "Open this agent's chat")
    }

    private var row: some View {
        HStack(spacing: 8) {
            MiniFace(status: "working", size: 20, fill: BotAccent.nsColor(name: bot.bot, stored: bot.color))
            Text(bot.bot)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PanelTheme.ink)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            Text(taskLine)
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(bot.noUpdateLabel(now: now))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(PanelTheme.ink2)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hovered ? PanelTheme.hoverFill : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var taskLine: String {
        bot.task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accessibilityText: String {
        var label = "\(bot.bot), \(bot.noUpdateLabel(now: now))"
        if !taskLine.isEmpty { label += ", \(taskLine)" }
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
    let today: [FinishedJob]
    let now: Date
    let quietAfterMinutes: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                TeamRow(bot: bot, lastPost: bot.lastPostDate(today: today), now: now, failedTint: bot.status == "failed", quietAfterMinutes: quietAfterMinutes)
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
    let lastPost: Date?
    let now: Date
    let failedTint: Bool
    let quietAfterMinutes: Int
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
                .fixedSize()
                .layoutPriority(1)
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

    /// "Done · 12m ago". Done and failed count from the job's end, everything else from started_at.
    /// A quiet idle bot says "no update in N min" and nothing else.
    private var statusText: String {
        if bot.status == "idle" && bot.isQuiet(now: now, afterMinutes: quietAfterMinutes) {
            return bot.noUpdateLabel(now: now)
        }
        let word: String
        switch bot.status {
        case "failed": word = "Failed"
        case "done": word = "Done"
        default: word = "Idle"
        }
        guard let lastPost = lastPost else { return word }
        return "\(word) · \(ago(since: lastPost, now: now))"
    }

    private var statusColor: Color {
        switch bot.status {
        case "failed": return PanelTheme.redText
        case "done": return PanelTheme.greenText
        default: return PanelTheme.ink2
        }
    }

    private var accessibilityText: String {
        if bot.status == "idle" && bot.isQuiet(now: now, afterMinutes: quietAfterMinutes) {
            var quiet = "\(bot.bot), \(bot.noUpdateLabel(now: now))"
            if bot.openURL != nil { quiet += ", opens chat" }
            return quiet
        }
        var label = "\(bot.bot), \(bot.status)"
        if bot.status != "idle" { label += ", \(taskLine)" }
        if let lastPost = lastPost { label += ", last update \(spokenAgo(since: lastPost, now: now))" }
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
        let lost = status == "lost"
        let face = fill
        let top = Color(nsColor: BotAccent.mix(face, with: .white, amount: 0.28))
        let base = Color(nsColor: face)
        let edge = Color(nsColor: BotAccent.mix(face, with: .black, amount: 0.22))
        let ink = BotAccent.featureInk(face)
        let lightFace = BotAccent.isLight(face)
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
            if size >= 20, !lost {
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
        case "needs_input":
            Text("?")
                .font(.system(size: 19 * unit, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .frame(width: size, height: 28.4 * unit, alignment: .center)
        case "lost":
            Text("404")
                .font(.system(size: max(7.5, 10.5 * unit), weight: .heavy, design: .rounded).monospacedDigit())
                .kerning(-0.2)
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .frame(width: size, height: 28.4 * unit, alignment: .center)
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

    /// Maybe stale. Black in both modes; the light rim is what keeps it apart from a dark panel.
    static let lostFace = NSColor(srgbRed: 17.0 / 255.0, green: 17.0 / 255.0, blue: 19.0 / 255.0, alpha: 1)
    static var lostCard: Color { dynamic("#111113", "#050506", lightAlpha: 0.92, darkAlpha: 0.94) }
    static var lostRim: Color { dynamic("#FFFFFF", "#FFFFFF", lightAlpha: 0.28, darkAlpha: 0.30) }
    static var lostInk: Color { dynamic("#F7F6FA", "#F7F6FA") }
    static var lostInk2: Color { dynamic("#C9C6D3", "#BDBAC8") }

    /// Needs input. Indigo #4F5BE8 (hue 235°), clear of orange, red, green, black, grey and every bot colour.
    static var indigo: Color { dynamic("#4F5BE8", "#6B76F5") }
    static var indigoText: Color { dynamic("#2A2F9E", "#C3C8FF") }
    static var indigoTint: Color { dynamic("#4F5BE8", "#4F5BE8", lightAlpha: 0.10, darkAlpha: 0.20) }
    static var indigoSoft: Color { dynamic("#4F5BE8", "#6B76F5", lightAlpha: 0.16, darkAlpha: 0.26) }
    static var indigoRim: Color { dynamic("#4F5BE8", "#8B93FF", lightAlpha: 0.45, darkAlpha: 0.45) }

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

/// "now" under a minute, then "12m ago", "3h ago", "2d ago".
private func ago(since date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

private func spokenAgo(since date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
    let hours = minutes / 60
    if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
    let days = hours / 24
    return days == 1 ? "1 day ago" : "\(days) days ago"
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

private struct AboutSection: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanelTheme.ink)
            Text("Chief Status \(AppVersion.current)")
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink)
            Button(model.checkingUpdate ? "Checking…" : "Check for updates") {
                model.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.checkingUpdate)
            updateResult
        }
        .padding(.top, 4)
    }

    private var updateResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.updateNote.isEmpty {
                Text(model.updateNote)
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.updateAvailable {
                if let page = model.updatePage {
                    Button("Download") { NSWorkspace.shared.open(page) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Text("brew upgrade --cask chief-status")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PanelTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct QuietAfterRow: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("No update after")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelTheme.ink)
                Picker("No update after", selection: Binding(
                    get: { model.quietAfterMinutes },
                    set: { model.setQuietAfter($0) }
                )) {
                    ForEach(QuietAfter.choices, id: \.self) { minutes in
                        Text(QuietAfter.title(for: minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 88)
            }
            .frame(height: 24)
            Text("A working or idle bot with no post for this long shows \"no update in N min\". No sound and no banner. The 30-minute black card is unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(PanelTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

private struct NeedsYouSettingsSection: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When a bot needs you")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanelTheme.ink)
            Toggle("Sound alert when a bot needs you", isOn: Binding(
                get: { model.needsYouSound },
                set: { model.setNeedsYouSound($0) }
            ))
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)
            reminderRow
            Text("Off until you turn it on. Speaks once when a bot starts waiting. It does not check Focus. A reminder speaks at most 3 times, then stops until a new bot starts waiting.")
                .font(.system(size: 11))
                .foregroundStyle(PanelTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var reminderRow: some View {
        HStack(spacing: 8) {
            Text("Remind every")
                .font(.system(size: 12))
                .foregroundStyle(PanelTheme.ink)
            Picker("Remind every", selection: Binding(
                get: { model.needsYouReminderMinutes },
                set: { model.setNeedsYouReminder($0) }
            )) {
                ForEach(NeedsYouSettings.reminderChoices, id: \.self) { minutes in
                    Text(NeedsYouSettings.title(for: minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 88)
        }
        .frame(height: 24)
    }
}

/// `ChiefStatus --render-preview <folder>`: sample panels in light and dark, the 404 face at 28 and 20 pt,
/// every menu bar cube, the icon colour presets, and the About section.
/// Nothing is read from or sent to the feed.
enum PreviewRenderer {
    static func run(folder: String) -> Int32 {
        let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = sampleModel()
        var ok = true
        for (name, dark) in [("light", false), ("dark", true)] {
            let height = Metrics.height(for: model)
            let panel = ZStack {
                Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93))
                StatusPopoverView(model: model)
            }
            .frame(width: Metrics.width, height: height)
            ok = write(panel, size: NSSize(width: Metrics.width, height: height), dark: dark, to: directory.appendingPathComponent("panel-\(name).png")) && ok

            model.editingAddress = true
            model.draftURL = "https://example.com/status"
            model.postPassword = "example-password"
            let setupHeight = Metrics.height(for: model)
            let settings = ZStack {
                Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93))
                StatusPopoverView(model: model)
            }
            .frame(width: Metrics.width, height: setupHeight)
            ok = write(settings, size: NSSize(width: Metrics.width, height: setupHeight), dark: dark, to: directory.appendingPathComponent("settings-\(name).png")) && ok
            model.editingAddress = false

            let faces = HStack(spacing: 14) {
                MiniFace(status: "working", size: 28, fill: BotAccent.nsColor(name: "Agent1", stored: "#3B82F6"))
                MiniFace(status: "lost", size: 28, fill: BotAccent.nsColor(name: "Agent2", stored: "#8B5CF6"))
                MiniFace(status: "lost", size: 20, fill: BotAccent.nsColor(name: "Agent2", stored: "#8B5CF6"))
                MiniFace(status: "idle", size: 20, fill: BotAccent.nsColor(name: "Agent5", stored: "#14B8A6"))
                MiniFace(status: "needs_input", size: 28, fill: BotAccent.nsColor(name: "Agent6", stored: "#A855F7"))
            }
            .padding(12)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            ok = write(faces, size: NSSize(width: 210, height: 52), dark: dark, to: directory.appendingPathComponent("faces-\(name).png")) && ok

            let states: [BarState] = [
                BarState(tone: .grey),
                BarState(tone: .orange),
                BarState(tone: .orange, staleDot: true, staleCount: 1),
                BarState(tone: .black, staleCount: 1),
                BarState(tone: .indigo, needsCount: 1),
                BarState(tone: .red),
            ]
            let bar = HStack(spacing: 14) {
                ForEach(0 ..< states.count, id: \.self) { index in
                    Image(nsImage: StatusIcon.image(
                        tone: states[index].tone,
                        pose: IconPose(),
                        staleDot: states[index].staleDot,
                        working: .palette
                    ))
                    .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 180, height: 24)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(red: 0.93, green: 0.93, blue: 0.95))
            ok = write(bar, size: NSSize(width: 180, height: 24), dark: dark, to: directory.appendingPathComponent("menubar-\(name).png")) && ok

            let colours = iconColourSheet(dark: dark)
            ok = write(colours, size: NSSize(width: 324, height: 380), dark: dark, to: directory.appendingPathComponent("icon-colours-\(name).png")) && ok

            let about = aboutSheet(dark: dark)
            ok = write(about, size: NSSize(width: 680, height: 540), dark: dark, to: directory.appendingPathComponent("about-\(name).png")) && ok
        }
        print(ok ? "Wrote previews to \(directory.path)" : "Some previews failed")
        return ok ? 0 : 1
    }

    private static func iconColourSheet(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        let presets: [(name: String, working: WorkingFill)] = IconSwatch.all.map { swatch in
            (name: swatch.name, working: .colour(swatch.nsColor))
        }
        let rows: [(name: String, working: WorkingFill)] = [(name: "Default", working: .palette)] + presets
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(" ")
                    .frame(width: 100, alignment: .leading)
                Text("Normal")
                    .frame(width: 48)
                Text("Stale")
                    .frame(width: 48)
                Text("Needs you")
                    .frame(width: 72)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .frame(height: 16)
            ForEach(0 ..< rows.count, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(rows[index].name)
                        .font(.system(size: 11))
                        .foregroundStyle(ink)
                        .frame(width: 100, alignment: .leading)
                    Image(nsImage: StatusIcon.image(
                        tone: .orange,
                        pose: IconPose(),
                        working: rows[index].working
                    ))
                    .frame(width: 48, height: 22)
                    Image(nsImage: StatusIcon.image(tone: .black, pose: IconPose(), working: rows[index].working))
                        .frame(width: 48, height: 22)
                    Image(nsImage: StatusIcon.image(
                        tone: .indigo,
                        pose: IconPose(),
                        working: rows[index].working
                    ))
                        .frame(width: 72, height: 22)
                }
            }
        }
        .padding(12)
        .frame(width: 324, height: 380, alignment: .topLeading)
        .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(red: 0.93, green: 0.93, blue: 0.95))
    }

    /// About, before a check, up to date, an available release, and the offline line. No network call.
    private static func aboutSheet(dark: Bool) -> some View {
        let ready = StatusModel()
        let current = StatusModel()
        current.updateNote = "You're up to date"
        let newer = StatusModel()
        newer.updateNote = "Version 1.6.0 is available"
        newer.updateAvailable = true
        newer.updatePage = URL(string: "https://github.com/pohstep/chief-status/releases/latest")
        let offline = StatusModel()
        offline.updateNote = "Couldn't check for updates. Try again when you're online."
        let ink = dark ? Color.white : Color.black
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                aboutColumn(model: ready, caption: "Before you check", ink: ink)
                aboutColumn(model: current, caption: "Up to date", ink: ink)
            }
            HStack(alignment: .top, spacing: 12) {
                aboutColumn(model: newer, caption: "Update available", ink: ink)
                aboutColumn(model: offline, caption: "Offline", ink: ink)
            }
        }
        .padding(12)
        .frame(width: 680, height: 540, alignment: .topLeading)
        .background(dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : Color(red: 0.93, green: 0.93, blue: 0.95))
    }

    private static func aboutColumn(model: StatusModel, caption: String, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
            AboutSection(model: model)
        }
        .padding(10)
        .frame(width: 318, height: 248, alignment: .topLeading)
    }

    private static func sampleModel() -> StatusModel {
        let model = StatusModel()
        let now = Date()
        func iso(_ minutesAgo: Double) -> String {
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: now.addingTimeInterval(-minutesAgo * 60))
        }
        model.feedURL = "https://example.com/status"
        model.lastUpdated = now
        model.now = now
        model.staleAfterMinutes = 60
        model.todayExpanded = true
        model.setSampleBots([
            Bot(bot: "Agent6", status: "needs_input", task: "Which logo do you want?", startedAt: iso(5), color: "#A855F7"),
            Bot(bot: "Agent1", status: "working", task: "Writing the release notes", startedAt: iso(4), color: "#3B82F6"),
            Bot(bot: "Agent2", status: "working", task: "Old task label", startedAt: iso(34), color: "#8B5CF6"),
            Bot(bot: "Agent3", status: "working", task: "Forgot to post done", startedAt: iso(65), color: "#EC4899"),
            Bot(bot: "Agent4", status: "done", task: "Fixed the login page", startedAt: iso(30), color: "#06B6D4"),
            Bot(bot: "Agent5", status: "idle", task: "", startedAt: iso(180), color: "#14B8A6"),
        ])
        model.today = sampleJobs(now: now)
        return model
    }

    private static func sampleJobs(now: Date) -> [FinishedJob] {
        let formatter = ISO8601DateFormatter()
        let ended = formatter.string(from: now.addingTimeInterval(-12 * 60))
        let started = formatter.string(from: now.addingTimeInterval(-30 * 60))
        let json = "[{\"bot\":\"Agent4\",\"task\":\"Fixed the login page\",\"started_at\":\"\(started)\",\"ended_at\":\"\(ended)\",\"duration_ms\":1080000,\"result\":\"done\"}]"
        return (try? JSONDecoder().decode([FinishedJob].self, from: Data(json.utf8))) ?? []
    }

    private static func write<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) -> Bool {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return false }
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
            hosting.appearance = appearance
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        guard let data = png else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
