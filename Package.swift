// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HermesKit", targets: ["HermesKit"])],
    targets: [
        // Protocol, auth and chat state; no SwiftUI, so it builds without Xcode.
        .target(name: "HermesKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Talks to a real gateway from the Mac so the protocol code is checked without a simulator.
        .executableTarget(name: "hermes-probe", dependencies: ["HermesKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
