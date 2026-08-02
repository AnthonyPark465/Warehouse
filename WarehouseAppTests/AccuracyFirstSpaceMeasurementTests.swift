import XCTest
import simd
@testable import WarehouseApp

final class RobustSectionedEdgeTests: XCTestCase {
    func testRobustLineFitRejectsOutliersAndRetainsPhysicalCoverage() throws {
        var samples = (0..<12).map { index in
            observation(Double(index) * 0.05, Double(index % 2) * 0.002, index: index)
        }
        samples += [observation(0.2, 0.35, index: 100), observation(-0.3, -0.5, index: 101)]
        let result = RobustLineFitter.fit(observations: samples)
        let fit = try XCTUnwrap(result.fit)
        XCTAssertGreaterThanOrEqual(fit.inlierCount, 12)
        XCTAssertLessThan(fit.rmsResidualMetres, 0.003)
        XCTAssertGreaterThan(fit.physicalLengthMetres, 0.5)
        XCTAssertGreaterThanOrEqual(result.rejected, 2)
    }

    func testRepeatedCorrelatedFramesDoNotBecomeIndependentEvidence() throws {
        let base = Date(timeIntervalSince1970: 100)
        let samples = (0..<20).map { index in
            observation(Double(index) * 0.0001, 0, index: index,
                        date: base.addingTimeInterval(Double(index) * 0.01))
        }
        let result = RobustLineFitter.fit(observations: samples)
        XCTAssertLessThan(result.accepted.count, 6)
        XCTAssertNil(result.fit)
    }

    func testSingleFrameDirectionChangeDoesNotProposeCorner() {
        let acquisition = SectionedBoundaryAcquisition()
        for index in 0..<10 { acquisition.add(observation(Double(index) * 0.04, 0, index: index)) }
        acquisition.add(observation(0.36, 0.05, index: 20))
        XCTAssertNil(acquisition.proposedCorner)
        XCTAssertEqual(acquisition.phase, .tracingEdge)
    }

    func testLineIntersectionCarriesUncertainty() throws {
        let horizontal = line(point: .init(0, 0), direction: .init(1, 0), uncertainty: 0.004)
        let vertical = line(point: .init(1, -1), direction: .init(0, 1), uncertainty: 0.006)
        let corner = try XCTUnwrap(RobustLineFitter.intersection(horizontal, vertical))
        XCTAssertEqual(corner.position.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(corner.position.y, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(corner.uncertaintyMetres, 0.006)
    }

    func testNearlyParallelLinesCannotCreateCorner() {
        let first = line(point: .init(0, 0), direction: .init(1, 0), uncertainty: 0.004)
        let second = line(point: .init(0, 1), direction: .init(1, 0.02), uncertainty: 0.004)
        XCTAssertNil(RobustLineFitter.intersection(first, second))
    }

    func testConcaveTShapeIsPreservedAndWrongOrderRejected() {
        let t = [(0.0, 0.0), (3, 0), (3, 1), (2, 1), (2, 3), (1, 3), (1, 1), (0, 1)]
            .enumerated().map { observation($0.element.0, $0.element.1, index: $0.offset) }
        let processed = DefaultBoundaryProcessor().process(observations: t, configuration: .standard)
        XCTAssertEqual(processed.validationState, .valid)
        XCTAssertEqual(processed.simplified.count, 8)

        let wrong = [(0.0, 0.0), (3, 1), (3, 0), (0, 1)]
            .enumerated().map { observation($0.element.0, $0.element.1, index: $0.offset) }
        XCTAssertEqual(DefaultBoundaryProcessor().process(observations: wrong, configuration: .standard).validationState,
                       .selfIntersecting)
    }

    private func line(point: Vector2D, direction: Vector2D, uncertainty: Double) -> LineFit2D {
        .init(point: point, direction: direction, rmsResidualMetres: 0.002,
              maximumResidualMetres: 0.004, uncertaintyMetres: uncertainty,
              physicalLengthMetres: 1, spatialCoverage: 1,
              viewingAngleDiversityRadians: 0.3, independentSampleCount: 10, inlierCount: 10)
    }

    private func observation(
        _ x: Double, _ y: Double, index: Int, date: Date? = nil
    ) -> BorderObservation {
        BorderObservation(
            id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!,
            worldPosition: Vector3D(x, 0, y), localPosition: Vector2D(x, y),
            depthGradient: 0.1, normalDifference: 0.6, basePlaneDistance: 0.002,
            measurementDistance: 1, source: .smoothedSceneDepth, segmentType: .dropEdge,
            trackingState: .normal, confidence: 0.9,
            timestamp: date ?? Date(timeIntervalSince1970: Double(index)),
            viewingDirection: Vector3D(sin(Double(index) * 0.08), 0, -cos(Double(index) * 0.08))
        )
    }
}

final class ShapeSpecificMeasurementTests: XCTestCase {
    func testPerfectAndNoisyCirclesAreAccepted() throws {
        let perfect = circlePoints(radius: 0.6, noise: 0)
        let noisy = circlePoints(radius: 0.6, noise: 0.004)
        let perfectFit = try XCTUnwrap(RobustCircleFitter.fit(points: perfect))
        let noisyFit = try XCTUnwrap(RobustCircleFitter.fit(points: noisy))
        XCTAssertTrue(perfectFit.acceptedAsCircle)
        XCTAssertEqual(perfectFit.radiusMetres, 0.6, accuracy: 0.000_001)
        XCTAssertTrue(noisyFit.acceptedAsCircle)
        XCTAssertEqual(noisyFit.radiusMetres, 0.6, accuracy: 0.006)
    }

    func testOvalAndIncompleteArcAreNotAcceptedAsCircles() throws {
        let oval = (0..<36).map { index -> Vector2D in
            let angle = Double(index) * 2 * .pi / 36
            return Vector2D(0.8 * cos(angle), 0.5 * sin(angle))
        }
        let arc = (0..<24).map { index -> Vector2D in
            let angle = Double(index) * .pi / 23
            return Vector2D(0.6 * cos(angle), 0.6 * sin(angle))
        }
        XCTAssertFalse(try XCTUnwrap(RobustCircleFitter.fit(points: oval, inlierThresholdMetres: 0.1)).acceptedAsCircle)
        XCTAssertFalse(try XCTUnwrap(RobustCircleFitter.fit(points: arc)).acceptedAsCircle)
    }

    private func circlePoints(radius: Double, noise: Double) -> [Vector2D] {
        (0..<36).map { index in
            let angle = Double(index) * 2 * .pi / 36
            let offset = noise * sin(Double(index) * 1.7)
            return Vector2D((radius + offset) * cos(angle), (radius + offset) * sin(angle))
        }
    }
}

final class CompartmentPlaneMeasurementTests: XCTestCase {
    func testPlaneFitRejectsOutlierAndRecordsCoverage() throws {
        var samples: [PlaneObservation] = []
        var index = 0
        for x in 0..<4 { for z in 0..<4 {
            samples.append(planeObservation(Double(x) * 0.1, 0.001 * Double((x + z) % 2), Double(z) * 0.1, index: index))
            index += 1
        }}
        samples.append(planeObservation(0.1, 0.3, 0.1, index: 99))
        let fit = try XCTUnwrap(RobustPlaneFitter.fit(surface: .bottom, observations: samples))
        XCTAssertEqual(fit.inlierCount, 16)
        XCTAssertLessThan(fit.rmsResidualMetres, 0.002)
        XCTAssertGreaterThan(fit.sampleCoverageMetres, 0.3)
    }

    func testHiddenCornerRequiresSufficientNonContradictoryPlanes() {
        let valid = RectangularCompartmentEvaluator.evaluate(planes: [
            plane(.bottom, normal: .init(0, 1, 0)), plane(.back, normal: .init(0, 0, 1)),
            plane(.left, normal: .init(1, 0, 0)), plane(.right, normal: .init(-1, 0, 0))
        ])
        XCTAssertEqual(valid.approval, .proposed)
        let missing = RectangularCompartmentEvaluator.evaluate(planes: [plane(.bottom, normal: .init(0, 1, 0))])
        XCTAssertEqual(missing.approval, .rejected)
    }

    func testContradictoryPlanesAndTaperAndWarpAreRejected() {
        let contradictory = RectangularCompartmentEvaluator.evaluate(planes: [
            plane(.bottom, normal: .init(0, 1, 0)), plane(.back, normal: .init(0, 0, 1)),
            plane(.left, normal: .init(1, 0, 0)), plane(.right, normal: .init(0, 0, 1))
        ])
        XCTAssertEqual(contradictory.approval, .rejected)

        let base = [plane(.bottom, normal: .init(0, 1, 0)), plane(.back, normal: .init(0, 0, 1)),
                    plane(.left, normal: .init(1, 0, 0)), plane(.right, normal: .init(-1, 0, 0))]
        let tapered = RectangularCompartmentEvaluator.evaluate(
            planes: base, frontOpeningWidthMetres: 0.7, interiorWidthMetres: 0.8
        )
        XCTAssertTrue(tapered.isTapered)
        XCTAssertEqual(tapered.approval, .rejected)

        var warpedPlanes = base
        warpedPlanes[0].maximumResidualMetres = 0.03
        XCTAssertTrue(RectangularCompartmentEvaluator.evaluate(planes: warpedPlanes).isWarped)
    }

    func testShelfLipAndDividerAreExplicit() {
        let base = [plane(.bottom, normal: .init(0, 1, 0)), plane(.back, normal: .init(0, 0, 1)),
                    plane(.left, normal: .init(1, 0, 0)), plane(.right, normal: .init(-1, 0, 0))]
        let lip = RectangularCompartmentEvaluator.evaluate(
            planes: base, frontOpeningWidthMetres: 0.74, interiorWidthMetres: 0.8,
            frontOpeningHeightMetres: 0.35, interiorHeightMetres: 0.4
        )
        XCTAssertTrue(lip.hasFrontLip)
        let divider = RectangularCompartmentEvaluator.evaluate(planes: base, dividerOrExclusionDetected: true)
        XCTAssertTrue(divider.requiresSeparateCompartmentsOrExclusions)
        XCTAssertEqual(divider.approval, .rejected)
    }

    private func planeObservation(_ x: Double, _ y: Double, _ z: Double, index: Int) -> PlaneObservation {
        .init(id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))!,
              position: Vector3D(x, y, z), viewingDirection: Vector3D(sin(Double(index) * 0.1), -1, -1),
              confidence: 0.9, trackingState: .normal)
    }

    private func plane(_ surface: CompartmentSurface, normal: Vector3D) -> FittedCompartmentPlane {
        .init(surface: surface, plane: CodablePlane(origin: Vector3D(0, 0, 0), normal: normal),
              rmsResidualMetres: 0.002, maximumResidualMetres: 0.004, uncertaintyMetres: 0.004,
              sampleCoverageMetres: 0.4, viewingDiversityRadians: 0.3, inlierCount: 12,
              evidenceState: .accepted)
    }
}

final class MeasurementAccuracyPolicyTests: XCTestCase {
    func testThresholdsAtEveryDistanceBoundary() {
        XCTAssertEqual(MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 1), 0.02, accuracy: 1e-9)
        XCTAssertEqual(MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 3), 0.04, accuracy: 1e-9)
        XCTAssertEqual(MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 5), 0.05, accuracy: 1e-9)
        XCTAssertEqual(MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 8), 0.08, accuracy: 1e-9)
        XCTAssertEqual(MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 20), 0.10, accuracy: 1e-9)
    }

    func testOverFiveCentimetresIsApproximatePlanningOnlyForLargeSpace() {
        let value = uncertainty(dimension: 8, uncertainty: 0.06)
        XCTAssertEqual(MeasurementAccuracyPolicy.evaluate(value, fitCritical: false).use, .approximatePlanning)
        XCTAssertEqual(MeasurementAccuracyPolicy.evaluate(value, fitCritical: true).use, .manualOnly)
    }

    func testAboveFivePercentRequiresManualDimensions() {
        XCTAssertEqual(MeasurementAccuracyPolicy.evaluate(
            uncertainty(dimension: 0.5, uncertainty: 0.026), fitCritical: false
        ).use, .manualOnly)
    }

    func testConservativeDimensionDoesNotDoubleCountClearance() {
        let result = ConservativeDimensionCalculator.calculate(
            measuredMetres: 1, uncertaintyMetres: 0.01, clearancePerSideMetres: [0.005, 0.005]
        )
        XCTAssertEqual(result.conservativeUsableMetres, 0.98, accuracy: 1e-9)
        XCTAssertEqual(result.clearancePerSideMetres.reduce(0, +), 0.01, accuracy: 1e-9)
    }

    func testFitWithinTwiceUncertaintyIsUncertain() {
        let result = ConservativeDimensionCalculator.calculate(
            measuredMetres: 1, uncertaintyMetres: 0.01, clearancePerSideMetres: []
        )
        XCTAssertEqual(ConservativeDimensionCalculator.productFit(productMetres: 0.975, usable: result),
                       .uncertainVerifyManually)
        XCTAssertEqual(ConservativeDimensionCalculator.productFit(productMetres: 0.95, usable: result), .fits)
    }

    private func uncertainty(dimension: Double, uncertainty: Double) -> DimensionUncertainty {
        .init(measuredMetres: dimension, estimatedUncertaintyMetres: uncertainty,
              robustFitResidualMetres: uncertainty / 2, repeatabilityMetres: uncertainty / 2,
              spatialCoverage: 0.9, viewingDiversityRadians: 0.3, closureErrorMetres: 0.003,
              inferencePenaltyMetres: 0, correctionDisplacementMetres: 0,
              correlatedSampleFraction: 0.1)
    }
}

final class LargeSpaceZoneTests: XCTestCase {
    func testOverlappingZonesAcceptAgreementAndRejectDisagreement() {
        let ids = (0..<3).map { UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", $0 + 1))! }
        let first = zone(ids: ids, offset: 0)
        XCTAssertTrue(LargeSpaceZoneValidator.compare(first, zone(ids: ids, offset: 0.01), toleranceMetres: 0.03).accepted)
        XCTAssertFalse(LargeSpaceZoneValidator.compare(first, zone(ids: ids, offset: 0.08), toleranceMetres: 0.03).accepted)
    }

    func testApproximateGlobalGeometryCannotAuthorizeCloseFit() {
        let approximate = LargeScanZone(id: UUID(), checkpoints: [], globalUncertaintyMetres: 0.04,
                                        localPlacementUncertaintyMetres: nil)
        XCTAssertFalse(LargeSpaceZoneValidator.permitsCloseFit(approximate))
        var verified = approximate
        verified.localPlacementUncertaintyMetres = 0.004
        XCTAssertTrue(LargeSpaceZoneValidator.permitsCloseFit(verified))
    }

    private func zone(ids: [UUID], offset: Double) -> LargeScanZone {
        .init(id: UUID(), checkpoints: ids.enumerated().map {
            .init(id: $0.element, localPosition: Vector2D(Double($0.offset) + offset, offset), uncertaintyMetres: 0.005)
        }, globalUncertaintyMetres: 0.03, localPlacementUncertaintyMetres: nil)
    }
}
