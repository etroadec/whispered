// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Whispered",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Whispered", targets: ["Whispered"])
    ],
    targets: [
        .executableTarget(
            name: "Whispered",
            dependencies: ["CWhisper"],
            path: "Whispered",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreML"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .unsafeFlags(["-Llib", "-lwhisper", "-lwhisper.coreml", "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal", "-lggml-blas", "-lc++"])
            ]
        ),
        .systemLibrary(
            name: "CWhisper",
            path: "WhisperCpp/include",
            pkgConfig: nil,
            providers: []
        )
    ]
)
