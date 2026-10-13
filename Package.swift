// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HermesKit", targets: ["HermesKit"])],
    targets: [
        // Protocol, auth and chat state; no SwiftUI, so it builds without Xcode.
        .target(name: "HermesKit", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
