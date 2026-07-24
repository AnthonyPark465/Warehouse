import Foundation

struct PackageDimensions: Codable, Equatable {
    let widthCM: Double
    let heightCM: Double
    let depthCM: Double

    var volumeCM3: Double { widthCM * heightCM * depthCM }

    var orientations: [PackageDimensions] {
        let values = [
            PackageDimensions(widthCM: widthCM, heightCM: heightCM, depthCM: depthCM),
            PackageDimensions(widthCM: widthCM, heightCM: depthCM, depthCM: heightCM),
            PackageDimensions(widthCM: heightCM, heightCM: widthCM, depthCM: depthCM),
            PackageDimensions(widthCM: heightCM, heightCM: depthCM, depthCM: widthCM),
            PackageDimensions(widthCM: depthCM, heightCM: widthCM, depthCM: heightCM),
            PackageDimensions(widthCM: depthCM, heightCM: heightCM, depthCM: widthCM)
        ]
        return values.reduce(into: []) { result, value in
            guard !result.contains(value) else { return }
            result.append(value)
        }
    }
}

struct PackagePlacementProfile: Equatable {
    let productId: String
    let dimensions: PackageDimensions
    let weightKG: Double
    /// 0...1. Higher means this SKU is picked more often.
    let demandVelocity: Double
}

struct StorageLocation: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let barcode: String
    let freeWidthCM: Double
    let freeHeightCM: Double
    let freeDepthCM: Double
    let remainingWeightKG: Double
    /// Walking distance from the receiving/picking origin.
    let walkingDistanceM: Double
    /// 0...1. Order-history relationship to nearby products.
    let orderAffinity: Double
    let source: Source

    enum Source: String, Codable {
        case mapped
        case lidarScan
    }

    var freeVolumeCM3: Double { freeWidthCM * freeHeightCM * freeDepthCM }
}

struct PlacementRecommendation: Identifiable, Equatable {
    let location: StorageLocation
    let orientation: PackageDimensions
    let score: Double
    let spaceEfficiency: Double
    let distanceScore: Double
    let affinityScore: Double
    let capacityScore: Double

    var id: String { location.id }
}

enum WarehouseScale: String, CaseIterable, Identifiable {
    case small = "Small"
    case growing = "Growing"
    case enterprise = "Enterprise"

    var id: String { rawValue }
}

