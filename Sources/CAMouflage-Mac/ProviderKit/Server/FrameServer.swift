import Foundation

private let kFrameSocketPath = "/tmp/camouflage-frames.sock"

private func suppressFrameSIGPIPE(on fd: Int32) {
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
}

/// Serves length-prefixed JPEG frames to simulator clients. One connection per
/// capture session: the client sends a one-line JSON hello naming its session,
/// then frames flow until either side closes. All state lives on `ioQueue`.
final class FrameServer {
    private let ioQueue = DispatchQueue(label: "camouflage.frames.io")

    // Guarded by ioQueue
    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var authorizedSessions = Set<UInt32>()
    private var sessionDeviceIDs: [UInt32: String] = [:]
    private var streams: [UInt32: Stream] = [:]
    private var baseSource: BaseSource = .fixture(.restore())
    private var clientFixturesByDeviceID: [String: FixtureSource]?

    private enum BaseSource {
        case fixture(FixtureSource)
        case passthrough(deviceID: String?)
    }

    /// Non-nil while passthrough is the active source: all streams read frames
    /// from this shared real-camera capture instead of a fixture. The camera
    /// only runs while at least one stream is live.
    private var cameraSource: CameraCaptureSource?

    /// Called on the main queue whenever frames were pushed recently.
    var onTraffic: (() -> Void)?

    /// Called on `ioQueue`, throttled to ~7 Hz, with the JPEG of a just-served
    /// frame — the panel decodes it into a live preview of what the client sees.
    var onPreviewFrame: ((Data) -> Void)?
    private var lastPreviewMicros: UInt64 = 0
    private static let previewIntervalMicros: UInt64 = 140_000

    private final class Stream {
        let sessionId: UInt32
        let fd: Int32
        var producer: FrameProducer
        var timer: DispatchSourceTimer?

        init(sessionId: UInt32, fd: Int32, producer: FrameProducer) {
            self.sessionId = sessionId
            self.fd = fd
            self.producer = producer
        }
    }

    func start() {
        ioQueue.async { [self] in
            guard serverFd < 0 else { return }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("CAMouflage-Mac: frame socket() failed")
                return
            }
            suppressFrameSIGPIPE(on: fd)
            unlink(kFrameSocketPath)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = kFrameSocketPath.utf8CString
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
            guard bindResult == 0, listen(fd, 4) == 0 else {
                NSLog("CAMouflage-Mac: frame socket bind/listen failed: %d", errno)
                close(fd)
                return
            }

            serverFd = fd
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

    func stop() {
        ioQueue.async { [self] in
            for stream in streams.values {
                stream.timer?.cancel()
                close(stream.fd)
            }
            streams.removeAll()
            authorizedSessions.removeAll()
            sessionDeviceIDs.removeAll()
            clientFixturesByDeviceID = nil
            cameraSource?.stop()
            cameraSource = nil

            acceptSource?.cancel()
            acceptSource = nil
            if serverFd >= 0 {
                unlink(kFrameSocketPath)
            }
            serverFd = -1
        }
    }

    func authorize(sessionId: UInt32, deviceID: String, completion: (() -> Void)? = nil) {
        ioQueue.async { [self] in
            authorizedSessions.insert(sessionId)
            sessionDeviceIDs[sessionId] = deviceID
            completion?()
        }
    }

    func revoke(sessionId: UInt32) {
        ioQueue.async { [self] in
            authorizedSessions.remove(sessionId)
            sessionDeviceIDs.removeValue(forKey: sessionId)
            if let stream = streams.removeValue(forKey: sessionId) {
                stream.timer?.cancel()
                close(stream.fd)
            }
            updateCameraRunState()
        }
    }

    func revokeAll() {
        ioQueue.async { [self] in
            for sessionId in Array(streams.keys) {
                if let stream = streams.removeValue(forKey: sessionId) {
                    stream.timer?.cancel()
                    close(stream.fd)
                }
            }
            authorizedSessions.removeAll()
            sessionDeviceIDs.removeAll()
            updateCameraRunState()
        }
    }

    /// Grabs a single still for a photo-capture request: the current frame from
    /// that session's producer (the fixture frame, or the latest camera frame in
    /// passthrough). Completion runs on `ioQueue`.
    func captureStill(sessionId: UInt32, completion: @escaping (ProducedFrame?) -> Void) {
        ioQueue.async { [self] in
            completion(streams[sessionId]?.producer.nextFrame())
        }
    }

    /// Serve a fixture (mock mode). Live-switches every running stream and
    /// releases any real camera held for passthrough.
    func useFixture(_ fixture: FixtureSource) {
        ioQueue.async { [self] in
            baseSource = .fixture(fixture)
            configureBaseSource()
            rebuildProducers()
        }
    }

    /// Serve frames from a real Mac camera (passthrough mode). Live-switches the
    /// forwarded device and starts/stops the camera to match stream demand.
    func usePassthrough(deviceID: String?) {
        ioQueue.async { [self] in
            baseSource = .passthrough(deviceID: deviceID)
            configureBaseSource()
            rebuildProducers()
        }
    }

    /// Temporarily replaces the menu-bar source with per-device fixtures. The
    /// override is connection-scoped and is never persisted.
    func useClientFixtures(_ fixtures: [String: FixtureSource]) {
        ioQueue.async { [self] in
            clientFixturesByDeviceID = fixtures
            configureBaseSource()
            rebuildProducers()
        }
    }

    func clearClientFixtures() {
        ioQueue.async { [self] in
            guard clientFixturesByDeviceID != nil else { return }
            clientFixturesByDeviceID = nil
            configureBaseSource()
            rebuildProducers()
        }
    }

    // MARK: - Source plumbing (ioQueue)

    private func makeProducer(for sessionId: UInt32) -> FrameProducer {
        if let clientFixturesByDeviceID {
            if let deviceID = sessionDeviceIDs[sessionId],
               let fixture = clientFixturesByDeviceID[deviceID] {
                return makeFrameProducer(for: fixture)
            }
            return TestPatternProducer()
        }
        if let cameraSource {
            return PassthroughFrameProducer(source: cameraSource)
        }
        if case let .fixture(fixture) = baseSource {
            return makeFrameProducer(for: fixture)
        }
        return TestPatternProducer()
    }

    private func rebuildProducers() {
        for stream in streams.values {
            stream.producer = makeProducer(for: stream.sessionId)
            startTimer(for: stream)
        }
    }

    private func configureBaseSource() {
        cameraSource?.stop()
        cameraSource = nil
        guard clientFixturesByDeviceID == nil else { return }
        guard case let .passthrough(deviceID) = baseSource else { return }
        let source = CameraCaptureSource()
        cameraSource = source
        source.select(deviceID: deviceID)
        updateCameraRunState()
    }

    /// The real camera should only run — and light its LED — while a simulator
    /// client is actually streaming frames.
    private func updateCameraRunState() {
        guard let cameraSource else { return }
        if streams.isEmpty {
            cameraSource.stop()
        } else {
            cameraSource.start()
        }
    }

    // MARK: - Connection handling (ioQueue)

    private func acceptClient() {
        let fd = accept(serverFd, nil, nil)
        guard fd >= 0 else { return }
        suppressFrameSIGPIPE(on: fd)

        // The hello line is tiny and arrives immediately; a bounded blocking
        // read keeps the handshake simple.
        var hello = Data()
        while hello.count < 512, !hello.contains(0x0A) {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            guard n == 1 else {
                close(fd)
                return
            }
            hello.append(byte)
        }
        guard let newlineIndex = hello.firstIndex(of: 0x0A),
              let json = try? JSONSerialization.jsonObject(with: hello.prefix(upTo: newlineIndex)) as? [String: Any],
              let sessionId = (json["sessionId"] as? NSNumber)?.uint32Value
        else {
            NSLog("CAMouflage-Mac: malformed frame stream hello")
            close(fd)
            return
        }
        guard authorizedSessions.contains(sessionId) else {
            NSLog("CAMouflage-Mac: rejecting frame stream for unknown session %u", sessionId)
            close(fd)
            return
        }
        if let existing = streams.removeValue(forKey: sessionId) {
            existing.timer?.cancel()
            close(existing.fd)
        }

        let stream = Stream(sessionId: sessionId, fd: fd, producer: makeProducer(for: sessionId))
        streams[sessionId] = stream
        updateCameraRunState()
        startTimer(for: stream)
        NSLog("CAMouflage-Mac: frame stream started for session %u", sessionId)
    }

    private func startTimer(for stream: Stream) {
        stream.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        let interval = 1.0 / Double(stream.producer.fps)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.pushFrame(to: stream)
        }
        timer.resume()
        stream.timer = timer
    }

    private func pushFrame(to stream: Stream) {
        guard let frame = stream.producer.nextFrame() else { return }
        let ptsMicros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        var packet = Data(capacity: 32 + frame.jpeg.count)
        packet.append(contentsOf: [0x43, 0x4D, 0x46, 0x31]) // 'C' 'M' 'F' '1'
        packet.appendLE(UInt32(frame.jpeg.count))
        packet.appendLE(stream.sessionId)
        packet.appendLE(frame.width)
        packet.appendLE(frame.height)
        packet.append(contentsOf: [0x6A, 0x70, 0x65, 0x67]) // 'j' 'p' 'e' 'g'
        packet.appendLE(UInt16(0)) // rotation
        packet.append(contentsOf: [0, 0]) // mirrored + reserved
        packet.appendLE(ptsMicros)
        packet.append(frame.jpeg)

        let ok = packet.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(stream.fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        if ok {
            if let onPreviewFrame, ptsMicros &- lastPreviewMicros >= Self.previewIntervalMicros {
                lastPreviewMicros = ptsMicros
                onPreviewFrame(frame.jpeg)
            }
            DispatchQueue.main.async { [onTraffic] in
                onTraffic?()
            }
        } else {
            NSLog("CAMouflage-Mac: frame stream write failed for session %u, closing", stream.sessionId)
            stream.timer?.cancel()
            close(stream.fd)
            streams.removeValue(forKey: stream.sessionId)
            updateCameraRunState()
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        let little = value.littleEndian
        Swift.withUnsafeBytes(of: little) { append(contentsOf: $0) }
    }
}
