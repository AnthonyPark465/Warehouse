import Foundation

struct ARWorldCoordinate: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    init(_ value: SIMD3<Float>) {
        x = Double(value.x)
        y = Double(value.y)
        z = Double(value.z)
    }

    var simd: SIMD3<Float> {
        SIMD3(Float(x), Float(y), Float(z))
    }
}

struct ManualBoundaryMarker: Codable, Equatable, Identifiable {
    let id: UUID
    let position: ARWorldCoordinate
    let timestamp: Date
    let trackingConfidence: Double
    let raycastType: String
    let surfaceAlignment: String
    let sessionIdentifier: UUID
}

struct MeasurementBasePlane: Codable, Equatable {
    let origin: ARWorldCoordinate
    let normal: ARWorldCoordinate
    let maximumDeviationMetres: Double
}

struct ManualARMeasurementMetadata: Codable, Equatable {
    let sessionIdentifier: UUID
    let boundaryMarkers: [ManualBoundaryMarker]
    let bottomMarker: ManualBoundaryMarker
    let topMarker: ManualBoundaryMarker
    let basePlane: MeasurementBasePlane
    let footprintAreaSquareMetres: Double
    let perimeterMetres: Double
    let orientationAngleDegrees: Double
    /// `true` means boundary/limit coordinates are an ROI only and were not
    /// used as the saved product dimensions.
    let scanningRegionOnly: Bool?
    let detectedProductPointCount: Int?
    let detectedProductTouchedRegionBoundary: Bool?
}

enum MeasurementQuality: String, Codable {
    case good
    case acceptable
    case low
    case repeatRecommended
}
