// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hark-dictate", targets: ["HarkDictate"]),
        .executable(name: "Hark", targets: ["HarkApp"]),
    ],
    targets: [
        // whisper.cpp with Metal, from the official release. b5454 is the build of v1.9.5.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        // The dictation engine and every rule that does not need macOS: no audio, no UI.
        .target(name: "HarkCore"),
        // The real ports: Core Audio mic, whisper.cpp, clipboard paste.
        .target(name: "HarkMac", dependencies: ["HarkCore", "whisper"]),
        .executableTarget(name: "HarkDictate", dependencies: ["HarkCore", "HarkMac"]),
        // The menu bar app. scripts/build-app.sh wraps it in Hark.app.
        .executableTarget(name: "HarkApp", dependencies: ["HarkCore", "HarkMac"]),
        .testTarget(name: "HarkCoreTests", dependencies: ["HarkCore"]),
        .testTarget(
            name: "HarkMacTests",
            dependencies: ["HarkCore", "HarkMac"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
