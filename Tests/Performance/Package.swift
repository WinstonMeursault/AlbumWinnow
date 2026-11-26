// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanBenchmark",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../Packages/AlbumWinnowApple"), .package(path: "../../Packages/AlbumWinnowRust")],
    targets: [
        .executableTarget(name: "ScanBenchmark", dependencies: ["AlbumWinnowApple", "AlbumWinnowRust"]),
        .executableTarget(name: "ReviewStateBenchmark", dependencies: ["AlbumWinnowRust"]),
    ]
)
