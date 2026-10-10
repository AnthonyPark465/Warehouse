import XCTest
import simd
@testable import WarehouseApp

/// End-to-end and per-stage tests of the object-measurement pipeline on
/// SYNTHETIC scans (see `SyntheticScanFixtures.swift`). They verify logic and
/// reported evidence; they are not evidence of accuracy on a device.
final class LiDARMeasurementPipelineTests: XCTestCase {
    private let configuration = LiDARFusionConfiguration.smallObject
    /// Two voxels, the tolerance the existing engine tests use.
    private var toleranceCM: Double { Double(configuration.voxelSize) * 200 }

    private let box = SyntheticObject(
        shape: .box(size: SIMD3<Float>(0.08, 0.06, 0.04)),
        baseCentre: .zero
    )
    private let boxDimensions = ObjectDimensions(length: 8, width: 4, height: 6)

    // MARK: Required cases

    func testRectangularObjectOnHorizontalSupportIsAcceptedWithEvidence() throws {
        let report = scan(SyntheticScene(objects: [box], supportHalfExtent: 0.10))

        assertDimensions(report, boxDimensions)
        XCTAssertEqual(report.decision.status, .accepted, "\(report.decision)")
        let evidence = report.evidence
        XCTAssertEqual(evidence.frames.capturedFrameCount, 24)
        XCTAssertEqual(evidence.frames.acceptedFrameCountSinceReset, 24)
        XCTAssertGreaterThan(evidence.voxels.stableVoxelCount, configuration.minimumStableVoxelCount)
        let support = try XCTUnwrap(evidence.supportPlane)
        XCTAssertEqual(support.method, LiDARSupportPlaneEstimate.Method.histogramPeak.rawValue)
        XCTAssertEqual(support.coordinateMetres, 0, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(support.voxelsBeyondFootprint), 24)
        XCTAssertEqual(
            evidence.components?.connectivityMode,
            LiDARComponentSelection.Mode.strict.rawValue
        )
        XCTAssertTrue(evidence.boundaryContacts.isEmpty)
        XCTAssertNotNil(evidence.uncertaintyCM)
        XCTAssertEqual(evidence.stability?.state, LiDARStabilityAssessment.State.stable.rawValue)
        XCTAssertEqual(evidence.reportedDimensionsCM, report.reportedDimensionsCM)
        XCTAssertEqual(evidence.bounds?.measuredDimensionsCM, report.reportedDimensionsCM)
    }

    func testRotatedRectangularObjectUsesOrientedBounds() throws {
        var rotated = box
        rotated.yaw = 35 * .pi / 180
        let report = scan(SyntheticScene(objects: [rotated], supportHalfExtent: 0.10))

        assertDimensions(report, boxDimensions)
        // The fixture's +35° yaw maps its long axis to −35°, i.e. 55° modulo
        // a quarter turn.
        let yaw = try XCTUnwrap(report.evidence.bounds?.yawDegrees)
        XCTAssertEqual(yaw.truncatingRemainder(dividingBy: 90), 55, accuracy: 2)
        XCTAssertNotEqual(report.decision.status, .refused, "\(report.decision)")
    }

    func testSmallObjectInsideMuchLargerRegionIsMeasuredNotTheRegion() {
        let cube = SyntheticObject(shape: .box(size: SIMD3<Float>(0.03, 0.03, 0.03)), baseCentre: .zero)
        var scene = SyntheticScene(objects: [cube], supportHalfExtent: 0.25)
        scene.supportSpacing = 0.006
        let report = scan(
            scene,
            region: SyntheticRegions.prism(halfWidth: 0.25, upperOffset: 0.40)
        )

        assertDimensions(report, ObjectDimensions(length: 3, width: 3, height: 3))
        XCTAssertTrue(report.evidence.boundaryContacts.isEmpty)
        XCTAssertNotEqual(report.decision.status, .refused, "\(report.decision)")
    }

    func testObjectFarFromTheSeedIsRefusedRatherThanMeasured() {
        let offCentre = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.04, 0.04, 0.04)),
            baseCentre: SIMD3<Float>(0.15, 0, 0.10)
        )
        var scene = SyntheticScene(objects: [offCentre], supportHalfExtent: 0.25)
        scene.supportSpacing = 0.006
        let report = scan(scene, region: SyntheticRegions.prism(halfWidth: 0.25))

        XCTAssertNil(report.reportedDimensionsCM)
        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.decision.failures.contains(.noObjectNearSeed))
    }

    func testNeighbourSeparatedBySmallGapIsExcludedAndReported() throws {
        let gap: Float = 0.007
        let neighbour = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.06, 0.09, 0.08)),
            baseCentre: SIMD3<Float>(0.04 + gap + 0.03, 0, 0)
        )
        let report = scan(
            SyntheticScene(objects: [box, neighbour], supportHalfExtent: 0.16),
            region: SyntheticRegions.prism(halfWidth: 0.16)
        )

        assertDimensions(report, boxDimensions)
        XCTAssertEqual(report.decision.status, .qualified)
        XCTAssertTrue(report.decision.warnings.contains(.nearbyObjectClose))
        let rejected = try XCTUnwrap(report.evidence.components?.rejected.first)
        XCTAssertTrue(rejected.qualifiesAsObject)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(rejected.gapToSelectedMetres),
            Double(configuration.neighbourProximityWarningDistance)
        )
        XCTAssertTrue(report.guidance.contains { $0.contains("Move farther from the nearby") })
    }

    func testNeighbourTooCloseToSeparateIsRefusedAsAPossibleMerge() {
        // 4 mm puts the facing sides in adjacent voxels; connectivity alone
        // cannot tell the two objects apart.
        let neighbour = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.06, 0.09, 0.08)),
            baseCentre: SIMD3<Float>(0.04 + 0.004 + 0.03, 0, 0)
        )
        let report = scan(
            SyntheticScene(objects: [box, neighbour], supportHalfExtent: 0.16),
            region: SyntheticRegions.prism(halfWidth: 0.16)
        )

        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.decision.failures.contains(.possibleMergedObjects))
        XCTAssertEqual(report.evidence.coverage?.interiorPartitionDetected, true)
    }

    func testBackgroundObjectBehindTheProductIsExcluded() throws {
        let background = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.20, 0.12, 0.03)),
            baseCentre: SIMD3<Float>(0, 0, 0.02 + 0.04 + 0.015)
        )
        let report = scan(
            SyntheticScene(objects: [box, background], supportHalfExtent: 0.16),
            region: SyntheticRegions.prism(halfWidth: 0.16)
        )

        assertDimensions(report, boxDimensions)
        let components = try XCTUnwrap(report.evidence.components)
        XCTAssertGreaterThanOrEqual(components.rejectedComponentCount, 1)
        XCTAssertTrue(components.rejected.contains { $0.qualifiesAsObject })
        XCTAssertFalse(report.decision.warnings.contains(.nearbyObjectClose))
        XCTAssertNotEqual(report.decision.status, .refused, "\(report.decision)")
    }

    func testTransientSingleFrameOutliersAreRejected() throws {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        let clean = SyntheticScanner.frames(scene: scene, plan: plan())
        var disturbed = clean
        // A dense patch just above and beside the product, in one frame, then
        // a different patch in two frames: neither reaches three frames.
        disturbed[5].points += patch(centre: SIMD3<Float>(0.045, 0.075, 0), halfSize: 0.012)
        disturbed[9].points += patch(centre: SIMD3<Float>(-0.05, 0.03, 0.03), halfSize: 0.012)
        disturbed[10].points += patch(centre: SIMD3<Float>(-0.05, 0.03, 0.03), halfSize: 0.012)

        let cleanReport = run(clean)
        let disturbedReport = run(disturbed)

        XCTAssertEqual(disturbedReport.reportedDimensionsCM, cleanReport.reportedDimensionsCM)
        XCTAssertGreaterThan(
            disturbedReport.evidence.voxels.transientVoxelCount,
            cleanReport.evidence.voxels.transientVoxelCount
        )
    }

    func testSparseSurfaceUsesExpandedConnectivityAndRecordsTheFallback() throws {
        let frames = repeatedOrbit(latticeBox() + tablePoints())

        let report = run(frames)

        let components = try XCTUnwrap(report.evidence.components)
        XCTAssertEqual(components.connectivityMode, LiDARComponentSelection.Mode.expanded.rawValue)
        XCTAssertEqual(
            components.fallbackReason,
            LiDARComponentSelection.FallbackReason.noQualifyingStrictComponent.rawValue
        )
        XCTAssertTrue(report.decision.fallbacks.contains(.expandedConnectivityUsed))
        XCTAssertEqual(report.evidence.fallbackCodes, ["expandedConnectivityUsed"])
        assertDimensions(report, latticeBoxDimensions)

        // The fallback was necessary: strict connectivity alone finds nothing.
        var strictOnly = configuration
        strictOnly.connectivityRadiusInVoxels = strictOnly.strictConnectivityRadiusInVoxels
        let strictReport = run(frames, configuration: strictOnly)
        XCTAssertNil(strictReport.reportedDimensionsCM)
        XCTAssertTrue(strictReport.decision.failures.contains(.insufficientConnectedGeometry))
    }

    func testExpandedConnectivityStillRejectsAnUnrelatedObjectWithinBridgingReach() throws {
        // A densely scanned neighbour whose side is two voxels from the
        // sparse product: inside the expanded radius, but object-sized on its
        // own, so it must never be absorbed.
        let neighbour = denseBox(
            minimum: SIMD3<Int32>(16, 0, -10),
            maximum: SIMD3<Int32>(30, 26, 10)
        )
        let report = run(repeatedOrbit(latticeBox() + neighbour + tablePoints()))

        let components = try XCTUnwrap(report.evidence.components)
        XCTAssertEqual(components.connectivityMode, LiDARComponentSelection.Mode.expanded.rawValue)
        assertDimensions(report, latticeBoxDimensions)
        XCTAssertTrue(report.decision.warnings.contains(.nearbyObjectClose))
        XCTAssertTrue(components.rejected.contains { $0.qualifiesAsObject })
    }

    func testExpandedConnectivityDoesNotBridgeToASparseObjectBeyondItsReach() {
        // Another sparse object four voxels away: beyond the expanded radius.
        let other = latticeBox(
            minimum: SIMD3<Int32>(18, 0, -6),
            maximum: SIMD3<Int32>(34, 20, 6)
        )
        let report = run(repeatedOrbit(latticeBox() + other + tablePoints()))

        assertDimensions(report, latticeBoxDimensions)
        XCTAssertEqual(
            report.evidence.components?.connectivityMode,
            LiDARComponentSelection.Mode.expanded.rawValue
        )
    }

    func testUnevenScanningCoverageIsReportedAndRaisesUncertainty() throws {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        let full = scan(scene)
        // A low camera sweeping 70° sees two sides and never the top.
        let partial = scan(scene, plan: plan(start: 10, sweep: 70, cameraHeight: 0.02))

        let coverage = try XCTUnwrap(partial.evidence.coverage)
        XCTAssertGreaterThanOrEqual(coverage.sparseSideCount, 1)
        XCTAssertTrue(partial.decision.warnings.contains(.sparseSideCoverage))
        XCTAssertTrue(partial.decision.warnings.contains(.topSurfaceSparse))
        XCTAssertNotEqual(partial.decision.status, .accepted)
        XCTAssertTrue(partial.guidance.contains { $0.contains("Scan another side") })
        let partialUncertainty = try XCTUnwrap(partial.evidence.uncertaintyCM)
        let fullUncertainty = try XCTUnwrap(full.evidence.uncertaintyCM)
        XCTAssertGreaterThan(
            partialUncertainty.length + partialUncertainty.width,
            fullUncertainty.length + fullUncertainty.width
        )
    }

    func testNarrowViewingArcIsRefusedAsInsufficientViewpoints() {
        let report = scan(
            SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            plan: plan(start: 20, sweep: 30)
        )

        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.decision.failures.contains(.insufficientViewpoints))
        XCTAssertTrue(report.guidance.contains { $0.contains("Scan another side") })
    }

    func testSupportPlaneNoiseDoesNotReduceObjectHeight() throws {
        var clean = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        var noisy = clean
        clean.supportNoiseSigma = 0
        noisy.supportNoiseSigma = 0.002

        let cleanReport = scan(clean)
        let noisyReport = scan(noisy)

        let cleanHeight = try XCTUnwrap(cleanReport.reportedDimensionsCM?.height)
        let noisyHeight = try XCTUnwrap(noisyReport.reportedDimensionsCM?.height)
        XCTAssertEqual(noisyHeight, cleanHeight, accuracy: 0.3)
        XCTAssertGreaterThan(noisyHeight, boxDimensions.height - 0.3)
        let support = try XCTUnwrap(noisyReport.evidence.supportPlane)
        XCTAssertEqual(support.coordinateMetres, 0, accuracy: 0.0015)
        XCTAssertGreaterThan(try XCTUnwrap(support.residualMetres), 0.001)
        // The band that was removed is wider than the height that was lost.
        XCTAssertGreaterThanOrEqual(support.removalBandMetres, 0.006)
    }

    func testSupportEstimateUsesThePlanePeakNotItsLowerNoiseTail() throws {
        var random = SyntheticRandom(seed: 11)
        let sigma: Float = 0.002
        var heights = (0..<6_000).map { _ in random.gaussian() * sigma }
        heights += (0..<1_500).map { _ in random.uniform(0.0...0.06) }

        let estimate = try XCTUnwrap(
            LiDARSupportPlaneEstimator.estimate(heights: heights, configuration: configuration)
        )

        XCTAssertEqual(estimate.method, .histogramPeak)
        XCTAssertEqual(estimate.coordinate, 0, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(estimate.residual), sigma, accuracy: sigma * 0.3)
        // The mean of the lowest populated bin, which the engine used before,
        // sits well below the plane and would have added to the height.
        let lowestBinMean = lowestQualifyingBinMean(heights)
        XCTAssertLessThan(lowestBinMean, -0.002)
    }

    func testVeryNoisySupportCapsTheRemovalBandAndIsReported() throws {
        var random = SyntheticRandom(seed: 5)
        let heights = (0..<6_000).map { _ in random.gaussian() * 0.005 }

        let estimate = try XCTUnwrap(
            LiDARSupportPlaneEstimator.estimate(heights: heights, configuration: configuration)
        )

        XCTAssertTrue(estimate.removalBandWasCapped)
        XCTAssertEqual(estimate.removalBand, configuration.maximumSupportPlaneNoiseBand)

        // A surface whose error does not average out across frames (the
        // same rough heights in every frame) stays noisy after fusion.
        let roughTable = SyntheticVoxelShapes.plane().map {
            $0 + SIMD3<Float>(0, random.gaussian() * 0.005, 0)
        }
        let product = SyntheticVoxelShapes.shell(
            minimum: SIMD3<Int32>(-13, 0, -8),
            maximum: SIMD3<Int32>(13, 20, 8)
        )
        let report = LiDARMeasurementSession(configuration: configuration).run(
            repeatedOrbit(product + roughTable),
            region: SyntheticRegions.prism(lowerOffset: -0.03),
            seed: SyntheticRegions.seed()
        )
        XCTAssertTrue(report.decision.warnings.contains(.supportPlaneNoisy), "\(report.decision)")
        XCTAssertEqual(report.evidence.supportPlane?.removalBandWasCapped, true)
    }

    func testHeightsWithNoSurfaceFallBackAndAreReportedAsNoSupport() throws {
        var random = SyntheticRandom(seed: 9)
        let heights = (0..<600).map { _ in random.uniform(0.0...0.30) }

        let estimate = try XCTUnwrap(
            LiDARSupportPlaneEstimator.estimate(heights: heights, configuration: configuration)
        )

        XCTAssertEqual(estimate.method, .percentileFallback)
        XCTAssertNil(estimate.residual)
        XCTAssertEqual(estimate.inlierCount, 0)
    }

    func testNothingIsFusedOrMeasuredBeforeASelectionIsLocked() {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)

        let result = engine.integrate(frame: boxFrames()[0])

        XCTAssertEqual(result.disposition, .rejected(.noSelectionLocked))
        XCTAssertEqual(engine.voxelCount, 0)
        XCTAssertEqual(engine.analyze().failures, [.noSelectionLocked])
        XCTAssertNil(engine.measurement())
    }

    func testObjectTouchingEachBoxRegionFaceIsReported() {
        let cases: [(face: LiDARRegionFace, centre: SIMD3<Float>, half: SIMD3<Float>)] = [
            (.side(0), SIMD3(-0.043 + 0.10, 0.045, 0), SIMD3(0.10, 0.055, 0.10)),
            (.side(1), SIMD3(0.043 - 0.10, 0.045, 0), SIMD3(0.10, 0.055, 0.10)),
            (.side(2), SIMD3(0, 0.045, -0.023 + 0.10), SIMD3(0.10, 0.055, 0.10)),
            (.side(3), SIMD3(0, 0.045, 0.023 - 0.10), SIMD3(0.10, 0.055, 0.10)),
            (.top, SIMD3(0, 0.0265, 0), SIMD3(0.10, 0.0365, 0.10))
        ]
        for testCase in cases {
            let region = LiDARSpatialRegion.box(
                LiDARScanVolume(centre: testCase.centre, halfExtents: testCase.half)
            )
            let report = scan(
                SyntheticScene(objects: [box], supportHalfExtent: 0.20),
                region: region,
                seed: SIMD3<Float>(0, 0.01, 0)
            )

            XCTAssertEqual(
                report.evidence.boundaryContacts.map(\.face),
                [testCase.face.label],
                "face \(testCase.face.label)"
            )
            XCTAssertEqual(report.decision.status, .refused)
            XCTAssertTrue(report.decision.failures.contains(.regionBoundaryContact))
            XCTAssertTrue(report.guidance.contains {
                $0.contains("touches the selected scan boundary")
            })
        }
    }

    func testObjectTouchingEachPrismEdgeIsReported() {
        // Polygon edges in order: −Z, +X, +Z, −X.
        let offsets: [(edge: Int, centre: SIMD2<Float>)] = [
            (0, SIMD2(0, 0.10 - 0.023)),
            (1, SIMD2(0.043 - 0.10, 0)),
            (2, SIMD2(0, 0.023 - 0.10)),
            (3, SIMD2(0.10 - 0.043, 0))
        ]
        for testCase in offsets {
            let report = scan(
                SyntheticScene(objects: [box], supportHalfExtent: 0.20),
                region: SyntheticRegions.prism(halfWidth: 0.10, centre: testCase.centre),
                seed: SIMD3<Float>(0, 0.01, 0)
            )

            XCTAssertEqual(
                report.evidence.boundaryContacts.map(\.face),
                [LiDARRegionFace.side(testCase.edge).label],
                "edge \(testCase.edge)"
            )
            XCTAssertTrue(report.decision.failures.contains(.regionBoundaryContact))
        }
    }

    func testRegionWhoseBottomLimitCutsTheProductReportsMissingSupport() {
        let report = scan(
            SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            region: SyntheticRegions.prism(lowerOffset: 0.02),
            seed: SIMD3<Float>(0, 0.03, 0)
        )

        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(
            report.decision.failures.contains(.supportNotBeyondFootprint)
                || report.decision.failures.contains(.supportPlaneNotFound),
            "\(report.decision)"
        )
        XCTAssertTrue(report.guidance.contains { $0.contains("surface under the product") })
    }

    func testUnstableEstimatesFollowedByRecovery() {
        var analyzer = LiDARStabilityAnalyzer(configuration: configuration)
        let product = ObjectDimensions(length: 8, width: 4, height: 6)
        let jumped = ObjectDimensions(length: 16, width: 12, height: 9)

        XCTAssertEqual(analyzer.consider(product).state, .warmingUp)
        XCTAssertEqual(analyzer.consider(product).state, .warmingUp)
        XCTAssertEqual(analyzer.consider(product).state, .stable)

        let disturbed = analyzer.consider(jumped)
        XCTAssertEqual(disturbed.state, .unstable)
        XCTAssertTrue(disturbed.jumpDetected)
        XCTAssertEqual(analyzer.stable, product)

        let recovered = analyzer.consider(product)
        XCTAssertEqual(recovered.state, .stable)
        XCTAssertFalse(recovered.jumpDetected)
        XCTAssertFalse(recovered.sustainedJumpAdopted)
    }

    func testUnstableDimensionsBlockAcceptanceUntilTheyAgree() {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        let frames = SyntheticScanner.frames(scene: scene, plan: plan())
        let session = LiDARMeasurementSession(configuration: configuration)
        session.begin(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())

        var sawUnstable = false
        var final = LiDARMeasurementReport()
        for frame in frames {
            final = session.process(frame)
            if final.reportedDimensionsCM != nil,
               final.decision.failures.contains(.dimensionsUnstable) {
                sawUnstable = true
                XCTAssertFalse(final.decision.allowsFinish)
            }
        }
        XCTAssertTrue(sawUnstable, "early estimates must not be finishable")
        XCTAssertTrue(final.dimensionsAreStable)
        XCTAssertTrue(final.decision.allowsFinish, "\(final.decision)")
    }

    func testStableEstimateKeepsRefiningInsteadOfFreezing() {
        var analyzer = LiDARStabilityAnalyzer(configuration: configuration)
        var last = LiDARStabilityAssessment(
            state: .warmingUp, estimateCount: 0, consistentEstimateCount: 0,
            spreadCM: nil, jumpDetected: false, sustainedJumpAdopted: false
        )
        // Each estimate grows by 2%: always within tolerance of its
        // neighbours, but 12% above the first by the end.
        for step in 0..<7 {
            let scale = pow(1.02, Double(step))
            last = analyzer.consider(ObjectDimensions(length: 8 * scale, width: 4, height: 6))
        }
        XCTAssertEqual(last.state, .stable)
        XCTAssertEqual(analyzer.stable?.length ?? 0, 8 * pow(1.02, 6), accuracy: 1e-9)
    }

    func testSustainedJumpIsAdoptedButFlaggedWhileRecent() {
        var analyzer = LiDARStabilityAnalyzer(configuration: configuration)
        let product = ObjectDimensions(length: 8, width: 4, height: 6)
        let merged = ObjectDimensions(length: 15, width: 8, height: 9)
        for _ in 0..<3 { _ = analyzer.consider(product) }
        _ = analyzer.consider(merged)
        _ = analyzer.consider(merged)
        let adopted = analyzer.consider(merged)

        XCTAssertEqual(adopted.state, .stable)
        XCTAssertTrue(adopted.sustainedJumpAdopted)
        let decision = LiDARMeasurementAcceptance.decide(
            frames: LiDARFrameEvidence(acceptedFrameCountSinceReset: 40),
            lastFrameTracking: .normal,
            analysis: nil,
            stability: adopted,
            uncertaintyCM: nil,
            configuration: configuration
        )
        XCTAssertTrue(decision.warnings.contains(.sustainedDimensionJump))
    }

    func testIdenticalInputProducesIdenticalDimensions() {
        var noisyPlan = plan()
        noisyPlan.depthNoiseSigma = 0.001
        let frames = SyntheticScanner.frames(
            scene: SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            plan: noisyPlan
        )

        let fresh = LiDARMeasurementSession(configuration: configuration)
        let first = fresh.run(frames, region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())

        // A session that already fused unrelated data has dictionaries with
        // a different capacity and iteration order.
        let reused = LiDARMeasurementSession(configuration: configuration)
        reused.run(
            SyntheticScanner.frames(
                scene: SyntheticScene(
                    objects: [SyntheticObject(
                        shape: .cylinder(radius: 0.05, height: 0.10),
                        baseCentre: .zero
                    )],
                    supportHalfExtent: 0.20
                ),
                plan: plan()
            ),
            region: SyntheticRegions.prism(halfWidth: 0.20),
            seed: SyntheticRegions.seed()
        )
        let second = reused.run(frames, region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())

        XCTAssertEqual(first.reportedDimensionsCM, second.reportedDimensionsCM)
        XCTAssertEqual(first.measurement, second.measurement)
        XCTAssertEqual(first.evidence, second.evidence)
    }

    func testPointOrderWithinFramesDoesNotChangeDimensions() throws {
        var noisyPlan = plan()
        noisyPlan.depthNoiseSigma = 0.001
        let frames = SyntheticScanner.frames(
            scene: SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            plan: noisyPlan
        )
        let reversed = frames.map { frame -> LiDARDepthFrame in
            var copy = frame
            copy.points.reverse()
            return copy
        }

        let first = try XCTUnwrap(run(frames).reportedDimensionsCM)
        let second = try XCTUnwrap(run(reversed).reportedDimensionsCM)

        // Float summation order within a voxel differs, so allow rounding
        // noise only: one hundredth of a millimetre.
        for (a, b) in zip(first.values, second.values) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testSquareAndRoundFootprintsResolveOrientationTiesTheSameWayEveryRun() {
        let shapes: [SyntheticObject.Shape] = [
            .box(size: SIMD3<Float>(0.05, 0.05, 0.05)),
            .cylinder(radius: 0.03, height: 0.08)
        ]
        for shape in shapes {
            let scene = SyntheticScene(
                objects: [SyntheticObject(shape: shape, baseCentre: .zero)],
                supportHalfExtent: 0.10
            )
            let frames = SyntheticScanner.frames(scene: scene, plan: plan())
            let first = run(frames)
            let second = run(frames)
            XCTAssertEqual(first.evidence.bounds, second.evidence.bounds)
            XCTAssertNotNil(first.evidence.bounds)
        }
    }

    func testCoordinateEpochChangeDiscardsEarlierEvidence() throws {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        let before = Array(SyntheticScanner.frames(scene: scene, plan: plan()).prefix(12))
        // After the reset the same scene appears 3 cm away, as it would if
        // the world origin had moved under the locked region.
        let shift = SIMD3<Float>(0.03, 0, 0)
        let after = SyntheticScanner.frames(scene: scene, plan: plan()).map { frame -> LiDARDepthFrame in
            var copy = frame
            copy.points = frame.points.map { $0 + shift }
            copy.cameraPosition = frame.cameraPosition.map { $0 + shift }
            copy.timestamp += 10
            copy.coordinateEpoch = 1
            return copy
        }
        let session = LiDARMeasurementSession(configuration: configuration)
        session.begin(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        for frame in before { session.process(frame) }
        XCTAssertNotNil(session.report.reportedDimensionsCM)

        let atReset = session.process(after[0])
        XCTAssertEqual(atReset.frame?.disposition, .acceptedAfterReset)
        XCTAssertNil(atReset.reportedDimensionsCM, "old dimensions must not survive")
        XCTAssertEqual(atReset.decision.status, .refused)
        XCTAssertTrue(atReset.decision.failures.contains(.insufficientAcceptedFrames))

        for frame in after.dropFirst() { session.process(frame) }
        let final = session.refresh()

        // Fusing both coordinate systems would smear the length to ~11 cm.
        assertDimensions(final, boxDimensions)
        XCTAssertEqual(final.evidence.frames.coordinateResetCount, 1)
        XCTAssertEqual(final.evidence.frames.acceptedFrameCountSinceReset, 24)
        XCTAssertEqual(final.evidence.frames.acceptedFrameCount, 36)
        XCTAssertEqual(final.decision.status, .qualified)
        XCTAssertTrue(final.decision.warnings.contains(.evidenceInvalidatedByTrackingReset))
    }

    func testRelocalizingFrameInvalidatesEvidence() {
        let engine = lockedEngine()
        for frame in boxFrames().prefix(8) { engine.integrate(frame: frame) }
        XCTAssertGreaterThan(engine.voxelCount, 0)

        let result = engine.integrate(frame: LiDARDepthFrame(
            points: [],
            timestamp: 5,
            tracking: .relocalizing
        ))

        XCTAssertEqual(result.disposition, .rejected(.trackingNotNormal))
        XCTAssertTrue(result.evidenceWasInvalidated)
        XCTAssertEqual(engine.voxelCount, 0)
        XCTAssertEqual(engine.frameEvidence.coordinateResetCount, 1)
        XCTAssertEqual(engine.frameEvidence.acceptedFrameCountSinceReset, 0)
    }

    func testBriefLimitedTrackingKeepsEvidenceButBlocksAcceptance() {
        let session = LiDARMeasurementSession(configuration: configuration)
        session.run(boxFrames(), region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        let voxelsBefore = session.report.totalVoxelCount
        XCTAssertTrue(session.report.decision.allowsFinish)

        let limited = session.process(LiDARDepthFrame(points: [], timestamp: 100, tracking: .limited))

        XCTAssertEqual(limited.totalVoxelCount, voxelsBefore)
        XCTAssertEqual(limited.evidence.frames.coordinateResetCount, 0)
        XCTAssertFalse(limited.decision.allowsFinish)
        XCTAssertTrue(limited.decision.failures.contains(.trackingNotNormal))
        XCTAssertEqual(limited.evidence.frames.rejectedFrameCounts["trackingNotNormal"], 1)
    }

    func testProlongedLimitedTrackingInvalidatesEvidence() {
        let engine = lockedEngine()
        for frame in boxFrames().prefix(8) { engine.integrate(frame: frame) }

        engine.integrate(frame: LiDARDepthFrame(points: [], timestamp: 5.0, tracking: .limited))
        XCTAssertGreaterThan(engine.voxelCount, 0, "a short lapse keeps the evidence")
        let late = engine.integrate(frame: LiDARDepthFrame(
            points: [],
            timestamp: 5.0 + configuration.maximumLimitedTrackingSeconds + 0.1,
            tracking: .limited
        ))

        XCTAssertTrue(late.evidenceWasInvalidated)
        XCTAssertEqual(engine.voxelCount, 0)
    }

    func testImplausibleCameraJumpIsTreatedAsACoordinateDiscontinuity() {
        let engine = lockedEngine()
        let frames = boxFrames()
        for frame in frames.prefix(8) { engine.integrate(frame: frame) }

        var teleported = frames[8]
        teleported.cameraPosition = frames[8].cameraPosition.map { $0 + SIMD3<Float>(2, 0, 0) }
        let result = engine.integrate(frame: teleported)

        XCTAssertEqual(result.disposition, .acceptedAfterReset)
        XCTAssertEqual(engine.frameEvidence.coordinateResetCount, 1)
        XCTAssertEqual(engine.frameEvidence.acceptedFrameCountSinceReset, 1)
    }

    // MARK: Frame validation and fusion

    func testOutOfOrderFrameIsRejectedAsStale() {
        let engine = lockedEngine()
        let frames = boxFrames()
        engine.integrate(frame: frames[3])

        let result = engine.integrate(frame: frames[2])

        XCTAssertEqual(result.disposition, .rejected(.invalidTimestamp))
        XCTAssertEqual(engine.frameEvidence.acceptedFrameCount, 1)
        XCTAssertEqual(engine.frameEvidence.capturedFrameCount, 2)
    }

    func testFrameStatisticsRecordDuplicatesOutsidePointsAndConfidence() {
        let engine = lockedEngine()
        let inside = SIMD3<Float>(0.0101, 0.0301, 0.0101)
        let result = engine.integrate(frame: LiDARDepthFrame(
            points: [
                inside,
                inside + SIMD3<Float>(0.0002, 0, 0),
                SIMD3<Float>(0.5, 0.03, 0),
                SIMD3<Float>(.nan, 0, 0)
            ],
            timestamp: 1,
            source: .sceneDepth,
            examinedSampleCount: 10,
            lowConfidenceSampleCount: 4,
            outOfRangeSampleCount: 2,
            highConfidenceSampleCount: 3
        ))

        XCTAssertEqual(result.acceptedPointCount, 1)
        let frames = engine.frameEvidence
        XCTAssertEqual(frames.inRegionSampleCount, 2)
        XCTAssertEqual(frames.duplicateSampleCount, 1)
        XCTAssertEqual(frames.outsideRegionSampleCount, 1)
        XCTAssertEqual(frames.nonFiniteSampleCount, 1)
        XCTAssertEqual(frames.lowConfidenceSampleCount, 4)
        XCTAssertEqual(frames.outOfRangeSampleCount, 2)
        XCTAssertEqual(frames.highConfidenceSampleCount, 3)
        XCTAssertEqual(frames.depthSource, .sceneDepth)
    }

    func testDepthSampleFilterRejectsLowConfidenceAndOutOfRangeSamples() {
        func classify(_ depth: Float, _ level: Int?) -> LiDARDepthSampleFilter.Verdict {
            LiDARDepthSampleFilter.classify(
                depth: depth,
                confidenceLevel: level,
                configuration: configuration
            )
        }
        XCTAssertEqual(classify(0.5, 0), .lowConfidence)
        XCTAssertEqual(classify(0.5, 1), .accepted(isHighConfidence: false))
        XCTAssertEqual(classify(0.5, 2), .accepted(isHighConfidence: true))
        XCTAssertEqual(classify(0.5, nil), .accepted(isHighConfidence: false))
        XCTAssertEqual(classify(0.05, 2), .outOfRange)
        XCTAssertEqual(classify(6, 2), .outOfRange)
        XCTAssertEqual(classify(.nan, 2), .outOfRange)
    }

    func testWeaklyObservedVoxelsExpireWhilePersistentOnesRemain() {
        var shortMemory = configuration
        shortMemory.weakVoxelExpiryFrames = 8
        let engine = lockedEngine(configuration: shortMemory)
        let product = denseBox(
            minimum: SIMD3<Int32>(-6, 3, -6),
            maximum: SIMD3<Int32>(6, 14, 6)
        ) + tablePoints()
        // Something passes through for four frames: enough to pass the
        // three-frame filter, never enough to become persistent.
        let passing = patch(centre: SIMD3<Float>(0.06, 0.05, 0.06), halfSize: 0.01)

        for index in 0..<4 {
            engine.integrate(frame: LiDARDepthFrame(
                points: product + passing,
                timestamp: Double(index + 1)
            ))
        }
        let withPassing = engine.analyze().voxels
        for index in 4..<24 {
            engine.integrate(frame: LiDARDepthFrame(points: product, timestamp: Double(index + 1)))
        }
        let later = engine.analyze().voxels

        XCTAssertGreaterThan(later.expiredVoxelCount, 0)
        XCTAssertLessThan(later.stableVoxelCount, withPassing.stableVoxelCount)
        XCTAssertNotNil(engine.measurement(), "persistent product geometry is kept")
    }

    func testAcceptanceRequiresTheMinimumNumberOfFrames() {
        let frames = Array(boxFrames().prefix(configuration.minimumFusedFrameCount - 4))
        let report = run(frames)

        XCTAssertNotNil(report.reportedDimensionsCM)
        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.decision.failures.contains(.insufficientAcceptedFrames))
    }

    func testFramesWithoutCameraPosesAreQualifiedAsUnknownCoverage() {
        var blind = plan()
        blind.reportsCameraPosition = false
        let report = scan(SyntheticScene(objects: [box], supportHalfExtent: 0.10), plan: blind)

        XCTAssertEqual(report.decision.status, .qualified)
        XCTAssertTrue(report.decision.warnings.contains(.viewpointCoverageUnknown))
        XCTAssertNil(report.evidence.coverage?.viewpointSpanDegrees)
    }

    // MARK: Stage-level checks

    func testViewpointSpanIsTheSmallestArcContainingAllViewpoints() {
        var bins = [Bool](repeating: false, count: 72)
        XCTAssertEqual(LiDARCoverageAnalyzer.viewpointSpanDegrees(occupiedBins: bins, binDegrees: 5), 0)
        bins[10] = true
        XCTAssertEqual(LiDARCoverageAnalyzer.viewpointSpanDegrees(occupiedBins: bins, binDegrees: 5), 0)
        bins[22] = true
        XCTAssertEqual(LiDARCoverageAnalyzer.viewpointSpanDegrees(occupiedBins: bins, binDegrees: 5), 60)
        // Wrapping through 0°: bins 70 and 2 are 4 bins apart.
        bins = [Bool](repeating: false, count: 72)
        bins[70] = true
        bins[2] = true
        XCTAssertEqual(LiDARCoverageAnalyzer.viewpointSpanDegrees(occupiedBins: bins, binDegrees: 5), 20)
    }

    func testExcessiveUncertaintyIsRefused() {
        var analysis = LiDARGeometryAnalysis()
        analysis.bounds = LiDARBoundsEvidence(
            yawDegrees: 0,
            trimmedExtentsCM: ObjectDimensions(length: 8, width: 4, height: 6),
            fullExtentsCM: ObjectDimensions(length: 12, width: 4, height: 6),
            measuredDimensionsCM: ObjectDimensions(length: 8.3, width: 4.3, height: 6.15)
        )
        analysis.measurement = LiDARFusionMeasurement(
            dimensionsCM: ObjectDimensions(length: 8.3, width: 4.3, height: 6.15),
            centredPointsInMetres: [],
            worldPointsInMetres: [],
            boundingBoxCornersWorld: [],
            touchesRegionBoundary: false,
            fusedVoxelCount: 500,
            averageObservationsPerVoxel: 8,
            supportPlaneY: 0,
            connectivityMode: .strict
        )
        let stable = LiDARStabilityAssessment(
            state: .stable, estimateCount: 3, consistentEstimateCount: 3,
            spreadCM: ObjectDimensions(length: 0, width: 0, height: 0),
            jumpDetected: false, sustainedJumpAdopted: false
        )
        let uncertainty = LiDARMeasurementAcceptance.uncertaintyCM(
            analysis: analysis,
            stability: stable,
            configuration: configuration
        )

        // A 4 cm untrimmed tail on the length is two centimetres of doubt.
        XCTAssertGreaterThan(uncertainty?.length ?? 0, 2)
        let decision = LiDARMeasurementAcceptance.decide(
            frames: LiDARFrameEvidence(acceptedFrameCountSinceReset: 40),
            lastFrameTracking: .normal,
            analysis: analysis,
            stability: stable,
            uncertaintyCM: uncertainty,
            configuration: configuration
        )
        XCTAssertEqual(decision.status, .refused)
        XCTAssertEqual(decision.failures, [.excessiveUncertainty])
    }

    func testEveryReasonCodeHasGuidanceAndEvidenceRoundTripsThroughJSON() throws {
        for code in LiDARMeasurementReasonCode.allCases {
            XCTAssertFalse(LiDARMeasurementGuidance.message(for: code).isEmpty, code.rawValue)
        }
        let report = scan(SyntheticScene(objects: [box], supportHalfExtent: 0.10))
        let data = try JSONEncoder().encode(report.evidence)
        let decoded = try JSONDecoder().decode(LiDARMeasurementEvidence.self, from: data)

        XCTAssertEqual(decoded, report.evidence)
        XCTAssertEqual(decoded.schemaVersion, LiDARMeasurementEvidence.currentSchemaVersion)
    }

    func testQualifiedMeasurementIsNeverGradedGood() {
        var blind = plan()
        blind.reportsCameraPosition = false
        let report = scan(SyntheticScene(objects: [box], supportHalfExtent: 0.10), plan: blind)

        XCTAssertEqual(report.decision.status, .qualified)
        XCTAssertLessThanOrEqual(report.coverageScore, configuration.qualifiedCoverageScoreCeiling)
        XCTAssertNotEqual(ObjectDimensionCalculator.quality(for: report.coverageScore), .good)
    }

    // MARK: Helpers

    private func plan(
        start: Float = 20,
        sweep: Float = 300,
        cameraHeight: Float = 0.35
    ) -> SyntheticScanPlan {
        SyntheticScanPlan(
            frameCount: 24,
            startAzimuthDegrees: start,
            sweepDegrees: sweep,
            cameraHeight: cameraHeight
        )
    }

    private func scan(
        _ scene: SyntheticScene,
        plan: SyntheticScanPlan? = nil,
        region: LiDARSpatialRegion = SyntheticRegions.prism(),
        seed: SIMD3<Float> = SyntheticRegions.seed()
    ) -> LiDARMeasurementReport {
        LiDARMeasurementSession(configuration: configuration).run(
            SyntheticScanner.frames(scene: scene, plan: plan ?? self.plan()),
            region: region,
            seed: seed
        )
    }

    private func run(
        _ frames: [LiDARDepthFrame],
        configuration: LiDARFusionConfiguration? = nil
    ) -> LiDARMeasurementReport {
        LiDARMeasurementSession(configuration: configuration ?? self.configuration).run(
            frames,
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )
    }

    private func boxFrames() -> [LiDARDepthFrame] {
        SyntheticScanner.frames(
            scene: SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            plan: plan()
        )
    }

    private func lockedEngine(
        configuration: LiDARFusionConfiguration? = nil
    ) -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: configuration ?? self.configuration)
        engine.lockSelection(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        return engine
    }

    private func assertDimensions(
        _ report: LiDARMeasurementReport,
        _ expected: ObjectDimensions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let dimensions = report.reportedDimensionsCM else {
            return XCTFail("no dimensions: \(report.decision)", file: file, line: line)
        }
        XCTAssertEqual(dimensions.length, expected.length, accuracy: toleranceCM, file: file, line: line)
        XCTAssertEqual(dimensions.width, expected.width, accuracy: toleranceCM, file: file, line: line)
        XCTAssertEqual(dimensions.height, expected.height, accuracy: toleranceCM, file: file, line: line)
    }

    private func repeatedOrbit(_ points: [SIMD3<Float>]) -> [LiDARDepthFrame] {
        SyntheticVoxelShapes.repeatedOrbit(points, plan: plan())
    }

    /// Every retained voxel has an empty voxel between it and the next, so
    /// strict connectivity finds only isolated voxels.
    private func latticeBox(
        minimum: SIMD3<Int32> = SIMD3<Int32>(-12, 0, -6),
        maximum: SIMD3<Int32> = SIMD3<Int32>(12, 20, 6)
    ) -> [SIMD3<Float>] {
        SyntheticVoxelShapes.shell(minimum: minimum, maximum: maximum, step: 2)
    }

    /// 24 × 12 voxels across, top at index 20: 7.5 × 3.9 × 6.3 cm after the
    /// pipeline's quantization compensation.
    private var latticeBoxDimensions: ObjectDimensions {
        ObjectDimensions(length: 7.5, width: 3.9, height: 6.3)
    }

    private func denseBox(minimum: SIMD3<Int32>, maximum: SIMD3<Int32>) -> [SIMD3<Float>] {
        SyntheticVoxelShapes.shell(minimum: minimum, maximum: maximum)
    }

    private func tablePoints() -> [SIMD3<Float>] {
        SyntheticVoxelShapes.plane()
    }

    private func patch(centre: SIMD3<Float>, halfSize: Float) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        let steps = Int(halfSize / 0.002)
        for x in -steps...steps {
            for z in -steps...steps {
                points.append(centre + SIMD3<Float>(Float(x) * 0.002, 0, Float(z) * 0.002))
            }
        }
        return points
    }

    /// Mean of the lowest height bin that qualifies as a plane candidate:
    /// the support coordinate the engine used before this refactor.
    private func lowestQualifyingBinMean(_ heights: [Float]) -> Float {
        var bins: [Int32: [Float]] = [:]
        for height in heights {
            bins[Int32((height / configuration.supportPlaneBinSize).rounded()), default: []]
                .append(height)
        }
        let minimum = max(
            configuration.supportPlaneMinimumSamples,
            Int(Double(heights.count) * configuration.supportPlaneMinimumFraction)
        )
        let lowest = bins.filter { $0.value.count >= minimum }.min { $0.key < $1.key }!
        return lowest.value.reduce(0, +) / Float(lowest.value.count)
    }
}
