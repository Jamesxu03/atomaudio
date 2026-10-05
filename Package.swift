// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioInput",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
    ],
    targets: [
        // Audio → text: Parakeet, word-list boosting, cleanup rules, on-device AI review.
        // Shared by the app and the benchmark so both measure the same thing.
        .target(
            name: "DictationCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Phase 2: the menu-bar dictation app. Package it with Scripts/build_app.sh.
        .executableTarget(
            name: "AudioInput",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Phase 1: compares speech engines on your own recordings (accuracy + speed).
        .executableTarget(
            name: "Bench",
            dependencies: ["DictationCore", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Regression checks for the text pipeline (no Xcode needed): swift run -c release CoreChecks
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Phase 0: records test clips of your voice, one per prompt line.
        .executableTarget(
            name: "RecordClips",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
