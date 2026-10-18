import AppKit
import SwiftUI

enum Metrics {
    static let width: CGFloat = 328

    static func height(for model: StatusModel) -> CGFloat {
        var height: CGFloat = 12
        height += 22
        height += 8
        switch model.mode {
        case .setup:
            height += 140
        case .checking:
            height += 36
        case .message:
            height += 72
        case .list:
            height += CGFloat(max(model.bots.count, 1)) * 34
            if model.errorText != nil {
                height += 40
            }
        }
        height += 8
        height += 1
        height += 8
        height += 22
        height += 10
        // A little slack so the footer is not clipped if the divider is taller than 1pt.
        return height + 6
    }
}

struct StatusPopoverView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chief Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)

            Color.clear.frame(height: 8)

            switch model.mode {
            case .setup:
                setup.frame(height: 140, alignment: .top)
            case .checking:
                checking.frame(height: 36, alignment: .leading)
            case .message:
                message.frame(height: 72, alignment: .top)
            case .list:
                list
            }

            Color.clear.frame(height: 8)
            Divider()
            Color.clear.frame(height: 8)
            footer.frame(height: 22)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: Metrics.width, height: Metrics.height(for: model), alignment: .top)
        .background(popoverBackground)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.canCancelEdit ? "Paste a new feed address." : "Paste your feed address to begin.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
                .foregroundStyle(model.setupError == nil ? Color.clear : Color(nsColor: ChiefPalette.red))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28, alignment: .top)
            HStack(spacing: 8) {
                Button("Save") {
                    model.saveAddress()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if model.canCancelEdit {
                    Button("Cancel") {
                        model.cancelEditing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking the feed…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var message: some View {
        Text(model.errorText ?? "Couldn't reach the feed.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.bots.isEmpty {
                Text("No bots yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34)
            } else {
                ForEach(model.bots) { bot in
                    BotRow(bot: bot, now: model.now)
                        .frame(height: 34)
                }
            }
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40, alignment: .top)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(updatedLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.mode != .setup {
                Button("Settings") {
                    model.beginEditingAddress()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
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
            FrostedBackground()
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

struct BotRow: View {
    let bot: Bot
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(bot.bot)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(taskLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(elapsedText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
                .layoutPriority(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var dotColor: Color {
        switch bot.status {
        case "working":
            return Color(nsColor: ChiefPalette.orange)
        case "failed":
            return Color(nsColor: ChiefPalette.red)
        case "done":
            return Color(nsColor: ChiefPalette.done)
        default:
            return Color(nsColor: ChiefPalette.grey)
        }
    }

    private var taskLine: String {
        let trimmed = bot.task
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch bot.status {
        case "working":
            return "Working"
        case "failed":
            return "Failed"
        case "done":
            return "Done"
        default:
            return "Idle"
        }
    }

    private var elapsedText: String {
        guard bot.status == "working", let start = ISODate.date(from: bot.startedAt) else {
            return ""
        }
        return elapsed(since: start, now: now)
    }

    private var accessibilityText: String {
        if elapsedText.isEmpty {
            return "\(bot.bot), \(bot.status), \(taskLine)"
        }
        return "\(bot.bot), working, \(taskLine), for \(elapsedText)"
    }
}

private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
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
    if seconds < 60 {
        return "\(seconds)s"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = minutes / 60
    let extra = minutes % 60
    if hours < 48 {
        if extra == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(extra)m"
    }
    return "\(hours / 24)d"
}
