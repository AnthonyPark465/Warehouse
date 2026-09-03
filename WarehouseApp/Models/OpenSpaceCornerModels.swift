import Foundation

enum SpaceMeasurementMethod: String, Codable, Equatable {
    case markerBoundaries
    case lidarBorderScan
    case lidarSectionedEdgeScan
    case standardARBorderScan
    case robustCircleScan
    case fittedCompartmentPlanes
    case overlappingZoneScan
    case lidarCornerPlacement
    case standardARCornerPlacement
    case legacyAreaScan
}

enum TrackingQualitySnapshot: String, Codable, Equatable {
    case normal, limited, unavailable
}

enum OpenSpaceScanError: Error, LocalizedError, Equatable {
    case lidarUnavailable
    case cameraPermissionDenied
    case trackingUnavailable
    case baseSurfaceNotFound
    case borderNotFound
    case borderLost
    case insufficientBorderData
    case insufficientDepthSamples
    case unstableMeasurement
    case invalidDepth
    case pointOutOfRange
    case inconsistentCoordinateSystem
    case inconsistentSurfaceHeight
    case disconnectedBoundary
    case boundaryNotClosed
    case duplicateCorner
    case edgeTooShort
    case selfIntersectingPolygon
    case zeroAreaPolygon
    case invalidHeight
    case invalidExcludedRegion
    case geometryConfidenceTooLow
    case excessiveInference
    case saveFailed
    case sessionInterrupted

    var errorDescription: String? {
        switch self {
        case .lidarUnavailable: "LiDAR is unavailable. Use the clearly labelled lower-confidence AR mode or cancel."
        case .cameraPermissionDenied: "Camera permission is required to measure corners."
        case .trackingUnavailable: "Tracking is limited. Hold still and keep previously viewed surfaces visible."
        case .baseSurfaceNotFound: "Aim at the horizontal storage surface until its base plane is detected."
        case .borderNotFound: "No persistent physical border was detected near the reticle."
        case .borderLost: "The edge was lost. Return to the last confirmed endpoint to resume."
        case .insufficientBorderData: "Scan more of the physical border before finishing."
        case .insufficientDepthSamples: "Hold still while more depth samples are collected."
        case .unstableMeasurement: "Depth is inconsistent. Aim at one visible corner and hold still."
        case .invalidDepth: "No valid depth was returned at the reticle."
        case .pointOutOfRange: "Move within the supported measurement range."
        case .inconsistentCoordinateSystem: "Tracking relocalized. Restart the boundary to avoid mixing coordinate spaces."
        case .inconsistentSurfaceHeight: "The corner is not on the locked base surface."
        case .disconnectedBoundary: "The detected border contains disconnected sections. Rescan the highlighted gap."
        case .boundaryNotClosed: "The border does not close consistently. Scan back to the starting point or add a repair segment."
        case .duplicateCorner: "That corner has already been placed."
        case .edgeTooShort: "The new edge is too short to measure reliably."
        case .selfIntersectingPolygon: "The closing edge crosses the boundary. Rescan the affected corner."
        case .zeroAreaPolygon: "The boundary has no usable area."
        case .invalidHeight: "Enter or measure a finite positive height above the base surface."
        case .invalidExcludedRegion: "An excluded region has invalid geometry."
        case .geometryConfidenceTooLow: "Geometry confidence is too low to save."
        case .excessiveInference: "Too much of this boundary is inferred. Rescan the missing physical edges."
        case .saveFailed: "The storage space could not be saved."
        case .sessionInterrupted: "The AR session was interrupted."
        }
    }
}

enum OpenSpaceScanState: Equatable {
    case idle
    case checkingDeviceSupport
    case initializingSession
    case measuringCorner(index: Int)
    case cornerReady(index: Int)
    case validatingCorner(index: Int)
    case reviewingBoundary
    case correctingBoundary
    case measuringHeight
    case selectingAccessDirection
    case previewingVolume
    case saving
    case completed
    case failed(OpenSpaceScanError)
}

/// Active open-space acquisition is deliberately corner based. Legacy border-trace
/// states remain below only so older saved scans and diagnostics can still decode.
enum GuidedCornerAcquisitionState: Equatable {
    case findingBasePlane
    case aiming(index: Int)
    case scanning(index: Int, progress: Double)
    case candidateReady(index: Int)
    case reviewingBoundary
    case correcting(index: Int)
    case closingShape
    case measuringHeight
    case selectingAccessDirection
    case completed
    case failed(OpenSpaceScanError)
}

enum CornerEstimatorKind: String, Codable, Equatable {
    case tabletopTerminationEdges
    case compartmentPlaneIntersection
    case manualMultiFrame
}

enum CornerObservationProvenance: String, Codable, Equatable {
    case directlyObserved
    case inferredFromSupportingGeometry
    case manualFallback
    case legacyUnknown
}

enum CornerCandidateApproval: String, Codable, Equatable {
    case candidate, accepted, rejected, replaced
}

struct LocalCornerPatchSample: Codable, Equatable, Identifiable {
    var id: UUID
    /// Point in the locked base-plane coordinate system (metres).
    var localPosition: Vector3D
    var cameraPositionLocal: Vector3D
    var timestamp: TimeInterval
    var frameSequence: Int
    var trackingState: TrackingQualitySnapshot
    var depthConfidence: Double
}

struct FittedCornerEdge: Codable, Equatable {
    var line: LineFit2D
    var supportingSampleIDs: [UUID]
}

struct GuidedCornerMeasurement: Codable, Equatable, Identifiable {
    var id: UUID
    var acceptedLocalPosition: Vector2D
    var originalCandidatePosition: Vector2D
    var estimator: CornerEstimatorKind
    var provenance: CornerObservationProvenance
    var approval: CornerCandidateApproval
    var uncertaintyMetres: Double
    var rmsResidualMetres: Double
    var maximumResidualMetres: Double
    var spatialCoverageMetres: Double
    var independentFrameCount: Int
    var viewingAngleDiversityRadians: Double
    var measurementDistanceMetres: Double
    var trackingState: TrackingQualitySnapshot
    var fittedEdges: [FittedCornerEdge]
    var fittedPlanes: [FittedCompartmentPlane]
    /// Bounded diagnostic evidence; production persistence must cap this array.
    var diagnosticSamples: [LocalCornerPatchSample]
    var coordinateSpace: ShelfGeometryCoordinateSpace
    var coordinateEpoch: UUID
    var schemaVersion: Int
    var capturedAt: Date
}

enum OpenSpaceBorderScanState: Equatable {
    case idle
    case checkingDeviceSupport
    case initializingSession
    case findingBaseSurface
    case searchingForBorder
    case borderCandidateDetected
    case tracingBorder
    case reviewingEdge
    case confirmingProposedCorner
    case startingNextEdge
    case rescanningSection
    case closingBoundary
    case borderLost
    case boundaryNearlyClosed
    case processingBoundary
    case reviewingBoundary
    case editingBoundary
    case measuringHeight
    case selectingAccessDirection
    case previewingVolume
    case saving
    case completed
    case failed(OpenSpaceScanError)
}

struct CornerMeasurementTelemetry: Equatable {
    var source: CornerMeasurementSource = .unknown
    var tracking: TrackingQualitySnapshot = .unavailable
    var distanceMetres: Double?
    var surfaceHeightDifferenceMetres: Double?
    var sampleCount = 0
    var confidence: Double?
}

struct MeasuredSpaceCornerRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var originalWorldPosition: Vector3D
    var projectedWorldPosition: Vector3D
    var localBoundaryPositionMetres: Vector2D
    var sampleCount: Int
    var positionalVariance: Double
    var depthVariance: Double
    var projectionDistance: Double
    var measurementDistance: Double
    var measurementSource: CornerMeasurementSource
    var trackingState: TrackingQualitySnapshot
    var confidenceScore: Double
    var timestamp: Date
    /// Nil on legacy records; callers must not infer fitted-LiDAR accuracy from nil.
    var estimatorKind: CornerEstimatorKind? = nil
    var provenance: CornerObservationProvenance? = nil
    var estimatedUncertaintyMetres: Double? = nil
    var approval: CornerCandidateApproval? = nil
    var coordinateEpoch: UUID? = nil
    var schemaVersion: Int? = nil
}
