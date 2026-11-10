// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPopup",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        // For the iOS app (an Xcode project under ios/).
        .library(name: "OCREngines", targets: ["OCREngines"]),
        .library(name: "LiveText", targets: ["LiveText"]),
    ],
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
            path: "Sources/OneOCRKernels",
            // iOS builds default to the A7's instruction set, without the dot product instructions the kernels use. The
            // iOS app's oldest device is the iPhone 13 mini (A15); the A14 is the Apple Silicon Mac's core, for the
            // simulator.
            cSettings: [.unsafeFlags(["-mcpu=apple-a14"], .when(platforms: [.iOS]))]
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
        // puts it in the Mac app, the iOS project's build in the iOS app).
        .target(
            name: "CurlImpersonate",
            path: "Sources/CurlImpersonate"
        ),
        // The Yomitan API's native messaging host (yomitan_api.py, without Python); scripts/build.sh puts it in the app.
        .executableTarget(
            name: "yomitan-api",
            path: "Sources/YomitanAPI"
        ),
        // The OCR engines (local, and Google Lens' and Bing's) and what OCR mode does with their readings (layout, furigana,
        // language), shared with the iOS app.
        .target(
            name: "OCREngines",
            dependencies: ["ScreenAI", "OneOCR", "CurlImpersonate"],
            path: "Sources/OCREngines"
        ),
        .executableTarget(
            name: "MacPopup",
            dependencies: ["LiveText", "OCREngines"],
            path: "Sources/MacPopup"
        ),
    ]
)
