// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPopup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacPopup",
            path: "Sources/MacPopup"
        ),
    ]
)
