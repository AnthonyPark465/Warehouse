import Foundation
import simd

enum BorderConfidenceLevel: String, Codable, Equatable, Comparable {
    case invalid, low, medium, high

    private var rank: Int {
        switch self {
        case .invalid: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

enum BorderObservationSource: String, Codable, Equatable {
    case smoothedSceneDepth
    case sceneDepth
    case planeBoundary
    case mesh
    case inferred
    case manual
}

enum BorderSegmentType: String, Codable, Equatable, Hashable {
    case dropEdge
    case planeIntersection
    case surfaceTermination
    case elevationChange
    case curvedEdge
    case inferred
    case manual
}

struct BorderObservation: Codable, Equatable, Identifiable {
    var id: UUID
    var worldPosition: Vector3D
    var localPosition: Vector2D
    var depthGradient: Double
    var normalDifference: Double
    var basePlaneDistance: Double
    var measurementDistance: Double
    var source: BorderObservationSource
    var segmentType: BorderSegmentType
    var trackingState: TrackingQualitySnapshot
    var confidence: Double
    var timestamp: Date
    var viewingDirection: Vector3D
}

struct DetectedBorderSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var rawObservations: [BorderObservation]
    var simplifiedPoints: [Vector2D]
    var segmentType: BorderSegmentType
    var confidence: Double
    var isInferred: Bool
    var isManuallyEdited: Bool
}

struct DetectedBorderCorner: Codable, Equatable, Identifiable {
    var id: UUID
    var localPosition: Vector2D
    var incomingSegmentID: UUID
    var outgoingSegmentID: UUID
    var angleRadians: Double
    var confidence: Double
    var isRoundedApproximation: Bool
    var isManuallyEdited: Bool
}

enum BoundaryValidationState: String, Codable, Equatable {
    case draft, valid, open, disconnected, selfIntersecting, zeroArea, excessiveUncertainty
}

struct BoundaryProcessingMetrics: Codable, Equatable {
    var maximumSimplificationDisplacementMetres: Double
    var averageSimplificationDisplacementMetres: Double
    var inferredGapLengthMetres: Double
    var manualEditCount: Int
}

struct ScannedStorageBoundary: Codable, Equatable, Identifiable {
    var id: UUID
    var basePlane: CodablePlane
    var surfaceType: SpaceSurfaceType
    var rawTrace: [BorderObservation]
    var detectedSegments: [DetectedBorderSegment]
    var detectedCorners: [DetectedBorderCorner]
    var simplifiedPolygon: [Vector2D]
    var approvedPolygon: [Vector2D]
    var suggestedPolygon: [Vector2D]?
    var geometryConfidence: Double
    var validationState: BoundaryValidationState
    var processingMetrics: BoundaryProcessingMetrics
    var measurementMethod: SpaceMeasurementMethod
    var deviceHasLiDAR: Bool
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date
    /// Accuracy-first schema v5 diagnostics. Nil means legacy accuracy is unknown.
    var shapeIntent: MeasurementShapeIntent? = nil
    var acquisitionSections: [BoundaryEdgeSection]? = nil
    var circleFit: CircleFitResult? = nil
    var dimensionUncertainties: [DimensionUncertainty]? = nil
    var approvalState: GeometryApprovalState? = nil
    var globalMapUncertaintyMetres: Double? = nil
    var localPlacementUncertaintyMetres: Double? = nil
    /// Schema v6 guided-corner evidence. Nil marks a legacy continuous/sectioned trace.
    var guidedCornerMeasurements: [GuidedCornerMeasurement]? = nil
    /// Schema v7 surface-first evidence. Nil identifies legacy corner/border capture and
    /// must never be interpreted as satisfying the surface-first accuracy standard.
    var surfaceFirstCompartment: SurfaceFirstCompartmentRecord? = nil
}

struct BorderDetectionEvidence: Equatable {
    var depthGradientMetres: Double
    var normalDifference: Double
    var basePlaneDistanceMetres: Double
    var measurementDistanceMetres: Double
    var validDepthSampleCount: Int
    var depthVariance: Double
    var persistenceFrames: Int
    var viewingAngleDiversity: Double
    var hasPlaneSupport: Bool
    var hasMeshSupport: Bool
    var surfaceContinuesBeyondEdge: Bool
    var missingDepthFraction: Double
    var trackingState: TrackingQualitySnapshot
    var surfaceType: SpaceSurfaceType
}

struct BorderDetectionResult: Equatable {
    var segmentType: BorderSegmentType?
    var confidence: Double
    var confidenceLevel: BorderConfidenceLevel
    var shouldCommit: Bool
}

protocol BorderDetectionEngine {
    func detectBorder(evidence: BorderDetectionEvidence) -> BorderDetectionResult
}

struct DefaultBorderDetectionEngine: BorderDetectionEngine {
    func detectBorder(evidence: BorderDetectionEvidence) -> BorderDetectionResult {
        guard evidence.trackingState == .normal,
              evidence.measurementDistanceMetres.isFinite,
              (0.10...4.0).contains(evidence.measurementDistanceMetres),
              evidence.basePlaneDistanceMetres.isFinite,
              evidence.basePlaneDistanceMetres <= 0.035,
              evidence.validDepthSampleCount >= 6,
              evidence.depthVariance.isFinite,
              evidence.depthVariance <= 0.04
        else { return .invalid }

        let type: BorderSegmentType?
        if evidence.surfaceContinuesBeyondEdge {
            type = nil // A product or internal obstacle is more likely than the outer edge.
        } else if evidence.depthGradientMetres >= threshold(for: evidence.surfaceType) {
            type = .dropEdge
        } else if evidence.normalDifference >= 0.45 && (evidence.hasPlaneSupport || evidence.hasMeshSupport) {
            type = .planeIntersection
        } else if evidence.missingDepthFraction >= 0.35 && evidence.hasPlaneSupport {
            type = .surfaceTermination
        } else if evidence.depthGradientMetres >= 0.025 && evidence.normalDifference >= 0.2 {
            type = .elevationChange
        } else {
            type = nil
        }
        guard let type else { return .invalid }

        let gradient = min(evidence.depthGradientMetres / 0.12, 1)
        let normal = min(evidence.normalDifference, 1)
        let samples = min(Double(evidence.validDepthSampleCount) / 30, 1)
        let persistence = min(Double(evidence.persistenceFrames) / 5, 1)
        let support = (evidence.hasPlaneSupport ? 0.55 : 0) + (evidence.hasMeshSupport ? 0.25 : 0)
        let view = min(evidence.viewingAngleDiversity / 0.5, 1)
        let distance = max(0, 1 - max(0, evidence.measurementDistanceMetres - 2) / 2)
        let variance = max(0, 1 - evidence.depthVariance / 0.04)
        let confidence = min(0.98,
            gradient * 0.22 + normal * 0.10 + samples * 0.12 + persistence * 0.22
                + support * 0.12 + view * 0.07 + distance * 0.07 + variance * 0.08
        )
        let level: BorderConfidenceLevel = confidence >= 0.78 ? .high
            : confidence >= 0.55 ? .medium
            : confidence >= 0.30 ? .low : .invalid
        return BorderDetectionResult(
            segmentType: type,
            confidence: confidence,
            confidenceLevel: level,
            shouldCommit: level >= .medium && evidence.persistenceFrames >= 3
        )
    }

    private func threshold(for surface: SpaceSurfaceType) -> Double {
        switch surface {
        case .floor: 0.10
        case .shelf, .tabletop, .workbench, .platform, .counter: 0.055
        case .customHorizontalSurface, .unknown: 0.075
        }
    }
}

private extension BorderDetectionResult {
    static var invalid: Self {
        .init(segmentType: nil, confidence: 0, confidenceLevel: .invalid, shouldCommit: false)
    }
}

struct BorderTraceConfiguration: Equatable {
    var minimumPointSpacingMetres = 0.012
    var duplicateMergeDistanceMetres = 0.025
    var maximumFrameMovementMetres = 0.18
    var closureDistanceMetres = 0.10
    var maximumInterpolatedGapMetres = 0.06
    var simplificationToleranceMetres = 0.012
    var minimumAreaSquareMetres = 0.01
    var cornerAngleDegrees = 24.0

    static let standard = Self()
}

protocol BorderTraceBuilding: AnyObject {
    var observations: [BorderObservation] { get }
    func begin(at observation: BorderObservation, type: BorderSegmentType)
    func add(_ observation: BorderObservation, type: BorderSegmentType)
    func undoLastSection()
    func reset()
}

final class DefaultBorderTraceBuilder: BorderTraceBuilding {
    private(set) var observations: [BorderObservation] = []
    private(set) var segmentTypes: [BorderSegmentType] = []
    let configuration: BorderTraceConfiguration

    init(configuration: BorderTraceConfiguration = .standard) {
        self.configuration = configuration
    }

    func begin(at observation: BorderObservation, type: BorderSegmentType) {
        guard observations.isEmpty else { return }
        observations = [observation]
        segmentTypes = [type]
    }

    func add(_ observation: BorderObservation, type: BorderSegmentType) {
        guard let last = observations.last else {
            begin(at: observation, type: type)
            return
        }
        let distance = simd_distance(last.localPosition.simd, observation.localPosition.simd)
        guard distance.isFinite,
              distance >= configuration.minimumPointSpacingMetres,
              distance <= configuration.maximumFrameMovementMetres else { return }

        // Repeated passes reinforce an existing location instead of creating duplicate edges.
        if let match = observations.indices.dropLast().min(by: {
            simd_distance(observations[$0].localPosition.simd, observation.localPosition.simd)
                < simd_distance(observations[$1].localPosition.simd, observation.localPosition.simd)
        }), simd_distance(observations[match].localPosition.simd, observation.localPosition.simd)
            <= configuration.duplicateMergeDistanceMetres {
            let previous = observations[match]
            let total = max(previous.confidence + observation.confidence, 0.001)
            let merged = (previous.localPosition.simd * previous.confidence
                + observation.localPosition.simd * observation.confidence) / total
            observations[match].localPosition = Vector2D(merged)
            observations[match].confidence = min(0.99, max(previous.confidence, observation.confidence) + 0.05)
            return
        }
        observations.append(observation)
        segmentTypes.append(type)
    }

    func undoLastSection() {
        guard !observations.isEmpty else { return }
        let removeCount = min(6, observations.count)
        observations.removeLast(removeCount)
        segmentTypes.removeLast(min(removeCount, segmentTypes.count))
    }

    func reset() {
        observations.removeAll()
        segmentTypes.removeAll()
    }
}

struct BoundaryProcessingResult: Equatable {
    var filtered: [Vector2D]
    var simplified: [Vector2D]
    var segments: [DetectedBorderSegment]
    var corners: [DetectedBorderCorner]
    var confidence: Double
    var validationState: BoundaryValidationState
    var metrics: BoundaryProcessingMetrics
}

protocol BoundaryProcessing {
    func process(
        observations: [BorderObservation],
        configuration: BorderTraceConfiguration
    ) -> BoundaryProcessingResult
}

struct DefaultBoundaryProcessor: BoundaryProcessing {
    func process(
        observations: [BorderObservation],
        configuration: BorderTraceConfiguration = .standard
    ) -> BoundaryProcessingResult {
        let finite = observations.filter {
            let p = $0.localPosition.simd
            return p.x.isFinite && p.y.isFinite && $0.confidence >= 0.30
        }
        let filtered = spatialMedian(finite.map(\.localPosition))
        let rawValidation = validate(filtered, minimumArea: configuration.minimumAreaSquareMetres)
        var simplified = simplify(filtered, tolerance: configuration.simplificationToleranceMetres)
        if let first = simplified.first, let last = simplified.last,
           simd_distance(first.simd, last.simd) <= configuration.closureDistanceMetres {
            simplified.removeLast()
        }
        // Simplification may never be used to hide a major raw-geometry error.
        let validation = rawValidation == .valid
            ? validate(simplified, minimumArea: configuration.minimumAreaSquareMetres)
            : rawValidation
        let displacement = filtered.map { point in
            simplified.map { simd_distance(point.simd, $0.simd) }.min() ?? 0
        }
        let metrics = BoundaryProcessingMetrics(
            maximumSimplificationDisplacementMetres: displacement.max() ?? 0,
            averageSimplificationDisplacementMetres: displacement.isEmpty
                ? 0 : displacement.reduce(0, +) / Double(displacement.count),
            inferredGapLengthMetres: 0,
            manualEditCount: 0
        )
        let confidence = finite.isEmpty ? 0
            : finite.map(\.confidence).reduce(0, +) / Double(finite.count)
        let segments = makeSegments(observations: finite, points: simplified, confidence: confidence)
        let corners = makeCorners(segments: segments, points: simplified, thresholdDegrees: configuration.cornerAngleDegrees)
        return BoundaryProcessingResult(
            filtered: filtered,
            simplified: simplified,
            segments: segments,
            corners: corners,
            confidence: validation == .valid ? confidence : min(confidence, 0.35),
            validationState: validation,
            metrics: metrics
        )
    }

    private func spatialMedian(_ points: [Vector2D]) -> [Vector2D] {
        // Sparse traces are already corner candidates. Median filtering them can
        // erase a real concavity or accidentally repair a crossing, so only
        // smooth dense continuous traces.
        guard points.count >= 8 else { return points }
        return points.indices.map { index in
            guard index > 0, index < points.count - 1 else { return points[index] }
            let xs = [points[index - 1].x, points[index].x, points[index + 1].x].sorted()
            let ys = [points[index - 1].y, points[index].y, points[index + 1].y].sorted()
            return Vector2D(xs[1], ys[1])
        }
    }

    private func simplify(_ points: [Vector2D], tolerance: Double) -> [Vector2D] {
        guard points.count > 2 else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifyRange(points, first: 0, last: points.count - 1, tolerance: tolerance, keep: &keep)
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    private func simplifyRange(
        _ points: [Vector2D], first: Int, last: Int, tolerance: Double, keep: inout [Bool]
    ) {
        guard last > first + 1 else { return }
        var greatest = 0.0
        var greatestIndex = first
        for index in (first + 1)..<last {
            let distance = pointSegmentDistance(points[index].simd, points[first].simd, points[last].simd)
            if distance > greatest { greatest = distance; greatestIndex = index }
        }
        if greatest > tolerance {
            keep[greatestIndex] = true
            simplifyRange(points, first: first, last: greatestIndex, tolerance: tolerance, keep: &keep)
            simplifyRange(points, first: greatestIndex, last: last, tolerance: tolerance, keep: &keep)
        }
    }

    private func validate(_ points: [Vector2D], minimumArea: Double) -> BoundaryValidationState {
        guard points.count >= 3 else { return .open }
        let unique = points.enumerated().filter { index, point in
            !points[..<index].contains { simd_distance($0.simd, point.simd) < 0.005 }
        }
        guard unique.count >= 3 else { return .disconnected }
        for first in points.indices {
            let nextFirst = (first + 1) % points.count
            for second in points.indices where second > first + 1 {
                let nextSecond = (second + 1) % points.count
                if first == 0 && nextSecond == 0 { continue }
                if segmentsIntersect(points[first].simd, points[nextFirst].simd,
                                     points[second].simd, points[nextSecond].simd) {
                    return .selfIntersecting
                }
            }
        }
        var twiceArea = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            twiceArea += points[index].x * next.y - next.x * points[index].y
        }
        let area = abs(twiceArea) / 2
        guard area >= minimumArea else { return .zeroArea }
        return .valid
    }

    private func makeSegments(
        observations: [BorderObservation], points: [Vector2D], confidence: Double
    ) -> [DetectedBorderSegment] {
        guard points.count >= 2 else { return [] }
        return points.indices.map { index in
            let next = (index + 1) % points.count
            let supporting = observations.filter {
                pointSegmentDistance(
                    $0.localPosition.simd, points[index].simd, points[next].simd
                ) <= 0.04
            }
            let dominantType = Dictionary(grouping: supporting, by: \.segmentType)
                .max { $0.value.count < $1.value.count }?.key ?? .inferred
            return DetectedBorderSegment(
                id: UUID(), rawObservations: supporting,
                simplifiedPoints: [points[index], points[next]],
                segmentType: dominantType,
                confidence: supporting.isEmpty ? confidence : supporting.map(\.confidence).reduce(0, +) / Double(supporting.count),
                isInferred: false, isManuallyEdited: false
            )
        }
    }

    private func makeCorners(
        segments: [DetectedBorderSegment], points: [Vector2D], thresholdDegrees: Double
    ) -> [DetectedBorderCorner] {
        guard points.count >= 3, segments.count == points.count else { return [] }
        return points.indices.compactMap { index in
            let previous = points[(index - 1 + points.count) % points.count].simd
            let current = points[index].simd
            let next = points[(index + 1) % points.count].simd
            let a = simd_normalize(previous - current)
            let b = simd_normalize(next - current)
            let angle = acos(max(-1, min(1, simd_dot(a, b))))
            let turn = abs(.pi - angle) * 180 / .pi
            guard turn >= thresholdDegrees else { return nil }
            return DetectedBorderCorner(
                id: UUID(), localPosition: points[index],
                incomingSegmentID: segments[(index - 1 + segments.count) % segments.count].id,
                outgoingSegmentID: segments[index].id,
                angleRadians: angle,
                confidence: min(segments[index].confidence,
                                segments[(index - 1 + segments.count) % segments.count].confidence),
                isRoundedApproximation: turn < 40,
                isManuallyEdited: false
            )
        }
    }

    private func pointSegmentDistance(
        _ point: SIMD2<Double>, _ start: SIMD2<Double>, _ end: SIMD2<Double>
    ) -> Double {
        let delta = end - start
        let denominator = simd_length_squared(delta)
        guard denominator > 1e-12 else { return simd_distance(point, start) }
        let t = max(0, min(1, simd_dot(point - start, delta) / denominator))
        return simd_distance(point, start + delta * t)
    }

    private func segmentsIntersect(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>
    ) -> Bool {
        func cross(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Double {
            let pq = q - p, pr = r - p
            return pq.x * pr.y - pq.y * pr.x
        }
        let epsilon = 1e-9
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        return ((abC > epsilon && abD < -epsilon) || (abC < -epsilon && abD > epsilon))
            && ((cdA > epsilon && cdB < -epsilon) || (cdA < -epsilon && cdB > epsilon))
    }
}

struct BorderScanSnapshot: Equatable {
    var state: OpenSpaceBorderScanState = .checkingDeviceSupport
    var status = "Checking device"
    var confidenceLevel: BorderConfidenceLevel = .invalid
    var confidence: Double = 0
    var tracePointCount = 0
    var canFinish = false
    var isPaused = false
    var lastError: OpenSpaceScanError?
    var acquisitionPhase: BoundaryAcquisitionPhase = .findingEdgeStart
    var currentEdgeIndex = 0
    var confirmedEdgeCount = 0
    var hasCornerProposal = false
    var currentEdgeUncertaintyMetres: Double?
    var measurementUse: MeasurementUse?
    var guidedState: GuidedCornerAcquisitionState = .findingBasePlane
    var candidate: GuidedCornerMeasurement?
    var acceptedCornerCount = 0
    var selectedCornerIndex: Int?
    var scanProgress: Double = 0
    var surfaceFirstState: SurfaceFirstAcquisitionState?
    var activeSurface: CompartmentSurface?
    var acceptedSurfaces: [CompartmentSurface] = []
    var surfaceCandidate: SurfaceCaptureRecord?
    var targetVolume: LocalTargetVolume?
    var calculatedCorners: [CompartmentCornerEvidence] = []
    var compartmentDimensions: CompartmentDimensions?
}
