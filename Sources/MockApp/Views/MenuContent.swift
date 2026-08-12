import SwiftUI
import UniformTypeIdentifiers

struct MenuContent: View {
    @ObservedObject var server: MockCameraServer
    @ObservedObject var catalog: CameraCatalog
    @ObservedObject var controller: StatusBarController
    let onDismiss: () -> Void

    @State private var dismissOnDeactivate = AppPreferences.dismissControlWindowOnDeactivate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker
            Divider()
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
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Image(systemName: "camera.aperture")
                .font(.title2)
            Text("CAMouflage")
                .font(.title3.weight(.semibold))
            Spacer()
            Text(AppVersion.current)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $controller.mode) {
            ForEach(ProviderMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Off shows no cameras · Mock serves a fixture · Passthrough forwards a real Mac camera.")
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

    private var offSection: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            Image(nsImage: NSApplication.shared.applicationIconImage)
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
            if let client = server.connectedClient {
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
        switch server.status {
            case .stopped: .red
            case .listening: .yellow
            case .clientConnected: server.trafficActive ? .green : .teal
        }
    }

    private var statusText: String {
        switch server.status {
            case .stopped: "Stopped"
            case .listening: "Waiting for a simulator app…"
            case .clientConnected: server.trafficActive ? "Streaming frames" : "Client connected"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Dismiss panel on app switch", isOn: $dismissOnDeactivate)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: dismissOnDeactivate) { _, newValue in
                    AppPreferences.dismissControlWindowOnDeactivate = newValue
                }
            HStack {
                Button("Quit CAMouflage") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Close") {
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout)
        }
    }
}
