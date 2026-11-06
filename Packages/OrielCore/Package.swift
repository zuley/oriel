// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrielCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OrielCore", targets: ["OrielCore"])],
    targets: [
        .target(name: "OrielCore"),
        .testTarget(name: "OrielCoreTests", dependencies: ["OrielCore"])
    ]
)
