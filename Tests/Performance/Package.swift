// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanBenchmark",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../Packages/AlbumWinnowCore")],
    targets: [
        .executableTarget(name: "ScanBenchmark", dependencies: ["AlbumWinnowCore"]),
        .executableTarget(name: "ReviewStateBenchmark", dependencies: ["AlbumWinnowCore"]),
    ]
)
