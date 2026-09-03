import XCTest
import simd
@testable import WarehouseApp

final class BorderDetectionEngineTests: XCTestCase {
    private let detector = DefaultBorderDetectionEngine()

    func testDropEdgeRequiresPersistentGeometry() {
        var evidence = validEvidence()
        evidence.depthGradientMetres = 0.14
        evidence.persistenceFrames = 2
        XCTAssertFalse(detector.detectBorder(evidence: evidence).shouldCommit)
        evidence.persistenceFrames = 5
        let result = detector.detectBorder(evidence: evidence)
        XCTAssertEqual(result.segmentType, .dropEdge)
        XCTAssertTrue(result.shouldCommit)
    }

    func testPlaneIntersectionDetection() {
        var evidence = validEvidence()
        evidence.depthGradientMetres = 0.01
        evidence.normalDifference = 0.8
        let result = detector.detectBorder(evidence: evidence)
        XCTAssertEqual(result.segmentType, .planeIntersection)
    }

    func testSurfaceTerminationDetection() {
        var evidence = validEvidence()
        evidence.depthGradientMetres = 0.01
        evidence.normalDifference = 0.05
        evidence.missingDepthFraction = 0.6
        let result = detector.detectBorder(evidence: evidence)
        XCTAssertEqual(result.segmentType, .surfaceTermination)
    }

    func testElevationChangeDetection() {
        var evidence = validEvidence()
        evidence.surfaceType = .floor
        evidence.depthGradientMetres = 0.04
        evidence.normalDifference = 0.35
        evidence.hasPlaneSupport = false
        let result = detector.detectBorder(evidence: evidence)
        XCTAssertEqual(result.segmentType, .elevationChange)
    }

    func testInternalObjectIsRejectedWhenSurfaceContinuesBehindIt() {
        var evidence = validEvidence()
        evidence.depthGradientMetres = 0.2
        evidence.surfaceContinuesBeyondEdge = true
        XCTAssertEqual(detector.detectBorder(evidence: evidence).confidenceLevel, .invalid)
    }

    func testInvalidDepthAndTrackingAreRejected() {
        var evidence = validEvidence()
        evidence.depthVariance = .infinity
        XCTAssertEqual(detector.detectBorder(evidence: evidence).confidenceLevel, .invalid)
        evidence = validEvidence()
        evidence.trackingState = .limited
        XCTAssertEqual(detector.detectBorder(evidence: evidence).confidenceLevel, .invalid)
    }

    private func validEvidence() -> BorderDetectionEvidence {
        BorderDetectionEvidence(
            depthGradientMetres: 0.12,
            normalDifference: 0.7,
            basePlaneDistanceMetres: 0.005,
            measurementDistanceMetres: 0.8,
            validDepthSampleCount: 40,
            depthVariance: 0.001,
            persistenceFrames: 5,
            viewingAngleDiversity: 0.4,
            hasPlaneSupport: true,
            hasMeshSupport: true,
            surfaceContinuesBeyondEdge: false,
            missingDepthFraction: 0,
            trackingState: .normal,
            surfaceType: .tabletop
        )
    }
}

final class BorderTraceAndProcessingTests: XCTestCase {
    func testTracePreservesScanOrderAndRejectsLargeJump() {
        let builder = DefaultBorderTraceBuilder()
        builder.begin(at: observation(0, 0), type: .dropEdge)
        builder.add(observation(0.1, 0), type: .dropEdge)
        builder.add(observation(2, 2), type: .dropEdge)
        builder.add(observation(0.1, 0.1), type: .dropEdge)
        XCTAssertEqual(builder.observations.map(\.localPosition), [
            Vector2D(0, 0), Vector2D(0.1, 0), Vector2D(0.1, 0.1)
        ])
    }

    func testRepeatedScanMergesInsteadOfDuplicatingEdge() {
        let builder = DefaultBorderTraceBuilder()
        builder.begin(at: observation(0, 0, confidence: 0.6), type: .dropEdge)
        builder.add(observation(0.1, 0), type: .dropEdge)
        builder.add(observation(0.002, 0.001, confidence: 0.9), type: .dropEdge)
        XCTAssertEqual(builder.observations.count, 2)
        XCTAssertGreaterThan(builder.observations[0].confidence, 0.9)
    }

    func testRectangularTraceClosesAndSimplifies() {
        let result = DefaultBoundaryProcessor().process(
            observations: denseRectangle(), configuration: .standard
        )
        XCTAssertEqual(result.validationState, .valid)
        XCTAssertGreaterThanOrEqual(result.simplified.count, 4)
        XCTAssertLessThan(result.simplified.count, denseRectangle().count)
        XCTAssertGreaterThanOrEqual(result.corners.count, 4)
    }

    func testConcaveBoundaryRemainsConcave() {
        let points = [
            (0.0, 0.0), (1, 0), (1, 1), (0.5, 0.45), (0, 1), (0, 0.02)
        ].map { observation($0.0, $0.1) }
        let result = DefaultBoundaryProcessor().process(observations: points, configuration: .standard)
        XCTAssertEqual(result.validationState, .valid)
        XCTAssertTrue(result.simplified.contains { abs($0.x - 0.5) < 0.02 && abs($0.y - 0.45) < 0.02 })
    }

    func testSelfIntersectionIsRejectedWithoutRepair() {
        let points = [(0.0, 0.0), (1, 1), (0, 1), (1, 0), (0, 0.01)]
            .map { observation($0.0, $0.1) }
        let result = DefaultBoundaryProcessor().process(observations: points, configuration: .standard)
        XCTAssertEqual(result.validationState, .selfIntersecting)
    }

    func testUndoRemovesOnlyRecentTraceSection() {
        let builder = DefaultBorderTraceBuilder()
        builder.begin(at: observation(0, 0), type: .dropEdge)
        for index in 1...10 { builder.add(observation(Double(index) * 0.02, 0), type: .dropEdge) }
        builder.undoLastSection()
        XCTAssertEqual(builder.observations.count, 5)
    }

    private func denseRectangle() -> [BorderObservation] {
        var points: [(Double, Double)] = []
        for i in 0...10 { points.append((Double(i) / 10, 0)) }
        for i in 1...10 { points.append((1, Double(i) / 10)) }
        for i in 1...10 { points.append((1 - Double(i) / 10, 1)) }
        for i in 1...10 { points.append((0, 1 - Double(i) / 10)) }
        return points.map { observation($0.0, $0.1) }
    }

    private func observation(
        _ x: Double, _ y: Double, confidence: Double = 0.9
    ) -> BorderObservation {
        BorderObservation(
            id: UUID(), worldPosition: Vector3D(x, 0, y),
            localPosition: Vector2D(x, y), depthGradient: 0.1,
            normalDifference: 0.6, basePlaneDistance: 0.002,
            measurementDistance: 1, source: .smoothedSceneDepth,
            segmentType: .dropEdge,
            trackingState: .normal, confidence: confidence, timestamp: .now,
            viewingDirection: Vector3D(0, 0, -1)
        )
    }
}

final class BorderScanPersistenceTests: XCTestCase {
    func testVersionFourBoundaryProvenanceRoundTrips() throws {
        let observation = BorderObservation(
            id: UUID(), worldPosition: Vector3D(1, 2, 3),
            localPosition: Vector2D(0.2, 0.4), depthGradient: 0.12,
            normalDifference: 0.7, basePlaneDistance: 0.003,
            measurementDistance: 1.2, source: .smoothedSceneDepth,
            segmentType: .dropEdge,
            trackingState: .normal, confidence: 0.88, timestamp: .now,
            viewingDirection: Vector3D(0, 0, -1)
        )
        let boundary = ScannedStorageBoundary(
            id: UUID(),
            basePlane: CodablePlane(origin: Vector3D(0, 0, 0), normal: Vector3D(0, 1, 0)),
            surfaceType: .workbench,
            rawTrace: [observation], detectedSegments: [], detectedCorners: [],
            simplifiedPolygon: [Vector2D(0, 0), Vector2D(1, 0), Vector2D(0, 1)],
            approvedPolygon: [Vector2D(0, 0), Vector2D(1, 0), Vector2D(0, 1)],
            suggestedPolygon: nil, geometryConfidence: 0.88,
            validationState: .valid,
            processingMetrics: .init(
                maximumSimplificationDisplacementMetres: 0.004,
                averageSimplificationDisplacementMetres: 0.002,
                inferredGapLengthMetres: 0, manualEditCount: 0
            ),
            measurementMethod: .lidarBorderScan, deviceHasLiDAR: true,
            schemaVersion: 4, createdAt: .now, updatedAt: .now
        )
        let decoded = try JSONDecoder().decode(
            ScannedStorageBoundary.self,
            from: JSONEncoder().encode(boundary)
        )
        XCTAssertEqual(decoded, boundary)
        XCTAssertEqual(decoded.rawTrace.first?.source, .smoothedSceneDepth)
        XCTAssertNil(decoded.acquisitionSections)
        XCTAssertNil(decoded.dimensionUncertainties)
        XCTAssertNil(decoded.approvalState)
        XCTAssertNil(decoded.guidedCornerMeasurements)
        XCTAssertNil(decoded.surfaceFirstCompartment)

        var versionFive = boundary
        versionFive.schemaVersion = 5
        versionFive.shapeIntent = .straightSidedPolygon
        versionFive.dimensionUncertainties = [DimensionUncertainty(
            measuredMetres: 1,
            estimatedUncertaintyMetres: 0.008,
            robustFitResidualMetres: 0.003,
            repeatabilityMetres: 0.004,
            spatialCoverage: 0.8,
            viewingDiversityRadians: 0.3,
            closureErrorMetres: 0.004,
            inferencePenaltyMetres: 0,
            correctionDisplacementMetres: 0,
            correlatedSampleFraction: 0.1
        )]
        versionFive.approvalState = .approvedRaw
        versionFive.localPlacementUncertaintyMetres = 0.008
        let decodedVersionFive = try JSONDecoder().decode(
            ScannedStorageBoundary.self,
            from: JSONEncoder().encode(versionFive)
        )
        XCTAssertEqual(decodedVersionFive, versionFive)
    }
}

final class GuidedCornerEstimatorTests: XCTestCase {
    func testTabletopEstimatorFindsIntersectionFromMultiFramePatch() throws {
        // UUIDs differ on every pass; evidence ordering must not affect the fit.
        for _ in 0..<5 {
            let capture = CornerPatchCapture(
                samples: tabletopSamples(),
                reticleLocalPosition: Vector2D(0, 0),
                coordinateEpoch: UUID(), startedAt: 0, endedAt: 1.4
            )
            let result = try TabletopCornerEstimator().estimate(capture: capture).get()
            XCTAssertEqual(result.estimator, .tabletopTerminationEdges)
            XCTAssertEqual(result.provenance, .directlyObserved)
            XCTAssertEqual(result.originalCandidatePosition.x, 0, accuracy: 0.012)
            XCTAssertEqual(result.originalCandidatePosition.y, 0, accuracy: 0.012)
            XCTAssertGreaterThanOrEqual(result.independentFrameCount, 6)
            XCTAssertLessThanOrEqual(result.uncertaintyMetres, 0.02)
            XCTAssertEqual(result.fittedEdges.count, 2)
        }
    }

    func testEstimatorRejectsNearlyParallelEvidence() {
        var samples: [LocalCornerPatchSample] = []
        for frame in 0..<7 {
            for index in 0..<12 {
                let x = Double(index) * 0.01
                samples.append(sample(x: x, y: 0, z: 0.001 * Double(frame), frame: frame))
            }
        }
        let capture = CornerPatchCapture(
            samples: samples, reticleLocalPosition: Vector2D(0, 0),
            coordinateEpoch: UUID(), startedAt: 0, endedAt: 1.4
        )
        guard case .failure(let failure) = TabletopCornerEstimator().estimate(capture: capture) else {
            return XCTFail("Parallel samples must not manufacture a corner")
        }
        XCTAssertTrue([.insufficientSpatialCoverage, .noReliableIntersection].contains(failure))
    }

    func testCornerAccuracyPolicyRejectsOverFivePercent() {
        XCTAssertFalse(CornerAccuracyPolicy.accepts(
            uncertaintyMetres: 0.051, measurementDistanceMetres: 1
        ))
        XCTAssertTrue(CornerAccuracyPolicy.accepts(
            uncertaintyMetres: 0.015, measurementDistanceMetres: 1
        ))
    }

    private func tabletopSamples() -> [LocalCornerPatchSample] {
        var samples: [LocalCornerPatchSample] = []
        for frame in 0..<7 {
            let jitter = Double(frame - 3) * 0.0002
            for index in 0...12 {
                let value = Double(index) * 0.01
                samples.append(sample(x: value, y: jitter, z: jitter, frame: frame))
                samples.append(sample(x: jitter, y: -jitter, z: value, frame: frame))
            }
            for x in 1...5 {
                for z in 1...5 {
                    samples.append(sample(
                        x: Double(x) * 0.018, y: jitter,
                        z: Double(z) * 0.018, frame: frame
                    ))
                }
            }
        }
        return samples
    }

    private func sample(
        x: Double, y: Double, z: Double, frame: Int
    ) -> LocalCornerPatchSample {
        LocalCornerPatchSample(
            id: UUID(), localPosition: Vector3D(x, y, z),
            cameraPositionLocal: Vector3D(-0.25 + Double(frame) * 0.004, 0.35, -0.4),
            timestamp: Double(frame) * 0.2, frameSequence: frame,
            trackingState: .normal, depthConfidence: 0.95
        )
    }
}
