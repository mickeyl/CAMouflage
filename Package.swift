// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CAMouflage",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CAMouflage",
            targets: ["CAMouflage"]
        ),
    ],
    targets: [
        .target(
            name: "CAMouflage",
            path: "Sources/CAMouflage",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
            ]
        ),
    ]
)
