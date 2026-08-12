// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CAMouflage-Mock",
    platforms: [.macOS("15.0")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CAMouflage-Mock",
            dependencies: [],
            path: ".",
            exclude: [
                "Resources/CAMouflage.icns",
                "Resources/Info.plist",
                "Resources/entitlements.plist",
            ],
            sources: [
                "MockApp.swift",
                "StatusBarController.swift",
                "Models/AppPreferences.swift",
                "Models/AppVersion.swift",
                "Models/FixtureSource.swift",
                "Models/ProviderMode.swift",
                "Server/MockCameraServer.swift",
                "Server/FrameServer.swift",
                "Server/FrameProducer.swift",
                "Server/CameraCaptureSource.swift",
                "Server/CameraCatalog.swift",
                "Views/MenuContent.swift",
            ]
        )
    ]
)
