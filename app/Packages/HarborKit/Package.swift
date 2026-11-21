// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HarborKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "HarborKit", targets: ["HarborKit"])],
    targets: [
        .target(name: "HarborKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HarborKitTests", dependencies: ["HarborKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
