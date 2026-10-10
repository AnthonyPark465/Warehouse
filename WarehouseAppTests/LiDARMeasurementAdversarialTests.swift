import XCTest
import simd
@testable import WarehouseApp

/// Inputs proposed by an independent adversarial review (Codex) to break the
/// pipeline. Each test either guards a fix or pins a known limitation so it
/// cannot change silently. SYNTHETIC data only.
final class LiDARMeasurementAdversarialTests: XCTestCase {
    private let configuration = LiDARFusionConfiguration.smallObject
    private typealias Shapes = SyntheticVoxelShapes

    // MARK: Fixed by the review

    func testCoordinateResetIsHonouredEvenWhenItsFrameHasAStaleTimestamp() {
        let session = LiDARMeasurementSession(configuration: configuration)
        let frames = Shapes.repeatedOrbit(productAndTable())
        session.run(frames, region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        XCTAssertTrue(session.report.decision.allowsFinish, "\(session.report.decision)")

        var stale = frames[10]
        stale.coordinateEpoch = 1
        let report = session.process(stale)

        XCTAssertEqual(report.frame?.disposition, .rejected(.invalidTimestamp))
        XCTAssertEqual(report.frame?.evidenceWasInvalidated, true)
        XCTAssertEqual(report.totalVoxelCount, 0)
        XCTAssertNil(report.reportedDimensionsCM)
        XCTAssertFalse(report.decision.allowsFinish)
    }

    func testNonFiniteTimestampsAreRejectedWithoutPoisoningTheSession() {
        let engine = lockedEngine()
        let points = productAndTable()
        engine.integrate(frame: LiDARDepthFrame(points: points, timestamp: 1))

        for timestamp in [Double.nan, .infinity, -.infinity] {
            let result = engine.integrate(frame: LiDARDepthFrame(points: points, timestamp: timestamp))
            XCTAssertEqual(result.disposition, .rejected(.invalidTimestamp))
        }
        let next = engine.integrate(frame: LiDARDepthFrame(points: points, timestamp: 2))

        XCTAssertEqual(next.disposition, .accepted)
    }

    func testFramesArrivingFasterThanTheFrameIntervalAreNotCounted() {
        let session = LiDARMeasurementSession(configuration: configuration)
        session.begin(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        let points = productAndTable()
        for index in 0..<40 {
            session.process(LiDARDepthFrame(points: points, timestamp: 1 + Double(index) * 0.001))
        }
        let report = session.refresh()

        XCTAssertEqual(report.evidence.frames.acceptedFrameCount, 1)
        XCTAssertEqual(report.evidence.frames.rejectedFrameCounts["tooSoonAfterPreviousFrame"], 39)
        XCTAssertFalse(report.decision.allowsFinish)
    }

    func testExpandedConnectivityDoesNotBridgeADiagonalTwoVoxelStep() throws {
        // Two sparse shells, each below object size, whose nearest voxels
        // differ by (2, 2, 2): one empty voxel on every axis, 10 mm apart.
        let first = Shapes.shell(
            minimum: SIMD3<Int32>(-8, 4, -8),
            maximum: SIMD3<Int32>(0, 16, 0),
            step: 2,
            includesTop: false
        )
        let second = Shapes.shell(
            minimum: SIMD3<Int32>(2, 18, 2),
            maximum: SIMD3<Int32>(10, 30, 10),
            step: 2,
            includesTop: false
        )
        let voxels = stableVoxels(first + second)
        XCTAssertLessThan(first.count, configuration.minimumStableVoxelCount)
        XCTAssertLessThan(second.count, configuration.minimumStableVoxelCount)
        XCTAssertGreaterThanOrEqual(first.count + second.count, configuration.minimumStableVoxelCount)

        let selection = LiDARComponentSelector.select(
            voxels: voxels,
            seed: Shapes.centre(-4, 10, -4),
            configuration: configuration
        )

        XCTAssertEqual(selection.failure, .insufficientConnectedGeometry)
        XCTAssertTrue(selection.selectedIndices.isEmpty)
    }

    func testLowerShelfIsNotAcceptedAsTheProductsSupport() throws {
        // The surface the product stands on returns too few points to be
        // detected; a lower shelf 6 cm below is dense.
        let product = Shapes.shell(minimum: SIMD3<Int32>(-13, 0, -8), maximum: SIMD3<Int32>(13, 16, 8))
        let shelf = Shapes.plane(halfExtent: 0.09, height: -0.060)
        let report = LiDARMeasurementSession(configuration: configuration).run(
            Shapes.repeatedOrbit(product + shelf),
            region: SyntheticRegions.prism(lowerOffset: -0.08),
            seed: SIMD3<Float>(0, 0.02, 0)
        )

        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.decision.failures.contains(.objectNotOnSupport), "\(report.decision)")
        XCTAssertGreaterThan(
            try XCTUnwrap(report.evidence.supportPlane?.contactGapMetres),
            Double(configuration.maximumSupportContactGap)
        )
    }

    func testProductLedgeIsNotAcceptedAsTheSupport() {
        // A stepped product with no visible table: a wide base, a narrower
        // upper block, and the step between them as the densest horizontal
        // surface. Taking the step as the support would report only the
        // upper block.
        let base = Shapes.shell(minimum: SIMD3<Int32>(-13, 0, -8), maximum: SIMD3<Int32>(13, 6, 8))
        let upper = Shapes.shell(minimum: SIMD3<Int32>(-13, 7, -8), maximum: SIMD3<Int32>(0, 20, 8))
        let report = LiDARMeasurementSession(configuration: configuration).run(
            Shapes.repeatedOrbit(base + upper),
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )

        XCTAssertEqual(report.decision.status, .refused, "\(report.decision)")
        XCTAssertFalse(
            Set(report.decision.failures).isDisjoint(with: [
                .geometryBelowSupport, .supportNotBeyondFootprint, .supportPlaneNotFound
            ]),
            "\(report.decision)"
        )
    }

    func testBrieflySeenGeometryThatExpiresIsReported() {
        var shortMemory = configuration
        shortMemory.weakVoxelExpiryFrames = 8
        let session = LiDARMeasurementSession(configuration: shortMemory)
        session.begin(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        // The far side (+Z) is seen in five frames only, then never again.
        let farSide: (SIMD3<Int32>) -> Bool = { $0.z == 8 && abs($0.x) < 13 }
        let whole = Shapes.shell(minimum: SIMD3<Int32>(-13, 0, -8), maximum: SIMD3<Int32>(13, 16, 8))
            + Shapes.plane()
        let withoutFar = Shapes.shell(
            minimum: SIMD3<Int32>(-13, 0, -8),
            maximum: SIMD3<Int32>(13, 16, 8),
            omitting: farSide
        ) + Shapes.plane()
        let orbit = SyntheticScanPlan(frameCount: 40)
        for index in 0..<40 {
            session.process(LiDARDepthFrame(
                points: index < 5 ? whole : withoutFar,
                timestamp: Double(index + 1) * 0.1,
                cameraPosition: SyntheticScanner.cameraPosition(frame: index, plan: orbit, around: .zero)
            ))
        }
        let report = session.refresh()

        XCTAssertGreaterThan(report.evidence.voxels.expiredStableVoxelCount, 0)
        XCTAssertTrue(report.decision.warnings.contains(.weakGeometryExpired), "\(report.decision)")
        XCTAssertNotEqual(report.decision.status, .accepted)
    }

    func testProductFlatterThanTheRemovalBandIsRefusedWithAFlatProductHint() {
        // 5 mm tall: every product voxel lies inside the removed band.
        let flat = SyntheticObject(shape: .box(size: SIMD3<Float>(0.10, 0.005, 0.08)), baseCentre: .zero)
        let report = LiDARMeasurementSession(configuration: configuration).run(
            SyntheticScanner.frames(
                scene: SyntheticScene(objects: [flat], supportHalfExtent: 0.11),
                plan: SyntheticScanPlan(frameCount: 24)
            ),
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )

        XCTAssertNil(report.reportedDimensionsCM)
        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertTrue(report.guidance.contains { $0.contains("too flat") }, "\(report.guidance)")
    }

    func testObjectSizedStrictComponentNeverAbsorbsANeighbourWithinBridgingReach() throws {
        // A small separate item two voxels from the product: within the
        // expanded radius, touching nothing else, and over a fifth of the
        // combined voxels.
        let product = Shapes.shell(minimum: SIMD3<Int32>(-8, 3, -4), maximum: SIMD3<Int32>(0, 10, 4))
        let item = Shapes.shell(
            minimum: SIMD3<Int32>(2, 3, -3),
            maximum: SIMD3<Int32>(4, 8, 3),
            includesTop: false
        )
        let productCount = Set(product.map(key)).count
        let itemCount = Set(item.map(key)).count
        XCTAssertLessThan(itemCount, configuration.minimumStableVoxelCount)
        XCTAssertGreaterThan(Double(itemCount), 0.2 * Double(productCount + itemCount))

        let selection = LiDARComponentSelector.select(
            voxels: stableVoxels(product + item),
            seed: Shapes.centre(-4, 6, 0),
            configuration: configuration
        )

        XCTAssertEqual(selection.mode, .strict)
        XCTAssertNil(selection.fallbackReason)
        XCTAssertEqual(selection.selected?.voxelCount, productCount)
        XCTAssertEqual(selection.looseFragmentVoxelCount, itemCount)
        XCTAssertTrue(selection.significantFragmentsExcluded)
    }

    func testAcceptedScanIsRefusedOnceTheProductLeavesView() {
        let session = LiDARMeasurementSession(configuration: configuration)
        let frames = Shapes.repeatedOrbit(productAndTable())
        session.run(frames, region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        XCTAssertTrue(session.report.decision.allowsFinish, "\(session.report.decision)")

        let empty = session.process(LiDARDepthFrame(
            points: [SIMD3<Float>(2, 2, 2)],
            timestamp: 50
        ))
        XCTAssertEqual(empty.frame?.disposition, .rejected(.noPointsInRegion))
        XCTAssertFalse(empty.decision.allowsFinish)
        XCTAssertTrue(empty.decision.failures.contains(.productNotInView))

        var back = frames[0]
        back.timestamp = 51
        XCTAssertFalse(session.process(back).decision.failures.contains(.productNotInView))
    }

    func testEstablishedVoxelsStillExpireAfterTheLongTimeout() {
        var shortMemory = configuration
        shortMemory.weakVoxelExpiryFrames = 4
        shortMemory.persistentVoxelExpiryFrames = 12
        let engine = LiDARVoxelFusionEngine(configuration: shortMemory)
        engine.lockSelection(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        let first = Shapes.shell(minimum: SIMD3<Int32>(-13, 0, -8), maximum: SIMD3<Int32>(-3, 16, 8))
        let replacement = Shapes.shell(minimum: SIMD3<Int32>(3, 0, -8), maximum: SIMD3<Int32>(13, 16, 8))
        let firstKeys = Set(first.map(key))

        for index in 0..<8 {
            engine.integrate(frame: LiDARDepthFrame(points: first, timestamp: Double(index + 1)))
        }
        XCTAssertGreaterThanOrEqual(engine.voxelCount, firstKeys.count)
        for index in 8..<40 {
            engine.integrate(frame: LiDARDepthFrame(points: replacement, timestamp: Double(index + 1)))
        }

        XCTAssertEqual(engine.voxelCount, Set(replacement.map(key)).count)
        XCTAssertGreaterThan(engine.analyze().voxels.expiredStableVoxelCount, 0)
    }

    func testThinlyScannedBaseBelowAShoulderIsNotIgnored() {
        // A stepped product: its lower part returned only a few voxels, and
        // its shoulder is the lowest dense horizontal surface.
        let upper = Shapes.shell(minimum: SIMD3<Int32>(-6, 17, -6), maximum: SIMD3<Int32>(6, 34, 6))
        let shoulder = Shapes.plane(halfExtent: 0.045, height: 0.0495, spacing: 0.003)
        let base = (0..<16).map { Shapes.centre(Int32($0) - 8, 4, -14) }
        let report = LiDARMeasurementSession(configuration: configuration).run(
            Shapes.repeatedOrbit(upper + shoulder + base),
            region: SyntheticRegions.prism(),
            seed: SIMD3<Float>(0, 0.07, 0)
        )

        XCTAssertEqual(report.decision.status, .refused, "\(report.decision)")
        XCTAssertTrue(report.decision.failures.contains(.geometryBelowSupport), "\(report.decision)")
    }

    func testFinishableResultIsReanalysedOnEveryFrameSoNewContactIsSeenImmediately() {
        let session = LiDARMeasurementSession(configuration: configuration)
        let frames = Shapes.repeatedOrbit(productAndTable())
        let region = SyntheticRegions.prism(halfWidth: 0.06)
        session.run(frames, region: region, seed: SyntheticRegions.seed())
        XCTAssertTrue(session.report.decision.allowsFinish, "\(session.report.decision)")

        // The product now also reaches the +X limit of the region.
        let extension_ = Shapes.shell(
            minimum: SIMD3<Int32>(13, 3, -8),
            maximum: SIMD3<Int32>(19, 16, 8)
        )
        var report = session.report
        for index in 0..<3 {
            report = session.process(LiDARDepthFrame(
                points: productAndTable() + extension_,
                timestamp: 100 + Double(index) * 0.1
            ))
            // The third frame makes the new voxels stable; each frame is
            // analysed without waiting for the usual interval.
            XCTAssertTrue(report.analysisWasUpdated || !report.decision.allowsFinish)
        }

        XCTAssertFalse(report.decision.allowsFinish, "\(report.decision)")
        XCTAssertTrue(report.decision.failures.contains(.regionBoundaryContact), "\(report.decision)")
    }

    func testStabilityMustBeEarnedAgainAfterAnAnalysisWithNoEstimate() {
        let session = LiDARMeasurementSession(configuration: configuration)
        let frames = Shapes.repeatedOrbit(productAndTable())
        session.run(frames, region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        XCTAssertTrue(session.report.dimensionsAreStable)

        // Evidence is discarded; the first estimate afterwards is alone.
        var next = frames[0]
        next.timestamp = 200
        next.coordinateEpoch = 1
        session.process(next)
        var latest = session.report
        for index in 1..<8 {
            var frame = frames[index]
            frame.timestamp = 200 + Double(index) * 0.1
            frame.coordinateEpoch = 1
            latest = session.process(frame)
            if latest.reportedDimensionsCM != nil { break }
        }

        XCTAssertNotNil(latest.reportedDimensionsCM)
        XCTAssertFalse(latest.dimensionsAreStable)
        XCTAssertTrue(latest.decision.failures.contains(.dimensionsUnstable))
    }

    // MARK: Found by the synthetic ablation

    func testSliverBridgedFromAPatchySurfaceIsRefusedAsPartial() throws {
        // `patchy-pair-3-gap8mm` of the synthetic ablation. No tile of the
        // patchy surface is object-sized, and the default reach joins four
        // of them near the seed into a 2 × 1 × 6 cm column. It stands on the
        // support, is stable and evenly covered within its own bounds, and
        // used to be offered as qualified.
        let testCase = try XCTUnwrap(
            MeasurementAblation.freeSpaceCases().first { $0.name == "patchy-pair-3-gap8mm" }
        )
        let report = LiDARMeasurementSession(configuration: configuration).run(
            SyntheticScanner.frames(scene: testCase.scene, plan: testCase.plan),
            region: testCase.region,
            seed: testCase.seed
        )

        let components = try XCTUnwrap(report.evidence.components)
        XCTAssertEqual(components.connectivityMode, LiDARComponentSelection.Mode.expanded.rawValue)
        XCTAssertGreaterThan(
            try XCTUnwrap(components.nearbyFragmentVoxelCount),
            components.selected.voxelCount
        )
        XCTAssertEqual(report.decision.status, .refused)
        XCTAssertEqual(report.decision.failures, [.possiblePartialObject])
        // The estimate behind the refusal is the sliver, not the product.
        let dimensions = try XCTUnwrap(report.reportedDimensionsCM)
        XCTAssertLessThan(dimensions.length, testCase.truth.length / 2)
    }

    func testBridgedSelectionIsPartialOnlyWhenNearbyFragmentsHoldALargeShare() {
        // Four 6 × 6 tiles one missing voxel apart: object-sized only when
        // bridged. Two empty voxels away, beyond the reach, more tiles.
        func tile(x: ClosedRange<Int32>, from y: Int32) -> [SIMD3<Float>] {
            x.flatMap { x in (y...(y + 5)).map { Shapes.centre(x, $0, 0) } }
        }
        let column = [3, 10, 17, 24].flatMap { tile(x: 0...5, from: $0) }
        let restOfSurface = [3, 11, 19].flatMap { tile(x: 8...13, from: $0) }
        let smallFragment = tile(x: 8...11, from: 3)
        func select(_ points: [SIMD3<Float>]) -> LiDARComponentSelection {
            LiDARComponentSelector.select(
                voxels: stableVoxels(points),
                seed: Shapes.centre(2, 3, 0),
                configuration: configuration
            )
        }

        let partial = select(column + restOfSurface)
        XCTAssertEqual(partial.mode, .expanded)
        XCTAssertEqual(partial.selected?.voxelCount, 144)
        XCTAssertEqual(partial.nearbyFragmentVoxelCount, 108)
        XCTAssertTrue(partial.selectionLooksPartial)

        // A sparse product with one small fragment beside it is still
        // offered, with the proximity warning.
        let whole = select(column + smallFragment)
        XCTAssertEqual(whole.mode, .expanded)
        XCTAssertEqual(whole.nearbyFragmentVoxelCount, 24)
        XCTAssertFalse(whole.selectionLooksPartial)
        XCTAssertTrue(whole.nearbyObjectDetected)
    }

    // MARK: Conservative by design

    func testFragmentContestedByTwoObjectsIsNotAbsorbedAndTheResultIsQualified() throws {
        // Two object-sized shells two voxels apart, with a small fragment in
        // reach of both. Its owner is ambiguous, so it joins neither.
        let a = Shapes.shell(minimum: SIMD3<Int32>(-14, 3, -6), maximum: SIMD3<Int32>(-2, 14, 6))
        let b = Shapes.shell(minimum: SIMD3<Int32>(2, 3, -6), maximum: SIMD3<Int32>(14, 14, 6))
        let fragment = (16...19).map { Shapes.centre(0, Int32($0), 0) }
            + (16...19).map { Shapes.centre(0, Int32($0), 1) }
        let voxels = stableVoxels(a + b + fragment)

        let selection = LiDARComponentSelector.select(
            voxels: voxels,
            seed: Shapes.centre(-8, 8, 0),
            configuration: configuration
        )

        XCTAssertEqual(selection.mode, .strict)
        XCTAssertEqual(selection.selected?.voxelCount, Set(a.map(key)).count)
        XCTAssertTrue(selection.nearbyObjectDetected)
    }

    // MARK: Known limitations, pinned

    /// Two boxes pressed together, their facing sides hidden from the
    /// sensor, are geometrically one box. Nothing in the depth data
    /// separates them; the user must.
    func testTouchingProductsWithHiddenFacingSidesMeasureAsOneBox() throws {
        var left = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.06, 0.05, 0.045)),
            baseCentre: SIMD3<Float>(-0.03, 0, 0)
        )
        left.omittedNormals = [SIMD3<Float>(1, 0, 0)]
        var right = left
        right.baseCentre.x = 0.03
        right.omittedNormals = [SIMD3<Float>(-1, 0, 0)]
        let report = LiDARMeasurementSession(configuration: configuration).run(
            SyntheticScanner.frames(
                scene: SyntheticScene(objects: [left, right], supportHalfExtent: 0.11),
                plan: SyntheticScanPlan(frameCount: 24)
            ),
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )

        let dimensions = try XCTUnwrap(report.reportedDimensionsCM)
        XCTAssertEqual(dimensions.length, 12, accuracy: 0.6)
        XCTAssertFalse(report.decision.failures.contains(.possibleMergedObjects))
    }

    /// A product with a real internal divider looks like two touching
    /// objects to the merge check and is refused; it must be entered by hand.
    func testProductWithAnInternalDividerIsRefusedAsAPossibleMerge() {
        let bin = Shapes.shell(
            minimum: SIMD3<Int32>(-15, 0, -10),
            maximum: SIMD3<Int32>(15, 26, 10),
            includesTop: false
        )
        var divider: [SIMD3<Float>] = []
        for y in Int32(0)...26 {
            for z in Int32(-9)...9 { divider.append(Shapes.centre(0, y, z)) }
        }
        let report = LiDARMeasurementSession(configuration: configuration).run(
            Shapes.repeatedOrbit(bin + divider + Shapes.plane()),
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )

        XCTAssertTrue(report.decision.failures.contains(.possibleMergedObjects), "\(report.decision)")
    }

    // MARK: Rejected proposal, checked

    /// Proposal: a single stripe near a missing far side would shorten the
    /// width while reporting that side as covered. With the adjacent sides
    /// present, they still span the full width, so the width is not short.
    func testStripeNearAMissingSideDoesNotShortenTheWidth() throws {
        let body = Shapes.shell(
            minimum: SIMD3<Int32>(-16, 0, -10),
            maximum: SIMD3<Int32>(16, 16, 10),
            includesTop: false,
            omitting: { $0.z == 10 && abs($0.x) < 16 }
        )
        let stripe = (Int32(-16)...16).map { Shapes.centre($0, 15, 6) }
        let report = LiDARMeasurementSession(configuration: configuration).run(
            Shapes.repeatedOrbit(body + stripe + Shapes.plane()),
            region: SyntheticRegions.prism(),
            seed: SyntheticRegions.seed()
        )

        let dimensions = try XCTUnwrap(report.reportedDimensionsCM)
        XCTAssertEqual(dimensions.width, 6.3, accuracy: 0.6)
    }

    // MARK: Helpers

    private func productAndTable() -> [SIMD3<Float>] {
        Shapes.shell(minimum: SIMD3<Int32>(-13, 0, -8), maximum: SIMD3<Int32>(13, 16, 8))
            + Shapes.plane()
    }

    private func lockedEngine() -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)
        engine.lockSelection(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        return engine
    }

    private func key(_ point: SIMD3<Float>) -> LiDARVoxelKey {
        .containing(point, cellSize: configuration.voxelSize)
    }

    private func stableVoxels(_ points: [SIMD3<Float>]) -> [LiDARStableVoxel] {
        var seen: Set<LiDARVoxelKey> = []
        return points.compactMap { point -> LiDARStableVoxel? in
            let voxelKey = key(point)
            guard seen.insert(voxelKey).inserted else { return nil }
            return LiDARStableVoxel(key: voxelKey, position: point, local: point, observations: 6)
        }.sorted { $0.key < $1.key }
    }
}
