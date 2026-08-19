import SwiftUI
import AppKit
import CAMouflageProviderKit

@MainActor
private final class MacAppRuntime {
    let server: MockCameraServer
    let statusBar: StatusBarController

    init() {
        server = MockCameraServer()
        statusBar = StatusBarController(server: server)
    }
}

@main
struct MacApp: App {
    fileprivate static var retainedRuntime: MacAppRuntime?

    @StateObject private var server: MockCameraServer
    @StateObject private var statusBar: StatusBarController

    init() {
        let runtime = Self.retainedRuntime ?? MacAppRuntime()
        Self.retainedRuntime = runtime

        _server = StateObject(wrappedValue: runtime.server)
        _statusBar = StateObject(wrappedValue: runtime.statusBar)

        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
