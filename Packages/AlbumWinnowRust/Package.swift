// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumWinnowRust",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "AlbumWinnowRust", targets: ["AlbumWinnowRust"])],
    targets: [
        .binaryTarget(name: "AlbumWinnowRustFFI", path: "../../.local/core/AlbumWinnowRustFFI.xcframework"),
        .target(name: "AlbumWinnowRust", dependencies: ["AlbumWinnowRustFFI"]),
        .testTarget(name: "AlbumWinnowRustTests", dependencies: ["AlbumWinnowRust"], resources: [.copy("CoreFixtures")]),
    ]
)
