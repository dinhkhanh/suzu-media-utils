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
    ],
    targets: [
        .target(name: "FaceCore", swiftSettings: v5),
        .target(name: "MediaKit", dependencies: ["FaceCore"], swiftSettings: v5),
        .target(name: "FaceLibrary", dependencies: ["FaceCore", "MediaKit", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: v5),
        .executableTarget(name: "facescan", dependencies: ["FaceCore", "MediaKit"], swiftSettings: v5),
        .executableTarget(name: "SuZuMediaUtils", dependencies: ["FaceLibrary", "MediaKit"], swiftSettings: v5),
        .testTarget(name: "FaceLibraryTests", dependencies: ["FaceLibrary", "MediaKit"], swiftSettings: v5),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"], swiftSettings: v5),
    ]
)
