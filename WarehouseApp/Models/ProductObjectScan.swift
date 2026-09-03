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
    case manualBoundary = "arkitManualBoundary"
    case manualEntry = "manualEntry"
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

    /// Optional for documents saved before manual measurement was introduced.
    let percentageTolerance: Double?
    let fixedToleranceCM: Double?
    let usesAdjustedDimensions: Bool?
    let measurementQuality: MeasurementQuality?
    let manualMeasurement: ManualARMeasurementMetadata?
}

struct ObjectDimensions: Codable, Equatable {
    let length: Double
    let width: Double
    let height: Double

    var values: [Double] { [length, width, height] }
}

/// Transient capture passed into Add Product. Manual-boundary metadata is
/// copied into `ProductObjectScan`; dense automatic-scan point clouds remain
/// transient to avoid oversized product documents.
struct ObjectScanCapture: Equatable {
    let id: UUID
    let rawDimensionsCM: ObjectDimensions
    let pointsInMetres: [SIMD3<Float>]
    let scanMethod: ObjectScanMethod
    let deviceModel: String
    let hasLiDAR: Bool
    let confidence: Double
    let timestamp: Date
    let manualMeasurement: ManualARMeasurementMetadata?

    init(
        id: UUID,
        rawDimensionsCM: ObjectDimensions,
        pointsInMetres: [SIMD3<Float>],
        scanMethod: ObjectScanMethod,
        deviceModel: String,
        hasLiDAR: Bool,
        confidence: Double,
        timestamp: Date,
        manualMeasurement: ManualARMeasurementMetadata? = nil
    ) {
        self.id = id
        self.rawDimensionsCM = rawDimensionsCM
        self.pointsInMetres = pointsInMetres
        self.scanMethod = scanMethod
        self.deviceModel = deviceModel
        self.hasLiDAR = hasLiDAR
        self.confidence = confidence
        self.timestamp = timestamp
        self.manualMeasurement = manualMeasurement
    }
}
