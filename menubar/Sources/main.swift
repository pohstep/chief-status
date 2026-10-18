import AppKit
import Darwin
import SwiftUI

private let appDelegate = AppDelegate()

let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = StatusModel()
    private let animator = FaceAnimator()
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !takeSingleInstanceLock() {
            NSApp.terminate(nil)
            return
        }

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
        model.start()
        updateChrome()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.setPanelOpen(true)
        updateChrome()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanelOpen(false)
        statusItem.button?.highlight(false)
    }

    private func updateChrome() {
        let tone = BarTone.from(bots: model.bots)
        animator.setTone(tone)
        statusItem.button?.toolTip = tone.toolTip
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
