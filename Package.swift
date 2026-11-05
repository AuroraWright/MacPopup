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
        // oneocr (the Windows Snipping Tool's OCR), ported to Swift; models converted by scripts/convert-oneocr.py.
        .target(
            name: "OneOCRKernels",
            path: "Sources/OneOCRKernels"
        ),
        .target(
            name: "OneOCR",
            dependencies: ["OneOCRKernels"],
            path: "Sources/OneOCR"
        ),
        // Runs oneocr on image files (for checking the port against the Python reimplementation).
        .executableTarget(
            name: "oneocr-cli",
            dependencies: ["OneOCR"],
            path: "Sources/OneOCRCLI"
        ),
        // Browser-like HTTP requests for the cloud OCR engines, with libcurl-impersonate (loaded at runtime; scripts/build.sh
        // puts it in the app).
        .target(
            name: "CurlImpersonate",
            path: "Sources/CurlImpersonate"
        ),
        // The Yomitan API's native messaging host (yomitan_api.py, without Python); scripts/build.sh puts it in the app.
        .executableTarget(
            name: "yomitan-api",
            path: "Sources/YomitanAPI"
        ),
        .executableTarget(
            name: "MacPopup",
            dependencies: ["LiveText", "ScreenAI", "OneOCR", "CurlImpersonate"],
            path: "Sources/MacPopup"
        ),
    ]
)
