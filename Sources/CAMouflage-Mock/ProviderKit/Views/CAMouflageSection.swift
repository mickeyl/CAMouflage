import SwiftUI
import UniformTypeIdentifiers
import SimBridgeServer
import SimBridgeShell

/// The embeddable heart of the CAMouflage provider UI: mode picker, source
/// selection, live preview, and status. The standalone panel wraps it with a
/// title header and an app footer; the Simsalabim suite embeds it as one
/// section among several providers.
public struct CAMouflageSection: View {
    @ObservedObject var server: MockCameraServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var catalog: CameraCatalog
    @ObservedObject var controller: ModeTransitionController<ProviderMode>

    public init(
        server: MockCameraServer,
        transport: ProtocolServer,
        catalog: CameraCatalog,
        controller: ModeTransitionController<ProviderMode>
    ) {
        self.server = server
        self.transport = transport
        self.catalog = catalog
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modePicker
            Divider()
            if let configuration = server.clientConfiguration {
                clientConfigurationSection(configuration)
                Divider()
                previewSection
                Divider()
                statusSection
            } else {
                switch controller.mode {
                    case .mock:
                        fixtureSection
                        Divider()
                        previewSection
                        Divider()
                        statusSection
                    case .passthrough:
                        passthroughSection
                        Divider()
                        previewSection
                        Divider()
                        statusSection
                    case .off:
                        offSection
                }
            }
        }
    }

    /// The provider's health, for a host that wants to tint its own chrome.
    public static func statusColor(mode: ProviderMode, status: ProtocolServer.Status, trafficActive: Bool) -> Color {
        guard mode != .off else { return .secondary }
        return switch status {
            case .stopped: .red
            case .listening: .yellow
            case .clientConnected: trafficActive ? .green : .teal
            case .blocked: .orange
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: modeBinding) {
            ForEach(ProviderMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(controller.isSwitching)
        .help("Off shows no cameras · Mock serves a fixture · Passthrough forwards a real Mac camera.")
    }

    private var modeBinding: Binding<ProviderMode> {
        Binding(
            get: { controller.mode },
            set: { controller.select($0) }
        )
    }

    private var fixtureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fixture")
                .font(.headline)
            fixtureRow(kind: .testPattern, title: "Test Pattern", symbol: "timelapse")
            fixtureRow(kind: .image, title: "Image…", symbol: "photo")
            fixtureRow(kind: .movie, title: "Movie…", symbol: "film")
            if server.fixture.kind != .testPattern, let path = server.fixture.path {
                Text((path as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func fixtureRow(kind: FixtureSource.Kind, title: String, symbol: String) -> some View {
        Button {
            selectFixture(kind: kind)
        } label: {
            HStack {
                Image(systemName: server.fixture.kind == kind ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(server.fixture.kind == kind ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectFixture(kind: FixtureSource.Kind) {
        switch kind {
            case .testPattern:
                server.fixture = FixtureSource(kind: .testPattern, path: nil)
            case .image:
                pickFile(types: [.png, .jpeg, .heic, .tiff]) { url in
                    server.fixture = FixtureSource(kind: .image, path: url.path)
                }
            case .movie:
                pickFile(types: [.movie, .mpeg4Movie, .quickTimeMovie]) { url in
                    server.fixture = FixtureSource(kind: .movie, path: url.path)
                }
            case .machineCode:
                break
        }
    }

    private func clientConfigurationSection(_ configuration: ClientMockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Controlled by simulator app", systemImage: "iphone.and.arrow.forward")
                .font(.headline)
            Text(configuration.name)
                .font(.callout.weight(.medium))
            ForEach(configuration.devices) { device in
                HStack {
                    Image(systemName: device.position == "front" ? "person.crop.rectangle" : "camera")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text(device.source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            Text("This temporary test configuration is discarded when the simulator app disconnects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var passthroughSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Camera")
                .font(.headline)
            switch catalog.authorization {
                case .authorized:
                    if catalog.devices.isEmpty {
                        Text("No cameras found. Connect a webcam or bring an iPhone nearby for Continuity Camera.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(catalog.devices) { device in
                                    cameraRow(device)
                                }
                            }
                        }
                        .frame(maxHeight: 176)
                    }
                case .notDetermined:
                    Text("CAMouflage needs access to your cameras to forward one to the simulator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Allow Camera Access…") {
                        catalog.activate()
                    }
                default:
                    Text("Camera access is denied. Enable it in System Settings › Privacy & Security › Camera, then reopen this panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
            }
        }
    }

    private func cameraRow(_ device: CameraDevice) -> some View {
        let isSelected = catalog.selectedDeviceID == device.id
        return Button {
            catalog.selectedDeviceID = device.id
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickFile(types: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    /// The product's own icon. Present in the standalone bundle and copied
    /// into the suite bundle by its Makefile, so the section shows CAMouflage
    /// branding regardless of which host app embeds it.
    private static let brandIcon = NSImage(named: "CAMouflage")

    private var offSection: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            Image(nsImage: Self.brandIcon ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 148, height: 148)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(spacing: 4) {
                Text("CAMouflage is off")
                    .font(.headline)
                Text("Simulator apps see no cameras.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Preview")
                .font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                if let image = server.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Waiting for a simulator app…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
            }
            if let client = transport.connectedClient {
                Text(client.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if server.activeSessionCount > 0 {
                Text("\(server.activeSessionCount) active session\(server.activeSessionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        Self.statusColor(mode: controller.mode, status: transport.status, trafficActive: server.trafficActive)
    }

    private var statusText: String {
        switch transport.status {
            case .stopped: "Stopped"
            case .listening: "Waiting for a simulator app…"
            case .clientConnected: server.trafficActive ? "Streaming frames" : "Client connected"
            case .blocked(let message): message
        }
    }
}
