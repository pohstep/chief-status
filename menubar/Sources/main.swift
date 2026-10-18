import AppKit
import CoreServices
import Darwin
import SwiftUI

private let appDelegate = AppDelegate()

let application = NSApplication.shared

// `ChiefStatus --render-preview <folder>` draws sample panels and faces to PNG files, then quits.
// Used for the README images and for checking the look without touching the live feed.
if let flag = CommandLine.arguments.firstIndex(of: "--render-preview") {
    let folder = flag + 1 < CommandLine.arguments.count ? CommandLine.arguments[flag + 1] : FileManager.default.currentDirectoryPath
    application.setActivationPolicy(.prohibited)
    exit(PreviewRenderer.run(folder: folder))
}

application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = StatusModel()
    private let animator = FaceAnimator()
    private var lockFD: Int32 = -1
    private var barState: BarState?
    private var pendingReveal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !takeSingleInstanceLock() {
            NSApp.terminate(nil)
            return
        }

        AppearanceChoice.stored().apply()

        let controller = PopoverController(model: model)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: Metrics.width, height: Metrics.height(for: model))
        popover.contentViewController = controller
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("Chief Status")
        }

        animator.onImage = { [weak self] image in
            guard let button = self?.statusItem.button else { return }
            image.isTemplate = false
            button.image = image
        }

        model.onChange = { [weak self] in
            self?.updateChrome()
        }
        model.onTick = { [weak self] in
            self?.updateBarIfChanged()
        }
        model.start()
        updateChrome()

        // Normal runs do not listen. A scripted test passes --test (or --render-preview) so it can
        // open the panel with a distributed notification named com.chiefstatus.togglePanel.
        if AppDelegate.allowsPanelToggleListener {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(togglePanelFromNotification(_:)),
                name: NSNotification.Name("com.chiefstatus.togglePanel"),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        if pendingReveal {
            revealPanel()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.applySetupURL(url)
        }
        revealPanel()
    }

    /// chiefstatus://setup links. The URL is not logged: it can carry the post password and the read token.
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        guard let url = URL(string: text) else { return }
        model.applySetupURL(url)
        revealPanel()
    }

    /// --test and --render-preview only. A normal launch does not observe this name.
    private static var allowsPanelToggleListener: Bool {
        let args = CommandLine.arguments
        if args.contains("--test") { return true }
        if args.contains("--render-preview") { return true }
        return false
    }

    private func revealPanel() {
        guard let popover = popover, statusItem != nil else {
            pendingReveal = true
            return
        }
        pendingReveal = false
        if popover.isShown { return }
        togglePanel(activate: false)
    }

    @objc private func togglePanelFromNotification(_ notification: Notification) {
        togglePanel(activate: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    /// The status-item click. That is the only path that may activate the app.
    @objc private func togglePopover(_ sender: Any?) {
        togglePanel(activate: true)
    }

    private func togglePanel(activate: Bool) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.setPanelOpen(true)
        updateChrome()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    func popoverDidClose(_ notification: Notification) {
        model.commitReadToken()
        model.setPanelOpen(false)
        statusItem.button?.highlight(false)
    }

    private func currentBarState() -> BarState {
        BarState.from(
            bots: model.bots,
            now: Date(),
            staleAfterMinutes: model.staleAfterMinutes,
            quietAfterMinutes: model.quietAfterMinutes
        )
    }

    private func applyBar(_ state: BarState) {
        barState = state
        animator.setState(state)
        statusItem.button?.toolTip = state.toolTip
        statusItem.button?.setAccessibilityLabel(state.toolTip)
    }

    /// A bot can go stale with no new post, so the 1 s clock re-checks the cube.
    private func updateBarIfChanged() {
        let state = currentBarState()
        if state != barState {
            applyBar(state)
        }
    }

    private func updateChrome() {
        applyBar(currentBarState())
        let wanted = model.appearance.nsAppearance
        if popover.appearance?.name != wanted?.name {
            popover.appearance = wanted
        }
        let size = NSSize(width: Metrics.width, height: Metrics.height(for: model))
        if popover.contentSize != size {
            popover.contentSize = size
        }
    }

    private func takeSingleInstanceLock() -> Bool {
        let directory = ConfigStore.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("instance.lock")
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        if fd < 0 {
            return true
        }
        // macOS 13: Darwin.flock is ambiguous with struct flock. lockf is the one that compiles.
        if Darwin.lockf(fd, F_TLOCK, 0) != 0 {
            Darwin.close(fd)
            return false
        }
        lockFD = fd
        return true
    }
}

final class PopoverController: NSViewController {
    private let hosting: NSHostingController<StatusPopoverView>

    init(model: StatusModel) {
        hosting = NSHostingController(rootView: StatusPopoverView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active

        let hosted = hosting.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.wantsLayer = true
        hosted.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: effect.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        view = effect
    }
}
