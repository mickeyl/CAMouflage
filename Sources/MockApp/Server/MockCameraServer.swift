import Foundation
import AppKit

private let kControlSocketPath = "/tmp/camouflage.sock"

struct SocketClientInfo: Equatable {
    let pid: Int
    let bundleId: String

    var displayText: String {
        "\(bundleId) (PID \(pid))"
    }
}

/// Control-plane socket server implementing the CAMouflage provider protocol
/// with mock devices. All socket I/O runs on `ioQueue`; UI-facing state is
/// published on the main thread.
final class MockCameraServer: ObservableObject {
    enum Status: Equatable {
        case stopped
        case listening
        case clientConnected
    }

    @Published var status: Status = .stopped
    @Published var lastActivity: String = ""
    @Published var trafficActive: Bool = false
    /// A live thumbnail of the most recently served frame — what the simulator
    /// app currently sees. Nil while no client is streaming.
    @Published var previewImage: NSImage?
    @Published private(set) var connectedClient: SocketClientInfo?
    @Published private(set) var activeSessionCount: Int = 0
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

    private let ioQueue = DispatchQueue(label: "camouflage.mock.io")
    private let frameServer = FrameServer()
    private var trafficResetWorkItem: DispatchWorkItem?

    // Guarded by ioQueue
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var clientInfo: SocketClientInfo?
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var sessions = Set<UInt32>()

    private static let serverEnabledKey = "ServerEnabled"

    private static let devices: [[String: Any]] = [
        ["id": "cmf-back", "name": "CAMouflage Back Camera", "position": "back"],
        ["id": "cmf-front", "name": "CAMouflage Front Camera", "position": "front"],
    ]

    init() {
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

    var isRunning: Bool { status != .stopped }

    // MARK: - Source mode

    /// Serve the currently selected fixture. Idempotently brings the sockets up.
    func useMock() {
        sourceMode = .mock
        start()
        frameServer.useFixture(fixture)
    }

    /// Forward a real Mac camera. `deviceID` may be nil until the user picks one
    /// (or grants camera access); frames start flowing once a device is set.
    func usePassthrough(deviceID: String?) {
        sourceMode = .passthrough
        passthroughDeviceID = deviceID
        start()
        frameServer.usePassthrough(deviceID: deviceID)
    }

    /// Live-switch the forwarded camera while passthrough is already active.
    func selectPassthroughDevice(_ deviceID: String?) {
        passthroughDeviceID = deviceID
        guard sourceMode == .passthrough, isRunning else { return }
        frameServer.usePassthrough(deviceID: deviceID)
    }

    func start(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        frameServer.start()
        ioQueue.async { [self] in
            defer {
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
            guard serverFd < 0 else { return }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("CAMouflage-Mock: socket() failed")
                return
            }
            unlink(kControlSocketPath)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = kControlSocketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                pathBytes.withUnsafeBufferPointer { buf in
                    raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
                }
            }
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                NSLog("CAMouflage-Mock: bind() failed: %d", errno)
                close(fd)
                return
            }
            guard listen(fd, 2) == 0 else {
                NSLog("CAMouflage-Mock: listen() failed")
                close(fd)
                return
            }

            serverFd = fd
            publishStatus(.listening)
            log("Listening")

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.acceptClient()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            acceptSource = source
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        frameServer.stop()
        ioQueue.async { [self] in
            let hadServer = serverFd >= 0

            readSource?.cancel()
            readSource = nil
            if clientFd >= 0 {
                close(clientFd)
                clientFd = -1
            }
            clientInfo = nil
            publishConnectedClient(nil)

            acceptSource?.cancel()
            acceptSource = nil
            serverFd = -1
            if hadServer {
                unlink(kControlSocketPath)
            }

            sessions.removeAll()
            publishSessionCount(0)
            readBuffer.removeAll()
            publishStatus(.stopped)
            log("Stopped")

            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // MARK: - Connection (ioQueue)

    private func acceptClient() {
        let fd = accept(serverFd, nil, nil)
        guard fd >= 0 else { return }

        if clientFd >= 0 {
            // Takeover: a freshly launched app (or another simulator) supersedes
            // the previous connection instead of being rejected. Tell the old
            // client to stand down — so its library stops auto-reconnecting and
            // does not fight for the slot — then evict it and accept the new one.
            send(["type": "connectionRejected", "code": "clientBusy",
                  "message": "superseded by a newer simulator connection"], to: clientFd)
            log("Superseding previous client")
            disconnectClient()
        }
        clientFd = fd
        readBuffer.removeAll()
        sessions.removeAll()
        publishSessionCount(0)
        publishStatus(.clientConnected)
        log("Client connected")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: fd)
        }
        source.resume()
        readSource = source
    }

    private func disconnectClient() {
        readSource?.cancel()
        readSource = nil
        if clientFd >= 0 {
            close(clientFd)
            clientFd = -1
        }
        clientInfo = nil
        publishConnectedClient(nil)
        for sessionId in sessions {
            frameServer.revoke(sessionId: sessionId)
        }
        sessions.removeAll()
        publishSessionCount(0)
        frameServer.revokeAll()
        publishStatus(serverFd >= 0 ? .listening : .stopped)
        log("Client disconnected")
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            disconnectClient()
            return
        }
        readBuffer.append(contentsOf: buffer[0..<n])

        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newlineIndex)
            readBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }
            handle(type: type, message: json)
        }
    }

    private func handle(type: String, message: [String: Any]) {
        switch type {
            case "hello":
                let info = SocketClientInfo(
                    pid: (message["pid"] as? NSNumber)?.intValue ?? 0,
                    bundleId: message["bundleId"] as? String ?? "unknown"
                )
                clientInfo = info
                publishConnectedClient(info)
                log("Hello from \(info.displayText)")

            case "listDevices":
                send(["type": "didListDevices", "devices": Self.devices], to: clientFd)

            case "startSession":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value else { return }
                let deviceId = message["deviceId"] as? String ?? "?"
                sessions.insert(sessionId)
                publishSessionCount(sessions.count)
                frameServer.authorize(sessionId: sessionId)
                send(["type": "didStartSession", "sessionId": sessionId, "ok": true], to: clientFd)
                log("Session \(sessionId) started (\(deviceId))")

            case "stopSession":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value else { return }
                sessions.remove(sessionId)
                publishSessionCount(sessions.count)
                frameServer.revoke(sessionId: sessionId)
                send(["type": "didStopSession", "sessionId": sessionId], to: clientFd)
                log("Session \(sessionId) stopped")

            case "capturePhoto":
                guard let sessionId = (message["sessionId"] as? NSNumber)?.uint32Value,
                      let requestId = (message["requestId"] as? NSNumber)?.uint32Value else { return }
                frameServer.captureStill(sessionId: sessionId) { [weak self] frame in
                    guard let self else { return }
                    self.ioQueue.async {
                        if let frame {
                            self.send(["type": "didCapturePhoto", "sessionId": sessionId, "requestId": requestId,
                                       "ok": true, "width": frame.width, "height": frame.height,
                                       "dataBase64": frame.jpeg.base64EncodedString()], to: self.clientFd)
                            self.log("Photo \(requestId) captured (\(frame.width)×\(frame.height))")
                        } else {
                            self.send(["type": "didCapturePhoto", "requestId": requestId, "ok": false,
                                       "error": "no frame available for session \(sessionId)"], to: self.clientFd)
                        }
                    }
                }

            default:
                log("Ignoring unknown message type \(type)")
        }
    }

    private func send(_ message: [String: Any], to fd: Int32) {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    // MARK: - Publishing

    private func publishStatus(_ status: Status) {
        DispatchQueue.main.async {
            self.status = status
        }
    }

    private func publishConnectedClient(_ info: SocketClientInfo?) {
        DispatchQueue.main.async {
            self.connectedClient = info
        }
    }

    private func publishSessionCount(_ count: Int) {
        DispatchQueue.main.async {
            self.activeSessionCount = count
            if count == 0 {
                self.previewImage = nil
            }
        }
    }

    private func log(_ message: String) {
        NSLog("CAMouflage-Mock: %@", message)
        DispatchQueue.main.async {
            self.lastActivity = message
        }
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
