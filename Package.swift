// swift-tools-version:6.0
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
                .unsafeFlags(["-parse-as-library"]),
                // Mode strict : les annotations de concurrence sont vérifiées par
                // le compilateur, pas seulement écrites en commentaire.
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .unsafeFlags(["-Llib", "-lwhisper", "-lparakeet", "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal", "-lggml-blas", "-lc++"])
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
