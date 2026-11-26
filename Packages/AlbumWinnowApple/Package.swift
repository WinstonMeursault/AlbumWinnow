// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumWinnowApple",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "AlbumWinnowApple", targets: ["AlbumWinnowApple"])],
    dependencies: [
        .package(path: "../AlbumWinnowRust"),
    ],
    targets: [
        .target(
            name: "AlbumWinnowApple",
            dependencies: [
                .product(name: "AlbumWinnowRust", package: "AlbumWinnowRust"),
            ]
        ),
        .testTarget(
            name: "AlbumWinnowAppleTests",
            dependencies: ["AlbumWinnowApple", .product(name: "AlbumWinnowRust", package: "AlbumWinnowRust")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
