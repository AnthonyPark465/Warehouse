import Foundation
import simd

struct ShelfPointSamplingConfiguration: Equatable {
    var windowSeconds = 0.8
    var minimumLiDARSamples = 7
    var minimumStandardARSamples = 11
    var maximumLiDARSpreadMetres = 0.008
    var maximumStandardARSpreadMetres = 0.012
    var minimumDistanceMetres = 0.10
    var maximumDistanceMetres = 4.0
    var depthClusterGapMetres = 0.03
    var minimumClusterSamples = 3

    /// A corner may be projected onto the locked base surface only within this distance.
    var maximumSurfaceProjectionMetres = 0.025
    /// Reject a sample stream when the camera pose jumps this far between frames.
    var maximumCameraTranslationPerFrameMetres = 0.12
    var maximumCameraRotationPerFrameDegrees = 12.0

    static let shelf = ShelfPointSamplingConfiguration()
}

struct ShelfPointSample: Equatable {
    let position: SIMD3<Double>
    let cameraDistanceMetres: Double
    let timestamp: TimeInterval
    let trackingConfidence: Double
    let hasLiDARDepth: Bool
    var source: CornerMeasurementSource = .unknown
}

enum CornerMeasurementSource: String, Codable, Equatable {
    case smoothedSceneDepth
    case sceneDepth
    case existingPlaneRaycast
    case estimatedPlaneRaycast
    case featurePointRaycast
    case unknown

    var reliability: Double {
        switch self {
        case .smoothedSceneDepth: 1
        case .sceneDepth: 0.92
        case .existingPlaneRaycast: 0.78
        case .estimatedPlaneRaycast: 0.62
        case .featurePointRaycast: 0.48
        case .unknown: 0.25
        }
    }
}

enum ShelfPointStability: String, Equatable {
    case searching = "Searching for surface"
    case lowConfidence = "Low confidence"
    case holdStill = "Hold still"
    case stable = "Stable"
    case ready = "Ready to place"
}

struct ShelfPointEstimate: Equatable {
    let position: SIMD3<Double>?
    let stability: ShelfPointStability
    let message: String
    let validSampleCount: Int
    let rejectedSampleCount: Int
    let spreadMetres: Double
    let confidence: Double
    let depthVariance: Double
    let measurementDistanceMetres: Double
    let source: CornerMeasurementSource

    var canPlace: Bool { stability == .ready && position != nil }
}

enum ShelfPointEstimator {
    static func estimate(
        samples: [ShelfPointSample],
        hasLiDAR: Bool,
        configuration: ShelfPointSamplingConfiguration = .shelf
    ) -> ShelfPointEstimate {
        guard let newest = samples.map(\.timestamp).max() else {
            return unavailable(.searching, "Move the reticle onto a visible shelf surface.")
        }
        let recent = samples.filter {
            newest - $0.timestamp <= configuration.windowSeconds
                && $0.timestamp <= newest
                && finite($0.position)
                && $0.cameraDistanceMetres.isFinite
                && $0.cameraDistanceMetres >= configuration.minimumDistanceMetres
                && $0.cameraDistanceMetres <= configuration.maximumDistanceMetres
                && $0.trackingConfidence > 0
        }
        let required = hasLiDAR
            ? configuration.minimumLiDARSamples
            : configuration.minimumStandardARSamples
        guard recent.count >= required else {
            return ShelfPointEstimate(
                position: nil,
                stability: recent.isEmpty ? .searching : .holdStill,
                message: recent.isEmpty
                    ? "The corner is not clearly detected."
                    : "Hold the phone steady while more independent samples are collected.",
                validSampleCount: recent.count,
                rejectedSampleCount: samples.count - recent.count,
                spreadMetres: .infinity,
                confidence: 0,
                depthVariance: .infinity,
                measurementDistanceMetres: .nan,
                source: .unknown
            )
        }

        // Split alternating foreground/background hits at large depth gaps.
        let depthSorted = recent.sorted { $0.cameraDistanceMetres < $1.cameraDistanceMetres }
        var clusters: [[ShelfPointSample]] = [[]]
        for sample in depthSorted {
            if let previous = clusters.last?.last,
               sample.cameraDistanceMetres - previous.cameraDistanceMetres
                > configuration.depthClusterGapMetres {
                clusters.append([])
            }
            clusters[clusters.count - 1].append(sample)
        }
        let eligibleClusters = clusters.filter {
            $0.count >= configuration.minimumClusterSamples
        }
        guard let surfaceCluster = eligibleClusters.sorted(by: {
            if $0.count != $1.count { return $0.count > $1.count }
            return median($0.map(\.cameraDistanceMetres))
                < median($1.map(\.cameraDistanceMetres))
        }).first else {
            return unavailable(.lowConfidence, "Depth readings disagree. Aim at one flat shelf surface.")
        }

        let centre = coordinateMedian(surfaceCluster.map(\.position))
        let distances = surfaceCluster.map { simd_distance($0.position, centre) }
        let distanceMedian = median(distances)
        let mad = median(distances.map { abs($0 - distanceMedian) })
        let cutoff = max(0.004, mad * 3)
        let inliers = surfaceCluster.filter {
            simd_distance($0.position, centre) <= cutoff
        }
        guard inliers.count >= required else {
            return ShelfPointEstimate(
                position: nil,
                stability: .holdStill,
                message: "The corner is moving between samples. Hold the phone steady.",
                validSampleCount: inliers.count,
                rejectedSampleCount: samples.count - inliers.count,
                spreadMetres: mad,
                confidence: 0.2,
                depthVariance: variance(inliers.map(\.cameraDistanceMetres)),
                measurementDistanceMetres: median(inliers.map(\.cameraDistanceMetres)),
                source: mostReliableSource(inliers)
            )
        }

        let representative = coordinateMedian(inliers.map(\.position))
        let spread = sqrt(
            inliers.reduce(0) {
                $0 + simd_distance_squared($1.position, representative)
            } / Double(inliers.count)
        )
        let maximumSpread = hasLiDAR
            ? configuration.maximumLiDARSpreadMetres
            : configuration.maximumStandardARSpreadMetres
        guard spread <= maximumSpread else {
            return ShelfPointEstimate(
                position: representative,
                stability: .holdStill,
                message: "Hold the phone steady. The corner estimate is moving by \((spread * 100).formatted(.number.precision(.fractionLength(1)))) cm.",
                validSampleCount: inliers.count,
                rejectedSampleCount: samples.count - inliers.count,
                spreadMetres: spread,
                confidence: max(0.15, 1 - spread / (maximumSpread * 2)),
                depthVariance: variance(inliers.map(\.cameraDistanceMetres)),
                measurementDistanceMetres: median(inliers.map(\.cameraDistanceMetres)),
                source: mostReliableSource(inliers)
            )
        }
        let tracking = inliers.map(\.trackingConfidence).reduce(0, +)
            / Double(inliers.count)
        let countScore = min(Double(inliers.count) / Double(required * 2), 1)
        let spreadScore = max(0, 1 - spread / maximumSpread)
        let source = mostReliableSource(inliers)
        let sourceScore = source.reliability
        let confidence = min(
            tracking * 0.35 + countScore * 0.20 + spreadScore * 0.25 + sourceScore * 0.20,
            0.98
        )
        return ShelfPointEstimate(
            position: representative,
            stability: .ready,
            message: "Stable corner detected. Ready to place.",
            validSampleCount: inliers.count,
            rejectedSampleCount: samples.count - inliers.count,
            spreadMetres: spread,
            confidence: confidence,
            depthVariance: variance(inliers.map(\.cameraDistanceMetres)),
            measurementDistanceMetres: median(inliers.map(\.cameraDistanceMetres)),
            source: source
        )
    }

    private static func unavailable(
        _ stability: ShelfPointStability,
        _ message: String
    ) -> ShelfPointEstimate {
        ShelfPointEstimate(
            position: nil,
            stability: stability,
            message: message,
            validSampleCount: 0,
            rejectedSampleCount: 0,
            spreadMetres: .infinity,
            confidence: 0,
            depthVariance: .infinity,
            measurementDistanceMetres: .nan,
            source: .unknown
        )
    }

    private static func mostReliableSource(_ samples: [ShelfPointSample]) -> CornerMeasurementSource {
        samples.map(\.source).max { $0.reliability < $1.reliability } ?? .unknown
    }

    private static func variance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let centre = median(values)
        return values.reduce(0) { $0 + pow($1 - centre, 2) } / Double(values.count)
    }

    private static func coordinateMedian(_ points: [SIMD3<Double>]) -> SIMD3<Double> {
        SIMD3(
            median(points.map(\.x)),
            median(points.map(\.y)),
            median(points.map(\.z))
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    private static func finite(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

struct ShelfBoundaryAnalysisConfiguration: Equatable {
    var duplicatePointDistanceMetres = 0.005
    var minimumEdgeLengthMetres = 0.01
    var minimumAreaSquareMetres = 0.0001
    var maximumPlaneResidualMetres = 0.015
    var maximumAngleDeviationDegrees = 12.0
    var maximumParallelDeviationDegrees = 12.0
    var maximumDiagonalDifferenceRatio = 0.12
    var highRectangleConfidence = 0.85
    var possibleRectangleConfidence = 0.65
    var maximumSuggestedPointMovementMetres = 0.035
    var maximumAveragePointMovementMetres = 0.02
    var maximumDimensionChangeRatio = 0.12
    var expectedDimensionConflictRatio = 0.15
    var placementSafetyMarginCM = 1.0

    static let shelf = ShelfBoundaryAnalysisConfiguration()
}

struct ShelfBoundaryDimensions: Equatable {
    let widthMetres: Double
    let depthMetres: Double
    let areaSquareMetres: Double
}

struct ShelfBoundaryAnalysis: Equatable {
    let inputRevision: UUID
    let rawBoundary: [SIMD3<Double>]
    let normalizedRawBoundary: [SIMD3<Double>]
    let suggestedBoundary: [SIMD3<Double>]?
    let detectedShapeType: ShelfShapeType
    let rawDimensions: ShelfBoundaryDimensions
    let suggestedDimensions: ShelfBoundaryDimensions?
    let rawCornerAnglesDegrees: [Double]
    let suggestedCornerAnglesDegrees: [Double]
    let pointMovementsMetres: [Double]
    let maximumPointMovementMetres: Double
    let averagePointMovementMetres: Double
    let planeRMSResidualMetres: Double
    let planeMaximumResidualMetres: Double
    let planeOrigin: SIMD3<Double>
    let planeNormal: SIMD3<Double>
    let rectangleConfidence: Double
    let scanConfidence: Double
    let correctionConfidence: Double
    let correctionReasons: [GeometryCorrectionReason]
    let requiresRescan: Bool
    let recoveryMessage: String?
}

enum ShelfBoundaryAnalysisError: LocalizedError, Equatable {
    case tooFewPoints
    case invalidCoordinate
    case duplicatePoint
    case shortEdge
    case zeroArea
    case selfIntersection
    case poorPlanarity
    case expectedDimensionsIncomplete
    case expectedDimensionsInvalid

    var errorDescription: String? {
        switch self {
        case .tooFewPoints: "Place at least three unique boundary points."
        case .invalidCoordinate: "The boundary contains an invalid or mixed-coordinate point. Rescan it."
        case .duplicatePoint: "Two corners are too close to distinguish. Delete or rescan one corner."
        case .shortEdge: "One shelf edge is below reliable sensor resolution. Rescan that area."
        case .zeroArea: "The boundary is too small or nearly collinear."
        case .selfIntersection: "Boundary edges cross. Rescan the affected corners in boundary order."
        case .poorPlanarity: "The points do not describe one reliable shelf surface."
        case .expectedDimensionsIncomplete: "Enter both expected width and expected depth, or leave both blank."
        case .expectedDimensionsInvalid: "Expected dimensions must be finite positive centimetre values."
        }
    }
}

enum ShelfBoundaryAnalyzer {
    static func analyze(
        points: [SIMD3<Double>],
        cornerConfidence: [Double],
        intent: ShelfShapeIntent,
        expectedWidthCM: Double? = nil,
        expectedDepthCM: Double? = nil,
        inputRevision: UUID = UUID(),
        configuration: ShelfBoundaryAnalysisConfiguration = .shelf
    ) throws -> ShelfBoundaryAnalysis {
        guard points.count >= 3 else { throw ShelfBoundaryAnalysisError.tooFewPoints }
        guard points.allSatisfy(finite) else { throw ShelfBoundaryAnalysisError.invalidCoordinate }
        if (expectedWidthCM == nil) != (expectedDepthCM == nil) {
            throw ShelfBoundaryAnalysisError.expectedDimensionsIncomplete
        }
        if let expectedWidthCM, let expectedDepthCM,
           !validExpected(expectedWidthCM) || !validExpected(expectedDepthCM) {
            throw ShelfBoundaryAnalysisError.expectedDimensionsInvalid
        }
        for first in points.indices {
            for second in points.indices where second > first {
                if simd_distance(points[first], points[second])
                    < configuration.duplicatePointDistanceMetres {
                    throw ShelfBoundaryAnalysisError.duplicatePoint
                }
            }
        }

        let fittedPlane: FittedMeasurementPlane
        do {
            fittedPlane = try ManualMeasurementGeometry.fitPlane(to: points)
        } catch {
            throw ShelfBoundaryAnalysisError.zeroArea
        }
        // Boundaries are captured in an ARPlaneAnchor coordinate system where
        // local Y is normal to the shelf. A near-sideways fitted normal means
        // the samples came from mixed surfaces or coordinate spaces.
        guard abs(fittedPlane.normal.y) >= 0.25 else {
            throw ShelfBoundaryAnalysisError.poorPlanarity
        }
        let signedResiduals = points.map {
            simd_dot($0 - fittedPlane.origin, fittedPlane.normal)
        }
        let residuals = signedResiduals.map(abs)
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(points.count))
        let maxResidual = residuals.max() ?? 0
        guard maxResidual <= configuration.maximumPlaneResidualMetres else {
            throw ShelfBoundaryAnalysisError.poorPlanarity
        }

        var ordered = points
        var reasons: [GeometryCorrectionReason] = [.refinedUsingRepeatedSamples]
        if selfIntersects(ordered.map { SIMD2($0.x, $0.z) }) {
            // Corner order is user intent. Never silently repair a bow-tie by sorting.
            throw ShelfBoundaryAnalysisError.selfIntersection
        }
        ordered = normalizedWinding(ordered)
        let raw2D = ordered.map { SIMD2($0.x, $0.z) }
        try validatePolygon(raw2D, configuration: configuration)
        let rawDimensions = dimensions(of: raw2D)
        let rawAngles = cornerAngles(raw2D)
        let averageCornerConfidence = cornerConfidence.isEmpty
            ? 0.5
            : cornerConfidence.reduce(0, +) / Double(cornerConfidence.count)
        let planarityScore = max(0, 1 - rms / configuration.maximumPlaneResidualMetres)
        let polygonScore = min(rawDimensions.areaSquareMetres / 0.02, 1)
        let scanConfidence = min(
            averageCornerConfidence * 0.55 + planarityScore * 0.30 + polygonScore * 0.15,
            0.98
        )
        let rectangleConfidence = rectangleScore(
            raw2D,
            planarityScore: planarityScore,
            scanConfidence: scanConfidence,
            configuration: configuration
        )
        let detected: ShelfShapeType
        if points.count == 4 && rectangleConfidence >= configuration.highRectangleConfidence {
            detected = .rectangle
        } else if points.count == 4 && rectangleConfidence >= configuration.possibleRectangleConfidence {
            detected = .likelyRectangle
        } else if points.count > 4 || rectangleConfidence < configuration.possibleRectangleConfidence {
            detected = .irregularPolygon
        } else {
            detected = .uncertain
        }

        let shouldFitRectangle = points.count == 4 && (
            intent == .rectangular
                || (intent == .automatic
                    && rectangleConfidence >= configuration.possibleRectangleConfidence)
        )
        var suggestion = maxResidual > 0.000_001
            ? ordered.map { point in
                point - fittedPlane.normal
                    * simd_dot(point - fittedPlane.origin, fittedPlane.normal)
            }
            : ordered
        if maxResidual > 0.001 {
            reasons.append(.projectedToBestFitPlane)
        }
        if shouldFitRectangle {
            var rectangle = fittedRectangle(raw2D)
            if let expectedWidthCM, let expectedDepthCM {
                rectangle = rectangleWithExpectedDimensions(
                    rectangle,
                    expectedWidthMetres: expectedWidthCM / 100,
                    expectedDepthMetres: expectedDepthCM / 100
                )
                reasons.append(.matchedExpectedDimensions)
            }
            suggestion = rectangle.map { point in
                let y = fittedPlane.origin.y - (
                    fittedPlane.normal.x * (point.x - fittedPlane.origin.x)
                        + fittedPlane.normal.z * (point.y - fittedPlane.origin.z)
                ) / fittedPlane.normal.y
                return SIMD3(point.x, y, point.y)
            }
            reasons.append(contentsOf: [
                .correctedNearRightAngle,
                .correctedOppositeSideParallelism,
                .correctedDiagonalMismatch
            ])
        }

        let suggested2D = suggestion.map { SIMD2($0.x, $0.z) }
        try validatePolygon(suggested2D, configuration: configuration)
        let suggestedDimensions = dimensions(of: suggested2D)
        let movements = zip(ordered, suggestion).map(simd_distance)
        let maxMovement = movements.max() ?? 0
        let averageMovement = movements.reduce(0, +) / Double(max(movements.count, 1))
        let dimensionChange = max(
            relativeChange(rawDimensions.widthMetres, suggestedDimensions.widthMetres),
            relativeChange(rawDimensions.depthMetres, suggestedDimensions.depthMetres)
        )
        let expectedConflict: Bool
        if let expectedWidthCM, let expectedDepthCM {
            expectedConflict = max(
                relativeChange(rawDimensions.widthMetres, expectedWidthCM / 100),
                relativeChange(rawDimensions.depthMetres, expectedDepthCM / 100)
            ) > configuration.expectedDimensionConflictRatio
        } else {
            expectedConflict = false
        }
        let correctionIsExcessive = maxMovement
                > configuration.maximumSuggestedPointMovementMetres
            || averageMovement > configuration.maximumAveragePointMovementMetres
            || dimensionChange > configuration.maximumDimensionChangeRatio
        let rectangleRequiredButUnsupported = intent == .rectangular
            && (points.count != 4
                || rectangleConfidence < configuration.possibleRectangleConfidence)
        let requiresRescan = correctionIsExcessive
            || rectangleRequiredButUnsupported
            || expectedConflict
            || scanConfidence < 0.45
        let recovery: String?
        if expectedConflict {
            recovery = "The scan and expected dimensions disagree beyond normal uncertainty. Verify the dimensions or rescan."
        } else if rectangleRequiredButUnsupported {
            recovery = "This scan does not contain enough evidence for a reliable rectangle. Rescan all four corners."
        } else if correctionIsExcessive {
            recovery = "The proposed correction moves corners too far. Rescan the highlighted corners."
        } else if scanConfidence < 0.45 {
            recovery = "Scan confidence is too low for automatic placement. Rescan while tracking is stable."
        } else {
            recovery = nil
        }
        let movementScore = max(
            0,
            1 - averageMovement / configuration.maximumAveragePointMovementMetres
        )
        let correctionConfidence = min(
            rectangleConfidence * 0.45
                + scanConfidence * 0.35
                + movementScore * 0.20,
            0.98
        )
        return ShelfBoundaryAnalysis(
            inputRevision: inputRevision,
            rawBoundary: points,
            normalizedRawBoundary: ordered,
            suggestedBoundary: requiresRescan ? nil : suggestion,
            detectedShapeType: requiresRescan ? .uncertain : detected,
            rawDimensions: rawDimensions,
            suggestedDimensions: requiresRescan ? nil : suggestedDimensions,
            rawCornerAnglesDegrees: rawAngles,
            suggestedCornerAnglesDegrees: requiresRescan ? [] : cornerAngles(suggested2D),
            pointMovementsMetres: movements,
            maximumPointMovementMetres: maxMovement,
            averagePointMovementMetres: averageMovement,
            planeRMSResidualMetres: rms,
            planeMaximumResidualMetres: maxResidual,
            planeOrigin: fittedPlane.origin,
            planeNormal: fittedPlane.normal,
            rectangleConfidence: rectangleConfidence,
            scanConfidence: scanConfidence,
            correctionConfidence: correctionConfidence,
            correctionReasons: Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue },
            requiresRescan: requiresRescan,
            recoveryMessage: recovery
        )
    }

    static func geometryRecord(
        from analysis: ShelfBoundaryAnalysis,
        approvedBoundary: [SIMD3<Double>],
        approval: ShelfGeometryApproval,
        intent: ShelfShapeIntent,
        meaning: ShelfBoundaryMeaning,
        cornerMetadata: [ShelfCornerMeasurementMetadata],
        expectedWidthCM: Double?,
        expectedDepthCM: Double?,
        deviceModel: String,
        hasLiDAR: Bool,
        version: Int = 1,
        configuration: ShelfBoundaryAnalysisConfiguration = .shelf
    ) -> ShelfGeometryRecord {
        ShelfGeometryRecord(
            version: version,
            inputRevision: analysis.inputRevision,
            rawBoundary: analysis.rawBoundary.map(Vector3D.init),
            correctedBoundary: analysis.suggestedBoundary?.map(Vector3D.init),
            approvedBoundary: approvedBoundary.map(Vector3D.init),
            detectedShapeType: analysis.detectedShapeType,
            requestedShapeIntent: intent,
            boundaryMeaning: meaning,
            correctionConfidence: analysis.correctionConfidence,
            scanConfidence: analysis.scanConfidence,
            correctionReasons: analysis.correctionReasons,
            approval: approval,
            approvedAt: approval == .draft ? nil : .now,
            placementSafetyMarginCM: configuration.placementSafetyMarginCM,
            measurementMetadata: ShelfMeasurementMetadata(
                capturedAt: .now,
                deviceModel: deviceModel,
                hasLiDAR: hasLiDAR,
                coordinateSpace: .planeAnchorLocal,
                unit: .metres,
                planeRMSResidualMetres: analysis.planeRMSResidualMetres,
                planeMaximumResidualMetres: analysis.planeMaximumResidualMetres,
                cornerMeasurements: cornerMetadata,
                expectedWidthCM: expectedWidthCM,
                expectedDepthCM: expectedDepthCM
            )
        )
    }

    private static func validatePolygon(
        _ polygon: [SIMD2<Double>],
        configuration: ShelfBoundaryAnalysisConfiguration
    ) throws {
        guard abs(signedArea(polygon)) >= configuration.minimumAreaSquareMetres else {
            throw ShelfBoundaryAnalysisError.zeroArea
        }
        for index in polygon.indices where simd_distance(
            polygon[index], polygon[(index + 1) % polygon.count]
        ) < configuration.minimumEdgeLengthMetres {
            throw ShelfBoundaryAnalysisError.shortEdge
        }
        guard !selfIntersects(polygon) else {
            throw ShelfBoundaryAnalysisError.selfIntersection
        }
    }

    private static func rectangleScore(
        _ points: [SIMD2<Double>],
        planarityScore: Double,
        scanConfidence: Double,
        configuration: ShelfBoundaryAnalysisConfiguration
    ) -> Double {
        guard points.count == 4 else { return 0 }
        let edges = points.indices.map { points[($0 + 1) % 4] - points[$0] }
        guard edges.allSatisfy({ simd_length($0) > 0 }) else { return 0 }
        let angles = cornerAngles(points)
        let angleDeviation = angles.map { abs($0 - 90) }.reduce(0, +) / 4
        let angleScore = max(
            0,
            1 - angleDeviation / configuration.maximumAngleDeviationDegrees
        )
        func parallelDeviation(_ first: SIMD2<Double>, _ second: SIMD2<Double>) -> Double {
            let cosine = min(max(abs(simd_dot(simd_normalize(first), simd_normalize(second))), -1), 1)
            return acos(cosine) * 180 / .pi
        }
        let parallel = (
            parallelDeviation(edges[0], edges[2])
                + parallelDeviation(edges[1], edges[3])
        ) / 2
        let parallelScore = max(
            0,
            1 - parallel / configuration.maximumParallelDeviationDegrees
        )
        let diagonalA = simd_distance(points[0], points[2])
        let diagonalB = simd_distance(points[1], points[3])
        let diagonalDifference = abs(diagonalA - diagonalB) / max(diagonalA, diagonalB)
        let midpointA = (points[0] + points[2]) / 2
        let midpointB = (points[1] + points[3]) / 2
        let midpointDifference = simd_distance(midpointA, midpointB)
            / max(diagonalA, diagonalB)
        let diagonalScore = max(
            0,
            1 - max(diagonalDifference, midpointDifference)
                / configuration.maximumDiagonalDifferenceRatio
        )
        return min(
            angleScore * 0.25
                + parallelScore * 0.25
                + diagonalScore * 0.20
                + planarityScore * 0.15
                + scanConfidence * 0.15,
            1
        )
    }

    private static func fittedRectangle(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let centre = points.reduce(.zero, +) / 4
        let edgeA = simd_normalize(points[1] - points[0])
        let oppositeA = simd_normalize(points[2] - points[3])
        var axisU = edgeA + oppositeA
        if simd_length(axisU) < 0.001 { axisU = edgeA }
        axisU = simd_normalize(axisU)
        let axisV = SIMD2<Double>(-axisU.y, axisU.x)
        let u = points.map { simd_dot($0 - centre, axisU) }
        let v = points.map { simd_dot($0 - centre, axisV) }
        let halfU = (u.map(abs).reduce(0, +) / 4)
        let halfV = (v.map(abs).reduce(0, +) / 4)
        return [
            centre - axisU * halfU - axisV * halfV,
            centre + axisU * halfU - axisV * halfV,
            centre + axisU * halfU + axisV * halfV,
            centre - axisU * halfU + axisV * halfV
        ]
    }

    private static func rectangleWithExpectedDimensions(
        _ rectangle: [SIMD2<Double>],
        expectedWidthMetres: Double,
        expectedDepthMetres: Double
    ) -> [SIMD2<Double>] {
        let centre = rectangle.reduce(.zero, +) / 4
        let axisU = simd_normalize(rectangle[1] - rectangle[0])
        let axisV = SIMD2<Double>(-axisU.y, axisU.x)
        let measuredU = simd_distance(rectangle[0], rectangle[1])
        let useExpectedWidthForU = abs(measuredU - expectedWidthMetres)
            <= abs(measuredU - expectedDepthMetres)
        let sizeU = useExpectedWidthForU ? expectedWidthMetres : expectedDepthMetres
        let sizeV = useExpectedWidthForU ? expectedDepthMetres : expectedWidthMetres
        return [
            centre - axisU * sizeU / 2 - axisV * sizeV / 2,
            centre + axisU * sizeU / 2 - axisV * sizeV / 2,
            centre + axisU * sizeU / 2 + axisV * sizeV / 2,
            centre - axisU * sizeU / 2 + axisV * sizeV / 2
        ]
    }

    private static func dimensions(of polygon: [SIMD2<Double>]) -> ShelfBoundaryDimensions {
        let rectangle = minimumAreaRectangle(polygon)
        return ShelfBoundaryDimensions(
            widthMetres: max(rectangle.sizeU, rectangle.sizeV),
            depthMetres: min(rectangle.sizeU, rectangle.sizeV),
            areaSquareMetres: abs(signedArea(polygon))
        )
    }

    private static func minimumAreaRectangle(
        _ polygon: [SIMD2<Double>]
    ) -> (sizeU: Double, sizeV: Double) {
        var best = (sizeU: 0.0, sizeV: 0.0, area: Double.greatestFiniteMagnitude)
        for index in polygon.indices {
            let edge = polygon[(index + 1) % polygon.count] - polygon[index]
            guard simd_length(edge) > 0 else { continue }
            let axisU = simd_normalize(edge)
            let axisV = SIMD2<Double>(-axisU.y, axisU.x)
            let u = polygon.map { simd_dot($0, axisU) }
            let v = polygon.map { simd_dot($0, axisV) }
            let sizeU = (u.max() ?? 0) - (u.min() ?? 0)
            let sizeV = (v.max() ?? 0) - (v.min() ?? 0)
            if sizeU * sizeV < best.area {
                best = (sizeU, sizeV, sizeU * sizeV)
            }
        }
        return (best.sizeU, best.sizeV)
    }

    private static func cornerAngles(_ polygon: [SIMD2<Double>]) -> [Double] {
        guard polygon.count >= 3 else { return [] }
        return polygon.indices.map { index in
            let previous = polygon[(index - 1 + polygon.count) % polygon.count]
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let first = simd_normalize(previous - current)
            let second = simd_normalize(next - current)
            let cosine = min(max(simd_dot(first, second), -1), 1)
            return acos(cosine) * 180 / .pi
        }
    }

    private static func angularOrder(_ points: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let centre = points.reduce(.zero, +) / Double(points.count)
        return points.sorted {
            atan2($0.z - centre.z, $0.x - centre.x)
                < atan2($1.z - centre.z, $1.x - centre.x)
        }
    }

    private static func normalizedWinding(_ points: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var result = points
        if signedArea(result.map { SIMD2($0.x, $0.z) }) < 0 {
            result.reverse()
        }
        guard let first = result.indices.min(by: {
            let lhs = result[$0]
            let rhs = result[$1]
            return lhs.x == rhs.x ? lhs.z < rhs.z : lhs.x < rhs.x
        }) else { return result }
        return Array(result[first...] + result[..<first])
    }

    private static func selfIntersects(_ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 4 else { return false }
        for first in polygon.indices {
            let firstNext = (first + 1) % polygon.count
            for second in polygon.indices {
                let secondNext = (second + 1) % polygon.count
                if first == second || firstNext == second || secondNext == first { continue }
                if segmentsIntersect(
                    polygon[first], polygon[firstNext],
                    polygon[second], polygon[secondNext]
                ) { return true }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>,
        _ c: SIMD2<Double>,
        _ d: SIMD2<Double>
    ) -> Bool {
        let abC = cross(b - a, c - a)
        let abD = cross(b - a, d - a)
        let cdA = cross(d - c, a - c)
        let cdB = cross(d - c, b - c)
        return abC * abD < -1e-10 && cdA * cdB < -1e-10
    }

    private static func signedArea(_ polygon: [SIMD2<Double>]) -> Double {
        polygon.indices.reduce(0) { partial, index in
            let next = polygon[(index + 1) % polygon.count]
            return partial + polygon[index].x * next.y - next.x * polygon[index].y
        } / 2
    }

    private static func cross(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> Double {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private static func relativeChange(_ first: Double, _ second: Double) -> Double {
        abs(first - second) / max(max(abs(first), abs(second)), 0.000_001)
    }

    private static func validExpected(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value < 10_000
    }

    private static func finite(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
