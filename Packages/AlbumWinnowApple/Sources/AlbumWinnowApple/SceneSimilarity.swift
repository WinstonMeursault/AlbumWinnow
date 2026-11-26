import AlbumWinnowRust
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

    init(pixels: [UInt8], size: Int, cancellation: CancellationHandle = CancellationHandle()) throws {
        let value = try coreResult {
            try cancellation.sceneQuality(pixels: corePixels(pixels, size: size))
        }
        meanLuminance = value.meanLuminance
        textureVariance = value.textureVariance
        focusEnergy = value.focusEnergy
        darkClipping = value.darkClipping
        brightClipping = value.brightClipping
    }
}

public struct SceneMatchEvidence: Codable, Equatable, Sendable {
    public let edge: MatchEdge
    public let featureDistance: Float
    public let sharedBurst: Bool
}

struct SceneFeature {
    static let version = "scene-v2.vn2.scaleFill512.\(ProcessInfo.processInfo.operatingSystemVersionString).\(architecture)"
    static var provider: CoreSceneProvider {
        CoreSceneProvider(providerId: "apple.vision", modelRevision: "VNGenerateImageFeaturePrintRequest.2",
                          preprocessing: "scaleFill512.srgb.v2", platformCompatibility: "\(ProcessInfo.processInfo.operatingSystemVersionString).\(architecture)")
    }
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

    init(input: ImageInput, cancellation: CancellationHandle = CancellationHandle()) throws {
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
        try self.init(observation: observation, quality: SceneQuality(pixels: PreparedImage.render(image, width: 128, height: 128), size: 128, cancellation: cancellation), cancellation: cancellation)
    }

    init(archive: Data, quality: SceneQuality) throws {
        guard archive.count <= 16_384,
              let observation = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: archive) else {
            throw ImageReadError.unreadableImage
        }
        try self.init(observation: observation, quality: quality)
    }

    private init(observation: VNFeaturePrintObservation, quality: SceneQuality, cancellation: CancellationHandle = CancellationHandle()) throws {
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
        keys = try coreResult { try cancellation.sceneKeys(vector: vector) }
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
        let burst = first.burstIdentifier.map { !$0.isEmpty && $0 == second.burstIdentifier } == true
        let distance = try distance(to: other)
        guard try coreResult({ try coreSceneMatches(first: quality.coreValue, second: other.quality.coreValue,
                                                   sharedBurst: burst, distance: distance) }) else { return nil }
        return SceneMatchEvidence(edge: MatchEdge(first: first.id, second: second.id, match: .sceneSimilar),
                                  featureDistance: distance, sharedBurst: burst)
    }
}

struct SceneCandidates {
    static let limit = 64
    private let index = RustSceneIndex()

    func candidates(for feature: SceneFeature, asset: PhotoAsset, date: Date? = nil) throws -> [Int] {
        try coreResult {
            try index.candidates(keys: feature.keys, burst: asset.burstIdentifier,
                                 date: (date ?? asset.captureDate)?.timeIntervalSince1970).map(Int.init)
        }
    }

    func insert(_ feature: SceneFeature, asset: PhotoAsset, at position: Int, date: Date? = nil) throws {
        try coreResult {
            try index.insert(keys: feature.keys, burst: asset.burstIdentifier,
                             date: (date ?? asset.captureDate)?.timeIntervalSince1970, index: UInt64(position))
        }
    }
}
