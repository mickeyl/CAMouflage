import AVFoundation
import Combine

/// A Mac video device the user can forward in passthrough mode.
struct CameraDevice: Identifiable, Equatable {
    let id: String   // AVCaptureDevice.uniqueID
    let name: String
}

/// Enumerates the Mac's video devices (built-in, external UVC, Continuity
/// Camera, Desk View), tracks camera authorization, and remembers which device
/// the user picked for passthrough. UI-facing state is published on the main
/// thread; the persisted selection survives relaunches.
@MainActor
public final class CameraCatalog: ObservableObject {
    @Published private(set) var devices: [CameraDevice] = []
    @Published private(set) var authorization: AVAuthorizationStatus
    @Published public var selectedDeviceID: String? {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            UserDefaults.standard.set(selectedDeviceID, forKey: Self.selectionKey)
        }
    }

    private static let selectionKey = "PassthroughDeviceID"
    private static let deviceTypes: [AVCaptureDevice.DeviceType] =
        [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]

    private var observers: [NSObjectProtocol] = []

    public init() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.selectionKey)
        refresh()

        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Requests camera access on first passthrough use, then refreshes the list.
    /// TCC-gated device names only resolve once access is granted.
    public func activate() {
        guard authorization == .notDetermined else {
            refresh()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes,
                                                         mediaType: .video,
                                                         position: .unspecified)
        devices = discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }

        // Keep the selection pointing at a device that still exists; fall back
        // to the first available camera so passthrough is useful out of the box.
        if let selected = selectedDeviceID, devices.contains(where: { $0.id == selected }) {
            return
        }
        selectedDeviceID = devices.first?.id
    }
}
