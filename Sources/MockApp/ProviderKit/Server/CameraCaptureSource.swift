import AVFoundation
import CoreImage
import CoreVideo

/// Captures frames from a real Mac camera and keeps the most recent one as a
/// JPEG, ready for `FrameServer` to forward to the simulator. A single instance
/// is shared across all passthrough streams so one `AVCaptureSession` backs
/// every virtual camera — Continuity Camera in particular refuses concurrent
/// sessions on the same physical device.
final class CameraCaptureSource: NSObject {
    let fps = 30

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camouflage.passthrough.session")
    private let frameQueue = DispatchQueue(label: "camouflage.passthrough.frames")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let frameLock = NSLock()
    private var latest: ProducedFrame?

    // Guarded by sessionQueue
    private var currentDeviceID: String?
    private var wantRunning = false

    override init() {
        super.init()
        session.sessionPreset = .high
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    /// Selects which Mac camera feeds the passthrough stream. A `nil` or unknown
    /// id leaves the session without an input, so no frames are produced.
    func select(deviceID: String?) {
        sessionQueue.async { [self] in
            guard deviceID != currentDeviceID else { return }
            currentDeviceID = deviceID
            reconfigureInput()
        }
    }

    func start() {
        sessionQueue.async { [self] in
            wantRunning = true
            updateRunning()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantRunning = false
            updateRunning()
        }
    }

    func latestFrame() -> ProducedFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latest
    }

    // MARK: - sessionQueue

    private func reconfigureInput() {
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        if let id = currentDeviceID,
           let device = AVCaptureDevice(uniqueID: id),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }
        session.commitConfiguration()
        updateRunning()
    }

    private func updateRunning() {
        let shouldRun = wantRunning && !session.inputs.isEmpty
        if shouldRun, !session.isRunning {
            session.startRunning()
        } else if !shouldRun, session.isRunning {
            session.stopRunning()
        }
        if !shouldRun {
            frameLock.lock()
            latest = nil
            frameLock.unlock()
        }
    }
}

extension CameraCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else {
            return
        }
        let frame = ProducedFrame(jpeg: jpeg,
                                  width: UInt16(CVPixelBufferGetWidth(pixelBuffer)),
                                  height: UInt16(CVPixelBufferGetHeight(pixelBuffer)))
        frameLock.lock()
        latest = frame
        frameLock.unlock()
    }
}

/// Bridges the shared `CameraCaptureSource` into the pull-based `FrameProducer`
/// contract: each passthrough stream owns one of these, but they all read the
/// same underlying camera.
final class PassthroughFrameProducer: FrameProducer {
    private let source: CameraCaptureSource

    init(source: CameraCaptureSource) {
        self.source = source
    }

    var fps: Int { source.fps }

    func nextFrame() -> ProducedFrame? {
        source.latestFrame()
    }
}
