// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumWinnowCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AlbumWinnowCore", targets: ["AlbumWinnowCore"])],
    dependencies: [.package(url: "https://github.com/JoshBashed/blake3-swift.git", exact: "0.2.2")],
    targets: [
        .target(
            name: "AlbumWinnowCore",
            dependencies: [.product(name: "BLAKE3", package: "blake3-swift")]
        ),
    ]
)
