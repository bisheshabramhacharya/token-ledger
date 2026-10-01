// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenLedger",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "TokenLedger", path: "Sources/TokenLedger")
    ]
)
