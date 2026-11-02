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
        // Screen AI OCR (Chrome's OCR models, converted to Core ML by scripts/convert-screenai.py).
        .target(
            name: "ScreenAI",
            path: "Sources/ScreenAI"
        ),
        // Runs Screen AI on image files (for checking the port against the C++ one).
        .executableTarget(
            name: "screenai-cli",
            dependencies: ["ScreenAI"],
            path: "Sources/ScreenAICLI"
        ),
        .executableTarget(
            name: "MacPopup",
            dependencies: ["LiveText", "ScreenAI"],
            path: "Sources/MacPopup"
        ),
    ]
)
