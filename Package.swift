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
    dependencies: [
        // WhisperKit, for the Whisper speech recognition models (Settings → Transcription).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "LiveText",
            path: "Sources/LiveText",
            linkerSettings: [.linkedFramework("VisionKit")]
        ),
        // What the engines recognized lines of recent readings as (see LineCache), shared by ScreenAI, OneOCR and OCREngines.
        .target(
            name: "OCRLineCache",
            path: "Sources/OCRLineCache"
        ),
        // Screen AI OCR (Chrome's OCR models, converted to Core ML by scripts/convert-screenai.py).
        .target(
            name: "ScreenAI",
            dependencies: ["OCRLineCache"],
            path: "Sources/ScreenAI"
        ),
        // oneocr (the Windows Snipping Tool's OCR), ported to Swift; models converted by scripts/convert-oneocr.py.
        .target(
            name: "OneOCRKernels",
            path: "Sources/OneOCRKernels"
        ),
        .target(
            name: "OneOCR",
            dependencies: ["OneOCRKernels", "OCRLineCache"],
            path: "Sources/OneOCR"
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
            dependencies: ["ScreenAI", "OneOCR", "CurlImpersonate", "OCRLineCache"],
            path: "Sources/OCREngines"
        ),
        // Speech recognition for the Floating Window's "Read text from audio": models converted or packed by
        // scripts/convert-{whisper,anime-whisper,kitsune,sensevoice,parakeet,sat}.py, loaded like the OCR engines' (ConvertedModels).
        .target(
            name: "Transcription",
            dependencies: ["OCREngines", "SODA", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/Transcription",
            // Accelerate's current CBLAS interface (the old one is deprecated; the same results).
            swiftSettings: [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])]
        ),
        // Chrome's on-device speech recognition (SODA, Live Caption) as opensoda reimplements it, the packs' models run
        // by a small TFLite interpreter with libsoda's kernels' arithmetic (the int8 ones in SODAKernels).
        .target(
            name: "SODAKernels",
            path: "Sources/SODAKernels",
            // No fused multiply-adds the source doesn't ask for: the float results must match TFLite's bit for bit.
            cSettings: [.unsafeFlags(["-ffp-contract=off"]),
                        .unsafeFlags(["-mcpu=apple-a14"], .when(platforms: [.iOS]))]
        ),
        .target(
            name: "SODA",
            dependencies: ["SODAKernels"],
            path: "Sources/SODA",
            // transcribe-cli soda reaches the stages' internals with @testable import. Accelerate's current CBLAS
            // interface (the old one is deprecated; the same results).
            swiftSettings: [.unsafeFlags(["-enable-testing", "-Xcc", "-DACCELERATE_NEW_LAPACK"])]
        ),
        // Reads picture files with the OCR engines (for the test corpus), and runs Screen AI's and oneocr's pieces (for
        // checking the ports against the C++ and Python ones when Google's or Microsoft's engines change).
        .executableTarget(
            name: "ocr-cli",
            dependencies: ["LiveText", "OCREngines", "ScreenAI", "OneOCR"],
            path: "Sources/OCRCLI"
        ),
        // Transcribes audio files (for checking the recognizers against the Python ones), and runs SODA's stages (for
        // checking the port against opensoda when Google's packs change).
        .executableTarget(
            name: "transcribe-cli",
            dependencies: ["OCREngines", "SODA", "Transcription"],
            path: "Sources/TranscribeCLI"
        ),
        // What MacPopup and its pause helper say to each other over XPC.
        .target(
            name: "PauseHelperInterface",
            path: "Sources/PauseHelperInterface"
        ),
        // The root helper that freezes the game while a popup is open (Settings → Scanning → Pause the game);
        // scripts/build.sh puts it in the app, with its launchd property list.
        .executableTarget(
            name: "pause-helper",
            dependencies: ["PauseHelperInterface"],
            path: "Sources/PauseHelper"
        ),
        .executableTarget(
            name: "MacPopup",
            dependencies: ["LiveText", "OCREngines", "PauseHelperInterface", "Transcription"],
            path: "Sources/MacPopup"
        ),
        // Unit tests (Swift Testing): scripts/test.sh unit, or swift test. See Tests/README.md.
        .testTarget(
            name: "UnitTests",
            dependencies: ["MacPopup", "OCREngines", "Transcription"],
            path: "Tests/Unit",
            // Read from the source folder (#filePath), not as resources.
            exclude: ["Fixtures"]
        ),
    ]
)
