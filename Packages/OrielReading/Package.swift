// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrielReading",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OrielReading", type: .static, targets: ["OrielReading", "OrielReaderUI"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "OrielReading", dependencies: ["ZIPFoundation"]),
        .target(name: "OrielReaderUI", dependencies: ["OrielReading"]),
        .testTarget(name: "OrielReadingTests", dependencies: ["OrielReading", "ZIPFoundation"]),
        .testTarget(name: "OrielReaderUITests", dependencies: ["OrielReaderUI", "OrielReading"])
    ]
)
