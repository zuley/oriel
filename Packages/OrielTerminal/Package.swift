// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrielTerminal",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OrielTerminal", type: .static, targets: ["OrielTerminal"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1")],
    targets: [
        .target(name: "OrielTerminal", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "OrielTerminalTests", dependencies: ["OrielTerminal"])
    ]
)
