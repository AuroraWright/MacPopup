// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPopup",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LiveText",
            path: "Sources/LiveText",
            linkerSettings: [.linkedFramework("VisionKit")]
        ),
        .executableTarget(
            name: "MacPopup",
            dependencies: ["LiveText"],
            path: "Sources/MacPopup"
        ),
    ]
)
