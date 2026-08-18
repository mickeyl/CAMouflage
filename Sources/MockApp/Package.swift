// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CAMouflage-Mock",
    platforms: [.macOS("15.0")],
    products: [
        // The host-side provider as a library, so the Simsalabim suite app can
        // embed it alongside other providers. The standalone menu bar app is a
        // thin wrapper around the same target.
        .library(name: "CAMouflageProviderKit", targets: ["CAMouflageProviderKit"]),
        .executable(name: "CAMouflage-Mock", targets: ["CAMouflage-Mock"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mickeyl/SimBridgeKit.git", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "CAMouflageProviderKit",
            dependencies: [
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: "ProviderKit"
        ),
        .executableTarget(
            name: "CAMouflage-Mock",
            dependencies: [
                "CAMouflageProviderKit",
                .product(name: "SimBridgeServer", package: "SimBridgeKit"),
                .product(name: "SimBridgeShell", package: "SimBridgeKit"),
            ],
            path: "App"
        )
    ]
)
