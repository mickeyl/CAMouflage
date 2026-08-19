import SwiftUI
import SimBridgeServer
import SimBridgeShell

/// The standalone app's control panel: a title header and an app footer
/// wrapped around `CAMouflageSection`, which carries the actual provider UI.
public struct MenuContent: View {
    @ObservedObject var server: MockCameraServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var catalog: CameraCatalog
    @ObservedObject var controller: ModeTransitionController<ProviderMode>
    let onDismiss: () -> Void

    @State private var dismissOnDeactivate = ShellPreferences.dismissControlWindowOnDeactivate
    @State private var launchAtLogin = MenuContent.launchAgent.isEnabled
    private static let launchAgent = LaunchAtLogin(label: "de.vanille.camouflage-mac")

    public init(
        server: MockCameraServer,
        transport: ProtocolServer,
        catalog: CameraCatalog,
        controller: ModeTransitionController<ProviderMode>,
        onDismiss: @escaping () -> Void
    ) {
        self.server = server
        self.transport = transport
        self.catalog = catalog
        self.controller = controller
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            CAMouflageSection(
                server: server,
                transport: transport,
                catalog: catalog,
                controller: controller
            )
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Dismiss panel on app switch", isOn: $dismissOnDeactivate)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: dismissOnDeactivate) { _, newValue in
                    ShellPreferences.dismissControlWindowOnDeactivate = newValue
                }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, newValue in
                    Self.launchAgent.setEnabled(newValue)
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
