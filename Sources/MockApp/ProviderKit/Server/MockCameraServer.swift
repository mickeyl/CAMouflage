import Foundation
import AppKit
import SimBridgeServer

private let kControlSocketPath = "/tmp/camouflage.sock"

/// The domain layer behind the CAMouflage control socket, serving mock camera
/// devices in both source modes. The control-plane transport — socket
/// lifecycle, NDJSON framing, hello handshake, last-connection-wins takeover,
/// client-socket hardening, and the socket-ownership guard — is SimBridgeKit's
/// `ProtocolServer`; the binary frame plane stays in `FrameServer`, untouched.
/// Every handler here runs on the transport's I/O queue, which also guards all
/// mutable state; UI-facing state is published on the main thread.
public final class MockCameraServer: ObservableObject {
    /// Socket lifecycle, connection status, and client identity are published
    /// by the transport; observe it directly.
    public let transport: ProtocolServer

    /// Frame-plane traffic pulse. Deliberately not the transport's control
    /// message pulse: "streaming" means frames are flowing, not JSON.
    @Published public private(set) var trafficActive: Bool = false
    /// A live thumbnail of the most recently served frame — what the simulator
    /// app currently sees. Nil while no client is streaming.
    @Published var previewImage: NSImage?
    @Published private(set) var activeSessionCount: Int = 0
    @Published private(set) var clientConfiguration: ClientMockConfiguration?
    @Published var fixture: FixtureSource = .restore() {
        didSet {
            guard fixture != oldValue else { return }
            fixture.persist()
            guard sourceMode == .mock else { return }
            frameServer.useFixture(fixture)
        }
    }

    /// Which kind of frame source the provider currently serves. Both modes use
    /// the same control/frame sockets and wire protocol; only the pixels differ.
    enum SourceMode {
        case mock
        case passthrough
    }

    private var sourceMode: SourceMode = .mock
    private var passthroughDeviceID: String?

    private let frameServer = FrameServer()
    private var trafficResetWorkItem: DispatchWorkItem?

    // Guarded by the transport's I/O queue
    private var sessions = Set<UInt32>()
    private var clientSuppliedConfiguration: ClientMockConfiguration?
    /// Bumped on every connect and teardown so async authorization completions
    /// can detect that "their" client is gone (the fd is not exposed anymore).
    private var connectionEpoch: UInt64 = 0

    private static let serverEnabledKey = "ServerEnabled"

    private static let devices: [[String: Any]] = [
        ["id": "cmf-back", "name": "CAMouflage Back Camera", "position": "back"],
        ["id": "cmf-front", "name": "CAMouflage Front Camera", "position": "front"],
    ]

    public init() {
        transport = ProtocolServer(
            socketPath: kControlSocketPath,
            name: "CAMouflage-Mock",
            appVersion: AppVersion.current
        )
        transport.onMessage = { [weak self] message in
            self?.handle(message)
        }
        transport.onClientConnected = { [weak self] _ in
            self?.handleClientConnected()
        }
        transport.onClientTeardown = { [weak self] _ in
            self?.handleClientTeardown()
        }
        frameServer.onTraffic = { [weak self] in
            self?.flashTraffic()
        }
        frameServer.onPreviewFrame = { [weak self] jpeg in
            let image = NSImage(data: jpeg)
            DispatchQueue.main.async {
                self?.previewImage = image
            }
        }
    }

    public var isRunning: Bool { transport.isRunning }

    // MARK: - Source mode

    /// Serve the currently selected fixture. Idempotently brings the sockets up.
    public func useMock(completion: (() -> Void)? = nil) {
        sourceMode = .mock
        start(completion: completion)
        frameServer.useFixture(fixture)
    }

    /// Forward a real Mac camera. `deviceID` may be nil until the user picks one
    /// (or grants camera access); frames start flowing once a device is set.
    public func usePassthrough(deviceID: String?, completion: (() -> Void)? = nil) {
        sourceMode = .passthrough
        passthroughDeviceID = deviceID
        start(completion: completion)
        frameServer.usePassthrough(deviceID: deviceID)
    }

    /// Live-switch the forwarded camera while passthrough is already active.
    public func selectPassthroughDevice(_ deviceID: String?) {
        passthroughDeviceID = deviceID
        guard sourceMode == .passthrough, isRunning else { return }
        frameServer.usePassthrough(deviceID: deviceID)
    }

    func start(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        frameServer.start()
        transport.start(completion: completion)
    }

    public func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        frameServer.stop()
        transport.stop(completion: completion)
    }

    // MARK: - Connection lifecycle (transport I/O queue)

    private func handleClientConnected() {
        connectionEpoch &+= 1
        sessions.removeAll()
        publishSessionCount(0)
        clearClientSuppliedConfiguration(logChange: false)
    }

    private func handleClientTeardown() {
        connectionEpoch &+= 1
        for sessionId in sessions {
            frameServer.revoke(sessionId: sessionId)
        }
        sessions.removeAll()
        publishSessionCount(0)
        frameServer.revokeAll()
        clearClientSuppliedConfiguration(logChange: true)
    }

    // MARK: - Protocol handling (transport I/O queue)

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
            case "listDevices":
                transport.send(["type": "didListDevices", "devices": currentWireDevices])

            case "setMockConfiguration":
                handleSetMockConfiguration(message)

            case "clearMockConfiguration":
                clearClientSuppliedConfiguration(logChange: true)
                sendMockConfigurationResult(ok: true, error: nil)
                transport.send(["type": "devicesChanged", "devices": currentWireDevices])

            case "startSession":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value,
                      let deviceID = message["deviceId"] as? String else { return }
                guard currentDeviceIDs.contains(deviceID) else {
                    transport.send(["type": "didStartSession", "sessionId": sessionId, "ok": false,
                                    "error": "unknown device '\(deviceID)'"])
                    return
                }
                let epoch = connectionEpoch
                frameServer.authorize(sessionId: sessionId, deviceID: deviceID) { [weak self] in
                    guard let self else { return }
                    self.transport.performOnIOQueue {
                        guard self.connectionEpoch == epoch else {
                            self.frameServer.revoke(sessionId: sessionId)
                            return
                        }
                        self.sessions.insert(sessionId)
                        self.publishSessionCount(self.sessions.count)
                        self.transport.send(["type": "didStartSession", "sessionId": sessionId, "ok": true])
                        self.log("Session \(sessionId) started (\(deviceID))")
                    }
                }

            case "stopSession":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value else { return }
                sessions.remove(sessionId)
                publishSessionCount(sessions.count)
                frameServer.revoke(sessionId: sessionId)
                transport.send(["type": "didStopSession", "sessionId": sessionId])
                log("Session \(sessionId) stopped")

            case "capturePhoto":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value,
                      let requestId = (message["requestId"] as? NSNumber)?.uint32Value else { return }
                frameServer.captureStill(sessionId: sessionId) { [weak self] frame in
                    guard let self else { return }
                    self.transport.performOnIOQueue {
                        if let frame {
                            self.transport.send(["type": "didCapturePhoto", "sessionId": sessionId, "requestId": requestId,
                                                 "ok": true, "width": frame.width, "height": frame.height,
                                                 "dataBase64": frame.jpeg.base64EncodedString()])
                            self.log("Photo \(requestId) captured (\(frame.width)×\(frame.height))")
                        } else {
                            self.transport.send(["type": "didCapturePhoto", "requestId": requestId, "ok": false,
                                                 "error": "no frame available for session \(sessionId)"])
                        }
                    }
                }

            default:
                log("Ignoring unknown message type \(type)")
        }
    }

    // MARK: - Client-supplied configuration (transport I/O queue)

    private var currentWireDevices: [[String: Any]] {
        clientSuppliedConfiguration?.wireDevices ?? Self.devices
    }

    private var currentDeviceIDs: Set<String> {
        Set(currentWireDevices.compactMap { $0["id"] as? String })
    }

    private func handleSetMockConfiguration(_ message: [String: Any]) {
        guard let rawConfiguration = message["configuration"] else {
            sendMockConfigurationResult(ok: false, error: "missing configuration")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: rawConfiguration)
            let configuration = try JSONDecoder().decode(ClientMockConfiguration.self, from: data)
            try configuration.validate()
            clientSuppliedConfiguration = configuration
            frameServer.useClientFixtures(Dictionary(uniqueKeysWithValues:
                configuration.devices.map { ($0.id, $0.source) }))
            publishClientConfiguration(configuration)
            sendMockConfigurationResult(ok: true, error: nil)
            transport.send(["type": "devicesChanged", "devices": currentWireDevices])
            log("Client supplied configuration '\(configuration.name)' with \(configuration.devices.count) device(s)")
        } catch {
            log("Rejected client configuration: \(error.localizedDescription)")
            sendMockConfigurationResult(ok: false, error: error.localizedDescription)
        }
    }

    private func clearClientSuppliedConfiguration(logChange: Bool) {
        guard clientSuppliedConfiguration != nil else { return }
        clientSuppliedConfiguration = nil
        frameServer.clearClientFixtures()
        publishClientConfiguration(nil)
        if logChange {
            log("Client configuration cleared; serving the menu-bar selection again")
        }
    }

    private func sendMockConfigurationResult(ok: Bool, error: String?) {
        var message: [String: Any] = ["type": "didSetMockConfiguration", "ok": ok]
        if let error { message["error"] = error }
        transport.send(message)
    }

    // MARK: - Publishing

    private func publishSessionCount(_ count: Int) {
        DispatchQueue.main.async {
            self.activeSessionCount = count
            if count == 0 {
                self.previewImage = nil
            }
        }
    }

    private func publishClientConfiguration(_ configuration: ClientMockConfiguration?) {
        DispatchQueue.main.async {
            self.clientConfiguration = configuration
        }
    }

    private func log(_ message: String) {
        NSLog("CAMouflage-Mock: %@", message)
        transport.note(message)
    }

    private func flashTraffic() {
        trafficActive = true
        trafficResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.trafficActive = false
        }
        trafficResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }
}
