import XCTest
@testable import WarehouseApp

final class ShelfPointEstimatorTests: XCTestCase {
    func testStableSamplesRejectOneExtremeOutlier() throws {
        var samples = stableSamples(around: SIMD3<Double>(0.2, 0.7, -0.4))
        samples.append(sample(SIMD3(2, 2, -3), depth: 3.5, time: 0.7))

        let estimate = ShelfPointEstimator.estimate(samples: samples, hasLiDAR: true)

        XCTAssertTrue(estimate.canPlace)
        XCTAssertEqual(try XCTUnwrap(estimate.position).x, 0.2, accuracy: 0.002)
        XCTAssertGreaterThan(estimate.rejectedSampleCount, 0)
    }

    func testBimodalDepthUsesDominantSurfaceCluster() throws {
        var samples = stableSamples(
            around: SIMD3<Double>(0.1, 0.5, -0.6),
            count: 9,
            baseDepth: 0.7
        )
        samples += stableSamples(
            around: SIMD3<Double>(0.1, 0.5, -1.5),
            count: 4,
            baseDepth: 1.6,
            startTime: 0.2
        )

        let estimate = ShelfPointEstimator.estimate(samples: samples, hasLiDAR: true)

        XCTAssertTrue(estimate.canPlace)
        XCTAssertEqual(try XCTUnwrap(estimate.position).z, -0.6, accuracy: 0.003)
    }

    func testInsufficientSamplesCannotBePlaced() {
        let estimate = ShelfPointEstimator.estimate(
            samples: stableSamples(around: .zero, count: 3),
            hasLiDAR: true
        )

        XCTAssertFalse(estimate.canPlace)
        XCTAssertEqual(estimate.stability, .holdStill)
    }

    func testNaNAndOutOfRangeSamplesAreRejected() {
        let samples = [
            sample(SIMD3(.nan, 0, 0), depth: 1, time: 0),
            sample(.zero, depth: 9, time: 0.1)
        ]
        let estimate = ShelfPointEstimator.estimate(samples: samples, hasLiDAR: true)
        XCTAssertFalse(estimate.canPlace)
    }

    private func stableSamples(
        around point: SIMD3<Double>,
        count: Int = 10,
        baseDepth: Double = 0.8,
        startTime: Double = 0
    ) -> [ShelfPointSample] {
        (0..<count).map { index in
            let offset = Double(index % 3 - 1) * 0.0005
            return sample(
                point + SIMD3(offset, -offset, offset / 2),
                depth: baseDepth + offset,
                time: startTime + Double(index) * 0.05
            )
        }
    }

    private func sample(
        _ point: SIMD3<Double>,
        depth: Double,
        time: Double
    ) -> ShelfPointSample {
        ShelfPointSample(
            position: point,
            cameraDistanceMetres: depth,
            timestamp: time,
            trackingConfidence: 0.9,
            hasLiDARDepth: true
        )
    }
}

final class ShelfBoundaryAnalyzerTests: XCTestCase {
    func testPerfectEightyByFortyRectangleIsDetected() throws {
        let analysis = try analyze(rectangle(width: 0.8, depth: 0.4))

        XCTAssertEqual(analysis.detectedShapeType, .rectangle)
        XCTAssertGreaterThanOrEqual(analysis.rectangleConfidence, 0.85)
        XCTAssertEqual(analysis.rawDimensions.widthMetres, 0.8, accuracy: 0.001)
        XCTAssertEqual(analysis.rawDimensions.depthMetres, 0.4, accuracy: 0.001)
    }

    func testRotatedTranslatedRectangleIsWorldAxisIndependent() throws {
        let points = transform(
            rectangle(width: 0.8, depth: 0.4),
            angle: .pi * 0.37,
            translation: SIMD2(3.2, -2.7)
        )
        let analysis = try analyze(points)

        XCTAssertEqual(analysis.detectedShapeType, .rectangle)
        XCTAssertEqual(analysis.rawDimensions.widthMetres, 0.8, accuracy: 0.002)
        XCTAssertEqual(analysis.rawDimensions.depthMetres, 0.4, accuracy: 0.002)
    }

    func testSmallCornerErrorProducesApprovalOnlySuggestion() throws {
        var points = rectangle(width: 0.8, depth: 0.4)
        points[2].x += 0.01
        let analysis = try analyze(points)

        XCTAssertNotNil(analysis.suggestedBoundary)
        XCTAssertNotEqual(analysis.rawBoundary, analysis.suggestedBoundary)
        XCTAssertLessThan(analysis.maximumPointMovementMetres, 0.035)
    }

    func testTrapezoidRemainsIrregularInAutomaticMode() throws {
        let trapezoid = points([
            SIMD2(0, 0), SIMD2(0.8, 0), SIMD2(0.67, 0.4), SIMD2(0.1, 0.4)
        ])
        let analysis = try analyze(trapezoid)

        XCTAssertEqual(analysis.detectedShapeType, .irregularPolygon)
        XCTAssertEqual(analysis.normalizedRawBoundary.count, 4)
        XCTAssertEqual(analysis.suggestedBoundary, analysis.normalizedRawBoundary)
    }

    func testStrongTrapezoidRejectedWhenRectangleRequired() throws {
        let trapezoid = points([
            SIMD2(0, 0), SIMD2(0.8, 0), SIMD2(0.55, 0.4), SIMD2(0.2, 0.4)
        ])
        let analysis = try analyze(trapezoid, intent: .rectangular)

        XCTAssertTrue(analysis.requiresRescan)
        XCTAssertNil(analysis.suggestedBoundary)
    }

    func testConcaveLShapePreservesConcavityAndArea() throws {
        let shape = points([
            SIMD2(0, 0), SIMD2(0.8, 0), SIMD2(0.8, 0.2),
            SIMD2(0.3, 0.2), SIMD2(0.3, 0.6), SIMD2(0, 0.6)
        ])
        let analysis = try analyze(shape, intent: .irregular)

        XCTAssertEqual(analysis.normalizedRawBoundary.count, 6)
        XCTAssertEqual(analysis.suggestedBoundary?.count, 6)
        XCTAssertEqual(analysis.rawDimensions.areaSquareMetres, 0.28, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(analysis.suggestedDimensions).areaSquareMetres,
            analysis.rawDimensions.areaSquareMetres,
            accuracy: 0.000_001
        )
    }

    func testBowTieFourPointOrderIsRejectedWithoutSilentReordering() {
        let bowTie = points([
            SIMD2(0, 0), SIMD2(0.8, 0.4), SIMD2(0.8, 0), SIMD2(0, 0.4)
        ])
        XCTAssertThrowsError(try analyze(bowTie)) {
            XCTAssertEqual($0 as? ShelfBoundaryAnalysisError, .selfIntersection)
        }
    }

    func testDuplicateAndInvalidPointsAreRejected() {
        XCTAssertThrowsError(try analyze(points([
            SIMD2(0, 0), SIMD2(0.8, 0), SIMD2(0.8, 0), SIMD2(0, 0.4)
        ])))
        XCTAssertThrowsError(try analyze([
            SIMD3(.nan, 0, 0), SIMD3(0.8, 0, 0), SIMD3(0, 0, 0.4)
        ]))
    }

    func testPoorPlanarityIsRejected() {
        var value = rectangle(width: 0.8, depth: 0.4)
        value[2].y = 0.08
        XCTAssertThrowsError(try analyze(value)) {
            XCTAssertEqual($0 as? ShelfBoundaryAnalysisError, .poorPlanarity)
        }
    }

    func testTiltedPlanarShelfUsesLeastSquaresPlaneInsteadOfFlatteningY() throws {
        let tilted = rectangle(width: 0.8, depth: 0.4).map { point in
            SIMD3(point.x, 0.025 * point.x - 0.01 * point.z, point.z)
        }
        let analysis = try analyze(tilted)

        XCTAssertLessThan(analysis.planeMaximumResidualMetres, 0.000_01)
        XCTAssertGreaterThan(analysis.planeNormal.y, 0.99)
        XCTAssertGreaterThan(abs(analysis.planeNormal.x), 0.01)
    }

    func testExpectedDimensionConflictRequiresRescan() throws {
        let analysis = try ShelfBoundaryAnalyzer.analyze(
            points: rectangle(width: 0.8, depth: 0.4),
            cornerConfidence: Array(repeating: 0.9, count: 4),
            intent: .rectangular,
            expectedWidthCM: 120,
            expectedDepthCM: 40
        )
        XCTAssertTrue(analysis.requiresRescan)
        XCTAssertNil(analysis.suggestedBoundary)
    }

    func testCorrectionIsDeterministicForSameInputRevision() throws {
        let revision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var value = rectangle(width: 0.8, depth: 0.4)
        value[2].x += 0.008
        let first = try ShelfBoundaryAnalyzer.analyze(
            points: value,
            cornerConfidence: Array(repeating: 0.9, count: 4),
            intent: .automatic,
            inputRevision: revision
        )
        let second = try ShelfBoundaryAnalyzer.analyze(
            points: Array(value.reversed()),
            cornerConfidence: Array(repeating: 0.9, count: 4),
            intent: .automatic,
            inputRevision: revision
        )
        XCTAssertEqual(first.suggestedBoundary, second.suggestedBoundary)
    }

    func testRandomRotatedRectanglesRemainAccurate() throws {
        var generator = SeededGenerator(state: 0x12345678)
        for _ in 0..<100 {
            let width = Double.random(in: 0.2...2.0, using: &generator)
            let depth = Double.random(in: 0.1...1.0, using: &generator)
            let angle = Double.random(in: -.pi ... .pi, using: &generator)
            let translation = SIMD2(
                Double.random(in: -4...4, using: &generator),
                Double.random(in: -4...4, using: &generator)
            )
            let analysis = try analyze(transform(
                rectangle(width: width, depth: depth),
                angle: angle,
                translation: translation
            ))
            XCTAssertGreaterThanOrEqual(analysis.rectangleConfidence, 0.85)
            XCTAssertEqual(
                analysis.rawDimensions.widthMetres,
                max(width, depth),
                accuracy: 0.002
            )
            XCTAssertEqual(
                analysis.rawDimensions.depthMetres,
                min(width, depth),
                accuracy: 0.002
            )
        }
    }

    private func analyze(
        _ points: [SIMD3<Double>],
        intent: ShelfShapeIntent = .automatic
    ) throws -> ShelfBoundaryAnalysis {
        try ShelfBoundaryAnalyzer.analyze(
            points: points,
            cornerConfidence: Array(repeating: 0.9, count: points.count),
            intent: intent
        )
    }

    private func rectangle(width: Double, depth: Double) -> [SIMD3<Double>] {
        points([
            SIMD2(0, 0), SIMD2(width, 0),
            SIMD2(width, depth), SIMD2(0, depth)
        ])
    }

    private func points(_ points: [SIMD2<Double>]) -> [SIMD3<Double>] {
        points.map { SIMD3($0.x, 0, $0.y) }
    }

    private func transform(
        _ points: [SIMD3<Double>],
        angle: Double,
        translation: SIMD2<Double>
    ) -> [SIMD3<Double>] {
        points.map {
            let x = cos(angle) * $0.x - sin(angle) * $0.z + translation.x
            let z = sin(angle) * $0.x + cos(angle) * $0.z + translation.y
            return SIMD3(x, $0.y, z)
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class ApprovedShelfGeometryPlacementTests: XCTestCase {
    func testVersionTwoShelfRejectsUnapprovedSuggestion() {
        let result = PlacementEngine.calculate(
            package: package(),
            shelf: shelf(geometry: geometry(approval: .draft))
        )

        XCTAssertNil(result.recommendation)
        XCTAssertTrue(
            result.evaluations.flatMap(\.rejectionReasons).contains(.staleShelfState)
        )
    }

    func testApprovedRectangleSupportsPlacementWithoutMutatingPhysicalBoundary() throws {
        let record = geometry(approval: .approvedCorrection)
        let result = PlacementEngine.calculate(
            package: package(),
            shelf: shelf(geometry: record)
        )

        XCTAssertNotNil(result.recommendation)
        XCTAssertEqual(record.approvedBoundary.first?.x, 0)
        XCTAssertEqual(record.placementSafetyMarginCM, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.recommendation).position.x, 1)
    }

    func testConcaveApprovedBoundaryDoesNotUseCutoutAsShelfSpace() throws {
        let footprint = [
            Vector3D(0, 0, 0), Vector3D(100, 0, 0),
            Vector3D(100, 0, 40), Vector3D(40, 0, 40),
            Vector3D(40, 0, 100), Vector3D(0, 0, 100)
        ]
        var record = geometry(approval: .approvedRaw)
        record.rawBoundary = footprint
        record.approvedBoundary = footprint
        record.correctedBoundary = footprint
        record.detectedShapeType = .irregularPolygon

        let placement = try XCTUnwrap(
            PlacementEngine.calculate(
                package: package(),
                shelf: shelf(geometry: record)
            ).recommendation
        )
        let centreX = placement.position.x + placement.orientedDimensions.widthCM / 2
        let centreZ = placement.position.z + placement.orientedDimensions.depthCM / 2
        XCTAssertFalse(centreX > 40 && centreZ > 40)
    }

    private func package() -> PackagePlacementProfile {
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 2
        return PackagePlacementProfile(
            productId: "product",
            dimensions: PackageDimensions(widthCM: 20, heightCM: 20, depthCM: 20),
            weightKG: 2,
            demandVelocity: 0.5,
            metadata: metadata
        )
    }

    private func shelf(geometry: ShelfGeometryRecord) -> ShelfState {
        let boundary = AxisAlignedVolume(
            id: "boundary",
            minimum: Vector3D(0, 0, 0),
            dimensions: PackageDimensions(widthCM: 100, heightCM: 100, depthCM: 100)
        )
        return ShelfState(
            id: "shelf", label: "Shelf", barcode: "LOC", version: 2,
            boundary: boundary,
            coordinateSystem: ShelfLocalCoordinateSystem(
                anchorOrigin: Vector3D(0, 0, 0),
                widthAxis: Vector3D(1, 0, 0),
                upAxis: Vector3D(0, 1, 0),
                depthAxis: Vector3D(0, 0, 1)
            ),
            primaryFrontDirection: Vector3D(0, 0, 1),
            secondaryAccessDirections: [],
            compartments: [ShelfCompartment(
                id: "main", label: "Main", volume: boundary, ratedWeightKG: 100
            )],
            obstacles: [], products: [],
            scanQuality: ShelfScanQuality(
                hasClosedBoundary: true,
                missingSurfaceCount: 0,
                trackingDriftCM: 0,
                confidence: 0.9,
                capturedAt: .now
            ),
            geometry: geometry,
            ratedWeightKG: 100,
            updatedAt: .now
        )
    }

    private func geometry(
        approval: ShelfGeometryApproval
    ) -> ShelfGeometryRecord {
        let footprint = [
            Vector3D(0, 0, 0), Vector3D(100, 0, 0),
            Vector3D(100, 0, 100), Vector3D(0, 0, 100)
        ]
        return ShelfGeometryRecord(
            version: 1,
            inputRevision: UUID(),
            rawBoundary: footprint,
            correctedBoundary: footprint,
            approvedBoundary: approval == .draft ? [] : footprint,
            detectedShapeType: .rectangle,
            requestedShapeIntent: .automatic,
            boundaryMeaning: .innerUsable,
            correctionConfidence: 0.9,
            scanConfidence: 0.9,
            correctionReasons: [],
            approval: approval,
            approvedAt: approval == .draft ? nil : .now,
            placementSafetyMarginCM: 1,
            measurementMetadata: ShelfMeasurementMetadata(
                capturedAt: .now,
                deviceModel: "test",
                hasLiDAR: true,
                coordinateSpace: .shelfLocal,
                unit: .centimetres,
                planeRMSResidualMetres: 0.001,
                planeMaximumResidualMetres: 0.002,
                cornerMeasurements: [],
                expectedWidthCM: nil,
                expectedDepthCM: nil
            )
        )
    }
}
