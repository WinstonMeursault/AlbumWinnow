import Foundation

public struct PhotoEvidence: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitDepth: Int?
    public let hasWideColor: Bool
    public let edgeContrast: Double?
    public var captureDate: Date? = nil
}
