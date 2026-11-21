// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumWinnowCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "AlbumWinnowCore", targets: ["AlbumWinnowCore"])],
    dependencies: [
        .package(url: "https://github.com/JoshBashed/blake3-swift.git", exact: "0.2.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "AlbumWinnowCore",
            dependencies: [
                .product(name: "BLAKE3", package: "blake3-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AlbumWinnowCoreTests",
            dependencies: ["AlbumWinnowCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
