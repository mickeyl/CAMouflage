import AppKit
import Combine
import SwiftUI

final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

final class MenuPanelContentView: NSView {
    private let hostingView: NSView
    private let cornerRadius: CGFloat

    override var isOpaque: Bool { false }

    init<Content: View>(rootView: Content, contentSize: NSSize, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        hostingView = TransparentHostingView(rootView: rootView)
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class StatusBarController: NSObject, ObservableObject, NSWindowDelegate {
    private let server: MockCameraServer
    private let catalog = CameraCatalog()
    private let statusItem: NSStatusItem
    private var controlWindow: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var statusButtonClickMonitor: Any?
    private static let controlWindowContentSize = NSSize(width: 400, height: 700)
    private static let controlWindowCornerRadius: CGFloat = 10

    /// The persisted provider mode; Passthrough is reserved for the helper.
    @Published var mode: ProviderMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "ProviderMode")
            applyMode()
        }
    }

    init(server: MockCameraServer) {
        self.server = server
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.mode = ProviderMode(rawValue: UserDefaults.standard.string(forKey: "ProviderMode") ?? "") ?? .off
        super.init()
        configureStatusItem()
        observeIconState()
        updateIcon()
        applyMode()
    }

    private func applyMode() {
        switch mode {
            case .off:
                server.stop()
            case .mock:
                server.useMock()
            case .passthrough:
                catalog.activate()
                server.usePassthrough(deviceID: catalog.selectedDeviceID)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggleControlWindow)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageOnly
        button.toolTip = "CAMouflage"
        statusButtonClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak button] event in
            guard let self, let button, event.window === button.window else { return event }
            guard !event.modifierFlags.contains(.command) else { return event }
            let location = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(location) else { return event }
            self.toggleControlWindow()
            return nil
        }
    }

    deinit {
        if let statusButtonClickMonitor {
            NSEvent.removeMonitor(statusButtonClickMonitor)
        }
    }

    private func observeIconState() {
        // @Published emits in willSet; hop through the main queue so
        // updateIcon() runs after didSet.
        server.transport.$status.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.$trafficActive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: AppPreferences.controlWindowBehaviorDidChange)
            .sink { [weak self] _ in self?.applyControlWindowBehavior() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.hideControlWindowAfterDeactivationIfNeeded() }
            .store(in: &cancellables)
        catalog.$selectedDeviceID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceID in
                guard let self, self.mode == .passthrough else { return }
                self.server.selectPassthroughDevice(deviceID)
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String =
            switch server.transport.status {
                case .stopped, .blocked:
                    "video.slash"
                case .listening, .clientConnected:
                    server.trafficActive ? "video.fill" : "video"
            }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "CAMouflage")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
    }

    @objc private func toggleControlWindow() {
        if controlWindow?.isVisible == true {
            hideControlWindow()
        } else {
            showControlWindow()
        }
    }

    private func showControlWindow() {
        let window = controlWindow ?? makeControlWindow()
        applyControlWindowBehavior()
        positionControlWindow(window)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeControlWindow() -> NSPanel {
        let root = MenuContent(
            server: server,
            transport: server.transport,
            catalog: catalog,
            controller: self,
            onDismiss: { [weak self] in self?.hideControlWindow() }
        )
        .frame(width: Self.controlWindowContentSize.width, height: Self.controlWindowContentSize.height)

        let contentRect = NSRect(origin: .zero, size: Self.controlWindowContentSize)
        let window = ControlPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = MenuPanelContentView(
            rootView: root,
            contentSize: Self.controlWindowContentSize,
            cornerRadius: Self.controlWindowCornerRadius
        )
        window.delegate = self
        window.title = "CAMouflage"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.invalidateShadow()
        controlWindow = window
        return window
    }

    private func applyControlWindowBehavior() {
        controlWindow?.hidesOnDeactivate = false
    }

    private func hideControlWindowAfterDeactivationIfNeeded() {
        guard AppPreferences.dismissControlWindowOnDeactivate else { return }
        hideControlWindow()
    }

    private func positionControlWindow(_ window: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            window.center()
            return
        }

        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        window.setContentSize(Self.controlWindowContentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.controlWindowContentSize)).size
        let centeredX = buttonFrame.midX - frameSize.width / 2
        let x = min(
            max(centeredX, visibleFrame.minX + 8),
            visibleFrame.maxX - frameSize.width - 8
        )
        let y = max(visibleFrame.minY + 8, buttonFrame.minY - frameSize.height - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideControlWindow() {
        controlWindow?.orderOut(nil)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard AppPreferences.dismissControlWindowOnDeactivate,
                  let window = notification.object as? NSWindow,
                  window === self.controlWindow
            else { return }
            self.hideControlWindow()
        }
    }
}
