// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Taptone",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Taptone", targets: ["Taptone"]),
        .executable(name: "TaptoneFixtures", targets: ["TaptoneFixtures"]),
        .library(name: "TaptoneAudio", targets: ["TaptoneAudio"]),
        .library(name: "TaptoneCore", targets: ["TaptoneCore"]),
    ],
    targets: [
        .target(name: "TaptoneCore"),
        .target(name: "AudioMailbox"),
        .target(name: "AudioListener"),
        .target(name: "TaptoneAudio", dependencies: ["AudioListener", "AudioMailbox", "TaptoneCore"]),
        // The only target that touches the private trackpad actuator ABI.
        .target(name: "TaptoneHaptics", dependencies: ["TaptoneCore"]),
        .executableTarget(name: "Taptone", dependencies: ["TaptoneCore", "TaptoneAudio", "TaptoneHaptics"]),
        .executableTarget(name: "TaptoneFixtures", dependencies: ["TaptoneCore"]),
        .testTarget(name: "TaptoneCoreTests", dependencies: ["TaptoneCore"]),
        .testTarget(name: "TaptoneFixturesTests", dependencies: ["TaptoneFixtures"]),
        .testTarget(name: "AudioMailboxTests", dependencies: ["AudioMailbox"]),
        .testTarget(name: "TaptoneAudioTests", dependencies: ["TaptoneAudio"]),
        .testTarget(name: "TaptoneHapticsTests", dependencies: ["TaptoneHaptics"]),
    ],
    cLanguageStandard: .c11
)
