// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoiseKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NoiseKit", targets: ["NoiseKit"]),
    ],
    targets: [
        .target(
            name: "NoiseKit",
            // The render loop runs per sample on the audio thread, so it is optimised in debug builds too.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "NoiseKitTests", dependencies: ["NoiseKit"]),
    ],
    swiftLanguageModes: [.v5]
)
