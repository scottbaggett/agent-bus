// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentBusBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentBusBar", path: "Sources/AgentBusBar")
    ]
)
