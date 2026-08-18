// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CAMouflage-Mock",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/mickeyl/SimBridgeKit.git", from: "0.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "CAMouflage-Mock",
            dependencies: [
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: ".",
            exclude: [
                "Resources/CAMouflage.icns",
                "Resources/Info.plist",
                "Resources/entitlements.plist",
            ],
            sources: [
                "MockApp.swift",
                "StatusBarController.swift",
                "Models/AppVersion.swift",
                "Models/ClientMockConfiguration.swift",
                "Models/FixtureSource.swift",
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
