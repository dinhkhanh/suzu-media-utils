// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SuZuMediaUtils",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FaceCore", targets: ["FaceCore"]),
        .executable(name: "facescan", targets: ["facescan"]),
        .executable(name: "SuZuMediaUtils", targets: ["SuZuMediaUtils"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(name: "FaceCore", swiftSettings: v5),
        .target(name: "MediaKit", dependencies: ["FaceCore"], swiftSettings: v5),
        // The one system call Swift can't make (an SMB server-side copy, see Exporter.copy).
        .target(name: "CShims"),
        .target(name: "FaceLibrary", dependencies: ["FaceCore", "MediaKit", "CShims", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: v5),
        .executableTarget(name: "facescan", dependencies: ["FaceCore", "MediaKit"], swiftSettings: v5),
        // AVKit by name: `import AVKit` alone links only its SwiftUI overlay, and a VideoPlayer then crashes looking
        // for AVPlayerView.
        .executableTarget(name: "SuZuMediaUtils", dependencies: ["FaceLibrary", "MediaKit", .product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: v5, linkerSettings: [.linkedFramework("AVKit")]),
        .testTarget(name: "FaceLibraryTests", dependencies: ["FaceLibrary", "MediaKit"], swiftSettings: v5),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"], swiftSettings: v5),
    ]
)
