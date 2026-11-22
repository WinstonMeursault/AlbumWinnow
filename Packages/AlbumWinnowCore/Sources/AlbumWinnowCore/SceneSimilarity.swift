import CoreGraphics
import Foundation
import Vision

public struct SceneQuality: Codable, Equatable, Sendable {
    public let meanLuminance: Double
    public let textureVariance: Double
    public let focusEnergy: Double
    public let darkClipping: Double
    public let brightClipping: Double

    var valid: Bool {
        [meanLuminance, textureVariance, darkClipping, brightClipping].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
            focusEnergy.isFinite && (0...16).contains(focusEnergy)
    }

    init(pixels: [UInt8], size: Int) throws {
        guard size > 2, size <= 1024, pixels.count == size * size * 4 else { throw ImageReadError.unreadableImage }
        let luminance: [Double] = stride(from: 0, to: pixels.count, by: 4).map { index -> Double in
            let red = 0.299 * Double(pixels[index])
            let green = 0.587 * Double(pixels[index + 1])
            let blue = 0.114 * Double(pixels[index + 2])
            return (red + green + blue) / 255.0
        }
        let count = Double(luminance.count)
        let mean = luminance.reduce(0, +) / count
        meanLuminance = mean
        textureVariance = luminance.reduce(0) { $0 + pow($1 - mean, 2) } / count
        darkClipping = Double(luminance.filter { $0 <= 0.02 }.count) / count
        brightClipping = Double(luminance.filter { $0 >= 0.98 }.count) / count
        var energy = 0.0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let i = y * size + x
                let horizontal: Double = 4.0 * luminance[i] - luminance[i - 1] - luminance[i + 1]
                let laplacian: Double = horizontal - luminance[i - size] - luminance[i + size]
                energy += laplacian * laplacian
            }
        }
        focusEnergy = energy / Double((size - 2) * (size - 2))
    }
}

public struct SceneMatchEvidence: Codable, Equatable, Sendable {
    public let edge: MatchEdge
    public let featureDistance: Float
    public let sharedBurst: Bool
}

struct SceneFeature {
    static let version = "scene-v1.vn2.scaleFill512.\(ProcessInfo.processInfo.operatingSystemVersionString).\(architecture)"
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    let observation: VNFeaturePrintObservation
    let quality: SceneQuality
    let keys: [UInt16]

    init(input: ImageInput) throws {
        try Task.checkCancellation()
        let source = try input.source()
        let metadata = try input.metadata(for: source)
        let image = try PreparedImage.orientedImage(source, longestSide: 512, override: metadata.orientationOverride)
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        #if targetEnvironment(simulator)
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first else { throw ImageReadError.unreadableImage }
        try self.init(observation: observation, quality: SceneQuality(pixels: PreparedImage.render(image, width: 128, height: 128), size: 128))
    }

    init(archive: Data, quality: SceneQuality) throws {
        guard archive.count <= 16_384,
              let observation = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archive) else {
            throw ImageReadError.unreadableImage
        }
        try self.init(observation: observation, quality: quality)
    }

    private init(observation: VNFeaturePrintObservation, quality: SceneQuality) throws {
        guard quality.valid, observation.requestRevision == VNGenerateImageFeaturePrintRequestRevision2,
              observation.elementType == .float, observation.elementCount == 768, observation.data.count == 3072 else {
            throw ImageReadError.unreadableImage
        }
        let vector = observation.data.withUnsafeBytes { buffer in
            stride(from: 0, to: buffer.count, by: 4).map { buffer.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        guard vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw ImageReadError.unreadableImage }
        self.observation = observation
        self.quality = quality
        keys = Self.projections.map { band in
            band.reduce(UInt16(0)) { key, projection in
                let value = projection.reduce(Float(0)) { $0 + vector[$1.index] * $1.sign }
                return (key << 1) | (value >= 0 ? 1 : 0)
            }
        }
    }

    func archive() throws -> Data { try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true) }

    func distance(to other: SceneFeature) throws -> Float {
        var distance: Float = 0
        try observation.computeDistance(&distance, to: other.observation)
        guard distance.isFinite, distance >= 0 else { throw ImageReadError.unreadableImage }
        return distance
    }

    func match(to other: SceneFeature, first: PhotoAsset, second: PhotoAsset) throws -> SceneMatchEvidence? {
        guard first.id != second.id else { return nil }
        if first.id.source.hasPrefix("folder:"), second.id.source.hasPrefix("folder:"),
           first.revision.split(separator: ":").prefix(2) == second.revision.split(separator: ":").prefix(2) { return nil }
        let burst = first.burstIdentifier.map { !$0.isEmpty && $0 == second.burstIdentifier } == true
        // Uniform-color feature proximity does not establish a shared scene.
        guard burst || (quality.textureVariance >= 0.0004 && other.quality.textureVariance >= 0.0004) else { return nil }
        let distance = try distance(to: other)
        guard distance <= (burst ? 0.32 : 0.24) else { return nil }
        return SceneMatchEvidence(edge: MatchEdge(first: first.id, second: second.id, match: .sceneSimilar),
                                  featureDistance: distance, sharedBurst: burst)
    }

    static func verify(_ first: PhotoAsset, source firstSource: any AssetSource,
                       _ second: PhotoAsset, source secondSource: any AssetSource, algorithm: String) async throws -> Bool {
        guard algorithm == version else { return false }
        func input(_ asset: PhotoAsset, _ source: any AssetSource) async throws -> ImageInput {
            do { return try await source.imageInput(for: asset) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ComparisonReadError(assetID: asset.id, underlying: error) }
        }
        let left = try await input(first, firstSource)
        let right = try await input(second, secondSource)
        let matches = try autoreleasepool {
            try SceneFeature(input: left).match(to: SceneFeature(input: right), first: first, second: second) != nil
        }
        try DuplicateDetector.validateComparisonImage(first, source: firstSource)
        try DuplicateDetector.validateComparisonImage(second, source: secondSource)
        try Task.checkCancellation()
        return matches
    }

    private struct Projection: Sendable { let index: Int; let sign: Float }
    private static let projections: [[[Projection]]] = {
        var seed: UInt64 = 0xA1B0_2026
        return (0..<4).map { _ in (0..<16).map { _ in (0..<16).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Projection(index: Int((seed >> 32) % 768), sign: seed & 1 == 0 ? 1 : -1)
        } } }
    }()
}

struct SceneCandidates {
    static let limit = 64
    private var buckets: [UInt32: [Int]] = [:]
    private var bursts: [String: [Int]] = [:]
    private var dated: [(index: Int, date: Date)] = []

    func candidates(for feature: SceneFeature, asset: PhotoAsset, date: Date? = nil) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        func add(_ values: [Int]) {
            for index in values.reversed() where result.count < Self.limit && seen.insert(index).inserted { result.append(index) }
        }
        if let burst = asset.burstIdentifier { add(bursts[burst] ?? []) }
        if let date = date ?? asset.captureDate {
            add(dated.suffix(16).filter { abs($0.date.timeIntervalSince(date)) <= 10 }.map(\.index))
        }
        for (band, key) in feature.keys.enumerated() where result.count < Self.limit {
            add(buckets[(UInt32(band) << 16) | UInt32(key)] ?? [])
            for bit in 0..<16 where result.count < Self.limit {
                add(buckets[(UInt32(band) << 16) | UInt32(key ^ (1 << bit))] ?? [])
            }
        }
        return result
    }

    mutating func insert(_ feature: SceneFeature, asset: PhotoAsset, at index: Int, date: Date? = nil) {
        for (band, key) in feature.keys.enumerated() {
            let key = (UInt32(band) << 16) | UInt32(key)
            buckets[key, default: []].append(index)
            if buckets[key]!.count > Self.limit { buckets[key]!.removeFirst() }
        }
        if let burst = asset.burstIdentifier {
            bursts[burst, default: []].append(index)
            if bursts[burst]!.count > 32 { bursts[burst]!.removeFirst() }
        }
        if let date = date ?? asset.captureDate {
            dated.append((index, date))
            if dated.count > 16 { dated.removeFirst() }
        }
    }
}
