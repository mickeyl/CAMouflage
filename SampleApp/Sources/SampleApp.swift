import SwiftUI
import UIKit
import AVFoundation
import CAMouflage

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraController()

    /// Committed position of the status overlay, relative to its bottom-center
    /// anchor. The live drag translation is added on top while a drag is active.
    @State private var overlayOffset = CGSize.zero
    @GestureState private var dragTranslation = CGSize.zero
    @State private var overlaySize = CGSize.zero
    @State private var isDragging = false
    @State private var spin = false
    @State private var flashOpacity = 0.0

    private static let overlayBottomInset: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ZStack(alignment: .bottom) {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()

                    if camera.isReceivingFrames {
                        statusOverlay
                            .onSizeChange { overlaySize = $0 }
                            .offset(x: overlayOffset.width + dragTranslation.width,
                                    y: overlayOffset.height + dragTranslation.height)
                            .scaleEffect(isDragging ? 1.04 : 1)
                            // Preserve the shutter's tap gesture while the card tracks drags.
                            .simultaneousGesture(dragGesture(in: proxy.size))
                            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.72), value: isDragging)
                            .padding(.bottom, Self.overlayBottomInset)
                    }
                }

                if !camera.isReceivingFrames {
                    noSignalPlaceholder
                }

                if let code = camera.detectedCode {
                    VStack {
                        scanBanner(code)
                            .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Color.white
                    .ignoresSafeArea()
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)

                if let image = camera.capturedImage {
                    photoReview(image)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeInOut(duration: 0.2), value: camera.capturedImage)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: camera.detectedCode)
        }
        .onAppear {
            camera.start()
        }
    }

    // Shown until the first frame arrives. The spinner animates continuously,
    // which keeps the simulator compositing (a static screen there can otherwise
    // get stuck on a stale/blank frame) and tells the user what to check.
    private var noSignalPlaceholder: some View {
        VStack(spacing: 18) {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }
            Text(camera.statusText)
                .font(.headline)
                .foregroundStyle(.white)
            Text("Make sure the CAMouflage Mac app is running (Mock or Passthrough).")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func scanBanner(_ code: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
            Text(code)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.green.opacity(0.9), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 4)
    }

    private var shutterButton: some View {
        Button {
            triggerCapture()
        } label: {
            ZStack {
                Circle().stroke(.primary, lineWidth: 3).frame(width: 50, height: 50)
                Circle().fill(.primary).frame(width: 38, height: 38)
            }
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(camera.capturedImage != nil)
        .accessibilityLabel("Capture photo")
    }

    private func triggerCapture() {
        camera.capturePhoto()
        // Instant shutter flash for feedback, then fade out on the next tick so
        // the peak actually renders (a single coalesced update would skip it).
        flashOpacity = 0.85
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.35)) {
                flashOpacity = 0
            }
        }
    }

    private func photoReview(_ image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button {
                        camera.capturedImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding()
                    }
                }
                Spacer()
                Text("Captured photo · \(Int(image.size.width))×\(Int(image.size.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, 44)
            }
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.secondary)
                .frame(width: 32, height: 4)
                .opacity(0.6)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.statusText)
                        .font(.callout.monospacedDigit())
                    Text(camera.frameText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                shutterButton
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: isDragging ? 12 : 0, y: isDragging ? 6 : 0)
        .contentShape(Rectangle())
    }

    private struct ShutterButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .shadow(radius: 2)
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }

    private func dragGesture(in container: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { _ in
                if !isDragging { isDragging = true }
            }
            .onEnded { value in
                let proposed = CGSize(width: overlayOffset.width + value.translation.width,
                                      height: overlayOffset.height + value.translation.height)
                overlayOffset = clampedOffset(proposed, in: container)
                isDragging = false
            }
    }

    /// Keeps the overlay fully on screen (with a small margin) no matter how far
    /// it is flung, so it can never be dragged out of reach. When the card is
    /// wider or taller than the available space on an axis (it spans almost the
    /// full width), that axis is simply centered rather than clamped.
    private func clampedOffset(_ proposed: CGSize, in container: CGSize) -> CGSize {
        guard overlaySize != .zero, container.width > 0, container.height > 0 else { return proposed }
        let margin: CGFloat = 8
        let halfWidth = overlaySize.width / 2
        let halfHeight = overlaySize.height / 2
        let naturalCenterX = container.width / 2
        let naturalCenterY = container.height - Self.overlayBottomInset - halfHeight

        let centerX = clamp(naturalCenterX + proposed.width,
                            low: halfWidth + margin, high: container.width - halfWidth - margin)
        let centerY = clamp(naturalCenterY + proposed.height,
                            low: halfHeight + margin, high: container.height - halfHeight - margin)

        return CGSize(width: centerX - naturalCenterX, height: centerY - naturalCenterY)
    }

    /// Clamps `value` into `[low, high]`, tolerating an inverted range (no room
    /// to fit) by returning the midpoint so the card stays centered.
    private func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard low <= high else { return (low + high) / 2 }
        return min(max(value, low), high)
    }
}

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension View {
    func onSizeChange(_ action: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: action)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        // A black backdrop so the "no signal" state reads as a camera without a
        // feed (status overlay legible on top) instead of a blank white/black void.
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

@MainActor
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()

    @Published var statusText = "Starting…"
    @Published var frameText = "no frames yet"
    @Published var capturedImage: UIImage?
    @Published var detectedCode: String?
    @Published var isReceivingFrames = false

    private let sessionQueue = DispatchQueue(label: "sample.session")
    private let videoQueue = DispatchQueue(label: "sample.video")
    private var frameCount = 0
    private var lastSize = CGSize.zero
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        enqueueConfigurationAttempt()
    }

    private func enqueueConfigurationAttempt() {
        sessionQueue.async { [weak self] in
            self?.configure()
        }
    }

    func capturePhoto() {
        sessionQueue.async { [self] in
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    nonisolated private func configure() {
        guard CAMouflageIsProviderConnected() else {
            Task { @MainActor in
                self.statusText = "No camera — is the CAMouflage Mac app running?"
            }
            scheduleConfigurationRetry()
            return
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else {
            Task { @MainActor in
                self.statusText = "Provider connected, but no camera found"
            }
            scheduleConfigurationRetry()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
            }
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: videoQueue)
                metadataOutput.metadataObjectTypes = [.qr, .aztec, .pdf417, .dataMatrix, .ean13, .code128]
            }
            session.commitConfiguration()
            session.startRunning()

            let name = device.localizedName
            Task { @MainActor in
                self.statusText = name
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.statusText = "Input failed: \(message)"
            }
            scheduleConfigurationRetry()
        }
    }

    nonisolated private func scheduleConfigurationRetry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.enqueueConfigurationAttempt()
        }
    }
}

extension CameraController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = metadataObjects
            .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
            .first
        else { return }
        Task { @MainActor in
            self.detectedCode = code
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }
        Task { @MainActor in
            self.capturedImage = image
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        var size = CGSize.zero
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        Task { @MainActor in
            self.frameCount += 1
            self.lastSize = size
            self.isReceivingFrames = true
            self.frameText = "\(self.frameCount) frames · \(Int(size.width))×\(Int(size.height))"
        }
    }
}
