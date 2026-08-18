import AppKit
import Combine
import SwiftUI
import SimBridgeServer
import SimBridgeShell

/// Owns the app's menu bar presence. The status item and control panel
/// machinery come from SimBridgeShell's `StatusItemPanelController`; this class
/// contributes the icon, the panel content, and the mode transitions.
@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private let server: MockCameraServer
    private let catalog: CameraCatalog
    let modeController: ModeTransitionController<ProviderMode>
    private var panel: StatusItemPanelController!
    private var cancellables: Set<AnyCancellable> = []
    private static let controlWindowContentSize = NSSize(width: 400, height: 700)

    /// The persisted mode keeps its historic defaults key so headless setups
    /// (`defaults write de.vanille.camouflage-mock ProviderMode …`) carry over.
    private static let modeDefaultsKey = "ProviderMode"

    init(server: MockCameraServer) {
        self.server = server
        let catalog = CameraCatalog()
        self.catalog = catalog
        // Creating the controller restores the persisted provider mode. Unlike
        // ImpossiBLE, mode switches deliberately do not bounce through a stop:
        // both sources are byte-identical on the wire, so the frame source
        // switches live under a running session.
        self.modeController = ModeTransitionController(
            initial: ProviderMode.persisted(key: Self.modeDefaultsKey),
            persist: { $0.persist(key: Self.modeDefaultsKey) }
        ) { mode, completion in
            switch mode {
                case .off:
                    server.stop(completion: completion)
                case .mock:
                    server.useMock(completion: completion)
                case .passthrough:
                    catalog.activate()
                    server.usePassthrough(deviceID: catalog.selectedDeviceID, completion: completion)
            }
        }
        super.init()
        panel = StatusItemPanelController(
            title: "CAMouflage",
            toolTip: "CAMouflage",
            contentSize: Self.controlWindowContentSize
        ) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MenuContent(
                server: self.server,
                transport: self.server.transport,
                catalog: self.catalog,
                controller: self.modeController,
                onDismiss: { [weak self] in self?.panel.hidePanel() }
            ))
        }
        observeIconState()
        updateIcon()
    }

    private func observeIconState() {
        // @Published emits in willSet; hop through the main queue so
        // updateIcon() runs after didSet.
        server.transport.$status.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.$trafficActive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        catalog.$selectedDeviceID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceID in
                guard let self, self.modeController.mode == .passthrough else { return }
                self.server.selectPassthroughDevice(deviceID)
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
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
        panel.setIcon(image)
    }
}
