import Foundation

/// Machine-readable outcome codes. Each belongs to exactly one category so a
/// stored record can be interpreted without the code that produced it.
enum LiDARMeasurementReasonCode: String, Codable, CaseIterable {
    // Failures: the evidence does not support a measurement.
    case noSelectionLocked
    case insufficientAcceptedFrames
    case trackingNotNormal
    case insufficientStableGeometry
    case insufficientGeometryAboveSupport
    case supportPlaneNotFound
    case noObjectNearSeed
    case insufficientConnectedGeometry
    case degenerateBounds
    case regionBoundaryContact
    case insufficientViewpoints
    case dimensionsUnstable
    case excessiveUncertainty
    /// The newest frame had no depth inside the region: the product is no
    /// longer being observed, so earlier evidence is not current.
    case productNotInView
    /// The selected shape contains an internal wall: most likely two objects
    /// too close for the voxel grid to separate.
    case possibleMergedObjects
    /// The detected "support" lies wholly under the product, so it may be
    /// the product's own underside or a ledge: the height has no base.
    case supportNotBeyondFootprint
    /// The selected geometry floats well above the detected surface, so
    /// that surface (a lower shelf, the floor) is not what it stands on.
    case objectNotOnSupport
    /// Repeated geometry lies below the detected surface. A real support
    /// has nothing under it inside the region, so the detected plane is a
    /// ledge of the product or the wrong surface.
    case geometryBelowSupport
    /// The selection was bridged from fragments, and comparably many more
    /// fragments lie just beyond bridging reach: most likely a piece of a
    /// surface that returned depth only in patches.
    case possiblePartialObject

    // Warnings: a measurement exists but must be qualified.
    case nearbyObjectClose
    case supportPlaneNoisy
    case sparseSideCoverage
    case topSurfaceSparse
    case viewpointCoverageUnknown
    case evidenceInvalidatedByTrackingReset
    case sustainedDimensionJump
    /// Briefly seen geometry was dropped as stale; if it was part of the
    /// product, the measurement is now short on that side.
    case weakGeometryExpired
    /// Loose fragments beside the selection were left out; if they belong
    /// to the product, that side is short.
    case fragmentsExcluded

    // Fallbacks: a secondary method produced the result.
    case expandedConnectivityUsed

    enum Category: String, Codable {
        case failure
        case warning
        case fallback
    }

    var category: Category {
        switch self {
        case .noSelectionLocked, .insufficientAcceptedFrames, .trackingNotNormal,
             .insufficientStableGeometry, .insufficientGeometryAboveSupport,
             .supportPlaneNotFound, .noObjectNearSeed, .insufficientConnectedGeometry,
             .degenerateBounds, .regionBoundaryContact, .insufficientViewpoints,
             .dimensionsUnstable, .excessiveUncertainty, .productNotInView,
             .possibleMergedObjects, .possiblePartialObject,
             .supportNotBeyondFootprint, .objectNotOnSupport, .geometryBelowSupport:
            .failure
        case .nearbyObjectClose, .supportPlaneNoisy, .sparseSideCoverage, .topSurfaceSparse, .viewpointCoverageUnknown,
             .evidenceInvalidatedByTrackingReset, .sustainedDimensionJump,
             .weakGeometryExpired, .fragmentsExcluded:
            .warning
        case .expandedConnectivityUsed:
            .fallback
        }
    }
}

enum LiDARAcceptanceStatus: String, Codable {
    /// No failure, warning or fallback.
    case accepted
    /// Usable, but stored and shown with its warnings and fallbacks.
    case qualified
    /// The evidence does not support a measurement; nothing is saved.
    case refused
}

struct LiDARAcceptanceDecision: Codable, Equatable {
    var status: LiDARAcceptanceStatus
    var failures: [LiDARMeasurementReasonCode]
    var warnings: [LiDARMeasurementReasonCode]
    var fallbacks: [LiDARMeasurementReasonCode]

    static let notStarted = LiDARAcceptanceDecision(
        status: .refused,
        failures: [.insufficientAcceptedFrames],
        warnings: [],
        fallbacks: []
    )

    var allowsFinish: Bool { status != .refused }
}

enum LiDARTrackingQuality: String, Codable {
    case normal
    case limited
    /// ARKit is re-establishing its map; the world origin may move.
    case relocalizing
    case notAvailable
}

enum LiDARDepthSource: String, Codable {
    case sceneDepth
    case featurePoints
    case unspecified
}

enum LiDARFrameRejectionReason: String, Codable {
    case noSelectionLocked
    case trackingNotNormal
    /// Not finite, or not later than the previous frame.
    case invalidTimestamp
    /// Sooner than the minimum frame spacing after the previous frame.
    case tooSoonAfterPreviousFrame
    case noPointsInRegion
}

struct LiDARFrameEvidence: Codable, Equatable {
    var capturedFrameCount = 0
    var acceptedFrameCount = 0
    /// Accepted frames contributing to the current evidence, i.e. since the
    /// last coordinate reset.
    var acceptedFrameCountSinceReset = 0
    var rejectedFrameCounts: [String: Int] = [:]
    var trackingNormalFrameCount = 0
    var coordinateResetCount = 0
    var depthSource = LiDARDepthSource.unspecified
    /// Depth-map samples examined before any filtering, when the capture
    /// layer reports them.
    var examinedDepthSampleCount = 0
    var lowConfidenceSampleCount = 0
    var outOfRangeSampleCount = 0
    var highConfidenceSampleCount = 0
    var nonFiniteSampleCount = 0
    var outsideRegionSampleCount = 0
    var inRegionSampleCount = 0
    /// In-region samples merged into a voxel already observed in the same frame.
    var duplicateSampleCount = 0
}

struct LiDARVoxelEvidence: Codable, Equatable {
    var totalVoxelCount = 0
    var stableVoxelCount = 0
    /// Voxels below the multi-frame observation minimum.
    var transientVoxelCount = 0
    /// Weakly observed voxels removed because they were not seen again.
    var expiredVoxelCount = 0
    /// Expired voxels that had already passed the multi-frame filter.
    var expiredStableVoxelCount = 0
    var meanObservationsPerStableVoxel = 0.0
}

struct LiDARSupportPlaneEvidence: Codable, Equatable {
    /// Plane height along the region's vertical axis, relative to its origin.
    var coordinateMetres: Double
    var worldHeightMetres: Double
    var method: String
    var inlierCount: Int
    /// One-sided robust noise estimate; nil when no plane was detected.
    var residualMetres: Double?
    var removalBandMetres: Double
    var removalBandWasCapped: Bool
    /// Support voxels lying outside the product footprint.
    var voxelsBeyondFootprint: Int?
    /// Height of the lowest selected voxel above the removed band.
    var contactGapMetres: Double?
    /// Stable voxels lying below the plane by more than its removal band.
    var voxelsBelowSupport: Int?
}

struct LiDARComponentStatistics: Codable, Equatable {
    var voxelCount: Int
    var seedDistanceMetres: Double
    /// Nearest distance to the selected component; nil when beyond the
    /// proximity-warning distance.
    var gapToSelectedMetres: Double?
    var qualifiesAsObject: Bool
}

struct LiDARComponentEvidence: Codable, Equatable {
    var connectivityMode: String
    var fallbackReason: String?
    var strictRadiusInVoxels: Int
    var expandedRadiusInVoxels: Int
    var selected: LiDARComponentStatistics
    var absorbedFragmentCount: Int
    var absorbedVoxelCount: Int
    var rejectedComponentCount: Int
    var rejectedVoxelCount: Int
    var rejected: [LiDARComponentStatistics]
    /// Voxels in loose fragments beside the selection that were left out.
    var looseFragmentVoxelCount: Int
    /// Voxel pairs within bridging reach that were not joined because the
    /// space between them was observed to be empty. Nil when free-space
    /// gating did not run.
    var freeSpaceBlockedBridgeCount: Int?
    /// Voxels in rejected fragment groups within the proximity-warning
    /// distance of the selection. Nil in records made before it was added.
    var nearbyFragmentVoxelCount: Int?
}

/// What the free-space grid held when the result was produced. Present only
/// when free-space gating is enabled.
struct LiDARFreeSpaceEvidence: Codable, Equatable {
    /// False when gating was enabled but could not run: the region was too
    /// large to track, or no frame carried a camera position.
    var wasAvailable: Bool
    /// Depth rays that crossed the region.
    var rayCount: Int
    /// Voxels seen through in at least one frame.
    var observedVoxelCount: Int
    var minimumFrameObservations: Int
    var carveMarginMetres: Double
}

struct LiDARBoundsEvidence: Codable, Equatable {
    var yawDegrees: Double
    /// Percentile-trimmed extents before quantization compensation.
    var trimmedExtentsCM: ObjectDimensions
    /// Untrimmed minimum-to-maximum extents.
    var fullExtentsCM: ObjectDimensions
    /// Trimmed extents plus quantization compensation: the raw measurement.
    var measuredDimensionsCM: ObjectDimensions
}

struct LiDARBoundaryContact: Codable, Equatable {
    var face: String
    var voxelCount: Int
}

struct LiDARCoverageEvidence: Codable, Equatable {
    /// Arc of camera azimuths around the seed; nil when camera poses were
    /// not supplied.
    var viewpointSpanDegrees: Double?
    var viewpointFrameCount: Int
    /// Occupied fraction of each footprint side: low/high along the length
    /// axis, then low/high along the width axis.
    var sideSupportFractions: [Double]
    var sparseSideCount: Int
    var topCoverageFraction: Double
    /// A dense vertical sheet was found inside the footprint.
    var interiorPartitionDetected: Bool
}

struct LiDARStabilityEvidence: Codable, Equatable {
    var state: String
    var estimateCount: Int
    var consistentEstimateCount: Int
    /// Per-axis range across the consistent estimates.
    var spreadCM: ObjectDimensions?
    var jumpDetected: Bool
    var sustainedJumpAdopted: Bool
}

/// Technical record of how one scan result was produced. Stored with the
/// product so a measurement can be audited without the point cloud.
struct LiDARMeasurementEvidence: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = LiDARMeasurementEvidence.currentSchemaVersion
    var frames = LiDARFrameEvidence()
    var voxels = LiDARVoxelEvidence()
    var supportPlane: LiDARSupportPlaneEvidence?
    var components: LiDARComponentEvidence?
    var freeSpace: LiDARFreeSpaceEvidence?
    var bounds: LiDARBoundsEvidence?
    var boundaryContacts: [LiDARBoundaryContact] = []
    var coverage: LiDARCoverageEvidence?
    var stability: LiDARStabilityEvidence?
    /// The dimensions offered to the user: the stable representative estimate
    /// when one exists, otherwise the latest estimate.
    var reportedDimensionsCM: ObjectDimensions?
    /// Heuristic per-axis uncertainty. Not calibrated against ground truth.
    var uncertaintyCM: ObjectDimensions?
    var decision = LiDARAcceptanceStatus.refused.rawValue
    var failureCodes: [String] = []
    var warningCodes: [String] = []
    var fallbackCodes: [String] = []
    /// Application-level coverage and stability indicator in 0...1. It is
    /// not a probability that the dimensions are correct.
    var coverageScore = 0.0
}
