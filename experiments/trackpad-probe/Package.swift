// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptoneTrackpadProbe",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "TaptoneTrackpadProbe", targets: ["TaptoneTrackpadProbe"])],
    dependencies: [.package(name: "Taptone", path: "../..")],
    targets: [
        .executableTarget(
            name: "TaptoneTrackpadProbe",
            dependencies: [.product(name: "TaptoneAudio", package: "Taptone"),
                           .product(name: "TaptoneCore", package: "Taptone")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker",
                                           Context.packageDirectory + "/Info.plist"])]
        ),
        .testTarget(name: "TrackpadProbeTests", dependencies: ["TaptoneTrackpadProbe"]),
    ]
)
