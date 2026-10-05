// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlenderRenderMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BlenderRenderMonitor", path: "Sources/BlenderRenderMonitor"),
    ]
)
