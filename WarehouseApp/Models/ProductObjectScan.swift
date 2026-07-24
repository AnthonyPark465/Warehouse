import Foundation

enum DimensionDisplayUnit: String, Codable, CaseIterable, Identifiable {
    case centimetres = "cm"
    case metres = "m"

    var id: String { rawValue }
}

enum ObjectScanMethod: String, Codable {
    case objectCapture = "realityKitObjectCapture"
    case lidar = "arkitLiDAR"
    case standardAR = "arkitFeaturePoints"
}

/// The object-measurement data stored as a nested map on the product document.
/// Centimetres are the single internal unit; `displayUnit` is presentation only.
struct ProductObjectScan: Codable, Equatable {
    let rawLength: Double
    let rawWidth: Double
    let rawHeight: Double

    let scanToleranceLength: Double
    let scanToleranceWidth: Double
    let scanToleranceHeight: Double

    let storageClearanceLength: Double
    let storageClearanceWidth: Double
    let storageClearanceHeight: Double

    let finalLength: Double
    let finalWidth: Double
    let finalHeight: Double

    let displayUnit: DimensionDisplayUnit
    let internalUnit: String
    let canBeRotated: Bool

    let scanMethod: ObjectScanMethod
    let deviceModel: String
    let hasLiDAR: Bool
    /// Normalized quality score in the range 0...1.
    let scanConfidence: Double
    let scanTimestamp: Date
}

struct ObjectDimensions: Codable, Equatable {
    let length: Double
    let width: Double
    let height: Double

    var values: [Double] { [length, width, height] }
}

/// Transient geometry used by the review viewer. It is intentionally not
/// persisted because the product record only needs warehouse dimensions.
struct ObjectScanCapture: Equatable {
    let id: UUID
    let rawDimensionsCM: ObjectDimensions
    let pointsInMetres: [SIMD3<Float>]
    let scanMethod: ObjectScanMethod
    let deviceModel: String
    let hasLiDAR: Bool
    let confidence: Double
    let timestamp: Date
}
