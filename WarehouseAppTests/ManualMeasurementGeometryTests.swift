import XCTest
@testable import WarehouseApp

final class ManualMeasurementGeometryTests: XCTestCase {
    private let acceptedDecision = LiDARAcceptanceDecision(
        status: .accepted,
        failures: [],
        warnings: [],
        fallbacks: []
    )

    func testFinishIsAvailableForAnAcceptedOrQualifiedMeasurement() {
        let dimensions = ObjectDimensions(length: 20, width: 10, height: 15)
        let corners = Array(repeating: SIMD3<Float>(0, 0, 0), count: 8)
        var qualified = acceptedDecision
        qualified.status = .qualified
        qualified.warnings = [.nearbyObjectClose]

        for decision in [acceptedDecision, qualified] {
            XCTAssertTrue(ManualProductScanStatus.finishIsAvailable(
                decision: decision,
                dimensions: dimensions,
                boundingBoxCornersWorld: corners
            ))
        }
    }

    func testFinishIsRefusedWhenAcceptanceRefusesEvenWithACompleteBox() {
        let dimensions = ObjectDimensions(length: 20, width: 10, height: 15)
        let corners = Array(repeating: SIMD3<Float>(0, 0, 0), count: 8)
        let refused = LiDARAcceptanceDecision(
            status: .refused,
            failures: [.regionBoundaryContact],
            warnings: [],
            fallbacks: []
        )

        XCTAssertFalse(ManualProductScanStatus.finishIsAvailable(
            decision: refused,
            dimensions: dimensions,
            boundingBoxCornersWorld: corners
        ))
    }

    func testIncompleteOrangeBoxCannotFinish() {
        let dimensions = ObjectDimensions(length: 20, width: 10, height: 15)
        let corners = Array(repeating: SIMD3<Float>(0, 0, 0), count: 7)

        XCTAssertFalse(ManualProductScanStatus.finishIsAvailable(
            decision: acceptedDecision,
            dimensions: dimensions,
            boundingBoxCornersWorld: corners
        ))
    }

    @MainActor
    func testFinishProductScanTransitionsToReview() {
        let dimensions = ObjectDimensions(length: 20, width: 10, height: 15)
        let corners = Array(repeating: SIMD3<Float>(0, 0, 0), count: 8)
        let status = ManualProductScanStatus(
            stablePointCount: ObjectScanValidation.minimumPointCount,
            detectedDimensionsCM: dimensions,
            boundingBoxCornersWorld: corners,
            canFinish: true,
            decision: acceptedDecision
        )

        let state = ManualARMeasurementState()
        state.updateTracking(.normal)
        state.updateProductScan(status)
        state.finishProductScan()

        XCTAssertEqual(state.stage, .review)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testFinishProductScanIsRejectedWhileTrackingIsNotNormal() {
        let status = ManualProductScanStatus(
            detectedDimensionsCM: ObjectDimensions(length: 20, width: 10, height: 15),
            boundingBoxCornersWorld: Array(repeating: SIMD3<Float>(0, 0, 0), count: 8),
            canFinish: true,
            decision: acceptedDecision
        )
        let state = ManualARMeasurementState()
        state.updateTracking(.limited(.excessiveMotion))
        state.updateProductScan(status)
        state.finishProductScan()

        XCTAssertNotEqual(state.stage, .review)
        XCTAssertNotNil(state.statusReason)
    }

    @MainActor
    func testTrackingResetStopsTheScanAndDiscardsItsResult() {
        let state = stateReadyToScan()
        state.startProductScan()
        state.updateProductScan(ManualProductScanStatus(
            detectedDimensionsCM: ObjectDimensions(length: 20, width: 10, height: 15),
            boundingBoxCornersWorld: Array(repeating: SIMD3<Float>(0, 0, 0), count: 8),
            canFinish: true,
            decision: acceptedDecision
        ))
        XCTAssertTrue(state.productScanIsActive)

        state.handleTrackingReset()

        XCTAssertFalse(state.productScanIsActive)
        XCTAssertNil(state.productScanStatus.detectedDimensionsCM)
        XCTAssertFalse(state.productScanStatus.canFinish)
        XCTAssertEqual(state.stage, .productScan)
        XCTAssertNotNil(state.errorMessage)
    }

    @MainActor
    func testContinuingFromReviewClearsThePreviousResult() {
        let state = stateReadyToScan()
        state.startProductScan()
        state.updateProductScan(ManualProductScanStatus(
            detectedDimensionsCM: ObjectDimensions(length: 20, width: 10, height: 15),
            boundingBoxCornersWorld: Array(repeating: SIMD3<Float>(0, 0, 0), count: 8),
            canFinish: true,
            decision: acceptedDecision
        ))
        state.finishProductScan()
        XCTAssertEqual(state.stage, .review)

        state.restartProductScan()

        XCTAssertEqual(state.stage, .productScan)
        XCTAssertTrue(state.productScanIsActive)
        XCTAssertNil(state.productScanStatus.detectedDimensionsCM)
        XCTAssertFalse(state.productScanStatus.canFinish)
    }

    @MainActor
    func testFinishProductScanIsRejectedWithTheMissingEvidence() {
        let guidance = LiDARMeasurementGuidance.message(for: .insufficientViewpoints)
        let status = ManualProductScanStatus(
            detectedDimensionsCM: ObjectDimensions(length: 20, width: 10, height: 15),
            boundingBoxCornersWorld: Array(repeating: SIMD3<Float>(0, 0, 0), count: 8),
            decision: LiDARAcceptanceDecision(
                status: .refused,
                failures: [.insufficientViewpoints],
                warnings: [],
                fallbacks: []
            ),
            guidance: [guidance]
        )

        let state = ManualARMeasurementState()
        state.updateProductScan(status)
        state.finishProductScan()

        XCTAssertNotEqual(state.stage, .review)
        XCTAssertEqual(state.statusReason, guidance)
    }

    func testInteriorPointOfConcaveBoundaryLiesInsideIt() throws {
        // A "C" whose vertex mean and area centroid both fall in the notch.
        let polygon: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(0.30, 0), SIMD2(0.30, 0.05), SIMD2(0.05, 0.05),
            SIMD2(0.05, 0.25), SIMD2(0.30, 0.25), SIMD2(0.30, 0.30), SIMD2(0, 0.30)
        ]
        let mean = polygon.reduce(SIMD2<Double>.zero, +) / Double(polygon.count)
        XCTAssertFalse(ManualMeasurementGeometry.contains(mean, in: polygon))

        let interior = try XCTUnwrap(ManualMeasurementGeometry.interiorPoint(of: polygon))
        XCTAssertTrue(ManualMeasurementGeometry.contains(interior, in: polygon))
    }

    func testInteriorPointOfConvexBoundaryIsItsCentroid() throws {
        let square: [SIMD2<Double>] = [
            SIMD2(-0.1, -0.1), SIMD2(0.1, -0.1), SIMD2(0.1, 0.1), SIMD2(-0.1, 0.1)
        ]
        let interior = try XCTUnwrap(ManualMeasurementGeometry.interiorPoint(of: square))
        XCTAssertEqual(interior.x, 0, accuracy: 1e-9)
        XCTAssertEqual(interior.y, 0, accuracy: 1e-9)
    }

    @MainActor
    func testMissingRaycastDoesNotCreateAMeasurementPoint() {
        let state = ManualARMeasurementState()
        state.place(nil)

        XCTAssertTrue(state.boundaryMarkers.isEmpty)
        XCTAssertNil(state.bottomMarker)
        XCTAssertNil(state.topMarker)
        // Placement rejections are inline status text, not modal errors (D16).
        XCTAssertNotNil(state.statusReason)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testFloorHitCannotBeAcceptedAsTopPoint() throws {
        let state = ManualARMeasurementState()
        let first = sample([0, 0, 0])
        state.updatePreview(first)
        state.updateTracking(.normal)
        [
            first,
            sample([0.4, 0, 0]),
            sample([0.4, 0, 0.3]),
            sample([0, 0, 0.3])
        ].forEach(state.place)
        state.closeBoundary()
        state.confirmBase()
        state.place(sample([0.1, 0, 0.1]))

        state.place(sample([0.2, 0, 0.2]))

        XCTAssertEqual(state.stage, .topLimit)
        XCTAssertNil(state.topMarker)
        // Placement rejections are inline status text, not modal errors (D16).
        XCTAssertNotNil(state.statusReason)
    }

    func testRotatedRectangleProducesOrientationIndependentDimensions() throws {
        let angle = Float.pi / 6
        let cosine = cos(angle)
        let sine = sin(angle)
        let local: [SIMD2<Float>] = [
            [-0.2, -0.1], [0.2, -0.1], [0.2, 0.1], [-0.2, 0.1]
        ]
        let points = local.map {
            SIMD3<Float>($0.x * cosine - $0.y * sine, 0.7, $0.x * sine + $0.y * cosine)
        }
        let result = try ManualMeasurementGeometry.measureBoundary(points)
        XCTAssertEqual(result.footprint.lengthMetres, 0.4, accuracy: 0.000_01)
        XCTAssertEqual(result.footprint.widthMetres, 0.2, accuracy: 0.000_01)
        XCTAssertEqual(result.footprint.areaSquareMetres, 0.08, accuracy: 0.000_01)
    }

    func testTopDirectlyAboveFloorUsesWorldUpHeight() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.4, 0.04, 0], [0.4, 0.04, 0.3], [0, 0, 0.3]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        let base = SIMD3<Float>(0.2, 0.02, 0.15)
        let measured = try ManualMeasurementGeometry.height(
            top: base + SIMD3<Float>(0, 0.5, 0),
            bottom: base,
            boundary: boundary
        )
        XCTAssertEqual(measured, 0.5, accuracy: 0.000_01)
    }

    func testHorizontalOffsetDoesNotIncreaseHeight() throws {
        let boundary = try horizontalBoundary()
        let measured = try ManualMeasurementGeometry.height(
            top: [0.30, 0.50, 0.20],
            bottom: [0.10, 0, 0.10],
            boundary: boundary
        )
        XCTAssertEqual(measured, 0.5, accuracy: 0.000_01)
    }

    func testReversedPointOrderProducesSameHeight() throws {
        let boundary = try horizontalBoundary()
        let lower = SIMD3<Float>(0.10, 0, 0.10)
        let upper = SIMD3<Float>(0.20, 0.50, 0.20)
        let forward = try ManualMeasurementGeometry.height(
            top: upper,
            bottom: lower,
            boundary: boundary
        )
        let reversed = try ManualMeasurementGeometry.height(
            top: lower,
            bottom: upper,
            boundary: boundary
        )
        XCTAssertEqual(forward, reversed, accuracy: 0.000_01)
    }

    func testDeviceOrientationDoesNotChangeWorldSpaceHeight() throws {
        let boundary = try horizontalBoundary()
        let bottom = SIMD3<Float>(0.10, 0, 0.10)
        for quarterTurns in 0..<4 {
            let angle = Float(quarterTurns) * .pi / 2
            let horizontalOffset = SIMD3<Float>(
                cos(angle) * 0.10,
                0,
                sin(angle) * 0.10
            )
            let measured = try ManualMeasurementGeometry.height(
                top: bottom + horizontalOffset + SIMD3<Float>(0, 0.40, 0),
                bottom: bottom,
                boundary: boundary
            )
            XCTAssertEqual(measured, 0.40, accuracy: 0.000_01)
        }
    }

    func testFiveCentimetreHeightIsAccepted() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.08, 0, 0], [0.08, 0, 0.06], [0, 0, 0.06]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        let measured = try ManualMeasurementGeometry.height(
            top: [0.04, 0.05, 0.03],
            bottom: [0.04, 0, 0.03],
            boundary: boundary
        )
        XCTAssertEqual(measured, 0.05, accuracy: 0.000_01)
    }

    func testBoundaryIsNotRejectedByFormerFiveMetreLimit() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [6, 0, 0], [6, 0, 0.1], [0, 0, 0.1]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        XCTAssertEqual(boundary.footprint.lengthMetres, 6, accuracy: 0.000_01)
    }

    /// D10: corners tapped in a Z/diagonal order used to be rejected as a
    /// self-intersection; they are now reordered by angle around the
    /// centroid into the footprint the user actually marked.
    func testZOrderBoundaryTapsAreAccepted() throws {
        let zOrder: [SIMD3<Float>] = [
            [0, 0, 0], [0.3, 0, 0.3], [0, 0, 0.3], [0.3, 0, 0]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(zOrder)
        XCTAssertEqual(boundary.footprint.lengthMetres, 0.3, accuracy: 0.000_01)
        XCTAssertEqual(boundary.footprint.widthMetres, 0.3, accuracy: 0.000_01)
        XCTAssertEqual(boundary.footprint.areaSquareMetres, 0.09, accuracy: 0.000_01)
    }

    func testRejectsNonCoplanarBoundary() {
        // 30 cm out of plane: far beyond the relaxed 3.5 cm tolerance (the
        // old 10 cm corner now fits under the tilted least-squares plane).
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.4, 0, 0], [0.4, 0.3, 0.3], [0, 0, 0.3]
        ]
        XCTAssertThrowsError(try ManualMeasurementGeometry.measureBoundary(points))
    }

    func testConcavePolygonTriangulatesWithoutUsingAFanOutsideBoundary() {
        let polygon: [SIMD2<Double>] = [
            [0, 0], [2, 0], [2, 2], [1, 1], [0, 2]
        ]
        let indices = ManualMeasurementGeometry.triangulationIndices(for: polygon)
        XCTAssertEqual(indices.count, (polygon.count - 2) * 3)
        XCTAssertTrue(indices.allSatisfy { Int($0) < polygon.count })
    }

    /// A state with a 40 × 30 cm region and 20 cm of height, at Scan Product.
    @MainActor
    private func stateReadyToScan() -> ManualARMeasurementState {
        let state = ManualARMeasurementState()
        let first = sample([0, 0, 0])
        state.updatePreview(first)
        state.updateTracking(.normal)
        [first, sample([0.4, 0, 0]), sample([0.4, 0, 0.3]), sample([0, 0, 0.3])]
            .forEach(state.place)
        state.closeBoundary()
        state.confirmBase()
        state.place(sample([0.1, 0, 0.1]))
        state.place(sample([0.1, 0.2, 0.1]))
        XCTAssertEqual(state.stage, .productScan)
        return state
    }

    // MARK: - Phase 3 stabilization coverage

    @MainActor
    func testBottomMarkerBelowBasePlaneIsRejectedWithReason() {
        let state = confirmedBaseState()

        state.place(sample([0.1, -0.1, 0.1]))

        XCTAssertNil(state.bottomMarker)
        XCTAssertEqual(state.stage, .bottomLimit)
        XCTAssertEqual(
            state.statusReason,
            "Place the bottom marker on the product's base, inside the scanned boundary."
        )
    }

    @MainActor
    func testBottomMarkerFarOutsideFootprintIsRejected() {
        let state = confirmedBaseState()

        state.place(sample([1.5, 0, 1.5]))

        XCTAssertNil(state.bottomMarker)
        XCTAssertNotNil(state.statusReason)
    }

    @MainActor
    func testUndoAfterReplaceDoesNotTrapOnNextPlacement() {
        let state = confirmedBaseState()
        state.replaceBoundaryPoint(at: 3)

        state.undo()
        state.place(sample([0.9, 0, 0.9]))

        XCTAssertEqual(state.boundaryMarkers.count, 5)
        XCTAssertNil(state.statusReason)
    }

    @MainActor
    func testRelaxedPlaneScatterIsAcceptedWithConfidencePenalty() throws {
        let flat = boundaryState([
            [0, 0, 0], [0.4, 0, 0], [0.4, 0, 0.3], [0, 0, 0.3]
        ])
        let scattered = boundaryState([
            [0, 0.025, 0], [0.4, -0.025, 0], [0.4, 0.025, 0.3], [0, -0.025, 0.3]
        ])

        let measurement = try XCTUnwrap(scattered.boundaryMeasurement)
        XCTAssertGreaterThan(measurement.plane.maximumDeviation, 0.02)
        XCTAssertLessThan(scattered.confidence, flat.confidence)
    }

    func testFourCentimetreScatterIsStillRejected() {
        let points: [SIMD3<Float>] = [
            [0, 0.04, 0], [0.4, -0.04, 0], [0.4, 0.04, 0.3], [0, -0.04, 0.3]
        ]
        XCTAssertThrowsError(try ManualMeasurementGeometry.measureBoundary(points))
    }

    @MainActor
    func testConcaveFootprintSeedLiesInsideThePolygon() throws {
        let state = ManualARMeasurementState()
        state.updatePreview(sample([0, 0, 0]))
        state.updateTracking(.normal)
        [
            sample([0, 0, 0]),
            sample([0.2, 0, 0]),
            sample([0.2, 0, 0.2]),
            sample([0.1, 0, 0.02]),
            sample([0, 0, 0.2])
        ].forEach(state.place)
        state.closeBoundary()
        state.confirmBase()
        state.place(sample([0.03, 0, 0.03]))
        state.place(sample([0.03, 0.3, 0.03]))

        let region = try XCTUnwrap(state.productScanRegion)
        let seed = try XCTUnwrap(state.productSeed)
        XCTAssertTrue(region.contains(seed))

        // The vertex centroid this replaced falls outside the concave notch.
        let vertexCentre = region.polygon.reduce(SIMD2<Float>.zero, +)
            / Float(region.polygon.count)
        let vertexSeed = region.origin
            + region.axisU * vertexCentre.x
            + region.axisV * vertexCentre.y
            + region.normal * (region.lowerOffset + 0.02)
        XCTAssertFalse(region.contains(vertexSeed))
    }

    @MainActor
    func testBoundaryFallbackCaptureUsesMinimumAreaRectangleAndMarkerHeight() throws {
        let state = productScanReadyState()

        let capture = try XCTUnwrap(state.makeBoundaryFallbackCapture())

        XCTAssertEqual(capture.rawDimensionsCM.length, 40, accuracy: 0.01)
        XCTAssertEqual(capture.rawDimensionsCM.width, 30, accuracy: 0.01)
        XCTAssertEqual(capture.rawDimensionsCM.height, 50, accuracy: 0.01)
        XCTAssertEqual(capture.scanMethod, .standardAR)
        XCTAssertEqual(capture.confidence, 0.5)
        XCTAssertEqual(capture.manualMeasurement?.scanningRegionOnly, false)
    }

    @MainActor
    func testReplaceBottomKeepsGeometricallyValidTopMarker() {
        let state = productScanReadyState()

        state.replaceBottom()
        XCTAssertNotNil(state.topMarker)
        XCTAssertEqual(state.stage, .bottomLimit)

        state.place(sample([0.15, 0, 0.15]))

        XCTAssertNotNil(state.bottomMarker)
        XCTAssertNotNil(state.topMarker)
        XCTAssertEqual(state.stage, .productScan)
    }

    @MainActor
    func testReplaceBottomClearsTopThatBecomesInvalid() {
        // Top only 2 cm above the base: a replacement bottom placed above it
        // invalidates the retained top and returns to the top-limit stage.
        let state = confirmedBaseState()
        state.place(sample([0.1, 0, 0.1]))
        state.place(sample([0.1, 0.02, 0.1]))
        XCTAssertEqual(state.stage, .productScan)

        state.replaceBottom()
        state.place(sample([0.1, 0.025, 0.1]))

        XCTAssertNil(state.topMarker)
        XCTAssertEqual(state.stage, .topLimit)
    }

    @MainActor
    private func confirmedBaseState() -> ManualARMeasurementState {
        let state = ManualARMeasurementState()
        state.updatePreview(sample([0, 0, 0]))
        state.updateTracking(.normal)
        [
            sample([0, 0, 0]),
            sample([0.4, 0, 0]),
            sample([0.4, 0, 0.3]),
            sample([0, 0, 0.3])
        ].forEach(state.place)
        state.closeBoundary()
        state.confirmBase()
        return state
    }

    @MainActor
    private func productScanReadyState() -> ManualARMeasurementState {
        let state = confirmedBaseState()
        state.place(sample([0.1, 0, 0.1]))
        state.place(sample([0.1, 0.5, 0.1]))
        return state
    }

    @MainActor
    private func boundaryState(_ corners: [SIMD3<Float>]) -> ManualARMeasurementState {
        let state = ManualARMeasurementState()
        state.updatePreview(sample(corners[0]))
        state.updateTracking(.normal)
        corners.forEach { state.place(sample($0)) }
        state.closeBoundary()
        return state
    }

    private func horizontalBoundary() throws -> BoundaryMeasurement {
        try ManualMeasurementGeometry.measureBoundary([
            [0, 0, 0], [0.4, 0, 0], [0.4, 0, 0.3], [0, 0, 0.3]
        ])
    }

    private func sample(_ position: SIMD3<Float>) -> CentreRaycastSample {
        CentreRaycastSample(
            position: position,
            raycastType: "test",
            surfaceAlignment: "test surface",
            confidence: 1,
            cameraDistanceMetres: 0.5
        )
    }
}
