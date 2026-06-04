// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Trace",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Trace", targets: ["Trace"]),
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "SharedCore", targets: ["SharedCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.7"),
        .package(url: "https://github.com/MrKai77/DynamicNotchKit.git", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0"),
        // On-device Whisper (multilingual incl. Mandarin) for local ASR — BAS-74.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        // === Libraries ===
        .target(
            name: "SharedCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/SharedCore",
            resources: [
                .copy("Dictation/ModeResources")
            ]
        ),
        .target(
            name: "DictationModule",
            dependencies: ["SharedCore"],
            path: "Sources/DictationModule"
        ),
        .target(
            name: "MeetingModule",
            dependencies: ["SharedCore"],
            path: "Sources/MeetingModule"
        ),
        .target(
            name: "FileBatchModule",
            dependencies: ["SharedCore"],
            path: "Sources/FileBatchModule"
        ),
        .target(
            name: "CoachModule",
            dependencies: ["SharedCore"],
            path: "Sources/CoachModule"
        ),
        .target(
            name: "AppShell",
            dependencies: [
                "SharedCore",
                "DictationModule",
                "MeetingModule",
                "FileBatchModule",
                "CoachModule",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AppShell",
            resources: [.copy("Resources")]
        ),

        // === Executable ===
        .executableTarget(
            name: "Trace",
            dependencies: ["AppShell"],
            path: "Sources/Trace"
        ),
        // Dev-only CLI: replays a recorded audio file through the real Parakeet
        // backend (and optionally the coach) so meeting transcription/coach can be
        // tested + diffed without sitting through a live meeting. Not shipped.
        .executableTarget(
            name: "TraceReplay",
            dependencies: ["SharedCore", "CoachModule"],
            path: "Sources/TraceReplay"
        ),

        // === Tests ===
        .testTarget(name: "SharedCoreTests", dependencies: ["SharedCore"], path: "Tests/SharedCoreTests"),
        .testTarget(
            name: "DictationModuleTests", dependencies: ["DictationModule"], path: "Tests/DictationModuleTests"),
        .testTarget(name: "MeetingModuleTests", dependencies: ["MeetingModule"], path: "Tests/MeetingModuleTests"),
        .testTarget(
            name: "FileBatchModuleTests", dependencies: ["FileBatchModule"], path: "Tests/FileBatchModuleTests"),
        .testTarget(name: "CoachModuleTests", dependencies: ["CoachModule"], path: "Tests/CoachModuleTests"),
        .testTarget(name: "AppShellTests", dependencies: ["AppShell"], path: "Tests/AppShellTests"),
    ]
)
