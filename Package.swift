// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Taptone",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "TaptoneFixtures", targets: ["TaptoneFixtures"]),
        .library(name: "TaptoneCore", targets: ["TaptoneCore"]),
    ],
    targets: [
        .target(name: "TaptoneCore"),
        .executableTarget(name: "TaptoneFixtures", dependencies: ["TaptoneCore"]),
        .testTarget(name: "TaptoneCoreTests", dependencies: ["TaptoneCore"]),
        .testTarget(name: "TaptoneFixturesTests", dependencies: ["TaptoneFixtures"]),
    ]
)
