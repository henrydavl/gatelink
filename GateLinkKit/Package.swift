// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GateLinkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GateLinkKit", targets: ["GateLinkKit"]),
    ],
    targets: [
        .target(name: "GateLinkKit"),
        .testTarget(name: "GateLinkKitTests", dependencies: ["GateLinkKit"]),
    ]
)
