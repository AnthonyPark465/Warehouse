import Foundation
import simd

struct PackageDimensions: Codable, Equatable, Hashable {
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

enum RetrievalPriority: Int, Codable, Comparable, CaseIterable, Identifiable {
    case veryLow = 1, low, normal, high, critical
    var id: Int { rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum RestingFace: String, Codable, CaseIterable, Hashable, Identifiable {
    case bottom, top, left, right, front, back
    var id: String { rawValue }
}

enum QuantityArrangement: String, Codable, CaseIterable, Identifiable {
    case singleUnit, groupedCase, separateUnits
    var id: String { rawValue }
}

struct StackingRules: Codable, Equatable {
    var canSupportProductsAbove: Bool
    var canBePlacedOnAnotherProduct: Bool
    var maximumSupportedWeight: Double?
    var maximumTotalStackHeight: Double?
    var maximumItemsAbove: Int?
    var maximumIdenticalStackCount: Int?
    var allowedProductTypesAbove: Set<String>?
    var prohibitedProductTypesAbove: Set<String>?
    var requiresFullBaseSupport: Bool
    var minimumSupportRatio: Double
    var fragileTopSurface: Bool
    var notes: String?

    static let conservative = StackingRules(
        canSupportProductsAbove: false,
        canBePlacedOnAnotherProduct: false,
        maximumSupportedWeight: nil,
        maximumTotalStackHeight: nil,
        maximumItemsAbove: nil,
        maximumIdenticalStackCount: nil,
        allowedProductTypesAbove: nil,
        prohibitedProductTypesAbove: nil,
        requiresFullBaseSupport: true,
        minimumSupportRatio: 0.95,
        fragileTopSurface: true,
        notes: "Unspecified stacking data; direct shelf support only."
    )
}

struct ProductPlacementMetadata: Codable, Equatable {
    var weightKG: Double?
    var retrievalPriority: RetrievalPriority
    var expectedRetrievalFrequency: Double
    var expirationUrgency: Double
    var isFragile: Bool?
    var permittedRestingFaces: Set<RestingFace>
    var mustRemainUpright: Bool
    var mayRotateAutomatically: Bool
    var requiredClearanceCM: Double
    var stacking: StackingRules
    var quantityArrangement: QuantityArrangement

    static let conservative = ProductPlacementMetadata(
        weightKG: nil,
        retrievalPriority: .normal,
        expectedRetrievalFrequency: 0.5,
        expirationUrgency: 0,
        isFragile: nil,
        permittedRestingFaces: [.bottom],
        mustRemainUpright: true,
        mayRotateAutomatically: false,
        requiredClearanceCM: 2,
        stacking: .conservative,
        quantityArrangement: .singleUnit
    )
}

struct PackagePlacementProfile: Equatable {
    let productId: String
    let dimensions: PackageDimensions
    let weightKG: Double
    /// 0...1. Higher means this SKU is picked more often.
    let demandVelocity: Double
    var productType: String = "General"
    var metadata: ProductPlacementMetadata = .conservative
    var measurementUncertaintyCM: PackageDimensions = .init(widthCM: 0, heightCM: 0, depthCM: 0)
}

struct StorageLocation: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let barcode: String
    let freeWidthCM: Double
    let freeHeightCM: Double
    let freeDepthCM: Double
    let remainingWeightKG: Double
    let walkingDistanceM: Double
    let orderAffinity: Double
    let source: Source

    enum Source: String, Codable { case mapped, lidarScan }
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
    case small = "Small", growing = "Growing", enterprise = "Enterprise"
    var id: String { rawValue }
}

/// Codable vector used at the persistence boundary. Placement math converts it
/// to SIMD so Firestore documents remain portable and migration-friendly.
struct Vector3D: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    init(_ value: SIMD3<Double>) { self.init(value.x, value.y, value.z) }
    var simd: SIMD3<Double> { SIMD3(x, y, z) }
    var normalized: Vector3D {
        let length = simd_length(simd)
        return length > 0 ? Vector3D(simd / length) : self
    }
}

struct AxisAlignedVolume: Codable, Equatable, Identifiable {
    var id: String
    /// Minimum corner in shelf-local centimetres: x=width, y=height, z=depth.
    var minimum: Vector3D
    var dimensions: PackageDimensions
    var maximum: Vector3D {
        Vector3D(minimum.x + dimensions.widthCM, minimum.y + dimensions.heightCM, minimum.z + dimensions.depthCM)
    }
}

enum ShelfObstacleKind: String, Codable { case wall, divider, support, lip, door, unknown }

struct ShelfObstacle: Codable, Equatable, Identifiable {
    var id: String
    var compartmentID: String?
    var kind: ShelfObstacleKind
    var volume: AxisAlignedVolume
}

struct ShelfCompartment: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var volume: AxisAlignedVolume
    var ratedWeightKG: Double?
}

struct StoredProductPlacement: Codable, Equatable, Identifiable {
    var id: String
    var productID: String
    var productType: String
    var compartmentID: String?
    var volume: AxisAlignedVolume
    var weightKG: Double?
    var priority: RetrievalPriority
    var retrievalFrequency: Double
    var stacking: StackingRules
    var supportingProductIDs: [String]
    var blockedProductIDs: [String]
}

struct ShelfLocalCoordinateSystem: Codable, Equatable {
    /// Origin and basis are stored in the shelf anchor's coordinate space.
    var anchorOrigin: Vector3D
    var widthAxis: Vector3D
    var upAxis: Vector3D
    var depthAxis: Vector3D

    init(anchorOrigin: Vector3D, widthAxis: Vector3D, upAxis: Vector3D, depthAxis: Vector3D) {
        self.anchorOrigin = anchorOrigin
        self.widthAxis = widthAxis.normalized
        self.upAxis = upAxis.normalized
        self.depthAxis = depthAxis.normalized
    }

    func localPoint(anchorPoint: Vector3D) -> Vector3D {
        let delta = anchorPoint.simd - anchorOrigin.simd
        return Vector3D(
            simd_dot(delta, widthAxis.simd),
            simd_dot(delta, upAxis.simd),
            simd_dot(delta, depthAxis.simd)
        )
    }
}

struct ShelfScanQuality: Codable, Equatable {
    var hasClosedBoundary: Bool
    var missingSurfaceCount: Int
    var trackingDriftCM: Double
    var confidence: Double
    var capturedAt: Date
}

enum ShelfShapeType: String, Codable, CaseIterable, Identifiable {
    case rectangle
    case likelyRectangle
    case irregularPolygon
    case uncertain

    var id: String { rawValue }
}

enum ShelfShapeIntent: String, Codable, CaseIterable, Identifiable {
    case automatic
    case rectangular
    case irregular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Let software determine"
        case .rectangular: "Rectangular"
        case .irregular: "Irregular"
        }
    }
}

enum ShelfBoundaryMeaning: String, Codable, CaseIterable, Identifiable {
    case innerUsable
    case opening
    case outer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .innerUsable: "Inner usable boundary"
        case .opening: "Shelf opening"
        case .outer: "Outer shelf boundary"
        }
    }
}

enum GeometryCorrectionReason: String, Codable, CaseIterable {
    case projectedToBestFitPlane
    case correctedNearRightAngle
    case correctedOppositeSideParallelism
    case correctedDiagonalMismatch
    case mergedNearDuplicatePoint
    case reorderedCrossingPolygon
    case refinedUsingRepeatedSamples
    case removedStatisticalOutlier
    case matchedExpectedDimensions

    var explanation: String {
        switch self {
        case .projectedToBestFitPlane: "Projected small elevation differences onto the best-fit shelf plane."
        case .correctedNearRightAngle: "Adjusted corners that were close to 90°."
        case .correctedOppositeSideParallelism: "Made opposite sides parallel."
        case .correctedDiagonalMismatch: "Balanced inconsistent diagonals."
        case .mergedNearDuplicatePoint: "Merged measurements of the same corner."
        case .reorderedCrossingPolygon: "Reordered an unambiguous crossing boundary."
        case .refinedUsingRepeatedSamples: "Used repeated stable samples instead of one raycast."
        case .removedStatisticalOutlier: "Rejected depth samples outside the robust surface cluster."
        case .matchedExpectedDimensions: "Applied user-provided trusted dimensions."
        }
    }
}

enum ShelfGeometryApproval: String, Codable {
    case draft
    case approvedRaw
    case approvedCorrection
    case approvedManual
}

enum ShelfGeometryUnit: String, Codable {
    case metres
    case centimetres
}

enum ShelfGeometryCoordinateSpace: String, Codable {
    case planeAnchorLocal
    case shelfLocal
}

struct ShelfCornerMeasurementMetadata: Codable, Equatable, Identifiable {
    var id: UUID
    var validSampleCount: Int
    var rejectedSampleCount: Int
    var spreadMetres: Double
    var capturedAt: Date
    var trackingWasNormal: Bool
    var usedLiDAR: Bool
}

struct ShelfMeasurementMetadata: Codable, Equatable {
    var capturedAt: Date
    var deviceModel: String
    var hasLiDAR: Bool
    var coordinateSpace: ShelfGeometryCoordinateSpace
    var unit: ShelfGeometryUnit
    var planeRMSResidualMetres: Double
    var planeMaximumResidualMetres: Double
    var cornerMeasurements: [ShelfCornerMeasurementMetadata]
    var expectedWidthCM: Double?
    var expectedDepthCM: Double?
}

struct ShelfGeometryRecord: Codable, Equatable {
    var version: Int
    var inputRevision: UUID
    /// Never mutated after capture.
    var rawBoundary: [Vector3D]
    /// A preview only until `approval` explicitly approves it.
    var correctedBoundary: [Vector3D]?
    var approvedBoundary: [Vector3D]
    var detectedShapeType: ShelfShapeType
    var requestedShapeIntent: ShelfShapeIntent
    var boundaryMeaning: ShelfBoundaryMeaning
    var correctionConfidence: Double
    var scanConfidence: Double
    var correctionReasons: [GeometryCorrectionReason]
    var approval: ShelfGeometryApproval
    var approvedAt: Date?
    var placementSafetyMarginCM: Double
    var measurementMetadata: ShelfMeasurementMetadata
    /// Open-space holes/exclusions in the same coordinate system and unit.
    var excludedRegions: [[Vector3D]]? = nil

    var isApproved: Bool {
        approval != .draft && approvedBoundary.count >= 3
    }
}

struct ShelfState: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var barcode: String
    var version: Int
    var boundary: AxisAlignedVolume
    var coordinateSystem: ShelfLocalCoordinateSystem
    /// Direction from the shelf opening toward the back, in shelf-local axes.
    var primaryFrontDirection: Vector3D
    var secondaryAccessDirections: [Vector3D]
    var compartments: [ShelfCompartment]
    var obstacles: [ShelfObstacle]
    var products: [StoredProductPlacement]
    var scanQuality: ShelfScanQuality
    /// Optional for backward compatibility with shelves saved before geometry
    /// review existed. New automatic placement requires an approved record.
    var geometry: ShelfGeometryRecord? = nil
    var ratedWeightKG: Double?
    var updatedAt: Date
}

struct PlacementToleranceConfiguration: Equatable {
    var minimumLinearToleranceCM: Double = 0.5
    var percentageTolerance: Double = 0.02
    var lowConfidenceMultiplier: Double = 1.75
    var insertionClearanceCM: Double = 2
    var retrievalClearanceCM: Double = 3
    var wallClearanceCM: Double = 1
    var stackClearanceCM: Double = 0.5
    static let warehouse = PlacementToleranceConfiguration()
}

struct ReachConfiguration: Equatable {
    var minimumPreferredHeightCM: Double = 70
    var maximumPreferredHeightCM: Double = 150
    var absoluteMaximumPlacementHeightCM: Double = 190
    var heavyProductMaximumHeightCM: Double? = 100
    static let warehouse = ReachConfiguration()
}

struct HandlingPolicy: Equatable {
    var heavyProductThresholdKG: Double? = 15
    var fragileProductsCannotSupportLoads = true
    var heavyProductsPreferLowerPlacement = true
    var heavyProductsRequireDirectFloorSupport = false
    var allowCriticalBlockingOverride = false
    static let warehouse = HandlingPolicy()
}

enum PlacementRejectionCode: String, Codable, Equatable {
    case outsideBoundary = "REJECT_OUTSIDE_BOUNDARY"
    case collision = "REJECT_COLLISION"
    case insufficientSupport = "REJECT_INSUFFICIENT_SUPPORT"
    case stackingRule = "REJECT_STACKING_RULE"
    case weightLimit = "REJECT_WEIGHT_LIMIT"
    case noInsertionPath = "REJECT_NO_INSERTION_PATH"
    case noRemovalPath = "REJECT_NO_REMOVAL_PATH"
    case criticalProductBlocked = "REJECT_CRITICAL_PRODUCT_BLOCKED"
    case staleShelfState = "REJECT_STALE_SHELF_STATE"
    case invalidOrientation = "REJECT_INVALID_ORIENTATION"
    case lowScanConfidence = "REJECT_LOW_SCAN_CONFIDENCE"
    case unstable = "REJECT_UNSTABLE"
}

struct PlacementRank: Codable, Equatable, Comparable {
    var criticalProductBlockingCount: Int
    var higherPriorityBlockingCost: Double
    var requiredMoveCount: Int
    var accessibilityScore: Double
    var safeHeightScore: Double
    var frontScore: Double
    var stabilityScore: Double
    var spaceEfficiencyScore: Double

    static func < (lhs: PlacementRank, rhs: PlacementRank) -> Bool {
        let l = [Double(-lhs.criticalProductBlockingCount), -lhs.higherPriorityBlockingCost,
                 Double(-lhs.requiredMoveCount), lhs.accessibilityScore, lhs.safeHeightScore,
                 lhs.frontScore, lhs.stabilityScore, lhs.spaceEfficiencyScore]
        let r = [Double(-rhs.criticalProductBlockingCount), -rhs.higherPriorityBlockingCost,
                 Double(-rhs.requiredMoveCount), rhs.accessibilityScore, rhs.safeHeightScore,
                 rhs.frontScore, rhs.stabilityScore, rhs.spaceEfficiencyScore]
        for (a, b) in zip(l, r) where a != b { return a < b }
        return false
    }
}

struct ProductPlacementResult: Codable, Equatable, Identifiable {
    var id: String
    var shelfID: String
    var compartmentID: String?
    var productID: String
    var shelfVersion: Int
    var position: Vector3D
    var quarterTurns: Int
    var orientedDimensions: PackageDimensions
    var supportSurfaceID: String?
    var supportingProductIDs: [String]
    var blockedProductIDs: [String]
    var insertionPath: [Vector3D]
    var removalPath: [Vector3D]
    var requiredMoves: [String]
    var confidence: Double
    var rank: PlacementRank
    var warnings: [String]
    var instructions: String
}

struct PlacementCandidateEvaluation: Equatable {
    var identifier: String
    var result: ProductPlacementResult?
    var rejectionReasons: [PlacementRejectionCode]
}

struct PlacementCalculation: Equatable {
    var recommendation: ProductPlacementResult?
    var alternatives: [ProductPlacementResult]
    var evaluations: [PlacementCandidateEvaluation]
    var failureMessage: String?
}

struct PlacementReservation: Codable, Equatable, Identifiable {
    var id: String
    var shelfID: String
    var productID: String
    var shelfVersion: Int
    var volume: AxisAlignedVolume
    var expiresAt: Date
    var createdBy: String
}
